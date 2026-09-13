import SwiftUI

/// One event, as it appears in a night's list, the highlight reel, and the favourites view.
///
/// The three differ only in whether the date is needed, so they share this rather than
/// drifting apart — starring from one screen and not another would be worse than no
/// starring.
struct EventRow: View {
    let event: NightSession.EventRecord
    let sessionID: String
    var showDate = false
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    private var isPlaying: Bool {
        player.playingIndex == event.index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    player.toggle(event, in: sessionID)
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(event.isFlagged ? Theme.gap : Theme.event)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: isPlaying)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(showDate ? Fmt.dateTime.string(from: event.at)
                            : Fmt.time.string(from: event.at))
                            .font(.rowTitle)
                            .foregroundStyle(Theme.textPrimary)
                        Text(event.kind.display)
                            .font(.rowLabel)
                            .foregroundStyle(event.kind == .unclear
                                ? Theme.textMuted : Theme.signal)
                        if event.kindWasCorrected {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.event)
                        } else if let label = event.topLabel, event.kind != .unclear {
                            Text("\(Int(label.confidence * 100))% sure")
                                .font(.rowMeta)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }

                    if let transcript = event.transcript, !transcript.isEmpty {
                        Text("“\(transcript)”")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(
                        "\(String(format: "%.1f", event.durationS))s · peak \(Int(event.peakDb)) dB"
                    )
                    .font(.rowMeta)
                    .foregroundStyle(Theme.textMuted)
                }

                Spacer(minLength: 4)

                MarkButtons(event: event, sessionID: sessionID, store: store)
            }

            // Notes only appear on marked events, which is why removing the last mark
            // removes the note too.
            if event.isMarked {
                Button { onEditNote(event) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: event.note == nil ? "square.and.pencil" : "text.bubble")
                            .font(.fine)
                        Text(event.note ?? "Add a note")
                            .font(.fine)
                            .italic(event.note == nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(event.note == nil ? Theme.textMuted : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .contextMenu {
            EventContextMenu(
                event: event,
                sessionID: sessionID,
                store: store,
                onEditNote: onEditNote
            )
        }
    }
}
