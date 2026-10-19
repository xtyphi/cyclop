import SwiftUI

/// The two sides of the folded notch while something runs: what it is on
/// the left, how it is going on the right — the Dynamic Island's compact
/// layout, split around the camera.
///
/// Each side watches its own store. The view model forwards nothing while
/// the panel is folded, and a clock that redrew the whole panel every second
/// to move two digits would be the wrong way round.
enum LiveActivityWings {
    /// The colours of the timer's dial: orange at work, green at rest.
    static func tint(for phase: FocusTimer.Phase) -> Color {
        phase == .rest
            ? Color(red: 0.30, green: 0.80, blue: 0.55)
            : Color(red: 1.0, green: 0.55, blue: 0.25)
    }

    struct Leading: View {
        let kind: LiveActivity.Kind
        @ObservedObject var focus: FocusTimer
        @ObservedObject var media: MediaController

        var body: some View {
            switch kind {
            case .focus:
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveActivityWings.tint(for: focus.phase))
                    .contentTransition(.symbolEffect(.replace))
            case .media:
                // Swapped as one piece, scaling through a cross-fade, when the
                // source or the cover changes — Telegram's icon giving way to
                // Spotify's cover used to cut over in a single frame.
                ZStack {
                    mediaGlyph
                        .id(glyphID)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: glyphID)
            }
        }

        /// What the glyph shows: this track's cover, or this app's icon.
        private var glyphID: String {
            if media.isMusicPlayer, media.artwork != nil { return "cover:\(media.track?.key ?? "")" }
            return "app:\(media.sourcePID ?? 0)"
        }

        @ViewBuilder
        private var mediaGlyph: some View {
            // Music shows its cover; anything else — a voice message in
            // Telegram, a video in a browser — the icon of the app it is
            // playing in, which says more there than a thumbnail would.
            if media.isMusicPlayer, let artwork = media.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            } else if let icon = media.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous)
                            .fill(Theme.surfaceHover)
                    )
            }
        }

        private var symbol: String {
            if focus.isPaused { return "pause.fill" }
            return focus.phase == .rest ? "cup.and.saucer.fill" : "timer"
        }
    }

    struct Trailing: View {
        let kind: LiveActivity.Kind
        @ObservedObject var focus: FocusTimer
        @ObservedObject var media: MediaController
        /// Height of the strip the clock sits in.
        var height: CGFloat = 32

        var body: some View {
            switch kind {
            case .focus:
                // Its own once-a-second clock: the timer's ticker runs only
                // while the timer's pane is on screen.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let text = FocusPane.clock(left(at: context.date))
                    Text(text)
                        // As large as the strip allows, up to 16: read in
                        // passing, from the corner of an eye.
                        .font(.system(size: min(16, height - 6), weight: .medium).monospacedDigit())
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(focus.isPaused ? Theme.secondary : LiveActivityWings.tint(for: focus.phase))
                        .lineLimit(1)
                        .fixedSize()
                        .rollingNumber(text, countsDown: true)
                }
            case .media:
                EqualizerBars(isAnimating: media.isPlaying, color: Color.white.opacity(0.9), height: 16)
            }
        }

        private func left(at date: Date) -> TimeInterval {
            if let paused = focus.pausedRemaining { return paused }
            guard let endsAt = focus.endsAt else { return 0 }
            return max(endsAt.timeIntervalSince(date), 0)
        }
    }
}
