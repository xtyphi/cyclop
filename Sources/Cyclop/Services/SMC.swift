import Foundation
import IOKit

/// The Mac's own sensor controller, read for one thing: how hot the processor
/// is running.
///
/// `AppleSMC` is an ordinary IOKit service — the connection opens without
/// privileges and without a prompt, which is how every temperature readout on
/// macOS works. The layout below is the one the controller has answered to for
/// years; it is undocumented, so every call is checked and a refusal shows up
/// as no reading rather than as a wrong one.
final class SMC {
    private var connection: io_connect_t = 0
    /// Resolved once: which sensors this particular chip publishes. The names
    /// differ between Macs, so they are discovered rather than assumed.
    private var cpuKeys: [UInt32]?

    /// Ceiling on how many sensors are read each time. Modern chips publish
    /// dozens; this is enough to cover every core on a laptop and keeps the
    /// per-second cost in single-digit milliseconds.
    private static let maxSensors = 64

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Reading

    /// Temperature of the hottest processor core, in degrees Celsius.
    ///
    /// The hottest rather than the average of all of them: that is what the
    /// figure is for. A chip with four cores working and six idle is warm,
    /// and averaging the idle ones in describes a Mac that is not there —
    /// the same reason nobody averages a fever with room temperature.
    func cpuTemperature() -> Double? {
        guard open() else { return nil }
        let keys = cpuKeys ?? discoverCPUKeys()
        cpuKeys = keys
        guard !keys.isEmpty else { return nil }

        var hottest: Double?
        for key in keys {
            guard let value = read(key), value > 5, value < 130 else { continue }
            hottest = max(hottest ?? value, value)
        }
        return hottest
    }

    private func open() -> Bool {
        guard connection == 0 else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var port: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &port) == kIOReturnSuccess else { return false }
        connection = port
        return true
    }

    /// Every key whose name starts with a prefix the chip uses for core
    /// temperatures: `Tp` and `Te` on Apple silicon — performance cores and
    /// efficiency cores, and a chip can be busy on either — or `TC` on the
    /// Intel Macs before it. The whole key list is walked once, which costs
    /// 2 ms, against a wrong guess at a name that would leave the card blank
    /// on somebody else's Mac.
    private func discoverCPUKeys() -> [UInt32] {
        guard let total = read(Self.fourCC("#KEY")).map({ Int($0) }), total > 0, total < 10_000 else {
            return []
        }
        var apple: [UInt32] = []
        var intel: [UInt32] = []
        for index in 0..<total {
            var query = SMCParam()
            query.data8 = Self.selectorKeyFromIndex
            query.data32 = UInt32(index)
            guard let out = call(query) else { continue }
            let name = Self.name(of: out.key)
            if name.hasPrefix("Tp") || name.hasPrefix("Te"), apple.count < Self.maxSensors {
                apple.append(out.key)
            } else if name.hasPrefix("TC"), intel.count < Self.maxSensors {
                intel.append(out.key)
            }
        }
        return apple.isEmpty ? intel : apple
    }

    /// One sensor. The controller states the type of every key, so the bytes
    /// are decoded by what it says they are rather than by what a key of that
    /// name held on some other Mac.
    private func read(_ key: UInt32) -> Double? {
        var info = SMCParam()
        info.key = key
        info.data8 = Self.selectorKeyInfo
        guard let meta = call(info) else { return nil }

        var request = SMCParam()
        request.key = key
        request.keyInfo = meta.keyInfo
        request.data8 = Self.selectorReadKey
        guard let out = call(request) else { return nil }

        let bytes = withUnsafeBytes(of: out.bytes) { Array($0) }
        let size = Int(meta.keyInfo.dataSize)
        switch Self.name(of: meta.keyInfo.dataType) {
        case "flt " where size >= 4:
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "sp78" where size >= 2:
            return Double(Int16(bytes[0]) << 8 | Int16(bytes[1])) / 256
        case "ui32" where size >= 4:
            let raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            return Double(raw)
        case "ui8 " where size >= 1:
            return Double(bytes[0])
        default:
            return nil
        }
    }

    private func call(_ input: SMCParam) -> SMCParam? {
        guard connection != 0 else { return nil }
        var request = input
        var response = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let status = IOConnectCallStructMethod(
            connection, Self.eventSelector,
            &request, MemoryLayout<SMCParam>.stride,
            &response, &size
        )
        guard status == kIOReturnSuccess, response.result == 0 else { return nil }
        return response
    }

    // MARK: - Wire format

    private static let eventSelector: UInt32 = 2
    private static let selectorReadKey: UInt8 = 5
    private static let selectorKeyFromIndex: UInt8 = 8
    private static let selectorKeyInfo: UInt8 = 9

    private static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func name(of value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParam {
    var key: UInt32 = 0
    var version = SMCVersion()
    var limits = SMCLimitData()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}
