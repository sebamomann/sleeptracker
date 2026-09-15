import SwiftUI

/// Corrections gathered so far, and the way out to Create ML.
///
/// Apple's classifier is general-purpose and trained on ordinary listening levels. A night
/// recording is quiet, close and mostly breathing, so it falls back on whichever class
/// attracts most — which is why a real night came back mostly as `music`. The fix is not a
/// better threshold; it is a model that has heard this room.
struct TrainingCard: View {
    @ObservedObject var store: NightsStore
    @State private var exported: TrainingExport.Result?
    @State private var failure: String?

    var body: some View {
        let taught = store.sessions.flatMap(\.taughtEvents)
        // Only single-sound clips train a classifier; see `TrainingExport`.
        let single = taught.filter { $0.correctedKinds.count == 1 }
        let mixed = taught.count - single.count
        let byKind = Dictionary(grouping: single) { $0.kind }

        VStack(alignment: .leading, spacing: Layout.loose) {
            Text(taught.isEmpty
                ? "Tap the sound's name on any event to correct it. Each "
                + "correction is a labelled example — enough of them and a model trained "
                + "on your own nights can replace the general one."
                : "\(taught.count) clip\(taught.count == 1 ? "" : "s") corrected by ear.")
                .font(.explain)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !byKind.isEmpty {
                FlowTags(tags: SoundKind.choices.compactMap { kind in
                    let count = byKind[kind]?.count ?? 0
                    return count > 0 ? "\(kind.display) \(count)" : nil
                })
            }

            if mixed > 0 {
                Text("\(mixed) hold\(mixed == 1 ? "s" : "") more than one sound and won't be "
                    + "exported — a classifier learns one sound per clip.")
                    .font(.fine)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let exported {
                Text("Wrote \(exported.clips) clips to Files › SleepTracker › training. "
                    + "Open that folder in Create ML's Sound Classification template.")
                    .font(.fine)
                    .foregroundStyle(Theme.event)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure {
                Text(failure).font(.fine).foregroundStyle(Theme.gap)
            }

            if !single.isEmpty {
                Button("Export \(single.count) for training") { export() }
                    .font(.rowLabel)
            }
        }
        .card()
    }

    private func export() {
        do {
            exported = try TrainingExport.write(from: store.sessions)
            failure = nil
        } catch {
            failure = "Could not write the folder: \(error.localizedDescription)"
        }
    }
}

/// Small wrapping tag row. Counts per class need to wrap on a phone, and an HStack clips.
struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(tags)
            VStack(alignment: .leading, spacing: 5) {
                row(Array(tags.prefix((tags.count + 1) / 2)))
                row(Array(tags.dropFirst((tags.count + 1) / 2)))
            }
        }
    }

    private func row(_ items: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(items, id: \.self) { tag in
                Text(tag)
                    .font(.fine)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surface2, in: Capsule())
            }
        }
    }
}
