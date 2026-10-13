import SwiftUI
import AppKit

enum Theme {
    static let openAnimation = Animation.spring(response: 0.27, dampingFraction: 0.82)
    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    static let paneOut = Animation.easeIn(duration: 0.12)
    static let artworkAnimation = Animation.easeOut(duration: 0.28)

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    // Type scale. Six steps for every word in the panel: before there was a
    // scale, fourteen sizes had grown pane by pane, down to 9 pt, and the
    // panes read as separate apps. Icons size themselves to their boxes and
    // are not on it.
    /// Uppercase labels, meta, hints.
    static let caption: CGFloat = 10
    /// Secondary lines.
    static let footnote: CGFloat = 11
    /// Row text.
    static let body: CGFloat = 12
    /// Values and emphasised rows.
    static let headline: CGFloat = 13
    /// The one title on a pane: the track, the next meeting.
    static let title: CGFloat = 16
    /// The big number: the timer, the converted amount.
    static let display: CGFloat = 24

    // Corner radii. Concentric with the panel: its lower corners are 22 and
    // the content sits 14 in, so a card against them is 8 — the inner curve
    // follows the outer one instead of crossing it.
    static let radiusXS: CGFloat = 4
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 8
    static let radiusL: CGFloat = 12
    static let radiusXL: CGFloat = 14

    /// Numbers that change in place roll to their new value rather than
    /// swapping, as the system's clocks and counters do.
    static let numberAnimation = Animation.snappy(duration: 0.35)

    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let surface = Color.white.opacity(0.08)
    static let surfaceHover = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? 17 : 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .contentShape(Circle())
            // The press lands on the frame the button goes down, unanimated:
            // easing into it is lag under the pointer. Only the release eases.
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

extension View {
    /// Rolls a number to its new value, digit by digit. Not for numbers being
    /// typed: there the change has to land on the keystroke, not after it.
    func rollingNumber<Value: Equatable>(_ value: Value, countsDown: Bool = false) -> some View {
        contentTransition(.numericText(countsDown: countsDown))
            .animation(Theme.numberAnimation, value: value)
    }

    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }
}

/// Drawn rather than `NSSwitch`-backed: the panel is a non-activating window
/// that almost never becomes key (that is what keeps hovering it from
/// stealing focus from whatever app was in front), and `NSSwitch` renders its
/// on-state in gray rather than accent blue whenever its window is not key.
/// A plain `Color` fill has no such state to lose.
struct NotchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Theme.surfaceHover)
                .frame(width: 28, height: 16)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: configuration.isOn ? 6 : -6)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Trackpad feedback for the moments that have a physical edge to them: a
/// tab clicking into place, a slider meeting its end, a copy landing. Felt
/// only through a Force Touch trackpad with a finger on it; elsewhere it is
/// silently nothing, which is the right amount for a mouse.
@MainActor
enum Haptics {
    /// Something snapped into place: a tab, a slider's end stop.
    static func snap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// An action went through: a copy.
    static func confirm() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
