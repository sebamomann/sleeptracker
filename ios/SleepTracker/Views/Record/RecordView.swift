import SwiftUI

/// The screen that is on while you sleep: black, dim red, one large target.
struct RecordView: View {
    @ObservedObject var recorder: NightRecorder
    @State private var now = Date()
    @State private var breathing = false
    /// Peak hold: the meter falls back slowly rather than snapping to silence, so a snore
    /// that has just ended is still visible when you glance over.
    @State private var peakHold = 0.0
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            glow
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nightGround()
        .onAppear {
            guard !Motion.isReduced else { return }
            withAnimation(Motion.breathing) { breathing = true }
        }
        .onReceive(tick) { instant in
            // Animated so the clock's digits settle rather than snap. Seconds where nothing
            // changes produce no transition, so this costs nothing 59 times a minute.
            withAnimation(Motion.respecting(Motion.standard)) { now = instant }
            withAnimation(Motion.respecting(Motion.standard)) {
                peakHold = max(fraction, peakHold - 0.09)
            }
        }
    }

    /// A dim, slow pulse behind the clock. Deliberately low contrast: this is on in a dark
    /// bedroom, and anything brighter would light the room.
    @ViewBuilder
    private var glow: some View {
        if !Motion.isReduced {
            Circle()
                .fill(RadialGradient(
                    colors: [Theme.nightInk.opacity(0.18), .clear],
                    center: .center, startRadius: 0, endRadius: 180
                ))
                .frame(width: 360, height: 360)
                .blur(radius: 18)
                .scaleEffect(breathing ? 1.05 : 0.93)
                .opacity(breathing ? 0.95 : 0.4)
                .allowsHitTesting(false)
        }
    }

    private var content: some View {
        VStack(spacing: 18) {
            Text(now, format: .dateTime.hour().minute())
                .contentTransition(.numericText())
                .font(.system(size: 72, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.nightInk)
                .monospacedDigit()

            meter

            if let listensAt = recorder.listensAt {
                Text("listening from \(Fmt.hourMinute.string(from: listensAt))")
                    .accessibilityIdentifier("listening-from")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.nightInk.opacity(0.75))

                Text("nothing is kept for \(max(0, listensAt.timeIntervalSince(now)).clock)")
                    .font(.rowMeta)
                    .foregroundStyle(Theme.nightInk.opacity(0.5))
                    .multilineTextAlignment(.center)
            } else if let s = recorder.session {
                Text("recording \(now.timeIntervalSince(s.startedAt).clock)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.nightInk.opacity(0.75))

                Text(status(s))
                    .font(.rowMeta)
                    .foregroundStyle(Theme.nightInk.opacity(0.5))
                    .multilineTextAlignment(.center)
            }

            Button { recorder.stop() } label: {
                Text("Stop recording")
                    .font(.sectionTitle)
                    .padding(.horizontal, 30).padding(.vertical, 15)
            }
            .foregroundStyle(Theme.nightInk)
            .overlay(Capsule().stroke(Theme.nightInk.opacity(0.45), lineWidth: 1))
            .padding(.top, 10)

            Text("You can lock the phone now. Keep it on a charger.")
                .font(.fine)
                .foregroundStyle(Theme.nightInk.opacity(0.35))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func status(_ s: NightSession) -> String {
        var parts = ["\(Int(recorder.floorDB)) dB floor",
                     "\(s.events.count) events"]
        if !s.realGaps.isEmpty {
            parts.append("\(s.realGaps.count) gaps")
        }
        if s.interruptions > 0 {
            parts.append("\(s.interruptions) interruptions")
        }
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
