import SwiftUI

/// The round buttons beside and below the open island.
///
/// Each one is born out of the island rather than faded in next to it: it
/// starts hidden behind the island's wall, small, and travels out on a spring
/// while a black neck ties it to the wall — the neck thins and lets go before
/// the circle has finished moving, so the button reads as a drop pinching off
/// the island. They wait for the island to arrive first; buttons racing the
/// outline out would be the outline's job done twice.
struct IslandButtons: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var panel: PanelState

    var body: some View {
        let geometry = panel.geometry
        let centers = geometry.buttonCenters(
            for: panel.openBodySize,
            left: panel.leftButtons.count,
            right: panel.rightButtons.count,
            bottom: panel.bottomButtons.count
        )
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(panel.leftButtons, centers.left)), id: \.0) { button, center in
                item(button, at: center, outward: .left)
            }
            ForEach(Array(zip(panel.rightButtons, centers.right)), id: \.0) { button, center in
                item(button, at: center, outward: .right)
            }
            ForEach(Array(zip(panel.bottomButtons, centers.bottom)), id: \.0) { button, center in
                item(button, at: center, outward: .down)
            }
        }
        .frame(width: geometry.windowSize.width, height: geometry.windowSize.height, alignment: .topLeading)
        // The body grows and shrinks with the tab — the teleprompter, the
        // grid — and the buttons below it ride the island's own height spring.
        .animation(.spring(duration: 0.38, bounce: 0.22), value: panel.openBodySize)
    }

    private func item(_ button: PanelState.Button, at center: CGPoint, outward: EmergingButton.Direction) -> some View {
        EmergingButton(
            symbol: symbol(for: button),
            isSelected: isSelected(button),
            help: help(for: button),
            outward: outward
        ) {
            Haptics.snap()
            panel.press(button)
        }
        .position(center)
    }

    private func symbol(for button: PanelState.Button) -> String {
        switch button {
        case .sections: return panel.showsSections ? "arrow.uturn.backward" : "square.grid.2x2"
        case .tab(let tab): return tab.symbol
        }
    }

    private func isSelected(_ button: PanelState.Button) -> Bool {
        switch button {
        case .sections: return panel.showsSections
        case .tab(let tab): return !panel.showsSections && vm.tab == tab
        }
    }

    private func help(for button: PanelState.Button) -> String {
        switch button {
        case .sections: return localized("Sections")
        case .tab(let tab): return tab.title
        }
    }
}

/// One round button and the neck that ties it to the island while it grows.
struct EmergingButton: View {
    enum Direction {
        case left, right, down

        /// Unit vector pointing away from the island.
        var vector: CGVector {
            switch self {
            case .left: return CGVector(dx: -1, dy: 0)
            case .right: return CGVector(dx: 1, dy: 0)
            case .down: return CGVector(dx: 0, dy: 1)
            }
        }
    }

    let symbol: String
    let isSelected: Bool
    let help: String
    let outward: Direction
    let action: () -> Void

    /// How far out the button has come: 0 hidden behind the wall, 1 in place.
    /// A spring, so it can pass 1 for a moment.
    @State private var progress: CGFloat = 0

    private static let radius = NotchGeometry.buttonDiameter / 2
    /// From the island's wall to the button's centre, in place.
    private static let reach = NotchGeometry.buttonGap + radius
    /// How far behind the wall the centre starts.
    private static let tuck: CGFloat = 14

