import SwiftUI

/// The sprint timer: how long is left, what it is counting toward, and the
/// three lengths to choose from while nothing is running.
struct FocusPane: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        VStack(spacing: 12) {
            timerRow
            WeekStrip(timer: timer)
        }
        // The dial and the controls travel as one group, centred in the pane
        // rather than pinned to the rail beside it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timerRow: some View {
        HStack(spacing: 22) {
            dial
            VStack(alignment: .leading, spacing: 12) {
                controls
                presets
                Text(localized("Sprints today: %d", timer.completedToday))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            // Wide enough for the longest row — Resume and two icons, 173 pt
            // in Russian — so the group keeps its width, and its place, when
            // Start turns into them.
            .frame(width: 210, alignment: .leading)
        }
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
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(phaseTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(timer.phase == .idle ? Theme.tertiary : accent)
            }
        }
        // 120 rather than 128: with the week strip underneath, a 44 pt notch
        // leaves 178 pt for the pane, and the two need 168 of it.
        .frame(width: 120, height: 120)
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

/// One week of sprints, a square per day, shaded the way GitHub shades
/// contributions: the darkest green for one, the brightest for four and up.
/// The count is written in the square too — at seven squares there is room,
/// and a shade alone makes two and three hard to tell apart.
private struct WeekStrip: View {
    @ObservedObject var timer: FocusTimer
    /// 0 is this week, -1 the one before, and so on. Not kept between
    /// visits: coming back to the tab should show today.
    @State private var offset = 0

    private let calendar = Calendar.current

    var body: some View {
        let days = week(offset)
        // Bottom-aligned: the arrows and the caption sit level with the
        // squares, not with the weekday letters above them.
        HStack(alignment: .bottom, spacing: 10) {
            arrow("chevron.left", enabled: canGoBack(from: days)) { offset -= 1 }
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in cell(day) }
            }
            arrow("chevron.right", enabled: offset < 0) { offset += 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title(days))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Text(localized("Total: %d", days.reduce(0) { $0 + timer.sprints(on: $1) }))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .lineLimit(1)
            .frame(width: 96, alignment: .leading)
        }
    }

    // MARK: - Days

    /// Monday to Sunday or Sunday to Saturday, by the region's own rule.
    private func week(_ offset: Int) -> [Date] {
        let now = Date()
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let shifted = calendar.date(byAdding: .weekOfYear, value: offset, to: start) ?? start
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: shifted) }
    }

    /// Back only as far as the first week anything was counted in.
    private func canGoBack(from days: [Date]) -> Bool {
        guard let first = timer.firstRecordedDay, let start = days.first else { return false }
        return first < start
    }

    private func title(_ days: [Date]) -> String {
        guard offset != 0 else { return localized("This week") }
        guard let first = days.first, let last = days.last else { return "" }
        let formatter = DateIntervalFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateTemplate = "dMMM"
        return formatter.string(from: first, to: last)
    }

    private static let symbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        return formatter.shortStandaloneWeekdaySymbols.map(\.sentenceCased)
    }()

    private func cell(_ day: Date) -> some View {
        let count = timer.sprints(on: day)
        let isToday = calendar.isDateInToday(day)
        let isFuture = !isToday && day > Date()
        let weekday = calendar.component(.weekday, from: day)
        return VStack(spacing: 3) {
            // One line, as wide as the square: left to itself the label was
            // offered less than its own width and broke "Thu" into a column.
            Text("\(Self.symbols[(weekday - 1) % 7]) \(calendar.component(.day, from: day))")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isToday ? Theme.secondary : Theme.tertiary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 34)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isFuture ? Color.white.opacity(0.07) : Self.shade(count))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isToday ? Color.white.opacity(0.7) : .clear, lineWidth: 1)
                )
                .overlay {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(count >= 3 ? Color.black.opacity(0.8) : Color.white.opacity(0.9))
                    }
                }
                .frame(width: 34, height: 22)
        }
    }

    /// GitHub's dark-theme contribution greens.
    private static func shade(_ count: Int) -> Color {
        switch count {
        case ..<1: return Color.white.opacity(0.14)
        case 1: return Color(red: 0.055, green: 0.267, blue: 0.161)
        case 2: return Color(red: 0.0, green: 0.427, blue: 0.196)
        case 3: return Color(red: 0.149, green: 0.651, blue: 0.255)
        default: return Color(red: 0.224, green: 0.827, blue: 0.325)
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Theme.secondary : Theme.hairline)
                .frame(width: 22, height: 22)
                .background(Circle().fill(enabled ? Theme.surface : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
