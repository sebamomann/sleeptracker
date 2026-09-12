import Foundation

/// Everything worth knowing about one night, in a shape that survives the app being killed.
/// Mirrors the browser spike's session JSON so the same reasoning applies to both.
struct NightSession: Codable, Identifiable {
    struct Device: Codable {
        var model: String
        var systemVersion: String
        var appVersion: String
    }

    struct Mark: Codable, Hashable, Identifiable {
        var at: Double // epoch ms
        var what: String
        var id: String {
            "\(at)-\(what)"
        }
    }

    struct QuietGap: Codable, Hashable, Identifiable {
        var startS: Double
        var endS: Double
        var durationS: Double
        var id: Double {
            startS
        }
    }

    struct EventRecord: Codable, Hashable, Identifiable {
        var index: Int
        var file: String // relative to the night's events/ directory
        var atMs: Double // epoch ms
        var startS: Double // offset into the night, in captured audio
        var endS: Double
        var durationS: Double
        var peakDb: Double
        /// Top labels from the on-device classifier, most confident first. Nil for events
        /// recorded before classification existed, or when the classifier is unavailable.
        var labels: [SoundLabel]?
        /// On-device transcript, for events the classifier called speech. Nil when nothing
        /// intelligible came back, which is common — sleep speech is often mumbled.
        var transcript: String?
        /// Optional rather than defaulted: synthesised Codable does not fall back to a
        /// property's default value for a missing key, it throws — so a non-optional Bool
        /// here would make every night recorded before starring existed unreadable.
        var starred: Bool?
        /// Separate from the star on purpose: a star keeps something because it is
        /// interesting, a flag keeps it because it is worrying. Collapsing them would make
        /// the favourites view unable to tell curiosity from concern.
        var flagged: Bool?
        /// A short note on either mark: "ask about this", "was dreaming about work".
        var note: String?

        var isStarred: Bool {
            starred == true
        }

        var isFlagged: Bool {
            flagged == true
        }

        var isMarked: Bool {
            isStarred || isFlagged
        }

        var topLabel: SoundLabel? {
            labels?.first
        }

        var isSpeech: Bool {
            (labels ?? []).contains { $0.identifier.lowercased().contains("speech") }
        }

        var id: Int {
            index
        }

        var at: Date {
            Date(timeIntervalSince1970: atMs / 1000)
        }
    }

    /// File-format version of the stored night.
    var version = 2
    var id: String // also the directory name
    var t0: Double // epoch ms
    var startedAt: Date
    var endedAt: Date?
    var ended = false
    /// A clock reading taken outside the audio thread on every save. Without it, a capture
    /// that dies and never resumes freezes every other counter with it, and differencing
    /// them reports a short, perfectly healthy night.
    var lastAliveAt: Double
    var device: Device
    var sampleRate: Double
    var audioSec: Double = 0
    var floorDb: Double = -60
    var thresholdDb: Double = -48
    var envelope: [[Double]] = [] // per second: [mean, max, p10] in dBFS
    var gaps: [CaptureHealth.Gap] = []
    var marks: [Mark] = []
    var events: [EventRecord] = []
    var interruptions = 0
    var droppedEvents = 0 // audio that scrolled out of the ring
    /// Every label this device's classifier can produce, recorded once so the available set
    /// is documented rather than assumed.
    var knownLabels: [String]?
    /// Near-silent stretches bracketed by sound. Computed at stop; see QuietGaps.
    var quietGaps: [QuietGap]?
    /// Wall clock of the most recent audio callback. The only record of when capture
    /// stopped, if it stopped and never resumed.
    var lastFrameAtMs: Double?
}
