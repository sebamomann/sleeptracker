import Foundation
import UserNotifications

/// A nudge on the nights you forget.
///
/// iOS cannot run a check at bedtime to see whether you plugged in and forgot, so this
/// schedules one notification for the next occurrence of your chosen hour. Starting a
/// recording before that reschedules to the following night, so the reminder only ever
/// arrives when there is nothing running.
enum StartReminder {
    private static let idKey = "sleeptracker.reminder"
    private static let enabledKey = "sleeptracker.reminder.enabled"
    private static let hourKey = "sleeptracker.reminder.hour"
    private static let minuteKey = "sleeptracker.reminder.minute"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var time: DateComponents {
        get {
            let defaults = UserDefaults.standard
            return DateComponents(
                hour: defaults.object(forKey: hourKey) as? Int ?? 22,
                minute: defaults.object(forKey: minuteKey) as? Int ?? 30
            )
        }
        set {
            UserDefaults.standard.set(newValue.hour ?? 22, forKey: hourKey)
            UserDefaults.standard.set(newValue.minute ?? 30, forKey: minuteKey)
        }
    }

    static func requestAuthorization() async -> Bool {
        await (try? UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Schedule the next reminder. `skippingTonight` when a recording is already running.
    static func reschedule(skippingTonight: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [idKey])
        guard isEnabled else { return }

        var target = time
        target.second = 0
        let cal = Calendar.current
        guard var next = cal.nextDate(
            after: Date(),
            matching: target,
            matchingPolicy: .nextTime
        ) else { return }
        if skippingTonight, next.timeIntervalSinceNow < 12 * 3600 {
            next = next.addingTimeInterval(24 * 3600)
        }

        let content = UNMutableNotificationContent()
        content.title = "Recording tonight?"
        content.body = "Sleeptracker is not running. Tap to start before you go to sleep."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: next),
            repeats: false
        )
        center.add(UNNotificationRequest(identifier: idKey, content: content, trigger: trigger))
    }
}
