import SwiftUI

/// Committed to a single dark look on purpose: this is read in a dark bedroom, and a light
/// mode would be actively unhelpful. Values are the palette validated for the web report,
/// so a night looks the same whichever screen it is read on.
enum Theme {
    static let surface0 = Color.black
    static let surface1 = Color(red: 0.102, green: 0.102, blue: 0.098) // #1a1a19
    static let surface2 = Color(red: 0.141, green: 0.141, blue: 0.133) // #242422
    static let line = Color(red: 0.227, green: 0.227, blue: 0.216) // #3a3a37

    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.765, green: 0.761, blue: 0.718) // #c3c2b7
    static let textMuted = Color(red: 0.541, green: 0.537, blue: 0.498) // #8a897f

    static let signal = Color(red: 0.224, green: 0.529, blue: 0.898) // #3987e5 loudness
    static let event = Color(red: 0.098, green: 0.620, blue: 0.439) // #199e70 gate events
    static let gap = Color(red: 0.902, green: 0.404, blue: 0.404) // #e66767 dead time

    /// Dim red for the recording screen — preserves night vision at low brightness.
    static let nightInk = Color(red: 0.561, green: 0.184, blue: 0.184) // #8f2f2f
}
