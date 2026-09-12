import SwiftUI

/// Semantic text roles, so a "row title" looks the same in every list.
///
/// Deliberately named for their job rather than their size: the previous code picked from
/// `.caption`, `.caption2`, `.footnote` and `.callout` per call site, so equivalent things
/// ended up different sizes in different views.
extension Font {
    /// The one number a screen is about.
    static let metricValue = Font.system(.title3, design: .rounded).weight(.semibold)
    /// The label above or below a metric.
    static let metricLabel = Font.caption2.weight(.medium)

    /// Section heading within a scroll view.
    static let sectionTitle = Font.subheadline.weight(.semibold)
    /// A summary sentence at the top of a screen.
    static let headlineStat = Font.title3.weight(.semibold)

    /// Primary text in a list row — timestamps and the like, so monospaced.
    static let rowTitle = Font.callout.monospaced()
    /// A classifier label or other emphasised inline word.
    static let rowLabel = Font.caption.weight(.medium)
    /// Figures under a row title.
    static let rowMeta = Font.caption2.monospaced()
    /// Explanatory prose: captions, disclaimers, empty states.
    static let explain = Font.footnote
    /// The smallest supporting text.
    static let fine = Font.caption2
}
