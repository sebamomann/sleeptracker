import Foundation

/// What earned a place in the reel, and why.
struct Highlight: Identifiable {
    enum Reason {
        case spoken(String)         // transcript
        case notable(String)        // label that warrants attention
        case pause(Double)          // seconds of near-silence inside an episode
        case representative(String) // the clearest example of this kind of sound
        case loudest
    }

    let event: NightSession.EventRecord?
    let reason: Reason
    var id: String

    var headline: String {
        switch reason {
        case .spoken(let text): return text
        case .notable(let label): return label
        case .pause(let s): return "\(Int(s))s with no breathing sound"
        case .representative(let label): return label
        case .loudest: return "Loudest moment"
        }
    }

    var caption: String {
        switch reason {
        case .spoken: return "You said something"
        case .notable: return "Worth a listen"
        case .pause: return "Inside an ongoing episode"
        case .representative(let label): return "Clearest \(label.lowercased())"
        case .loudest: return "Peak of the night"
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
        "cry", "scream", "shout", "groan", "whimper", "hiccup",
    ]

    /// Labels that describe the ordinary background of a night and never count as notable.
    static let mundaneKeywords = ["snor", "breath", "silence", "speech", "background"]

    static func isNotable(_ event: NightSession.EventRecord) -> Bool {
        guard let id = event.topLabel?.identifier.lowercased() else { return false }
        if mundaneKeywords.contains(where: id.contains) { return false }
        return notableKeywords.contains(where: id.contains)
    }

    static func reel(for session: NightSession, limit: Int = 8) -> [Highlight] {
        var out: [Highlight] = []
        var usedLabels = Set<String>()
        var usedEvents = Set<Int>()

        func take(_ h: Highlight, event: NightSession.EventRecord?, label: String?) {
            out.append(h)
            if let e = event { usedEvents.insert(e.index) }
            if let l = label { usedLabels.insert(l) }
        }

        // 1. Anything you actually said, longest transcript first — the most specific thing
        //    the night can tell you.
        let spoken = session.events
            .filter { !($0.transcript ?? "").isEmpty }
            .sorted { ($0.transcript?.count ?? 0) > ($1.transcript?.count ?? 0) }
        for e in spoken.prefix(3) {
            take(Highlight(event: e, reason: .spoken(e.transcript!), id: "spoken-\(e.index)"),
                 event: e, label: e.topLabel?.identifier)
        }

        // 2. Sounds that warrant attention.
        let notable = session.events
            .filter { isNotable($0) && !usedEvents.contains($0.index) }
            .sorted { ($0.topLabel?.confidence ?? 0) > ($1.topLabel?.confidence ?? 0) }
        for e in notable.prefix(2) {
            take(Highlight(event: e, reason: .notable(e.topLabel?.display ?? "Unusual sound"),
                           id: "notable-\(e.index)"),
                 event: e, label: e.topLabel?.identifier)
        }

        // 3. Pauses inside an episode — no audio of their own, so they carry no event.
        for gap in (session.quietGaps ?? []).sorted(by: { $0.durationS > $1.durationS }).prefix(2) {
            out.append(Highlight(event: nil, reason: .pause(gap.durationS),
                                 id: "pause-\(Int(gap.startS))"))
        }

        // 4. One representative per remaining kind of sound. Rarer kinds first: a single
        //    door at 4am says more about the night than the 200th snore.
        let groups = Dictionary(grouping: session.events.filter { $0.topLabel != nil },
                                by: { $0.topLabel!.identifier })
        let byRarity = groups
            .filter { !usedLabels.contains($0.key) }
            .sorted { $0.value.count < $1.value.count }

        for (label, events) in byRarity {
            guard out.count < limit else { break }
            // Clearest example: confidence weighted by duration, so a confident three-second
            // clip beats a marginal twenty-second one but a long clear one wins outright.
            guard let best = events
                .filter({ !usedEvents.contains($0.index) })
                .max(by: { ($0.topLabel!.confidence * $0.durationS) < ($1.topLabel!.confidence * $1.durationS) })
            else { continue }
            take(Highlight(event: best,
                           reason: .representative(best.topLabel?.display ?? label),
                           id: "rep-\(best.index)"),
                 event: best, label: label)
        }

        // 5. If nothing was labelled at all, fall back to the loudest moment so the reel is
        //    never empty on a night that clearly recorded something.
        if out.isEmpty, let loudest = session.events.max(by: { $0.peakDb < $1.peakDb }) {
            out.append(Highlight(event: loudest, reason: .loudest, id: "loudest-\(loudest.index)"))
        }

        return Array(out.prefix(limit))
    }
}
