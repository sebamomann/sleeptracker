import SwiftUI

/// When the night was bad, in hour-sized pieces.
///
/// Bar height is time spent making noise, not peak loudness: one door slam would otherwise
/// dominate a whole hour and hide an hour of continuous snoring.
struct HourStrip: View {
    let session: NightSession
    @State private var grown = false

    private let barHeight = 56.0
    /// Non-zero hours never collapse to the same mark as empty ones.
    private let minimumBar = 6.0

    var body: some View {
        let hours = session.byHour
        let busiest = hours.max { $0.seconds < $1.seconds }
        let scale = max(1, busiest?.seconds ?? 1)

        VStack(alignment: .leading, spacing: Layout.loose) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                    column(hour, index: index, scale: scale)
                }
            }

            if let busiest, busiest.seconds > 0 {
                Text("Busiest around \(Fmt.hour.string(from: busiest.start)) — "
                    + "\(busiest.seconds.short) of sound across \(busiest.events) events.")
                    .font(.explain)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
        // Without this every bar sat at its collapsed height forever: the animation reads
        // `grown`, and nothing was ever setting it.
        .onAppear { grown = true }
    }

    private func column(_ hour: NightSession.HourBucket, index: Int, scale: Double) -> some View {
        VStack(spacing: 5) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(hour.seconds == 0
                        ? AnyShapeStyle(Theme.surface2)
                        : AnyShapeStyle(Theme.spectrumGradient))
                    .frame(height: grown ? height(hour, scale: scale) : 3)
                    .animation(Motion.respecting(Motion.stagger(index)), value: grown)
            }
            .frame(height: barHeight)

            Text(Fmt.hour.string(from: hour.start))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
        }
    }

    /// Square-rooted, because a night's dynamic range is enormous: an hour holding forty
    /// minutes of snoring next to one holding twenty seconds would render the second as a
    /// hairline, which reads as "nothing happened" rather than "a little happened". The
    /// ordering is unchanged and the caption carries the real figure.
    private func height(_ hour: NightSession.HourBucket, scale: Double) -> Double {
        guard hour.seconds > 0 else { return 3 }
        let fraction = (hour.seconds / scale).squareRoot()
        return max(minimumBar, barHeight * fraction)
    }
}
