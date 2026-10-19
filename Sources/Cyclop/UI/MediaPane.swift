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
    /// The cover's own colour, for the progress bar. White for a cover with
    /// no colour to speak of.
    @State private var tint = Color.white

    /// Artwork and the text column share this height, so their top and bottom
    /// edges line up instead of the column floating past them.
    private let blockHeight: CGFloat = 112

    var body: some View {
        if let track = media.track {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    reveal { artwork(for: track) }
                    VStack(alignment: .leading, spacing: 0) {
                        reveal {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title)
                                    .font(.system(size: Theme.title, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(subtitle(for: track))
                                    .font(.system(size: Theme.body))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Where the song is, right under what the song is.
                        scrubber
                            .padding(.top, 10)
                        Spacer(minLength: 2)
                        controls
                    }
                    .frame(height: blockHeight)
                }
                bottomRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 2)
            // Title and artist arrive together, so the whole column can cross-
            // fade as one unit when the track changes.
            .animation(Theme.artworkAnimation, value: track.key)
            .onAppear { tint = ArtworkTint.color(of: media.artwork) }
            .onChange(of: media.artwork) { _, image in
                withAnimation(Theme.artworkAnimation) { tint = ArtworkTint.color(of: image) }
            }
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
                SkeletonBox(cornerRadius: Theme.radiusXL)
            }
        }
        .frame(width: blockHeight, height: blockHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        // The same shape again, this time for the pointer. `clipShape` hides
        // overflow but does not stop it being touched, and that overhang once
        // reached the tab rail on the left, where four icons stopped answering
        // the pointer (#22). Fitting non-square covers takes the overflow away
        // at its source; this stays as the guard it always was.
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusXL, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
        // A paused cover steps back a little, as the phone's does.
        .scaleEffect(media.isPlaying ? 1 : 0.94)
        .animation(.smooth(duration: 0.3), value: media.isPlaying)
        .animation(Theme.artworkAnimation, value: media.artwork)
    }

    // MARK: - Scrubber

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 7 : 5

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14)).frame(height: height)
                    // Deliberately unanimated: a seek has to land under the
                    // cursor at once. Smoothness comes from the tick rate
                    // instead, which keeps each step well under a pixel.
                    Capsule()
                        .fill(tint.opacity(0.92))
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
            .frame(height: 12)

            HStack {
                Text(formatTime(progress * media.duration))
                    .rollingNumber(formatTime(progress * media.duration))
                Spacer()
                // What is left rather than the length: the number that
                // changes is the one worth reading.
                Text("−" + formatTime(max(media.duration - progress * media.duration, 0)))
            }
            .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Transport

    /// Skipping is dimmed, not hidden, when the player does not offer it — a
    /// video in a browser tab has nothing to skip to, so the command would
    /// leave and nothing would happen. Dim says "not here"; a button that
    /// looks live and does nothing says "broken". The system's own Now Playing
    /// widget dims the same two arrows on the same session.
    private var controls: some View {
        HStack(spacing: 26) {
            Button { media.previous() } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(IslandPressStyle(shape: Circle()))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)

            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(IslandPressStyle(shape: Circle()))
            .animation(.smooth(duration: 0.22), value: media.isPlaying)

            Button { media.next() } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(IslandPressStyle(shape: Circle()))
            .disabled(!media.canSkip)
            .opacity(media.canSkip ? 1 : 0.35)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: media.canSkip)
    }

    /// The volume across the bottom, and where the sound goes.
    private var bottomRow: some View {
        HStack(spacing: 12) {
            VolumeControl(volume: volume, barWidth: 240, barHeight: 8)
            Spacer(minLength: 0)
            OutputPicker(volume: volume)
        }
        .frame(height: 26)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            // Status, not instruction: an empty pane on its own would not say
            // whether nothing is playing or nothing could be read.
            Text("Nothing is playing")
                .font(.system(size: Theme.body, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the Mac's sound goes: the device now, and the others on click.
private struct OutputPicker: View {
    @ObservedObject var volume: SystemVolume

    private var current: SystemVolume.Output? {
        volume.outputs.first { $0.id == volume.currentOutput }
    }

    var body: some View {
        Menu {
            ForEach(volume.outputs) { output in
                Button {
                    volume.selectOutput(output.id)
                } label: {
                    if output.id == volume.currentOutput {
                        Label(output.name, systemImage: "checkmark")
                    } else {
                        Text(output.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill")
                    .font(.system(size: 11, weight: .medium))
                Text(current?.name ?? localized("Output"))
                    .font(.system(size: Theme.footnote, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(IslandPressStyle(shape: Capsule(), lifts: false))
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 200, alignment: .trailing)
        .help(localized("Output"))
        .onAppear { volume.refreshOutputs() }
        .onHover { if $0 { volume.refreshOutputs() } }
    }
}

/// The colour a cover is known by, picked from a thumbnail of it: the most
/// vivid of its reasonably bright pixels, lifted until it reads on black.
enum ArtworkTint {
    static func color(of image: NSImage?) -> Color {
        guard let image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var best: (score: CGFloat, hue: CGFloat, saturation: CGFloat)?
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let color = NSColor(
                red: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                blue: CGFloat(pixels[i + 2]) / 255, alpha: 1
            )
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard brightness > 0.25 else { continue }
            let score = saturation * brightness
            if score > (best?.score ?? 0) { best = (score, hue, saturation) }
        }
        // A grey, black or white cover has no colour to lend.
        guard let best, best.saturation > 0.3 else { return .white }
        return Color(hue: Double(best.hue), saturation: Double(min(best.saturation, 0.75)), brightness: 0.95)
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
