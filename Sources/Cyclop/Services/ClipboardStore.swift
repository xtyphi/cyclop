import AppKit
import CryptoKit

struct ClipItem: Identifiable, Equatable {
    enum Payload: Equatable {
        case text(String)
        case file(URL)
        /// A picture kept by the history itself, under a name taken from its
        /// content — the same screenshot copied twice is one file and one row.
        case image(URL, CGSize)
    }

    var id = UUID()
    let payload: Payload
    let date: Date
    /// The app that was in front when the copy was made — almost always the
    /// one it was copied from. Shown in the enlarged view.
    var app: String?

    /// What a search is matched against: the whole text, or the file's path.
    var searchable: String {
        switch payload {
        case .text(let string): return string
        case .file(let url): return url.path
        // Nothing to match a picture against: a search shows text.
        case .image: return ""
        }
    }

    /// Everything, untrimmed, for the enlarged view.
    var fullText: String {
        switch payload {
        case .text(let string): return string
        case .file(let url): return url.path
        case .image(_, let size): return "\(Int(size.width)) × \(Int(size.height))"
        }
    }

    var preview: String {
        switch payload {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .file(let url):
            return url.lastPathComponent
        case .image(_, let size):
            return "\(Int(size.width)) × \(Int(size.height))"
        }
    }

    var symbol: String {
        switch payload {
        case .text(let string):
            if string.hasPrefix("http://") || string.hasPrefix("https://") { return "link" }
            return "text.alignleft"
        case .file:
            return "doc"
        case .image:
            return "photo"
        }
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool { lhs.payload == rhs.payload }
}

/// One line of the history file.
private struct ClipRecord: Codable {
    var id: UUID
    var kind: String
    var value: String
    var date: Date
    var app: String?
    var width: Double?
    var height: Double?

    init(_ item: ClipItem) {
        id = item.id
        date = item.date
        app = item.app
        switch item.payload {
        case .text(let string): kind = "text"; value = string
        case .file(let url): kind = "file"; value = url.path
        case .image(let url, let size):
            kind = "image"; value = url.lastPathComponent
            width = size.width; height = size.height
        }
    }

    var item: ClipItem? {
        switch kind {
        case "text": return ClipItem(id: id, payload: .text(value), date: date, app: app)
        case "file": return ClipItem(id: id, payload: .file(URL(fileURLWithPath: value)), date: date, app: app)
        case "image":
            // Stored by name and resolved against the folder, so the history
            // survives the folder moving with the app's support directory.
            let url = ClipboardStore.imageFolder.appendingPathComponent(value)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let size = CGSize(width: width ?? 0, height: height ?? 0)
            return ClipItem(id: id, payload: .image(url, size), date: date, app: app)
        default: return nil
        }
    }
}

/// Polls the general pasteboard's change counter. Cheap: one integer read
/// twice a second, and nothing at all is read until the counter moves.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    /// Raised for image data on the pasteboard — a screenshot taken straight to
    /// the clipboard, which would otherwise vanish after one paste.
    var onImage: ((Data) -> Void)?

    /// Whether images are worth reading at all. Asked before the TIFF → PNG
    /// encode, not after: with screenshot saving switched off, a copied picture
    /// would otherwise be encoded in full and then thrown away.
    var wantsImages: () -> Bool = { true }

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    /// A week back, as far as anyone goes looking for something copied. Kept
    /// on disk, so a restart does not take the week with it.
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// A ceiling under the week, for the week somebody copies a log line by
    /// line: past it the oldest go first.
    private let limit = 1000
    private static let file = Support.file("clipboard.json")
    /// Where copied pictures are kept for the week, one PNG each.
    nonisolated static let imageFolder = Support.directory("ClipboardImages")
    private let saves = DebouncedWrite(after: 1.0)
    private var lastPrune = Date.distantPast

