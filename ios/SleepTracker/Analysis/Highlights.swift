import Foundation

/// What earned a place in the reel, and why.
struct Highlight: Identifiable {
    enum Reason {
        case spoken(String) // transcript
        case notable(String) // label that warrants attention
        case pause(Double) // seconds of near-silence inside an episode
        case representative(String) // the clearest example of this kind of sound
        case loudest
    }

    let event: NightSession.EventRecord?
    let reason: Reason
    var id: String

    var headline: String {
        switch reason {
        case let .spoken(text): text
        case let .notable(label): label
        case let .pause(s): "\(Int(s))s with no breathing sound"
        case let .representative(label): label
        case .loudest: "Loudest moment"
        }
    }

    var caption: String {
        switch reason {
        case .spoken: "You said something"
        case .notable: "Worth a listen"
        case .pause: "Inside an ongoing episode"
        case let .representative(label): "Clearest \(label.lowercased())"
        case .loudest: "Peak of the night"
        }
    }
}

/// Builds the reel, variety first.
///
/// A snoring night is almost entirely snoring, so ranking by loudness or count produces a
/// list of near-identical snores. Instead each *kind* of sound contributes its clearest
/// example, with speech and anything notable promoted to the top — the reel is a summary of
/// the night, not its top ten decibels.
enum Highlights {
    /// Substring matches rather than exact labels: the classifier's vocabulary varies by iOS
    /// version, and matching "cough" catches "coughing" and "cough_cough" alike.
    static let notableKeywords = [
        "cough", "gasp", "chok", "wheez", "sneez", "snort", "gag",
        "cry", "scream", "shout", "groan", "whimper", "hiccup"
    ]

    /// Labels that describe the ordinary background of a night and never count as notable.
    static let mundaneKeywords = ["snor", "breath", "silence", "speech", "background"]

    static func isNotable(_ event: NightSession.EventRecord) -> Bool {
        guard let id = event.topLabel?.identifier.lowercased() else { return false }
        if mundaneKeywords.contains(where: id.contains) {
            return false
        }
        return notableKeywords.contains(where: id.contains)
    }

    static func reel(for session: NightSession, limit: Int = 8) -> [Highlight] {
        var builder = Builder(limit: limit)
        builder.addSpoken(from: session)
        builder.addNotable(from: session)
        builder.addPauses(from: session)
        builder.addRepresentatives(from: session)
        builder.addFallback(from: session)
        return Array(builder.reel.prefix(limit))
    }
}

/// Assembles the reel one pass at a time, remembering what each pass already used.
///
/// The passes were one long function; as separate steps the priority order is legible and
/// each rule can be read without holding the others in mind.
private struct Builder {
    let limit: Int
    var reel: [Highlight] = []

    init(limit: Int) {
        self.limit = limit
    }

    private var usedLabels: Set<String> = []
    private var usedEvents: Set<Int> = []

    // Every ordering below breaks ties on the event index. Swift's sort is not stable, so a
    // comparison on one key alone lets equal elements swap places each time the reel is
    // rebuilt — and it is rebuilt on every render, including when playback starts. That is
    // what made rows jump around while they were playing.

    private func longerTranscript(
        _ lhs: NightSession.EventRecord,
        _ rhs: NightSession.EventRecord
    ) -> Bool {
        let left = lhs.transcript?.count ?? 0
        let right = rhs.transcript?.count ?? 0
        return left == right ? lhs.index < rhs.index : left > right
    }

    private func moreConfident(
        _ lhs: NightSession.EventRecord,
        _ rhs: NightSession.EventRecord
    ) -> Bool {
        let left = lhs.topLabel?.confidence ?? 0
        let right = rhs.topLabel?.confidence ?? 0
        return left == right ? lhs.index < rhs.index : left > right
    }

