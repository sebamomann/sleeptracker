import Foundation

/// A stretch the gate decided is worth keeping, on its way to disk.
///
/// A parameter object rather than seven arguments: the writer took `samples`, `index`, `at`,
/// `startS`, `endS`, `peakDb` and `nightID`, which is a call site nobody can read and an
/// ordering mistake waiting to happen.
struct PendingEvent {
    let samples: [Float]
    let index: Int
    /// Wall-clock time of the first sample, including pre-roll.
    let at: Date
    /// Offsets into the night's captured audio.
    let startS: Double
    let endS: Double
    let peakDb: Double
    let nightID: String
}
