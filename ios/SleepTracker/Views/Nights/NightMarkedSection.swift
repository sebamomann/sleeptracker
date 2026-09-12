import SwiftUI

/// What you starred or flagged in this night. The same events also appear in the Favourites
/// tab, across every night.
struct NightMarkedSection: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    var body: some View {
        let marked = session.markedEvents
        if !marked.isEmpty {
            SectionHeader("Marked (\(marked.count))")
            EventList(
                events: marked,
                sessionID: session.id,
                player: player,
                store: store,
                onEditNote: onEditNote
            )
        }
    }
}

/// A card of event rows, divided. Used wherever events are listed.
struct EventList: View {
    let events: [NightSession.EventRecord]
    let sessionID: String
    var showDate = false
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                EventRow(
                    event: event,
                    sessionID: sessionID,
                    showDate: showDate,
                    player: player,
                    store: store,
                    onEditNote: onEditNote
                )
                if event.index != events.last?.index {
                    Divider().overlay(Theme.line)
                }
            }
        }
        .card(padding: 0)
    }
}
