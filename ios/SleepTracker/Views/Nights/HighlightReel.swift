import SwiftUI

/// The main thing you read in the morning: a handful of entries that summarise the night,
/// rather than the top N decibels of it.
struct HighlightReel: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    private var files: SessionStore {
        .shared
    }

    var body: some View {
        let reel = Highlights.reel(for: session)
        VStack(spacing: 0) {
            if reel.isEmpty {
                Text("Nothing stood out. Either the night was genuinely quiet, or capture "
                    + "did not run — the dead-time tile below says which.")
                    .font(.explain).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Layout.cardPadding)
            } else {
                ForEach(Array(reel.enumerated()), id: \.element.id) { i, h in
                    row(h)
                    if i < reel.count - 1 {
                        Divider().overlay(Theme.line)
                    }
                }
            }
        }
        .cardSurface()
    }

    @ViewBuilder
    private func row(_ h: Highlight) -> some View {
        let playable = h.event.map { files.url(forEvent: $0, in: session.id) }
        Button {
            if let event = h.event {
                player.toggle(event, in: session.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                icon(h)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(h.headline)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let e = h.event {
                            Text(Fmt.time.string(from: e.at))
                                .font(.rowMeta)
                            Text("·").font(.fine).foregroundStyle(Theme.textMuted)
                            Text("\(String(format: "%.1f", e.durationS))s")
                                .font(.rowMeta)
                        }
                        Text(h.caption).font(.fine)
                    }
                    .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 4)

                // Marking belongs here: this is the screen where you actually listen, so it
                // is where you decide something is worth keeping.
                if let e = h.event {
                    MarkButtons(event: e, sessionID: session.id, store: store)
                }
            }
            .padding(.vertical, 11).padding(.horizontal, 13)
        }
        .buttonStyle(.plain)
        .disabled(playable == nil)
        .contextMenu {
            if let e = h.event {
                Button { onEditNote(e) } label: {
                    Label(
                        e.note == nil ? "Add note" : "Edit note",
                        systemImage: "square.and.pencil"
                    )
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
            playIcon(
                playing ? "stop.circle.fill" : "exclamationmark.circle",
                tint: Theme.gap,
                playing: playing
            )
        case .spoken:
            playIcon(
                playing ? "stop.circle.fill" : "text.quote",
                tint: Theme.signal,
                playing: playing
            )
        default:
            playIcon(
                playing ? "stop.circle.fill" : "play.circle",
                tint: Theme.event,
                playing: playing
            )
        }
    }

    private func playIcon(_ name: String, tint: Color, playing: Bool) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: playing)
    }
}
