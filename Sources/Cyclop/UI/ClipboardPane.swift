import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var browser: ClipboardBrowser
    @ObservedObject var privacy: PrivacyMode
    /// Whether the panel holds the keyboard, so the search field can follow.
    @Binding var wantsKeyboard: Bool

    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = browser.visible
        let selected = browser.selected
        VStack(spacing: 6) {
            search
            if clipboard.items.isEmpty {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                Text(localized("Nothing found"))
                    .font(.system(size: Theme.footnote, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                ClipRow(
                                    item: item,
                                    shortcut: index < 9 ? index + 1 : nil,
                                    isSelected: item.id == selected?.id,
                                    clipboard: clipboard,
                                    browser: browser,
                                    privacy: privacy
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: browser.scrollTarget) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                    .onChange(of: browser.query) { _, _ in
                        if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
                .overlay {
                    if browser.previewing, let selected {
                        ClipPreview(item: selected) { browser.previewing = false }
                            .transition(.opacity)
                    }
                }
            }
        }
        .padding(.top, 2)
        // Asked again a moment later, not only on the spot: the pane is
        // still being inserted when the panel opens, and a focus request
        // that lands before the field is in the window is dropped silently.
        // That is what left the caret out of the search after ⌥⇧C.
        .task(id: wantsKeyboard) {
            guard wantsKeyboard else {
                searchFocused = false
                return
            }
            for delay in [0, 60, 250] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, wantsKeyboard else { return }
                searchFocused = true
            }
        }
        .animation(Theme.contentAnimation, value: browser.previewing)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField(localized("Search"), text: $browser.query)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.footnote))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($searchFocused)
            if !browser.query.isEmpty {
                Button { browser.query = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
            }
            PrivacySwitch(privacy: privacy, section: .clipboard)
            Button(localized("Clear")) { clipboard.clear() }
                .buttonStyle(.plain)
                .font(.system(size: Theme.caption, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .pointerStyle(.default)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
    }
}

/// One copy, large: the whole text rather than its first line, with where and
/// when it was copied. Opened with → or the expand button, closed with ←,
/// Escape or a click.
private struct ClipPreview: View {
    let item: ClipItem
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .image(let url, _) = item.payload {
                Group {
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(item.fullText)
                        .font(.system(size: Theme.body))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 6) {
                if let app = item.app {
                    Text(app)
                }
                if case .image = item.payload {
                    Text(item.fullText)
                }
                Text(Self.stamp(item.date))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surfaceHover))
                }
                .buttonStyle(.plain)
                .pointerStyle(.default)
            }
            .font(.system(size: Theme.caption, weight: .medium))
            .foregroundStyle(Theme.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .fill(Color(white: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
        )
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        return formatter.string(from: date)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    /// Where the arrow keys stand. Drawn like a hover, so the mouse and the
    /// keys point at rows the same way.
    /// ⌘ and this number copy the row: the first nine of whatever the list
    /// shows right now, search included.
    let shortcut: Int?
    let isSelected: Bool
    @ObservedObject var clipboard: ClipboardStore
    let browser: ClipboardBrowser
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }
    private var isImage: Bool {
        if case .image = item.payload { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            if case .image(let url, _) = item.payload {
                ClipThumbnail(url: url)
                    .blur(radius: hidden ? 8 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXS, style: .continuous))
            }
            SpoilerText(
                text: item.preview.replacingOccurrences(of: "\n", with: " "),
                hidden: hidden,
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )
            Spacer(minLength: 6)
            if hovering {
                if privacy.covers(.clipboard) {
                    RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                }
                if !hidden {
                    Button {
                        browser.selectedID = item.id
                        browser.previewing = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localized("Open large"))
                }
                Button { clipboard.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            } else if let shortcut {
                // Where the buttons go on hover, so the row keeps its width.
                Text("⌘\(shortcut)")
                    .font(.system(size: Theme.caption, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 9)
        // A picture gets a row tall enough to recognise it by; text stays at
        // one line.
        .frame(height: isImage ? 48 : 26)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .fill(hovering || isSelected ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { browser.selectedID = item.id }
        }
        .onTapGesture {
            clipboard.copy(item)
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}

/// A small copy of a picture in the history, made once and kept: decoding a
/// full screenshot for every row on every redraw would make the list crawl.
private struct ClipThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = Self.thumbnail(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 64, height: 38)
    }

    @MainActor private static let cache = NSCache<NSURL, NSImage>()

    @MainActor
    private static func thumbnail(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