    /// Ascending by clarity — confidence weighted by duration, so a confident three-second
    /// clip beats a marginal twenty-second one but a long clear one wins outright. Written
    /// ascending so `max(by:)` can use it, with ties resolved on index so the maximum is the
    /// same element on every rebuild.
    private func lessClear(
        _ lhs: NightSession.EventRecord,
        _ rhs: NightSession.EventRecord
    ) -> Bool {
        let left = (lhs.topLabel?.confidence ?? 0) * lhs.durationS
        let right = (rhs.topLabel?.confidence ?? 0) * rhs.durationS
        return left == right ? lhs.index > rhs.index : left < right
    }

    private mutating func take(
        _ highlight: Highlight,
        event: NightSession.EventRecord?,
        label: String?
    ) {
        reel.append(highlight)
        if let event {
            usedEvents.insert(event.index)
        }
        if let label {
            usedLabels.insert(label)
        }
    }

    /// Anything you actually said, longest transcript first — the most specific thing the
    /// night can tell you.
    mutating func addSpoken(from session: NightSession) {
        let spoken = session.events
            .filter { !($0.transcript ?? "").isEmpty }
            .sorted { longerTranscript($0, $1) }
        for event in spoken.prefix(3) {
            take(
                Highlight(
                    event: event,
                    reason: .spoken(event.transcript ?? ""),
                    id: "spoken-\(event.index)"
                ),
                event: event,
                label: event.topLabel?.identifier
            )
        }
    }

    /// Sounds that warrant attention.
    mutating func addNotable(from session: NightSession) {
        let notable = session.events
            .filter { Highlights.isNotable($0) && !usedEvents.contains($0.index) }
            .sorted { moreConfident($0, $1) }
        for event in notable.prefix(2) {
            take(
                Highlight(
                    event: event,
                    reason: .notable(event.kind.display),
                    id: "notable-\(event.index)"
                ),
                event: event,
                label: event.topLabel?.identifier
            )
        }
    }

    /// Pauses inside an episode. These have no audio of their own, so they carry no event.
    mutating func addPauses(from session: NightSession) {
        let longest = (session.quietGaps ?? []).sorted { lhs, rhs in
            lhs.durationS == rhs.durationS ? lhs.startS < rhs.startS
                : lhs.durationS > rhs.durationS
        }
        for gap in longest.prefix(2) {
            reel.append(Highlight(
                event: nil,
                reason: .pause(gap.durationS),
                id: "pause-\(Int(gap.startS))"
            ))
        }
    }

    /// One representative per remaining kind of sound, rarer kinds first: a single door at
    /// 4am says more about the night than the 200th snore.
    mutating func addRepresentatives(from session: NightSession) {
        let groups = Dictionary(
            grouping: session.events.filter { $0.topLabel != nil },
            by: { $0.topLabel?.identifier ?? "" }
        )
        let byRarity = groups
            .filter { !usedLabels.contains($0.key) }
            .sorted { lhs, rhs in
                // Dictionary order is arbitrary and the sort is unstable, so count alone
                // left same-sized groups to land in a different order every time.
                lhs.value.count == rhs.value.count ? lhs.key < rhs.key
                    : lhs.value.count < rhs.value.count
            }

        for (label, events) in byRarity {
            guard reel.count < limit else { return }
            // Clearest example: confidence weighted by duration, so a confident three-second
            // clip beats a marginal twenty-second one, but a long clear one wins outright.
            let best = events
                .filter { !usedEvents.contains($0.index) }
                .max(by: lessClear)
            guard let best else { continue }
            take(
                Highlight(
                    event: best,
                    reason: .representative(best.kind.display),
                    id: "rep-\(best.index)"
                ),
                event: best,
                label: label
            )
        }
    }

    /// If nothing was labelled at all, the loudest moment keeps the reel from being empty on
    /// a night that clearly recorded something.
    mutating func addFallback(from session: NightSession) {
        let loudest = session.events.max { lhs, rhs in
            lhs.peakDb == rhs.peakDb ? lhs.index > rhs.index : lhs.peakDb < rhs.peakDb
        }
        guard reel.isEmpty, let loudest else { return }
        reel.append(Highlight(event: loudest, reason: .loudest, id: "loudest-\(loudest.index)"))
    }
}
