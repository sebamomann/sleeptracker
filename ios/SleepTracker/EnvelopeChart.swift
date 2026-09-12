import SwiftUI

/// Loudness over the night: one filled series (per-second peak), the noise floor beneath it,
/// the gate threshold, and marks for what the gate caught and what the OS took away.
///
/// Drag to scrub — the readout replaces a hover tooltip, which a phone cannot offer.
struct EnvelopeChart: View {
    let session: NightSession
    @State private var cursor: Int?

    private let dbLow = -80.0
    private let dbHigh = 0.0
    private let height = 190.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            readout
            Canvas { ctx, size in draw(ctx, size) }
                .frame(height: height)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in cursor = bucketIndex(atX: v.location.x) }
                        .onEnded { _ in cursor = nil }
                )
            legend
        }
    }

    // MARK: - Readout

    private var readout: some View {
        HStack(spacing: 14) {
            if let i = cursor, let b = buckets[safe: i] {
                Text(timeLabel(forBucket: i))
                    .font(.caption.monospaced().weight(.semibold))
                Text("peak \(Int(b.max)) dB")
                    .font(.caption.monospaced()).foregroundStyle(Theme.signal)
                Text("floor \(Int(b.p10)) dB")
                    .font(.caption.monospaced()).foregroundStyle(Theme.textMuted)
            } else {
                Text("Drag across the chart to read a moment")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .frame(height: 16)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Theme.signal, "peak")
            swatch(Theme.textMuted, "floor")
            swatch(Theme.event, "events")
            if !session.realGaps.isEmpty { swatch(Theme.gap, "dead") }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(Theme.textSecondary)
    }

    private func swatch(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(label)
        }
    }

    // MARK: - Downsampling

    /// An eight-hour night is ~29k samples; a phone-width chart has a few hundred pixels.
    /// Bucket by max so a one-second snore in a quiet minute still shows up — averaging
    /// would erase exactly the events this chart exists to reveal.
    private var buckets: [(mean: Double, max: Double, p10: Double)] {
        let target = 360
        let env = session.envelope
        guard !env.isEmpty else { return [] }
        guard env.count > target else {
            return env.map { (mean: $0[0], max: $0[1], p10: $0[2]) }
        }
        let per = Double(env.count) / Double(target)
        return (0..<target).map { i in
            let lo = Int(Double(i) * per), hi = min(env.count, Int(Double(i + 1) * per))
            let slice = env[lo..<max(lo + 1, hi)]
            return (mean: slice.map { $0[0] }.reduce(0, +) / Double(slice.count),
                    max: slice.map { $0[1] }.max() ?? dbLow,
                    p10: slice.map { $0[2] }.min() ?? dbLow)
        }
    }

    private var secondsPerBucket: Double {
        let env = session.envelope
        guard !env.isEmpty else { return 1 }
        return Double(env.count) / Double(buckets.count)
    }

    private func bucketIndex(atX x: Double) -> Int? {
        guard !buckets.isEmpty else { return nil }
        return min(buckets.count - 1, max(0, Int(x / chartWidth * Double(buckets.count))))
    }

    // Approximate; only used to map a drag back to a bucket.
    private var chartWidth: Double { UIScreen.main.bounds.width - 64 }

    private func timeLabel(forBucket i: Int) -> String {
        let t = session.startedAt.addingTimeInterval(Double(i) * secondsPerBucket)
        return Self.hm.string(from: t)
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let pts = buckets
        guard pts.count > 1 else { return }

        let plotH = size.height - 18          // room for the event rail
        func y(_ db: Double) -> Double {
            let clamped = min(dbHigh, max(dbLow, db))
            return (dbHigh - clamped) / (dbHigh - dbLow) * plotH
        }
        func x(_ i: Int) -> Double { Double(i) / Double(pts.count - 1) * size.width }

        // recessive grid
        for db in stride(from: dbLow, through: dbHigh, by: 20) {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y(db)))
            p.addLine(to: CGPoint(x: size.width, y: y(db)))
            ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
        }

        // dead time, under the signal
        let spb = secondsPerBucket
        for gap in session.realGaps {
            let startS = (gap.at - session.t0) / 1000
            let i0 = max(0, startS / spb)
            let i1 = min(Double(pts.count - 1), (startS + gap.audioLostMs / 1000) / spb)
            guard i1 > i0 else { continue }
            let rect = CGRect(x: x(Int(i0)), y: 0,
                              width: max(2, x(Int(i1)) - x(Int(i0))), height: plotH)
            ctx.fill(Path(rect), with: .color(Theme.gap.opacity(0.25)))
        }

        // peak loudness area + line
        var area = Path()
        area.move(to: CGPoint(x: 0, y: plotH))
        for i in pts.indices { area.addLine(to: CGPoint(x: x(i), y: y(pts[i].max))) }
        area.addLine(to: CGPoint(x: size.width, y: plotH))
        area.closeSubpath()
        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [Theme.signal.opacity(0.45), Theme.signal.opacity(0.06)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: plotH)))

        var line = Path()
        for i in pts.indices {
            let pt = CGPoint(x: x(i), y: y(pts[i].max))
            i == 0 ? line.move(to: pt) : line.addLine(to: pt)
        }
        ctx.stroke(line, with: .color(Theme.signal), lineWidth: 1)

        // noise floor
        var floor = Path()
        for i in pts.indices {
            let pt = CGPoint(x: x(i), y: y(pts[i].p10))
            i == 0 ? floor.move(to: pt) : floor.addLine(to: pt)
        }
        ctx.stroke(floor, with: .color(Theme.textMuted), lineWidth: 2)

        // gate threshold
        var thresh = Path()
        thresh.move(to: CGPoint(x: 0, y: y(session.thresholdDb)))
        thresh.addLine(to: CGPoint(x: size.width, y: y(session.thresholdDb)))
        ctx.stroke(thresh, with: .color(Theme.event.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // event rail
        for e in session.events {
            let i0 = e.startS / spb, i1 = e.endS / spb
            var r = Path()
            r.move(to: CGPoint(x: x(Int(i0)), y: plotH + 10))
            r.addLine(to: CGPoint(x: max(x(Int(i1)), x(Int(i0)) + 2), y: plotH + 10))
            ctx.stroke(r, with: .color(Theme.event),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // cursor
        if let i = cursor {
            var c = Path()
            c.move(to: CGPoint(x: x(i), y: 0))
            c.addLine(to: CGPoint(x: x(i), y: plotH))
            ctx.stroke(c, with: .color(Theme.textPrimary.opacity(0.5)), lineWidth: 1)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
