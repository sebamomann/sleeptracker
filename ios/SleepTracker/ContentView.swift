import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = NightRecorder()
    @State private var sessions: [NightSession] = []
    @State private var reminderOn = StartReminder.isEnabled
    @State private var reminderTime = Calendar.current.date(
        from: StartReminder.time) ?? Date()

    var body: some View {
        Group {
            if recorder.isRecording {
                RecordView(recorder: recorder)
            } else {
                home
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.signal)
        .onAppear(perform: reload)
        .task {
            // Asked once, up front, so the first speech event is not silently dropped for
            // want of a permission nobody was prompted for.
            _ = await Transcriber.requestAuthorization()
            StartReminder.reschedule(skippingTonight: recorder.isRecording)
        }
        .onChange(of: recorder.isRecording) { _, recording in if !recording { reload() } }
    }

    private var home: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button { recorder.start() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.circle.fill").font(.title2)
                            Text("Start recording").font(.headline)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Start it, lock the phone, leave it on a charger. Everything stays on "
                         + "this device.")
                        .font(.footnote).foregroundStyle(Theme.textMuted)

                    if let err = recorder.lastError {
                        Text(err)
                            .font(.caption.monospaced()).foregroundStyle(Theme.gap)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.gap.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }

                    reminderRow

                    SectionHeader(text: sessions.isEmpty ? "No nights yet"
                                                          : "Nights (\(sessions.count))")
                    ForEach(sessions) { s in
                        NavigationLink { SessionDetailView(session: s) } label: { row(s) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.surface0)
            .navigationTitle("Sleeptracker")
        }
    }

    /// "Manual, but warn me": recording never starts on its own, but a forgotten night gets
    /// a nudge at the hour you choose.
    private var reminderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $reminderOn) {
                Text("Remind me at bedtime").font(.subheadline)
            }
            .onChange(of: reminderOn) { _, on in
                StartReminder.isEnabled = on
                if on {
                    Task {
                        if await StartReminder.requestAuthorization() {
                            StartReminder.reschedule(skippingTonight: recorder.isRecording)
                        } else {
                            reminderOn = false
                            StartReminder.isEnabled = false
                        }
                    }
                } else {
                    StartReminder.reschedule()
                }
            }

            if reminderOn {
                DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    .font(.subheadline)
                    .onChange(of: reminderTime) { _, t in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: t)
                        StartReminder.time = c
                        StartReminder.reschedule(skippingTonight: recorder.isRecording)
                    }
                Text("Recording still only starts when you press start — this is just a nudge "
                     + "on the nights you forget.")
                    .font(.caption2).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        .padding(.top, 6)
    }

    private func row(_ s: NightSession) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(s.tooShort ? Theme.textMuted : (s.survived ? Theme.event : Theme.gap))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.dayFormatter.string(from: s.startedAt))
                    .font(.callout.weight(.medium))
                Text("\(s.wall.short) · \(s.events.count) events · \(s.audio.short) audio"
                     + (s.dead > 30 ? " · \(s.dead.short) dead" : ""))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textMuted)
        }
        .padding(13)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private func reload() { sessions = SessionStore.shared.list() }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f
    }()
}
