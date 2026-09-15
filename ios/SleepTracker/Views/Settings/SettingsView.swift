import SwiftUI

/// Everything you set up once and rarely revisit: how long to wait before listening, what
/// the gate has learned about the room, teaching the classifier, and the bedtime reminder.
///
/// Split out of the Record tab, which used to carry all of this above the fold along with
/// the one button that matters at bedtime. A sheet rather than a fourth tab: these are
/// occasional visits, not a place you read every morning.
struct SettingsView: View {
    @ObservedObject var recorder: NightRecorder
    @ObservedObject var nights: NightsStore
    @Environment(\.dismiss) private var dismiss

    @State private var delayMinutes = ListeningDelay.minutes
    @State private var reminderOn = StartReminder.isEnabled
    @State private var reminderTime = Calendar.current.date(from: StartReminder.time) ?? Date()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Before it starts")
                    delayRow

                    SectionHeader("Sensitivity")
                    SensitivityCard()

                    SectionHeader("Teach it")
                    TrainingCard(store: nights)

                    SectionHeader("Reminder")
                    reminderRow
                }
                .padding(Layout.gutter)
            }
            .spectrogramGround()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Falling asleep is not the night. How long that takes is yours to say.
    private var delayRow: some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            Picker(selection: $delayMinutes) {
                ForEach(ListeningDelay.choices, id: \.self) { minutes in
                    Text(ListeningDelay.label(minutes)).tag(minutes)
                }
            } label: {
                Text("Start keeping sounds").font(.actionDetail)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("delay-picker")
            .onChange(of: delayMinutes) { _, minutes in ListeningDelay.minutes = minutes }

            Text(delayMinutes == 0
                ? "Everything from the moment you press start is kept."
                : "The first \(delayMinutes) minutes — getting into bed, falling asleep — are "
                + "not kept, and the night's report begins after them.")
                .font(.fine).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Layout.cardPadding)
        .cardSurface()
    }

    /// "Manual, but warn me": recording never starts on its own, but a forgotten night gets
    /// a nudge at the hour you choose.
    private var reminderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $reminderOn) {
                Text("Remind me at bedtime").font(.actionDetail)
            }
            .onChange(of: reminderOn) { _, on in
                StartReminder.isEnabled = on
                guard on else { StartReminder.reschedule(); return }
                Task {
                    if await StartReminder.requestAuthorization() {
                        StartReminder.reschedule(skippingTonight: recorder.isRecording)
                    } else {
                        reminderOn = false
                        StartReminder.isEnabled = false
                    }
                }
            }

            if reminderOn {
                DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    .font(.actionDetail)
                    .onChange(of: reminderTime) { _, time in
                        StartReminder.time = Calendar.current
                            .dateComponents([.hour, .minute], from: time)
                        StartReminder.reschedule(skippingTonight: recorder.isRecording)
                    }
                Text("Recording still only starts when you press start — this is just a nudge "
                    + "on the nights you forget.")
                    .font(.fine).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Layout.cardPadding)
        .cardSurface()
    }
}
