import Foundation
import UIKit

// How a night starts: the device, the classifier's vocabulary, and whether transcription
// is available. Construction rather than behaviour, so it lives with the model.

extension NightSession {
    /// A fresh night, with everything about the device and its capabilities recorded up
    /// front. "Nothing was transcribed" is not a useful thing to discover in the morning
    /// without knowing why, so unavailability is written into the log at the start.
    static func beginning(id: String, at now: Date) -> NightSession {
        var session = NightSession(
            id: id,
            t0: now.timeIntervalSince1970 * 1000,
            startedAt: now,
            lastAliveAt: now.timeIntervalSince1970 * 1000,
            device: .init(
                model: deviceModel,
                systemVersion: UIDevice.current.systemVersion,
                appVersion: appVersion
            ),
            sampleRate: CaptureEngine.sampleRate
        )

        session.marks.append(.init(at: session.t0, what: "started"))

        let classifier = EventClassifier.shared
        session.knownLabels = classifier.knownLabels
        session.marks.append(.init(
            at: session.t0,
            what: classifier.isAvailable
                ? "classifier ready, \(classifier.knownLabels.count) labels"
                : "CLASSIFIER UNAVAILABLE"
        ))

        // Recorded up front: "nothing was transcribed" is not a useful thing to discover in
        // the morning without knowing why.
        session.marks.append(.init(
            at: session.t0,
            what: Transcriber.shared.unavailableReason
                .map { "TRANSCRIPTION UNAVAILABLE: \($0)" } ?? "on-device transcription ready"
        ))

        return session
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
