import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController
    let volume: SystemVolume
    /// Called along with the reveal: the panel has done its job the moment
    /// the other app comes forward.
    var dismiss: () -> Void = {}

    @State private var scrubHover = false
    /// Set while dragging, so the bar follows the finger instead of the clock.
    @State private var scrubbing: Double?

    /// Artwork and the text column share this height, so their top and bottom
    /// edges line up instead of the column floating past them.
    private let blockHeight: CGFloat = 122

    var body: some View {
        if let track = media.track {
            HStack(spacing: 18) {
                reveal { artwork(for: track) }
                VStack(alignment: .leading, spacing: 0) {
                    reveal {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(subtitle(for: track))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 6)
                    controls
                    Spacer(minLength: 6)
                    scrubber
                }
                .frame(height: blockHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Title and artist arrive together, so the whole column can cross-
            // fade as one unit when the track changes.
            .animation(Theme.artworkAnimation, value: track.key)
        } else {
            emptyState
        }
    }

    /// Cover and title lead back to whatever is playing: the browser with the
    /// video in it, Spotify, Music. Wrapped rather than given a button style,
    /// so the artwork and the text keep looking like what they are — the
    /// pointer turning into a hand is the whole invitation. Without a source
    /// to raise the click is simply not there, instead of being there and
    /// doing nothing.
    @ViewBuilder
    private func reveal<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if media.canRevealSource {
            content()
                .contentShape(Rectangle())
                .onTapGesture {
                    media.revealSource()
                    dismiss()
                }
                .modifier(PointingHandCursor())
                .help(media.sourceName.map { localized("Open %@", $0) } ?? "")
        } else {
            content()
        }
    }

    /// The system often repeats the title as the album name; showing
    /// "Artist — Title" twice reads like a bug.
    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if !track.album.isEmpty, track.album != track.title { parts.append(track.album) }
        return parts.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    // MARK: - Artwork

    /// Covers arrive at whatever size the source publishes, so squareness is
    /// a question about proportion, not about exact pixels: a 300x301 cover is
    /// square to everyone looking at it.
    private func isSquare(_ image: NSImage) -> Bool {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return true }
        return abs(size.width / size.height - 1) < 0.02
    }

    private func artwork(for track: MediaController.Track) -> some View {
        ZStack {
            if let image = media.artwork {
                // A square cover fills the box, as it always has. Anything of
                // another shape is fitted into it instead: `.fill` crops by the
                // shorter side, and a 16:9 thumbnail — what a video in a
                // browser tab publishes — loses 44 % of its width that way,
                // 22 % off each edge. On a video frame those edges are what
                // says which video it is: a face, a caption, an object (#33).
                Theme.surface
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: isSquare(image) ? .fill : .fit)
                    .transition(.opacity)
            } else {
                SkeletonBox(cornerRadius: 14)
            }
        }
        .frame(width: 118, height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // The same shape again, this time for the pointer. `clipShape` hides
        // overflow but does not stop it being touched, and that overhang once
        // reached the tab rail on the left, where four icons stopped answering
        // the pointer (#22). Fitting non-square covers takes the overflow away
        // at its source; this stays as the guard it always was.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        .animation(Theme.artworkAnimation, value: media.artwork)
    }

    // MARK: - Scrubber

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(formatTime(progress * media.duration))
                .frame(width: 32, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: height)
                    // Deliberately unanimated: a seek has to land under the
                    // cursor at once. Smoothness comes from the tick rate
                    // instead, which keeps each step well under a pixel.
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: filled, height: height)
                    if scrubHover {
                        Circle()
                            .fill(.white)
                            .frame(width: 11, height: 11)
                            .offset(x: min(max(filled - 5.5, 0), width - 11))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { scrubHover = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0 else { return }
                            let target = min(max(value.location.x / width, 0), 1)
                            // Seek first: clearing `scrubbing` beforehand would
                            // drop the bar back to the old position for a frame
                            // before the new one lands.
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
                .animation(Theme.contentAnimation, value: scrubHover)
            }
            .frame(height: 14)

            Text(formatTime(media.duration))
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: - Transport

    /// Skipping is dimmed, not hidden, when the player does not offer it — a
    /// video in a browser tab has nothing to skip to, so the command would
    /// leave and nothing would happen. Dim says "not here"; a button that
    /// looks live and does nothing says "broken". The system's own Now Playing
    /// widget dims the same two arrows on the same session.
    private var controls: some View {
        HStack(spacing: 20) {
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 40, prominent: true))
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(NotchButtonStyle(size: 30))
                .disabled(!media.canSkip)
                .opacity(media.canSkip ? 1 : 0.35)
        }
        .frame(maxWidth: .infinity)
        // Volume sits at the trailing edge, over the row rather than in it, so
        // the transport stays centred on the column as before.
        .overlay(alignment: .trailing) { VolumeControl(volume: volume) }
        .animation(.easeInOut(duration: 0.15), value: media.canSkip)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing or nothing could be read.
            Text("Nothing is playing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A hand over anything that leads somewhere.
///
/// The pushed cursor is remembered rather than popped on the way out alone:
/// the view under the pointer can go away while the pointer is still on it —
/// the player the cover pointed at quits, the track ends — and a push with no
/// matching pop leaves the whole Mac with a hand cursor until something else
/// happens to reset it.
private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != pushed else { return }
                pushed = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                guard pushed else { return }
                pushed = false
                NSCursor.pop()
            }
    }
}
