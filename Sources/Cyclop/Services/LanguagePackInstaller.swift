import AppKit
import SwiftUI
import Translation

/// Downloads a language pack from inside Cyclop.
///
/// `prepareTranslation()` asks for the download in a sheet, and a sheet needs
/// an ordinary window of an active app to hang from — the panel is neither. So
/// a small window comes up for the length of the question, the app activates
/// for it, and both go away once the system has answered.
@MainActor
enum LanguagePackInstaller {
    private static var window: NSWindow?

    static func install(from source: Locale.Language, to target: Locale.Language, done: @escaping @MainActor () -> Void) {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }

        let host = NSHostingController(rootView: Prompt(source: source, target: target) {
            close()
            done()
        })
        let window = NSWindow(contentViewController: host)
        window.title = localized("Translation Languages…")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 120))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func close() {
        window?.close()
        window = nil
    }

    private struct Prompt: View {
        let source: Locale.Language
        let target: Locale.Language
        let finish: @MainActor () -> Void

        @State private var configuration: TranslationSession.Configuration?

        var body: some View {
            Text(localized("Downloading %@ ↔ %@…", Translator.name(source), Translator.name(target)))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { configuration = .init(source: source, target: target) }
                .translationTask(configuration) { session in
                    await prepare(session)
                    finish()
                }
        }

        /// Answers once the user has agreed and the download is done, or with
        /// an error once they have declined.
        private func prepare(_ session: sending TranslationSession) async {
            try? await session.prepareTranslation()
        }
    }
}
