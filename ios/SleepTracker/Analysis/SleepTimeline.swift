import Foundation

/// What sound can and cannot say about sleep.
///
/// It **cannot** give sleep stages. REM, deep and light are defined by brain and eye
/// activity — EEG and EOG — and a microphone has no access to either. Wearables approximate
/// them from movement and heart-rate variability, and even those agree with a sleep lab only
/// moderately. Anything here labelled "deep sleep" would be invention.
///
/// It **can** do roughly what actigraphy does: tell moving from still. Sleep onset, the
/// final wake, and restlessness in between follow reasonably from when sounds happen. Worth
/// having, as long as every figure is presented as an estimate from sound rather than a
/// measurement of sleep.
///
/// The rules are pinned by `SleepTimelineTests`.
enum SleepTimeline {
    /// Five-minute epochs, the usual actigraphy resolution.
    static let epochSeconds = 300.0
    static let restlessEvents = 2
    static let awakeEvents = 5
    /// Consecutive calm epochs before sleep is called — 15 minutes of settling.
    static let onsetQuietEpochs = 3
    /// Consecutive active epochs at the end before it counts as having got up.
    static let wakeRunEpochs = 2

    enum State: String {
        case asleep, restless, awake
    }

    struct Epoch: Identifiable {
        var startS: Double
        var events: Int
        var state: State
        var id: Double { startS }
    }

    struct Estimate {
        var epochs: [Epoch] = []
        var onsetS: Double?
        var finalWakeS: Double?
        var asleepSeconds: Double = 0
        var inBedSeconds: Double = 0
        var efficiency: Double = 0
        var awakenings: Int = 0

        var settled: Bool { onsetS != nil }
    }

    static func estimate(for session: NightSession) -> Estimate {
        let total = max(0, session.wall)
        let epochs = classify(session, total: total)
        guard !epochs.isEmpty else { return Estimate() }

        guard let onset = findOnset(epochs),
              let finalWake = findFinalWake(epochs),
              finalWake > onset
        else {
            return Estimate(epochs: epochs, inBedSeconds: total)
        }

        let (asleepEpochs, awakenings) = tally(epochs, from: onset, to: finalWake)
        let inBed = Double(finalWake) * epochSeconds
        let asleep = Double(asleepEpochs) * epochSeconds

        return Estimate(
            epochs: epochs,
            onsetS: Double(onset) * epochSeconds,
            finalWakeS: inBed,
            asleepSeconds: asleep,
            inBedSeconds: inBed,
            efficiency: inBed > 0 ? asleep / inBed : 0,
            awakenings: awakenings
        )
    }

    /// Bucket the night and label each epoch by how much happened in it.
    private static func classify(_ session: NightSession, total: Double) -> [Epoch] {
        let count = Int(ceil(total / epochSeconds))
        guard count > 0 else { return [] }

        var epochs = (0 ..< count).map {
            Epoch(startS: Double($0) * epochSeconds, events: 0, state: .asleep)
        }
        var talking = [Bool](repeating: false, count: count)

        for event in session.events {
            let index = min(count - 1, Int(event.startS / epochSeconds))
            guard index >= 0 else { continue }
            epochs[index].events += 1
            // One sentence is not restlessness — people do not hold conversations asleep. Nor
            // is a sound you marked as being up.
            if event.kinds.contains(where: \.meansAwake) {
                talking[index] = true
            }
        }

        for index in epochs.indices {
            if talking[index] || epochs[index].events >= awakeEvents {
                epochs[index].state = .awake
            } else if epochs[index].events >= restlessEvents {
                epochs[index].state = .restless
            }
        }
        return epochs
    }

    /// Calm epochs, and how many separate times the night was interrupted.
    private static func tally(
        _ epochs: [Epoch],
        from onset: Int,
        to finalWake: Int
    ) -> (asleep: Int, awakenings: Int) {
        var asleep = 0
        var awakenings = 0
        var wasAwake = false
        for index in onset ..< finalWake {
            let awake = epochs[index].state == .awake
            if awake, !wasAwake {
                awakenings += 1
            }
            if !awake {
                asleep += 1
            }
            wasAwake = awake
        }
        return (asleep, awakenings)
    }

    /// First epoch followed by a sustained calm run — settling, not a momentary lull.
    private static func findOnset(_ epochs: [Epoch]) -> Int? {
        guard epochs.count >= onsetQuietEpochs else { return nil }
        for start in 0 ... (epochs.count - onsetQuietEpochs) {
            let settled = epochs[start ..< start + onsetQuietEpochs]
                .allSatisfy { $0.state != .awake }
            if settled {
                return start
            }
        }
        return nil
    }

    /// Just after the last epoch that was not awake.
    ///
    /// Deliberately the last one, not the last sustained activity: waking at 3am and
    /// sleeping four more hours is a wake in the middle of the night, not the end of it.
    private static func findFinalWake(_ epochs: [Epoch]) -> Int? {
        guard let lastAsleep = epochs.lastIndex(where: { $0.state != .awake }) else { return nil }
        // Trailing activity only counts as getting up if it is sustained; one stirring
        // epoch at the end is not morning.
        let trailing = epochs.count - 1 - lastAsleep
        return trailing >= wakeRunEpochs ? lastAsleep + 1 : epochs.count
    }
}
