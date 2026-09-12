import SwiftUI

/// One night, read in the morning.
///
/// Ordered by what you want to know, not by what was easy to compute: a one-line summary,
/// then the few things worth hearing, then when the night was bad, then anything concerning.
/// The recorder's own diagnostics come last and collapsed — they mattered while the approach
/// was unproven, and are now only consulted when something looks wrong.
struct NightReport: View {
    /// Resolved from the store on every render rather than copied into @State: the same night
    /// is reachable from the night list and from favourites, and a star set in one place has
    /// to be visible in the other.
    private let fallback: NightSession
    @ObservedObject var store: NightsStore
    @StateObject private var player = EventPlayer()
    @State private var editing: PendingNote?
    @State private var pendingDelete: NightDeletion?
    @Environment(\.dismiss) private var dismiss

    init(session: NightSession, store: NightsStore) {
        fallback = session
        self.store = store
    }

    private var session: NightSession {
        store.session(id: fallback.id) ?? fallback
    }

    struct PendingNote: Identifiable {
        let event: NightSession.EventRecord
        var id: Int {
            event.index
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.section) {
                headline

                SectionHeader("Worth hearing")
                HighlightReel(session: session, player: player, store: store, onEditNote: edit)

                NightMarkedSection(
                    session: session,
                    player: player,
                    store: store,
                    onEditNote: edit
                )

                if session.byHour.count > 1 {
                    SectionHeader("When")
                    HourStrip(session: session)
                }

                NightConcerningSection(session: session, player: player)
                NightCompositionSection(session: session, store: store)
                NightCaptureSection(
                    session: session,
                    player: player,
                    store: store,
                    onEditNote: edit
                )
            }
            .padding(Layout.gutter)
        }
        .spectrogramGround()
        .navigationTitle(Fmt.dayTime.string(from: session.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .sheet(item: $editing) { pending in
            NoteEditor(event: pending.event, sessionID: session.id, store: store)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        pendingDelete = NightDeletion(session: session)
                    } label: {
                        Label("Delete night", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmNightDeletion($pendingDelete) { deletion in
            player.stop()
            store.delete(id: deletion.id)
            // Nothing left to show, so leave rather than sit on an empty report.
            dismiss()
        }
    }

    private func edit(_ event: NightSession.EventRecord) {
        editing = PendingNote(event: event)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(figure.value)
                    .font(.displayValue)
                    .foregroundStyle(Theme.textPrimary)
                Text(figure.unit)
                    .font(.rowLabel)
                    .foregroundStyle(Theme.textMuted)
            }
            if let rest = secondary {
                Text(rest)
                    .font(.headlineStat)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Text("\(session.wall.short) recorded · \(session.events.count) events · "
                + "\(session.keptAudio.short) kept")
                .font(.rowMeta)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The single number the screen is about. Snoring when there was any, since that is what
    /// people open this for; otherwise the event count, so an unusual night still leads with
    /// something true rather than a zero.
    private var figure: (value: String, unit: String) {
        if session.snoringSeconds >= 60 {
            return (session.snoringSeconds.short, "snoring")
        }
        if !session.events.isEmpty {
            return ("\(session.events.count)", session.events.count == 1 ? "sound" : "sounds")
        }
        return ("Quiet", "nothing crossed the gate")
    }

    /// Whatever the figure does not already say.
    private var secondary: String? {
        var parts: [String] = []
        let spoke = session.events.filter { !($0.transcript ?? "").isEmpty }.count
        if spoke > 0 {
            parts.append("\(spoke) thing\(spoke == 1 ? "" : "s") you said")
        }
        let concerns = session.notableEvents.count + (session.quietGaps?.count ?? 0)
        if concerns > 0 {
            parts.append("\(concerns) worth attention")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
