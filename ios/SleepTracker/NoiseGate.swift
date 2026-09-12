import Foundation

/// Port of `public/analysis.js`. The constants, the rolling noise floor and the hysteresis
/// are identical to the browser spike's, which is covered by the Node test suite — keep the
/// two in step when tuning.
struct GateConfig {
    var frameMS = 20.0
    var gateDB = 12.0           // open this far above the rolling floor
    var openMS = 150.0          // sustained, before an event opens
    var closeMS = 1500.0        // sustained, before it closes
    var floorWindowS = 60       // rolling window for the noise floor
    var floorWarmupS = 10       // ...before which the floor may fall but never rise
    var initialFloorDB = -60.0
    var preRollS = 2.0
    var postRollS = 1.0
    var maxEnvelopeSeconds = 14 * 3600   // hard cap on retained envelope
}

struct GateEvent {
    let startSample: Int
    let endSample: Int
    let peakDB: Double
}

final class NoiseGate {
    private let cfg: GateConfig
    private let sampleRate: Double
    private let framesPerSecond: Int
    private let samplesPerFrame: Int

    private(set) var floorDB: Double
    private(set) var envelope: [(mean: Double, max: Double, p10: Double)] = []
    private(set) var peakSinceRead = -100.0

    private var secondBuffer: [Double] = []
    private var floorHistory: [Double] = []
    private var frameIndex = 0
    private var accumulator = 0.0
    private var samplesInFrame = 0

    private var open = false
    private var aboveFrames = 0
    private var belowFrames = 0
    private var openedAtFrame = 0
    private var eventPeak = -100.0

    var threshold: Double { floorDB + cfg.gateDB }

    /// Emitted when an event closes. Sample indices are absolute and already padded with
    /// the pre/post roll, so the caller can slice them straight out of its ring.
    var onEvent: ((GateEvent) -> Void)?

    init(sampleRate: Double, config: GateConfig = GateConfig()) {
        self.cfg = config
        self.sampleRate = sampleRate
        self.samplesPerFrame = Int(sampleRate * config.frameMS / 1000.0)
        self.framesPerSecond = Int(1000.0 / config.frameMS)
        self.floorDB = config.initialFloorDB
    }

    func read(peak: Bool = true) -> Double {
        defer { if peak { peakSinceRead = -100.0 } }
        return peakSinceRead
    }

    func process(_ samples: UnsafePointer<Float>, count: Int, totalSamplesBefore: Int) {
        for i in 0..<count {
            let s = Double(samples[i])
            accumulator += s * s
            samplesInFrame += 1
            guard samplesInFrame >= samplesPerFrame else { continue }

            let rms = (accumulator / Double(samplesInFrame)).squareRoot()
            accumulator = 0
            samplesInFrame = 0
            frameIndex += 1

            let db = max(-100.0, min(0.0, 20.0 * log10(rms + 1e-12)))
            if db > peakSinceRead { peakSinceRead = db }
            secondBuffer.append(db)
            if secondBuffer.count >= framesPerSecond { rollSecond() }
            runGate(db, absoluteFrameEnd: totalSamplesBefore + i + 1)
        }
    }

    private func rollSecond() {
        let sorted = secondBuffer.sorted()
        let p10 = sorted[min(sorted.count - 1, sorted.count / 10)]
        if envelope.count < cfg.maxEnvelopeSeconds {
            envelope.append((secondBuffer.reduce(0, +) / Double(secondBuffer.count),
                             secondBuffer.max() ?? -100, p10))
        }

        floorHistory.append(p10)
        if floorHistory.count > cfg.floorWindowS { floorHistory.removeFirst() }

        if floorHistory.count >= cfg.floorWarmupS {
            let s = floorHistory.sorted()
            floorDB = s[s.count / 2]
        } else {
            // During warmup the floor may fall but never rise: a recorder started mid-snore
            // would otherwise take the snore as the room, lift the threshold above it, and
            // close the gate on the very event it opened for.
            floorDB = min(cfg.initialFloorDB, floorHistory.min() ?? cfg.initialFloorDB)
        }
        secondBuffer.removeAll(keepingCapacity: true)
    }

    private func runGate(_ db: Double, absoluteFrameEnd: Int) {
        let t = threshold
        if !open {
            aboveFrames = db > t ? aboveFrames + 1 : 0
            if Double(aboveFrames) * cfg.frameMS >= cfg.openMS {
                open = true
                belowFrames = 0
                openedAtFrame = frameIndex - aboveFrames
                eventPeak = db
            }
            return
        }

        if db > eventPeak { eventPeak = db }
        belowFrames = db < t ? belowFrames + 1 : 0
        guard Double(belowFrames) * cfg.frameMS >= cfg.closeMS else { return }

        let startFrame = openedAtFrame
        let endFrame = frameIndex - belowFrames
        let start = Int((Double(startFrame) * cfg.frameMS / 1000.0 - cfg.preRollS) * sampleRate)
        let end = Int((Double(endFrame) * cfg.frameMS / 1000.0 + cfg.postRollS) * sampleRate)
        onEvent?(GateEvent(startSample: max(0, start), endSample: end, peakDB: eventPeak))

        open = false
        aboveFrames = 0
        belowFrames = 0
        eventPeak = -100
    }
}
