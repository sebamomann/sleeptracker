import SwiftUI

/// The ground the whole app sits on.
///
/// A slate gradient with a faint spectrogram drawn into it — the app's own subject as its
/// texture, rather than a decorative pattern borrowed from somewhere else. Fades out
/// downward so it reads as a horizon behind the content and never competes with it.
struct SpectrogramGround: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.surface0Top, Theme.surface0],
                startPoint: .top, endPoint: .bottom
            )
            Canvas { context, size in draw(context, size) }
                .mask(LinearGradient(
                    colors: [.black.opacity(0.85), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.7)
                ))
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        // A fixed sequence rather than random(): the texture must be identical on every
        // render, or it flickers each time SwiftUI re-evaluates the view.
        var seed: UInt64 = 0x5EED
        func next(_ modulo: UInt64) -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % modulo)
        }

        var offset = 0.0
        while offset < size.width {
            let width = 1 + next(3)
            let alpha = 0.05 + next(60) / 1000
            let hue = Theme.spectrum[Int(next(UInt64(Theme.spectrum.count)))]
            let bar = CGRect(x: offset, y: 0, width: width, height: size.height)
            context.fill(Path(bar), with: .color(hue.opacity(alpha)))
            offset += width + 2 + next(6)
        }
    }
}

/// The ground for the recording screen: indigo rather than slate, with one dim pool of light
/// where the clock sits. Kept separate from `SpectrogramGround` because this is the only
/// screen looked at in the dark, and it answers to different rules.
struct NightGround: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.nightGroundTop, Theme.nightGroundBottom],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Theme.nightInk.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.34),
                startRadius: 0, endRadius: 320
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    func spectrogramGround() -> some View {
        background(SpectrogramGround())
    }

    func nightGround() -> some View {
        background(NightGround())
    }
}
