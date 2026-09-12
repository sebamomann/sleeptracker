import Foundation

/// One second of loudness, in dBFS.
///
/// Was a three-member tuple passed between the gate, the session and the chart, which meant
/// every call site re-stated what `.0`, `.1` and `.2` meant — and the persisted form is a
/// bare `[Double]`, so nothing but convention kept the order straight.
struct EnvelopeSample: Equatable {
    /// Average level across the second.
    var mean: Double
    /// Loudest frame in the second — what the chart draws, so a one-second event in a quiet
    /// minute is still visible.
    var max: Double
    /// 10th percentile: the second's own quiet level, from which the noise floor is built.
    var p10: Double

    /// The stored form: `[mean, max, p10]`, rounded to whole dB. At one sample per second an
    /// eight-hour night is ~29k entries, and the extra precision is noise no view shows.
    var rounded: [Double] { [mean.rounded(), max.rounded(), p10.rounded()] }

    init(mean: Double, max: Double, p10: Double) {
        self.mean = mean
        self.max = max
        self.p10 = p10
    }

    /// Reads the stored form back, tolerating a short or empty row.
    init(stored: [Double]) {
        mean = stored.isEmpty ? -100 : stored[0]
        max = stored.count > 1 ? stored[1] : -100
        p10 = stored.count > 2 ? stored[2] : -100
    }
}

/// How much of a night one classifier label accounts for.
struct LabelTally: Identifiable {
    var label: String
    var display: String
    var count: Int
    var seconds: Double
    var id: String { label }
}
