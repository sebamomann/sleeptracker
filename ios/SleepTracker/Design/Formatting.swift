import Foundation

/// Every date format the app uses, in one place.
///
/// Six views each carried a private static DateFormatter, several with the same format
/// string. Beyond the duplication, they drifted: the same timestamp appeared as `02:14:07`
/// in one list and `12 Sep 02:14:07` in another for no reason the reader could see.
enum Fmt {
    /// 02:14:07
    static let time = formatter("HH:mm:ss")
    /// 02:14
    static let hourMinute = formatter("HH:mm")
    /// 02
    static let hour = formatter("HH")
    /// 12 Sep 02:14:07
    static let dateTime = formatter("d MMM HH:mm:ss")
    /// 12 Sep, 02:14:07
    static let dateTimeLong = formatter("d MMM, HH:mm:ss")
    /// Thu 12 Sep
    static let day = formatter("EEE d MMM")
    /// Thu 12 Sep, 23:14
    static let dayTime = formatter("EEE d MMM, HH:mm")
    /// 2026-09-12-23-14 — a night's directory name, so never localised.
    static let sessionID = formatter("yyyy-MM-dd-HH-mm", localised: false)
    /// 231407 — an event's file name, likewise.
    static let fileTime = formatter("HHmmss", localised: false)

    private static func formatter(_ format: String, localised: Bool = true) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        if !localised {
            f.locale = Locale(identifier: "en_US_POSIX")
        }
        return f
    }
}

extension TimeInterval {
    /// "7h 14m", "3m 09s", "12s"
    var short: String {
        let s = Int(rounded())
        if s >= 3600 {
            return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
        }
        if s >= 60 {
            return "\(s / 60)m \(String(format: "%02d", s % 60))s"
        }
        return "\(s)s"
    }

    /// "7:14:22"
    var clock: String {
        let s = Int(max(0, self))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
