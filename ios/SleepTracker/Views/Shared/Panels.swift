import SwiftUI

struct StatTile: View {
    let label: String
    let value: String
    var note: String?
    var tint: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.metricLabel)
                .foregroundStyle(Theme.textMuted)
                .tracking(0.4)
            Text(value)
                .font(.metricValue)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.fine).foregroundStyle(Theme.textMuted).lineLimit(2)
            }
        }
        // maxHeight as well as maxWidth: a `note` that wraps to two lines was leaving that
        // tile taller than its row-mates, each with its own short card border rather than
        // a shared one — LazyVGrid sizes the row to the tallest cell, but a cell has to ask
        // to fill it, or its own background stops at its own content.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Layout.cardPadding)
        .cardSurface()
    }
}

struct Verdict: View {
    let title: String
    let detail: String
    let good: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.actionTitle)
            Text(detail).font(.actionDetail).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.gutter)
        .background(
            (good ? Theme.event : Theme.gap).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(good ? Theme.event : Theme.gap, lineWidth: 1))
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        // Uppercased and tracked rather than bold: at 11 points a heading that competes
        // with body text for weight just makes the page louder, while a quiet label with
        // air in it reads as structure.
        Text(title.uppercased())
            .font(.sectionTitle)
            .tracking(1.6)
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Layout.loose)
    }
}
