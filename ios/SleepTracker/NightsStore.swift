import Foundation

/// The loaded nights, and the single place they are mutated.
///
/// Marks and notes are edited from three screens — a night's event list, the highlight reel,
/// and the global favourites view — so the state cannot live in any one of them. Every change
/// writes straight through to disk: there is no save button, and a marked event that vanished
/// on relaunch would be worse than no marking at all.
@MainActor
final class NightsStore: ObservableObject {
    @Published private(set) var sessions: [NightSession] = []

    private let store = SessionStore.shared

    func reload() { sessions = store.list() }

    func session(id: String) -> NightSession? { sessions.first { $0.id == id } }

    func update(id: String, _ mutate: (inout NightSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i])
        try? store.save(sessions[i])
    }

    func toggleStar(sessionID: String, eventIndex: Int) {
        mutateEvent(sessionID, eventIndex) { e in
            e.starred = !(e.starred ?? false)
            dropNoteIfUnmarked(&e)
        }
    }

    func toggleFlag(sessionID: String, eventIndex: Int) {
        mutateEvent(sessionID, eventIndex) { e in
            e.flagged = !(e.flagged ?? false)
            dropNoteIfUnmarked(&e)
        }
    }

    func setNote(sessionID: String, eventIndex: Int, note: String?) {
        mutateEvent(sessionID, eventIndex) { e in
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            e.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
            // A note is itself a reason to keep something, so writing one stars it if it
            // carries no mark yet — otherwise the note would be invisible, since notes only
            // ever appear on marked events.
            if e.note != nil, !e.isMarked { e.starred = true }
        }
    }

    private func mutateEvent(_ sessionID: String, _ eventIndex: Int,
                             _ mutate: (inout NightSession.EventRecord) -> Void) {
        update(id: sessionID) { s in
            guard let j = s.events.firstIndex(where: { $0.index == eventIndex }) else { return }
            mutate(&s.events[j])
        }
    }

    /// An unmarked event's note is unreachable, so removing the last mark removes the note.
    private func dropNoteIfUnmarked(_ e: inout NightSession.EventRecord) {
        if !e.isMarked { e.note = nil }
    }

    func delete(id: String) {
        store.delete(id: id)
        sessions.removeAll { $0.id == id }
    }

    enum MarkFilter: String, CaseIterable, Identifiable {
        case all = "All", starred = "Starred", flagged = "Flagged"
        var id: String { rawValue }

        func matches(_ e: NightSession.EventRecord) -> Bool {
            switch self {
            case .all: return e.isMarked
            case .starred: return e.isStarred
            case .flagged: return e.isFlagged
            }
        }
    }

    /// Marked events grouped by night, newest night first — the shape the favourites view
    /// renders directly.
    func markedByNight(_ filter: MarkFilter = .all)
        -> [(night: NightSession, events: [NightSession.EventRecord])] {
        sessions
            .map { ($0, $0.events.filter(filter.matches).sorted { $0.atMs < $1.atMs }) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0.t0 > $1.0.t0 }
    }

    var starredCount: Int { sessions.reduce(0) { $0 + $1.starredEvents.count } }
    var flaggedCount: Int { sessions.reduce(0) { $0 + $1.flaggedEvents.count } }
    var markedCount: Int { sessions.reduce(0) { $0 + $1.markedEvents.count } }
}
