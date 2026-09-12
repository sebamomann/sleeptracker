import SwiftUI

/// Loudness over the night: one filled series (per-second peak), the noise floor beneath it,
/// the gate threshold, and marks for what the gate caught and what the OS took away.
///
/// Drag to scrub — the readout stands in for a hover tooltip, which a phone cannot offer.
struct EnvelopeChart: View {
    let session: NightSession
    @State private var cursor: Int?
    @State private var reveal = 0.0

    private static let dbLow = -80.0
    private static let dbHigh = 0.0
    private static let plotHeight = 190.0
    /// A phone-width chart has a few hundred pixels; a night has up to ~29k samples.
    private static let bucketTarget = 360

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.loose) {
            readout
            Canvas { context, size in
                EnvelopePlot(session: session, buckets: buckets, cursor: cursor, size: size)
                    .draw(in: context)
            }
            .frame(height: Self.plotHeight)
            // Revealed left to right, which is the direction the night ran. Also hides the
            // fact that a whole night's path appears in one frame.
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: reveal, anchor: .leading)
            }
            .onAppear {
                guard !Motion.isReduced else { reveal = 1; return }
                withAnimation(.easeOut(duration: 0.85)) { reveal = 1 }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in cursor = bucketIndex(atX: drag.location.x) }
                    .onEnded { _ in cursor = nil }
            )
            legend
        }
    }

    // MARK: - Readout and legend

    private var readout: some View {
        HStack(spacing: Layout.cardPadding) {
            if let index = cursor, let bucket = buckets[safe: index] {
                Text(timeLabel(forBucket: index)).font(.rowMeta).bold()
                Text("peak \(Int(bucket.max)) dB").font(.rowMeta).foregroundStyle(Theme.signal)
                Text("floor \(Int(bucket.p10)) dB").font(.rowMeta)
                    .foregroundStyle(Theme.textMuted)
            } else {
                Text("Drag across the chart to read a moment")
                    .font(.fine).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .frame(height: 16)
        .motion(Motion.quick, value: cursor)
    }

    private var legend: some View {
        HStack(spacing: Layout.cardPadding) {
            swatch(Theme.signal, "peak")
            swatch(Theme.textMuted, "floor")
            swatch(Theme.event, "events")
            if !session.realGaps.isEmpty {
                swatch(Theme.gap, "dead")
            }
            Spacer()
        }
        .font(.fine)
        .foregroundStyle(Theme.textSecondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label)
        }
    }

    // MARK: - Downsampling

    /// Bucketed by *max*, not mean: a one-second snore in an otherwise quiet minute must
    /// still appear, and averaging would erase exactly the events this chart exists to show.
    private var buckets: [EnvelopeSample] {
        let env = session.envelope
        guard !env.isEmpty else { return [] }
        guard env.count > Self.bucketTarget else { return env.map(EnvelopeSample.init(stored:)) }

        let per = Double(env.count) / Double(Self.bucketTarget)
        return (0 ..< Self.bucketTarget).map { index in
            let lo = Int(Double(index) * per)
            let hi = min(env.count, Int(Double(index + 1) * per))
            let slice = env[lo ..< max(lo + 1, hi)]
            return EnvelopeSample(
                mean: slice.map { $0[0] }.reduce(0, +) / Double(slice.count),
                max: slice.map { $0[1] }.max() ?? Self.dbLow,
                p10: slice.map { $0[2] }.min() ?? Self.dbLow
            )
        }
    }

    private var secondsPerBucket: Double {
        guard !session.envelope.isEmpty, !buckets.isEmpty else { return 1 }
        return Double(session.envelope.count) / Double(buckets.count)
    }

    private func bucketIndex(atX x: Double) -> Int? {
        guard !buckets.isEmpty else { return nil }
        let width = UIScreen.main.bounds.width - 2 * Layout.gutter - 2 * Layout.cardPadding
        return min(buckets.count - 1, max(0, Int(x / width * Double(buckets.count))))
    }

    private func timeLabel(forBucket index: Int) -> String {
        Fmt.time.string(from: session.startedAt
            .addingTimeInterval(Double(index) * secondsPerBucket))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
