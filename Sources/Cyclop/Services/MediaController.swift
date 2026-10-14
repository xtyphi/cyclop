import AppKit

/// Now Playing for whatever the system is playing — browser tabs included.
///
/// Primary source is `NowPlayingFeed`, which reaches MediaRemote through a
/// helper hosted by `/usr/bin/perl`. If that route ever closes, the controller
/// falls back to scripting Apple Music and Spotify directly.
@MainActor
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var key: String
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var sourceName: String?
    /// Whether the player accepts skipping at all. A browser tab playing one
    /// video registers no handler for it — the command leaves and nothing
    /// happens — so the buttons go dim rather than dead, the way the system's
    /// own Now Playing widget dims them for the same session. True until told
    /// otherwise: the scripted fallback below drives Music and Spotify, and
    /// both skip fine.
    @Published private(set) var canSkip = true

    /// Whether the source can be brought forward at all: a session whose
    /// owner has since quit leaves its name on screen but nothing to raise.
    @Published private(set) var canRevealSource = false

    private(set) var sourcePID: pid_t? {
        didSet { canRevealSource = runningSource != nil }
    }

    private let feed = NowPlayingFeed()
    private var feedAvailable = true

    private var activeApp: PlayerApp?
    /// A scriptable player shown in place of the system's choice. macOS names
    /// one app as playing — the last to claim it — and keeps naming it after
    /// it pauses: start a Telegram voice message over Spotify, pause it, and
    /// the system goes on reporting a paused Telegram while Spotify plays.
    /// While the system's pick is paused and Spotify or Music is playing,
    /// that player is shown, and the buttons go to it.
    private var overrideApp: PlayerApp?
    /// Bumped whenever something plays through the system, so a player check
    /// still out then does not override it on its way back.
    private var overrideCheck = 0
    /// A player check is out; later answers wait for it instead of starting
    /// their own. Restarting on every answer starved the check outright when
    /// the scripts took longer than the feed's next answer.
    private var overrideChecking = false
    /// The newest answer from the feed, which a returning check judges.
    private var latestSnapshot: NowPlayingFeed.Snapshot?
    /// What the focus chime paused, so it resumes that and nothing else: the
    /// system's pick can change during the chime.
    private var alertPaused: (override: PlayerApp?, pid: pid_t?)?
    private var overrideObservers: [Any] = []
    private var artworkKey: String?
    /// The track a missing cover was already asked for again, so a source
    /// that has none (a voice message) is asked once, not on every update.
    private var artworkRetryKey: String?
    private var anchor: (position: TimeInterval, at: Date)?
    /// Where we asked the player to jump, and when — see `apply`.
    private var pendingSeek: (target: TimeInterval, at: Date)?
    private var ticker: Timer?
    private var observers: [Any] = []
    /// Whether the panel is open — the ticker below runs only then.
    private var isActive = false

    // MARK: - Lifecycle

    func start() {
        feed.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        feed.onUnavailable = { [weak self] in self?.switchToScriptingFallback() }
        feed.start()

        // Spotify and Music announce their own changes. Listened to only to
        // keep an overriding player current — the feed covers the rest.
        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            overrideObservers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshOverride() }
            })
        }
    }

    func stop() {
        feed.stop()
        (observers + overrideObservers).forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        overrideObservers.removeAll()
        overrideApp = nil
        ticker?.invalidate()
        ticker = nil
    }

    /// Panel visibility. The position ticker hangs off this: it exists to move
    /// a bar, and a bar in a collapsed panel is painted for nobody — at four
    /// wake-ups a second for as long as anything plays. The position itself is
    /// never lost, because the anchor records where it stood and when: opening
    /// computes it from there instantly, and the feed's fresh answer corrects
    /// whatever drifted a beat later.
    func setActive(_ active: Bool) {
        isActive = active
        updateTicker()
        guard active else { return }
        tick()
        if feedAvailable {
            feed.refresh()
        } else {
            refreshFromPlayers()
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        // Optimistic flip so the button feels instant; the feed corrects it.
        isPlaying.toggle()
        setAnchor(position)
        // The per-client command set has no toggle of its own (#23) — Play
        // and Pause are sent explicitly, by the state just flipped to above.
        dispatch(feed: isPlaying ? .play : .pause, script: { PlayerBridge.playPause($0) }, key: .playPause)
    }

    /// For the focus chime: stops what is playing and says whether it did,
    /// so that only music it stopped is started again afterwards.
    func pauseIfPlaying() -> Bool {
        guard track != nil, isPlaying else { return false }
        alertPaused = (overrideApp, sourcePID)
        togglePlayPause()
        return true
    }

    /// The other half. Skipped if something already started it again in the
    /// meantime — the user, or the player itself.
    func resumeIfPaused() {
        let paused = alertPaused
        alertPaused = nil
        guard track != nil, !isPlaying,
              let paused, paused.override == overrideApp, paused.pid == sourcePID else { return }
        togglePlayPause()
    }

    func next() {
        dispatch(feed: .next, script: { PlayerBridge.next($0) }, key: .next)
    }

    func previous() {
        dispatch(feed: .previous, script: { PlayerBridge.previous($0) }, key: .previous)
    }

    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        setAnchor(clamped)
        pendingSeek = (clamped, Date())
        if let overrideApp {
            PlayerBridge.seek(overrideApp, to: clamped)
        } else if feedAvailable {
            feed.seek(to: clamped)
        } else if let activeApp {
            PlayerBridge.seek(activeApp, to: clamped)
        }
    }

    private func dispatch(
        feed command: NowPlayingFeed.Command,
        script: (PlayerApp) -> Void,
        key: PlayerBridge.MediaKey
    ) {
        // The system's active player is not the one on screen, so a command
        // through the feed would reach the paused one.
        if let overrideApp {
            script(overrideApp)
        } else if feedAvailable {
            feed.send(command)
        } else if let activeApp {
            script(activeApp)
        } else {
            PlayerBridge.postMediaKey(key.rawValue)
        }
    }

    // MARK: - Feed

    private func apply(_ snapshot: NowPlayingFeed.Snapshot) {
        latestSnapshot = snapshot
        guard !snapshot.isPlaying, PlayerApp.allCases.contains(where: \.isRunning) else {
            overrideCheck += 1
            overrideApp = nil
            return applyFeed(snapshot)
        }
        // Once shown, the player stays shown until something plays through the
        // system again — pausing it from the panel must not hand the screen
        // back to the voice message paused ten minutes ago.
        if overrideApp != nil { return refreshOverride() }
        // The system's pick is paused, or there is none: is a scriptable
        // player playing on its own? Asked before anything is shown, so a
        // paused voice message does not flash up on its way out.
        guard !overrideChecking else { return }
        overrideChecking = true
        let check = overrideCheck
        PlayerBridge.currentState { [weak self] state in
            guard let self else { return }
            self.overrideChecking = false
            guard check == self.overrideCheck, let snapshot = self.latestSnapshot else { return }
            if snapshot.isPlaying { return self.applyFeed(snapshot) }
            let source = snapshot.sourcePID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            if let state, state.isPlaying, state.app.bundleID != source {
                self.overrideApp = state.app
                self.adoptScripted(state)
            } else {
                self.overrideApp = nil
                self.applyFeed(snapshot)
            }
        }
    }

    /// An overriding player changed — paused, skipped, resumed. Gone, it
    /// stops overriding and the system's own pick is asked for again.
    private func refreshOverride() {
        guard feedAvailable, let app = overrideApp else { return }
        PlayerBridge.state(of: app) { [weak self] state in
            guard let self, self.overrideApp == app else { return }
            if let state {
                self.adoptScripted(state)
            } else {
                self.overrideApp = nil
                self.feed.refresh()
            }
        }
    }

    private func applyFeed(_ snapshot: NowPlayingFeed.Snapshot) {
        guard !snapshot.isEmpty else { return clear() }

        let key = "\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        // The helper reads the owning pid one call ahead of the record, so the
        // first report of a new track still names whoever was playing before
        // it — enough for a click on the cover to raise the wrong app. Asking
        // again the moment the track changes costs one line on a pipe and
        // closes that window to the time it takes to answer.
        let switched = track?.key != key
        track = Track(title: snapshot.title, artist: snapshot.artist, album: snapshot.album, key: key)
        if switched, feedAvailable { feed.refresh() }
        // The system's own answer, and nothing else. The rate looks like a
        // second witness but is not one: Telegram keeps reporting its speed
        // setting — 1.5 for a voice message at 1.5× — straight through a
        // pause, and reading that as playing kept the notch's equalizer going
        // over silence. Control Center goes by the flag alone too.
        isPlaying = snapshot.isPlaying
        duration = snapshot.duration
        sourceName = snapshot.source
        sourcePID = snapshot.sourcePID
        // Both directions travel together: no player has ever offered one
        // without the other, and two separately dimmed arrows would read as
        // a glitch rather than a limit.
        canSkip = snapshot.offers(.next) && snapshot.offers(.previous)

        let reported = reportedPosition(from: snapshot)

        // A player needs a moment to act on a seek, and until it does it keeps
        // reporting the old position. Accepting that would yank the bar back.
        if let pending = pendingSeek {
            let settled = abs(reported - pending.target) < 2.5
            let expired = Date().timeIntervalSince(pending.at) > 1.5
            if settled || expired {
                pendingSeek = nil
                adopt(reported)
            }
        } else {
            adopt(reported)
        }
        updateTicker()

        if let data = snapshot.artwork {
            artworkKey = key
            decodeArtwork(data, for: key)
        } else if artworkKey != key {
            // Track changed and the payload carried no artwork; the skeleton
            // covers the gap until the system publishes the new cover.
            artworkKey = key
            artwork = nil
        }

        // Still no cover a moment later: ask for it outright. The helper sends
        // a cover once per track, so one that got lost on the way never came
        // back by itself — the panel sat on the skeleton until the next song.
        if artwork == nil, snapshot.artwork == nil, artworkRetryKey != key {
            artworkRetryKey = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.artwork == nil, self.track?.key == key, self.overrideApp == nil else { return }
                self.feed.refreshArtwork()
            }
        }
    }

    /// JPEG decoding on the main thread is what makes a track change stutter,
    /// so it happens off it and the finished image is handed back.
    private func decodeArtwork(_ data: Data, for key: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else { return }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    private func clear() {
        activeApp = nil
        track = nil
        artwork = nil
        artworkKey = nil
        isPlaying = false
        duration = 0
        position = 0
        sourceName = nil
        sourcePID = nil
        canSkip = true
        updateTicker()
    }

    // MARK: - Source

    /// The icon of the app the sound is coming from — Spotify, the browser,
    /// Telegram. Redrawn with `canRevealSource`, which changes whenever the
    /// source does.
    var sourceIcon: NSImage? { runningSource?.icon }

    /// Players whose artwork is an album cover. Everything else — a browser,
    /// Telegram, a video player — sends a thumbnail or nothing, and is
    /// better told apart by its own icon.
    private static let musicPlayers: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.iTunes",
        "ru.yandex.desktop.music",
        "ru.yandex.music",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "com.coppertino.Vox",
        "com.apple.podcasts",
    ]

    /// True when the sound is music from a music player: then the cover says
    /// more than the icon of the app it came from.
    var isMusicPlayer: Bool {
        guard let id = runningSource?.bundleIdentifier else { return false }
        return Self.musicPlayers.contains(id)
    }

    private var runningSource: NSRunningApplication? {
        sourcePID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    /// Brings the player forward — the browser tab, Spotify, whatever owns the
    /// session. A tab is as far as this goes: which tab inside that browser is
    /// playing is not something the app is told, and is not worth guessing at
    /// by driving another app's windows.
    func revealSource() {
        guard let app = runningSource else {
            canRevealSource = false
            return
        }
        app.activate(options: [.activateAllWindows])
    }

    // MARK: - Fallback: scriptable players only

    private func switchToScriptingFallback() {
        guard feedAvailable else { return }
        feedAvailable = false
        // The scripting route has its own idea of the active player.
        overrideApp = nil
        overrideCheck += 1
        // Nothing reports supported commands on this route, and the two apps it
        // drives both skip — so the arrows come back rather than staying dim
        // on a state no longer being refreshed.
        canSkip = true
        NSLog("Cyclop: Now Playing helper unavailable, falling back to Music/Spotify scripting")

        let center = DistributedNotificationCenter.default()
        for app in PlayerApp.allCases {
            observers.append(center.addObserver(
                forName: app.changeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activeApp = app
                    self?.refreshFromPlayers()
                }
            })
        }
        refreshFromPlayers()
    }

    private func refreshFromPlayers() {
        PlayerBridge.currentState { [weak self] state in
            guard let self else { return }
            guard let state else { return self.clear() }
            self.adoptScripted(state)
        }
    }

    /// Shows a player's state as read by script: the whole of the fallback
    /// route, and the overriding player on the feed's.
    private func adoptScripted(_ state: PlayerState) {
        activeApp = state.app
        // Spotify and Music both skip; nothing on this route says otherwise.
        canSkip = true
        sourceName = state.app.displayName
        sourcePID = NSRunningApplication
            .runningApplications(withBundleIdentifier: state.app.bundleID).first?
            .processIdentifier
        track = Track(title: state.title, artist: state.artist, album: state.album, key: state.key)
        isPlaying = state.isPlaying
        duration = state.duration
        adopt(state.position)
        updateTicker()

        guard artworkKey != state.key else { return }
        artworkKey = state.key
        artwork = nil
        PlayerBridge.artwork(for: state) { [weak self] image in
            guard let self, self.artworkKey == state.key else { return }
            artwork = image
        }
    }

    // MARK: - Position

    /// What a report actually says by the time it is read.
    ///
    /// MediaRemote does not keep the elapsed time running. The field is a
    /// reading taken when the session last changed state, and the timestamp
    /// beside it says when — a tab playing for three minutes keeps reporting
    /// the second it started at, and many browsers report a plain zero. Taken
    /// literally, every refresh describes the beginning of the track, and
    /// `adopt` reads the gap as a seek made in the player and obeys it. Which
    /// is exactly what hovering did: open the panel, refresh, bar to zero.
    ///
    /// So the reading is aged by the clock that came with it. A paused session
    /// is left alone — its reading is not moving and there is nothing to add.
    private func reportedPosition(from snapshot: NowPlayingFeed.Snapshot) -> TimeInterval {
        // Paused, the clock stands still whatever rate is reported (see `apply`).
        guard snapshot.isPlaying, let takenAt = snapshot.takenAt else {
            return snapshot.elapsed
        }
        let since = Date().timeIntervalSince(takenAt)
        // A stamp from the future is not a clock to add to. Trust the reading.
        guard since >= 0 else { return snapshot.elapsed }
        let rate = snapshot.rate > 0 ? snapshot.rate : 1
        let aged = snapshot.elapsed + since * rate
        return snapshot.duration > 0 ? min(aged, snapshot.duration) : aged
    }

    private func setAnchor(_ value: TimeInterval) {
        position = value
        anchor = (value, Date())
    }

    /// Below this a forward correction is pipeline jitter, not movement.
    private let forwardTolerance: TimeInterval = 0.75
    /// A disagreement this large is an event — a seek made in the player
    /// itself, or a track change — not a discrepancy to be smoothed over.
    private let seekThreshold: TimeInterval = 2

    /// Takes a position reported by the player, without letting the report undo
    /// what has already been shown.
    ///
    /// Every reading arrives late: the helper, the pipe and the parse sit
    /// between the player's clock and ours, so a report is normally a little
    /// *behind* the bar. Accepting it moves the bar backwards — and backwards
    /// is the one direction anybody notices, because time does not do it. So
    /// the two directions get different rules rather than one shared tolerance:
    /// backwards only for something big enough to be a real event, forwards for
    /// anything past the jitter. Left alone, the bar keeps its own count, which
    /// runs at exactly the speed the music does.
    private func adopt(_ reported: TimeInterval) {
        var value = max(0, reported)
        if duration > 0 { value = min(value, duration) }
        let delta = value - position

        if delta >= forwardTolerance || delta <= -seekThreshold {
            position = value
            anchor = (value, Date())
        } else {
            // Keep what is on screen and re-base the clock under it, so the
            // ignored difference cannot accumulate into the next comparison.
            anchor = (position, Date())
        }
    }

    private func updateTicker() {
        ticker?.invalidate()
        ticker = nil
        guard isPlaying, isActive else { return }
        // Four times a second: the bar advances in sub-pixel steps, so it reads
        // as smooth without any animation smoothing the seek away with it.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        guard let anchor, isPlaying else { return }
        let value = anchor.position + Date().timeIntervalSince(anchor.at)
        position = duration > 0 ? min(value, duration) : value
    }
}
