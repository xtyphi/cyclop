import SwiftUI

/// System volume next to the transport: a speaker that mutes on click and a
/// short bar that follows a drag, drawn like the scrubber below it.
///
/// Observes the volume on its own, so a press of the volume keys redraws this
/// and not the whole Music pane.
struct VolumeControl: View {
    @ObservedObject var volume: SystemVolume

    @State private var hover = false
    /// Set while dragging, so the bar follows the pointer instead of lagging a
    /// listener round-trip behind it.
    @State private var dragging: Float?

    private let barWidth: CGFloat = 64

    private var shown: Float {
        dragging ?? (volume.isMuted ? 0 : volume.level)
    }

    private var symbol: String {
        if volume.isMuted || shown == 0 { return "speaker.slash.fill" }
        if shown < 0.34 { return "speaker.wave.1.fill" }
        if shown < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { volume.toggleMute() } label: {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 18, height: 18, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)

            let height: CGFloat = hover ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface).frame(height: height)
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: barWidth * CGFloat(shown), height: height)
                if hover {
                    Circle()
                        .fill(.white)
                        .frame(width: 11, height: 11)
                        .offset(x: min(max(barWidth * CGFloat(shown) - 5.5, 0), barWidth - 11))
                        .shadow(color: .black.opacity(0.4), radius: 3)
                }
            }
            .frame(width: barWidth, height: 14)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let target = Float(min(max(value.location.x / barWidth, 0), 1))
                        dragging = target
                        volume.setLevel(target)
                    }
                    .onEnded { _ in dragging = nil }
            )
            .animation(Theme.contentAnimation, value: hover)
        }
        .disabled(!volume.isAvailable)
        .opacity(volume.isAvailable ? 1 : 0.35)
        .help(volume.isAvailable ? localized("Volume") : localized("This output has no volume control"))
    }
}
