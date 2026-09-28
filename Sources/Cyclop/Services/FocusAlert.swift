import AppKit

/// The three seconds at the end of a sprint or a break: a chime on a loop,
/// the music paused underneath it, and the notch saying which of the two
/// ended.
///
/// The music is paused rather than played over. A chime mixed into music from
/// the same speakers is the one that went unheard, and there is no public way
/// to lower another app's volume on its own — only the whole Mac's, which
/// would lower the chime with it. So the player stops for the three seconds,
/// the way a phone's alarm interrupts it, and picks up again afterwards.
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

    static let duration: TimeInterval = 3

    private var sound: NSSound?
    private var pausedMedia = false
    private var expiry: DispatchWorkItem?

    func fire(_ kind: Kind) {
        expiry?.cancel()
        sound?.stop()
        // A second alert inside the first one's three seconds keeps the music
        // it already paused rather than finding it stopped and doing nothing.
        if !pausedMedia { pausedMedia = pauseMedia() }

        // A copy: `NSSound(named:)` hands out one shared instance, and a
        // looping shared sound is one somebody else's `stop` would cut.
        let sound = NSSound(named: kind == .sprintEnded ? "Glass" : "Hero")?.copy() as? NSSound
        sound?.loops = true
        sound?.play()
        self.sound = sound
        current = kind

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
        if pausedMedia {
            pausedMedia = false
            resumeMedia()
        }
    }
}
