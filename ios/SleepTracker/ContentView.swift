import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = NightRecorder()
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if recorder.isRecording { recordingView } else { idleView }
        }
        .preferredColorScheme(.dark)
        .onReceive(tick) { now = $0 }
        // Nothing to stop on backgrounding — that is the entire point. The audio session
        // keeps running with the screen locked, which is what the web version could not do.
        .persistentSystemOverlays(.hidden)
    }

    // MARK: -

    private var idleView: some View {
        VStack(spacing: 22) {
            Text("Sleeptracker").font(.title2.weight(.semibold))
            Text("Records the night, keeps only what isn't silence.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button { recorder.start() } label: {
                Text("Start recording")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)

            Text("Lock the phone once it starts. Keep it plugged in.")
                .font(.footnote).foregroundStyle(.tertiary)

            if let err = recorder.lastError {
                Text(err).font(.caption.monospaced()).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if !recorder.events.isEmpty { eventList }
        }
        .padding(28)
    }

    private var recordingView: some View {
        VStack(spacing: 20) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 76, weight: .semibold, design: .monospaced))
                .foregroundStyle(nightInk)

            meter

            Text(elapsed).font(.footnote.monospaced()).foregroundStyle(nightInk.opacity(0.7))
            Text("\(Int(recorder.floorDB)) dB floor · \(recorder.events.count) events"
                 + (recorder.interruptions > 0 ? " · \(recorder.interruptions) interruptions" : ""))
                .font(.caption2.monospaced()).foregroundStyle(nightInk.opacity(0.5))

            Button("Stop recording") { recorder.stop() }
                .font(.subheadline)
                .tint(nightInk)
                .buttonStyle(.bordered)
                .padding(.top, 10)
        }
        .padding(28)
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.11))
                Capsule().fill(nightInk)
                    .frame(width: geo.size.width * levelFraction)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 320)
        .animation(.linear(duration: 0.1), value: recorder.levelDB)
    }

    private var eventList: some View {
        List(recorder.events.reversed()) { e in
            HStack {
                Text(e.at, format: .dateTime.hour().minute().second())
                    .font(.caption.monospaced())
                Spacer()
                Text("\(e.duration, specifier: "%.1f")s")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("\(Int(e.peakDB)) dB")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 260)
    }

    // MARK: -

    private var nightInk: Color { Color(red: 0.56, green: 0.18, blue: 0.18) }

    private var levelFraction: CGFloat {
        max(0, min(1, CGFloat((recorder.levelDB + 70) / 70)))
    }

    private var elapsed: String {
        guard let started = recorder.startedAt else { return "" }
        let s = Int(now.timeIntervalSince(started))
        return String(format: "recording %d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
