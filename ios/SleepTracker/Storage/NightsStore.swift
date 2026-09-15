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

    private let store: SessionStore

    /// `store` is a seam for tests: pass one rooted in a scratch directory to exercise
    /// mutation without touching a real night.
    init(store: SessionStore = .shared) {
        self.store = store
    }

    func reload() {
        sessions = store.list()
    }

    func session(id: String) -> NightSession? {
        sessions.first { $0.id == id }
    }

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

    /// Add or remove one sound from what an event actually was. Overrides the classifier,
    /// and becomes training data for a model that would not need overriding.
    func toggleKind(sessionID: String, eventIndex: Int, kind: SoundKind) {
        mutateEvent(sessionID, eventIndex) { $0.toggleCorrected(kind) }
    }

    /// Back to the classifier's guess.
    func clearKinds(sessionID: String, eventIndex: Int) {
        mutateEvent(sessionID, eventIndex) { $0.setCorrected([]) }
    }

    func setNote(sessionID: String, eventIndex: Int, note: String?) {
        mutateEvent(sessionID, eventIndex) { e in
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            e.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
            // A note is itself a reason to keep something, so writing one stars it if it
            // carries no mark yet — otherwise the note would be invisible, since notes only
            // ever appear on marked events.
            if e.note != nil, !e.isMarked {
                e.starred = true
            }
        }
    }

    private func mutateEvent(
        _ sessionID: String,
        _ eventIndex: Int,
        _ mutate: (inout NightSession.EventRecord) -> Void
    ) {
        update(id: sessionID) { s in
            guard let j = s.events.firstIndex(where: { $0.index == eventIndex }) else { return }
            mutate(&s.events[j])
        }
    }

    /// An unmarked event's note is unreachable, so removing the last mark removes the note.
    private func dropNoteIfUnmarked(_ e: inout NightSession.EventRecord) {
        if !e.isMarked {
            e.note = nil
        }
    }

    /// Remove specific events from a night, files and all.
    ///
    /// Used by the tidy-up, which offers to drop events that look like nothing. The audio
    /// goes with the record — leaving orphaned files behind would quietly fill the phone
    /// with clips nothing can reach.
    func deleteEvents(sessionID: String, indices: Set<Int>) {
        update(id: sessionID) { session in
            for event in session.events where indices.contains(event.index) {
                try? FileManager.default.removeItem(
                    at: self.store.url(forEvent: event, in: sessionID)
                )
            }
            session.events.removeAll { indices.contains($0.index) }
        }
    }

    /// Re-runs the classifier on `events` and merges fresh labels back in.
    ///
    /// Shared by "Classify N unlabelled events" (nights recorded before classification
    /// existed) and "Re-classify all" (a second opinion after the rules or the model
    /// change) — the two were the same loop written twice. Classifying is slow enough that
    /// it runs off the main actor; only the merge touches `sessions`.
    ///
    /// `refreshKnownLabels` says whether to overwrite the recorded vocabulary even if one
    /// is already there — a full re-classify wants today's answer, while filling in gaps
    /// only wants a vocabulary recorded if the night predates having one at all.
    func reclassify(
        sessionID: String,
        events: [NightSession.EventRecord],
        refreshKnownLabels: Bool = false
    ) async {
        // Copied to a local so the detached task captures a plain value, not `self` — this
        // class isn't Sendable, and the task must not touch anything on the main actor.
        let capturedStore = store
        let labelled = await Task.detached(priority: .utility) { () -> [Int: [SoundLabel]] in
            var fresh: [Int: [SoundLabel]] = [:]
            for event in events {
                let labels = EventClassifier.shared
                    .classify(url: capturedStore.url(forEvent: event, in: sessionID))
                if !labels.isEmpty {
                    fresh[event.index] = labels
                }
            }
            return fresh
        }.value

        update(id: sessionID) { session in
            for (index, labels) in labelled {
                if let i = session.events.firstIndex(where: { $0.index == index }) {
                    session.events[i].labels = labels
                }
            }
            if refreshKnownLabels || session.knownLabels == nil {
                session.knownLabels = EventClassifier.shared.knownLabels
            }
        }
    }

    func delete(id: String) {
        store.delete(id: id)
        sessions.removeAll { $0.id == id }
    }

    enum MarkFilter: String, CaseIterable, Identifiable {
        case all = "All", starred = "Starred", flagged = "Flagged"
        var id: String {
            rawValue
        }

        func matches(_ e: NightSession.EventRecord) -> Bool {
            switch self {
            case .all: e.isMarked
            case .starred: e.isStarred
            case .flagged: e.isFlagged
            }
        }
    }

    /// Marked events grouped by night, newest night first — the shape the favourites view
    /// renders directly.
    func markedByNight(_ filter: MarkFilter = .all)
        -> [(night: NightSession, events: [NightSession.EventRecord])] {
        sessions
            .map { night in
                (night, night.events.filter(filter.matches).sorted { lhs, rhs in
                    lhs.atMs == rhs.atMs ? lhs.index < rhs.index : lhs.atMs < rhs.atMs
                })
            }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0.t0 > $1.0.t0 }
    }

    var starredCount: Int {
        sessions.reduce(0) { $0 + $1.starredEvents.count }
    }

    var flaggedCount: Int {
        sessions.reduce(0) { $0 + $1.flaggedEvents.count }
    }

    var markedCount: Int {
        sessions.reduce(0) { $0 + $1.markedEvents.count }
    }
}
