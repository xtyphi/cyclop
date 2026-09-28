import SwiftUI

/// The sprint timer: how long is left, what it is counting toward, and the
/// three lengths to choose from while nothing is running.
struct FocusPane: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        HStack(spacing: 22) {
            dial
            VStack(alignment: .leading, spacing: 12) {
                presets
                controls
                Text(localized("Sprints today: %d", timer.completedToday))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            // Wide enough for the longest row — Resume and two icons, 173 pt
            // in Russian — so the group keeps its width, and its place, when
            // Start turns into them.
            .frame(width: 210, alignment: .leading)
        }
        // The dial and the controls travel as one group, centred in the pane
        // rather than pinned to the rail beside it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { timer.refreshDay() }
    }

    // MARK: - Dial

    private var accent: Color {
        switch timer.phase {
        case .work: return Color(red: 1.0, green: 0.55, blue: 0.25)
        case .rest: return Color(red: 0.30, green: 0.80, blue: 0.55)
        case .idle: return Color.white.opacity(0.9)
        }
    }

    private var phaseTitle: String {
        if timer.isPaused { return localized("Paused") }
        switch timer.phase {
        case .work: return localized("Work")
        case .rest: return localized("Break")
        case .idle: return localized("Ready")
        }
    }

    private var dial: some View {
        ZStack {
            // Inset by half the line, so the whole ring lies inside the
            // frame. A stroke is drawn centred on the path, and the half
            // outside it was cut off by the pane's clip along the left edge.
            Circle()
                .inset(by: 3)
                .stroke(Theme.surfaceHover, lineWidth: 6)
            Circle()
                .inset(by: 3)
                .trim(from: 0, to: timer.progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: timer.progress)
            VStack(spacing: 2) {
                Text(Self.clock(timer.remaining))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(phaseTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(timer.phase == .idle ? Theme.tertiary : accent)
            }
        }
        .frame(width: 128, height: 128)
    }

    /// Minutes and seconds, the way a sprint is thought of — 90:00, not 1:30:00.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Presets

    private var presets: some View {
        HStack(spacing: 6) {
            ForEach(FocusTimer.presets.indices, id: \.self) { index in
                let selected = index == timer.presetIndex
                Button {
                    timer.selectPreset(index)
                } label: {
                    Text(FocusTimer.presets[index].label)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Color.black : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(
                            Capsule().fill(selected ? Color.white.opacity(0.9) : Theme.surface)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Offered only at rest: see `FocusTimer.selectPreset`.
                .disabled(timer.phase != .idle)
                .opacity(timer.phase == .idle || selected ? 1 : 0.35)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if timer.phase == .idle {
                pill(localized("Start"), symbol: "play.fill", prominent: true) { timer.begin() }
            } else {
                if timer.isPaused {
                    pill(localized("Resume"), symbol: "play.fill", prominent: true) { timer.resume() }
                } else {
                    pill(localized("Pause"), symbol: "pause.fill", prominent: true) { timer.pause() }
                }
                // The secondary two as icons, named on hover. Spelled out,
                // the running row reached 335 pt in Russian — the whole pane,
                // with nothing left to centre the group in.
                icon(
                    timer.phase == .work ? localized("Finish") : localized("Skip Break"),
                    symbol: "forward.end.fill"
                ) { timer.skip() }
                icon(localized("Stop"), symbol: "stop.fill") { timer.reset() }
            }
        }
    }

    private func icon(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.surfaceHover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func pill(
        _ title: String,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(prominent ? Color.white.opacity(0.9) : Theme.surfaceHover))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
