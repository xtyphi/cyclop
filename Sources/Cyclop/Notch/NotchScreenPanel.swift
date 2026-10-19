import AppKit
import Combine
import SwiftUI

/// The panel as it stands on one display: the window, the view, hover
/// tracking, and the open/close mechanics.
///
/// Every instance shares one `NotchViewModel` — the tab and the services are
/// the same wherever you look — and keeps its own `PanelState`, window and
/// pointer watcher, because whether *this* notch is open depends only on where
/// the pointer is on *this* screen. The watchers cost nothing to have in
/// duplicate: the pointer is on one display at a time, so at most one of them
/// is ever sampling at full rate (see `PointerWatcher.updateRate`).
@MainActor
final class NotchScreenPanel {
    let geometry: NotchGeometry
    let state: PanelState

    /// Whether a running teleprompter is holding this screen open. Set by the
    /// controller for the one screen the take was started from — see
    /// `NotchViewModel.holdsOpen` for why the exception exists at all, and
    /// `NotchController.updatePin` for why it is granted to a single screen.
    var isPinned = false

    /// Opened by the clipboard shortcut rather than by the pointer. Held open
    /// with the pointer anywhere, because the shortcut is pressed with the
    /// mouse wherever it happens to be; let go of when the keyboard is —
    /// Escape, Return, or a click into another app.
    private(set) var isSummoned = false

    private let vm: NotchViewModel
    private let pointer = PointerWatcher()
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var cancellables = Set<AnyCancellable>()
    private var closeActiveRectWork: DispatchWorkItem?
    /// Monotonic stamp for the deferred half of closing: any newer open or
    /// close outdates the one still in flight.
    private var openGeneration = 0

    init(geometry: NotchGeometry, vm: NotchViewModel) {
        self.geometry = geometry
        self.vm = vm
        self.state = PanelState(geometry: geometry, vm: vm)
        build()
    }

    func teardown() {
        pointer.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
    }

    func toggle() {
        setOpen(!state.isOpen)
        pointer.setInside(state.isOpen)
    }

