import Testing
@testable import SleepTracker

/// The lift shared by in-app playback (an EQ, non-destructive) and training export (an
/// actual re-encode) — see `AudioBoost`.
struct AudioBoostTests {
    @Test func liftsAQuietClipTowardTheTarget() {
        // -20 dBFS lifted by 14 dB lands exactly on the -6 dBFS target.
        #expect(AudioBoost.gainDB(forPeak: -20) == 14)
    }

    @Test func neverBoostsPastTheCeiling() {
        // A very quiet clip would otherwise ask for more lift than is usable — past this
        // point boosting mostly amplifies the room's own noise floor.
        #expect(AudioBoost.gainDB(forPeak: -50) == AudioBoost.maxBoostDB)
    }

    @Test func aSilentSeemingClipStillGetsTheCeilingNotInfinity() {
        #expect(AudioBoost.gainDB(forPeak: -100) == AudioBoost.maxBoostDB)
    }

    @Test func neverPushesAnAlreadyLoudClipHarder() {
        // A clip already past the target needs no lift, and never a negative one.
        #expect(AudioBoost.gainDB(forPeak: -3) == 0)
        #expect(AudioBoost.gainDB(forPeak: 0) == 0)
    }

    @Test func aClipRightAtTheTargetNeedsNoLift() {
        #expect(AudioBoost.gainDB(forPeak: AudioBoost.targetDB) == 0)
    }
}
