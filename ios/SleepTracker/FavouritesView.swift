import SwiftUI

/// Everything you marked, across every night, grouped under date headers.
///
/// Grouped rather than flat because the night is context: knowing something happened at
/// 02:14 matters less than knowing it was the night you slept badly.
struct FavouritesView: View {
    @ObservedObject var store: NightsStore
    @StateObject private var player = EventPlayer()
    @State private var filter: NightsStore.MarkFilter = .all
    @State private var editing: PendingNote?

    private struct PendingNote: Identifiable {
        let event: NightSession.EventRecord
        let sessionID: String
        var id: String { "\(sessionID)-\(event.index)" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                let groups = store.markedByNight(filter)
                VStack(alignment: .leading, spacing: 14) {
                    picker
                    if groups.isEmpty {
                        empty
                    } else {
                        ForEach(groups, id: \.night.id) { group in
                            night(group.night, events: group.events)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.surface0)
            .navigationTitle("Favourites")
            .onDisappear { player.stop() }
            .sheet(item: $editing) { p in
                NoteEditor(event: p.event, sessionID: p.sessionID, store: store)
            }
        }
    }

    private var picker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(NightsStore.MarkFilter.allCases) { f in
                Text(label(for: f)).tag(f)
            }
        }
        .pickerStyle(.segmented)
    }

    private func label(for f: NightsStore.MarkFilter) -> String {
        switch f {
        case .all:     return "All \(store.markedCount)"
        case .starred: return "★ \(store.starredCount)"
        case .flagged: return "⚑ \(store.flaggedCount)"
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(filter == .all ? "Nothing marked yet"
                                : "Nothing \(filter.rawValue.lowercased()) yet")
                .font(.subheadline.weight(.medium))
            Text("Star anything worth keeping, flag anything worth worrying about. Both show "
                 + "up here, with whatever note you left on them.")
                .font(.footnote).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private func night(_ session: NightSession,
                       events: [NightSession.EventRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.day.string(from: session.startedAt))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                NavigationLink { SessionDetailView(session: session, store: store) } label: {
                    Text("the night").font(.caption2).foregroundStyle(Theme.signal)
                }
            }
            VStack(spacing: 0) {
                ForEach(events) { e in
                    EventRow(event: e, sessionID: session.id, showDate: false,
                             player: player, store: store) { ev in
                        editing = PendingNote(event: ev, sessionID: session.id)
                    }
                    if e.index != events.last?.index { Divider().overlay(Theme.line) }
                }
            }
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}
