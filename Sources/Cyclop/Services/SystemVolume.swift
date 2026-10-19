import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's output volume, the one the volume keys move.
///
/// System volume rather than the player's own: the source on the Music tab is
/// whatever macOS reports as Now Playing — a browser tab as often as a player —
/// and a browser tab has no volume anyone outside it can reach. The output
/// device does, through CoreAudio, with no permission asked.
///
/// Listeners rather than a poll: nothing runs until the volume or the default
/// output actually changes.
@MainActor
final class SystemVolume: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isMuted = false
    /// False for outputs with no software volume — HDMI and some USB DACs.
    @Published private(set) var isAvailable = false
    /// Every device sound can go to, and the one it goes to now.
    @Published private(set) var outputs: [Output] = []
    @Published private(set) var currentOutput = AudioObjectID(kAudioObjectUnknown)

    struct Output: Identifiable, Hashable {
        let id: AudioObjectID
        let name: String
    }

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listening = false
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    func start() {
        guard !listening else { return }
        listening = true
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.bindDefaultDevice() }
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener
        )
        bindDefaultDevice()
    }

    func stop() {
        guard listening else { return }
        listening = false
        unbindDevice()
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, deviceListener
            )
        }
        deviceListener = nil
    }

    /// 0…1. Moving the slider off zero also lifts a mute — a muted Mac with a
    /// slider halfway up would read as broken.
    func setLevel(_ value: Float) {
        guard isAvailable else { return }
        var clamped = min(max(value, 0), 1)
        AudioObjectSetPropertyData(
            device, &Self.volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped
        )
        if isMuted, clamped > 0 { setMuted(false) }
        level = clamped
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    private func setMuted(_ muted: Bool) {
        guard isAvailable, AudioObjectHasProperty(device, &Self.muteAddress) else { return }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &Self.muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        // A read-only mute refuses the write; the speaker must not claim silence.
        if status == noErr { isMuted = muted }
    }

    // MARK: - Outputs

    /// Re-reads the list. Asked for when the picker is about to show rather
    /// than kept live: headphones come and go, and nobody looks at the list
    /// in between.
    func refreshOutputs() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        let found = ids.compactMap { id -> Output? in
            guard Self.hasOutputStreams(id), !Self.isPrivate(id), let name = Self.name(of: id) else { return nil }
            // A monitor announces an audio output over its cable whether or
            // not it has anything to play it on, and most have nothing. Left
            // out unless it is where the sound already goes.
            if Self.isDisplayAudio(id), id != currentOutput { return nil }
            return Output(id: id, name: name)
        }
        if found != outputs { outputs = found }
    }

    /// Sends the Mac's sound to this device, as choosing it in Control Centre
    /// does. The volume follows on its own: the default-device listener
    /// rebinds to it.
    func selectOutput(_ id: AudioObjectID) {
        var target = id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &target
        )
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    /// A private aggregate is visible only to the process that made it —
    /// Cyclop's own, through which the equalizer bars hear the music. It is
    /// plumbing, not somewhere to send sound, and nobody else lists it.
    private static func isPrivate(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return false }
        var composition: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition) == noErr,
              let dictionary = composition?.takeRetainedValue() as? [String: Any] else { return false }
        return (dictionary[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    private static func isDisplayAudio(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() as String?, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Device

    private func bindDefaultDevice() {
        // A device change queued just before `stop()` still arrives after it,
        // and must not put listeners back that nothing will ever remove.
        guard listening else { return }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, 0, nil, &size, &id
        )
        guard status == noErr, id != device else {
            if status != noErr { unbindDevice() }
            return
        }
        unbindDevice()
        device = id
        currentOutput = id

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.read() }
        }
        volumeListener = listener
        AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, .main, listener)
        if AudioObjectHasProperty(device, &Self.muteAddress) {
            AudioObjectAddPropertyListenerBlock(device, &Self.muteAddress, .main, listener)
        }
        read()
    }

    private func unbindDevice() {
        if device != kAudioObjectUnknown, let volumeListener {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, .main, volumeListener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, .main, volumeListener)
        }
        volumeListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
        isAvailable = false
    }

    private func read() {
        guard device != kAudioObjectUnknown, AudioObjectHasProperty(device, &Self.volumeAddress) else {
            isAvailable = false
            return
        }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(device, &Self.volumeAddress, &settable)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &value)
        isAvailable = status == noErr && settable.boolValue
        level = value

        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &Self.muteAddress),
           AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &muteSize, &muted) == noErr {
            isMuted = muted != 0
        } else {
            isMuted = false
        }
    }
}
