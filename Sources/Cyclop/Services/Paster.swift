import AppKit
import ApplicationServices

/// Pastes into whatever app is in front, by pressing ⌘V for it.
///
/// A synthetic key press needs Accessibility. Without it the first attempt
/// asks for it, and the copy is still made — so the row is on the clipboard
/// either way, and ⌘V by hand finishes the job.
@MainActor
enum Paster {
    static func pasteSoon() {
        guard AXIsProcessTrusted() else {
            // The literal rather than `kAXTrustedCheckOptionPrompt`, which is
            // a mutable global Swift 6 will not read from here.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        // After the panel has folded and handed the keyboard back, so the
        // press lands in the app underneath and not in the search field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pressCommandV() }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // the V key, whatever the layout prints on it
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            // Command alone: ⌥ is most likely still held from ⌥Enter, and
            // ⌥⌘V means "move" in Finder rather than "paste".
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
