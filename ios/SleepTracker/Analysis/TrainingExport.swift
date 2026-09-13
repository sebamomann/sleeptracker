import Foundation

/// Gathers your corrections into the folder layout Create ML wants.
///
/// Every time you tell the app what something actually was, that clip becomes a labelled
/// example. Enough of them — Apple suggests tens per class as a floor, hundreds to be
/// comfortable — and Create ML's Sound Classification template will train a model on your
/// room, your microphone and your distance from the bed, which is the part no general
/// classifier can know.
///
/// Writes into the app's Documents directory, which `UIFileSharingEnabled` exposes, so the
/// folder can be dragged off the phone in Finder.
enum TrainingExport {
    struct Result {
        var folder: URL
        var clips: Int
        var byKind: [SoundKind: Int]
    }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("training", isDirectory: true)
    }

    @discardableResult
    static func write(from sessions: [NightSession]) throws -> Result {
        let files = FileManager.default
        // Rebuilt rather than appended to: a correction changed since the last export must
        // not leave the clip sitting in its old class as well as its new one.
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        var counts: [SoundKind: Int] = [:]
        for session in sessions {
            for event in session.taughtEvents {
                guard let raw = event.userKind,
                      let kind = SoundKind(rawValue: raw) else { continue }
                let classFolder = folder.appendingPathComponent(kind.rawValue, isDirectory: true)
                try files.createDirectory(at: classFolder, withIntermediateDirectories: true)

                let source = SessionStore.shared.url(forEvent: event, in: session.id)
                guard files.fileExists(atPath: source.path) else { continue }
                let destination = classFolder
                    .appendingPathComponent("\(session.id)-\(event.index).m4a")
                try? files.removeItem(at: destination)
                try files.copyItem(at: source, to: destination)
                counts[kind, default: 0] += 1
            }
        }

        try readme(counts: counts).write(
            to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8
        )
        return Result(folder: folder, clips: counts.values.reduce(0, +), byKind: counts)
    }

    private static func readme(counts: [SoundKind: Int]) -> String {
        let lines = counts
            .sorted { $0.value > $1.value }
            .map { "  \($0.key.rawValue): \($0.value)" }
            .joined(separator: "\n")

        return """
        Sleeptracker training data
        ==========================

        One folder per class, each holding the clips you corrected by ear.

        \(lines.isEmpty ? "  (nothing corrected yet)" : lines)

        To train:
          1. Copy this folder to a Mac (Finder > your iPhone > Files > SleepTracker).
          2. Create ML > New Project > Sound Classification.
          3. Drop this folder on Training Data. Leave validation automatic.
          4. Train, then Output > Get > SleepSounds.mlmodel.
          5. Add it to ios/SleepTracker/ and rebuild — EventClassifier prefers it
             over Apple's automatically, and says which one it used in a night's log.

        Apple suggests at least tens of examples per class; hundreds is more comfortable.
        Classes with only a handful are better deleted than trained on.
        """
    }
}
