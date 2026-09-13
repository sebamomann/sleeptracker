import SwiftUI

/// Star and flag, as a pair.
///
/// These existed twice — once in the event row, once in the highlight reel — with the same
/// glyphs, colours and hit areas written out separately. Two copies of a control is two
/// places for it to drift.
struct MarkButtons: View {
    let event: NightSession.EventRecord
    let sessionID: String
    @ObservedObject var store: NightsStore

    var body: some View {
        HStack(spacing: 2) {
            button(
                filled: "star.fill",
                empty: "star",
                active: event.isStarred,
                tint: Theme.signal
            ) {
                store.toggleStar(sessionID: sessionID, eventIndex: event.index)
            }
            button(
                filled: "flag.fill",
                empty: "flag",
                active: event.isFlagged,
                tint: Theme.gap
            ) {
                store.toggleFlag(sessionID: sessionID, eventIndex: event.index)
            }
        }
    }

    private func button(
        filled: String,
        empty: String,
        active: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: active ? filled : empty)
                .font(.footnote)
                .foregroundStyle(active ? tint : Theme.textMuted.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: active)
                .scaleEffect(active ? 1.1 : 1)
                .animation(Motion.respecting(Motion.springy), value: active)
                // A target larger than the glyph: these are reached with a thumb, often
                // first thing in the morning.
                .frame(width: Layout.hitTarget, height: Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The star/flag/note actions, as a context menu. Shared so a long press does the same thing
/// wherever an event appears.
struct EventContextMenu: View {
    let event: NightSession.EventRecord
    let sessionID: String
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    var body: some View {
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
        // Correcting by ear is the only reliable label there is, and every correction is
        // one more example a model of your own could be trained on.
        Menu {
            ForEach(SoundKind.choices) { kind in
                Button {
                    store.setKind(sessionID: sessionID, eventIndex: event.index, kind: kind)
                } label: {
                    Label(kind.display, systemImage: kind.symbol)
                }
            }
            if event.kindWasCorrected {
                Divider()
                Button(role: .destructive) {
                    store.setKind(sessionID: sessionID, eventIndex: event.index, kind: nil)
                } label: {
                    Label("Clear correction", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            Label("It's actually…", systemImage: "tag")
        }
        ShareLink(item: SessionStore.shared.url(forEvent: event, in: sessionID)) {
            Label("Share clip", systemImage: "square.and.arrow.up")
        }
    }
}
