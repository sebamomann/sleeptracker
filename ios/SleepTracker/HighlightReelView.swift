import SwiftUI

/// The main thing you read in the morning: a handful of entries that summarise the night,
/// rather than the top N decibels of it.
struct HighlightReelView: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer

    private var store: SessionStore { .shared }

    var body: some View {
        let reel = Highlights.reel(for: session)
        VStack(spacing: 0) {
            if reel.isEmpty {
                Text("Nothing stood out. Either the night was genuinely quiet, or capture "
                     + "did not run — the dead-time tile below says which.")
                    .font(.footnote).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ForEach(Array(reel.enumerated()), id: \.element.id) { i, h in
                    row(h)
                    if i < reel.count - 1 { Divider().overlay(Theme.line) }
                }
            }
        }
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func row(_ h: Highlight) -> some View {
        let playable = h.event.map { store.url(forEvent: $0, in: session.id) }
        Button {
            if let url = playable, let e = h.event { player.toggle(url: url, index: e.index) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                icon(h)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(h.headline)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let e = h.event {
                            Text(Self.time.string(from: e.at))
                                .font(.caption2.monospaced())
                            Text("·").font(.caption2).foregroundStyle(Theme.textMuted)
                            Text("\(String(format: "%.1f", e.durationS))s")
                                .font(.caption2.monospaced())
                        }
                        Text(h.caption).font(.caption2)
                    }
                    .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 11).padding(.horizontal, 13)
        }
        .buttonStyle(.plain)
        .disabled(playable == nil)
    }

    @ViewBuilder
    private func icon(_ h: Highlight) -> some View {
        let playing = h.event.map { player.playingIndex == $0.index } ?? false
        switch h.reason {
        case .pause:
            Image(systemName: "pause.circle").font(.title3).foregroundStyle(Theme.gap)
        case .notable:
            Image(systemName: playing ? "stop.circle.fill" : "exclamationmark.circle")
                .font(.title3).foregroundStyle(Theme.gap)
        case .spoken:
            Image(systemName: playing ? "stop.circle.fill" : "text.quote")
                .font(.title3).foregroundStyle(Theme.signal)
        default:
            Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                .font(.title3).foregroundStyle(Theme.event)
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
