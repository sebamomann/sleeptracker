import SwiftUI

/// Notable sounds and pauses inside an episode.
///
/// Presented as observation rather than assessment, and says so on screen: a fan, rolling
/// over, or simply breathing quietly all look identical to a gap detector.
struct NightConcerningSection: View {
    let session: NightSession
    @ObservedObject var player: EventPlayer

    var body: some View {
        let notable = session.notableEvents
        let gaps = (session.quietGaps ?? []).sorted { $0.durationS > $1.durationS }

        if !notable.isEmpty || !gaps.isEmpty {
            SectionHeader("Worth attention")
            VStack(alignment: .leading, spacing: Layout.loose) {
                ForEach(notable) { event in
                    Button {
                        player.toggle(
                            url: SessionStore.shared.url(
                                forEvent: event,
                                in: session.id
                            ),
                            index: event.index
                        )
                    } label: {
                        entry(
                            icon: player.playingIndex == event.index
                                ? "stop.circle.fill" : "play.circle",
                            text: event.topLabel?.display ?? "Unusual sound",
                            at: event.at
                        )
                    }
                    .buttonStyle(.plain)
                }

                ForEach(gaps) { gap in
                    entry(
                        icon: "pause.circle",
                        text: "\(Int(gap.durationS))s with no breathing sound",
                        at: session.start.addingTimeInterval(gap.startS)
                    )
                }

                Text("A personal observation tool, not a medical assessment. A fan, rolling "
                    + "over, or simply breathing quietly all look like a pause from here.")
                    .font(.fine)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .card()
        }
    }

    private func entry(icon: String, text: String, at: Date) -> some View {
        HStack(spacing: Layout.loose) {
            Image(systemName: icon).foregroundStyle(Theme.gap)
            Text(text).font(.rowLabel).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(Fmt.time.string(from: at))
                .font(.rowMeta).foregroundStyle(Theme.textMuted)
        }
    }
}
