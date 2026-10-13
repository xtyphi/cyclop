import Combine
import Foundation

/// What the folded notch carries on its sides between visits, the way the
/// Dynamic Island carries a timer or a song: a running sprint first, music
/// second, nothing otherwise.
///
/// The sprint wins because it is the one with a deadline. Music playing
/// during a sprint is the usual case, and its title can wait for a hover;
/// the time left cannot be read anywhere else without opening the panel.
@MainActor
final class LiveActivity: ObservableObject {
    enum Kind: Equatable {
        case focus
        case media
    }

    @Published private(set) var kind: Kind?

    private var cancellable: AnyCancellable?

    /// `hiddenTabs` stands in for the switches in Settings: a tab turned off
    /// is a feature turned off, and it does not come back through the side
    /// door of the notch.
    func bind(
        focus: FocusTimer,
        media: MediaController,
        hiddenTabs: some Publisher<Set<NotchViewModel.Tab>, Never>
    ) {
        cancellable = Publishers.CombineLatest4(
            focus.$phase,
            media.$isPlaying,
            media.$track.map { $0 != nil },
            hiddenTabs
        )
        .map { phase, playing, hasTrack, hidden -> Kind? in
            if phase != .idle, !hidden.contains(.focus) { return .focus }
            if playing, hasTrack, !hidden.contains(.media) { return .media }
            return nil
        }
        .removeDuplicates()
        .sink { [weak self] kind in self?.kind = kind }
    }
}
