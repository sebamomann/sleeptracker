import Foundation
import Testing
@testable import SleepTracker

/// Pauses inside an episode — and, just as important, everything that is not one.
struct QuietGapsTests {
    /// An envelope at -25 dB inside `loud` ranges and -60 dB everywhere else.
    private func night(seconds: Int, loud: [Range<Int>]) -> NightSession {
        var session = makeSession(seconds: Double(seconds))
        session.floorDb = -61
        session.envelope = (0 ..< seconds).map { second in
            loud.contains { $0.contains(second) } ? [-30, -25, -32] : [-60, -59, -61]
        }
        session.events = loud.enumerated().map { index, range in
            makeEvent(
                index: index + 1,
                startS: Double(range.lowerBound),
                durationS: Double(range.count)
            )
        }
        return session
    }

    @Test func aPauseInsideAnOngoingEpisodeIsFlagged() throws {
        let gaps = QuietGaps.find(in: night(seconds: 120, loud: [0 ..< 20, 35 ..< 55]))
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        #expect(gap.startS == 20)
        #expect(gap.durationS == 15)
    }

    @Test func aQuietNightHasNoGaps() {
        #expect(QuietGaps.find(in: night(seconds: 600, loud: [])).isEmpty)
    }

    @Test func silenceAfterTheLastSoundIsNotAPause() {
        #expect(QuietGaps.find(in: night(seconds: 200, loud: [0 ..< 20])).isEmpty)
    }

    @Test func anOrdinaryBreathIsTooShortToFlag() {
        #expect(QuietGaps.find(in: night(seconds: 120, loud: [0 ..< 20, 25 ..< 45])).isEmpty)
    }

    @Test func aLongQuietStretchBetweenEpisodesIsNotAPause() {
        // Adjacency alone cannot reject 100 s of quiet between two events; the upper bound does.
        #expect(QuietGaps.find(in: night(seconds: 260, loud: [0 ..< 20, 120 ..< 140])).isEmpty)
    }

    @Test func aPauseAtTheEdgeOfPlausibleIsStillReported() throws {
        let gaps = QuietGaps.find(in: night(seconds: 200, loud: [0 ..< 20, 100 ..< 120]))
        #expect(gaps.count == 1)
        #expect(try #require(gaps.first).durationS == 80)
    }

    @Test func severalPausesInOneEpisodeAreAllFound() {
        let gaps = QuietGaps.find(
            in: night(seconds: 200, loud: [0 ..< 10, 25 ..< 35, 50 ..< 60, 75 ..< 85])
        )
        #expect(gaps.map(\.durationS) == [15, 15, 15])
    }

    @Test func toleratesAnEmptyNight() {
        #expect(QuietGaps.find(in: makeSession(seconds: 0)).isEmpty)
    }
}

/// The thresholds the app learns: toward the target rate, bounded, and converging.
struct CalibrationTests {
    private typealias Night = Calibration.NightStat

    private func night(_ events: Int, hours: Double = 8, peak: Double = -30) -> Night {
        Night(hours: hours, events: events, medianPeakDb: peak)
    }

    private func calibrate(
        _ history: [Night],
        gate: Double,
        minPeak: Double
    ) -> Calibration.State {
        var state = Calibration.State()
        state.gateDb = gate
        state.minPeakDb = minPeak
        state.history = history
        Calibration.apply(to: &state)
        return state
    }

    @Test func tooManyEventsListensLessClosely() {
        // The real complaint: 102 events in eight hours against a target of 4 an hour.
        let out = calibrate([night(102)], gate: 15, minPeak: -52)
        #expect(out.gateDb > 15)
        #expect(out.why.contains("listening less closely"))
    }

    @Test func tooFewEventsListensMoreClosely() {
        let out = calibrate([night(4)], gate: 20, minPeak: -40)
        #expect(out.gateDb < 20)
        #expect(out.why.contains("listening more closely"))
    }

    @Test func aNightOnTargetHoldsStill() {
        let out = calibrate([night(32)], gate: 15, minPeak: -45)
        #expect(out.gateDb == 15)
        #expect(out.why.contains("holding"))
    }

    @Test func oneNightCannotSwingTheGateWideOpen() {
        let out = calibrate([night(4000)], gate: 15, minPeak: -45)
        #expect(out.gateDb <= 15 + Calibration.maxStepDB)
    }

    @Test func convergesOnTheTargetInsteadOfOscillating() {
        // Every extra dB of gate halves the events.
        var gate = 12.0
        var events = 102
        for _ in 0 ..< 12 {
            let next = calibrate([night(events)], gate: gate, minPeak: -45)
            events = max(1, Int((Double(events) / pow(2, next.gateDb - gate)).rounded()))
            gate = next.gateDb
        }
        let rate = Double(events) / 8
        #expect(abs(rate - Calibration.State().targetPerHour) < 2, "settled at \(rate)/h")
        #expect(Calibration.gateRange.contains(gate))
    }