    /// Same display, same notch, moved: keep the panel and everything on it.
    func setFrame(_ frame: CGRect) {
        panel?.setFrame(frame, display: false)
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    func activeSpaceChanged() {
        guard state.isOpen else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

    /// A dark display has no hover to watch, so the one timer that never
    /// otherwise stops — the pointer sampler — stops with it. The panel closes
    /// too, so waking always starts from the same, folded state.
    func screensSlept() {
        setOpen(false)
        pointer.setInside(false)
        pointer.stop()
    }

    func screensWoke() {
        pointer.start()
    }

    // MARK: - Construction

    private func build() {
        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm, panel: state, alert: vm.focus.alert, activity: vm.liveActivity))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        root.addSubview(hosting)

        root.onDragEntered = { [weak self] in
            // A shelf that is switched off is not a drop target: the panel
            // does not open for a file it has nowhere to show.
            guard let self, vm.isVisible(.shelf) else { return }
            state.select(.shelf)
            state.isDropTargeted = true
            setOpen(true)
        }
        root.onDragExited = { [weak self] in
            guard let self else { return }
            state.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            scheduleCollapseIfPointerAway()
        }
        root.onDrop = { [weak self] urls in
            guard let self else { return false }
            state.isDropTargeted = false
            let accepted = vm.accept(urls: urls)
            pointer.setInside(true)
            setOpen(true)
            scheduleCollapseIfPointerAway()
            return accepted
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        panel.onKey = { [weak self] event in
            self?.handleKey(event) ?? false
        }

        panel.onPress = { [weak self] in
            // A click on the folded notch can only be a click on the focus
            // notice: it closes the notice, and must not open a typing tab.
            guard let self, state.isOpen || foldedSize == geometry.collapsedSize else { return }
            guard vm.clickTakesKeyboard else { return }
            state.wantsKeyboard = true
        }

        state.onActivate = { [weak self] tab in
            guard let self else { return }
            state.select(tab)
            setOpen(true)
            scheduleCollapseIfPointerAway()
        }

        state.onDismiss = { [weak self] in
            guard let self else { return }
            setOpen(false)
            pointer.suppressUntilExit()
        }

        panel.contentView = root
        panel.ignoresMouseEvents = true
        panel.setFrame(geometry.windowFrame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
        self.rootView = root

        applyActiveRect(open: false)

        pointer.warmZone = geometry.warmZone
        // Cut for the tab that will be showing, not for the standard body: the
        // tab is shared, so a screen built while the teleprompter is up opens
        // straight into a body twice as deep as the rest.
        pointer.closeRect = openHoverRect
        // Nothing under the notch means opening the moment the pointer arrives
        // costs nothing. A notch with menu bar icons under it is the other
        // case: a pointer crossing them is usually on its way to one of them,
        // and unfolding the panel over what it was reaching for is the whole
        // complaint. There, staying put is what asks for the panel.
        pointer.openDelay = geometry.guardsIcons ? 0.3 : 0.05
        pointer.isDragging = { [weak root] in root?.isReceivingDrag ?? false }
        pointer.isPanelOpen = { [weak state] in state?.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            guard let self else { return }
            // The one place the pointer does not decide — see `holdsOpen`.
            // Guarded here rather than inside `setOpen` so that the reasons
            // that are not the pointer, like the screen going to sleep, still
            // close a running teleprompter.
            if !inside, holdsOpen { return }
            setOpen(inside)
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
        }
        pointer.start()

        // Switching tabs can change how far down the panel reaches, and both
        // the clickable region and the region the pointer counts as "on the
        // panel" are cut from that. Left alone, the teleprompter would open to
        // its full height with only its top 208 pt alive.
        vm.$tab
            .removeDuplicates()
            .sink { [weak self] tab in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Leaving the tab that types gives the keyboard back, on
                    // whichever screen was holding it.
                    if !tab.needsKeyboard { self.state.wantsKeyboard = false }
                    guard self.state.isOpen else { return }
                    // A pass later: `openBodySize` reads `tab`, and this fires
                    // while the property is still being set.
                    DispatchQueue.main.async { self.refreshOpenRects() }
                }
            }
            .store(in: &cancellables)

        // The focus notice widens the folded notch for five seconds, and
        // its close button has to be clickable for exactly that long. Open,
        // the panel's own rect already covers where the notice is drawn.
        // The timer or the song on the folded notch's sides widens it for as
        // long as either runs, and the sides are clickable for that long.
        Publishers.Merge(
            vm.focus.alert.$current.removeDuplicates().map { _ in () },
            vm.liveActivity.$kind.removeDuplicates().map { _ in () }
        )
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    // A pass later, for the same reason as the tab: this
                    // fires while the value is still being set.
                    DispatchQueue.main.async {
                        guard let self, !self.state.isOpen else { return }
                        self.applyActiveRect(open: false)
                    }
                }
            }
            .store(in: &cancellables)

