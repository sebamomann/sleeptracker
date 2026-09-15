import Foundation

/// How far to lift a clip toward a comfortable listening level, from its recorded peak.
///
/// Sleep audio is quiet by nature: a snore recorded across a room peaks near -30 dBFS, and a
/// breath far below that, so left untouched a clip is barely audible even at full volume.
///
/// Shared by two different amplifiers for two different reasons: `EventPlayer` lifts what
/// you hear in-app through an EQ node, so the file on disk stays the true measurement.
/// `TrainingExport` writes an actually-amplified copy, because a clip dragged off the phone
/// to a Mac has no such EQ standing between it and your ears.
enum AudioBoost {
    /// Where a clip is lifted to. Short of 0 dBFS so a boosted peak has room and does not
    /// clip on the way out.
    static let targetDB = -6.0
    /// Past this, boosting mostly amplifies the room's own noise floor rather than the
    /// sound itself. Also where EQ gain tops out, for the in-app amplifier.
    static let maxBoostDB = 24.0

    /// dB of lift for a clip whose recorded peak was `peak`.
    static func gainDB(forPeak peak: Double) -> Double {
        guard peak > -100 else { return maxBoostDB }
        return min(maxBoostDB, max(0, targetDB - peak))
    }
}
