import SwiftUI

/// The Spectrogram palette.
///
/// The look comes from what the app does. A deep slate ground carries a faint spectrogram
/// texture, and a spectral ramp — violet through cyan and mint to amber — is reserved
/// **strictly for data**: bars, chart fills, the classifier's own output. Everything
/// structural stays greyscale, so on any screen the numbers are the only colour.
///
/// Committed to a single dark world on purpose: this is read in a bedroom, and a light mode
/// would be actively unhelpful at the hours it gets opened.
enum Theme {
    // MARK: - Ground and surfaces

    /// The base of the ground gradient; see `spectrogramGround()`.
    static let surface0 = Color(hex: 0x06090D)
    /// The top of the ground gradient — lighter, so the screen has a horizon.
    static let surface0Top = Color(hex: 0x0C1219)
    static let surface1 = Color(hex: 0x111820)
    static let surface2 = Color(hex: 0x1A2430)
    static let line = Color(hex: 0x1F2A35)

    // MARK: - Ink

    static let textPrimary = Color(hex: 0xEAF0F6)
    static let textSecondary = Color(hex: 0x9FB0BF)
    static let textMuted = Color(hex: 0x6D7F8E)

    // MARK: - The spectral ramp — data only

    static let spectrumViolet = Color(hex: 0xA97BF0)
    static let spectrumCyan = Color(hex: 0x59C8F5)
    static let spectrumMint = Color(hex: 0x7DDBA6)
    static let spectrumAmber = Color(hex: 0xF5C453)

    /// Low to high, as a spectrogram reads. Used vertically in bars and chart fills.
    static let spectrum = [spectrumViolet, spectrumCyan, spectrumMint, spectrumAmber]

    /// Vertical: amber at the top, violet at the bottom, so height reads as magnitude.
    static var spectrumGradient: LinearGradient {
        LinearGradient(colors: spectrum.reversed(), startPoint: .top, endPoint: .bottom)
    }

    /// Horizontal, for bars that grow sideways.
    static var spectrumGradientAcross: LinearGradient {
        LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - Roles

    /// Loudness and classifier output — data, so it draws from the ramp.
    static let signal = spectrumCyan
    /// Something the gate caught, and the star.
    static let event = spectrumMint
    /// Semantic, and deliberately outside the ramp so a warning can never read as a
    /// measurement: dead time, flags, anything wrong.
    static let gap = Color(hex: 0xFF8A6B)

    // MARK: - The recording screen

    /// Ink for the screen you look at on the way to sleep. Cool teal, chosen over the dim
    /// red it had before. Both are defensible — red disturbs dark-adapted eyes least, teal
    /// suits the rest of the app — and this is the single token to change to go back.
    static let nightInk = Color(hex: 0x4EE0D4)
    static let nightGroundBottom = Color(hex: 0x080B1A)
    static let nightGroundTop = Color(hex: 0x131A36)
}

extension Color {
    /// Hex literals, so the palette reads as the palette rather than as thirds.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
