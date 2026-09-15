import SwiftUI

/// Re-run the classifier, and clear out what turned out to be nothing.
///
/// A real night produced 102 events of which most were rustles and room tone, labelled
/// `music` because that is what the classifier reaches for when a clip says little. The
/// gate now rejects those as they happen; this is how a night recorded before that gets
/// cleaned, and how any night gets a second opinion after the rules change.
struct NightTidySection: View {
    let session: NightSession
    @ObservedObject var store: NightsStore

    @State private var working: String?
    @State private var confirmingDrop = false

    var body: some View {
        let empty = session.emptyLookingEvents
        if !session.events.isEmpty {
            SectionHeader("Tidy up")
            VStack(alignment: .leading, spacing: Layout.loose) {
                Text(summary(emptyCount: empty.count))
                    .font(.explain)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let working {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(working).font(.rowLabel).foregroundStyle(Theme.textMuted)
                    }
                } else {
                    HStack(spacing: Layout.cardPadding) {
                        Button("Re-classify all \(session.events.count)") { reclassify() }
                            .font(.rowLabel)
                        if !empty.isEmpty {
                            Button("Delete \(empty.count)", role: .destructive) {
                                confirmingDrop = true
                            }
                            .font(.rowLabel)
                        }
                    }
                }
            }
            .card()
            .confirmationDialog(
                "Delete \(empty.count) events that look like nothing?",
                isPresented: $confirmingDrop, titleVisibility: .visible
            ) {
                Button("Delete them", role: .destructive) { drop(empty) }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(dropMessage(empty))
            }
        }
    }

    /// Why, tallied: "3 too quiet to hear · 2 unrecognised". `Relevance.reason` already
    /// exists for exactly this, and was going unused — the dialog only named a count.
    private func dropMessage(_ events: [NightSession.EventRecord]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for event in events {
            let reason = Relevance.reason(event)
            if counts[reason] == nil {
                order.append(reason)
            }
            counts[reason, default: 0] += 1
        }
        let breakdown = order.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: " · ")

        return (breakdown.isEmpty ? "" : "\(breakdown). ")
            + "Anything starred, flagged, transcribed, or recognised as snoring, speech or "
            + "coughing is kept. This cannot be undone."
    }

    private func summary(emptyCount: Int) -> String {
        guard emptyCount > 0 else {
            return "Every event here looks like something. Percentages beside a label are how "
                + "sure the classifier is, not how loud the sound was."
        }
        return "\(emptyCount) of \(session.events.count) look like nothing — too quiet to hear, "
            + "unrecognised, or labelled with one of the classifier's catch-alls. "
            + "Percentages beside a label are how sure it is."
    }

    private func reclassify() {
        working = "Re-classifying…"
        Task {
            await store.reclassify(
                sessionID: session.id, events: session.events, refreshKnownLabels: true
            )
            working = nil
        }
    }

    private func drop(_ events: [NightSession.EventRecord]) {
        withAnimation(Motion.respecting(Motion.standard)) {
            store.deleteEvents(
                sessionID: session.id,
                indices: Set(events.map(\.index))
            )
        }
    }
}
