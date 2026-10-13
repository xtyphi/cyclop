import Carbon.HIToolbox

/// A system-wide shortcut, through the Carbon hot key API.
///
/// Carbon rather than a global event monitor: a monitor only sees keys once
/// the app has been granted Accessibility, and it cannot stop the key from
/// also reaching the app in front. A registered hot key needs no permission
/// and is taken out of the stream, so ⌥⇧C opens the history instead of also
/// typing "Ç" into whatever has the caret.
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var nextID: UInt32 = 1

    /// `keyCode` is the physical key (`kVK_…`), so the shortcut stays on the
    /// same key in every keyboard layout; `modifiers` are Carbon's
    /// (`optionKey | shiftKey`). Nil when the combination is already taken.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4359_434C), id: id) // "CYCL"
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else { return nil }
        Self.actions[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            // Delivered on the main thread: Carbon events come in through the
            // main run loop.
            let id = hotKeyID.id
            MainActor.assumeIsolated { GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
