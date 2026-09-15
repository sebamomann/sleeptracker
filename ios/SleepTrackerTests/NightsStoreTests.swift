import Foundation
import Testing
@testable import SleepTracker

/// The single place marks, notes and corrections are mutated. Every test here runs against
/// a scratch `SessionStore`, never the real `nights/` folder.
@MainActor
struct NightsStoreTests {
    private func makeStore(_ sessions: NightSession...) -> (NightsStore, SessionStore) {
        let files = makeScratchStore()
        for session in sessions {
            try? files.save(session)
        }
        let nights = NightsStore(store: files)
        nights.reload()
        return (nights, files)
    }

    // MARK: - Marks

    @Test func togglingStarFlipsItAndSurvivesAReload() {
        let (nights, files) = makeStore(makeSession(events: [makeEvent()]))
        nights.toggleStar(sessionID: "test", eventIndex: 1)
        #expect(nights.session(id: "test")?.events.first?.isStarred == true)

        nights.reload()
        #expect(nights.session(id: "test")?.events.first?.isStarred == true, "saved to disk")

        nights.toggleStar(sessionID: "test", eventIndex: 1)
        #expect(nights.session(id: "test")?.events.first?.isStarred == false)
        _ = files
    }

    @Test func toggleFlagIsIndependentOfStar() {
        let (nights, _) = makeStore(makeSession(events: [makeEvent()]))
        nights.toggleFlag(sessionID: "test", eventIndex: 1)
        let event = nights.session(id: "test")?.events.first
        #expect(event?.isFlagged == true)
        #expect(event?.isStarred == false)
        #expect(event?.isMarked == true)
    }

    @Test func removingTheLastMarkDropsTheNote() {
        let (nights, _) = makeStore(makeSession(events: [makeEvent()]))
        nights.toggleStar(sessionID: "test", eventIndex: 1)
        nights.setNote(sessionID: "test", eventIndex: 1, note: "ask about this")
        #expect(nights.session(id: "test")?.events.first?.note == "ask about this")

        nights.toggleStar(sessionID: "test", eventIndex: 1) // the only mark
        #expect(nights.session(id: "test")?.events.first?.note == nil, "unreachable once unmarked")
    }

    @Test func writingANoteOnAnUnmarkedEventStarsIt() {
        // A note is itself a reason to keep something; otherwise it would be invisible.
        let (nights, _) = makeStore(makeSession(events: [makeEvent()]))
        nights.setNote(sessionID: "test", eventIndex: 1, note: "hmm")
        let event = nights.session(id: "test")?.events.first
        #expect(event?.isStarred == true)
        #expect(event?.note == "hmm")
    }

    @Test func aBlankNoteIsStoredAsNone() {
        let (nights, _) = makeStore(makeSession(events: [makeEvent()]))
        nights.toggleFlag(sessionID: "test", eventIndex: 1)
        nights.setNote(sessionID: "test", eventIndex: 1, note: "   ")
        #expect(nights.session(id: "test")?.events.first?.note == nil)
    }

    // MARK: - Kind corrections

    @Test func toggleKindDelegatesToTheEventRecord() {
        // Thin on purpose: the ordering and toggling rules are `SoundKindTests`'; this only
        // checks the store actually calls through and persists it.
        let (nights, _) = makeStore(makeSession(events: [makeEvent()]))
        nights.toggleKind(sessionID: "test", eventIndex: 1, kind: .farting)
        nights.toggleKind(sessionID: "test", eventIndex: 1, kind: .breathing)
        #expect(nights.session(id: "test")?.events.first?.correctedKinds == [.farting, .breathing])

        nights.clearKinds(sessionID: "test", eventIndex: 1)
        #expect(nights.session(id: "test")?.events.first?.correctedKinds == [])
    }

    // MARK: - Deleting events

    @Test func deletingAnEventRemovesItsFile() throws {
        let event = makeEvent(index: 1)
        let (nights, files) = makeStore(makeSession(events: [event, makeEvent(index: 2)]))
        let url = try writeDummyClip(for: event, in: "test", store: files)
        #expect(FileManager.default.fileExists(atPath: url.path))

        nights.deleteEvents(sessionID: "test", indices: [1])

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(nights.session(id: "test")?.events.map(\.index) == [2])
    }

