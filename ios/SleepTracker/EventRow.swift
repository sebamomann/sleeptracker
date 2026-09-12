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

    private var isPlaying: Bool { player.playingIndex == event.index }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    player.toggle(url: SessionStore.shared.url(forEvent: event, in: sessionID),
                                  index: event.index)
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(event.isFlagged ? Theme.gap : Theme.event)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(showDate ? Self.dateTime.string(from: event.at)
                                      : Self.timeOnly.string(from: event.at))
                            .font(.callout.monospaced())
                            .foregroundStyle(Theme.textPrimary)
                        if let l = event.topLabel {
                            Text(l.display)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.signal)
                            Text("\(Int(l.confidence * 100))%")
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textMuted)
                        }
                    }

                    if let t = event.transcript, !t.isEmpty {
                        Text("“\(t)”")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("\(String(format: "%.1f", event.durationS))s · peak \(Int(event.peakDb)) dB")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textMuted)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    mark(systemName: event.isStarred ? "star.fill" : "star",
                         active: event.isStarred, tint: Theme.signal) {
                        store.toggleStar(sessionID: sessionID, eventIndex: event.index)
                    }
                    mark(systemName: event.isFlagged ? "flag.fill" : "flag",
                         active: event.isFlagged, tint: Theme.gap) {
                        store.toggleFlag(sessionID: sessionID, eventIndex: event.index)
                    }
                }
            }

            // Notes only appear on marked events, which is why removing the last mark
            // removes the note too.
            if event.isMarked {
                Button { onEditNote(event) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: event.note == nil ? "square.and.pencil" : "text.bubble")
                            .font(.caption2)
                        Text(event.note ?? "Add a note")
                            .font(.caption2)
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
            Button {
                store.toggleStar(sessionID: sessionID, eventIndex: event.index)
            } label: {
                Label(event.isStarred ? "Remove star" : "Star", systemImage: "star")
            }
            Button {
                store.toggleFlag(sessionID: sessionID, eventIndex: event.index)
            } label: {
                Label(event.isFlagged ? "Remove flag" : "Flag", systemImage: "flag")
            }
            Button { onEditNote(event) } label: {
                Label(event.note == nil ? "Add note" : "Edit note", systemImage: "square.and.pencil")
            }
            ShareLink(item: SessionStore.shared.url(forEvent: event, in: sessionID)) {
                Label("Share clip", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func mark(systemName: String, active: Bool, tint: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.footnote)
                .foregroundStyle(active ? tint : Theme.textMuted.opacity(0.6))
                // A bigger hit area than the glyph: these are small targets reached with a
                // thumb, often first thing in the morning.
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let timeOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm:ss"; return f
    }()
}

/// Sheet for writing the note on a marked event.
struct NoteEditor: View {
    let event: NightSession.EventRecord
    let sessionID: String
    @ObservedObject var store: NightsStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(event: NightSession.EventRecord, sessionID: String, store: NightsStore) {
        self.event = event
        self.sessionID = sessionID
        self.store = store
        _text = State(initialValue: event.note ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(Self.when.string(from: event.at)
                     + (event.topLabel.map { " · \($0.display)" } ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textMuted)

                if let t = event.transcript, !t.isEmpty {
                    Text("“\(t)”").font(.callout).foregroundStyle(Theme.textSecondary)
                }

                TextField("What about this?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(3...8)
                    .padding(12)
                    .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
                    .focused($focused)

                Spacer()
            }
            .padding(18)
            .background(Theme.surface0)
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setNote(sessionID: sessionID, eventIndex: event.index, note: text)
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private static let when: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm:ss"; return f
    }()
}
