import SwiftUI

/// One scale for the whole app.
///
/// Before this, card padding was 12, 13, 14 or 16 depending on the file and corner radii
/// were 8, 10 or 12 — differences nobody chose, which read as sloppiness rather than
/// hierarchy. Everything spatial comes from here now.
enum Layout {
    /// Screen edge inset.
    static let gutter: CGFloat = 16
    /// Between top-level sections.
    static let section: CGFloat = 14
    /// Inside a card.
    static let cardPadding: CGFloat = 14
    /// Between lines within one item.
    static let tight: CGFloat = 4
    /// Between grouped items.
    static let loose: CGFloat = 8

    /// Near-square. The Spectrogram direction leans on hairlines rather than pills.
    static let cardRadius: CGFloat = 5
    static let rowInsetV: CGFloat = 10
    static let rowInsetH: CGFloat = 13

    /// Minimum tap target. Star and flag are small glyphs reached with a thumb, often first
    /// thing in the morning, so the target is deliberately larger than the icon.
    static let hitTarget: CGFloat = 34
}

extension View {
    /// The app's one surface: a bordered panel on the background. Use this directly when the
    /// contents manage their own insets, such as a list of rows.
    func cardSurface() -> some View {
        background(Theme.surface1, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Layout.cardRadius)
                .stroke(Theme.line, lineWidth: 1))
    }

    /// A panel with the standard padding, filling the available width.
    func card(padding: CGFloat = Layout.cardPadding) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}
