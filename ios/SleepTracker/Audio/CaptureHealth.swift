import Foundation

/// Tracks whether capture actually kept running — the one thing this build exists to prove.
///
/// Port of the gap detector in `public/analysis.js`. Liveness is derived from the audio
/// tap's own sample counter, never from a timer: a suspended app's timers stop too, so a
/// timer-based heartbeat cannot tell "we were frozen" from "we stopped being scheduled".
/// Samples processed cannot be faked.
final class CaptureHealth {
    struct Gap: Codable, Hashable {
        let at: Double // epoch ms, start of the gap
        let ms: Double // wall-clock stall
        let audioLostMs: Double // ...of which this much audio never arrived
    }

    static let stallMS = 700.0
    static let lostMS = 300.0

    private(set) var gaps: [Gap] = []
    private(set) var audioSeconds = 0.0
    private(set) var lastFrameAt: Date?

    private var lastCallbackAt: Date?
    private var lastAudioSeconds = 0.0

    /// Call once per tap callback, with the running total of samples delivered so far.
    func note(totalSamples: Int, sampleRate: Double, now: Date = Date()) {
        let audioSec = Double(totalSamples) / sampleRate

        if let last = lastCallbackAt {
            let wallGap = now.timeIntervalSince(last) * 1000
            let audioGap = (audioSec - lastAudioSeconds) * 1000
            if wallGap > Self.stallMS {
                // A late callback whose sample counter kept up means the main thread was
                // busy but capture continued — harmless. One that fell behind means audio
                // genuinely stopped arriving. From the outside they look identical.
                gaps.append(Gap(
                    at: last.timeIntervalSince1970 * 1000,
                    ms: wallGap,
                    audioLostMs: max(0, wallGap - audioGap)
                ))
            }
        }

        lastCallbackAt = now
        lastAudioSeconds = audioSec
        audioSeconds = audioSec
        lastFrameAt = now
    }

    var realGaps: [Gap] {
        gaps.filter { $0.audioLostMs > Self.lostMS }
    }
}
