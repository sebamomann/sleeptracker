// @preconcurrency silences one Sendable warning: AVAudioConverter's input block is
// @Sendable and captures the tap's buffer. That capture is safe because the block runs
// synchronously inside convert(), on the audio thread, while the buffer is still valid —
// handing the same buffer to another queue to read *later* was the real bug, and that is
// gone. Without this, the only alternatives are suppressing it at the call site or
// pretending AVAudioPCMBuffer is Sendable.
@preconcurrency import AVFoundation
import Foundation
import UIKit

/// Captures the night, gates it, writes one WAV per event, and records enough about its own
/// behaviour to prove whether capture survived the screen locking.
///
/// The two things that make this work where the web version could not:
///   * `UIBackgroundModes: audio` in Info.plist, so iOS keeps the session alive when the
///     screen locks. A plist declaration, not a signed entitlement — it works on a free
///     personal team.
///   * `.measurement` mode, which disables the input processing chain. The browser needed
///     echoCancellation/noiseSuppression/autoGainControl off for the same reason: AGC
///     renormalises levels so the noise floor is meaningless, and noise suppression deletes
///     exactly the quiet sounds the gate is hunting for.
@MainActor
final class NightRecorder: ObservableObject {
    @Published private(set) var session: NightSession?
    @Published private(set) var isRecording = false
    @Published private(set) var levelDB = -100.0
    @Published private(set) var floorDB = -60.0
    @Published private(set) var lastError: String?

    // nonisolated: read from the audio thread and the processing queue, not just the UI.
    nonisolated static let sampleRate = 16_000.0   // SoundAnalysis and YAMNet want 16 kHz mono
    private let ringSeconds = 120
    private let saveEvery: TimeInterval = 15

    private let engine = AVAudioEngine()
    private let store = SessionStore.shared
    private var saveTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// The analysis state below is touched ONLY on `processing`, never from the main actor
    /// or the audio thread. `nonisolated(unsafe)` states that discipline: the compiler
    /// cannot check it, the serial queue enforces it.
    private let processing = DispatchQueue(label: "de.sebamomann.sleeptracker.processing",
                                            qos: .userInitiated)
    /// Writing a WAV and classifying it takes tens to hundreds of milliseconds. On the
    /// processing queue that would stall the audio path behind it and drop capture, so it
    /// gets its own queue and a lower priority.
    private let io = DispatchQueue(label: "de.sebamomann.sleeptracker.io", qos: .utility)
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var gate: NoiseGate?
    private nonisolated(unsafe) var ring: SampleRing?
    private nonisolated(unsafe) var health = CaptureHealth()
    private nonisolated(unsafe) var totalSamples = 0
    private nonisolated(unsafe) var eventCounter = 0
    private nonisolated(unsafe) var nightID = ""
    private nonisolated(unsafe) var nightStart = Date()

