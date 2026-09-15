import Foundation

/// The rolling noise floor, the hysteresis and the rules for what is worth a file. Pinned by
/// `NoiseGateTests`; a tuning change should move a test with it.
struct GateConfig {
    var frameMS = 20.0
    var gateDB = 15.0 // open this far above the rolling floor
    var openMS = 150.0 // sustained, before an event opens
    /// Sustained below threshold before the gate closes. Generous on purpose: breathing and
    /// snoring come in bursts with seconds of quiet between them, and a short hold chops one
    /// episode into a string of unlistenable fragments.
    var closeMS = 4000.0
    var floorWindowS = 60 // rolling window for the noise floor
    var floorWarmupS = 10 // ...before which the floor may fall but never rise
    var initialFloorDB = -60.0
    /// Two rules that exist because a real night produced 102 events and most were nothing.
    /// A relative threshold alone is not enough: in a very quiet room the floor sits so low
    /// that a rustle clears it, and with roll a 150 ms tick becomes a four-second file that
    /// sounds like silence.
    var minEventMS = 400.0 // the sound itself must last this long, roll excluded
    var minPeakDB = -52.0 // ...and be audible in absolute terms, not merely prominent
    /// A sound this far above `minPeakDB` is kept whatever its duration. Duration alone
    /// cannot tell a meaningless tick from a genuine sound that is simply brief — a fart, a
    /// single cough, a knock — and those are exactly the kind of sharp, loud, short sound
    /// this app exists to catch. The margin is well above the ~12 dB a typical kept event
    /// already clears (see `Calibration.peakMarginDB`), so this only fires for something
    /// distinctly louder than an ordinary night, not for every event that clears the floor.
    var veryLoudMarginDB = 20.0

    var preRollS = 4.0 // kept before the gate opened — events would start mid-snore
    /// Kept after it closed. May exceed `closeMS`: AnalysisPipeline defers the cut until
    /// the tail has actually been recorded, rather than letting the ring clamp it.
    var postRollS = 4.0
    var fadeMS = 40.0 // ramp at each edge, so a clip has no click at either end
    var maxEnvelopeSeconds = 14 * 3600 // hard cap on retained envelope
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
    private(set) var envelope: [EnvelopeSample] = []
    private(set) var peakSinceRead = -100.0
    /// Gate openings discarded as too short or too quiet.
    private(set) var rejected = 0

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

    var threshold: Double {
        floorDB + cfg.gateDB
    }

    /// Emitted when an event closes. Sample indices are absolute and already padded with
    /// the pre/post roll, so the caller can slice them straight out of its ring.
    var onEvent: ((GateEvent) -> Void)?

    init(sampleRate: Double, config: GateConfig = GateConfig()) {
        cfg = config
        self.sampleRate = sampleRate
        samplesPerFrame = Int(sampleRate * config.frameMS / 1000.0)
        framesPerSecond = Int(1000.0 / config.frameMS)
        floorDB = config.initialFloorDB
    }

    func read(peak: Bool = true) -> Double {
        defer {
            if peak {
                peakSinceRead = -100.0
            }
        }
        return peakSinceRead
    }

    func process(_ samples: UnsafePointer<Float>, count: Int, totalSamplesBefore: Int) {
        for i in 0 ..< count {
            let s = Double(samples[i])
            accumulator += s * s
            samplesInFrame += 1
            guard samplesInFrame >= samplesPerFrame else { continue }

            let rms = (accumulator / Double(samplesInFrame)).squareRoot()
            accumulator = 0
            samplesInFrame = 0
            frameIndex += 1

            let db = max(-100.0, min(0.0, 20.0 * log10(rms + 1e-12)))
            if db > peakSinceRead {
                peakSinceRead = db
            }
            secondBuffer.append(db)
            if secondBuffer.count >= framesPerSecond {
                rollSecond()
            }
            runGate(db, absoluteFrameEnd: totalSamplesBefore + i + 1)
        }
    }

    private func rollSecond() {
        let sorted = secondBuffer.sorted()
        let p10 = sorted[min(sorted.count - 1, sorted.count / 10)]
        if envelope.count < cfg.maxEnvelopeSeconds {
            envelope.append(EnvelopeSample(
                mean: secondBuffer.reduce(0, +) / Double(secondBuffer.count),
                max: secondBuffer.max() ?? -100,
                p10: p10
            ))
        }

        floorHistory.append(p10)
        if floorHistory.count > cfg.floorWindowS {
            floorHistory.removeFirst()
        }

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
        let openAbove = threshold
        if !open {
            aboveFrames = db > openAbove ? aboveFrames + 1 : 0
            if Double(aboveFrames) * cfg.frameMS >= cfg.openMS {
                open = true
                belowFrames = 0
                openedAtFrame = frameIndex - aboveFrames
                eventPeak = db
            }
            return
        }

        if db > eventPeak {
            eventPeak = db
        }
        belowFrames = db < openAbove ? belowFrames + 1 : 0
        guard Double(belowFrames) * cfg.frameMS >= cfg.closeMS else { return }

        let startFrame = openedAtFrame
        let endFrame = frameIndex - belowFrames
        let soundMS = Double(endFrame - startFrame) * cfg.frameMS

        let longAndAudible = soundMS >= cfg.minEventMS && eventPeak >= cfg.minPeakDB
        let veryLoud = eventPeak >= cfg.minPeakDB + cfg.veryLoudMarginDB
        if longAndAudible || veryLoud {
            let start = Int((Double(startFrame) * cfg.frameMS / 1000 - cfg.preRollS) * sampleRate)
            let end = Int((Double(endFrame) * cfg.frameMS / 1000 + cfg.postRollS) * sampleRate)
            onEvent?(GateEvent(startSample: max(0, start), endSample: end, peakDB: eventPeak))
        } else {
            // Counted rather than silently dropped: a night that rejects thousands means the
            // threshold is wrong, not that the room was busy.
            rejected += 1
        }

        open = false
        aboveFrames = 0
        belowFrames = 0
        eventPeak = -100
    }
}
