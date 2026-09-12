import Foundation
import SoundAnalysis

struct SoundLabel: Codable, Hashable, Identifiable {
    var identifier: String
    var confidence: Double
    var id: String { identifier }

    /// "door_open_or_close" → "Door open or close"
    var display: String {
        let words = identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Labels an event's WAV using Apple's built-in sound classifier.
///
/// Entirely on-device: no server, no network, no entitlement, and nothing that needs a paid
/// developer account. Classification runs per event rather than continuously — an all-night
/// stream would burn battery analysing silence, and the gate has already decided which
/// seconds are worth looking at.
final class EventClassifier {
    static let shared = EventClassifier()

    private let request: SNClassifySoundRequest?

    init() {
        request = try? SNClassifySoundRequest(classifierIdentifier: .version1)
    }

    var isAvailable: Bool { request != nil }

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
        analyzer.analyze()      // synchronous; callers are already off the main thread
        return collector.top(top)
    }
}

private final class Collector: NSObject, SNResultsObserving {
    private var sums: [String: Double] = [:]
    private var windows = 0

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        windows += 1
        for c in result.classifications {
            sums[c.identifier, default: 0] += Double(c.confidence)
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
