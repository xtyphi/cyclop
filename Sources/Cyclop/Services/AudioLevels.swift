import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// How loud six bands of whatever the Mac is playing are right now, from
/// the bass up — what makes the equalizer bars move with the music instead
/// of breathing on a loop.
///
/// Heard through a Core Audio process tap: a copy of everything the Mac
/// sends to its speakers, minus Cyclop itself, mixed down to one channel.
/// The whole mix rather than the player's own process, because the sound of
/// a browser tab or a Telegram voice message comes out of a helper process,
/// not out of the app whose name is on the panel.
///
/// The tap asks for the "system audio recording" permission the first time
/// it runs. Refused, it still runs and hears only silence; the bars then fall
/// back to their old loop on their own (`hasSignal`), so a refusal costs
/// nothing but the feature.
///
/// It runs only while some equalizer is on screen and playing: views take a
/// hold with `acquire()` and give it back with `release()`.
final class AudioLevels: @unchecked Sendable {
    static let shared = AudioLevels()

    /// How many bands the sound is split into.
    static let bandCount = 6

    /// Band levels, bass first, each 0…1; lanes past `bandCount` stay 0. A
    /// vector rather than an array: it is written on the audio thread, and
    /// an array there could allocate.
    typealias Bands = SIMD8<Float>

    private struct Shared {
        var bands = Bands(repeating: 0)
        var lastSound = Date.distantPast
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let queue = DispatchQueue(label: "cyclop.audio-levels", qos: .userInteractive)

    // Touched on `queue` only.
    private var holds = 0
    private var tap: Tap?
    private var pendingStop: DispatchWorkItem?

    /// The latest levels.
    var bands: Bands { shared.withLock { $0.bands } }

    /// True while there has been sound in the last second and a half. False
    /// with the permission refused, with nothing playing, or before the tap
    /// has started — every case in which the bars should not pretend.
    var hasSignal: Bool {
        shared.withLock { Date().timeIntervalSince($0.lastSound) < 1.5 }
    }

    func acquire() {
        queue.async { [self] in
            holds += 1
            pendingStop?.cancel()
            pendingStop = nil
            if tap == nil { tap = Tap(levels: self) }
        }
    }

    func release() {
        queue.async { [self] in
            holds = max(holds - 1, 0)
            guard holds == 0 else { return }
            // A grace period: opening the panel swaps the bars on the notch's
            // side for the ones in its header, one going as the other comes,
            // and tearing the tap down between them would be a restart.
            let stop = DispatchWorkItem { [self] in
                guard holds == 0 else { return }
                tap = nil
                shared.withLock { $0 = Shared() }
            }
            pendingStop = stop
            queue.asyncAfter(deadline: .now() + 2, execute: stop)
        }
    }

    /// The default output changed — headphones in, AirPods connected. The
    /// tap's clock was the old device, so it is rebuilt on the new one.
    fileprivate func restart() {
        queue.async { [self] in
            guard tap != nil else { return }
            tap = nil
            tap = Tap(levels: self)
        }
    }

    fileprivate func publish(_ bands: Bands, loud: Bool) {
        shared.withLock {
            $0.bands = bands
            if loud { $0.lastSound = Date() }
        }
    }
}

// MARK: - Tap

/// One running tap: the tap itself, the private aggregate device it is read
/// through, and the callback reading it. Torn down in reverse by `deinit`.
private final class Tap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let analyzer: Analyzer

    init?(levels: AudioLevels) {
        // Everything but Cyclop, mono: the bars need loudness per band, not
        // stereo, and half the samples is half the work.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Tap.ownProcess().map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return nil }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        analyzer = Analyzer(levels: levels, sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000,
                            channels: Int(max(format.mChannelsPerFrame, 1)))

        guard let outputUID = Tap.defaultOutputUID() else { destroy(); return nil }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Cyclop Equalizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else {
            destroy()
            return nil
        }

        let analyzer = analyzer
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, _, _ in
            analyzer.consume(input)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else {
            destroy()
            return nil
        }

