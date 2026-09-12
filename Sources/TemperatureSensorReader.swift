import AppKit
import Darwin
import IOKit

/// Reads temperature sensors via private IOHID symbols (works on Apple Silicon; may be empty on some Intel Macs).
enum TemperatureSensorReader {
    struct Reading: Hashable {
        let name: String
        let celsius: Double
        let category: Category
    }

    enum Category: String, CaseIterable {
        case cpu = "CPU"
        case gpu = "GPU"
        case ssd = "存储"
        case battery = "电池"
        case ane = "神经引擎"
        case soc = "SoC"
        case other = "其他"

        var sortOrder: Int {
            switch self {
            case .cpu: return 0
            case .gpu: return 1
            case .ssd: return 2
            case .battery: return 3
            case .ane: return 4
            case .soc: return 5
            case .other: return 6
            }
        }
    }

    static func sample() -> [Reading] {
        guard let client = createClient() else { return [] }
        setMatching(client, [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ] as CFDictionary)

        guard let services = copyServices(client) else { return [] }
        let count = CFArrayGetCount(services)
        var readings: [Reading] = []
        readings.reserveCapacity(count)

        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let nameObj = copyProperty(service, "Product" as CFString),
                  let name = nameObj as? String,
                  !name.isEmpty else { continue }
            guard let event = copyEvent(service, 15, 0, 0) else { continue }
            let value = eventFloatValue(event, 983_040)
            // Discard impossible / unavailable readings.
            guard value.isFinite, value > -20, value < 150 else { continue }
            readings.append(Reading(name: name, celsius: value, category: categorize(name)))
        }

        // Deduplicate identical name+temp noise by keeping first of each name.
        var seenNames = Set<String>()
        readings = readings.filter { seenNames.insert($0.name).inserted }

        return readings.sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func categorize(_ name: String) -> Category {
        let n = name.lowercased()
        if n.contains("nand") || n.contains("ssd") || n.contains("flash") {
            return .ssd
        }
        if n.contains("batt") || n.contains("battery") {
            return .battery
        }
        if n.contains("ane") || n.contains("neural") {
            return .ane
        }
        if n.contains("gpu") || n.contains("pmu2") {
            return .gpu
        }
        if n.contains("pacc") || n.contains("eacc") || n.contains("cpu")
            || n.contains("tdie") || n.hasPrefix("tp") && n.contains("s") {
            return .cpu
        }
        if n.contains("soc") || n.contains("pmgr") || n.contains("isp") {
            return .soc
        }
        return .other
    }

    static func average(of readings: [Reading], category: Category) -> Double? {
        let values = readings.filter { $0.category == category }.map(\.celsius)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Value for summary cards. On Apple Silicon without a dedicated GPU sensor,
    /// fall back to package-die (CPU/tdie) average — GPU shares the same SoC.
    static func summaryAverage(of readings: [Reading], category: Category) -> (value: Double, estimated: Bool)? {
        if let value = average(of: readings, category: category) {
            return (value, false)
        }
        if category == .gpu, let die = average(of: readings, category: .cpu) {
            return (die, true)
        }
        return nil
    }

    static func maximum(of readings: [Reading]) -> Reading? {
        readings.max(by: { $0.celsius < $1.celsius })
    }

    static func thermalStateText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "较高"
        case .critical: return "过热"
        @unknown default: return "未知"
        }
    }
}

// MARK: - IOHID dynamic symbols

private typealias NFHIDClient = UnsafeMutableRawPointer
private typealias NFHIDService = UnsafeMutableRawPointer
private typealias NFHIDEvent = UnsafeMutableRawPointer

private typealias CreateFn = @convention(c) (CFAllocator?) -> NFHIDClient?
private typealias SetMatchingFn = @convention(c) (NFHIDClient?, CFDictionary?) -> Void
private typealias CopyServicesFn = @convention(c) (NFHIDClient?) -> CFArray?
private typealias CopyEventFn = @convention(c) (NFHIDService?, Int64, Int32, Int64) -> NFHIDEvent?
private typealias EventFloatFn = @convention(c) (NFHIDEvent?, UInt32) -> Double
private typealias CopyPropertyFn = @convention(c) (NFHIDService?, CFString?) -> AnyObject?

private struct IOHIDSymbols {
    let create: CreateFn
    let setMatching: SetMatchingFn
    let copyServices: CopyServicesFn
    let copyEvent: CopyEventFn
    let eventFloat: EventFloatFn
    let copyProperty: CopyPropertyFn

    static let shared: IOHIDSymbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func load<T>(_ name: String) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        guard
            let create: CreateFn = load("IOHIDEventSystemClientCreate"),
            let setMatching: SetMatchingFn = load("IOHIDEventSystemClientSetMatching"),
            let copyServices: CopyServicesFn = load("IOHIDEventSystemClientCopyServices"),
            let copyEvent: CopyEventFn = load("IOHIDServiceClientCopyEvent"),
            let eventFloat: EventFloatFn = load("IOHIDEventGetFloatValue"),
            let copyProperty: CopyPropertyFn = load("IOHIDServiceClientCopyProperty")
        else {
            return nil
        }
        return IOHIDSymbols(
            create: create,
            setMatching: setMatching,
            copyServices: copyServices,
            copyEvent: copyEvent,
            eventFloat: eventFloat,
            copyProperty: copyProperty
        )
    }()
}

private func createClient() -> NFHIDClient? {
    IOHIDSymbols.shared?.create(kCFAllocatorDefault)
}

private func setMatching(_ client: NFHIDClient, _ matching: CFDictionary) {
    IOHIDSymbols.shared?.setMatching(client, matching)
}

private func copyServices(_ client: NFHIDClient) -> CFArray? {
    IOHIDSymbols.shared?.copyServices(client)
}

private func copyEvent(_ service: NFHIDService, _ type: Int64, _ options: Int32, _ depth: Int64) -> NFHIDEvent? {
    IOHIDSymbols.shared?.copyEvent(service, type, options, depth)
}

private func eventFloatValue(_ event: NFHIDEvent, _ field: UInt32) -> Double {
    IOHIDSymbols.shared?.eventFloat(event, field) ?? .nan
}

private func copyProperty(_ service: NFHIDService, _ key: CFString) -> AnyObject? {
    IOHIDSymbols.shared?.copyProperty(service, key)
}
