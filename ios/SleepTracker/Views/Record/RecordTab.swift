import SwiftUI

/// Where a night is started, and a look back at the last one. Everything you'd only touch
/// occasionally — sensitivity, the listening delay, teaching the classifier, the bedtime
/// reminder — lives in `SettingsView` instead, a tap away rather than in the way.
struct RecordTab: View {
    @ObservedObject var recorder: NightRecorder
    @ObservedObject var nights: NightsStore
    var openNights: () -> Void

    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button { recorder.start() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.circle.fill").font(.title2)
                            Text("Start recording").font(.actionTitle)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Start it, lock the phone, leave it on a charger. Everything stays "
                        + "on this device.")
                        .font(.explain).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = recorder.lastError {
                        Text(err)
                            .font(.rowMeta).foregroundStyle(Theme.gap)
                            .padding(Layout.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Theme.gap.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                    }

                    if let last = nights.sessions.first {
                        SectionHeader("Last night")
                        Button(action: openNights) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Fmt.dayTime.string(from: last.startedAt))
                                    .font(.rowTitle)
                                Text("\(last.wall.short) · \(last.events.count) events"
                                    + (last.snoringSeconds >= 60
                                        ? " · snored \(last.snoringSeconds.short)" : ""))
                                    .font(.rowMeta)
                                    .foregroundStyle(Theme.textMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Layout.cardPadding)
                            .cardSurface()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Layout.gutter)
            }
            .spectrogramGround()
            .navigationTitle("Sleeptracker")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings-button")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(recorder: recorder, nights: nights)
        }
    }
}
