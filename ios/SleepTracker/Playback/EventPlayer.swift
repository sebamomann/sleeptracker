import AVFoundation
import SwiftUI

/// Plays one event at a time, loud enough to actually hear.
///
/// Built on AVAudioEngine rather than AVAudioPlayer because `volume` only attenuates — it
/// cannot exceed 1.0. Sleep audio is quiet by nature: a snore recorded across a room peaks
/// near -30 dBFS, and a breath far below that, so played back untouched the clips are
/// inaudible even at full system volume.
///
/// Each clip is lifted toward a target level using the peak already measured at record time,
/// so quiet events get more help than loud ones and every clip lands at a similar loudness.
/// The files are never modified: `peakDb` remains the true measurement, and the boost exists
/// only in the signal path.
@MainActor
final class EventPlayer: NSObject, ObservableObject {
    @Published private(set) var playingIndex: Int?

    /// Where clips are lifted to. Short of 0 dBFS so a boosted peak has room and does not
    /// clip on the way out.
    private static let targetDB = -6.0
    /// AVAudioUnitEQ tops out at +24 dB, and pushing a very quiet clip that far mostly
    /// amplifies the room. Better a quiet clip than a wall of hiss.
    private static let maxBoostDB = 24.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let amplifier = AVAudioUnitEQ(numberOfBands: 0)
    private var wired = false

    func toggle(_ event: NightSession.EventRecord, in sessionID: String) {
        if playingIndex == event.index {
            stop(); return
        }
        stop()

        let url = SessionStore.shared.url(forEvent: event, in: sessionID)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let file = try AVAudioFile(forReading: url)
            wire(for: file.processingFormat)
            amplifier.globalGain = Float(boost(forPeak: event.peakDb))

            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in
                    // Fires for a natural finish and for a stop alike; only the former
                    // should clear the row, and stop() has already cleared it by then.
                    guard self?.playingIndex == event.index else { return }
                    self?.stop()
                }
            }
            player.play()
            playingIndex = event.index
        } catch {
            playingIndex = nil
        }
    }

    func stop() {
        playingIndex = nil
        if player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.pause()
        }
    }

    /// dB of lift for a clip whose recorded peak was `peak`.
    private func boost(forPeak peak: Double) -> Double {
        guard peak > -100 else { return Self.maxBoostDB }
        return min(Self.maxBoostDB, max(0, Self.targetDB - peak))
    }

    private func wire(for format: AVAudioFormat) {
        guard !wired else { return }
        engine.attach(player)
        engine.attach(amplifier)
        engine.connect(player, to: amplifier, format: format)
        engine.connect(amplifier, to: engine.mainMixerNode, format: format)
        engine.prepare()
        wired = true
    }
}
