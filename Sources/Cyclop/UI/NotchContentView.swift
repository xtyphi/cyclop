import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// This screen's share of the panel. Everything the pointer decides is
    /// here; everything shown is in `vm`, the same on every display.
    @ObservedObject var panel: PanelState
    /// Watched on its own, like the counters below: the view model does not
    /// forward the timer, and the notice has to appear with the panel folded.
    @ObservedObject var alert: FocusAlert
    /// Watched here for the same reason: it decides the folded notch's width.
    @ObservedObject var activity: LiveActivity

    private var isOpen: Bool { panel.isActive }
    /// The folded notch grown sideways for the end-of-sprint notice.
    private var showsNotice: Bool { !isOpen && alert.current != nil }
    /// The timer or the song on the folded notch's sides. Only on a real
    /// notch: a drawn one is transparent at rest, and a black pill standing
    /// in the middle of an external display's menu bar for as long as music
    /// plays would be the panel claiming a screen it was asked to stay out of.
    private var activityKind: LiveActivity.Kind? {
        guard !isOpen, alert.current == nil, panel.geometry.isPhysical else { return nil }
        return activity.kind
    }
    private var size: CGSize {
        if showsNotice { return panel.geometry.alertSize }
        if let kind = activityKind { return panel.geometry.activitySize(for: kind) }
        return panel.bodySize
    }
    /// The island's outer size, shoulders included. Folded, the shoulders sit
    /// inside the notch's own width; open, they flare out past the body.
    private var outerSize: CGSize {
        guard isOpen else { return size }
        return CGSize(width: size.width + 2 * NotchShape.shoulder(forHeight: size.height), height: size.height)
    }
    /// A synthetic notch has content underneath it — a full-screen app on an
    /// external display — so at rest it is drawn transparent and only turns
    /// black once the panel opens.
    private var fillOpacity: Double { isOpen || showsNotice || panel.geometry.isPhysical ? 1 : 0 }

    @StateObject private var motion = IslandMotion()

    var body: some View {
        // Only the outline moves. Each layer is laid out once, at the size it
        // is going to have, and the outline reveals it: the panes never
        // re-lay themselves out on every frame of the spring.
        ZStack(alignment: .top) {
            IslandSilhouette(motion: motion)
                .opacity(fillOpacity)
                .animation(.easeOut(duration: 0.26), value: fillOpacity)

            ZStack(alignment: .top) {
                if isOpen {
                    openLayer
                        .modifier(IslandArrival())
                        // Gone at once on close: the outline is already
                        // folding over it, and a fade would only smear it.
                        .transition(.identity)
                } else {
                    foldedLayer
                        // Back once the outline has arrived, not while it is
                        // still pulling up past the strip.
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.26)),
                            removal: .identity
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(IslandSilhouette(motion: motion))

            // Outside the mask: the buttons stand beside the island, not in it.
            if isOpen {
                IslandButtons(vm: vm, panel: panel)
                    .transition(.opacity.animation(.easeIn(duration: 0.12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { motion.set(outerSize, animated: false) }
        .onChange(of: outerSize) { _, target in motion.set(target) }
    }

    // MARK: - Layers

    /// The open panel, at the full size of the tab on screen.
    private var openLayer: some View {
        let body = panel.openBodySize
        return VStack(spacing: 0) {
            openHeader
            page
                // Open, the notice floats over the top of the pane rather
                // than in the header strip, which is kept free of anything
                // clickable (see below).
                .overlay(alignment: .top) {
                    if let kind = alert.current {
                        FocusNotice(kind: kind, dismiss: alert.dismiss)
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: alert.current)
        }
        .frame(width: body.width, height: body.height, alignment: .top)
    }

    /// The folded notch: bare, or with the timer, the song or the notice on
    /// its sides.
    private var foldedLayer: some View {
        foldedHeader
            .frame(width: size.width, height: size.height, alignment: .top)
            .animation(.easeOut(duration: 0.2), value: activityKind)
            .animation(.easeOut(duration: 0.2), value: alert.current)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var foldedHeader: some View {
        HStack(spacing: 0) {
            // The one exception to the rule above, and only folded, for three
            // seconds: the notice needs a close button, and the notch is where
            // it is looked for.
            if showsNotice, let kind = alert.current {
                FocusNotice.Label(kind: kind)
                    .padding(.leading, 12)
                    .frame(width: NotchGeometry.alertWing, alignment: .leading)
                    .transition(.opacity)
            }
            if let kind = activityKind {
                activityWing(kind, leading: true) {
                    LiveActivityWings.Leading(kind: kind, focus: vm.focus, media: vm.media)
                }
            }
            Spacer(minLength: 0)
            if let kind = activityKind {
                activityWing(kind, leading: false) {
                    LiveActivityWings.Trailing(kind: kind, focus: vm.focus, media: vm.media, height: panel.geometry.notchSize.height)
                }
            }
            if showsNotice {
                FocusNotice.CloseButton(dismiss: alert.dismiss)
                    .padding(.trailing, 10)
                    .frame(width: NotchGeometry.alertWing, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .frame(height: panel.geometry.notchSize.height)
    }

    private var openHeader: some View {
        let title = panel.showsSections ? localized("Sections") : vm.tab.title
        return HStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: Theme.caption, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 16)
                .id(title)
                .transition(.opacity)
            Spacer(minLength: 0)
            Color.clear.frame(width: panel.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if !panel.showsSections {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: panel.geometry.notchSize.height)
        .animation(Theme.paneSwap, value: title)
    }

    /// One side of the folded notch's activity. A click on either side
    /// opens the panel on the tab it came from, as a tap on the Dynamic
    /// Island opens the app.
    ///
    /// Each side's content sits the same distance in from its outer edge —
    /// the cover's own top margin, so it is inset evenly on three sides — and
    /// not centred in its half: the cover and the bars differ in width, and
    /// centred they stood 16 pt and 13 pt from the edges, which read as the
    /// whole island sitting off to one side.
    private func activityWing(_ kind: LiveActivity.Kind, leading: Bool, @ViewBuilder content: () -> some View) -> some View {
        // Clear of the outline: the shoulders now sit inside the folded
        // width, so the content keeps 5 pt from the wall they curve into.
        let height = panel.geometry.notchSize.height
        let inset = max((height - 22) / 2, NotchShape.shoulder(forHeight: height) + 5)
        return Button {
            panel.onActivate?(kind == .focus ? .focus : .media)
        } label: {
            content()
                .padding(leading ? .leading : .trailing, inset)
                .frame(width: NotchGeometry.activityWing(for: kind), height: panel.geometry.notchSize.height,
                       alignment: leading ? .leading : .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName ?? "")
                    .font(.system(size: Theme.caption, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .snippets:
            counter(vm.snippets.items.count)
        case .calendar:
            if let next = vm.calendar.next {
                Text(CalendarPane.countdown(to: next, from: vm.calendar.now))
                    .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
                    .foregroundStyle(next.isRunning ? Color.white.opacity(0.8) : Theme.tertiary)
            }
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .currency:
            CurrencyRateDate(currencies: vm.currencies)
        case .limits:
            EmptyView()
        case .system:
            EmptyView()
        case .focus:
            FocusCounter(timer: vm.focus)
        case .notes:
            NotesCounter(notes: vm.notes)
        case .teleprompter:
            EmptyView()
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
                .rollingNumber(value)
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    /// The tab, or the grid of every section in its place.
    private var page: some View {
        ZStack(alignment: .top) {
            if panel.showsSections {
                SectionsGallery(vm: vm, panel: panel)
                    .transition(.opacity.animation(Theme.paneSwap))
            } else {
                panes
                    .padding(.horizontal, 14)
                    // The body's height is measured from this same number.
                    .padding(.bottom, NotchGeometry.bodyBottomPadding)
                    .transition(.opacity.animation(Theme.paneSwap))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var panes: some View {
        // Content is replaced in place — a plain cross-fade, no travel and no
        // zoom. The rail is vertical and the panes are unrelated, so either
        // would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.opacity.animation(Theme.paneSwap))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            MediaPane(media: vm.media, volume: vm.volume, dismiss: { panel.onDismiss?() })
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: panel.isDropTargeted)
        case .clipboard:
            ClipboardPane(
                clipboard: vm.clipboard,
                browser: vm.clipboardBrowser,
                privacy: vm.privacy,
                wantsKeyboard: $panel.wantsKeyboard
            )
        case .calendar:
            CalendarPane(calendar: vm.calendar, privacy: vm.privacy)
        case .snippets:
            SnippetsPane(snippets: vm.snippets, privacy: vm.privacy, wantsKeyboard: $panel.wantsKeyboard)
        case .translate:
            TranslatePane(translator: vm.translator, wantsKeyboard: $panel.wantsKeyboard)
        case .currency:
            CurrencyPane(currencies: vm.currencies, wantsKeyboard: $panel.wantsKeyboard)
        case .limits:
            LimitsPane(limits: vm.limits)
        case .system:
            SystemPane(load: vm.load)
        case .focus:
            FocusPane(timer: vm.focus)
        case .notes:
            NotesPane(notes: vm.notes, privacy: vm.privacy, wantsKeyboard: $panel.wantsKeyboard)
        case .teleprompter:
            TeleprompterPane(prompter: vm.teleprompter, wantsKeyboard: $panel.wantsKeyboard)
        case .settings:
            SettingsPane(vm: vm, shelf: vm.shelf, screenshots: vm.screenshotFolder)
        }
    }
}

/// Watches the note store itself rather than reading through the view model:
/// notes are born and deleted inside the pane while this counter is on
/// screen, and the view model deliberately does not forward keystroke-driven
/// stores.
private struct NotesCounter: View {
    @ObservedObject var notes: NoteStore

    var body: some View {
        if !notes.notes.isEmpty {
            Text("\(notes.notes.count)")
                .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
                .rollingNumber(notes.notes.count)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// Same reason as `NotesCounter`: rate fetches must not redraw the whole panel
/// on every keystroke in the amount fields, so the date badge observes the
/// store on its own.
private struct CurrencyRateDate: View {
    @ObservedObject var currencies: CurrencyStore

    var body: some View {
        if let date = currencies.pairDate {
            // Named when it is the official rate, so a figure that differs
            // from a market quote elsewhere says why.
            Text(currencies.usesCentralBank ? "\(localized("CBR")) · \(date)" : date)
                .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// Sprints done today, beside the tab name. Watches the timer directly: the
/// view model does not forward its changes, so the header would otherwise
/// show the count from whenever something else last redrew it.
private struct FocusCounter: View {
    @ObservedObject var timer: FocusTimer

    var body: some View {
        if timer.completedToday > 0 {
            Text("\(timer.completedToday)")
                .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
                .rollingNumber(timer.completedToday)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// What the end of a sprint or a break looks like in the notch. Folded, the
/// label and the close button sit on either side of the notch; open, the two
/// come together in a capsule over the pane.
private struct FocusNotice: View {
    let kind: FocusAlert.Kind
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label(kind: kind)
            CloseButton(dismiss: dismiss)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(Capsule().fill(Color(white: 0.16)))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    }

    struct Label: View {
        let kind: FocusAlert.Kind

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: kind == .sprintEnded ? "cup.and.saucer.fill" : "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                Text(kind == .sprintEnded ? localized("Break") : localized("Back to work"))
                    .font(.system(size: Theme.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }

        /// The colours of the phase being entered, as on the timer's dial.
        private var color: Color {
            kind == .sprintEnded
                ? Color(red: 0.30, green: 0.80, blue: 0.55)
                : Color(red: 1.0, green: 0.55, blue: 0.25)
        }
    }

    /// Silences the chime and closes the notice in one press.
    struct CloseButton: View {
        let dismiss: () -> Void

        var body: some View {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.surfaceHover))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(localized("Dismiss"))
        }
    }
}
