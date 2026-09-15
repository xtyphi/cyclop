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