    @Test func deletingAMissingFileDoesNotThrowOrBlockTheRemoval() {
        // No clip was ever written for this event — a night recorded before this feature,
        // or one whose file already went missing. The record still comes out cleanly.
        let (nights, _) = makeStore(makeSession(events: [makeEvent(index: 1)]))
        nights.deleteEvents(sessionID: "test", indices: [1])
        #expect(nights.session(id: "test")?.events.isEmpty == true)
    }

    // MARK: - Marked, grouped by night

    @Test func markedByNightGroupsNewestNightFirstAndDropsEmptyNights() {
        var quiet = makeSession(id: "quiet")
        quiet.t0 = 0
        var later = makeSession(id: "later", events: [makeEvent(index: 1)])
        later.t0 = 2000
        var earlier = makeSession(id: "earlier", events: [makeEvent(index: 2)])
        earlier.t0 = 1000

        let (nights, _) = makeStore(quiet, later, earlier)
        nights.toggleStar(sessionID: "later", eventIndex: 1)
        nights.toggleFlag(sessionID: "earlier", eventIndex: 2)

        let groups = nights.markedByNight()
        #expect(groups.map(\.night.id) == ["later", "earlier"], "newest first, quiet dropped")
    }

    @Test func markFilterSeparatesStarredFromFlagged() {
        let (nights, _) = makeStore(makeSession(events: [makeEvent(index: 1), makeEvent(index: 2)]))
        nights.toggleStar(sessionID: "test", eventIndex: 1)
        nights.toggleFlag(sessionID: "test", eventIndex: 2)

        #expect(nights.markedByNight(.starred).first?.events.map(\.index) == [1])
        #expect(nights.markedByNight(.flagged).first?.events.map(\.index) == [2])
        #expect(nights.markedByNight(.all).first?.events.count == 2)
    }

    @Test func countsAddUpAcrossNights() {
        var first = makeSession(id: "first", events: [makeEvent(index: 1), makeEvent(index: 2)])
        first.t0 = 0
        var second = makeSession(id: "second", events: [makeEvent(index: 3)])
        second.t0 = 1

        let (nights, _) = makeStore(first, second)
        nights.toggleStar(sessionID: "first", eventIndex: 1)
        nights.toggleFlag(sessionID: "first", eventIndex: 2)
        nights.toggleStar(sessionID: "second", eventIndex: 3)

        #expect(nights.starredCount == 2)
        #expect(nights.flaggedCount == 1)
        #expect(nights.markedCount == 3)
    }

    // MARK: - Reclassify

    @Test func reclassifyingAMissingFileLeavesLabelsAlone() async {
        // No clip was written, so the classifier finds nothing to open — same as a night
        // whose audio never made it to disk. The merge must not crash or invent labels.
        let (nights, _) = makeStore(makeSession(events: [makeEvent(index: 1, labels: nil)]))
        await nights.reclassify(sessionID: "test", events: [makeEvent(index: 1)])
        #expect(nights.session(id: "test")?.events.first?.labels == nil)
    }

    @Test func reclassifyOnlyFillsKnownLabelsWhenAskedTo() async {
        let (nights, _) = makeStore(makeSession(events: [makeEvent(index: 1)]))
        #expect(nights.session(id: "test")?.knownLabels == nil)

        await nights.reclassify(sessionID: "test", events: [], refreshKnownLabels: false)
        #expect(
            nights.session(id: "test")?.knownLabels?.isEmpty == false,
            "filled in because it was nil, regardless of the flag"
        )
    }

    @Test func reclassifyWithRefreshOverwritesAnExistingVocabulary() async {
        let (nights, _) = makeStore(makeSession(events: [makeEvent(index: 1)]))
        nights.update(id: "test") { $0.knownLabels = ["stale"] }

        await nights.reclassify(sessionID: "test", events: [], refreshKnownLabels: true)
        #expect(nights.session(id: "test")?.knownLabels != ["stale"])
    }

    @Test func reclassifyWithoutRefreshLeavesAnExistingVocabularyAlone() async {
        let (nights, _) = makeStore(makeSession(events: [makeEvent(index: 1)]))
        nights.update(id: "test") { $0.knownLabels = ["stale"] }

        await nights.reclassify(sessionID: "test", events: [], refreshKnownLabels: false)
        #expect(nights.session(id: "test")?.knownLabels == ["stale"])
    }
}
