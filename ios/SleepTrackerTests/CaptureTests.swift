import Foundation
import Testing
@testable import SleepTracker

/// Whether capture kept running, judged from the sample counter — never from a timer.
struct CaptureHealthTests {
    private let rate = 16000.0

    /// Where a run of callbacks left off.
    private struct Clock {
        let health = CaptureHealth()
        var samples = 0
        var now = nightStart
    }

    /// Five seconds of healthy callbacks, every 200 ms.
    private func healthy() -> Clock {
        var clock = Clock()
        for _ in 0 ..< 25 {
            clock.samples += Int(rate * 0.2)
            clock.health.note(totalSamples: clock.samples, sampleRate: rate, now: clock.now)
            clock.now.addTimeInterval(0.2)
        }
        return clock
    }

    @Test func aSuspendedCaptureIsRealDeadTime() throws {
        var clock = healthy()
        clock.now.addTimeInterval(30)
        clock.samples += Int(rate * 0.2)
        clock.health.note(totalSamples: clock.samples, sampleRate: rate, now: clock.now)

        #expect(clock.health.realGaps.count == 1)
        let gap = try #require(clock.health.realGaps.first)
        #expect(abs(gap.audioLostMs - 30000) < 500)
    }

    @Test func aLateCallbackThatKeptUpIsNotDeadTime() {
        // The backlog arrives in one late callback: stalled, but no audio lost.
        var clock = healthy()
        clock.now.addTimeInterval(5)
        clock.samples += Int(rate * 5.2)
        clock.health.note(totalSamples: clock.samples, sampleRate: rate, now: clock.now)

        #expect(clock.health.gaps.count == 1, "the stall is still recorded")
        #expect(clock.health.realGaps.isEmpty, "but it is not a failure")
    }
}

/// The verdict on a stored night. A session's end must come from outside the audio thread,
/// or capture that died and never resumed reads as a short, healthy night.
struct NightVerdictTests {
    @Test func aNightThatRanToTheEndSurvived() {
        let night = makeSession()
        #expect(night.survived)
        #expect(night.dead < 1)
        #expect(!night.diedAndStayedDead)
    }

    @Test func captureThatDiesAndNeverResumesIsNotSurvived() {
        var night = makeSession()
        night.audioSec = 600
        night.lastFrameAtMs = night.t0 + 600_000

        #expect(!night.survived, "ten minutes of audio in an eight-hour night is not a pass")
        #expect(night.diedAndStayedDead)
        #expect(abs(night.wall - 8 * hour) < 1, "wall clock comes from the stop time")
        #expect(abs(night.dead - (8 * hour - 600)) < 1)
        #expect(abs(night.trailingDead - (8 * hour - 600)) < 1)
    }

    @Test func anInterruptedNightFallsBackToItsLastSave() {
        var night = makeSession()
        night.endedAt = nil
        night.ended = false
        night.lastAliveAt = night.t0 + 3 * hour * 1000
        night.audioSec = 600
        night.lastFrameAtMs = night.t0 + 600_000

        #expect(abs(night.wall - 3 * hour) < 1)
        #expect(!night.survived)
        #expect(night.diedAndStayedDead)
    }

    @Test func aShortNightIsFlaggedRatherThanJudged() {
        let night = makeSession(seconds: 30)
        #expect(night.tooShort)
        #expect(!night.survived)
    }

    @Test func gapsMidNightAreCountedWithoutImplyingDeath() {
        var night = makeSession()
        night.audioSec = 8 * hour - 40
        night.gaps = [
            .init(at: night.t0 + hour * 1000, ms: 40000, audioLostMs: 40000),
            .init(at: night.t0 + 2 * hour * 1000, ms: 800, audioLostMs: 0)
        ]
        #expect(night.realGaps.count == 1, "the 800 ms stall lost no audio")
        #expect(night.worstGapMs == 40000)
        #expect(!night.diedAndStayedDead, "it recovered")
        #expect(!night.survived, "40 s of lost audio is still a failure")
    }

    @Test func toleratesANightWithNoLastFrame() {
        var night = makeSession(seconds: 600)
        night.lastFrameAtMs = nil
        #expect(night.trailingDead == 0)
        #expect(!night.diedAndStayedDead)
    }

    @Test func lockingDuringTheListeningDelayCountsFromTheNightsStart() throws {
        var night = makeSession(seconds: hour)
        let before = night.t0 - 10 * 60 * 1000
        night.marks = [
            .init(at: before, what: "backgrounded"),
            .init(at: night.t0 + 30 * 60 * 1000, what: "foregrounded")
        ]
        let span = try #require(night.backgroundedSpans.first)
        #expect(span.from == night.startedAt)
        #expect(abs(night.backgroundSeconds - 30 * 60) < 1)
    }
}

/// The rolling window an event is cut back out of.
struct SampleRingTests {
    private func ramp(from start: Int, count: Int) -> [Float] {
        (0 ..< count).map { Float(start + $0) }
    }

    private func push(_ ring: SampleRing, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { ring.append($0.baseAddress!, count: $0.count) }
    }

    @Test func slicesAcrossChunkBoundaries() {
        let ring = SampleRing(capacity: 1000)
        push(ring, ramp(from: 0, count: 10))
        push(ring, ramp(from: 10, count: 10))
        push(ring, ramp(from: 20, count: 10))
        #expect(ring.slice(from: 5, to: 25) == ramp(from: 5, count: 20))
        #expect(ring.slice(from: 0, to: 30) == ramp(from: 0, count: 30))
        #expect(ring.written == 30)
    }

    @Test func retainsTheNewestWindowExactly() {
        let ring = SampleRing(capacity: 50)
        for chunk in 0 ..< 20 {
            push(ring, ramp(from: chunk * 10, count: 10))
        }
        #expect(ring.slice(from: 150, to: 200) == ramp(from: 150, count: 50))
        #expect(ring.oldest == 150)
    }

    @Test func aRangeThatScrolledAwayComesBackEmptyNotAsSilence() {
        let ring = SampleRing(capacity: 50)
        for chunk in 0 ..< 20 {
            push(ring, ramp(from: chunk * 10, count: 10))
        }
        #expect(ring.slice(from: 0, to: 40).isEmpty)
    }

    @Test func clampsARangePastTheNewestSample() {
        let ring = SampleRing(capacity: 1000)
        push(ring, ramp(from: 0, count: 10))
        #expect(ring.slice(from: 5, to: 999) == ramp(from: 5, count: 5))
    }

    @Test func anEmptyRingYieldsEmptySlices() {
        let ring = SampleRing(capacity: 100)
        #expect(ring.slice(from: 0, to: 10).isEmpty)
        #expect(ring.oldest == 0)
    }
}
