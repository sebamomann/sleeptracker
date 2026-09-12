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
        var at: Double          // epoch ms
        var what: String
        var id: String { "\(at)-\(what)" }
    }

    struct EventRecord: Codable, Hashable, Identifiable {
        var index: Int
        var file: String        // relative to the night's events/ directory
        var atMs: Double        // epoch ms
        var startS: Double      // offset into the night, in captured audio
        var endS: Double
        var durationS: Double
        var peakDb: Double
        /// Top labels from the on-device classifier, most confident first. Nil for events
        /// recorded before classification existed, or when the classifier is unavailable.
        var labels: [SoundLabel]?
        var topLabel: SoundLabel? { labels?.first }
        var id: Int { index }
        var at: Date { Date(timeIntervalSince1970: atMs / 1000) }
    }

    var v = 2
    var id: String              // also the directory name
    var t0: Double              // epoch ms
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
    var envelope: [[Double]] = []          // per second: [mean, max, p10] in dBFS
    var gaps: [CaptureHealth.Gap] = []
    var marks: [Mark] = []
    var events: [EventRecord] = []
    var interruptions = 0
    var droppedEvents = 0                  // audio that scrolled out of the ring
    /// Every label this device's classifier can produce, recorded once so the available set
    /// is documented rather than assumed.
    var knownLabels: [String]?
    /// Wall clock of the most recent audio callback. The only record of when capture
    /// stopped, if it stopped and never resumed.
    var lastFrameAtMs: Double?
}

// MARK: - Derived verdict

extension NightSession {
    /// The session's end has to come from outside the audio thread: the stop timestamp, or
    /// the last save. See `lastAliveAt`.
    var endAt: Date { endedAt ?? Date(timeIntervalSince1970: lastAliveAt / 1000) }
    var start: Date { Date(timeIntervalSince1970: t0 / 1000) }

    var wall: TimeInterval { max(0, endAt.timeIntervalSince(start)) }
    var audio: TimeInterval { audioSec }
    var dead: TimeInterval { max(0, wall - audio) }

    var realGaps: [CaptureHealth.Gap] { gaps.filter { $0.audioLostMs > CaptureHealth.lostMS } }
    var worstGapMs: Double { realGaps.map(\.audioLostMs).max() ?? 0 }

    var tooShort: Bool { wall <= 60 }
    var survived: Bool { !tooShort && dead < 30 }

    /// Capture that stopped and never came back leaves no gap record — there is no later
    /// callback to close one — so it is measured from the last frame to the end instead.
    var trailingDead: TimeInterval {
        guard let last = lastFrameAtMs else { return 0 }
        return max(0, endAt.timeIntervalSince1970 - last / 1000)
    }
    var diedAndStayedDead: Bool { trailingDead > 60 }

    var keptAudio: TimeInterval { events.reduce(0) { $0 + $1.durationS } }

    /// What the night was made of, by the classifier's best label, longest first.
    var byLabel: [(label: String, display: String, count: Int, seconds: Double)] {
        var agg: [String: (count: Int, seconds: Double, display: String)] = [:]
        for e in events {
            guard let l = e.topLabel else { continue }
            var cur = agg[l.identifier] ?? (0, 0, l.display)
            cur.count += 1
            cur.seconds += e.durationS
            agg[l.identifier] = cur
        }
        return agg.map { (label: $0.key, display: $0.value.display,
                          count: $0.value.count, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }

    var unlabelledEvents: [EventRecord] { events.filter { ($0.labels ?? []).isEmpty } }
    var keptFraction: Double { audio > 0 ? keptAudio / audio : 0 }

    /// How much of the session happened while the app was not in the foreground. This is the
    /// number the whole native detour was for.
    var backgroundedSpans: [(from: Date, to: Date)] {
        var spans: [(Date, Date)] = []
        var enteredAt: Date?
        for m in marks {
            let at = Date(timeIntervalSince1970: m.at / 1000)
            if m.what.hasPrefix("backgrounded") { enteredAt = at }
            if m.what.hasPrefix("foregrounded"), let from = enteredAt {
                spans.append((from, at)); enteredAt = nil
            }
        }
        if let from = enteredAt { spans.append((from, endAt)) }
        return spans
    }

    var backgroundSeconds: TimeInterval {
        backgroundedSpans.reduce(0) { $0 + $1.to.timeIntervalSince($1.from) }
    }

    /// Events captured while the app was backgrounded — the direct evidence.
    var backgroundEvents: [EventRecord] {
        let spans = backgroundedSpans
        return events.filter { e in spans.contains { e.at >= $0.from && e.at <= $0.to } }
    }
}
