import Foundation

/// Rolling window of recent audio, addressed by absolute sample index.
///
/// The gate only closes a close-hold after a sound ends, and events want pre-roll — so by
/// the time an event is known, its opening is already in the past. This keeps enough
/// history to cut it back out.
final class SampleRing {
    private var storage: [Float]
    private let capacity: Int
    private(set) var written = 0 // absolute index one past the newest sample

    init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    var oldest: Int {
        max(0, written - capacity)
    }

    func append(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0 ..< count {
            storage[(written + i) % capacity] = samples[i]
        }
        written += count
    }

    /// Samples in `[from, to)`, clamped to what is still retained. Returns an empty array if
    /// the range has already scrolled out — callers must treat that as "too late", never
    /// write it out as a file of zeroes that looks like a silent recording.
    func slice(from: Int, to: Int) -> [Float] {
        let lo = max(from, oldest)
        let hi = min(to, written)
        guard hi > lo else { return [] }
        return (lo ..< hi).map { storage[$0 % capacity] }
    }
}
