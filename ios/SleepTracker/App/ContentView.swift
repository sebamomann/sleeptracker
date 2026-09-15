import SwiftUI

struct ContentView: View {
    enum Tab: Hashable { case record, nights, favourites }

    @StateObject private var recorder = NightRecorder()
    @StateObject private var nights = NightsStore()
    @State private var tab: Tab = .record

    var body: some View {
        ZStack {
            if recorder.isRecording {
                // Recording takes the whole screen rather than living in a tab: there is
                // nothing else to do while it runs, and the screen is meant to be dark.
                // It fades in over half a second — a hard cut to black at bedtime is a
                // small shock, and this is the one screen you look at on the way to sleep.
                RecordView(recorder: recorder)
                    .transition(.opacity)
            } else {
                tabs.transition(.opacity)
            }
        }
        .motion(Motion.gentle, value: recorder.isRecording)
        .preferredColorScheme(.dark)
        .tint(Theme.signal)
        .onAppear { nights.reload() }
        .onChange(of: recorder.isRecording) { _, recording in
            if !recording {
                nights.reload()
                tab = .nights // the night you just finished is the thing to read
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

// MARK: - Nights

private struct NightsTab: View {
    @ObservedObject var store: NightsStore
    @State private var pendingDelete: NightDeletion?

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("No nights yet").font(.emptyStateTitle)
                        Text("Record one from the Record tab.")
                            .font(.explain).foregroundStyle(Theme.textMuted)
                    }
                    .padding(Layout.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .spectrogramGround()
                } else {
                    List {
                        ForEach(store.sessions) { s in
                            NavigationLink { NightReport(session: s, store: store) } label: {
                                row(s)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.line)
                        }
                        // A swipe asks rather than acts: the audio is only on this phone,
                        // and .onDelete would have destroyed a night on one gesture.
                        .onDelete { offsets in
                            guard let first = offsets.first,
                                  store.sessions.indices.contains(first) else { return }
                            pendingDelete = NightDeletion(session: store.sessions[first])
                        }
                    }
                    .listStyle(.plain)
                    // A List paints its own opaque background, which would sit on top of the
                    // ground and hide it. Rows carry their own surface, so nothing is lost.
                    .scrollContentBackground(.hidden)
                    .spectrogramGround()
                    .motion(Motion.standard, value: store.sessions.count)
                }
            }
            .navigationTitle("Nights")
        }
        .confirmNightDeletion($pendingDelete) { deletion in
            withAnimation(Motion.respecting(Motion.standard)) {
                store.delete(id: deletion.id)
            }
        }
    }

    private func row(_ s: NightSession) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(s.tooShort ? Theme.textMuted : (s.survived ? Theme.event : Theme.gap))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(Fmt.dayTime.string(from: s.startedAt)).font(.rowTitle)
                Text("\(s.wall.short) · \(s.events.count) events"
                    + (s.snoringSeconds >= 60 ? " · snored \(s.snoringSeconds.short)" : "")
                    + (s.dead > 30 ? " · \(s.dead.short) dead" : ""))
                    .font(.rowMeta)
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
                .font(.fine)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 3)
    }
}
