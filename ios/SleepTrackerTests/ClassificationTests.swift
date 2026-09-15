import Foundation
import Testing
@testable import SleepTracker

/// The app's own vocabulary, and how the classifier and your corrections map into it.
struct SoundKindTests {
    @Test(arguments: [
        ("snoring", SoundKind.snoring),
        ("speech", .talking),
        ("cough", .coughing),
        ("fart", .farting),
        ("sniff", .sniffing),
        ("breathing", .breathing),
        ("door_open_or_close", .outside)
    ])
    func mapsClassifierIdentifiers(identifier: String, kind: SoundKind) {
        #expect(SoundKind.from(identifier: identifier) == kind)
    }

    @Test func attractorClassesMeanNothing() {
        #expect(SoundKind.from(identifier: "music") == nil)
    }

    @Test func nothingIsOfferedThatOnlyTheAppConcludes() {
        #expect(!SoundKind.choices.contains(.unclear))
        #expect(SoundKind.choices.contains(.farting))
        #expect(SoundKind.choices.contains(.awake))
        #expect(SoundKind.choices.contains(.sniffing))
    }

    @Test func anUnconvincingGuessIsUnclear() {
        #expect(makeEvent().kinds == [.unclear])
        let unsure = makeEvent(labels: [SoundLabel(identifier: "snoring", confidence: 0.2)])
        #expect(unsure.kinds == [.unclear])
        let sure = makeEvent(labels: [SoundLabel(identifier: "snoring", confidence: 0.8)])
        #expect(sure.kinds == [.snoring])
    }

    @Test func yourCorrectionBeatsTheClassifier() {
        let event = makeEvent(
            labels: [SoundLabel(identifier: "snoring", confidence: 0.9)],
            kinds: [.farting, .breathing]
        )
        #expect(event.kinds == [.farting, .breathing])
        #expect(event.kind == .farting)
        #expect(event.kindWasCorrected)
        #expect(event.has(.breathing))
        #expect(!event.has(.snoring))
        #expect(event.kindsDisplay == "Farting, breathing")
    }

    @Test func togglingKeepsTheOrderTheSoundsWereHeard() {
        var event = makeEvent()
        event.toggleCorrected(.farting)
        event.toggleCorrected(.breathing)
        event.toggleCorrected(.movement)
        #expect(event.correctedKinds == [.farting, .breathing, .movement])

        event.toggleCorrected(.breathing)
        #expect(event.correctedKinds == [.farting, .movement])
    }

    @Test func untickingTheLastKindGoesBackToTheGuess() {
        var event = makeEvent(labels: [SoundLabel(identifier: "snoring", confidence: 0.9)])
        event.toggleCorrected(.farting)
        event.toggleCorrected(.farting)
        #expect(event.userKinds == nil)
        #expect(!event.kindWasCorrected)
        #expect(event.kinds == [.snoring])
    }

    @Test func aNightCorrectedBeforeMultiSelectStillReads() throws {
        // Written by an older build: one `userKind`, none of the fields added since. A
        // non-optional new field would make this throw — and every old night unreadable.
        let json = """
        {"index": 3, "file": "0003.m4a", "atMs": 0, "startS": 10, "endS": 14,
         "durationS": 4, "peakDb": -31, "userKind": "coughing"}
        """
        var event = try JSONDecoder().decode(
            NightSession.EventRecord.self, from: Data(json.utf8)
        )
        #expect(event.correctedKinds == [.coughing])

        event.toggleCorrected(.movement)
        #expect(event.userKind == nil, "absorbed into the list on the next correction")
        #expect(event.correctedKinds == [.coughing, .movement])
    }

    @Test func anUnknownStoredKindIsIgnoredRatherThanFatal() {
        var event = makeEvent()
        event.userKinds = ["hovering", "snoring"]
        #expect(event.correctedKinds == [.snoring])
    }
}

/// What a night's figures do with a clip that holds several sounds.
struct MixedClipTests {
    @Test func aMixedClipCountsUnderEachOfItsKinds() {
        let night = makeSession(events: [
            makeEvent(index: 1, durationS: 4, kinds: [.farting, .breathing]),
            makeEvent(index: 2, durationS: 6, kinds: [.breathing])
        ])
        let tallies = Dictionary(uniqueKeysWithValues: night.byLabel.map { ($0.label, $0) })
        #expect(tallies["breathing"]?.count == 2)
        #expect(tallies["breathing"]?.seconds == 10)
        #expect(tallies["farting"]?.count == 1)
    }

