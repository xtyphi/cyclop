import AppKit

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var edited: Date
    /// The copy in Apple Notes, when mirroring is on. Optional, so files
    /// written before it existed still decode.
    var appleID: String?
    /// The text Notes last confirmed. Kept in the file, so an edit that had
    /// not reached Notes when the app quit still goes on the next launch.
    var mirroredText: String?
}

/// Scratch notes: somewhere to put a thought down for an hour.
///
/// Deliberately not a notes app. No folders, no formatting, no search — for
/// that there are real editors. This replaces the unsaved buffer people keep
/// in one: a phone number from a call, half a link, a thought to come back to
/// — written fast, then deleted or carried off through the clipboard.
///
/// Everything here is shaped by that shortness of life: notes are created
/// empty and instantly, deleted in one click, and the blank ones sweep
/// themselves out when the tab is left. The file they live in is an
/// implementation detail — unlike the snippets file, nobody is expected to
/// edit it by hand.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// Which note the editor shows. Lives here rather than in the pane so the
    /// choice survives the pane being unmounted with the panel.
    @Published var selected: Note.ID?

    private static let file = Support.file("notes.json")

    private let saves = DebouncedWrite()

    /// Notes with a write still in flight. A note edited during its write
    /// goes again once the write answers: two writes at once would each create
    /// a note of their own.
    private var mirroring: Set<Note.ID> = []

    init() {
        load()
        // Picks up whatever did not make it last time: Notes refused, or the
        // app quit before the write answered.
        mirror()
    }

    // MARK: - Editing

    /// A new empty note, selected and ready to type into. Newest on top, and
    /// the order never changes afterwards: a list that reshuffles itself on
    /// every edit loses the reader's place for tidiness nobody asked for.
    func add() {
        let note = Note(id: UUID(), text: "", edited: Date())
        notes.insert(note, at: 0)
        selected = note.id
        scheduleSave()
    }

    func update(_ id: Note.ID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        notes[index].edited = Date()
        scheduleSave()
    }

    func remove(_ id: Note.ID) {
        // Only while mirroring is on: switched off, the Apple note is the
        // user's own and may hold things written there since.
        if AppleNotesMirror.isEnabled, let appleID = notes.first(where: { $0.id == id })?.appleID {
            AppleNotesMirror.delete(appleID)
        }
        notes.removeAll { $0.id == id }
        if selected == id { selected = notes.first?.id }
        scheduleSave()
    }

    /// Called when the user leaves the tab: notes that never got any text
    /// sweep themselves out. They cost one hover to recreate, and a trail of
    /// blank cards is exactly the clutter a scratchpad exists to avoid.
    func leave() {
        for note in notes where note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if AppleNotesMirror.isEnabled, let appleID = note.appleID { AppleNotesMirror.delete(appleID) }
        }
        notes.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let selected, !notes.contains(where: { $0.id == selected }) {
            self.selected = notes.first?.id
        }
        flush()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let stored = try? JSONDecoder().decode([Note].self, from: data) else { return }
        notes = stored
        selected = notes.first?.id
    }

    /// A moment after the typing pauses, not on every keystroke: the text
    /// lives in memory either way, and the file only has to be right by the
    /// time somebody could read it.
    private func scheduleSave() {
        saves.schedule { [weak self] in
            self?.persist()
            self?.mirror()
        }
    }

    // MARK: - Apple Notes

    /// Every note whose text Notes does not have yet. Blank ones wait: they
    /// are either about to be typed into or about to be swept out.
    func mirror() {
        guard AppleNotesMirror.isEnabled else { return }
        for note in notes where note.mirroredText != note.text && !mirroring.contains(note.id)
            && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            push(note)
        }
    }

    private func push(_ note: Note) {
        mirroring.insert(note.id)
        let text = note.text
        AppleNotesMirror.write(text, to: note.appleID) { [weak self] appleID in
            guard let self else { return }
            mirroring.remove(note.id)
            guard let appleID else { return }
            guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
                // Removed while Notes was still writing it.
                AppleNotesMirror.delete(appleID)
                return
            }
            notes[index].appleID = appleID
            notes[index].mirroredText = text
            // Straight to disk, not after a debounce: a crash before the id is
            // saved would make the next launch create the Apple note again.
            persist()
            if notes[index].text != text { mirror() }
        }
    }

    func flush() { saves.flush() }

    private func persist() {
        do {
            try JSONEncoder().encode(notes).write(to: Self.file, options: .atomic)
        } catch {
            NSLog("Cyclop: cannot write notes.json: \(error.localizedDescription)")
        }
    }
}
