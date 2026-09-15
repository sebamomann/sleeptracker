import Foundation

/// Which sounds a list shows: only some kinds, or everything but some.
///
/// Matched against every kind an event holds, so "only farting" keeps a clip that was a
/// fart and then breathing, and "hide breathing" drops it.
struct KindFilter: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case only = "Show only"
        case hide = "Hide"
        var id: String {
            rawValue
        }
    }

    var mode = Mode.only
    var kinds: Set<SoundKind> = []

    var isActive: Bool {
        !kinds.isEmpty
    }

    func matches(_ event: NightSession.EventRecord) -> Bool {
        guard isActive else { return true }
        let hit = event.kinds.contains(where: kinds.contains)
        return mode == .only ? hit : !hit
    }

    mutating func toggle(_ kind: SoundKind) {
        if kinds.contains(kind) {
            kinds.remove(kind)
        } else {
            kinds.insert(kind)
        }
    }

    /// "Only snoring, farting" · "Hiding unclear"
    var summary: String {
        let names = SoundKind.allCases.filter(kinds.contains).map { $0.display.lowercased() }
        guard !names.isEmpty else { return "All sounds" }
        return (mode == .only ? "Only " : "Hiding ") + names.joined(separator: ", ")
    }
}
