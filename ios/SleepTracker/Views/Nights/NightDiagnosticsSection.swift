import SwiftUI

/// The night's own log, and the export.
///
/// Every lifecycle event, interruption and reset the recorder saw, in order. Collapsed: this
/// is for when a night looks wrong, not for reading every morning.
struct NightDiagnosticsSection: View {
    let session: NightSession
    @State private var expanded = false

    var body: some View {
        log
        export
    }

    @ViewBuilder
    private var log: some View {
        Button { expanded.toggle() } label: {
            HStack {
                Text("Diagnostics (\(session.marks.count))").font(.sectionTitle)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.fine)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, Layout.loose)
        }
        .buttonStyle(.plain)

        if expanded {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.marks) { mark in
                    let at = Date(timeIntervalSince1970: mark.at / 1000)
                    HStack(alignment: .top, spacing: Layout.loose) {
                        Text(Fmt.time.string(from: at))
                            .font(.rowMeta).foregroundStyle(Theme.textMuted)
                        Text(at.timeIntervalSince(session.startedAt).clock)
                            .font(.rowMeta).foregroundStyle(Theme.textMuted)
                        // Shouted marks are the ones that mean something went wrong.
                        Text(mark.what)
                            .font(.rowMeta)
                            .foregroundStyle(mark.what.uppercased() == mark.what
                                ? Theme.gap : Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
                Text("device: \(session.device.model) · iOS \(session.device.systemVersion)"
                    + " · app \(session.device.appVersion)"
                    + " · classifier labels: \(session.knownLabels?.count ?? 0)")
                    .font(.rowMeta).foregroundStyle(Theme.textMuted)
                    .padding(.top, Layout.loose)
            }
            .card()
        }
    }

    private var export: some View {
        let json = SessionStore.shared.directory(for: session.id)
            .appendingPathComponent("session.json")
        return HStack {
            ShareLink(item: json) {
                Label("Share session.json", systemImage: "square.and.arrow.up")
                    .font(.explain)
            }
            Spacer()
            Text(ByteCountFormatter.string(
                fromByteCount: SessionStore.shared.bytes(of: session.id),
                countStyle: .file
            ))
            .font(.rowMeta).foregroundStyle(Theme.textMuted)
        }
        .padding(.top, Layout.tight)
    }
}
