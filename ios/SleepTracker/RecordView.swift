import SwiftUI

/// The screen that is on while you sleep: black, dim red, one large target.
struct RecordView: View {
    @ObservedObject var recorder: NightRecorder
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 72, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.nightInk)
                .monospacedDigit()

            meter

            if let s = recorder.session {
                Text("recording \(now.timeIntervalSince(s.startedAt).clock)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.nightInk.opacity(0.75))

                Text(status(s))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.nightInk.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            Button { recorder.stop() } label: {
                Text("Stop recording")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 30).padding(.vertical, 15)
            }
            .foregroundStyle(Theme.nightInk)
            .overlay(Capsule().stroke(Theme.nightInk.opacity(0.45), lineWidth: 1))
            .padding(.top, 10)

            Text("You can lock the phone now. Keep it on a charger.")
                .font(.caption2)
                .foregroundStyle(Theme.nightInk.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface0)
        .onReceive(tick) { now = $0 }
    }

    private func status(_ s: NightSession) -> String {
        var parts = ["\(Int(recorder.floorDB)) dB floor",
                     "\(s.events.count) events"]
        if !s.realGaps.isEmpty { parts.append("\(s.realGaps.count) gaps") }
        if s.interruptions > 0 { parts.append("\(s.interruptions) interruptions") }
        return parts.joined(separator: " · ")
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.10))
                Capsule().fill(Theme.nightInk)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 300)
        .animation(.linear(duration: 0.12), value: recorder.levelDB)
    }

    private var fraction: Double {
        min(1, max(0, (recorder.levelDB + 70) / 70))
    }
}
