import Foundation

/// Whether an event is worth keeping, judged after the fact.
///
/// The gate now rejects ticks and inaudible sounds as they happen, but nights recorded
/// before that still hold them — one real night produced 102 events, most of them nothing,
/// and most of those labelled `music`, which is what this classifier reaches for when a clip
/// carries too little information to identify.
///
/// Nothing here deletes anything by itself. It only answers "does this look like nothing",
/// and the count is always shown before any file is removed.
enum Relevance {
    /// Below this a clip is inaudible on a phone speaker, whatever it contains.
    static let inaudibleDB = -48.0
    /// A top label this unsure means the classifier recognised nothing.
    static let unsureBelow = 0.30
    /// A catch-all label has to be this confident before it counts as an answer.
    static let vagueNeeds = 0.65

    /// What the classifier reaches for when it does not know. On a bedroom recording these
    /// nearly always mean "nothing happened".
    static let vagueLabels = [
        "music", "silence", "noise", "static", "hum", "inside", "environment",
        "background", "vehicle", "wind", "rustl"
    ]

    /// Sounds the app exists to catch. Kept even when the classifier is hesitant, because a
    /// missed snore costs more than a kept rustle.
    static let alwaysKeep = [
        "snor", "speech", "cough", "breath", "gasp", "chok", "sneez", "sniff"
    ]

    static func looksLikeNothing(_ event: NightSession.EventRecord) -> Bool {
        // Never discard something deliberately kept, or something with words in it.
        if event.isMarked {
            return false
        }
        if !(event.transcript ?? "").isEmpty {
            return false
        }
        if (event.labels ?? []).contains(where: { label in
            alwaysKeep.contains(where: label.identifier.lowercased().contains)
                && label.confidence >= 0.25
        }) {
            return false
        }

        if event.peakDb < inaudibleDB {
            return true
        }
        guard let top = event.topLabel else { return true }
        if top.confidence < unsureBelow {
            return true
        }
        if isVague(top.identifier), top.confidence < vagueNeeds {
            return true
        }
        return false
    }

    static func isVague(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        return vagueLabels.contains(where: lowered.contains)
    }

    /// Why, in plain terms, for the confirmation.
    static func reason(_ event: NightSession.EventRecord) -> String {
        if event.peakDb < inaudibleDB {
            return "too quiet to hear"
        }
        guard let top = event.topLabel else { return "not labelled" }
        if top.confidence < unsureBelow {
            return "unrecognised"
        }
        if isVague(top.identifier) {
            return "\(top.display.lowercased()), unconvincingly"
        }
        return "kept"
    }
}

extension NightSession {
    var emptyLookingEvents: [EventRecord] { events.filter(Relevance.looksLikeNothing) }
}
