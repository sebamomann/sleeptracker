import SwiftUI

/// What the night was made of, by the classifier's best label.
struct NightCompositionSection: View {
    let session: NightSession
    @ObservedObject var store: NightsStore
    @State private var classifying = false

    var body: some View {
        let breakdown = session.byLabel
        let unlabelled = session.unlabelledEvents

        if !breakdown.isEmpty || !unlabelled.isEmpty {
            SectionHeader("What it heard")
            VStack(alignment: .leading, spacing: Layout.loose) {
                if breakdown.isEmpty {
                    Text("Nothing is labelled yet.")
                        .font(.explain).foregroundStyle(Theme.textMuted)
                } else {
                    let longest = breakdown.first?.seconds ?? 1
                    ForEach(breakdown) { row in
                        bar(row, relativeTo: longest)
                    }
                }

                if !unlabelled.isEmpty {
                    Divider().overlay(Theme.line)
                    classifyButton(unlabelled)
                }
            }
            .card()
        }
    }

    private func bar(_ row: LabelTally, relativeTo longest: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.display).font(.rowLabel)
                Spacer()
                Text("\(row.count) · \(row.seconds.short)")
                    .font(.rowMeta).foregroundStyle(Theme.textMuted)
            }
            // Bar length is time, not count: forty one-second ticks matter less than four
            // thirty-second episodes.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.spectrumGradientAcross)
                    .frame(width: max(3, geo.size.width * row.seconds / longest))
            }
            .frame(height: 5)
        }
    }

    private func classifyButton(_ pending: [NightSession.EventRecord]) -> some View {
        Button { classifyMissing(pending) } label: {
            HStack(spacing: 7) {
                if classifying {
                    ProgressView().controlSize(.mini)
                }
                Text(classifying
                    ? "Classifying…"
                    : "Classify \(pending.count) unlabelled event\(pending.count == 1 ? "" : "s")")
                    .font(.rowLabel)
            }
        }
        .disabled(classifying)
    }

    /// Label events recorded before classification existed, or missed at the time.
    private func classifyMissing(_ pending: [NightSession.EventRecord]) {
        classifying = true
        let id = session.id
        let files = SessionStore.shared
        let nights = store

        Task.detached(priority: .utility) {
            var labelled: [Int: [SoundLabel]] = [:]
            for event in pending {
                let labels = EventClassifier.shared
                    .classify(url: files.url(forEvent: event, in: id))
                if !labels.isEmpty {
                    labelled[event.index] = labels
                }
            }
            // Frozen before crossing to the main actor: a var captured by a concurrently
            // executing closure is a data race, and an error under Swift 6.
            let results = labelled
            await MainActor.run {
                nights.update(id: id) { session in
                    for (index, labels) in results {
                        if let i = session.events.firstIndex(where: { $0.index == index }) {
                            session.events[i].labels = labels
                        }
                    }
                    if session.knownLabels == nil {
                        session.knownLabels = EventClassifier.shared.knownLabels
                    }
                }
                classifying = false
            }
        }
    }
}
