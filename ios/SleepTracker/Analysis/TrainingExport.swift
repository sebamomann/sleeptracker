import AVFoundation
import Foundation

/// Gathers your corrections into the folder layout Create ML wants.
///
/// Every time you tell the app what something actually was, that clip becomes a labelled
/// example. Enough of them — Apple suggests tens per class as a floor, hundreds to be
/// comfortable — and Create ML's Sound Classification template will train a model on your
/// room, your microphone and your distance from the bed, which is the part no general
/// classifier can know.
///
/// Only clips holding a single sound are exported. Create ML's sound classifier learns one
/// class per clip, and a clip filed under farting, breathing and movement at once would teach
/// it that all three sound the same. Mixed clips are counted, so it is clear what was left out.
///
/// Exported clips are amplified the same way in-app playback is — see `AudioBoost` — but as
/// an actual re-encode rather than an EQ in the signal path: a clip dragged off the phone to
/// a Mac has nothing standing between it and your ears the way `EventPlayer` does.
///
/// Writes into the app's Documents directory, which `UIFileSharingEnabled` exposes, so the
/// folder can be dragged off the phone in Finder.
enum TrainingExport {
    struct Result {
        var folder: URL
        var clips: Int
        var byKind: [SoundKind: Int]
        /// Corrected clips holding more than one sound, and so not exported.
        var mixed: Int
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
        var mixed = 0
        for session in sessions {
            for event in session.taughtEvents {
                guard let kind = exportableKind(event) else {
                    mixed += 1
                    continue
                }
                let classFolder = folder.appendingPathComponent(kind.rawValue, isDirectory: true)
                try files.createDirectory(at: classFolder, withIntermediateDirectories: true)

                let source = SessionStore.shared.url(forEvent: event, in: session.id)
                guard files.fileExists(atPath: source.path) else { continue }
                let destination = classFolder
                    .appendingPathComponent("\(session.id)-\(event.index).m4a")
                try? files.removeItem(at: destination)
                guard (try? amplify(source, to: destination, peakDb: event.peakDb)) != nil
                else { continue }
                counts[kind, default: 0] += 1
            }
        }

        try readme(counts: counts, mixed: mixed).write(
            to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8
        )
        return Result(
            folder: folder, clips: counts.values.reduce(0, +), byKind: counts, mixed: mixed
        )
    }

    /// Decodes `source`, lifts it by `AudioBoost.gainDB(forPeak:)`, and re-encodes the
    /// result to `destination`.
    private static func amplify(_ source: URL, to destination: URL, peakDb: Double) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(input.length)
        )
        else { throw CocoaError(.fileReadCorruptFile) }
        try input.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let gain = Float(pow(10, AudioBoost.gainDB(forPeak: peakDb) / 20))
        let count = Int(buffer.frameLength)
        var boosted = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            // Clamped rather than trusted: `peakDb` is measured at record time, and a
            // decode that comes back even slightly hotter than that must not clip on export.
            boosted[i] = max(-1, min(1, channel[i] * gain))
        }

        try EventWriter.encode(boosted, format: format, to: destination)
    }

    /// The class a corrected clip trains, or nil when it holds more than one sound.
    static func exportableKind(_ event: NightSession.EventRecord) -> SoundKind? {
        let kinds = event.correctedKinds
        return kinds.count == 1 ? kinds.first : nil
    }

    private static func readme(counts: [SoundKind: Int], mixed: Int) -> String {
        let lines = counts
            .sorted { $0.value > $1.value }
            .map { "  \($0.key.rawValue): \($0.value)" }
            .joined(separator: "\n")

        return """
        Sleeptracker training data
        ==========================

        One folder per class, each holding the clips you corrected by ear.

        \(lines.isEmpty ? "  (nothing corrected yet)" : lines)

        \(mixed) clip\(mixed == 1 ? "" : "s") holding more than one sound left out: a sound
        classifier learns one class per clip, so a mixed clip would blur the classes it
        belongs to.

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