        // The sections grid is a body of its own size, and the buttons around
        // it move with its edges.
        state.$showsSections
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.async { self?.refreshOpenRects() }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state.isOpen else { return }
                    self.menuRelease?.cancel()
                    self.isMenuOpen = true
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isMenuOpen else { return }
                    // The pointer decides again, from wherever the choice left
                    // it — once the grace is over.
                    let release = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.isMenuOpen = false
                        self.scheduleCollapseIfPointerAway(after: 0)
                    }
                    self.menuRelease?.cancel()
                    self.menuRelease = release
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuGrace, execute: release)
                }
            }
            .store(in: &cancellables)

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on the typing tab now, and that alone must not take
        // the keyboard away from the window underneath.
        state.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped. This is
        // also what hands the keyboard between screens: the panel that takes it
        // makes itself key, and the one that had it hears about it here.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.state.wantsKeyboard = false }
            }
            .store(in: &cancellables)

        // A fresh panel starts closed. If the pointer is already sitting on
        // it — a display just woke, or was plugged in under the cursor —
        // reopen at once instead of waiting for a trip back to the notch.
        if openHoverRect.contains(NSEvent.mouseLocation) {
            pointer.setInside(true)
            setOpen(true)
        }
    }

    // MARK: - Open / close

    /// Whether something other than the pointer holds this screen open: a
    /// running script, or the clipboard shortcut.
    private var holdsOpen: Bool { (isPinned && vm.holdsOpen) || isSummoned || isMenuOpen }

    /// A menu opened from the panel — the output picker — is up. It hangs
    /// below the island, so the pointer choosing from it is off the panel by
    /// every rect, and folding the island there took the menu away mid-choice.
    ///
    /// Held for a moment after the menu closes, too: the choice is made with
    /// the pointer below the island, and the way back to it should not race
    /// the fold.
    private var isMenuOpen = false
    private var menuRelease: DispatchWorkItem?
    private static let menuGrace: TimeInterval = 2

    /// The clipboard shortcut: the history, open, with the caret in search.
    /// Pressed again while it is up, it closes it.
    func summon(_ tab: NotchViewModel.Tab) {
        if isSummoned, state.isOpen {
            dismissSummoned()
            return
        }
        vm.clipboardBrowser.reset()
        vm.tab = tab
        isSummoned = true
        state.wantsKeyboard = true
    }

    private func dismissSummoned() {
        isSummoned = false
        state.onDismiss?()
    }

    /// Arrows, Return and Escape for the clipboard list. Only those keys, only
    /// unmodified, and only while the list is what is on screen — everything
    /// else carries on to the search field as typing.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard state.isOpen, vm.tab == .clipboard else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key: ClipboardBrowser.Key
        // Maccy's two: ⌘1…⌘9 for a row by its place, ⌥⌫ to drop one. By key
        // code, so they hold in any keyboard layout.
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if flags == .command, let number = digits[event.keyCode] {
            key = .pick(number)
        } else if flags == .option, event.keyCode == 51 {
            key = .delete
        } else if flags == .option, event.keyCode == 36 || event.keyCode == 76 {
            key = .paste
        } else {
            guard flags.isEmpty else { return false }
            switch Int(event.keyCode) {
            case 126: key = .up
            case 125: key = .down
            case 124: key = .right
            case 123: key = .left
            case 36, 76: key = .enter
            case 53: key = .escape
            default: return false
            }
        }
        switch vm.clipboardBrowser.handle(key) {
        case .ignored: return false
        case .handled: return true
        case .close:
            dismissSummoned()
            return true
        case .closeAndPaste:
            dismissSummoned()
            Paster.pasteSoon()
            return true
        }
    }

    /// Hands the keyboard to the panel, or gives it back.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true)
        }
        panel?.acceptsKeyboard = wants
        // The shortcut's hold is a hold on the keyboard: once that is gone —
        // a click into another app, most often — the pointer decides again.
        if !wants { isSummoned = false }
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants {
            // An open panel hands the keyboard back in `collapse`, a pass after
            // the fold has started — see `NotchPanel.releaseKey`. Closed, there
            // is no animation to protect, so it goes at once (#44).
            if !state.isOpen {
                DispatchQueue.main.async { [weak self] in self?.panel?.releaseKey() }
            }
            scheduleCollapseIfPointerAway()
        }
    }

    /// The pointer decides, almost always. A field with something in it does
    /// not hold the panel open: it is opened by hovering, and anything that
    /// survives the pointer leaving has to be dismissed some other way, which
    /// is a second rule to learn for a panel that has exactly one. What was
    /// typed is kept, so coming back finds it where it was left.
    ///
    /// The teleprompter is the single exception, and it is one because it
    /// cannot be anything else: a script is read while looking at the camera,
    /// which is precisely the moment nobody is touching the trackpad. The
    /// exception is held as narrow as it goes — one tab, one screen, and only
    /// while the script is actually moving — and it is enforced where the
    /// pointer is read, not here. Everything else that closes the panel still
    /// closes it: the screen sleeping, the space changing, the display
    /// arrangement changing. A pinned teleprompter surviving any of those
    /// would be a panel stuck open on a screen nobody is looking at.
    private func setOpen(_ open: Bool) {
        guard state.isOpen != open else { return }
        // Closing ends the take, but only on the screen reading it: the pin is
        // a consequence of the script moving, so the script stops with the
        // panel it is moving on — and not with any other panel folding away.
        if !open, isPinned { vm.teleprompter.suspend() }
        if !open { isSummoned = false }
        openGeneration += 1
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            // No SwiftUI animation: the outline moves on its own springs and
            // the content brings itself in (`IslandMotion`, `IslandArrival`).
            // An animated transaction here would also animate every frame
            // inside the panel, which is the reflow this is built to avoid.
            state.isOpen = true
            // The history is opened to search it, by hover as much as by the
            // shortcut, so it takes the caret on arrival. A pass later: this
            // runs inside the open that the keyboard request would start.
            if vm.tab == .clipboard {
                DispatchQueue.main.async { [weak self] in
                    guard let self, state.isOpen, vm.tab == .clipboard else { return }
                    state.wantsKeyboard = true
                }
            }
        } else {
            // The keyboard goes first and the fold goes second — one run-loop
            // pass apart, never together. Dropped in the same pass, resigning
            // the field's first responder and structurally removing that field
            // land in one transaction, and SwiftUI applies the state but loses
            // the repaint: the panel stands on screen fully expanded with
            // `isOpen` already false, wedged until the next hover repaints it.
            // That was the translate tab "hanging open" — type, move the
            // pointer away, and the picture stayed while the state closed.
            state.wantsKeyboard = false
            let generation = openGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, openGeneration == generation else { return }
                collapse()
            }
        }
    }

    /// The visual half of closing, one pass after the keyboard was let go.
    private func collapse() {
        guard state.isOpen else { return }
        state.isOpen = false
        // The next visit starts on the tab, not on the grid it was chosen from.
        state.showsSections = false

        // The keyboard goes back only now, a pass after the fold has started:
        // `acceptsKeyboard` no longer does it on its own, precisely because the
        // window's round trip landed mid-fold and took the repaint with it.
        //
        // The repaint is then asked for outright. Even if some future order of
        // events loses it again, the picture must not be left disagreeing with
        // the state: that disagreement is what made the panel unclosable and its
        // buttons dead, since clicks land by state and the drawing said other
        // (#44).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            panel?.releaseKey()
            state.objectWillChange.send()
            rootView?.needsDisplay = true
            panel?.displayIfNeeded()
        }

        // Shrink only once the panel has finished collapsing. Doing it
        // while it is still visibly there would leave a window in which
        // clicks land on whatever is behind the panel.
        let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
        closeActiveRectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func scheduleCollapseIfPointerAway(after delay: TimeInterval = 0.6) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !openHoverRect.contains(NSEvent.mouseLocation)
            pointer.setInside(!away)
            if away, !holdsOpen { setOpen(false) }
        }
    }

    /// Re-cuts both rects for the body currently on screen.
    private func refreshOpenRects() {
        guard state.isOpen else { return }
        applyActiveRect(open: true)
        pointer.closeRect = openHoverRect
    }

    /// The round buttons around the open body, in window coordinates.
    private var buttonRects: [CGRect] {
        geometry.buttonRects(
            for: state.openBodySize,
            left: state.leftButtons.count,
            right: state.rightButtons.count,
            bottom: state.bottomButtons.count
        )
    }

    /// Where the pointer counts as still on the open panel: the body, and the
    /// buttons around it with a margin — the pointer crossing the gap on its
    /// way to a button must not read as leaving.
    private var openHoverRect: CGRect {
        buttonRects
            .map { geometry.screenRect($0).insetBy(dx: -16, dy: -16) }
            .reduce(geometry.hoverRect(for: state.openBodySize)) { $0.union($1) }
    }

    /// What the folded notch claims: the notice, the timer or the song on
    /// its sides, or the notch alone. The sides only on a real notch — on a
    /// drawn one they would be a black pill parked over a full-screen app.
    private var foldedSize: CGSize {
        if vm.focus.alert.current != nil { return geometry.alertSize }
        if let kind = vm.liveActivity.kind, geometry.isPhysical { return geometry.activitySize(for: kind) }
        return geometry.collapsedSize
    }

    private func applyActiveRect(open: Bool) {
        guard let rootView else { return }
        // Collapsed, the panel claims only its target strip — on a synthetic
        // notch that is deliberately shallower than the menu bar, so clicks on
        // status items underneath reach them instead of a panel nobody can see.
        // The open size is the current tab's, not a constant: the teleprompter
        // is taller, and a rect cut for 208 would leave the bottom half of it
        // visible but untouchable.
        let size = open ? state.openBodySize : foldedSize
        var rect = geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -NotchShape.maxShoulder, dy: 0)
        }
        rootView.activeRects = open ? [rect] + buttonRects : [rect]
        // Follows the folded shape for the timer or the song on its sides. Not
        // for the end-of-sprint notice: its close button sits on a side, and a
        // pointer on its way to it would open the panel over it.
        if !open {
            let showsActivity = vm.focus.alert.current == nil && vm.liveActivity.kind != nil && geometry.isPhysical
            pointer.openRect = showsActivity
                ? geometry.hoverRect(folded: foldedSize.width)
                : geometry.hoverRect
        }
        let island = geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -NotchShape.maxShoulder : 0, dy: 0)
        pointer.interactiveRects = open ? [island] + buttonRects.map(geometry.screenRect) : [island]
    }
}
