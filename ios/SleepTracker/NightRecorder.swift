import AVFoundation
import Foundation

/// Captures the night, gates it, and writes one WAV per event.
///
/// The two things that make this work where the web version could not:
///   * `UIBackgroundModes: audio` in Info.plist, so iOS keeps the session alive when the
///     screen locks. This is a plist declaration, not a signed entitlement — it works on a
///     free personal team.
///   * `.measurement` mode, which disables the input processing chain. The browser needed
///     echoCancellation/noiseSuppression/autoGainControl turned off for the same reason:
///     AGC renormalises levels so the noise floor is meaningless, and noise suppression
///     deletes exactly the quiet sounds the gate is hunting for.
@MainActor
final class NightRecorder: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let index: Int
        let at: Date
        let duration: TimeInterval
        let peakDB: Double
        let url: URL
    }

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var events: [Event] = []
    @Published private(set) var floorDB = -60.0
    @Published private(set) var levelDB = -100.0
    @Published private(set) var interruptions = 0
    @Published private(set) var lastError: String?

    static let sampleRate = 16_000.0      // SoundAnalysis and YAMNet both want 16 kHz mono
    private let ringSeconds = 120

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var gate: NoiseGate?
    private var ring: SampleRing?
    private var totalSamples = 0
    private var nightDir: URL?

    private let workFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: NightRecorder.sampleRate,
                                           channels: 1, interleaved: false)!

    // MARK: - Control

    func start() {
        guard !isRecording else { return }
        lastError = nil
        do {
            try configureSession()
            try makeNightDirectory()
            try startEngine()
            isRecording = true
            startedAt = Date()
        } catch {
            lastError = String(describing: error)
            stop()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .record (not .playAndRecord): nothing here plays, and the narrower category is
        // less likely to be interrupted by other audio on the device.
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setPreferredSampleRate(NightRecorder.sampleRate)
        try session.setActive(true)

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
                self?.handleInterruption(note)
            }
        // Media services can be reset out from under a long-running session; without this
        // the engine comes back silently dead and the night is lost with no gap recorded.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session, queue: .main) { [weak self] _ in
                self?.restartAfterReset()
            }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            interruptions += 1
        case .ended:
            // A phone call, an alarm, Siri. Resume rather than treating the night as over.
            try? AVAudioSession.sharedInstance().setActive(true)
            if isRecording, !engine.isRunning { try? startEngine() }
        @unknown default:
            break
        }
    }

    private func restartAfterReset() {
        guard isRecording else { return }
        interruptions += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? configureSession()
        try? startEngine()
    }

    // MARK: - Capture

    private func startEngine() throws {
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hwFormat, to: workFormat)

        if gate == nil {
            let g = NoiseGate(sampleRate: NightRecorder.sampleRate)
            g.onEvent = { [weak self] event in
                Task { @MainActor in self?.writeEvent(event) }
            }
            gate = g
            ring = SampleRing(capacity: Int(NightRecorder.sampleRate) * ringSeconds)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private nonisolated func handle(_ buffer: AVAudioPCMBuffer) {
        Task { @MainActor [weak self] in
            guard let self, let converter = self.converter,
                  let gate = self.gate, let ring = self.ring else { return }

            let ratio = self.workFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.workFormat,
                                             frameCapacity: capacity) else { return }

            var supplied = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, out.frameLength > 0,
                  let channel = out.floatChannelData?[0] else { return }

            let count = Int(out.frameLength)
            ring.append(channel, count: count)
            gate.process(channel, count: count, totalSamplesBefore: self.totalSamples)
            self.totalSamples += count

            self.floorDB = gate.floorDB
            self.levelDB = gate.read()
        }
    }

    // MARK: - Output

    private func makeNightDirectory() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm"
        let dir = docs.appendingPathComponent("nights/\(fmt.string(from: Date()))/events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        nightDir = dir
    }

    private func writeEvent(_ event: GateEvent) {
        guard let ring, let dir = nightDir, let started = startedAt else { return }
        let samples = ring.slice(from: event.startSample, to: event.endSample)
        // Empty means the audio scrolled out of the ring before we reached it. Recording it
        // as a file of zeroes would be worse than admitting it is gone.
        guard !samples.isEmpty else { return }

        let index = events.count + 1
        let at = started.addingTimeInterval(Double(event.startSample) / NightRecorder.sampleRate)
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        let url = dir.appendingPathComponent(String(format: "%04d-%@.wav", index, fmt.string(from: at)))

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: NightRecorder.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: workFormat,
                                             frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            try file.write(from: buf)

            events.append(Event(index: index, at: at,
                                duration: Double(samples.count) / NightRecorder.sampleRate,
                                peakDB: event.peakDB, url: url))
        } catch {
            lastError = "write failed: \(error)"
        }
    }
}
