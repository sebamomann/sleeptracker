import Foundation
@testable import SleepTracker

/// 23:00 on a night in September, as a fixed point every fixture counts from.
let nightStart = Date(timeIntervalSince1970: 1_789_254_000)
let hour = 3600.0

/// A night of `seconds`, ended cleanly, with every second of audio captured unless a test
/// says otherwise.
func makeSession(
    id: String = "test",
    seconds: Double = 8 * hour,
    events: [NightSession.EventRecord] = []
) -> NightSession {
    let t0 = nightStart.timeIntervalSince1970 * 1000
    var session = NightSession(
        id: id,
        t0: t0,
        startedAt: nightStart,
        lastAliveAt: t0 + seconds * 1000,
        device: .init(model: "test", systemVersion: "0", appVersion: "0"),
        sampleRate: 16000
    )
    session.endedAt = nightStart.addingTimeInterval(seconds)
    session.ended = true
    session.audioSec = seconds
    session.lastFrameAtMs = t0 + seconds * 1000
    session.events = events
    return session
}

func makeEvent(
    index: Int = 1,
    startS: Double = 0,
    durationS: Double = 4,
    peakDb: Double = -30,
    labels: [SoundLabel]? = nil,
    kinds: [SoundKind]? = nil
) -> NightSession.EventRecord {
    var event = NightSession.EventRecord(
        index: index,
        file: "\(index).m4a",
        atMs: nightStart.timeIntervalSince1970 * 1000 + startS * 1000,
        startS: startS,
        endS: startS + durationS,
        durationS: durationS,
        peakDb: peakDb
    )
    event.labels = labels
    event.userKinds = kinds?.map(\.rawValue)
    return event
}

/// A `SessionStore` rooted in a fresh scratch directory, so a test can save, mutate and
/// delete nights without going near a real one, or another test's.
func makeScratchStore() -> SessionStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sleeptracker-tests-\(UUID().uuidString)", isDirectory: true)
    return SessionStore(root: root)
}

/// A placeholder clip on disk for `event`, so deletion has a real file to remove and
/// classification has a real (if silent-to-the-classifier) URL to open.
@discardableResult
func writeDummyClip(
    for event: NightSession.EventRecord,
    in sessionID: String,
    store: SessionStore
) throws -> URL {
    try store.prepare(id: sessionID)
    let url = store.url(forEvent: event, in: sessionID)
    try Data("not really audio".utf8).write(to: url)
    return url
}

/// Drives a `NoiseGate` with a level that varies over time — the shape of a night, without
/// needing one.
///
/// Runs at 1 kHz rather than a real capture rate: the gate works in 20 ms frames whatever the
/// rate, and a thousand samples a second keeps a ten-minute night fast in a debug build.
final class GateHarness {
    static let sampleRate = 1000.0

    let config: GateConfig
    let gate: NoiseGate
    private(set) var events: [GateEvent] = []
    private var total = 0

    init(config: GateConfig = GateConfig()) {
        self.config = config
        gate = NoiseGate(sampleRate: Self.sampleRate, config: config)
        gate.onEvent = { [weak self] event in self?.events.append(event) }
    }

    /// `seconds` of audio whose level at each moment is `level(time)` in dBFS.
    func run(seconds: Double, level: (Double) -> Double) {
        let frameSamples = Int(Self.sampleRate * config.frameMS / 1000)
        let frames = Int(seconds * 1000 / config.frameMS)
        var chunk: [Float] = []
        for frame in 0 ..< frames {
            let time = Double(frame) * config.frameMS / 1000
            let amplitude = Float(pow(10, level(time) / 20))
            chunk.append(contentsOf: repeatElement(amplitude, count: frameSamples))
            if chunk.count >= Int(Self.sampleRate) {
                feed(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        feed(chunk)
    }

    private func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { buffer in
            gate.process(buffer.baseAddress!, count: buffer.count, totalSamplesBefore: total)
        }
        total += samples.count
    }

    /// Where the sound itself began, pre-roll removed. Meaningless for an event near 0, where
    /// the roll is clamped.
    func soundStart(_ event: GateEvent) -> Double {
        Double(event.startSample) / Self.sampleRate + config.preRollS
    }

    /// Where the sound itself ended, post-roll removed.
    func soundEnd(_ event: GateEvent) -> Double {
        Double(event.endSample) / Self.sampleRate - config.postRollS
    }

    /// Seconds of audio the events would keep, roll included.
    var keptSeconds: Double {
        events.reduce(0) { $0 + Double($1.endSample - $1.startSample) / Self.sampleRate }
    }
}
