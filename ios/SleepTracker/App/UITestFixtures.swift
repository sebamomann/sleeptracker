import Foundation

/// A known set of nights for the UI tests, in a folder of their own.
///
/// Only in debug builds on the simulator. The tests could be pointed at a real phone from
/// Xcode's destination menu, and on one they would otherwise delete the nights on it — so
/// on a device this is inert whatever the launch environment says, and it never touches the
/// real `nights/` folder even on the simulator.
enum UITestFixtures {
    /// Set by `SleepTrackerUITests`: `fresh` reseeds, `keep` reuses what the last launch left.
    static let environmentKey = "SLEEPTRACKER_UITEST"

    static let nightID = "2026-09-14-23-00"
    static let olderNightID = "2026-09-13-23-10"

    static var mode: String? {
        #if DEBUG && targetEnvironment(simulator)
            return ProcessInfo.processInfo.environment[environmentKey]
        #else
            return nil
        #endif
    }

    static var isActive: Bool {
        mode != nil
    }

    /// Where nights live while the tests run, or nil for the real folder.
    static var root: URL? {
        guard isActive else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-nights", isDirectory: true)
    }

    /// Called before any view loads.
    static func prepareIfRequested() {
        guard mode == "fresh", let root else { return }
        try? FileManager.default.removeItem(at: root)
        if let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        let store = SessionStore.shared
        try? store.save(night(id: nightID, hoursAgo: 20, events: lastNightsEvents))
        try? store.save(night(id: olderNightID, hoursAgo: 44, events: [
            event(1, at: 1.2, "snoring", 0.8),
            event(2, at: 3.4, "cough", 0.7)
        ]))
    }

    /// Six sounds: two snores, speech with a transcript, a cough, breathing, and a `music`
    /// the app should call unclear.
    private static var lastNightsEvents: [NightSession.EventRecord] {
        var speech = event(3, at: 2, "speech", 0.7)
        speech.transcript = "turn the light off"
        return [
            event(1, at: 1, "snoring", 0.85),
            event(2, at: 1.5, "snoring", 0.8),
            speech,
            event(4, at: 3, "cough", 0.75),
            event(5, at: 4, "music", 0.4),
            event(6, at: 5, "breathing", 0.6)
        ]
    }

    private static func night(
        id: String,
        hoursAgo: Double,
        events: [NightSession.EventRecord]
    ) -> NightSession {
        let start = Date().addingTimeInterval(-hoursAgo * 3600)
        let t0 = start.timeIntervalSince1970 * 1000
        let seconds = 8 * 3600.0
        var session = NightSession(
            id: id,
            t0: t0,
            startedAt: start,
            lastAliveAt: t0 + seconds * 1000,
            device: .init(model: "simulator", systemVersion: "0", appVersion: "fixture"),
            sampleRate: 16000
        )
        session.endedAt = start.addingTimeInterval(seconds)
        session.ended = true
        session.audioSec = seconds
        session.lastFrameAtMs = t0 + seconds * 1000
        session.events = events.map { record in
            var shifted = record
            shifted.atMs = t0 + record.startS * 1000
            return shifted
        }
        return session
    }

    private static func event(
        _ index: Int,
        at hours: Double,
        _ label: String,
        _ confidence: Double
    ) -> NightSession.EventRecord {
        var record = NightSession.EventRecord(
            index: index,
            file: "missing-\(index).m4a",
            atMs: 0,
            startS: hours * 3600,
            endS: hours * 3600 + 6,
            durationS: 6,
            peakDb: -28
        )
        record.labels = [SoundLabel(identifier: label, confidence: confidence)]
        return record
    }
}
