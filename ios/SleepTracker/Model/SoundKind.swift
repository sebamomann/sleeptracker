import Foundation

/// The handful of things that actually happen in a bedroom at night.
///
/// Apple's classifier knows ~300 sounds drawn from general-purpose audio — YouTube-scale
/// clips at normal listening levels. A night recording is the opposite: quiet, close, and
/// mostly breathing and fabric. Out of distribution, it falls back on whichever class is
/// the biggest attractor, which is why so much of a real night came back as `music`.
///
/// So its output is mapped into this small vocabulary before anything is shown, and
/// anything unconvincing becomes `unclear` rather than a confident wrong answer. `unclear`
/// is an honest label; `music` at 3am is not.
enum SoundKind: String, Codable, CaseIterable, Identifiable {
    case snoring
    case talking
    case breathing
    case coughing
    case movement
    case outside
    case nothing
    case unclear

    var id: String { rawValue }

    var display: String {
        switch self {
        case .snoring: "Snoring"
        case .talking: "Talking"
        case .breathing: "Breathing"
        case .coughing: "Coughing"
        case .movement: "Movement"
        case .outside: "Outside"
        case .nothing: "Nothing"
        case .unclear: "Unclear"
        }
    }

    var symbol: String {
        switch self {
        case .snoring: "zzz"
        case .talking: "text.bubble"
        case .breathing: "wind"
        case .coughing: "exclamationmark.bubble"
        case .movement: "bed.double"
        case .outside: "building.2"
        case .nothing: "circle.dotted"
        case .unclear: "questionmark.circle"
        }
    }

    /// The ones worth offering as a correction. `unclear` is something the app concludes,
    /// never something a person means.
    static var choices: [SoundKind] {
        allCases.filter { $0 != .unclear }
    }

    /// Substrings of Apple's identifiers, checked in order. First match wins, so the
    /// specific cases sit above the general ones.
    private static let mapping: [(SoundKind, [String])] = [
        (.snoring, ["snor", "snort"]),
        (.coughing, ["cough", "sneez", "throat", "gag", "chok", "hiccup"]),
        (.talking, ["speech", "conversation", "shout", "whisper", "narrat", "yell",
                    "singing", "laugh", "babbl"]),
        (.breathing, ["breath", "wheez", "gasp", "sigh", "pant"]),
        (.movement, ["rustl", "cloth", "fabric", "bed", "footst", "scratch", "slap",
                     "thump", "knock", "creak", "shuffle"]),
        (.outside, ["traffic", "vehicle", "car", "engine", "siren", "dog", "bird",
                    "rain", "wind", "thunder", "door", "aircraft", "train"]),
        (.nothing, ["silence", "quiet"])
    ]

    /// What a classifier identifier means here, or nil when it means nothing useful —
    /// including `music`, `noise` and the other attractor classes it reaches for when it has
    /// no idea.
    static func from(identifier: String) -> SoundKind? {
        let lowered = identifier.lowercased()
        for (kind, needles) in mapping where needles.contains(where: lowered.contains) {
            return kind
        }
        return nil
    }
}

extension NightSession.EventRecord {
    /// What this event is, in the app's own vocabulary.
    ///
    /// Your correction wins outright. Otherwise the classifier's best label is translated,
    /// and only if it is confident enough to be worth repeating — below that, `unclear`,
    /// which is at least true.
    var kind: SoundKind {
        if let userKind, let corrected = SoundKind(rawValue: userKind) {
            return corrected
        }
        guard let top = topLabel, top.confidence >= 0.35 else { return .unclear }
        return SoundKind.from(identifier: top.identifier) ?? .unclear
    }

    var kindWasCorrected: Bool { userKind != nil }
}
