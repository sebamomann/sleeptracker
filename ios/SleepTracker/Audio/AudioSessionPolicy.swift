import AVFoundation

/// The audio session, and the things the system does to it during an eight-hour recording.
///
/// Separated from the engine because these are policy decisions with reasons, not plumbing:
/// which category to claim, what not to allow, and which interruptions must not be allowed
/// to end the night.
@MainActor
final class AudioSessionPolicy {
    enum SystemEvent {
        case interruptionBegan // a call, an alarm, Siri
        case interruptionEnded
        case mediaServicesReset // the audio stack restarted underneath us
        case routeChanged
    }

    var onSystemEvent: ((SystemEvent) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func activate() throws {
        let session = AVAudioSession.sharedInstance()

        // .record rather than .playAndRecord: nothing here plays, and the narrower category
        // is less likely to be interrupted by other audio on the device.
        //
        // .measurement disables the input processing chain, which is the native equivalent
        // of the browser's echoCancellation/noiseSuppression/autoGainControl all being off:
        // AGC renormalises levels so the noise floor is meaningless, and noise suppression
        // deletes exactly the quiet sounds the gate is hunting for.
        //
        // No .allowBluetoothHFP: with it, a pair of AirPods left on the nightstand — or in a
        // closed case — becomes the input, and the night is recorded through a muffled
        // 8 kHz headset mic instead of the phone lying next to you.
        try session.setCategory(.record, mode: .measurement)
        try session.setPreferredSampleRate(CaptureEngine.sampleRate)
        try session.setActive(true)

        observe(AVAudioSession.interruptionNotification, on: session) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began: self?.onSystemEvent?(.interruptionBegan)
            case .ended: self?.onSystemEvent?(.interruptionEnded)
            @unknown default: break
            }
        }

        // Media services can be reset out from under a long-running session; without
        // handling this the engine comes back silently dead and the night is lost with no
        // gap recorded.
        observe(AVAudioSession.mediaServicesWereResetNotification, on: session) { [weak self] _ in
            self?.onSystemEvent?(.mediaServicesReset)
        }

        observe(AVAudioSession.routeChangeNotification, on: nil) { [weak self] _ in
            self?.onSystemEvent?(.routeChanged)
        }
    }

    func reactivate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func deactivate() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observe(
        _ name: Notification.Name,
        on object: Any?,
        _ handler: @escaping @MainActor (Notification) -> Void
    ) {
        observers.append(NotificationCenter.default.addObserver(
            forName: name, object: object, queue: .main
        ) { note in
            MainActor.assumeIsolated { handler(note) }
        })
    }
}
