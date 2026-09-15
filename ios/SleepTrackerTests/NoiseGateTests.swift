import Foundation
import Testing
@testable import SleepTracker

/// The gate: noise floor, hysteresis, and the rules that decide what is worth a file.
struct NoiseGateTests {
    /// Room tone at -58 dB with a loud six-second burst every 45 seconds.
    private func burstyRoom(_ time: Double) -> Double {
        time.truncatingRemainder(dividingBy: 45) < 6 ? -30 : -58
    }

    @Test func floorTracksTheRoomNotTheEventsInIt() {
        let harness = GateHarness()
        harness.run(seconds: 600, level: burstyRoom)
        #expect(abs(harness.gate.floorDB - -58) <= 2)
        #expect(harness.gate.envelope.count == 600, "one envelope sample per second")
    }

    @Test func findsTheEventsAndGetsTheirBoundariesRight() throws {
        let harness = GateHarness()
        harness.run(seconds: 600, level: burstyRoom)
        #expect(harness.events.count == 14)

        let second = try #require(harness.events.dropFirst().first)
        #expect(harness.soundStart(second) == 45, "starts on the burst, not after the debounce")
        #expect(harness.soundEnd(second) == 51, "ends on the burst, not after the close hold")
        #expect(abs(second.peakDB - -30) <= 2)
    }

    @Test func aQuietNightProducesNoEvents() {
        let harness = GateHarness()
        harness.run(seconds: 300) { _ in -58 }
        #expect(harness.events.isEmpty)
        #expect(harness.gate.rejected == 0)
    }

    @Test func followsARisingFloorInsteadOfLatchingOpen() {
        // A fan kicks in halfway: a fixed threshold would fire from then on.
        let harness = GateHarness()
        harness.run(seconds: 600) { $0 < 300 ? -70 : -50 }
        #expect(harness.gate.floorDB > -55)
        #expect(harness.keptSeconds < 60, "a latched gate would keep ~300 s")
    }

    @Test func envelopeIsCapped() {
        var config = GateConfig()
        config.maxEnvelopeSeconds = 30
        let harness = GateHarness(config: config)
        harness.run(seconds: 60) { _ in -58 }
        #expect(harness.gate.envelope.count == 30)
    }

    @Test func aRecorderStartedMidSoundDoesNotCloseOnThatSound() throws {
        // The floor window starts empty. If a loud opening were taken as the room, the
        // threshold would rise above the sound in progress and truncate it.
        let harness = GateHarness()
        harness.run(seconds: 60) { $0 < 8 ? -26 : -58 }
        let first = try #require(harness.events.first)
        #expect(harness.soundEnd(first) > 6, "the sound ran 8 s from the start")
    }

    @Test func floorStillConvergesOnTheRoomOnceTheWindowFills() {
        let harness = GateHarness()
        harness.run(seconds: 300) { $0 < 8 ? -26 : -58 }
        #expect(abs(harness.gate.floorDB - -58) <= 2)
    }

    @Test func aThreeSecondPauseStaysInsideOneEvent() throws {
        let harness = GateHarness()
        harness.run(seconds: 60) { time in
            (time < 2 || (time >= 5 && time < 7)) ? -26 : -58
        }
        #expect(harness.events.count == 1)
        let event = try #require(harness.events.first)
        #expect(harness.soundEnd(event) >= 7)
    }

    @Test func aPauseLongerThanTheCloseHoldSeparatesEvents() {
        let harness = GateHarness()
        harness.run(seconds: 60) { time in
            (time < 2 || (time >= 12 && time < 14)) ? -26 : -58
        }
        #expect(harness.events.count == 2)
    }

    // MARK: - What is not an event

    @Test func aBriefTickIsDroppedAndCounted() {
        // 200 ms: the shape that made most of a real night's 102 events.
        let harness = GateHarness()
        harness.run(seconds: 60) { $0.truncatingRemainder(dividingBy: 10) < 0.2 ? -20 : -60 }
        #expect(harness.events.isEmpty)
        #expect(harness.gate.rejected > 0, "counted, so a bad threshold is visible")
    }

    @Test func aSustainedSoundOfTheSameLoudnessIsKept() {
        // Offset from 0, where the pre-roll is clamped and the sound's start unrecoverable.
        let harness = GateHarness()
        harness.run(seconds: 60) { ($0 + 10).truncatingRemainder(dividingBy: 20) < 3 ? -20 : -60 }
        #expect(harness.events.count >= 2)
        #expect(harness.events.allSatisfy { harness.soundEnd($0) - harness.soundStart($0) >= 0.4 })
    }

    @Test func aSoundThatNeverBecomesAudibleIsDroppedHoweverProminent() {
        // 20 dB over a -90 dB floor clears the relative rule; nothing at -70 dBFS is audible.
        let harness = GateHarness()
        harness.run(seconds: 60) { $0.truncatingRemainder(dividingBy: 20) < 3 ? -70 : -90 }
        #expect(harness.events.isEmpty)
        #expect(harness.gate.rejected > 0)
    }

    @Test func aRealSnoreClearsBothRules() {
        let harness = GateHarness()
        harness.run(seconds: 60) { $0.truncatingRemainder(dividingBy: 20) < 4 ? -26 : -58 }
        #expect(harness.events.count >= 2)
        #expect(harness.events.allSatisfy { $0.peakDB >= GateConfig().minPeakDB })
    }
}

/// The raised-cosine ramp that keeps a clip from clicking at either end.
struct FadeEdgesTests {
    @Test func rampsBothEndsToSilenceAndLeavesTheMiddleAlone() {
        let rate = 16000.0
        var samples = [Float](repeating: 1, count: Int(rate))
        EventWriter.fadeEdges(&samples, rate: rate, ms: 40)

        let ramp = 640
        #expect(abs(samples[0]) < 1e-6)
        #expect(abs(samples[samples.count - 1]) < 1e-6)
        #expect(samples[ramp / 2] > 0.3 && samples[ramp / 2] < 0.7)
        #expect(samples[samples.count / 2] == 1)
        #expect((1 ..< ramp).allSatisfy { samples[$0] >= samples[$0 - 1] }, "monotonic")
    }

    @Test func doesNotOverFadeAClipShorterThanTwoRamps() {
        var samples = [Float](repeating: 1, count: 100)
        EventWriter.fadeEdges(&samples, rate: 16000, ms: 40)
        #expect(abs(samples[0]) < 1e-6)
        #expect(samples.contains { $0 > 0.9 })
    }

    @Test func toleratesAClipTooShortToRamp() {
        var samples: [Float] = [1]
        EventWriter.fadeEdges(&samples, rate: 16000, ms: 40)
        #expect(samples == [1])
    }
}
