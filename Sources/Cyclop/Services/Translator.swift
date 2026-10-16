import AppKit
import Translation

/// Apple's on-device translator, driven from the panel.
///
/// The session is not ours to create: `translationTask` hands one over and owns
/// its lifetime, so everything here is about deciding *what* to translate and
/// holding the result. `TranslatePane` supplies the session.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")

    /// Both ends are always named. Leaving the source to the framework looks
    /// tempting, but its identifier is a separate asset that is not installed
    /// either — auto-detection fails with `unableToIdentifyLanguage`, and the
    /// translation that follows hangs instead of returning an error.
    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op.
    struct Request: Equatable {
        var text: String
        var attempt: Int
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing language pack, which is a thing the user can
    /// go and fix — so the pane offers the button that takes them there.
    @Published private(set) var needsDownload = false
    /// Checked when the tab opens, before anything is typed: an empty pane
    /// with no pack behind it would otherwise look ready and do nothing.
    @Published private(set) var packMissing = false
    /// Misspelled words in the input with the spelling macOS would put
    /// instead. Shown under the field as one-tap fixes.
    @Published private(set) var fixes: [Fix] = []

    struct Fix: Equatable, Identifiable {
        var range: NSRange
        var word: String
        var guess: String
        var id: Int { range.location }
    }

    private var attempt = 0

    var request: Request { Request(text: input, attempt: attempt) }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { Self.route(for: trimmed) }

    /// Russian goes out to English, everything else comes in to Russian.
    ///
    /// Decided by script rather than by language detection: a single word is
    /// far too short to identify reliably, and "привет" comes back as Bulgarian
    /// often enough to matter.
    static func route(for text: String) -> Route {
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return cyrillic
            ? Route(source: russian, target: english)
            : Route(source: english, target: russian)
    }

    func retry() {
        attempt += 1
    }

    /// One pack covers both directions, so one check is enough.
    func checkPack() async {
        let status = await LanguageAvailability().status(from: Self.english, to: Self.russian)
        packMissing = status == .supported
    }

    func installPack() {
        LanguagePackInstaller.install(from: Self.english, to: Self.russian) { [weak self] in
            guard let self else { return }
            Task {
                await self.checkPack()
                if !self.packMissing { self.retry() }
            }
        }
    }

    // MARK: - Spelling

    /// Looked up after a pause in typing, with the same language the route
    /// picked: the system checker has both, but guessing the language of a
    /// single misspelled word is exactly where it goes wrong.
    func checkSpelling() {
        let text = input
        let language = route.source.languageCode?.identifier ?? "en"
        let checker = NSSpellChecker.shared
        var found: [Fix] = []
        var start = 0
        while found.count < 4 {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language,
                                              wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            start = range.location + range.length
            if let guess = checker.guesses(forWordRange: range, in: text, language: language,
                                           inSpellDocumentWithTag: 0)?.first {
                found.append(Fix(range: range, word: (text as NSString).substring(with: range), guess: guess))
            }
        }
        fixes = found
    }

    /// Back to front, so the ranges still ahead stay where they were. A word
    /// edited since the check is left alone rather than overwritten.
    func apply(_ chosen: [Fix]) {
        var text = input as NSString
        for fix in chosen.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(fix.range) <= text.length, text.substring(with: fix.range) == fix.word else { continue }
            text = text.replacingCharacters(in: fix.range, with: fix.guess) as NSString
        }
        fixes = []
        input = text as String
    }

    /// The result becomes the text to translate, which sends it back the
    /// other way: the direction follows the script of whatever is typed.
    func swap() {
        guard !output.isEmpty else { return }
        input = output
        output = ""
    }

    func clear() {
        fixes = []
        output = ""
        failure = nil
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: sending TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else { return }

        // No language pack ships installed. `prepareTranslation()` is what asks
        // for one, but it blocks until its system prompt is answered — and that
        // prompt has nowhere to appear over a borderless panel of an app that
        // never activates, so it would hang forever. Check instead, and send
        // the user to the one place that can actually install it.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    /// "Русский", "English" — for the column headers. Named in the language the
    /// panel itself is in, not in the system's: those two can differ, and a
    /// column headed in one language above a button worded in another reads as
    /// a mistake.
    static func name(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: code) else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Short code for the header badge — "EN → RU" reads at a glance where a
    /// spelled-out name would not fit in the strip.
    static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier.uppercased() ?? "?"
    }

    /// System Settings → General → Language & Region, which is where the
    /// "Translation Languages…" button lives.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