    init() {
        load()
    }
    /// Types an app sets to keep a copy out of history tools. Presence is what
    /// counts, not content: a type can be declared with data that is still on
    /// its way, and asking for the bytes would then answer nil for a password
    /// that is about to arrive. `ConcealedType` is what password managers set;
    /// the other two mark copies made by a machine rather than by a hand.
    private let optOut: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    func start() {
        stop()
        prune()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // The half-second is a ceiling, not a beat: nobody notices a copy
        // landing in history a fifth of a second late, and the slack lets the
        // system fold this wake-up into others.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() {
        items.removeAll()
        scheduleSave()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    /// Writes whatever is waiting now. Called on quit.
    func flush() {
        saves.flush()
    }

    /// Puts an entry back on the pasteboard without re-recording it.
    func copy(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.payload {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .file(let url):
            pasteboard.writeObjects([url as NSURL])
        case .image(let url, _):
            if let data = try? Data(contentsOf: url) { pasteboard.setData(data, forType: .png) }
        }
        lastChangeCount = pasteboard.changeCount
        // Freshly used entries bubble to the top.
        if let index = items.firstIndex(where: { $0.id == item.id }), index != 0 {
            items.remove(at: index)
            items.insert(item, at: 0)
            scheduleSave()
        }
    }

    private func poll() {
        // Hourly rather than only on a copy: a quiet week must still let
        // the old ones go, from the file as well as from the list.
        if Date().timeIntervalSince(lastPrune) > 3600 {
            lastPrune = Date()
            prune()
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard pasteboard.availableType(from: optOut) == nil else { return }
        // Our own write — copying a screenshot back out of the shelf must not
        // save it to disk all over again.
        guard pasteboard.data(forType: .cyclopInternal) == nil else { return }

        // A copied file arrives as a URL, not as image data, so URLs win first.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first {
            record(ClipItem(payload: .file(url), date: Date(), app: Self.frontApp))
            return
        }

        // Pictures go to the history every time, and to the shelf as well
        // when that is switched on — two different places with two jobs. A
        // copy that also carries text, as one from a document or a table
        // often does, is kept in the history as its text: that is what a
        // search finds and what pasting it back is usually for.
        if let png = pngFromPasteboard(pasteboard) {
            receivedImage(png, from: pasteboard)
            return
        }
        // A copy made on the phone arrives in two parts: macOS puts the
        // type on the pasteboard the moment the phone announces it, and
        // the picture itself is still coming over the air. So the counter
        // can move while there are no bytes to read yet — and reading once
        // would drop the screenshot for good, because the counter has
        // already been marked as seen. Wait for it instead.
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            awaitImage(at: pasteboard.changeCount, attempt: 0)
            return
        }

        guard let string = pasteboard.string(forType: .string),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        record(ClipItem(payload: .text(string), date: Date(), app: Self.frontApp))
    }

