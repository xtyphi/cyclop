import AppKit
import SwiftUI

/// The island's outline in motion: its width and its height, each on a spring
/// of its own.
///
/// Two springs rather than one because the two directions want different
/// things. Growing, the island drops a little ahead of widening and swings
/// past its size before it settles; shrinking, it pulls up ahead of narrowing
/// and never overshoots, so a folding island lands exactly on the camera
/// cutout instead of bouncing around it.
///
/// Only the outline moves. What is inside is laid out once, at the size it is
/// going to have, and the outline reveals it — so nothing reflows while the
/// island is moving, which is where the stutter of animating a frame came
/// from: every pane re-laid itself out on every frame of the spring.
@MainActor
final class IslandMotion: ObservableObject {
    /// True while either axis is still moving. The silhouette's timeline runs
    /// only for that long; a settled island costs nothing per frame.
    @Published private(set) var isMoving = false

    private var width = Axis(value: 0)
    private var height = Axis(value: 0)
    private var generation = 0

    /// Outer size of the outline, shoulders included, at this moment.
    func size(at time: TimeInterval) -> CGSize {
        CGSize(width: width.value(at: time), height: height.value(at: time))
    }

    /// Sends the outline toward a new size. Interrupted, it starts from where
    /// it is on screen, not from where it was headed.
    func set(_ target: CGSize, animated: Bool = true) {
        let now = Date.timeIntervalSinceReferenceDate
        let current = size(at: now)
        guard target != CGSize(width: width.target, height: height.target) else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion, current != .zero else {
            width = Axis(value: target.width)
            height = Axis(value: target.height)
            isMoving = false
            return
        }

        let widthSpring: IslandSpring
        if abs(target.height - current.height) < 0.5 {
            // Only the width changes — a clock gaining a digit: no bounce, so
            // the island does not wobble every time a number grows.
            widthSpring = .steady
        } else {
            widthSpring = target.width >= current.width ? .growingWidth : .shrinkingWidth
        }
        let heightSpring: IslandSpring = target.height >= current.height ? .growingHeight : .shrinkingHeight

        width = Axis(from: current.width, to: target.width, start: now, spring: widthSpring)
        height = Axis(from: current.height, to: target.height, start: now, spring: heightSpring)

        generation += 1
        let stamp = generation
        isMoving = true
        let settle = max(width.settle, height.settle)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle + 1.0 / 60) { [weak self] in
            guard let self, generation == stamp else { return }
            isMoving = false
        }
    }

    // MARK: - One axis

    private struct Axis {
        var from: CGFloat
        var target: CGFloat
        var start: TimeInterval = 0
        var zeta: Double = 1
        var omega: Double = 1
        /// Seconds until the axis stays within half a point of its target.
        var settle: TimeInterval = 0

        init(value: CGFloat) {
            from = value
            target = value
        }

        init(from: CGFloat, to: CGFloat, start: TimeInterval, spring: IslandSpring) {
            self.from = from
            self.target = to
            self.start = start
            omega = 2 * .pi / spring.duration
            zeta = spring.damping(forTravel: Double(abs(to - from)))
            settle = Self.settleTime(travel: Double(abs(to - from)), zeta: zeta, omega: omega)
        }

        func value(at time: TimeInterval) -> CGFloat {
            guard settle > 0 else { return target }
            let t = time - start
            if t <= 0 { return from }
            if t >= settle { return target }
            return from + (target - from) * CGFloat(Self.progress(t, zeta: zeta, omega: omega))
        }

        /// A damped oscillator released from rest at 0, heading for 1.
        static func progress(_ t: Double, zeta: Double, omega: Double) -> Double {
            if zeta >= 1 {
                return 1 - exp(-omega * t) * (1 + omega * t)
            }
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t)
            return 1 - decay * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }

        /// Last moment the axis is still half a point or more off its target,
        /// found by sampling at the display's own rate.
        static func settleTime(travel: Double, zeta: Double, omega: Double) -> TimeInterval {
            guard travel >= 0.5 else { return 0 }
            let step = 1.0 / 240
            var last = 0.0
            var t = step
            while t <= 2 {
                if abs(1 - progress(t, zeta: zeta, omega: omega)) * travel >= 0.5 { last = t }
                t += step
            }
            return last + step
        }
    }
}

/// A spring by how it feels: how long it takes, and how much it swings past.
struct IslandSpring {
    let duration: Double
    let bounce: Double

    static let growingWidth = IslandSpring(duration: 0.44, bounce: 0.25)
    static let growingHeight = IslandSpring(duration: 0.38, bounce: 0.22)
    static let shrinkingWidth = IslandSpring(duration: 0.30, bounce: 0)
    static let shrinkingHeight = IslandSpring(duration: 0.26, bounce: 0)
    static let steady = IslandSpring(duration: 0.50, bounce: 0)

    /// Furthest the outline may swing past its size. A small change keeps its
    /// bounce; opening the whole panel would otherwise fly 30 pt past the
    /// bottom of it, which reads as a mistake, not as play.
    static let maxOvershoot = 12.0

    /// Damping ratio for a move of this length, with the bounce cut back just
    /// enough to keep the swing within `maxOvershoot`.
    func damping(forTravel travel: Double) -> Double {
        let zeta = 1 - bounce
        guard zeta < 1, travel > 0 else { return 1 }
        let overshoot = travel * exp(-.pi * zeta / (1 - zeta * zeta).squareRoot())
        guard overshoot > Self.maxOvershoot else { return zeta }
        let ratio = log(Self.maxOvershoot / travel)
        return -ratio / (Double.pi * Double.pi + ratio * ratio).squareRoot()
    }
}

/// The island's outline, drawn at whatever size the motion has reached this
/// frame. Used twice: filled black as the island itself, and as the mask that
/// reveals the content laid out inside it.
struct IslandSilhouette: View {
    @ObservedObject var motion: IslandMotion
    var fill: Color = .black

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !motion.isMoving)) { context in
            let size = motion.size(at: context.date.timeIntervalSinceReferenceDate)
            NotchShape()
                .fill(fill)
                .frame(width: size.width, height: size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

/// How the open panel's content arrives: held back while the island makes
/// the first third of its move, then fading in from slightly small and out of
/// focus, settling with the island — the way the phone's island brings its
/// content in.
struct IslandArrival: ViewModifier {
    @State private var shown = false
    @State private var grown = false
    @State private var sharp = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(grown ? 1 : 0.86, anchor: .top)
            .blur(radius: sharp ? 0 : 12)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                    shown = true
                    grown = true
                    sharp = true
                    return
                }
                withAnimation(.easeOut(duration: 0.29).delay(0.16)) { shown = true }
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)) { grown = true }
                withAnimation(.easeOut(duration: 0.45)) { sharp = true }
            }
    }
}
