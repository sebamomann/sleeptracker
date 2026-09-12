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
        .background(Theme.surface0)
        .navigationTitle(Fmt.dayTime.string(from: session.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .sheet(item: $editing) { pending in
            NoteEditor(event: pending.event, sessionID: session.id, store: store)
        }
    }

    private func edit(_ event: NightSession.EventRecord) {
        editing = PendingNote(event: event)
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            Text(summary)
                .font(.headlineStat)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(session.wall.short) recorded · \(session.events.count) events · "
                + "\(session.keptAudio.short) of audio kept")
                .font(.rowMeta)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A sentence, assembled from whatever the night actually contained — an empty night
    /// should say so rather than print a row of zeroes.
    private var summary: String {
        var parts: [String] = []
        if session.snoringSeconds >= 60 {
            parts.append("Snored \(session.snoringSeconds.short)")
        }
        let spoke = session.events.filter { !($0.transcript ?? "").isEmpty }.count
        if spoke > 0 {
            parts.append("\(spoke) thing\(spoke == 1 ? "" : "s") you said")
        }
        let concerns = session.notableEvents.count + (session.quietGaps?.count ?? 0)
        if concerns > 0 {
            parts.append("\(concerns) worth attention")
        }
        if parts.isEmpty {
            parts.append(session.events.isEmpty
                ? "A quiet night"
                : "\(session.events.count) sounds, nothing notable")
        }
        return parts.joined(separator: " · ")
    }
}
