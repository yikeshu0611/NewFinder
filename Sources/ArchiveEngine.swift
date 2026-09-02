import Foundation

enum CompressFormat: String, CaseIterable {
    case zip
    case tarGz

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        }
    }
}

enum SplitVolumeSize: String, CaseIterable {
    case none
    case mb1
    case mb10
    case mb100
    case mb650
    case mb700
    case mb4092

    /// Argument for `zip -s`, nil means no split.
    var zipSplitArgument: String? {
        switch self {
        case .none: return nil
        case .mb1: return "1m"
        case .mb10: return "10m"
        case .mb100: return "100m"
        case .mb650: return "650m"
        case .mb700: return "700m"
        case .mb4092: return "4092m"
        }
    }

    static func fromDialogValue(_ value: String) -> SplitVolumeSize {
        switch value {
        case "1m": return .mb1
        case "10m": return .mb10
        case "100m": return .mb100
        case "650m": return .mb650
        case "700m": return .mb700
        case "4092m": return .mb4092
        default: return .none
        }
    }
}

struct ArchiveListEntry: Codable, Equatable {
    var path: String
    var isDirectory: Bool
    var size: Int64?
}

enum ArchiveError: LocalizedError {
    case emptySelection
    case unsupportedArchive(String)
    case toolFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "请先添加要处理的文件或文件夹。"
        case .unsupportedArchive(let name):
            return "暂不支持解压：\(name)"
        case .toolFailed(let detail):
            return detail
        case .cancelled:
            return "操作已取消。"
        }
    }
}

