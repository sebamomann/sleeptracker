import Foundation

/// Runs a night: starts capture, feeds the gate, writes what the gate catches, and records
/// enough about its own behaviour to show whether capture survived the screen locking.
///
/// Orchestration only. The microphone and its conversion live in `CaptureEngine`, the
/// session category and system interruptions in `AudioSessionPolicy`, and encoding and
/// labelling in `EventWriter`.
///
/// Three threads meet here, and the boundaries are the design:
///   * the **audio thread** delivers samples and must never wait on anything;
///   * **`AnalysisPipeline`** owns the gate, the ring and the health counters, on its own
///     serial queue;
///   * **`io`** encodes, classifies and writes, which takes long enough that it cannot
///     share a queue with the audio path.
@MainActor
final class NightRecorder: ObservableObject {
    @Published private(set) var session: NightSession?
    @Published private(set) var isRecording = false
    @Published private(set) var levelDB = -100.0
    @Published private(set) var floorDB = -60.0
    @Published private(set) var lastError: String?
    /// When the night begins to be kept, while `ListeningDelay` is still running. Capture is
    /// already on; nothing before this is written.
    @Published private(set) var listensAt: Date?

    private let saveEvery: TimeInterval = 15

    private let engine = CaptureEngine()
    private let policy = AudioSessionPolicy()
    private let store = SessionStore.shared
    private var saveTimer: Timer?
    /// Logged during the wait, before a night exists. Without "backgrounded" from then, the
    /// report would say the phone never left the foreground.
    private var waitLog: [NightSession.Mark] = []

    private let pipeline: AnalysisPipeline
    /// Encoding, classifying and writing take long enough that they cannot share a queue
    /// with the audio path. `nonisolated(unsafe)` states the discipline the compiler cannot
    /// check: `writer` is touched only from `io`.
    private let io = DispatchQueue(label: "de.sebamomann.sleeptracker.io", qos: .utility)
    nonisolated(unsafe) private let writer: EventWriter

