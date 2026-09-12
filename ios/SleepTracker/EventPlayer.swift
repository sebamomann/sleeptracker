import AVFoundation
import SwiftUI

/// Plays one event at a time. Recording leaves the audio session in `.record`, which cannot
/// play anything, so the category is switched on demand — hence playback only being offered
/// for nights that have finished.
@MainActor
final class EventPlayer: NSObject, ObservableObject {
    @Published private(set) var playingIndex: Int?

    private var player: AVAudioPlayer?

    func toggle(url: URL, index: Int) {
        if playingIndex == index { stop(); return }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            playingIndex = index
        } catch {
            playingIndex = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingIndex = nil
    }
}

extension EventPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingIndex = nil }
    }
}