        var outputAddress = Tap.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak levels] _, _ in levels?.restart() }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, nil, listener)
    }

    deinit { destroy() }

    private func destroy() {
        if let outputListener {
            var address = Tap.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, outputListener)
            self.outputListener = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
            procID = nil
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Cyclop's own audio object, so the chime at the end of a sprint does
    /// not make the bars jump.
    private static func ownProcess() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

// MARK: - Analysis

/// Turns the tap's samples into three band levels. Runs on Core Audio's
/// real-time thread: no allocation and no locks there beyond the one
/// unfair lock `publish` takes for a few words.
private final class Analyzer: @unchecked Sendable {
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    private static let hop = 1 << 9

    private weak var levels: AudioLevels?
    private let channels: Int
    private let setup: FFTSetup
    private let window: [Float]
    /// Bin range of each band, spaced evenly in pitch from 50 Hz to 12 kHz:
    /// an octave-like split, which is how the ear hears the difference
    /// between a kick and a hi-hat, rather than evenly in hertz, which would
    /// give five bands of treble and one of everything else.
    private let ranges: [Range<Int>]

    private var buffer: [Float]
    private var filled = 0
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    /// Loudest each band has been lately: the bars are scaled against the
    /// song, so a quiet track moves them as much as a loud one.
    private var peaks = AudioLevels.Bands(repeating: 1e-6)
    private var shown = AudioLevels.Bands(repeating: 0)

    init(levels: AudioLevels, sampleRate: Double, channels: Int) {
        self.levels = levels
        self.channels = channels
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        buffer = [Float](repeating: 0, count: Self.size)
        windowed = buffer
        real = [Float](repeating: 0, count: Self.size / 2)
        imaginary = real
        magnitudes = real
        let binWidth = sampleRate / Double(Self.size)
        func bin(_ hertz: Double) -> Int { min(max(Int(hertz / binWidth), 1), Self.size / 2) }
        let edges = (0...AudioLevels.bandCount).map { 50 * pow(12_000.0 / 50, Double($0) / Double(AudioLevels.bandCount)) }
        ranges = (0..<AudioLevels.bandCount).map { bin(edges[$0])..<max(bin(edges[$0 + 1]), bin(edges[$0]) + 1) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // The tap's stream comes after the output device's own inputs in the
        // aggregate. A plain speaker has none, but an audio interface does,
        // and its first buffer is the microphone — so the last one is read.
        guard let first = list.last, let data = first.mData else { return }
        let stride = max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * stride)
        let samples = data.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            buffer[filled] = samples[frame * stride]
            filled += 1
            if filled == Self.size {
                analyze()
                // Half-overlapping windows: a reading every 512 samples, about
                // 94 a second, so the bars have a fresh value every frame.
                buffer.withUnsafeMutableBufferPointer {
                    $0.baseAddress!.update(from: $0.baseAddress! + Self.hop, count: Self.size - Self.hop)
                }
                filled = Self.size - Self.hop
            }
        }
    }

    private func analyze() {
        vDSP.multiply(buffer, window, result: &windowed)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.size / 2))
            }
        }

        var loud = false
        for (index, range) in ranges.enumerated() where !range.isEmpty {
            var energy: Float = 0
            magnitudes.withUnsafeBufferPointer {
                vDSP_meanv($0.baseAddress! + range.lowerBound, 1, &energy, vDSP_Length(range.count))
            }
            if energy > 1e-3 { loud = true }
            // The peak falls slowly, so a chorus after a quiet verse does not
            // pin every bar to the top for the rest of the song.
            peaks[index] = max(peaks[index] * 0.9985, energy, 1e-6)
            let level = min(sqrtf(energy / peaks[index]), 1)
            // Up at once, down gently: a beat lands on the frame it happens,
            // and the fall is what the eye follows.
            // Quick up, slow down, both eased: a beat still lands within a
            // couple of frames, and nothing snaps — the bars glide.
            let ease: Float = level > shown[index] ? 0.55 : 0.12
            shown[index] += (level - shown[index]) * ease
        }
        levels?.publish(shown, loud: loud)
    }
}
