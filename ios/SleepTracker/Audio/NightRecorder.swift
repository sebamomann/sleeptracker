import Foundation
import UIKit

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

    private let saveEvery: TimeInterval = 15

    private let engine = CaptureEngine()
    private let policy = AudioSessionPolicy()
    private let store = SessionStore.shared
    private var saveTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []

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

    func start() {
        guard !isRecording else { return }
        lastError = nil

        let now = Date()
        let id = Fmt.sessionID.string(from: now)
        session = NightSession.beginning(id: id, at: now)
        let settings = Calibration.config()
        session?.gateDbUsed = settings.gateDB
        session?.minPeakDbUsed = settings.minPeakDB
        mark("gate \(Int(settings.gateDB)) dB over floor, ignoring under "
            + "\(Int(settings.minPeakDB)) dBFS")
        pipeline.begin(nightID: id, at: now)

        do {
            try store.prepare(id: id)
            try policy.activate()
            try mark("input " + (engine.start()))
            observeAppLifecycle()
            isRecording = true
            saveTimer = Timer
                .scheduledTimer(withTimeInterval: saveEvery, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.persist() }
                }
            StartReminder.reschedule(skippingTonight: true) // tonight is covered
            persist()
        } catch {
            lastError = String(describing: error)
            mark("start failed: \(error)")
            stop()
        }
    }

    func stop() {
        engine.stop()
        // Anything still waiting on its tail is cut now with whatever was recorded: a
        // slightly short last event beats losing it.
        pipeline.flush()
        saveTimer?.invalidate(); saveTimer = nil
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
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
        }
    }

    private func restartEngine(reason: String) {
        do { try mark("engine restarted \(reason): " + (engine.start())) } catch {
            mark("engine restart failed \(reason): \(error)")
        }
    }

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        for (name, label) in [(UIApplication.didEnterBackgroundNotification, "backgrounded"),
                              (UIApplication.willEnterForegroundNotification, "foregrounded")] {
            lifecycleObservers.append(nc.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // "backgrounded" is the moment that mattered on the web: capture died
                    // there. Here it is the evidence that it does not.
                    self?.mark(label)
                    self?.persist()
                }
            })
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
        session?.marks.append(.init(at: Date().timeIntervalSince1970 * 1000, what: what))
    }

    private func persist() {
        guard var s = session else { return }
        s.lastAliveAt = Date().timeIntervalSince1970 * 1000

        pipeline.snapshot(into: &s)
        session = s
        do { try store.save(s) } catch { lastError = "save failed: \(error)" }
    }
}
