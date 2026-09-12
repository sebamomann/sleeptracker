import SwiftUI

/// The main thing you read in the morning: a handful of entries that summarise the night,
/// rather than the top N decibels of it.
struct HighlightReelView: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    private var files: SessionStore { .shared }

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
        let playable = h.event.map { files.url(forEvent: $0, in: session.id) }
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

                // Marking belongs here: this is the screen where you actually listen, so it
                // is where you decide something is worth keeping.
                if let e = h.event {
                    HStack(spacing: 2) {
                        Button {
                            store.toggleStar(sessionID: session.id, eventIndex: e.index)
                        } label: {
                            Image(systemName: e.isStarred ? "star.fill" : "star")
                                .font(.footnote)
                                .foregroundStyle(e.isStarred ? Theme.signal
                                                            : Theme.textMuted.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            store.toggleFlag(sessionID: session.id, eventIndex: e.index)
                        } label: {
                            Image(systemName: e.isFlagged ? "flag.fill" : "flag")
                                .font(.footnote)
                                .foregroundStyle(e.isFlagged ? Theme.gap
                                                            : Theme.textMuted.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 11).padding(.horizontal, 13)
        }
        .buttonStyle(.plain)
        .disabled(playable == nil)
        .contextMenu {
            if let e = h.event {
                Button { onEditNote(e) } label: {
                    Label(e.note == nil ? "Add note" : "Edit note",
                          systemImage: "square.and.pencil")
                }
                ShareLink(item: files.url(forEvent: e, in: session.id)) {
                    Label("Share clip", systemImage: "square.and.arrow.up")
                }
            }
        }
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
