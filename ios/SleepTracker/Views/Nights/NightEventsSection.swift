import SwiftUI

/// Every sound the night kept, narrowed by kind when a whole night is too much to scroll.
struct NightEventsSection: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer
    @ObservedObject var store: NightsStore
    var onEditNote: (NightSession.EventRecord) -> Void

    @State private var filter = KindFilter()

    var body: some View {
        let shown = session.events.filter(filter.matches)

        if !session.events.isEmpty {
            SectionHeader(filter.isActive
                ? "Every sound (\(shown.count) of \(session.events.count))"
                : "Every sound (\(session.events.count))")
                .accessibilityIdentifier("every-sound-header")
            KindFilterMenu(filter: $filter, events: session.events)

            if shown.isEmpty {
                Text("Nothing matches. Tick fewer kinds, or show everything.")
                    .font(.explain).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .card()
            } else {
                EventList(
                    events: shown,
                    sessionID: session.id,
                    player: player,
                    store: store,
                    onEditNote: onEditNote
                )
                // The same event can also be in the reel or the marked list above, so tests
                // look for its controls inside this list specifically.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("every-sound")
                .motion(Motion.standard, value: filter)
            }
        }
    }
}
