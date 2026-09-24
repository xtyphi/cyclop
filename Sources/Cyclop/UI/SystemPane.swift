import SwiftUI

/// Processor, memory and graphics side by side: the number now, and the last
/// minute behind it. The graph is the point — a percentage on its own cannot
/// say whether the fan is spinning up or calming down.
struct SystemPane: View {
    @ObservedObject var load: SystemLoad

    var body: some View {
        HStack(spacing: 10) {
            card(
                symbol: "cpu",
                name: localized("CPU"),
                value: load.current.cpu,
                color: Color(red: 0.24, green: 0.60, blue: 1.0),
                series: load.history.map(\.cpu)
            )
            card(
                symbol: "memorychip",
                name: localized("Memory"),
                value: load.current.memory,
                color: Color(red: 0.25, green: 0.84, blue: 0.45),
                series: load.history.map(\.memory)
            )
            if let gpu = load.current.gpu {
                card(
                    symbol: "display",
                    name: localized("GPU"),
                    value: gpu,
                    color: Color(red: 0.93, green: 0.33, blue: 0.85),
                    series: load.history.map { $0.gpu ?? 0 }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(
        symbol: String,
        name: String,
        value: Double,
        color: Color,
        series: [Double]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(color)
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(String(format: "%.1f%%", value))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            Sparkline(series: series, capacity: SystemLoad.historyLength, color: color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }
}

/// The last minute as one line, filled underneath.
///
/// Drawn across the full width from the first sample on, so the line grows
/// into the card from the left rather than stretching two readings across it
/// and calling that a history.
private struct Sparkline: View {
    let series: [Double]
    let capacity: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // One sample cannot be a line, and the spacing below divides by
            // the capacity, which is never zero — but it is stated rather
            // than assumed, because a zero here is a crash, not a blank card.
            let steps = max(capacity - 1, 1)
            let step = size.width / CGFloat(steps)
            let baseline = size.height

            ZStack {
                if series.count > 1 {
                    let points = series.enumerated().map { index, value in
                        CGPoint(
                            x: CGFloat(index) * step,
                            y: baseline - baseline * CGFloat(min(max(value, 0), 100)) / 100
                        )
                    }
                    line(points, floor: baseline)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.45), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    line(points)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: baseline - 0.8))
                        path.addLine(to: CGPoint(x: size.width, y: baseline - 0.8))
                    }
                    .stroke(color, lineWidth: 1.6)
                }
            }
        }
        .frame(minHeight: 34)
    }

    /// Without a `floor` this is the line itself; with one it is the area
    /// under it, closed along the bottom of the card so the gradient has the
    /// card's own height to fade over.
    private func line(_ points: [CGPoint], floor: CGFloat? = nil) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        guard let floor else { return path }
        path.addLine(to: CGPoint(x: last.x, y: floor))
        path.addLine(to: CGPoint(x: first.x, y: floor))
        path.closeSubpath()
        return path
    }
}
