import Foundation
import Speech

/// Transcribes speech events on-device.
///
/// `requiresOnDeviceRecognition` is the whole point: without it, Apple's recogniser uploads
/// audio to its servers. Everything about this app is local, and sleep talking is the last
/// thing that should leave the phone.
final class Transcriber {
    static let shared = Transcriber()

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    var isAvailable: Bool {
        guard let r = recognizer else { return false }
        return r.isAvailable && r.supportsOnDeviceRecognition
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Why it is unavailable, for the diagnostics log — "nothing was transcribed" is not a
    /// useful thing to discover in the morning.
    var unavailableReason: String? {
        guard let r = recognizer else { return "no recogniser for \(Locale.current.identifier)" }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined: return "permission not requested"
        case .denied: return "permission denied"
        case .restricted: return "restricted on this device"
        @unknown default: return "unknown authorisation state"
        }
        if !r.supportsOnDeviceRecognition { return "no on-device model for \(r.locale.identifier)" }
        if !r.isAvailable { return "recogniser temporarily unavailable" }
        return nil
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    func transcribe(url: URL) async -> String? {
        guard isAvailable, let recognizer else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                // The callback fires more than once, and either branch can be last, so the
                // continuation has to be guarded — resuming twice is a crash, not a warning.
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    once.resume(cont, with: text.isEmpty ? nil : text)
                } else if error != nil {
                    once.resume(cont, with: nil)
                }
            }
        }
    }
}

private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false

    func resume(_ c: CheckedContinuation<String?, Never>, with value: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        c.resume(returning: value)
    }
}
