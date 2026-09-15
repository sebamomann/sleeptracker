import SwiftUI

/// One event, as it appears in a night's list, the highlight reel, and favourites.
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

    private var isPlaying: Bool { player.playingIndex == event.index }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            HStack(alignment: .top, spacing: Layout.loose) {
                // The whole left side plays. Hunting for a 17-point circle is not a thing
                // anyone should have to do to hear a four-second clip.
                HStack(alignment: .top, spacing: Layout.loose) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(event.isFlagged ? Theme.gap : Theme.event)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, isActive: isPlaying)
                    details
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { player.toggle(event, in: sessionID) }

                controls
            }

            // Notes only appear on marked events, which is why removing the last mark
            // removes the note too.
            if event.isMarked {
                noteRow
            }
        }
        .padding(.vertical, Layout.rowInsetV)
        .padding(.horizontal, Layout.rowInsetH)
        // A faint wash on whatever is playing, so the ear and the eye agree in a long list.
        .background(isPlaying ? Theme.event.opacity(0.07) : Color.clear)
        .motion(Motion.quick, value: isPlaying)
        .contextMenu {
            EventContextMenu(
                event: event,
                sessionID: sessionID,
                store: store,
                onEditNote: onEditNote
            )
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(showDate ? Fmt.dateTime.string(from: event.at)
                    : Fmt.time.string(from: event.at))
                    .font(.rowTitle)
                    .foregroundStyle(Theme.textPrimary)
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
                    .font(.explain)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(String(format: "%.1f", event.durationS))s · peak \(Int(event.peakDb)) dB")
                .font(.rowMeta)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            KindPicker(event: event, sessionID: sessionID, store: store)
            MarkButtons(event: event, sessionID: sessionID, store: store)
        }
    }

    private var noteRow: some View {
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

/// The classifier's guess, and one tap to overrule it.
///
/// This was a long-press context menu, which is too slow for something done to most rows on
/// a bad night. It reads as the current answer and behaves as a dropdown. Several can be
/// ticked, because one clip is often a fart, then heavy breathing, then rolling over — so
/// the menu stays open between ticks, and the order they are ticked in is kept.
struct KindPicker: View {
    let event: NightSession.EventRecord
    let sessionID: String
    @ObservedObject var store: NightsStore

    var body: some View {
        Menu {
            Section("It's actually — tick all you hear") {
                ForEach(SoundKind.choices) { kind in
                    Toggle(isOn: ticked(kind)) {
                        Label(kind.display, systemImage: kind.symbol)
                    }
                }
            }
            if event.kindWasCorrected {
                Button(role: .destructive) {
                    store.clearKinds(sessionID: sessionID, eventIndex: event.index)
                } label: {
                    Label("Back to the guess", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(event.kind.display)
                    .font(.rowLabel)
                    .lineLimit(1)
                if event.kinds.count > 1 {
                    Text("+\(event.kinds.count - 1)")
                        .font(.rowMeta)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(event.kind == .unclear ? Theme.textMuted : Theme.signal)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.surface2, in: Capsule())
            .contentShape(Capsule())
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(.plain)
        .accessibilityLabel(event.kindsDisplay)
        .accessibilityIdentifier("kind-picker-\(event.index)")
    }

    private func ticked(_ kind: SoundKind) -> Binding<Bool> {
        Binding(
            get: { event.correctedKinds.contains(kind) },
            set: { _ in
                store.toggleKind(sessionID: sessionID, eventIndex: event.index, kind: kind)
            }
        )
    }
}
