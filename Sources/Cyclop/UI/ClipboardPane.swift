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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 3) {
                            ForEach(rows) { item in
                                ClipRow(
                                    item: item,
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
        .onChange(of: wantsKeyboard) { _, wants in searchFocused = wants }
        .onAppear { if wantsKeyboard { searchFocused = true } }
        .animation(Theme.contentAnimation, value: browser.previewing)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField(localized("Search"), text: $browser.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .pointerStyle(.default)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
            ScrollView {
                Text(item.fullText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if let app = item.app {
                    Text(app)
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
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(white: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
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
    let isSelected: Bool
    @ObservedObject var clipboard: ClipboardStore
    let browser: ClipboardBrowser
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
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
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