    @Test func snoringAnywhereInAClipCountsAsSnoring() {
        let night = makeSession(events: [
            makeEvent(index: 1, durationS: 30, kinds: [.movement, .snoring]),
            makeEvent(index: 2, durationS: 20, kinds: [.movement])
        ])
        #expect(night.snoringSeconds == 30)
    }

    @Test func onlySingleSoundClipsAreTrainingData() {
        #expect(TrainingExport.exportableKind(makeEvent(kinds: [.farting])) == .farting)
        #expect(TrainingExport.exportableKind(makeEvent(kinds: [.farting, .movement])) == nil)
        #expect(TrainingExport.exportableKind(makeEvent()) == nil, "uncorrected")
    }
}

struct KindFilterTests {
    private let fartThenBreath = makeEvent(kinds: [.farting, .breathing])
    private let snore = makeEvent(kinds: [.snoring])

    @Test func anEmptyFilterShowsEverything() {
        let filter = KindFilter()
        #expect(!filter.isActive)
        #expect(filter.matches(fartThenBreath) && filter.matches(snore))
        #expect(filter.summary == "All sounds")
    }

    @Test func showOnlyMatchesAnyKindInTheClip() {
        var filter = KindFilter(mode: .only)
        filter.toggle(.breathing)
        #expect(filter.matches(fartThenBreath))
        #expect(!filter.matches(snore))
        #expect(filter.summary == "Only breathing")
    }

    @Test func hideDropsAClipHoldingAnyHiddenKind() {
        var filter = KindFilter(mode: .hide)
        filter.toggle(.breathing)
        #expect(!filter.matches(fartThenBreath))
        #expect(filter.matches(snore))
        #expect(filter.summary == "Hiding breathing")
    }

    @Test func togglingTwiceClears() {
        var filter = KindFilter()
        filter.toggle(.snoring)
        filter.toggle(.snoring)
        #expect(!filter.isActive)
    }
}

/// Whether an old event looks like nothing — and what must never be treated that way.
struct RelevanceTests {
    private let music = [SoundLabel(identifier: "music", confidence: 0.5)]

    @Test func anUnconvincingCatchAllLabelIsNothing() {
        #expect(Relevance.looksLikeNothing(makeEvent(peakDb: -30, labels: music)))
    }

    @Test func anInaudibleClipIsNothing() {
        let quiet = makeEvent(
            peakDb: -60,
            labels: [SoundLabel(identifier: "door", confidence: 0.9)]
        )
        #expect(Relevance.looksLikeNothing(quiet))
    }

    @Test func markedOrTranscribedEventsAreNeverNothing() {
        var starred = makeEvent(peakDb: -60, labels: music)
        starred.starred = true
        #expect(!Relevance.looksLikeNothing(starred))

        var spoken = makeEvent(peakDb: -60, labels: music)
        spoken.transcript = "the train"
        #expect(!Relevance.looksLikeNothing(spoken))
    }

    @Test func aHesitantSnoreIsKept() {
        let snore = makeEvent(
            peakDb: -60,
            labels: [SoundLabel(identifier: "snoring", confidence: 0.3)]
        )
        #expect(!Relevance.looksLikeNothing(snore))
    }

    @Test func aHesitantSniffIsKept() {
        let sniff = makeEvent(
            peakDb: -60,
            labels: [SoundLabel(identifier: "sniffling", confidence: 0.3)]
        )
        #expect(!Relevance.looksLikeNothing(sniff))
    }

    // MARK: - reason(_:), shown in the tidy-up confirmation

    @Test func explainsAnInaudibleClipByLoudnessAlone() {
        let quiet = makeEvent(
            peakDb: -60, labels: [SoundLabel(identifier: "door", confidence: 0.9)]
        )
        #expect(Relevance.reason(quiet) == "too quiet to hear")
    }

    @Test func explainsAnUnsureLabelAsUnrecognised() {
        let unsure = makeEvent(
            peakDb: -30, labels: [SoundLabel(identifier: "door", confidence: 0.1)]
        )
        #expect(Relevance.reason(unsure) == "unrecognised")
    }

    @Test func explainsAVagueLabelByName() {
        #expect(Relevance.reason(makeEvent(peakDb: -30, labels: music)) == "music, unconvincingly")
    }

    @Test func explainsAMissingLabelAsNotLabelled() {
        #expect(Relevance.reason(makeEvent(peakDb: -30, labels: nil)) == "not labelled")
    }

    @Test func explainsAKeptEventAsKept() {
        let clear = makeEvent(
            peakDb: -30,
            labels: [SoundLabel(identifier: "snoring", confidence: 0.9)]
        )
        #expect(Relevance.reason(clear) == "kept")
    }
}
