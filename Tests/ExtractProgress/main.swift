import AppKit
import Foundation

// A small harness that checks that the extraction reports progress as it
// goes, and that the files really come out.

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("NF-extract-test-\(UUID().uuidString)")
try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

// A source folder with a few files.
let source = tmp.appendingPathComponent("src")
try? fm.createDirectory(at: source, withIntermediateDirectories: true)
for index in 0..<4 {
    let data = Data(repeating: UInt8(index), count: 40 * 1024 * 1024)
    try? data.write(to: source.appendingPathComponent("file\(index).bin"))
}
try? "hello".write(to: source.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

// A zip of it, made with the same tool the app uses.
let archive = tmp.appendingPathComponent("test.zip")
let zipTask = Process()
zipTask.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zipTask.arguments = ["-r", "-q", archive.path, "src"]
zipTask.currentDirectoryURL = tmp
try? zipTask.run()
zipTask.waitUntilExit()
print("压缩包: \(archive.path)")

// The size of what is inside it.
let total = await ArchiveEngine.totalSize(ofArchiveContents: archive)
print("压缩包内总大小: \(total) 字节")

// The extraction, with the progress watched.
let destination = tmp.appendingPathComponent("out")
try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

let progressLock = NSLock()
var progressEvents: [(Double, UInt64, UInt64)] = []
var fileEvents: [(String, UInt64, UInt64, UInt64)] = []

let start = Date()
do {
    try await ArchiveEngine.extract(
        archive: archive,
        to: destination,
        password: nil,
        progressDetail: { progress in
            progressLock.lock()
            progressEvents.append((progress.fraction, progress.completedBytes, progress.totalBytes))
            progressLock.unlock()
        },
        fileProgress: { file in
            progressLock.lock()
            fileEvents.append((file.name, file.originalBytes, file.completedBytes, file.compressedBytes))
            progressLock.unlock()
        },
        progress: { _ in }
    )
} catch {
    print("解压失败: \(error)")
    exit(1)
}
let elapsed = Date().timeIntervalSince(start)

progressLock.lock()
let events = progressEvents
let files = fileEvents
progressLock.unlock()

print("")
print("=== 总体进度事件 (\(events.count) 个) ===")
for event in events.prefix(8) {
    print(String(format: "  %.1f%%  %d / %d", event.0 * 100, event.1, event.2))
}
if events.count > 8 { print("  … 还有 \(events.count - 8) 个") }

print("")
print("=== 文件进度事件 (\(files.count) 个) ===")
var seen: [String: (UInt64, UInt64)] = [:]
for event in files { seen[event.0] = (event.1, event.2) }
for (name, state) in seen.sorted(by: { $0.key < $1.key }) {
    print("  \(name): \(state.0) -> \(state.1)")
}

// The checks.
var failures: [String] = []

if events.count < 2 {
    failures.append("进度事件太少: \(events.count)")
}
if let last = events.last {
    if last.2 != total {
        failures.append("总大小不对: 窗口 \(last.2) vs 预期 \(total)")
    }
    if abs(last.0 - 1.0) > 0.001 {
        failures.append("最后进度不是 100%: \(last.0)")
    }
} else {
    failures.append("没有进度事件")
}
// The progress has to grow, not jump straight to the end.
let fractions = events.map(\.0)
if total > 0 && !fractions.contains(where: { $0 > 0.01 && $0 < 0.99 }) {
    failures.append("进度没有中间值: \(fractions.prefix(10))")
}
if seen.count < 5 {
    failures.append("文件数不对: \(seen.count)")
}
// Every file has to be fully written at the end.
for (name, state) in seen {
    if state.1 != state.0 {
        failures.append("文件没有写完: \(name) \(state.1)/\(state.0)")
    }
}

// Every file has to have been seen going up, not only at the end. A file
// that is smaller than one chunk is written in one go, so it has no
// middle step.
for (name, state) in seen {
    let path = files.filter { $0.0 == name }.map(\.2)
    let middle = path.contains { $0 > 0 && $0 < state.0 }
    if state.0 > 1024 * 1024 && !middle {
        failures.append("文件进度没有中间值: \(name) \(path.prefix(5))")
    }
}

// The files really are on disk and have the right size.
for index in 0..<4 {
    let url = destination.appendingPathComponent("src/file\(index).bin")
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    if values?.fileSize != 40 * 1024 * 1024 {
        failures.append("文件大小不对: \(url.lastPathComponent) \(values?.fileSize ?? -1)")
    }
}
if !fm.fileExists(atPath: destination.appendingPathComponent("src/note.txt").path) {
    failures.append("note.txt 不存在")
}

print("")
print("耗时: \(String(format: "%.2f", elapsed)) 秒")
try? fm.removeItem(at: tmp)
if failures.isEmpty {
    print("✅ 全部通过")
    exit(0)
} else {
    for failure in failures { print("❌ \(failure)") }
    exit(1)
}
