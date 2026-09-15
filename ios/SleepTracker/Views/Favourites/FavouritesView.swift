import SwiftUI

/// Everything you marked, across every night, grouped under date headers.
///
/// Grouped rather than flat because the night is context: knowing something happened at
/// 02:14 matters less than knowing it was the night you slept badly.
struct FavouritesView: View {
    @ObservedObject var store: NightsStore
    @StateObject private var player = EventPlayer()
    @State private var filter: NightsStore.MarkFilter = .all
    @State private var kinds = KindFilter()
    @State private var editing: PendingNote?

    private struct PendingNote: Identifiable {
        let event: NightSession.EventRecord
        let sessionID: String
        var id: String {
            "\(sessionID)-\(event.index)"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let marked = store.markedByNight(filter)
                let groups = marked
                    .map { (night: $0.night, events: $0.events.filter(kinds.matches)) }
                    .filter { !$0.events.isEmpty }
                VStack(alignment: .leading, spacing: 14) {
                    picker
                    KindFilterMenu(filter: $kinds, events: marked.flatMap(\.events))
                    if groups.isEmpty {
                        empty
                    } else {
                        ForEach(groups, id: \.night.id) { group in
                            night(group.night, events: group.events)
                        }
                    }
                }
                .padding(Layout.gutter)
                .motion(Motion.standard, value: filter)
                .motion(Motion.standard, value: kinds)
                .motion(Motion.standard, value: store.markedCount)
            }
            .spectrogramGround()
            .navigationTitle("Favourites")
            .onDisappear { player.stop() }
            .sheet(item: $editing) { pending in
                NoteEditor(event: pending.event, sessionID: pending.sessionID, store: store)
            }
        }
    }

    private var picker: some View {
        SegmentedPills(
            items: [
                .init(.all, label: "All \(store.markedCount)"),
                .init(.starred, symbol: "star.fill", label: "\(store.starredCount)"),
                .init(.flagged, symbol: "flag.fill", label: "\(store.flaggedCount)")
            ],
            selection: $filter
        )
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kinds.isActive ? "Nothing marked matches"
                : filter == .all ? "Nothing marked yet"
                : "Nothing \(filter.rawValue.lowercased()) yet")
                .font(.subheadline.weight(.medium))
            Text("Star anything worth keeping, flag anything worth worrying about. Both show "
                + "up here, with whatever note you left on them.")
                .font(.explain).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Layout.gutter)
        .cardSurface()
    }

    private func night(
        _ session: NightSession,
        events: [NightSession.EventRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Fmt.day.string(from: session.startedAt))
                    .font(.sectionTitle)
                Spacer()
                NavigationLink { NightReport(session: session, store: store) } label: {
                    Text("the night").font(.fine).foregroundStyle(Theme.signal)
                }
            }
            VStack(spacing: 0) {
                ForEach(events) { e in
                    EventRow(
                        event: e,
                        sessionID: session.id,
                        showDate: false,
                        player: player,
                        store: store
                    ) { ev in
                        editing = PendingNote(event: ev, sessionID: session.id)
                    }
                    if e.index != events.last?.index {
                        Divider().overlay(Theme.line)
                    }
                }
            }
            .cardSurface()
        }
    }
}
