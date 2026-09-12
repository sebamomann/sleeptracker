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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
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
        Text(title)
            .font(.sectionTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Layout.tight)
    }
}
