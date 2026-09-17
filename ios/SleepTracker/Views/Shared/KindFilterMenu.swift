import SwiftUI

/// Narrow a list of events by kind of sound. Stays open while kinds are ticked, like
/// `KindPicker`, since filtering to three kinds should not take three trips into a menu.
struct KindFilterMenu: View {
    @Binding var filter: KindFilter
    /// The events being filtered, so the menu offers only kinds that occur, with counts.
    let events: [NightSession.EventRecord]

    var body: some View {
        Menu {
            Picker("Mode", selection: $filter.mode) {
                ForEach(KindFilter.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Section {
                ForEach(offered, id: \.kind) { entry in
                    Toggle(isOn: ticked(entry.kind)) {
                        Label(
                            "\(entry.kind.display) (\(entry.count))",
                            systemImage: entry.kind.symbol
                        )
                    }
                }
            }

            if filter.isActive {
                Button {
                    filter.kinds = []
                } label: {
                    Label("Show everything", systemImage: "xmark.circle")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                Text(filter.summary)
                    .lineLimit(1)
            }
            .font(.rowLabel)
            .foregroundStyle(filter.isActive ? Theme.signal : Theme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface2, in: Capsule())
            .contentShape(Capsule())
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(.plain)
        .accessibilityIdentifier("kind-filter")
    }

    /// Kinds present in the list, plus any still ticked that no longer are — otherwise a
    /// kind could be filtered on with no way to untick it.
    private var offered: [(kind: SoundKind, count: Int)] {
        var counts: [SoundKind: Int] = [:]
        for event in events {
            for kind in event.kinds {
                counts[kind, default: 0] += 1
            }
        }
        return SoundKind.allCases
            .filter { counts[$0] != nil || filter.kinds.contains($0) }
            .map { ($0, counts[$0] ?? 0) }
            .sorted { $0.kind.display < $1.kind.display }
    }

    private func ticked(_ kind: SoundKind) -> Binding<Bool> {
        Binding(
            get: { filter.kinds.contains(kind) },
            set: { _ in filter.toggle(kind) }
        )
    }
}
