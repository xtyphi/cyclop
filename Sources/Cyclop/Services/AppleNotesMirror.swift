import AppKit

/// Copies scratch notes into Apple Notes, folder "Cyclop" of the default
/// account — which on most Macs is iCloud, so the note also reaches the phone.
///
/// One way only: Cyclop writes, Notes receives. An edit made on the Notes side
/// is overwritten by the next edit in Cyclop. Reading Notes back would mean
/// polling a slow AppleScript and parsing its HTML on every visit to the tab,
/// for a scratchpad whose notes live an hour.
///
/// Off by default: the first write makes macOS ask for permission to control
/// Notes, and that question should come from someone who switched this on.
@MainActor
enum AppleNotesMirror {
    private static let key = "mirrorToAppleNotes"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Its own queue rather than the players' one: launching Notes takes
    /// seconds, and the player state must not wait behind it.
    private static let queue = DispatchQueue(label: "com.cyclop.notes", qos: .utility)

    /// Writes the text into the note with this id, or into a new note when
    /// there is none yet or it was deleted in Notes. Answers with the id the
    /// text ended up under, nil if Notes refused.
    static func write(_ text: String, to id: String?, completion: @escaping @MainActor (String?) -> Void) {
        let body = quoted(html(text))
        let lookup = id.map { "set n to note id \(quoted($0))\n        set body of n to \(body)" } ?? "error number -1728"
        run("""
        tell application "Notes"
            try
                \(lookup)
            on error
                try
                    set f to folder "Cyclop" of default account
                on error
                    set f to make new folder at default account with properties {name:"Cyclop"}
                end try
                set n to make new note at f with properties {body:\(body)}
            end try
            return id of n
        end tell
        """) { completion($0?.stringValue) }
    }

    /// Into Notes' own Recently Deleted, where it stays for 30 days.
    static func delete(_ id: String) {
        run("""
        tell application "Notes"
            try
                delete note id \(quoted(id))
            end try
        end tell
        """) { _ in }
    }

    // MARK: - Script

    /// Notes takes the body as HTML and names the note after its first line.
    private static func html(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let escaped = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<div>\(escaped.isEmpty ? "<br>" : escaped)</div>"
        }.joined()
    }

    private static func quoted(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func run(_ source: String, completion: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != 0 {
                NSLog("Cyclop: Notes script error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            let answer = error == nil ? result : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(answer) } }
        }
    }
}
