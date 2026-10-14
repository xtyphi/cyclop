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

/// The equalizer beside the source name and on the notch's side, drawn the
/// way the Dynamic Island draws a call: six capsules growing up and down
/// from a common middle, tallest in the centre.
///
/// The levels come from `AudioLevels` — bass in the middle pair, the treble
/// at the edges — which listens only while some bars hold it. With no sound
/// to go by (the recording permission refused, the tap not up yet) the bars
/// drift on two slow waves instead; paused, they rest as dots.
struct EqualizerBars: View {
    var isAnimating: Bool
    var color: Color = Theme.tertiary
    /// Height of the tallest bar; the rest of the look scales from it.
    var height: CGFloat = 10

    @State private var holding = false

    /// Which band each bar shows, left to right: bass in the middle.
    private static let order = [4, 2, 0, 1, 3, 5]
    /// How tall each bar may grow relative to the middle ones: the shape of
    /// a voice waveform, which is what the Island's call bars imitate.
    private static let envelope: [CGFloat] = [0.55, 0.8, 1, 1, 0.8, 0.55]

    private var barWidth: CGFloat { max(height / 6, 2) }
    private var spacing: CGFloat { barWidth * 0.8 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating)) { context in
            let levels = levels(at: context.date)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<Self.order.count, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight(levels[index], index: index))
                }
            }
            .frame(height: height)
        }
        .animation(.easeOut(duration: 0.25), value: isAnimating)
        .onAppear { hold(isAnimating) }
        .onDisappear { hold(false) }
        .onChange(of: isAnimating) { _, playing in hold(playing) }
    }

    private func barHeight(_ level: CGFloat, index: Int) -> CGFloat {
        barWidth + level * Self.envelope[index] * (height - barWidth)
    }

    /// 0…1 per bar, left to right.
    private func levels(at date: Date) -> [CGFloat] {
        guard isAnimating else { return Array(repeating: 0, count: Self.order.count) }
        let audio = AudioLevels.shared
        if audio.hasSignal {
            let bands = audio.bands
            return Self.order.map { CGFloat(bands[$0]) }
        }
        // Two slow waves per bar, out of step with each other and with the
        // neighbours: never repeats in an obvious way, never jumps.
        let t = date.timeIntervalSinceReferenceDate
        return (0..<Self.order.count).map { index in
            let i = Double(index)
            let a = sin(t * 5.1 + i * 1.7)
            let b = sin(t * 3.3 + i * 2.9)
            return CGFloat(0.35 + 0.3 * a * b + 0.2 * (a + 1) / 2)
        }
    }

    private func hold(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        if wanted { AudioLevels.shared.acquire() } else { AudioLevels.shared.release() }
    }
}
