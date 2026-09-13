import CoreML
import Foundation
import SoundAnalysis

/// Labels an event's WAV using Apple's built-in sound classifier.
///
/// Entirely on-device: no server, no network, no entitlement, and nothing that needs a paid
/// developer account. Classification runs per event rather than continuously — an all-night
/// stream would burn battery analysing silence, and the gate has already decided which
/// seconds are worth looking at.
final class EventClassifier {
    static let shared = EventClassifier()

    private let request: SNClassifySoundRequest?

    /// Which model is answering, for the night's log.
    private(set) var source = "Apple's built-in classifier"

    init() {
        // A model trained on your own corrected clips, if one has been dropped into the
        // bundle. Apple's is general-purpose and trained on ordinary listening levels; a
        // night recording is quiet, close and mostly breathing, which is why so much of it
        // comes back as `music`. Create ML's Sound Classification template takes the folders
        // that `TrainingExport` writes and produces exactly this file.
        if let url = Bundle.main.url(forResource: "SleepSounds", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url),
           let custom = try? SNClassifySoundRequest(mlModel: model) {
            request = custom
            source = "SleepSounds — trained on your nights"
            return
        }
        request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
    }

    var isAvailable: Bool {
        request != nil
    }

    /// Every label this build of iOS can produce. Recorded into the session so the set the
    /// device actually offers is documented, rather than assumed.
    var knownLabels: [String] {
        (request?.knownClassifications ?? []).sorted()
    }

    /// Top labels for one file, averaged over the analysis windows.
    ///
    /// Averaged rather than taking the single most confident window: a four-second clip
    /// produces several windows, and one spike of "speech" in the middle of otherwise
    /// obvious snoring should not relabel the whole event.
    func classify(url: URL, top: Int = 3) -> [SoundLabel] {
        guard let request, let analyzer = try? SNAudioFileAnalyzer(url: url) else { return [] }
        let collector = Collector()
        do { try analyzer.add(request, withObserver: collector) } catch { return [] }
        analyzer.analyze() // synchronous; callers are already off the main thread
        return collector.top(top)
    }
}

private final class Collector: NSObject, SNResultsObserving {
    private var sums: [String: Double] = [:]
    private var windows = 0

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        windows += 1
        for classification in result.classifications {
            sums[classification.identifier, default: 0] += Double(classification.confidence)
        }
    }

    func top(_ n: Int) -> [SoundLabel] {
        guard windows > 0 else { return [] }
        return sums
            .map { SoundLabel(identifier: $0.key, confidence: $0.value / Double(windows)) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(n)
            .map { $0 }
    }
}
