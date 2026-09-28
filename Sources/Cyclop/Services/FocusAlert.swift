import AppKit

/// The end of a sprint or a break: one chime, the music paused for as long
/// as it rings, and five seconds of the notch saying which of the two ended.
///
/// The music is paused rather than played over. A chime mixed into music from
/// the same speakers is the one that went unheard, and there is no public way
/// to lower another app's volume on its own — only the whole Mac's, which
/// would lower the chime with it. So the player stops for the chime, the way
/// a phone's alarm interrupts it, and picks up again once it has rung out —
/// not after the notice, which stays up longer than anyone needs silence.
@MainActor
final class FocusAlert: ObservableObject {
    enum Kind: Equatable {
        /// Work is over and the break has started.
        case sprintEnded
        /// The break is over; the next sprint waits for a click.
        case breakEnded
    }

    @Published private(set) var current: Kind?

    /// Wired to the player by the view model. `pauseMedia` answers whether
    /// it actually stopped something, so only music this paused is resumed.
    var pauseMedia: () -> Bool = { false }
    var resumeMedia: () -> Void = {}

    static let duration: TimeInterval = 5

    private var sound: NSSound?
    private var pausedMedia = false
    private var expiry: DispatchWorkItem?
    private var resumption: DispatchWorkItem?

    func fire(_ kind: Kind) {
        expiry?.cancel()
        resumption?.cancel()
        sound?.stop()
        // A second alert inside the first one's chime keeps the music
        // it already paused rather than finding it stopped and doing nothing.
        if !pausedMedia { pausedMedia = pauseMedia() }

        // A copy: `NSSound(named:)` hands out one shared instance, and a
        // shared sound is one somebody else's `stop` could cut. The same
        // chime for both ends: the notch says which one it was.
        let sound = NSSound(named: "Blow")?.copy() as? NSSound
        sound?.play()
        self.sound = sound
        current = kind

        // The music comes back a beat after the chime has rung out.
        let resume = DispatchWorkItem { [weak self] in self?.resumeMediaIfPaused() }
        resumption = resume
        DispatchQueue.main.asyncAfter(deadline: .now() + (sound?.duration ?? 0) + 0.4, execute: resume)

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration, execute: work)
    }

    /// Silences the chime and takes the notice down, early or on time.
    func dismiss() {
        guard current != nil else { return }
        expiry?.cancel()
        expiry = nil
        sound?.stop()
        sound = nil
        current = nil
        resumeMediaIfPaused()
    }

    private func resumeMediaIfPaused() {
        resumption?.cancel()
        resumption = nil
        guard pausedMedia else { return }
        pausedMedia = false
        resumeMedia()
    }
}
