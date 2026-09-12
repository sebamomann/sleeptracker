import SwiftUI

/// When the night was bad, in hour-sized pieces.
///
/// Bar height is time spent making noise, not peak loudness: one door slam would otherwise
/// dominate a whole hour and hide an hour of continuous snoring.
struct HourStrip: View {
    let session: NightSession

    var body: some View {
        let hours = session.byHour
        let busiest = hours.max(by: { $0.seconds < $1.seconds })
        let scale = max(1, busiest?.seconds ?? 1)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(hours) { h in
                    VStack(spacing: 5) {
                        GeometryReader { geo in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(h.seconds == 0 ? Theme.surface2 : Theme.signal)
                                    .frame(height: max(3, geo.size.height * h.seconds / scale))
                            }
                        }
                        .frame(height: 56)
                        Text(Fmt.hour.string(from: h.start))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }

            if let busiest, busiest.seconds > 0 {
                Text("Busiest around \(Fmt.hour.string(from: busiest.start)) — "
                    + "\(busiest.seconds.short) of sound across \(busiest.events) events.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
