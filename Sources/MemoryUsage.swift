import AppKit
import Darwin

/// The memory the machine is really using.
///
/// There are two ways to answer the question, and they give very different
/// numbers:
///
/// * The virtual-memory statistics count every page that is not free. That
///   includes the *inactive* pages — the file cache. The system keeps those
///   around so it does not have to read the files again, and it can take
///   them back at any moment. The system's own Activity Monitor counts them
///   separately as「已缓存」— about 36 GB on a machine like this one.
/// * The processes' resident sizes count the memory the applications
///   actually hold. This is what the system reports as「应用程序内存」, and
///   what it reports as「已使用内存」.
///
/// The second one is used here, so the number agrees with the system's own
/// Activity Monitor.
enum MemoryUsage {

    /// The memory in use, and the total physical memory.
    ///
    /// - Returns: the used and the total memory, in bytes.
    static func usedAndTotal() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        let used = residentBytesOfAllProcesses()
        return (min(used, total), total)
    }

    /// The sum of the resident size of every running process.
    ///
    /// This is the「应用程序内存」the system's Activity Monitor reports.
    ///
    /// Walking every process takes well under a millisecond, so it is cheap
    /// enough to do for the status bar.
    static func residentBytesOfAllProcesses() -> UInt64 {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return 0 }

        let capacity = Int(bytesNeeded) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let filled = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        let count = max(0, Int(filled) / MemoryLayout<pid_t>.size)

        var total: UInt64 = 0
        for pid in pids[0..<count] {
            guard pid > 0 else { continue }
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }
            total &+= UInt64(task.pti_resident_size)
        }
        return total
    }
}
