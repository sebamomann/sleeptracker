import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = NightRecorder()
    @State private var sessions: [NightSession] = []

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
