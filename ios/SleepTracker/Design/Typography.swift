import SwiftUI

/// Semantic text roles, on a scale with actual contrast.
///
/// The app previously ran on six sizes between 11 and 20 points, so a section heading, a row
/// title and a timestamp all read at about the same importance and nothing led. This scale
/// opens a gap at the top and turns headings into quiet tracked eyebrows, which leaves one
/// figure per screen as the thing your eye lands on first.
extension Font {
    /// The one figure a screen is about. Condensed, so a large number does not dominate the
    /// width it sits in.
    static let displayValue = Font.system(size: 38, weight: .semibold).width(.condensed)
    /// The sentence beside or below the display figure.
    static let headlineStat = Font.system(size: 22, weight: .semibold)

    /// Section heading. Small, tracked and muted — set with `SectionHeader`, which applies
    /// the uppercasing and letter-spacing this size needs.
    static let sectionTitle = Font.system(size: 11, weight: .medium)

    /// A metric in a tile.
    static let metricValue = Font.system(size: 24, weight: .semibold).width(.condensed)
    /// The label above a metric.
    static let metricLabel = Font.system(size: 10, weight: .medium)

    /// Primary text in a row — timestamps included, hence the fixed-width digits.
    static let rowTitle = Font.system(size: 15, weight: .medium).monospacedDigit()
    /// A classifier label or other emphasised inline word.
    static let rowLabel = Font.system(size: 12.5, weight: .medium)
    /// Figures under a row title.
    static let rowMeta = Font.system(size: 11).monospaced()
    /// Explanatory prose: captions, disclaimers, empty states.
    static let explain = Font.system(size: 12.5)
    /// The smallest supporting text.
    static let fine = Font.system(size: 11)
}
