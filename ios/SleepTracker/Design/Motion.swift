import SwiftUI

/// One set of curves, like `Layout` is one set of spacings.
///
/// Two speeds, for two situations. Anything you touch responds in under 200 ms, because
/// slower than that feels broken. Anything to do with going to sleep or waking up takes its
/// time — a hard cut to a black screen at bedtime is jarring, and a 600 ms fade is not.
enum Motion {
    /// Direct response to a tap.
    static let quick = Animation.easeOut(duration: 0.18)
    /// Layout settling: disclosures, filters, list changes.
    static let standard = Animation.easeInOut(duration: 0.28)
    /// Entering or leaving the night.
    static let gentle = Animation.easeInOut(duration: 0.6)
    /// Marking something. A little overshoot, because this is the one control that should
    /// feel good to press.
    static let springy = Animation.spring(response: 0.34, dampingFraction: 0.58)
    /// The level meter, which must not lag behind the sound.
    static let meter = Animation.linear(duration: 0.1)
    /// The breathing pulse on the recording screen. Slow enough to be calming, dim enough
    /// not to light the room.
    static let breathing = Animation.easeInOut(duration: 4).repeatForever(autoreverses: true)

    /// Sections arriving in sequence rather than all at once, so the eye has an order.
    static func stagger(_ index: Int, step: Double = 0.045) -> Animation {
        standard.delay(Double(index) * step)
    }

    /// Nil when the system asks for less motion, which turns every `withAnimation` and
    /// `.animation` using it into an instant change.
    ///
    /// Read at evaluation time rather than through the environment: this is called from
    /// button actions and modifiers alike, and the setting does not change mid-session in
    /// any way worth re-rendering for.
    static func respecting(_ animation: Animation) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : animation
    }

    static var isReduced: Bool { UIAccessibility.isReduceMotionEnabled }
}

/// Fade-and-rise on first appearance, offset by position so a screenful of cards arrives in
/// reading order instead of all at once.
private struct AppearFade: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.respecting(Motion.stagger(index))) { shown = true }
            }
    }
}

extension View {
    func appearFade(_ index: Int) -> some View {
        modifier(AppearFade(index: index))
    }

    /// `.animation` that yields to Reduce Motion.
    func motion(_ animation: Animation, value: some Equatable) -> some View {
        self.animation(Motion.respecting(animation), value: value)
    }
}
