import AppKit

/// One screen's share of the panel: whether the notch on *this* display is
/// open, and the geometry it is cut from.
///
/// The split is the pointer's. It is on exactly one display at a time, so
/// everything it drives — open, drop-targeted, holding the keyboard — belongs
/// to a screen, while the tab, the stores and the running services are the
/// same everywhere and stay in `NotchViewModel`.
@MainActor
final class PanelState: ObservableObject {
    @Published var isOpen = false { didSet { notify(isOpen != oldValue) } }
    @Published var isDropTargeted = false { didSet { notify(isDropTargeted != oldValue) } }
    /// Whether this screen's panel holds the keyboard. Per screen because only
    /// one window can be key, and it is this one the user clicked into.
    @Published var wantsKeyboard = false { didSet { notify(wantsKeyboard != oldValue) } }
    /// The grid of every section is up instead of a tab. Per screen, like
    /// open: it is a way of choosing, and the choice is the shared tab.
    @Published var showsSections = false

    let geometry: NotchGeometry
    private let vm: NotchViewModel

    /// Raised when any of the three above moves, so whoever owns every screen
    /// can recompute what the shared model needs to know about the panels.
    var onChange: (() -> Void)?

    /// Folds this screen's panel and keeps it folded until the pointer leaves.
    /// Set by the screen that owns the panel; called by a pane whose click
    /// sends the user somewhere else entirely.
    var onDismiss: (() -> Void)?

    /// A click on the timer or the song beside the folded notch: open the
    /// panel on the tab it belongs to.
    var onActivate: ((NotchViewModel.Tab) -> Void)?

    init(geometry: NotchGeometry, vm: NotchViewModel) {
        self.geometry = geometry
        self.vm = vm
    }

    /// Whether this screen is showing anything beyond the bare notch.
    var isActive: Bool { isOpen || isDropTargeted }

    /// Body this screen takes when open — asked whether it is open yet or not.
    ///
    /// Separate from `bodySize` because the rects are cut one step before the
    /// panel is marked open: `setOpen` grows the interactive area first, so
    /// the pointer never falls through a region the animation has not covered.
    /// Reading a size that returns the notch until `isOpen` flips would hand
    /// that step the collapsed size and leave the whole body drawn but deaf to
    /// the pointer.
    ///
    /// One tab is taller than the rest. Type large enough to read at a glance
    /// leaves room for two lines in the standard body, and two lines is not a
    /// teleprompter — it is a countdown. The extra height buys the paragraph
    /// the reader needs to see coming.
    var openBodySize: CGSize {
        if showsSections { return geometry.sectionsBodySize(tabs: sections.count) }
        switch vm.tab {
        case .teleprompter: return geometry.tallExpandedSize
        case .media: return geometry.mediaExpandedSize
        case .clipboard: return geometry.clipboardExpandedSize
        default: return geometry.expandedSize
        }
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize { isActive ? openBodySize : geometry.notchSize }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    ///
    /// The tab is shared and the keyboard is not: choosing on one screen
    /// changes what every screen shows, but only this one starts listening.
    func select(_ tab: NotchViewModel.Tab) {
        showsSections = false
        vm.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    // MARK: - Navigation

    /// Every tab that is switched on, in the order the grid shows them.
    var sections: [NotchViewModel.Tab] { vm.leftRail + vm.rightRail }

    /// What the round buttons beside and below the island stand for. The
    /// grid on the left is the way to everything; the rest are the sections
    /// reached for most, one click away. A tab switched off loses its button.
    enum Button: Hashable {
        case sections
        case tab(NotchViewModel.Tab)
    }

    var leftButtons: [Button] { [.sections] + tabs([.focus]) }
    var rightButtons: [Button] { tabs([.settings, .shelf]) }
    var bottomButtons: [Button] { tabs([.media]) }

    private func tabs(_ list: [NotchViewModel.Tab]) -> [Button] {
        list.filter(vm.isVisible).map { .tab($0) }
    }

    func press(_ button: Button) {
        switch button {
        case .sections:
            showsSections.toggle()
            if showsSections { wantsKeyboard = false }
        case .tab(let tab):
            select(tab)
        }
    }

    private func notify(_ changed: Bool) {
        guard changed else { return }
        onChange?()
    }
}
