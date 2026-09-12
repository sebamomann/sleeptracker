import SwiftUI

/// Loudness over the night: one filled series (per-second peak), the noise floor beneath it,
/// the gate threshold, and marks for what the gate caught and what the OS took away.
///
/// Drag to scrub — the readout stands in for a hover tooltip, which a phone cannot offer.
struct EnvelopeChart: View {
    let session: NightSession
    @State private var cursor: Int?

    private static let dbLow = -80.0
    private static let dbHigh = 0.0
    private static let plotHeight = 190.0
    /// A phone-width chart has a few hundred pixels; a night has up to ~29k samples.
    private static let bucketTarget = 360

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.loose) {
            readout
            Canvas { context, size in
                Plot(session: session, buckets: buckets, cursor: cursor, size: size)
                    .draw(in: context)
            }
            .frame(height: Self.plotHeight)
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

// MARK: - Drawing

/// Everything the canvas needs, and one small method per mark.
///
/// Was a single 60-line `draw` with the geometry recomputed inline; splitting it means each
/// mark can be read on its own, and the shared coordinate maths is stated once.
private struct Plot {
    let session: NightSession
    let buckets: [EnvelopeSample]
    let cursor: Int?
    let size: CGSize

    /// Room below the plot for the event rail.
    private var plotHeight: Double { size.height - 18 }
    private var railY: Double { plotHeight + 10 }
    private var secondsPerBucket: Double {
        guard !session.envelope.isEmpty, !buckets.isEmpty else { return 1 }
        return Double(session.envelope.count) / Double(buckets.count)
    }

    private func y(_ db: Double) -> Double {
        let clamped = min(0.0, max(-80.0, db))
        return (0.0 - clamped) / 80.0 * plotHeight
    }

    private func x(_ index: Int) -> Double {
        guard buckets.count > 1 else { return 0 }
        return Double(index) / Double(buckets.count - 1) * size.width
    }

    func draw(in context: GraphicsContext) {
        guard buckets.count > 1 else { return }
        drawGrid(context)
        drawDeadTime(context) // under the signal: it is absence, not a mark
        drawSignal(context)
        drawFloor(context)
        drawThreshold(context)
        drawEventRail(context)
        drawCursor(context)
    }

    private func drawGrid(_ context: GraphicsContext) {
        for db in stride(from: -80.0, through: 0.0, by: 20) {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(db)))
            line.addLine(to: CGPoint(x: size.width, y: y(db)))
            context.stroke(line, with: .color(Theme.line), lineWidth: 1)
        }
    }

    private func drawDeadTime(_ context: GraphicsContext) {
        for gap in session.realGaps {
            let startS = (gap.at - session.t0) / 1000
            let from = max(0, startS / secondsPerBucket)
            let to = min(
                Double(buckets.count - 1),
                (startS + gap.audioLostMs / 1000) / secondsPerBucket
            )
            guard to > from else { continue }
            let rect = CGRect(
                x: x(Int(from)),
                y: 0,
                width: max(2, x(Int(to)) - x(Int(from))),
                height: plotHeight
            )
            context.fill(Path(rect), with: .color(Theme.gap.opacity(0.25)))
        }
    }

    private func drawSignal(_ context: GraphicsContext) {
        var area = Path()
        area.move(to: CGPoint(x: 0, y: plotHeight))
        for index in buckets.indices {
            area.addLine(to: CGPoint(x: x(index), y: y(buckets[index].max)))
        }
        area.addLine(to: CGPoint(x: size.width, y: plotHeight))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(
            Gradient(colors: [Theme.signal.opacity(0.45), Theme.signal.opacity(0.06)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: plotHeight)
        ))
        context.stroke(line(\.max), with: .color(Theme.signal), lineWidth: 1)
    }

    private func drawFloor(_ context: GraphicsContext) {
        context.stroke(line(\.p10), with: .color(Theme.textMuted), lineWidth: 2)
    }

    private func drawThreshold(_ context: GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y(session.thresholdDb)))
        path.addLine(to: CGPoint(x: size.width, y: y(session.thresholdDb)))
        context.stroke(
            path,
            with: .color(Theme.event.opacity(0.7)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )
    }

    private func drawEventRail(_ context: GraphicsContext) {
        for event in session.events {
            let from = event.startS / secondsPerBucket
            let to = event.endS / secondsPerBucket
            var rail = Path()
            rail.move(to: CGPoint(x: x(Int(from)), y: railY))
            rail.addLine(to: CGPoint(x: max(x(Int(to)), x(Int(from)) + 2), y: railY))
            context.stroke(
                rail,
                with: .color(Theme.event),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }

    private func drawCursor(_ context: GraphicsContext) {
        guard let cursor else { return }
        var path = Path()
        path.move(to: CGPoint(x: x(cursor), y: 0))
        path.addLine(to: CGPoint(x: x(cursor), y: plotHeight))
        context.stroke(path, with: .color(Theme.textPrimary.opacity(0.5)), lineWidth: 1)
    }

    private func line(_ value: KeyPath<EnvelopeSample, Double>) -> Path {
        var path = Path()
        for index in buckets.indices {
            let point = CGPoint(x: x(index), y: y(buckets[index][keyPath: value]))
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