    var body: some View {
        let travel = Self.reach + Self.tuck
        let back = travel * (1 - progress)
        ZStack {
            Neck(progress: progress, outward: outward)
                .fill(Color.black)
                .allowsHitTesting(false)
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: NotchGeometry.buttonDiameter, height: NotchGeometry.buttonDiameter)
                    .background(Circle().fill(Color.black))
                    .overlay(Circle().strokeBorder(Color.white.opacity(isSelected ? 0.6 : 0.16), lineWidth: 0.75))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IslandPressStyle(shape: Circle()))
            .help(help)
            .scaleEffect(0.4 + 0.6 * progress)
            .offset(x: -outward.vector.dx * back, y: -outward.vector.dy * back)
            .opacity(min(max(progress, 0), 1))
        }
        .frame(width: 2 * travel + 2 * Self.radius, height: 2 * travel + 2 * Self.radius)
        .animation(.smooth(duration: 0.22), value: symbol)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                progress = 1
                return
            }
            withAnimation(.spring(duration: 0.38, bounce: 0.12).delay(0.24)) { progress = 1 }
        }
    }

    /// The black bridge from the island's wall to the growing button: full
    /// at first, thinning as the button travels, gone once it is most of
    /// the way out.
    private struct Neck: Shape {
        var progress: CGFloat
        let outward: Direction

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func path(in rect: CGRect) -> Path {
            let p = progress
            let radius = EmergingButton.radius * (0.4 + 0.6 * p)
            let half = radius * max(0, 1 - p / 0.84)
            guard half > 0.3 else { return Path() }
            let travel = EmergingButton.reach + EmergingButton.tuck
            // Along the outward axis, from the view's centre (the button's
            // place): the wall, a little inside it so no seam shows, and the
            // circle's centre where it stands now.
            let wall = -EmergingButton.reach - 2
            let tip = -travel * (1 - p)
            guard tip > wall + 0.5 else { return Path() }
            let middle = (wall + tip) / 2

            let u = outward.vector
            let v = CGVector(dx: abs(u.dy), dy: abs(u.dx))
            func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                CGPoint(x: rect.midX + u.dx * along + v.dx * across,
                        y: rect.midY + u.dy * along + v.dy * across)
            }

            var path = Path()
            path.move(to: point(wall, -half * 1.5))
            path.addQuadCurve(to: point(tip, -half), control: point(middle, -half * 0.55))
            path.addLine(to: point(tip, half))
            path.addQuadCurve(to: point(wall, half * 1.5), control: point(middle, half * 0.55))
            path.closeSubpath()
            return path
        }
    }
}

/// Every section as a tile: the way to the ones without a button of their own.
struct SectionsGallery: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var panel: PanelState

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: NotchGeometry.tileSpacing),
            count: panel.geometry.sectionsColumns
        )
        LazyVGrid(columns: columns, spacing: NotchGeometry.tileSpacing) {
            ForEach(panel.sections) { tab in
                Button {
                    Haptics.snap()
                    panel.select(tab)
                } label: {
                    SectionTile(tab: tab, isCurrent: tab == vm.tab)
                }
                .buttonStyle(IslandPressStyle(
                    shape: RoundedRectangle(cornerRadius: SectionTile.radius, style: .continuous),
                    lifts: false
                ))
            }
        }
        .padding(.top, NotchGeometry.sectionsTopGap)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SectionTile: View {
    let tab: NotchViewModel.Tab
    let isCurrent: Bool

    static let radius: CGFloat = 16

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: tab.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
            Text(tab.title)
                .font(.system(size: Theme.footnote, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(height: 27, alignment: .top)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: NotchGeometry.tileHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Color.white.opacity(isCurrent ? 0.10 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(7)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
    }

    /// A few sections keep a colour of their own, as their apps do.
    private var tint: Color {
        switch tab {
        case .media: return Color(red: 1.0, green: 0.30, blue: 0.45)
        case .calendar: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .focus: return LiveActivityWings.tint(for: .work)
        default: return Color.white.opacity(0.85)
        }
    }
}

/// Hover and press for the island's own controls: a faint wash and a slight
/// lift under the pointer, a small give on press, all on quick springs.
struct IslandPressStyle<S: Shape>: ButtonStyle {
    let shape: S
    var lifts = true

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, shape: shape, lifts: lifts)
    }

    private struct Surface: View {
        let configuration: Configuration
        let shape: S
        let lifts: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay(shape.fill(Color.white.opacity(hovering ? 0.09 : 0)).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed ? 0.965 : (hovering && lifts ? 1.022 : 1))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.32, dampingFraction: 0.75), value: hovering)
                .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}