    init() {
        writer = EventWriter(format: engine.workFormat)
        // Tonight runs on what the last few nights taught it, not on constants.
        pipeline = AnalysisPipeline(
            sampleRate: CaptureEngine.sampleRate,
            ringSeconds: 120,
            gateConfig: Calibration.config()
        )

        engine.onSamples = { [weak self] samples in
            // On the audio thread: hand off and return immediately.
            self?.pipeline.push(samples)
        }
        pipeline.onEvent = { [weak self] pending in self?.write(pending) }
        pipeline.onDropped = { [weak self] in
            Task { @MainActor in self?.session?.droppedEvents += 1 }
        }
        pipeline.onLevel = { [weak self] floor, peak in
            Task { @MainActor in
                self?.floorDB = floor
                self?.levelDB = peak
            }
        }
        policy.onSystemEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Control

    /// Capture starts now; the night starts after `ListeningDelay`, or now if there is none.
    func start() {
        guard !isRecording else { return }
        lastError = nil
        session = nil
        waitLog = []

        let delay = ListeningDelay.seconds
        if delay > 0 {
            // Checked when the hold ends: a wait outliving a stop must not begin a night.
            let target = Date().addingTimeInterval(delay)
            listensAt = target
            pipeline.hold(seconds: delay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, listensAt == target else { return }
                    listensAt = nil
                    do { try beginNight(delay: delay) } catch { fail(error) }
                }
            }
        }

        do {
            // Either way the pipeline is set up before capture starts, so not one sample
            // reaches last night's gate.
            if delay == 0 {
                try beginNight(delay: 0)
            }
            try policy.activate()
            try mark("input " + engine.start())
            isRecording = true
            saveTimer = Timer
                .scheduledTimer(withTimeInterval: saveEvery, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.persist() }
                }
            StartReminder.reschedule(skippingTonight: true) // tonight is covered
            persist()
        } catch {
            fail(error)
        }
    }

    /// Create the night's session and start keeping what the gate catches.
    private func beginNight(delay: TimeInterval) throws {
        let now = Date()
        let id = Fmt.sessionID.string(from: now)
        session = NightSession.beginning(
            id: id, at: now, settings: Calibration.config(), delay: delay, earlier: waitLog
        )
        pipeline.begin(nightID: id, at: now)
        try store.prepare(id: id)
        persist()
    }

    private func fail(_ error: Error) {
        lastError = String(describing: error)
        mark("start failed: \(error)")
        stop()
    }

    func stop() {
        engine.stop()
        // Stopped during the wait: there is no night, and nothing to save.
        pipeline.cancelHold()
        listensAt = nil
        // Anything still waiting on its tail is cut now with whatever was recorded: a
        // slightly short last event beats losing it.
        pipeline.flush()
        saveTimer?.invalidate(); saveTimer = nil
        isRecording = false

        mark("stopped")
        session?.ended = true
        session?.endedAt = Date()
        persist() // refreshes the envelope the gap search needs

        if var s = session {
            s.quietGaps = QuietGaps.find(in: s)
            if !(s.quietGaps ?? []).isEmpty {
                mark("\((s.quietGaps ?? []).count) quiet gaps inside episodes")
            }
            session = s
            try? store.save(s)
            // Feed the night back, so tomorrow starts from what tonight showed.
            Calibration.learn(from: s)
        }

        policy.deactivate()
        StartReminder.reschedule()
    }

    // MARK: - System events

    private func handle(_ event: AudioSessionPolicy.SystemEvent) {
        switch event {
        case .interruptionBegan:
            session?.interruptions += 1
            mark("INTERRUPTION began")
            persist()

        case .interruptionEnded:
            // A phone call, an alarm, Siri. Resume rather than treating the night as over.
            mark("interruption ended")
            policy.reactivate()
            if isRecording, !engine.isRunning {
                restartEngine(reason: "after interruption")
            }
            persist()

        case .mediaServicesReset:
            guard isRecording else { return }
            session?.interruptions += 1
            mark("MEDIA SERVICES RESET")
            engine.stop()
            try? policy.activate()
            restartEngine(reason: "after reset")
            persist()

        case .routeChanged:
            mark("route changed")

        case .backgrounded, .foregrounded:
            mark(event == .backgrounded ? "backgrounded" : "foregrounded")
            persist()
        }
    }

    private func restartEngine(reason: String) {
        do { try mark("engine restarted \(reason): " + (engine.start())) } catch {
            mark("engine restart failed \(reason): \(error)")
        }
    }

    // MARK: - Events

    /// On the pipeline's queue: hand the event to `io`, which encodes, classifies and writes.
    nonisolated private func write(_ pending: PendingEvent) {
        io.async { [weak self] in
            guard let self else { return }
            do {
                let written = try writer.write(pending)
                Task { @MainActor [weak self] in self?.record(written) }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "write failed: \(error)"
                    self?.mark("event write failed: \(error)")
                }
            }
        }
    }

    private func record(_ written: EventWriter.Written) {
        session?.events.append(written.record)
        persist()
        guard written.isSpeech else { return }

        // Transcription is slower and asynchronous, so the event is stored first and patched
        // when text arrives. A speech event with no transcript yet is still one you can
        // listen to.
        let index = written.record.index
        let url = written.url
        Task.detached(priority: .utility) {
            guard let text = await Transcriber.shared.transcribe(url: url) else { return }
            await MainActor.run { [weak self] in
                guard let self, var s = session,
                      let i = s.events.firstIndex(where: { $0.index == index }) else { return }
                s.events[i].transcript = text
                session = s
                persist()
            }
        }
    }

    // MARK: - Persistence

    private func mark(_ what: String) {
        let entry = NightSession.Mark(at: Date().timeIntervalSince1970 * 1000, what: what)
        guard session != nil else { return waitLog.append(entry) }
        session?.marks.append(entry)
    }

    private func persist() {
        guard var s = session else { return }
        s.lastAliveAt = Date().timeIntervalSince1970 * 1000

        pipeline.snapshot(into: &s)
        session = s
        do { try store.save(s) } catch { lastError = "save failed: \(error)" }
    }
}
