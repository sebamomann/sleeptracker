import SwiftUI

/// Everything the canvas needs, and one small method per mark.
///
/// Was a single 60-line `draw` with the geometry recomputed inline; splitting it means each
/// mark can be read on its own, and the shared coordinate maths is stated once.
struct EnvelopePlot {
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
