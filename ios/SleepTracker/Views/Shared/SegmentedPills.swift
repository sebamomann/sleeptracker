import SwiftUI

/// A segmented control that belongs to this app.
///
/// Replaces a stock `.segmented` Picker, which drew its own materials and sat in the dark UI
/// looking like a control someone forgot to style. It also let the labels drift: the filter
/// used the text characters ★ and ⚑ while the buttons it filtered used the SF Symbols
/// `star.fill` and `flag.fill` — the same two ideas drawn two different ways on one screen.
///
/// The selection is a single capsule that slides between segments via
/// `matchedGeometryEffect`, so the movement reads as one object moving rather than two
/// fading.
struct SegmentedPills<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let symbol: String?
        let label: String
        var id: Value { value }

        init(_ value: Value, symbol: String? = nil, label: String) {
            self.value = value
            self.symbol = symbol
            self.label = label
        }
    }

    let items: [Item]
    @Binding var selection: Value
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                segment(item)
            }
        }
        .padding(3)
        .background(Theme.surface1, in: Capsule())
        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }

    private func segment(_ item: Item) -> some View {
        let selected = item.value == selection
        return Button {
            withAnimation(Motion.respecting(Motion.springy)) { selection = item.value }
        } label: {
            HStack(spacing: 5) {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(item.label).font(.rowLabel)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if selected {
                    Capsule()
                        .fill(Theme.surface2)
                        .matchedGeometryEffect(id: "pill", in: indicator)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
