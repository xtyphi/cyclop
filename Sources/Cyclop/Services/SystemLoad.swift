import Darwin
import Foundation
import IOKit

/// Processor, memory and graphics load, sampled once a second while the tab is
/// on screen.
///
/// Public interfaces only, and nothing that asks permission: `host_processor_info`
/// for the per-core tick counters, `host_statistics64` for the memory page
/// counts, and the IORegistry's own `PerformanceStatistics` for the GPU — the
/// same numbers `ioreg` prints for anyone who asks.
@MainActor
final class SystemLoad: ObservableObject {
    /// One reading of everything, kept together so the three cards always
    /// describe the same moment.
    struct Sample {
        var cpu: Double = 0
        var memory: Double = 0
        var gpu: Double?
        /// Processor temperature in degrees Celsius, where the Mac publishes
        /// one at all.
        var temperature: Double?
    }

    @Published private(set) var current = Sample()
    /// Oldest first. Long enough to show the last minute at a glance, short
    /// enough that a spike is still a spike rather than a hairline.
    @Published private(set) var history: [Sample] = []

    static let historyLength = 60

    private var timer: Timer?
    private var previousTicks: [UInt32]?
    /// Taken once and kept. `mach_host_self` hands out a send right on every
    /// call, and a right nobody gives back is a right the process keeps: at
    /// three calls a second an open tab would collect thousands of them.
    private let host = mach_host_self()
    private let smc = SMC()

    // MARK: - Lifecycle

    /// Sampling exists for a pane nobody is looking at otherwise: a second
    /// timer running behind a closed panel would read counters for nothing.
    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        // The first CPU reading needs a previous one to compare against, so
        // the counters are taken now and the first shown figure is the gap
        // between this moment and the next tick.
        previousTicks = nil
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        setActive(false)
        history.removeAll()
        current = Sample()
    }

    private func sample() {
        var next = Sample()
        next.cpu = readCPU() ?? current.cpu
        next.memory = readMemory() ?? current.memory
        // No carrying the last reading forward: a driver that stops
        // publishing would leave the card frozen on a number that stopped
        // being true, which is worse than no card.
        next.gpu = readGPU()
        next.temperature = smc.cpuTemperature()
        current = next
        history.append(next)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    // MARK: - Processor

    /// Busy share across all cores, from the difference between two readings
    /// of the same tick counters — the counters themselves only ever climb,
    /// so a single reading says how busy the Mac has been since it booted,
    /// which is not what anybody means by "CPU right now".
    private func readCPU() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(
            host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount
        )
        guard status == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previousTicks = ticks }
        guard let previous = previousTicks, previous.count == ticks.count else { return nil }

        var busy = 0.0
        var total = 0.0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            guard base + Int(CPU_STATE_MAX) <= ticks.count else { break }
            var coreTotal = 0.0
            var coreIdle = 0.0
            for state in 0..<Int(CPU_STATE_MAX) {
                // Unsigned subtraction, so a counter that wrapped past its
                // 32 bits gives the real gap rather than a number near four
                // billion — one wrapped core would otherwise pin the whole
                // graph at zero for a second.
                let delta = Double(ticks[base + state] &- previous[base + state])
                coreTotal += delta
                if state == Int(CPU_STATE_IDLE) { coreIdle = delta }
            }
            busy += coreTotal - coreIdle
            total += coreTotal
        }
        guard total > 0 else { return nil }
        return min(max(busy / total * 100, 0), 100)
    }

    // MARK: - Memory

    /// What Activity Monitor calls memory used: app memory, wired, and what
    /// the compressor holds. Free and cached pages are left out — a Mac that
    /// has filled its spare memory with disk cache is not a Mac under
    /// pressure, and counting that as used would read as 90 % forever.
    private func readMemory() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        var rawPageSize: vm_size_t = 0
        guard host_page_size(host, &rawPageSize) == KERN_SUCCESS else { return nil }
        let pageSize = Double(rawPageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
        return min(max(used / total * 100, 0), 100)
    }

    // MARK: - Graphics

    /// The GPU driver publishes its own utilisation in the IORegistry. Macs
    /// without such an entry — or a driver that stops publishing it — get no
    /// card at all rather than a card reading zero.
    private func readGPU() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            guard let value = raw["Device Utilization %"] as? NSNumber else { continue }
            // Several accelerators can answer at once on a Mac with more than
            // one GPU; the busiest is the one the number is about.
            best = max(best ?? 0, min(max(value.doubleValue, 0), 100))
        }
        return best
    }
}
