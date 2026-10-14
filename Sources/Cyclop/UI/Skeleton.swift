import SwiftUI

/// Placeholder shown while artwork is on its way. The system publishes the new
/// title before it has fetched the new cover, so without this the panel would
/// sit on an empty grey square for a moment on every track change.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = Theme.radiusXL
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

/// The equalizer beside the source name and on the notch's side: a spectrum
/// in seven bars, bass on the left and treble on the right, growing up from
/// a common floor, each with a small cap that marks its recent peak and
/// sinks back slowly.
///
/// The levels come from `AudioLevels`, which listens only while some bars
/// hold it. With no sound to go by (the recording permission refused, the
/// tap not up yet) the bars drift on two slow waves instead, without caps;
/// paused, they rest at the floor.
struct EqualizerBars: View {
    var isAnimating: Bool
    var color: Color = Theme.tertiary
    /// Height of the tallest bar; the rest of the look scales from it.
    var height: CGFloat = 10

    @State private var holding = false

    private static let count = AudioLevels.bandCount

    private var barWidth: CGFloat { height >= 14 ? 2.5 : 2 }
    private var spacing: CGFloat { height >= 14 ? 1.5 : 1 }
    private var capHeight: CGFloat { height >= 14 ? 1.5 : 1 }
    /// Room above the tallest bar for its cap and the gap under it.
    private var headroom: CGFloat { capHeight + 1 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating)) { context in
            let frame = levels(at: context.date)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<Self.count, id: \.self) { index in
                    bar(level: frame.bars[index], cap: frame.caps?[index])
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .animation(.easeOut(duration: 0.25), value: isAnimating)
        .onAppear { hold(isAnimating) }
        .onDisappear { hold(false) }
        .onChange(of: isAnimating) { _, playing in hold(playing) }
    }

    private func bar(level: CGFloat, cap: CGFloat?) -> some View {
        let travel = height - headroom - barWidth
        let barHeight = barWidth + level * travel
        return ZStack(alignment: .bottom) {
            Capsule()
                .fill(color)
                .frame(width: barWidth, height: barHeight)
            if let cap {
                Capsule()
                    .fill(color.opacity(0.6))
                    .frame(width: barWidth, height: capHeight)
                    .offset(y: -(barWidth + max(cap, level) * travel + 1))
            }
        }
        .frame(width: barWidth, height: height, alignment: .bottom)
    }

    /// 0…1 per bar, bass first, and the caps when there is sound to cap.
    private func levels(at date: Date) -> (bars: [CGFloat], caps: [CGFloat]?) {
        guard isAnimating else { return (Array(repeating: 0, count: Self.count), nil) }
        let audio = AudioLevels.shared
        if audio.hasSignal {
            let bands = audio.bands, caps = audio.caps
            return ((0..<Self.count).map { CGFloat(bands[$0]) }, (0..<Self.count).map { CGFloat(caps[$0]) })
        }
        // Two slow waves per bar, out of step with each other and with the
        // neighbours: never repeats in an obvious way, never jumps.
        let t = date.timeIntervalSinceReferenceDate
        return ((0..<Self.count).map { index in
            let i = Double(index)
            let a = sin(t * 5.1 + i * 1.7)
            let b = sin(t * 3.3 + i * 2.9)
            return CGFloat(0.3 + 0.3 * a * b + 0.2 * (a + 1) / 2)
        }, nil)
    }

    private func hold(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        if wanted { AudioLevels.shared.acquire() } else { AudioLevels.shared.release() }
    }
}
