import SwiftUI

struct ContentView: View {
    enum Tab: Hashable { case record, nights, favourites }

    @StateObject private var recorder = NightRecorder()
    @StateObject private var nights = NightsStore()
    @State private var tab: Tab = .record

    var body: some View {
        Group {
            if recorder.isRecording {
                // Recording takes the whole screen rather than living in a tab: there is
                // nothing else to do while it runs, and the screen is meant to be dark.
                RecordView(recorder: recorder)
            } else {
                tabs
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.signal)
        .onAppear { nights.reload() }
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording {
                nights.reload()
                tab = .nights          // the night you just finished is the thing to read
            }
        }
        .task {
            // Asked once, up front, so the first speech event is not silently dropped for
            // want of a permission nobody was prompted for.
            _ = await Transcriber.requestAuthorization()
            StartReminder.reschedule(skippingTonight: recorder.isRecording)
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            RecordTab(recorder: recorder, nights: nights, openNights: { tab = .nights })
                .tabItem { Label("Record", systemImage: "waveform.circle") }
                .tag(Tab.record)

            NightsTab(store: nights)
                .tabItem { Label("Nights", systemImage: "moon.stars") }
                .tag(Tab.nights)

            FavouritesView(store: nights)
                .tabItem { Label("Favourites", systemImage: "star") }
                .tag(Tab.favourites)
                .badge(nights.markedCount)
        }
    }
}

// MARK: - Record

private struct RecordTab: View {
    @ObservedObject var recorder: NightRecorder
    @ObservedObject var nights: NightsStore
    var openNights: () -> Void

    @State private var reminderOn = StartReminder.isEnabled
    @State private var reminderTime = Calendar.current.date(from: StartReminder.time) ?? Date()

    var body: some View {
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

                    Text("Start it, lock the phone, leave it on a charger. Everything stays "
                         + "on this device.")
                        .font(.footnote).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = recorder.lastError {
                        Text(err)
                            .font(.caption.monospaced()).foregroundStyle(Theme.gap)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.gap.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let last = nights.sessions.first {
                        SectionHeader(text: "Last night")
                        Button(action: openNights) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.day.string(from: last.startedAt))
                                    .font(.callout.weight(.medium))
                                Text("\(last.wall.short) · \(last.events.count) events"
                                     + (last.snoringSeconds >= 60
                                        ? " · snored \(last.snoringSeconds.short)" : ""))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.textMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    reminderRow
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
                    .font(.subheadline)
                    .onChange(of: reminderTime) { _, t in
                        StartReminder.time = Calendar.current
                            .dateComponents([.hour, .minute], from: t)
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

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f
    }()
}

// MARK: - Nights

private struct NightsTab: View {
    @ObservedObject var store: NightsStore

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("No nights yet").font(.subheadline.weight(.medium))
                        Text("Record one from the Record tab.")
                            .font(.footnote).foregroundStyle(Theme.textMuted)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.surface0)
                } else {
                    List {
                        ForEach(store.sessions) { s in
                            NavigationLink { SessionDetailView(session: s, store: store) } label: {
                                row(s)
                            }
                        }
                        .onDelete { idx in
                            idx.map { store.sessions[$0].id }.forEach(store.delete)
                        }
                    }
                    .listStyle(.plain)
                    .background(Theme.surface0)
                }
            }
            .navigationTitle("Nights")
        }
    }

    private func row(_ s: NightSession) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(s.tooShort ? Theme.textMuted : (s.survived ? Theme.event : Theme.gap))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.day.string(from: s.startedAt)).font(.callout.weight(.medium))
                Text("\(s.wall.short) · \(s.events.count) events"
                     + (s.snoringSeconds >= 60 ? " · snored \(s.snoringSeconds.short)" : "")
                     + (s.dead > 30 ? " · \(s.dead.short) dead" : ""))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if !s.markedEvents.isEmpty {
                HStack(spacing: 3) {
                    if !s.starredEvents.isEmpty {
                        Label("\(s.starredEvents.count)", systemImage: "star.fill")
                            .foregroundStyle(Theme.signal)
                    }
                    if !s.flaggedEvents.isEmpty {
                        Label("\(s.flaggedEvents.count)", systemImage: "flag.fill")
                            .foregroundStyle(Theme.gap)
                    }
                }
                .font(.caption2)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f
    }()
}
