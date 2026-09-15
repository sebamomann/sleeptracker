import SwiftUI

/// Everything the canvas needs, and one small method per mark.
///
/// Was a single 60-line `draw` with the geometry recomputed inline; splitting it means each
/// mark can be read on its own, and the shared coordinate maths is stated once.
struct EnvelopePlot {
    /// The chart's dB axis: everything above `dbHigh` or below `dbLow` clamps to the edge.
    /// Shared with `EnvelopeChart`, which reads the same bounds when scrubbing.
    static let dbLow = -80.0
    static let dbHigh = 0.0

    let session: NightSession
    let buckets: [EnvelopeSample]
    let cursor: Int?
    let size: CGSize

    /// Room below the plot for the event rail.
    private var plotHeight: Double { size.height - 18 }
    private var railY: Double { plotHeight + 10 }

    /// How many seconds of the night one bucket covers — the downsampling ratio between the
    /// night's per-second envelope and however many buckets the chart actually drew.
    static func secondsPerBucket(session: NightSession, bucketCount: Int) -> Double {
        guard !session.envelope.isEmpty, bucketCount > 0 else { return 1 }
        return Double(session.envelope.count) / Double(bucketCount)
    }

    private var secondsPerBucket: Double {
        Self.secondsPerBucket(session: session, bucketCount: buckets.count)
    }

    private func y(_ db: Double) -> Double {
        let clamped = min(Self.dbHigh, max(Self.dbLow, db))
        return (Self.dbHigh - clamped) / (Self.dbHigh - Self.dbLow) * plotHeight
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
        // The ramp read against the dB axis: loud moments reach the amber end, quiet ones
        // stay violet. The colour is doing the same job as the height.
        context.fill(area, with: .linearGradient(
            Gradient(colors: [
                Theme.spectrumAmber.opacity(0.55),
                Theme.spectrumMint.opacity(0.40),
                Theme.spectrumCyan.opacity(0.28),
                Theme.spectrumViolet.opacity(0.10)
            ]),
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