    @Test func theAbsoluteFloorFollowsTheRoom() {
        // A phone on the pillow hears everything louder than one across the room.
        let near = calibrate([night(32, peak: -20)], gate: 15, minPeak: -52)
        let far = calibrate([night(32, peak: -44)], gate: 15, minPeak: -52)
        #expect(near.minPeakDb == -32)
        #expect(far.minPeakDb == -56)
    }

    @Test func shortNightsAreNotEvidence() {
        let out = calibrate([night(60, hours: 0.1)], gate: 15, minPeak: -52)
        #expect(out.nights == 0)
        #expect(out.gateDb == 15)
        #expect(out.why.contains("No nights yet"))
    }

    @Test func thresholdsStayInBoundsHoweverExtremeTheHistory() {
        var gate = 15.0
        for _ in 0 ..< 30 {
            gate = calibrate([night(100_000)], gate: gate, minPeak: -52).gateDb
        }
        #expect(gate == Calibration.gateRange.upperBound)
        for _ in 0 ..< 30 {
            gate = calibrate([night(0)], gate: gate, minPeak: -52).gateDb
        }
        #expect(gate == Calibration.gateRange.lowerBound)
    }

    @Test func aNightReducesToWhatCalibrationNeeds() {
        let session = makeSession(events: [-20, -30, -40].enumerated().map {
            makeEvent(index: $0.offset + 1, peakDb: $0.element)
        })
        let stat = Calibration.stat(of: session)
        #expect(stat.hours == 8)
        #expect(stat.events == 3)
        #expect(stat.medianPeakDb == -30)
    }
}

/// Sleep, inferred from when sounds happen — and nothing more than that.
struct SleepTimelineTests {
    /// Eight events per five-minute epoch between two minutes of the night.
    private func busy(from: Int, to: Int, kinds: [SoundKind]? = nil) -> [NightSession.EventRecord] {
        var events: [NightSession.EventRecord] = []
        for minute in stride(from: from, to: to, by: 5) {
            for offset in 0 ..< 8 {
                events.append(makeEvent(
                    index: events.count + 1,
                    startS: Double(minute * 60 + offset),
                    kinds: kinds
                ))
            }
        }
        return events
    }

    private func estimate(_ events: [NightSession.EventRecord]) -> SleepTimeline.Estimate {
        SleepTimeline.estimate(for: makeSession(events: events))
    }

    @Test func aQuietNightIsAsleepAlmostAllOfIt() {
        let out = estimate([])
        #expect(out.onsetS == 0)
        #expect(out.efficiency > 0.95)
        #expect(out.awakenings == 0)
    }

    @Test func timeSpentSettlingIsNotSleep() {
        let out = estimate(busy(from: 0, to: 30))
        #expect(out.onsetS == 1800.0)
        #expect(out.asleepSeconds == 7.5 * hour)
    }

    @Test func gettingUpAtTheEndEndsTheNightThere() {
        let out = estimate(busy(from: 450, to: 480))
        #expect(out.finalWakeS == 27000.0)
        #expect(out.inBedSeconds < 8 * hour)
    }

    @Test func wakingInTheMiddleIsCounted() {
        let out = estimate(busy(from: 180, to: 200))
        #expect(out.awakenings == 1)
        #expect(out.efficiency < 0.98)
        #expect(out.efficiency > 0.8, "one wake should not wreck the night")
    }

    @Test func talkingMeansAwakeHoweverLittle() {
        let moved = estimate([makeEvent(startS: hour, kinds: [.movement])])
        let spoke = estimate([makeEvent(startS: hour, kinds: [.talking])])
        #expect(moved.awakenings == 0)
        #expect(spoke.awakenings == 1)
    }

    @Test func talkingHeardByTheClassifierCountsToo() {
        let spoke = estimate([makeEvent(
            startS: hour,
            labels: [SoundLabel(identifier: "speech", confidence: 0.9)]
        )])
        #expect(spoke.awakenings == 1)
    }

    @Test func talkingAmongOtherSoundsStillMeansAwake() {
        let mixed = estimate([makeEvent(startS: hour, kinds: [.movement, .talking])])
        let none = estimate([makeEvent(startS: hour, kinds: [.farting, .breathing])])
        #expect(mixed.awakenings == 1)
        #expect(none.awakenings == 0)
    }

    @Test func aSoundMarkedAwakeMeansAwake() {
        #expect(estimate([makeEvent(startS: hour, kinds: [.awake])]).awakenings == 1)
    }

    @Test func aBriefStirIsNotGettingUp() {
        #expect(estimate(busy(from: 475, to: 480)).finalWakeS == 8 * hour)
    }

    @Test func aNightThatNeverSettlesReportsNoSleep() {
        let out = estimate(busy(from: 0, to: 480))
        #expect(out.onsetS == nil)
        #expect(out.asleepSeconds == 0)
        #expect(out.efficiency == 0)
    }

    @Test func anEmptyRecordingProducesZeroes() {
        let out = SleepTimeline.estimate(for: makeSession(seconds: 0))
        #expect(out.epochs.isEmpty)
        #expect(out.efficiency == 0)
        #expect(out.asleepSeconds == 0)
    }
}