/// Compression / extraction using macOS built-in tools (ditto, tar, unzip).
enum ArchiveEngine {
    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "cab", "iso"
    ]

    static func looksLikeArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz")
            || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz")
    }

    static func defaultArchiveName(for items: [URL], format: CompressFormat) -> String {
        if items.count == 1 {
            let base = items[0].deletingPathExtension().lastPathComponent
            return "\(base).\(format.fileExtension)"
        }
        return "Archive.\(format.fileExtension)"
    }

    static func compress(
        items: [URL],
        to destination: URL,
        format: CompressFormat,
        password: String? = nil,
        split: SplitVolumeSize = .none,
        progress: @escaping (String) -> Void
    ) async throws {
        guard !items.isEmpty else { throw ArchiveError.emptySelection }

        try Task.checkCancellation()
        progress("正在压缩…")

        let wantsZipFeatures = (password?.isEmpty == false) || split != .none
        let effectiveFormat: CompressFormat = wantsZipFeatures ? .zip : format

        switch effectiveFormat {
        case .zip:
            try await compressZip(
                items: items,
                to: destination,
                password: password,
                split: split
            )
        case .tarGz:
            try await compressTarGz(items: items, to: destination)
        }

        progress("压缩完成")
    }

    static func extract(
        archive: URL,
        to directory: URL,
        password: String? = nil,
        progress: @escaping (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        progress("正在解压…")

        let name = archive.lastPathComponent.lowercased()
        let ext = archive.pathExtension.lowercased()

        if ext == "zip" {
            if let password, !password.isEmpty {
                try await run("/usr/bin/unzip", [
                    "-P", password, "-o", archive.path, "-d", directory.path
                ])
            } else {
                try await run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            }
        } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") || ext == "gz" && name.contains(".tar.") {
            try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
        } else if name.hasSuffix(".tar.bz2") || ext == "bz2" && name.contains(".tar.") {
            try await run("/usr/bin/tar", ["-xjf", archive.path, "-C", directory.path])
        } else if name.hasSuffix(".tar.xz") || ext == "xz" && name.contains(".tar.") {
            try await run("/usr/bin/tar", ["-xJf", archive.path, "-C", directory.path])
        } else if ext == "tar" {
            try await run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
        } else if ext == "rar" || ext == "7z" {
            try await extractWithOptionalTools(archive: archive, to: directory, password: password)
        } else if ext == "gz" || ext == "bz2" || ext == "xz" {
            try await extractSingleCompressedFile(archive: archive, to: directory)
        } else {
            throw ArchiveError.unsupportedArchive(archive.lastPathComponent)
        }

        progress("解压完成")
    }

    /// Flat list of all entries inside an archive (files and inferred directories).
    static func listEntries(in archive: URL) async throws -> [ArchiveListEntry] {
        let name = archive.lastPathComponent.lowercased()
        let ext = archive.pathExtension.lowercased()

        let paths: [String]
        if ext == "zip" {
            // Apple zipinfo/unzip -Z mangle UTF-8 names into '?'. bsdtar preserves them.
            let out = try await run(
                "/usr/bin/bsdtar",
                ["-tf", archive.path],
                environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            )
            paths = out
                .split(whereSeparator: \.isNewline)
                .map { line -> String in
                    var s = String(line)
                    if s.hasPrefix("./") { s = String(s.dropFirst(2)) }
                    return s
                }
                .filter { !$0.isEmpty && $0 != "." }
        } else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            let out = try await run("/usr/bin/tar", ["-tzf", archive.path])
            paths = out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        } else if name.hasSuffix(".tar.bz2") {
            let out = try await run("/usr/bin/tar", ["-tjf", archive.path])
            paths = out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        } else if name.hasSuffix(".tar.xz") {
            let out = try await run("/usr/bin/tar", ["-tJf", archive.path])
            paths = out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        } else if ext == "tar" {
            let out = try await run("/usr/bin/tar", ["-tf", archive.path])
            paths = out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        } else if ext == "rar" || ext == "7z" {
            paths = try await listWithOptionalTools(archive: archive)
        } else {
            throw ArchiveError.unsupportedArchive(archive.lastPathComponent)
        }

        return normalizeListEntries(paths)
    }

    // MARK: - Private

    private static func normalizeListEntries(_ rawPaths: [String]) -> [ArchiveListEntry] {
        var directories = Set<String>()
        var files: [(String, Bool)] = []

        for raw in rawPaths {
            let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, !path.hasPrefix("__MACOSX") else { continue }
            let isDir = raw.hasSuffix("/")
            if isDir {
                directories.insert(path)
            } else {
                files.append((path, false))
                var parent = (path as NSString).deletingLastPathComponent
                while !parent.isEmpty, parent != "." {
                    directories.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }

        var result: [ArchiveListEntry] = directories.sorted().map {
            ArchiveListEntry(path: $0, isDirectory: true, size: nil)
        }
        result += files.map { ArchiveListEntry(path: $0.0, isDirectory: false, size: nil) }
        return result
    }

    private static func compressZip(
        items: [URL],
        to destination: URL,
        password: String?,
        split: SplitVolumeSize
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // Remove leftover split parts
        let base = destination.deletingPathExtension().path
        let parent = destination.deletingLastPathComponent()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: parent.path) {
            for name in files where name.hasPrefix((base as NSString).lastPathComponent + ".z") {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
            }
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for item in items {
            try FileManager.default.copyItem(
                at: item,
                to: staging.appendingPathComponent(item.lastPathComponent)
            )
        }

        var zipArgs = "/usr/bin/zip -r"
        if let password, !password.isEmpty {
            zipArgs += " -P \(shellEscape(password))"
        }
        if let splitArg = split.zipSplitArgument {
            zipArgs += " -s \(splitArg)"
        }
        zipArgs += " \(shellEscape(destination.path)) ."

        try await run(
            "/bin/bash",
            ["-c", "cd \(shellEscape(staging.path)) && \(zipArgs)"],
            environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        )
        // Info-ZIP on macOS stores UTF-8 bytes but often omits the UTF-8 flag,
        // so other tools (and zipinfo) show garbled names. Mark non-ASCII entries.
        try markZipFilenamesAsUTF8(at: destination)
    }

    /// Set general-purpose bit 11 (UTF-8) on local + central headers for non-ASCII names.
    private static func markZipFilenamesAsUTF8(at url: URL) throws {
        var data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        let utf8Flag: UInt16 = 0x800

        func patch(signature: [UInt8], flagOffset: Int) {
            var searchFrom = 0
            let sig = Data(signature)
            while searchFrom + 30 < data.count {
                guard let range = data.range(of: sig, in: searchFrom..<data.count) else { break }
                let header = range.lowerBound
                let nameLenOffset = header + (signature == [0x50, 0x4b, 0x03, 0x04] ? 26 : 28)
                let nameOffset = header + (signature == [0x50, 0x4b, 0x03, 0x04] ? 30 : 46)
                guard nameLenOffset + 2 <= data.count else { break }
                let nameLen = Int(data[nameLenOffset]) | (Int(data[nameLenOffset + 1]) << 8)
                guard nameOffset + nameLen <= data.count else {
                    searchFrom = header + 4
                    continue
                }
                let name = data[nameOffset..<(nameOffset + nameLen)]
                if name.contains(where: { $0 >= 0x80 }) {
                    let flagIndex = header + flagOffset
                    var flags = UInt16(data[flagIndex]) | (UInt16(data[flagIndex + 1]) << 8)
                    flags |= utf8Flag
                    data[flagIndex] = UInt8(flags & 0xff)
                    data[flagIndex + 1] = UInt8((flags >> 8) & 0xff)
                }
                searchFrom = header + 4
            }
        }

        // Local file header PK\x03\x04 — flags at +6
        patch(signature: [0x50, 0x4b, 0x03, 0x04], flagOffset: 6)
        // Central directory header PK\x01\x02 — flags at +8
        patch(signature: [0x50, 0x4b, 0x01, 0x02], flagOffset: 8)

        try data.write(to: url, options: .atomic)
    }

    private static func compressTarGz(items: [URL], to destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        var args = ["-czf", destination.path]
        // Use -C parent + basename so paths inside archive are short
        if items.count == 1 {
            let item = items[0]
            args += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent]
            try await run("/usr/bin/tar", args)
            return
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for item in items {
            try FileManager.default.copyItem(
                at: item,
                to: staging.appendingPathComponent(item.lastPathComponent)
            )
        }

        try await run("/usr/bin/tar", [
            "-czf", destination.path,
            "-C", staging.path,
            "."
        ])
    }

    private static func extractWithOptionalTools(
        archive: URL,
        to directory: URL,
        password: String? = nil
    ) async throws {
        var candidates: [(String, [String])] = []
        if let password, !password.isEmpty {
            candidates += [
                ("/opt/homebrew/bin/7z", ["x", "-y", "-p\(password)", "-o\(directory.path)", archive.path]),
                ("/usr/local/bin/7z", ["x", "-y", "-p\(password)", "-o\(directory.path)", archive.path]),
                ("/opt/homebrew/bin/unrar", ["x", "-o+", "-p\(password)", archive.path, directory.path + "/"]),
                ("/usr/local/bin/unrar", ["x", "-o+", "-p\(password)", archive.path, directory.path + "/"])
            ]
        }
        candidates += [
            ("/opt/homebrew/bin/unar", ["-o", directory.path, archive.path]),
            ("/usr/local/bin/unar", ["-o", directory.path, archive.path]),
            ("/opt/homebrew/bin/7z", ["x", "-y", "-o\(directory.path)", archive.path]),
            ("/usr/local/bin/7z", ["x", "-y", "-o\(directory.path)", archive.path]),
            ("/opt/homebrew/bin/unrar", ["x", "-o+", archive.path, directory.path + "/"]),
            ("/usr/local/bin/unrar", ["x", "-o+", archive.path, directory.path + "/"])
        ]

        for (tool, args) in candidates {
            if FileManager.default.isExecutableFile(atPath: tool) {
                try await run(tool, args)
                return
            }
        }

        let format = archive.pathExtension.uppercased()
        throw ArchiveError.toolFailed(
            "解压 \(format) 需要额外工具。可在终端执行：brew install unar"
        )
    }

    private static func listWithOptionalTools(archive: URL) async throws -> [String] {
        let candidates: [(String, [String])] = [
            ("/opt/homebrew/bin/zipinfo", ["-1", archive.path]),
            ("/opt/homebrew/bin/7z", ["l", "-ba", "-slt", archive.path]),
            ("/usr/local/bin/7z", ["l", "-ba", "-slt", archive.path]),
            ("/opt/homebrew/bin/unar", ["-l", archive.path]),
            ("/usr/local/bin/unar", ["-l", archive.path])
        ]
        for (tool, args) in candidates {
            guard FileManager.default.isExecutableFile(atPath: tool) else { continue }
            let out = try await run(tool, args)
            if tool.contains("7z") {
                return out.split(separator: "\n").compactMap { line -> String? in
                    let s = String(line)
                    if s.hasPrefix("Path = ") {
                        let p = String(s.dropFirst("Path = ".count))
                        return p == archive.lastPathComponent ? nil : p
                    }
                    return nil
                }
            }
            if tool.contains("unar") {
                // unar -l lines often look like:   path/to/file  (size)
                return out.split(separator: "\n").compactMap { line -> String? in
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    guard !s.isEmpty, !s.hasPrefix("unar:"), !s.hasPrefix("(") else { return nil }
                    if let range = s.range(of: #"\s+\d+\s*$"#, options: .regularExpression) {
                        return String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    }
                    return s
                }
            }
            return out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        }
        throw ArchiveError.toolFailed("无法列出压缩包内容，可安装：brew install unar")
    }

    private static func extractSingleCompressedFile(archive: URL, to directory: URL) async throws {
        let ext = archive.pathExtension.lowercased()
        let outName: String
        if archive.lastPathComponent.lowercased().hasSuffix(".\(ext)") {
            outName = String(archive.lastPathComponent.dropLast(ext.count + 1))
        } else {
            outName = archive.deletingPathExtension().lastPathComponent
        }
        let outURL = directory.appendingPathComponent(outName)

        switch ext {
        case "gz":
            try await run("/bin/bash", [
                "-c",
                "/usr/bin/gzip -dc \(shellEscape(archive.path)) > \(shellEscape(outURL.path))"
            ])
        case "bz2":
            try await run("/bin/bash", [
                "-c",
                "/usr/bin/bunzip2 -c \(shellEscape(archive.path)) > \(shellEscape(outURL.path))"
            ])
        case "xz":
            try await run("/bin/bash", [
                "-c",
                "/usr/bin/xz -dc \(shellEscape(archive.path)) > \(shellEscape(outURL.path))"
            ])
        default:
            throw ArchiveError.unsupportedArchive(archive.lastPathComponent)
        }
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Wait without blocking the cooperative thread pool forever
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outText = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let detail = errText.isEmpty ? outText : errText
            throw ArchiveError.toolFailed(
                detail.isEmpty
                    ? "命令失败：\(launchPath)（退出码 \(process.terminationStatus)）"
                    : detail
            )
        }

        return outText
    }
}
