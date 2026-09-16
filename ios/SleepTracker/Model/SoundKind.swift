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
    case groaning
    case sniffing
    case farting
    case movement
    case awake
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
        case .groaning: "Groaning"
        case .sniffing: "Sniffing"
        case .farting: "Farting"
        case .movement: "Movement"
        case .awake: "Awake"
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
        case .groaning: "waveform.path.ecg"
        case .sniffing: "allergens"
        case .farting: "cloud"
        case .movement: "bed.double"
        case .awake: "eye"
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

    /// Kinds that mean someone was up, which `SleepTimeline` counts as awake. `awake` itself
    /// — up, checking the phone — is one only you can say: no classifier hears being awake,
    /// so nothing in `mapping` leads to it.
    var meansAwake: Bool {
        self == .talking || self == .awake
    }

    /// Substrings of Apple's identifiers, checked in order. First match wins, so the
    /// specific cases sit above the general ones.
    private static let mapping: [(SoundKind, [String])] = [
        (.snoring, ["snor", "snort"]),
        (.groaning, ["groan", "grunt", "moan", "whimper"]),
        (.coughing, ["cough", "sneez", "throat", "gag", "chok", "hiccup"]),
        (.sniffing, ["sniff"]),
        (.farting, ["fart"]),
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
    /// Everything this event holds, in the order it was heard.
    ///
    /// A clip is often more than one thing — a fart, then heavy breathing, then rolling
    /// over. Your correction wins outright. Otherwise the classifier's best label is
    /// translated, and only if it is confident enough to be worth repeating — below that,
    /// `unclear`, which is at least true.
    var kinds: [SoundKind] {
        let corrected = correctedKinds
        if !corrected.isEmpty {
            return corrected
        }
        guard let top = topLabel, top.confidence >= 0.35 else { return [.unclear] }
        return [SoundKind.from(identifier: top.identifier) ?? .unclear]
    }

    /// The first of `kinds`, for places with room for one word.
    var kind: SoundKind {
        kinds.first ?? .unclear
    }

    /// What you said it was. Nights corrected before a clip could hold several sounds
    /// carry a single `userKind`, which reads as a list of one.
    var correctedKinds: [SoundKind] {
        (userKinds ?? userKind.map { [$0] } ?? []).compactMap(SoundKind.init(rawValue:))
    }

    var kindWasCorrected: Bool { !correctedKinds.isEmpty }

    /// Add or remove one sound from the correction. Added to the end, so picking them in the
    /// order they were heard keeps that order.
    mutating func toggleCorrected(_ kind: SoundKind) {
        var kinds = correctedKinds
        if let i = kinds.firstIndex(of: kind) {
            kinds.remove(at: i)
        } else {
            kinds.append(kind)
        }
        setCorrected(kinds)
    }

    /// Always writes `userKinds`, and clears the legacy `userKind` it has absorbed.
    mutating func setCorrected(_ kinds: [SoundKind]) {
        userKinds = kinds.isEmpty ? nil : kinds.map(\.rawValue)
        userKind = nil
    }

    func has(_ kind: SoundKind) -> Bool {
        kinds.contains(kind)
    }

    /// "Farting, breathing, movement"
    var kindsDisplay: String {
        let words = kinds.map(\.display)
        guard let first = words.first else { return SoundKind.unclear.display }
        return ([first] + words.dropFirst().map { $0.lowercased() }).joined(separator: ", ")
    }
}
