import AppKit
import Darwin

/// Bottom status-bar widget showing whole-machine disk / memory / CPU usage.
/// Displayed as "used(total)" for disk and memory, plus a CPU percentage.
final class SystemUsageMonitor: NSObject {
    static let shared = SystemUsageMonitor()

    struct Snapshot {
        var diskUsed: UInt64 = 0
        var diskTotal: UInt64 = 0
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = 0
        var cpuPercent: Double = 0
    }

    private var timer: Timer?
    private var previousCPU: (user: UInt32, system: UInt32, idle: UInt32)?
    private var snapshot = Snapshot()
    private var listeners: [(Snapshot) -> Void] = []

    private override init() {
        super.init()
        refresh()
        previousCPU = readCPUTicks()
    }

    // MARK: - Lifecycle

    func start(interval: TimeInterval = 3.0) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Registers a callback that receives a fresh snapshot on every refresh.
    func addListener(_ listener: @escaping (Snapshot) -> Void) {
        listeners.append(listener)
        listener(snapshot)
    }

    // MARK: - Sampling

    private func refresh() {
        let disk = readDiskUsage()
        let memory = readMemoryUsage()
        let cpu = readCPUUsage()

        snapshot.diskUsed = disk.used
        snapshot.diskTotal = disk.total
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.cpuPercent = cpu

        for listener in listeners {
            listener(snapshot)
        }
    }

    private func readDiskUsage() -> (used: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        guard let values else { return (0, 0) }

        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let available: UInt64
        if let important = values.volumeAvailableCapacityForImportantUsage {
            available = UInt64(max(0, important))
        } else if let plain = values.volumeAvailableCapacity {
            available = UInt64(max(0, plain))
        } else {
            available = 0
        }
        guard total > 0 else { return (0, 0) }
        let used = total > available ? total - available : 0
        return (used, total)
    }

    private func readMemoryUsage() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }

        let pageSize = UInt64(vm_kernel_page_size)
        // Wired + active + inactive + compressed approximates the in-use footprint;
        // file-backed pages are reclaimable, so they are excluded.
        let usedPages = UInt64(vmStat.wire_count)
            &+ UInt64(vmStat.active_count)
            &+ UInt64(vmStat.inactive_count)
            &+ UInt64(vmStat.compressor_page_count)
        let used = min(usedPages * pageSize, total)
        return (used, total)
    }

    private func readCPUTicks() -> (user: UInt32, system: UInt32, idle: UInt32)? {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = loadInfo.cpu_ticks
        return (ticks.0, ticks.1, ticks.2)
    }

    private func readCPUUsage() -> Double {
        guard let current = readCPUTicks() else { return 0 }
        guard let previous = previousCPU else {
            previousCPU = current
            return 0
        }
        previousCPU = current

        let userDelta = current.user &- previous.user
        let systemDelta = current.system &- previous.system
        let idleDelta = current.idle &- previous.idle
        let totalDelta = userDelta &+ systemDelta &+ idleDelta
        guard totalDelta > 0 else { return 0 }
        let busy = Double(userDelta &+ systemDelta) / Double(totalDelta) * 100.0
        return min(100, max(0, busy))
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func formatText(_ snapshot: Snapshot) -> String {
        let disk = "\(formatBytes(snapshot.diskUsed))(\(formatBytes(snapshot.diskTotal)))"
        // Memory usage as a percentage with two decimals, e.g. 54.10%.
        let memoryPercent = snapshot.memoryTotal > 0
            ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) * 100.0
            : 0
        let memory = String(format: "%.2f%%", memoryPercent)
        // CPU always shows two digits, e.g. 05%.
        let cpu = String(format: "%02d%%", Int(snapshot.cpuPercent.rounded()))
        return "硬盘 \(disk) · 内存 \(memory) · CPU \(cpu)"
    }
}