    /// Checks back until the promised picture has actually arrived.
    ///
    /// Gives up after a few seconds, and stops the moment the pasteboard moves
    /// on: a copy made in the meantime is the newer intention, and finishing a
    /// transfer the user has already replaced would put the wrong thing on the
    /// shelf.
    private func awaitImage(at changeCount: Int, attempt: Int) {
        // Out of patience. Something declared a picture and never produced one,
        // so fall back to what else was on the pasteboard — otherwise a copy
        // that merely offered an image alongside its text would go unrecorded.
        guard attempt < 12 else {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount,
                  let string = pasteboard.string(forType: .string),
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            record(ClipItem(payload: .text(string), date: Date(), app: Self.frontApp))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                guard pasteboard.changeCount == changeCount else { return }
                if let png = self.pngFromPasteboard(pasteboard) {
                    self.receivedImage(png, from: pasteboard)
                    return
                }
                self.awaitImage(at: changeCount, attempt: attempt + 1)
            }
        }
    }

    /// Screenshots land as PNG; other apps often offer only TIFF.
    private func pngFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func receivedImage(_ png: Data, from pasteboard: NSPasteboard) {
        if wantsImages() { onImage?(png) }
        if let string = pasteboard.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record(ClipItem(payload: .text(string), date: Date(), app: Self.frontApp))
        } else {
            recordImage(png)
        }
    }

    /// Named after its content, so a picture copied again lands on the same
    /// file and replaces its old row instead of adding a second one.
    private func recordImage(_ png: Data) {
        let name = SHA256.hash(data: png).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        let url = Self.imageFolder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? png.write(to: url, options: .atomic)) != nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let size = NSBitmapImageRep(data: png).map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? .zero
        record(ClipItem(payload: .image(url, size), date: Date(), app: Self.frontApp))
    }

    private static var frontApp: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func record(_ item: ClipItem) {
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        prune()
        scheduleSave()
    }

    // MARK: - History file

    /// Drops what is older than the week. Run on start and on every copy, so
    /// a Mac left on for a fortnight still lets the old ones go.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let kept = items.filter { $0.date >= cutoff }
        guard kept.count != items.count else { return }
        items = kept
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let records = try? JSONDecoder().decode([ClipRecord].self, from: data)
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        items = Array(records.compactMap(\.item).filter { $0.date >= cutoff }.prefix(limit))
        // What was left behind goes from the file too, not only from view.
        if items.count != records.count { scheduleSave() }
    }

    private func scheduleSave() {
        saves.schedule { [weak self] in self?.save() }
    }

    /// Readable by this user only: copies include things nobody else on the
    /// Mac should be able to open — the password managers that mark theirs
    /// are skipped, the rest of what passes through cannot be told apart.
    private func save() {
        guard let data = try? JSONEncoder().encode(items.map(ClipRecord.init)) else { return }
        // Pictures go only once the list without them is on disk: a failed
        // write leaves a file that still names them, and so they stay.
        guard (try? data.write(to: Self.file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
        sweepImages()
    }

    /// Deletes the pictures no row points at any more — aged out, removed,
    /// or cleared. Only inside the history's own folder, and only after the
    /// list that no longer names them has been written.
    private func sweepImages() {
        let kept = Set(items.compactMap { item -> String? in
            if case .image(let url, _) = item.payload { return url.lastPathComponent }
            return nil
        })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.imageFolder.path)) ?? []
        for name in files where name.hasSuffix(".png") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: Self.imageFolder.appendingPathComponent(name))
        }
    }
}

/// Search, keyboard selection and the enlarged view over the history.
///
/// Apart from the store on purpose: the view model redraws the whole panel
/// whenever the store changes, and a query typed letter by letter would
/// redraw it on every keystroke.
@MainActor
final class ClipboardBrowser: ObservableObject {
    enum Key { case up, down, enter, escape, right, left }
    enum Outcome { case ignored, handled, close }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            selectedID = nil
            previewing = false
        }
    }
    @Published var selectedID: UUID?
    @Published var previewing = false
    /// The row the arrow keys just moved to. Separate from the selection,
    /// which the mouse moves too: scrolling to a row because the pointer
    /// rested on it would slide the list out from under the pointer.
    @Published private(set) var scrollTarget: UUID?

    let store: ClipboardStore
    /// Whether a row is under the privacy cover. A covered row is not opened
    /// large: that would uncover it without the eye being pressed.
    var isHidden: (ClipItem) -> Bool = { _ in false }

    init(store: ClipboardStore) {
        self.store = store
    }

    var visible: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.items }
        return store.items.filter {
            $0.searchable.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The chosen row, or the newest one until something is chosen — so
    /// Return straight after opening takes the last copy, as it would in any
    /// clipboard manager.
    var selected: ClipItem? {
        let rows = visible
        return rows.first { $0.id == selectedID } ?? rows.first
    }

    /// Back to a blank search at the top of the list.
    func reset() {
        query = ""
        selectedID = nil
        previewing = false
    }

    private func move(to id: UUID) {
        selectedID = id
        scrollTarget = id
    }

    func handle(_ key: Key) -> Outcome {
        let rows = visible
        let index = selected.flatMap { item in rows.firstIndex { $0.id == item.id } }
        switch key {
        case .up:
            if let index, index > 0 { move(to: rows[index - 1].id) }
            return .handled
        case .down:
            if let index, index + 1 < rows.count { move(to: rows[index + 1].id) }
            return .handled
        case .right:
            if let item = selected, !isHidden(item) { previewing = true }
            return .handled
        case .left:
            guard previewing else { return .ignored }
            previewing = false
            return .handled
        case .enter:
            guard let item = selected else { return .handled }
            store.copy(item)
            reset()
            return .close
        case .escape:
            if previewing {
                previewing = false
                return .handled
            }
            if !query.isEmpty {
                query = ""
                return .handled
            }
            reset()
            return .close
        }
    }
}