    private let workFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: NightRecorder.sampleRate,
                                           channels: 1, interleaved: false)!

    // MARK: - Control

    func start() {
        guard !isRecording else { return }
        lastError = nil
        let now = Date()
        let id = Self.idFormatter.string(from: now)

        var s = NightSession(
            id: id,
            t0: now.timeIntervalSince1970 * 1000,
            startedAt: now,
            lastAliveAt: now.timeIntervalSince1970 * 1000,
            device: .init(model: Self.deviceModel,
                          systemVersion: UIDevice.current.systemVersion,
                          appVersion: Self.appVersion),
            sampleRate: Self.sampleRate)
        s.marks.append(.init(at: s.t0, what: "started"))
        let classifier = EventClassifier.shared
        s.knownLabels = classifier.knownLabels
        s.marks.append(.init(at: s.t0, what: classifier.isAvailable
            ? "classifier ready, \(classifier.knownLabels.count) labels"
            : "CLASSIFIER UNAVAILABLE"))
        // Recorded up front: "nothing was transcribed" is not a useful thing to discover in
        // the morning without knowing why.
        if let why = Transcriber.shared.unavailableReason {
            s.marks.append(.init(at: s.t0, what: "TRANSCRIPTION UNAVAILABLE: \(why)"))
        } else {
            s.marks.append(.init(at: s.t0, what: "on-device transcription ready"))
        }
        session = s

        processing.sync {
            nightID = id
            nightStart = now
            totalSamples = 0
            eventCounter = 0
            health = CaptureHealth()
            gate = nil
            ring = nil
        }

        do {
            try store.prepare(id: id)
            try configureSession()
            try startEngine()
            observeLifecycle()
            isRecording = true
            // Tonight is covered; the next nudge belongs to tomorrow.
            StartReminder.reschedule(skippingTonight: true)
            saveTimer = Timer.scheduledTimer(withTimeInterval: saveEvery, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.persist() }
            }
            persist()
        } catch {
            lastError = String(describing: error)
            mark("start failed: \(error)")
            stop()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        saveTimer?.invalidate(); saveTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        converter = nil
        isRecording = false

        mark("stopped")
        session?.ended = true
        session?.endedAt = Date()
        persist()                       // refreshes the envelope the gap search needs

        if var s = session {
            s.quietGaps = QuietGaps.find(in: s)
            if !(s.quietGaps ?? []).isEmpty {
                mark("\((s.quietGaps ?? []).count) quiet gaps inside episodes")
            }
            session = s
            try? store.save(s)
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        StartReminder.reschedule()
    }

    // MARK: - Diagnostics

    private func mark(_ what: String) {
        session?.marks.append(.init(at: Date().timeIntervalSince1970 * 1000, what: what))
    }

    private func persist() {
        guard var s = session else { return }
        s.lastAliveAt = Date().timeIntervalSince1970 * 1000

        // Snapshot the analysis state from its own queue rather than reaching into it.
        processing.sync {
            s.audioSec = health.audioSeconds
            s.gaps = health.gaps
            s.lastFrameAtMs = health.lastFrameAt.map { $0.timeIntervalSince1970 * 1000 }
            if let g = gate {
                s.floorDb = g.floorDB
                s.thresholdDb = g.threshold
                // Rounded to whole dB: at one sample per second an eight-hour night is ~29k
                // entries, and the extra precision is noise the report never shows.
                s.envelope = g.envelope.map { [$0.mean.rounded(), $0.max.rounded(), $0.p10.rounded()] }
            }
        }

        session = s
        do { try store.save(s) } catch { lastError = "save failed: \(error)" }
    }

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // The moment that mattered on the web: this is where capture died there.
                self?.mark("backgrounded")
                self?.persist()
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.mark("foregrounded")
                self?.persist()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.mark("route changed") }
        })
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .record rather than .playAndRecord: nothing here plays, and the narrower category
        // is less likely to be interrupted by other audio on the device.
        //
        // No .allowBluetoothHFP: with it, a pair of AirPods left on the nightstand — or in a
        // closed case — becomes the input, and the night is recorded through a muffled
        // 8 kHz headset mic instead of the phone lying next to you.
        try session.setCategory(.record, mode: .measurement)
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setActive(true)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        })
        // Media services can be reset out from under a long-running session; without this
        // the engine comes back silently dead and the night is lost with no gap recorded.
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartAfterReset() }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            session?.interruptions += 1
            mark("INTERRUPTION began")
            persist()
        case .ended:
            // A phone call, an alarm, Siri. Resume rather than treating the night as over.
            mark("interruption ended")
            try? AVAudioSession.sharedInstance().setActive(true)
            if isRecording, !engine.isRunning {
                do { try startEngine(); mark("engine restarted") }
                catch { mark("engine restart failed: \(error)") }
            }
            persist()
        @unknown default:
            break
        }
    }

    private func restartAfterReset() {
        guard isRecording else { return }
        session?.interruptions += 1
        mark("MEDIA SERVICES RESET")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try configureSession()
            try startEngine()
            mark("engine rebuilt after reset")
        } catch {
            mark("rebuild failed: \(error)")
        }
        persist()
    }

    // MARK: - Capture

    private func startEngine() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "SleepTracker", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "input node has no format — is the mic permission granted?"])
        }
        mark("input \(Int(hwFormat.sampleRate)) Hz \(hwFormat.channelCount)ch → \(Int(Self.sampleRate)) Hz mono")

        // Built before the tap is installed, so this is the one point where the processing
        // state is touched from elsewhere.
        let hw = hwFormat
        let work = workFormat
        converter = AVAudioConverter(from: hw, to: work)
        processing.sync {
            if gate == nil {
                let g = NoiseGate(sampleRate: Self.sampleRate)
                g.onEvent = { [weak self] event in self?.harvest(event) }   // on `processing`
                gate = g
                ring = SampleRing(capacity: Int(Self.sampleRate) * ringSeconds)
            }
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Called on the audio thread. The tap's buffer is owned by the engine and recycled as
    /// soon as this returns, so it is converted and COPIED here — handing it to another
    /// thread to read later is a use-after-free that shows up as corrupted audio.
    private nonisolated func handle(_ buffer: AVAudioPCMBuffer) {
        let work = workFormat
        let ratio = work.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        // Converted inline on the audio thread. Handing this to another queue and waiting
        // would put the audio path behind whatever that queue is doing, and a stall here is
        // dropped capture.
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: work,
                                                        frameCapacity: capacity) else { return }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        processing.async { [weak self] in self?.consume(samples) }
    }

    /// On `processing`. Owns all analysis state; publishes only values to the main actor.
    private nonisolated func consume(_ samples: [Float]) {
        guard let gate, let ring else { return }
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            ring.append(base, count: buf.count)
            gate.process(base, count: buf.count, totalSamplesBefore: totalSamples)
        }
        totalSamples += samples.count
        health.note(totalSamples: totalSamples, sampleRate: Self.sampleRate)

        let floor = gate.floorDB
        let level = gate.read()
        Task { @MainActor [weak self] in
            self?.floorDB = floor
            self?.levelDB = level
        }
    }

    // MARK: - Events

    /// On `processing`: cut the event out of the ring and write it, off the main thread.
    private nonisolated func harvest(_ event: GateEvent) {
        guard let ring else { return }
        let samples = ring.slice(from: event.startSample, to: event.endSample)
        // Empty means the audio scrolled out of the ring before we reached it. Recording it
        // as a file of zeroes would be worse than admitting it is gone.
        guard !samples.isEmpty else {
            Task { @MainActor [weak self] in self?.session?.droppedEvents += 1 }
            return
        }

        eventCounter += 1
        let index = eventCounter
        let at = nightStart.addingTimeInterval(Double(event.startSample) / Self.sampleRate)
        let startS = Double(event.startSample) / Self.sampleRate
        let endS = Double(event.endSample) / Self.sampleRate
        let peak = event.peakDB
        let night = nightID

        io.async { [weak self] in
            self?.writeAndClassify(samples: samples, index: index, at: at,
                                   startS: startS, endS: endS, peak: peak, nightID: night)
        }
    }

    /// On `io`: fade, write, classify, then report back. Never on the audio path.
    private nonisolated func writeAndClassify(samples: [Float], index: Int, at: Date,
                                              startS: Double, endS: Double, peak: Double,
                                              nightID: String) {
        // Ramp the edges: a gated clip starts at an arbitrary sample, so its first and last
        // values are almost never zero, and that step is audible as a click at both ends.
        var faded = samples
        Self.fadeEdges(&faded, rate: Self.sampleRate, ms: 40)
        // AAC in m4a rather than WAV: roughly a tenth the size at 32 kbps mono, which is
        // ample for 16 kHz speech and snoring. Not Opus — on iOS that means a CAF container
        // nothing outside Apple's stack will open, whereas m4a plays everywhere and is read
        // natively by both the classifier and the transcriber.
        let file = String(format: "%04d-%@.m4a", index, Self.timeFormatter.string(from: at))
        let url = SessionStore.shared.eventsDirectory(for: nightID).appendingPathComponent(file)

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let audioFile = try AVAudioFile(forWriting: url, settings: settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: workFormat,
                                             frameCapacity: AVAudioFrameCount(faded.count))
            else { return }
            buf.frameLength = AVAudioFrameCount(faded.count)
            faded.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: faded.count)
            }
            try audioFile.write(from: buf)

            // Classified here, after the file exists — the classifier reads it back rather
            // than taking a buffer, and this queue is free to take its time.
            let labels = EventClassifier.shared.classify(url: url)

            // Transcription is slower and asynchronous, so the event is recorded first and
            // patched when the text arrives. A speech event with no transcript yet is still
            // a speech event you can listen to.
            if labels.contains(where: { $0.identifier.lowercased().contains("speech") }) {
                Task.detached(priority: .utility) {
                    guard let text = await Transcriber.shared.transcribe(url: url) else { return }
                    await MainActor.run { [weak self] in
                        guard let self, var s = self.session,
                              let i = s.events.firstIndex(where: { $0.index == index }) else { return }
                        s.events[i].transcript = text
                        self.session = s
                        self.persist()
                    }
                }
            }

            let record = NightSession.EventRecord(
                index: index, file: file,
                atMs: at.timeIntervalSince1970 * 1000,
                startS: startS, endS: endS,
                durationS: Double(faded.count) / Self.sampleRate,
                peakDb: peak,
                labels: labels.isEmpty ? nil : labels)
            Task { @MainActor [weak self] in
                self?.session?.events.append(record)
                self?.persist()
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.lastError = "write failed: \(error)"
                self?.mark("event write failed: \(error)")
            }
        }
    }

    // MARK: - Static helpers

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm"; return f
    }()
    /// Raised-cosine ramp at both edges, in place. Mirrors `fadeEdges` in `public/wav.js`.
    private nonisolated static func fadeEdges(_ s: inout [Float], rate: Double, ms: Double) {
        let n = min(Int(rate * ms / 1000), s.count / 2)
        guard n >= 1 else { return }
        for i in 0..<n {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n)))
            s[i] *= g
            s[s.count - 1 - i] *= g
        }
    }

    /// Used from `processing` when naming an event file, so it cannot be actor-isolated.
    private nonisolated static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; return f
    }()
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
