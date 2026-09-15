import Foundation

/// How long after pressing start the night begins to be kept.
///
/// The first stretch of a night is getting into bed and lying there — scrolling, turning
/// over, the duvet — and it filled the morning's list with events nobody wanted. Some people
/// take longer than others to fall asleep, so it is a setting rather than a constant.
///
/// Capture still starts the moment you press start: iOS lets a backgrounded app keep
/// recording, never begin, so waiting with the microphone off would mean a locked phone
/// could never start at all.
enum ListeningDelay {
    private static let key = "sleeptracker.listeningDelay.minutes"

    static let choices = [0, 5, 10, 15, 20, 30, 45, 60]

    static var minutes: Int {
        get { UserDefaults.standard.object(forKey: key) as? Int ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var seconds: TimeInterval {
        TimeInterval(minutes * 60)
    }

    static func label(_ minutes: Int) -> String {
        minutes == 0 ? "Straight away" : "After \(minutes) min"
    }
}
