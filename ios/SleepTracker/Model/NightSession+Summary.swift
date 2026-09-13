import Foundation

// Everything derived from a stored night: the capture verdict, the aggregates the report
// shows, and the groupings the views render. Kept apart from the Codable declaration so the
// persisted shape is readable on its own — that file is the file format.

// MARK: - Derived verdict

extension NightSession {
    /// The session's end has to come from outside the audio thread: the stop timestamp, or
    /// the last save. See `lastAliveAt`.
    var endAt: Date {
        endedAt ?? Date(timeIntervalSince1970: lastAliveAt / 1000)
    }

    var start: Date {
        Date(timeIntervalSince1970: t0 / 1000)
    }

    var wall: TimeInterval {
        max(0, endAt.timeIntervalSince(start))
    }

    var audio: TimeInterval {
        audioSec
    }

    var dead: TimeInterval {
        max(0, wall - audio)
    }

    var realGaps: [CaptureHealth.Gap] {
        gaps.filter { $0.audioLostMs > CaptureHealth.lostMS }
    }

    var worstGapMs: Double {
        realGaps.map(\.audioLostMs).max() ?? 0
    }

    var tooShort: Bool {
        wall <= 60
    }

    var survived: Bool {
        !tooShort && dead < 30
    }

    /// Capture that stopped and never came back leaves no gap record — there is no later
    /// callback to close one — so it is measured from the last frame to the end instead.
    var trailingDead: TimeInterval {
        guard let last = lastFrameAtMs else { return 0 }
        return max(0, endAt.timeIntervalSince1970 - last / 1000)
    }

    var diedAndStayedDead: Bool {
        trailingDead > 60
    }

    var keptAudio: TimeInterval {
        events.reduce(0) { $0 + $1.durationS }
    }

    /// What the night was made of, by the classifier's best label, longest first.
    var byLabel: [LabelTally] {
        var tallies: [String: LabelTally] = [:]
        for event in events {
            let kind = event.kind
            var tally = tallies[kind.rawValue] ?? LabelTally(
                label: kind.rawValue, display: kind.display, count: 0, seconds: 0
            )
            tally.count += 1
            tally.seconds += event.durationS
            tallies[kind.rawValue] = tally
        }
        return tallies.values.sorted { lhs, rhs in
            lhs.seconds == rhs.seconds ? lhs.label < rhs.label : lhs.seconds > rhs.seconds
        }
    }

    var unlabelledEvents: [EventRecord] {
        events.filter { ($0.labels ?? []).isEmpty }
    }

    /// Speech events still waiting on a transcript.
    var untranscribedSpeech: [EventRecord] {
        events.filter { $0.isSpeech && $0.transcript == nil }
    }

    var notableEvents: [EventRecord] {
        events.filter(Highlights.isNotable)
    }

    var starredEvents: [EventRecord] {
        events.filter(\.isStarred)
    }

    var flaggedEvents: [EventRecord] {
        events.filter(\.isFlagged)
    }

    /// Events corrected by ear — the labelled set a model of your own would train on.
    var taughtEvents: [EventRecord] {
        events.filter { $0.userKind != nil }
    }

    var markedEvents: [EventRecord] {
        events.filter(\.isMarked)
    }

    /// Total time spent on anything the classifier called snoring.
    var snoringSeconds: Double {
        events.filter { $0.kind == .snoring }.reduce(0) { $0 + $1.durationS }
    }

    /// The night in hour-sized pieces — answers "when was it bad", which a flat event list
    /// cannot. Loudness alone would be dominated by one door slam, so this carries both how
    /// much happened and how loud it got.
    struct HourBucket: Identifiable {
        var start: Date
        var events: Int
        var seconds: Double
        var peakDb: Double
        var id: Date {
            start
        }
    }

    var byHour: [HourBucket] {
        guard wall > 0 else { return [] }
        let hours = max(1, Int(ceil(wall / 3600)))
        return (0 ..< hours).map { h in
            let from = Double(h) * 3600, to = from + 3600
            let inBucket = events.filter { $0.startS >= from && $0.startS < to }
            return HourBucket(
                start: start.addingTimeInterval(from),
                events: inBucket.count,
                seconds: inBucket.reduce(0) { $0 + $1.durationS },
                peakDb: inBucket.map(\.peakDb).max() ?? -100
            )
        }
    }

    var keptFraction: Double {
        audio > 0 ? keptAudio / audio : 0
    }

    /// How much of the session happened while the app was not in the foreground. This is the
    /// number the whole native detour was for.
    var backgroundedSpans: [(from: Date, to: Date)] {
        var spans: [(Date, Date)] = []
        var enteredAt: Date?
        for mark in marks {
            let at = Date(timeIntervalSince1970: mark.at / 1000)
            if mark.what.hasPrefix("backgrounded") {
                enteredAt = at
            }
            if mark.what.hasPrefix("foregrounded"), let from = enteredAt {
                spans.append((from, at))
                enteredAt = nil
            }
        }
        if let from = enteredAt {
            spans.append((from, endAt))
        }
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
