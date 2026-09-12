import AVFoundation
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
        persist()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        processing.sync {
            converter = AVAudioConverter(from: hw, to: work)
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

        var samples: [Float] = []
        processing.sync {
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
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        }
        guard !samples.isEmpty else { return }
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
        let file = String(format: "%04d-%@.wav", index, Self.timeFormatter.string(from: at))
        let url = SessionStore.shared.eventsDirectory(for: nightID).appendingPathComponent(file)

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let audioFile = try AVAudioFile(forWriting: url, settings: settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: workFormat,
                                             frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buf.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            try audioFile.write(from: buf)

            let record = NightSession.EventRecord(
                index: index, file: file,
                atMs: at.timeIntervalSince1970 * 1000,
                startS: Double(event.startSample) / Self.sampleRate,
                endS: Double(event.endSample) / Self.sampleRate,
                durationS: Double(samples.count) / Self.sampleRate,
                peakDb: event.peakDB)
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
