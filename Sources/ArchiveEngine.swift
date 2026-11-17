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

/// How far along a compression is.
struct ArchiveProgress {
    /// The share of the work that is done, from 0 to 1.
    var fraction: Double
    /// The bytes that have been written so far.
    var completedBytes: UInt64
    /// The total number of bytes to compress.
    var totalBytes: UInt64

    /// The percentage, as a whole number.
    var percent: Int {
        guard totalBytes > 0 else { return 0 }
        let value = Int((fraction * 100).rounded())
        return min(100, max(0, value))
    }
}

/// The state of one file inside an archive that is being written.
///
/// The window shows one row of these, so the person can see how each file
/// is doing and how well it compresses.
struct ArchiveFileProgress {
    /// The name of the file inside the archive.
    var name: String
    /// How big the file was before it was compressed.
    var originalBytes: UInt64
    /// How big the file is inside the archive.
    var compressedBytes: UInt64
    /// How much of the file has been read so far.
    var completedBytes: UInt64

    /// How far along this file is, from 0 to 1.
    var fraction: Double {
        guard originalBytes > 0 else { return 1 }
        return min(1, Double(completedBytes) / Double(originalBytes))
    }

    /// The percentage of this file that is done.
    var percent: Int {
        guard originalBytes > 0 else { return 100 }
        let value = Int((fraction * 100).rounded())
        return min(100, max(0, value))
    }

    /// How much smaller the file became, as a percentage.
    ///
    /// A file that grew — which happens with files that are already
    /// compressed — gives a negative number. A file that has not been
    /// written yet has no size in the archive, so it has no ratio either.
    var ratioPercent: Int {
        guard originalBytes > 0, compressedBytes > 0 else { return 0 }
        let saved = Double(originalBytes) - Double(compressedBytes)
        return Int((saved * 100 / Double(originalBytes)).rounded())
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
            let item = items[0]
            var base = stemName(for: item)
            if looksLikeArchive(item) {
                base += " 压缩"
            }
            return "\(base).\(format.fileExtension)"
        }
        return "Archive.\(format.fileExtension)"
    }

    /// Strip one archive extension (including `.tar.gz`) for suggested names.
    static func stemName(for url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        if lower.hasSuffix(".tar.bz2") { return String(name.dropLast(8)) }
        if lower.hasSuffix(".tar.xz") { return String(name.dropLast(7)) }
        return url.deletingPathExtension().lastPathComponent
    }

    static func compress(
        items: [URL],
        to destination: URL,
        format: CompressFormat,
        password: String? = nil,
        split: SplitVolumeSize = .none,
        progress: @escaping (String) -> Void,
        progressDetail: ((ArchiveProgress) -> Void)? = nil,
        fileProgress: ((ArchiveFileProgress) -> Void)? = nil,
        processControl: ((Process) -> Void)? = nil
    ) async throws {
        guard !items.isEmpty else { throw ArchiveError.emptySelection }

        try Task.checkCancellation()
        progress("正在压缩…")

        // The size of the source, which the progress is measured against.
        let sourceBytes = totalSize(of: items)

        let wantsZipFeatures = (password?.isEmpty == false) || split != .none
        let effectiveFormat: CompressFormat = wantsZipFeatures ? .zip : format

        switch effectiveFormat {
        case .zip:
            try await compressZip(
                items: items,
                to: destination,
                password: password,
                split: split,
                sourceBytes: sourceBytes,
                progressDetail: progressDetail,
                fileProgress: fileProgress,
                processControl: processControl
            )
        case .tarGz:
            try await compressTarGz(
                items: items,
                to: destination,
                sourceBytes: sourceBytes,
                progressDetail: progressDetail,
                processControl: processControl
            )
        }

        progress("压缩完成")
    }

    /// The total size of the files that are about to be compressed.
    ///
    /// The size of each item is measured separately, so a folder is walked
    /// and its files are added up.
    static func totalSize(of items: [URL]) -> UInt64 {
        var total: UInt64 = 0
        for item in items {
            total &+= size(of: item)
        }
        return total
    }

    /// The total size of what is inside an archive.
    ///
    /// This is the size of the files once they are out of the archive, not
    /// the size of the archive itself, so it is what the progress of an
    /// extraction is measured against.
    static func totalSize(ofArchiveContents archive: URL) async -> UInt64 {
        let ext = archive.pathExtension.lowercased()
        guard ext == "zip" else { return size(of: archive) }

        let entries = await listZipEntries(archive)
        let total = entries.reduce(Int64(0)) { sum, entry in
            guard !entry.isDirectory, let size = entry.size else { return sum }
            return sum + size
        }
        return total > 0 ? UInt64(total) : size(of: archive)
    }

    private static func size(of url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return UInt64(max(0, values?.fileSize ?? 0))
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: []
        ) else { return 0 }

        var total: UInt64 = 0
        for case let child as URL in enumerator {
            var childIsDirectory: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &childIsDirectory) else { continue }
            if childIsDirectory.boolValue { continue }
            let values = try? child.resourceValues(forKeys: [.fileSizeKey])
            total &+= UInt64(max(0, values?.fileSize ?? 0))
        }
        return total
    }

    static func extract(
        archive: URL,
        to directory: URL,
        password: String? = nil,
        protecting otherArchives: [URL] = [],
        progressDetail: ((ArchiveProgress) -> Void)? = nil,
        fileProgress: ((ArchiveFileProgress) -> Void)? = nil,
        processControl: ((Process) -> Void)? = nil,
        progress: @escaping (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        progress("正在解压…")

        let fm = FileManager.default
        let archive = archive.standardizedFileURL
        let directory = directory.standardizedFileURL
        var protectedPaths = Set(otherArchives.map { $0.standardizedFileURL.path })
        protectedPaths.insert(archive.path)

        guard fm.fileExists(atPath: archive.path) else {
            throw ArchiveError.toolFailed("压缩包不存在：\(archive.lastPathComponent)")
        }
        if directory.path == archive.path {
            throw ArchiveError.toolFailed("解压目标不能是压缩包本身")
        }

        // If the archive lives inside the destination tree, extract via a temp folder
        // first. Otherwise an entry named like the archive can overwrite the source
        // mid-read (ditto/unzip), which then fails with “文件不存在”.
        if archiveIsInsideDestination(archive, destination: directory) {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("NewFinder-extract-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            // A damaged archive is a special case: the files that could be
            // read are worth keeping, so the temporary folder is not thrown
            // away when that happens. Any other failure still cleans up.
            var keepStaging = false
            defer { if !keepStaging { try? fm.removeItem(at: staging) } }
            do {
                try await extractDirect(
                    archive: archive,
                    to: staging,
                    password: password,
                    progressDetail: progressDetail,
                    fileProgress: fileProgress,
                    processControl: processControl
                )
            } catch {
                keepStaging = await isDamagedZipFile(archive)
                guard keepStaging else { throw error }
                // The files that were read are moved to where they belong,
                // and the failure is reported afterwards.
                try mergeExtractedContents(from: staging, into: directory, protecting: protectedPaths)
                throw error
            }
            try mergeExtractedContents(from: staging, into: directory, protecting: protectedPaths)
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try await extractDirect(
                archive: archive,
                to: directory,
                password: password,
                progressDetail: progressDetail,
                fileProgress: fileProgress,
                processControl: processControl
            )
        }

        progress("解压完成")
    }

    /// True when writing into `destination` could replace `archive` itself.
    private static func archiveIsInsideDestination(_ archive: URL, destination: URL) -> Bool {
        let dest = destination.path
        let parent = archive.deletingLastPathComponent().path
        if parent == dest { return true }
        return archive.path.hasPrefix(dest.hasSuffix("/") ? dest : dest + "/")
    }

    private static func mergeExtractedContents(
        from staging: URL,
        into destination: URL,
        protecting protectedPaths: Set<String>
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in items {
            var target = destination.appendingPathComponent(item.lastPathComponent)
            if protectedPaths.contains(target.standardizedFileURL.path) {
                // Keep source archives; place the same-named entry beside them.
                let stem = stemName(for: target)
                let ext = item.pathExtension
                let renamed = ext.isEmpty ? "\(stem) 内容" : "\(stem) 内容.\(ext)"
                target = destination.appendingPathComponent(renamed)
                var index = 2
                while fm.fileExists(atPath: target.path) {
                    let again = ext.isEmpty ? "\(stem) 内容 \(index)" : "\(stem) 内容 \(index).\(ext)"
                    target = destination.appendingPathComponent(again)
                    index += 1
                }
            } else if fm.fileExists(atPath: target.path) {
                // A folder that is already there is not thrown away. Its
                // contents are kept and the new files are added beside them.
                // Otherwise extracting into the folder that holds the
                // archive would delete what was already there.
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try mergeFolderContents(from: item, into: target)
                    continue
                }
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: item, to: target)
        }
    }

    /// Moves what was read out of an archive into a folder that is already
    /// there, keeping the files that were there before.
    private static func mergeFolderContents(from source: URL, into target: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in items {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: destination.path) {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    try mergeFolderContents(from: item, into: destination)
                    continue
                }
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: item, to: destination)
        }
    }

    private static func extractDirect(
        archive: URL,
        to directory: URL,
        password: String?,
        progressDetail: ((ArchiveProgress) -> Void)? = nil,
        fileProgress: ((ArchiveFileProgress) -> Void)? = nil,
        processControl: ((Process) -> Void)? = nil
    ) async throws {
        let name = archive.lastPathComponent.lowercased()
        let ext = archive.pathExtension.lowercased()

        if ext == "zip" {
            if let password, !password.isEmpty {
                try await run("/usr/bin/unzip", [
                    "-P", password, "-o", archive.path, "-d", directory.path
                ])
            } else {
                try await extractZipWithProgress(
                    archive: archive,
                    to: directory,
                    password: password,
                    progressDetail: progressDetail,
                    fileProgress: fileProgress,
                    processControl: processControl
                )
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
    }

    /// Extracts a zip file.
    ///
    /// `bsdtar` is used, not `ditto`. `ditto -x -k` only understands the
    /// zips that the Archive Utility makes — it reads the `__MACOSX`
    /// metadata that goes with them — and it gives up with “Couldn't read
    /// pkzip signature” on an ordinary zip. `bsdtar` reads both kinds, and
    /// it also recovers the entries of a zip that was truncated part way
    /// through: `ditto` lost every file in that case, `bsdtar` kept the
    /// ones that were complete.
    ///
    /// A zip that is damaged fails, and the failure is reported in a way
    /// that says what is wrong: the file itself is broken, and the person
    /// has to get another copy of it. Whatever could be read is left on
    /// disk, so the work is not thrown away.
    private static func extractZip(archive: URL, to directory: URL) async throws {
        do {
            try await run(
                "/usr/bin/bsdtar",
                ["-xf", archive.path, "-C", directory.path],
                environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            )
        } catch {
            // The archive may simply be broken. That is worth saying in
            // plain words, because the tools only answer “bsdtar: (null)”.
            if await isDamagedZip(archive) {
                throw ArchiveError.toolFailed(
                    damagedZipMessage(archive, recoveredIn: directory)
                )
            }
            throw error
        }
    }

    /// Extracts a zip file, saying how far along it is.
    ///
    /// The reporter is used when it is there, because it knows how big
    /// every file in the archive is and can say how far along each one is.
    /// Without it the archive is still extracted, only the progress is
    /// missing.
    ///
    /// A zip that was cut short is still handled the same way as before:
    /// the files that could be read are kept, and the failure is reported
    /// afterwards.
    private static func extractZipWithProgress(
        archive: URL,
        to directory: URL,
        password: String?,
        progressDetail: ((ArchiveProgress) -> Void)?,
        fileProgress: ((ArchiveFileProgress) -> Void)?,
        processControl: ((Process) -> Void)?
    ) async throws {
        guard let script = progressReporterURL(named: "progress_unzip") else {
            try await extractZip(archive: archive, to: directory)
            return
        }

        // The size of the archive is what has to be read, so it is used as
        // the total of the progress.
        let total = size(of: archive)

        var arguments = [script.path, archive.path, directory.path]
        if let password, !password.isEmpty {
            arguments.append(password)
        }

        do {
            try await run(
                "/usr/bin/python3",
                arguments,
                environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"],
                sourceBytes: total,
                progressDetail: progressDetail,
                progressParser: Self.reporterBytesHandled(in:),
                reportsAbsoluteValue: true,
                fileParser: Self.reporterFileProgress(in:),
                fileProgress: fileProgress,
                processControl: processControl,
                keepsOutputOnFailure: true
            )
        } catch {
            // The archive may simply be broken. That is worth saying in
            // plain words, because the tools only answer “bsdtar: (null)”.
            if await isDamagedZip(archive) {
                throw ArchiveError.toolFailed(
                    damagedZipMessage(archive, recoveredIn: directory)
                )
            }
            throw error
        }
    }

    /// True when the file is a zip that was cut short.
    ///
    /// A zip ends with a table of contents — the “central directory” —
    /// and that table is what the tools read to find the files. When the
    /// file has no such table it was cut short while it was being written.
    static func isDamagedZipFile(_ archive: URL) async -> Bool {
        guard archive.pathExtension.lowercased() == "zip" else { return false }
        return await isDamagedZip(archive)
    }

    /// True when the file is not a readable zip.
    ///
    /// A zip is finished with a table of contents — the “central
    /// directory” — and that table is what the tools read to find the
    /// files. When the file has no such table it was cut short while it
    /// was being written, and there is no way to read it as a whole.
    private static func isDamagedZip(_ archive: URL) async -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return false }
        defer { try? handle.close() }

        // The end-of-central-directory record is the last 22 bytes, plus a
        // comment that can be up to 64 KB long.
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= 22 else { return true }

        let tailLength = min(size, 64 * 1024 + 22)
        guard (try? handle.seek(toOffset: UInt64(size) - UInt64(tailLength))) != nil,
              let data = try? handle.read(upToCount: Int(tailLength)) else { return true }

        // The record starts with `PK\x05\x06`.
        return !data.contains([0x50, 0x4B, 0x05, 0x06])
    }

    /// The message shown for a zip that cannot be read.
    ///
    /// When some of the files could be read they are named, so the person
    /// knows what was saved and what is still missing.
    private static func damagedZipMessage(_ archive: URL, recoveredIn directory: URL) -> String {
        let recovered = recoveredFiles(in: directory)
        var text = """
        压缩包已损坏，无法完整解压。
        \(archive.lastPathComponent) 缺少目录信息，文件在制作过程中被截断了。
        """
        if recovered.isEmpty {
            text += "\n没有读出任何文件，请重新获取或重新压缩这个文件。"
        } else {
            text += "\n已读出 \(recovered.count) 个文件："
            for name in recovered.prefix(5) {
                text += "\n· \(name)"
            }
            if recovered.count > 5 {
                text += "\n…以及其他 \(recovered.count - 5) 个文件"
            }
            text += "\n请重新获取或重新压缩这个文件，以取回剩下的内容。"
        }
        return text
    }

    /// The files that were read out of an archive, by name.
    private static func recoveredFiles(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        ) else { return [] }

        var names: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            // A file that came out empty is not a file that was read.
            guard (values?.fileSize ?? 0) > 0 else { continue }
            names.append(url.lastPathComponent)
        }
        return names.sorted()
    }

    /// Lists the files inside a zip, with the size of each one.
    ///
    /// A zip that was cut short makes the tool stop with an error, but the
    /// names it printed before it stopped are still good. They are kept, so
    /// the archive window shows what can be seen instead of an empty list.
    ///
    /// The listing is made with the verbose form, which prints the size of
    /// every file next to its name:
    ///
    ///     -rw-r--r--  0 501    0          5 Nov 15 18:13 folder/file.txt
    ///
    private static func listZipEntries(_ archive: URL) async -> [ArchiveListEntry] {
        let out = try? await run(
            "/usr/bin/bsdtar",
            ["-tvf", archive.path],
            environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"],
            keepsOutputOnFailure: true
        )
        guard let out else { return [] }

        // The tool writes its complaints to the same stream as the names,
        // so the lines that are not names are dropped. Otherwise they show
        // up in the file list as if they were folders.
        var entries: [ArchiveListEntry] = []
        for line in out.split(whereSeparator: { $0.isNewline }) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // The complaint can be written right after the last name,
            // without a line break in between, so it is cut off here.
            for marker in ["bsdtar:", "tar:", "zip:"] {
                if let cut = trimmed.range(of: marker) {
                    trimmed = String(trimmed[trimmed.startIndex..<cut.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            guard !trimmed.isEmpty else { continue }

            guard let entry = parseVerboseLine(trimmed) else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Reads one line of a verbose archive listing.
    ///
    /// The line looks like this:
    ///
    ///     -rw-r--r--  0 501    0          5 Nov 15 18:13 folder/file.txt
    ///
    /// The size is the number before the date, and the name is everything
    /// after the date. The line is taken apart from both ends, because the
    /// date is written in different ways depending on the language and the
    /// name may hold spaces.
    private static func parseVerboseLine(_ line: String) -> ArchiveListEntry? {
        let fields = line.split(
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )
        guard fields.count >= 6 else { return nil }

        // The first field is the permissions. A name that starts with
        // something else is not a listing line.
        let permissions = String(fields[0])
        guard permissions.first == "-" || permissions.first == "d" else { return nil }

        // The date is the month, the day and the year, and after it comes
        // the time and then the name. The name is the last part of the
        // line, so it is taken from the end.
        //
        //     perms  0 501  0  5  Nov 15 18:13  name
        //                   ^     ^         ^
        //                   size  month     name starts after the time
        //
        // The size is the last number before the month. It is looked for
        // from the front, because the number of spaces the tool puts
        // between the fields is not the same on every line.
        var sizeIndex: Int? = nil
        for index in 1..<fields.count {
            if Int64(fields[index]) != nil {
                sizeIndex = index
            } else {
                break
            }
        }
        guard let sizeIndex else { return nil }
        // The fields after the size are the date and the time, then the
        // name. The name always follows at least three of them.
        let nameStart = sizeIndex + 4
        guard nameStart < fields.count else { return nil }

        let name = fields[nameStart...]
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces)

        var path = name
        if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        guard !path.isEmpty, path != "." else { return nil }

        let isDirectory = permissions.first == "d" || name.hasSuffix("/")
        return ArchiveListEntry(
            path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            isDirectory: isDirectory,
            size: isDirectory ? nil : Int64(fields[sizeIndex])
        )
    }

    /// Flat list of all entries inside an archive (files and inferred directories).
    static func listEntries(in archive: URL) async throws -> [ArchiveListEntry] {
        let name = archive.lastPathComponent.lowercased()
        let ext = archive.pathExtension.lowercased()

        if ext == "zip" {
            // Apple zipinfo/unzip -Z mangle UTF-8 names into '?'. bsdtar preserves them.
            let entries = await listZipEntries(archive)
            return normalizeListEntries(entries)
        }

        let paths: [String]
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            let out = try await run("/usr/bin/tar", ["-tzf", archive.path])
            paths = out.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
        } else if name.hasSuffix(".tar.bz2") {
            let out = try await run("/usr/bin/tar", ["-tjf", archive.path])
            paths = out.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
        } else if name.hasSuffix(".tar.xz") {
            let out = try await run("/usr/bin/tar", ["-tJf", archive.path])
            paths = out.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
        } else if ext == "tar" {
            let out = try await run("/usr/bin/tar", ["-tf", archive.path])
            paths = out.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
        } else if ext == "rar" || ext == "7z" {
            paths = try await listWithOptionalTools(archive: archive)
        } else {
            throw ArchiveError.unsupportedArchive(archive.lastPathComponent)
        }

        return normalizeListEntries(paths.map {
            ArchiveListEntry(path: $0, isDirectory: $0.hasSuffix("/"), size: nil)
        })
    }

    // MARK: - Private

    /// Fills in the folders that the entries imply, and keeps the sizes.
    private static func normalizeListEntries(_ rawEntries: [ArchiveListEntry]) -> [ArchiveListEntry] {
        var directories = Set<String>()
        var files: [ArchiveListEntry] = []

        for entry in rawEntries {
            let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty, !path.hasPrefix("__MACOSX") else { continue }
            let isDir = entry.isDirectory
            if isDir {
                directories.insert(path)
            } else {
                files.append(ArchiveListEntry(path: path, isDirectory: false, size: entry.size))
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
        result += files
        return result
    }

    private static func compressZip(
        items: [URL],
        to destination: URL,
        password: String?,
        split: SplitVolumeSize,
        sourceBytes: UInt64,
        progressDetail: ((ArchiveProgress) -> Void)?,
        fileProgress: ((ArchiveFileProgress) -> Void)?,
        processControl: ((Process) -> Void)?
    ) async throws {
        let fm = FileManager.default
        let outputDir = fm.temporaryDirectory
            .appendingPathComponent("NewFinder-zipout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: outputDir)
        }

        // A password and split volumes are things the `zip` command does and
        // the progress reporter does not, so those go through the command.
        // Without them the reporter is used, which can say how far along
        // the work is even while a single big file is being read.
        let needsZipCommand = (password?.isEmpty == false) || split != .none

        // The archive is written straight to its final name, so the file
        // shows up in the folder right away and grows as the work goes on.
        // The old file is kept until the new one is ready, so a failure
        // never leaves the user without their archive.
        let destination = destination.standardizedFileURL
        let backupURL = fm.fileExists(atPath: destination.path)
            ? outputDir.appendingPathComponent("previous-archive")
            : nil
        if let backupURL {
            try fm.moveItem(at: destination, to: backupURL)
        }
        var workFinished = false
        defer {
            if workFinished {
                // The new archive is good; the old one is not needed.
                if let backupURL { try? fm.removeItem(at: backupURL) }
            } else {
                // The work was stopped or failed, so the half-written
                // archive is taken away and the old one goes back.
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                if let backupURL {
                    try? fm.moveItem(at: backupURL, to: destination)
                }
            }
        }

        let tempZip = destination

        if needsZipCommand {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("NewFinder-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(at: staging)
            }

            for item in items {
                try fm.copyItem(
                    at: item,
                    to: staging.appendingPathComponent(item.lastPathComponent)
                )
            }
            // The verbose mode prints how much of each file has been handled,
            // which is what the progress is measured from.
            var zipArgs = "/usr/bin/zip -r -v"
            if let password, !password.isEmpty {
                zipArgs += " -P \(shellEscape(password))"
            }
            if let splitArg = split.zipSplitArgument {
                zipArgs += " -s \(splitArg)"
            }
            zipArgs += " \(shellEscape(tempZip.path)) ."

            try await run(
                "/bin/bash",
                ["-c", "cd \(shellEscape(staging.path)) && \(zipArgs)"],
                environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"],
                sourceBytes: sourceBytes,
                progressDetail: progressDetail,
                progressParser: Self.zipBytesHandled(in:),
                processControl: processControl
            )
        } else {
            try await compressZipWithProgressReporter(
                items: items,
                to: tempZip,
                sourceBytes: sourceBytes,
                progressDetail: progressDetail,
                fileProgress: fileProgress,
                processControl: processControl
            )
        }

        guard fm.fileExists(atPath: tempZip.path) else {
            throw ArchiveError.toolFailed("压缩完成但未生成 ZIP 文件")
        }
        // The `zip` command mangles non-ASCII names, so the flag is set by
        // hand. The reporter already sets it correctly, and rewriting its
        // file would break the archive.
        if needsZipCommand {
            try markZipFilenamesAsUTF8(at: tempZip)
        }
        // The split parts, if there are any, also belong in the folder.
        if needsZipCommand {
            moveSplitParts(from: outputDir, to: destination)
        }
        workFinished = true
    }

    /// Compresses with the progress reporter, which reads the source in
    /// chunks and says how many bytes have been handled.
    private static func compressZipWithProgressReporter(
        items: [URL],
        to destination: URL,
        sourceBytes: UInt64,
        progressDetail: ((ArchiveProgress) -> Void)?,
        fileProgress: ((ArchiveFileProgress) -> Void)?,
        processControl: ((Process) -> Void)?
    ) async throws {
        guard let script = progressReporterURL() else {
            // Without the reporter the compression still works, only the
            // progress is missing.
            var zipArgs = "/usr/bin/zip -r \(shellEscape(destination.path))"
            for item in items {
                zipArgs += " \(shellEscape(item.path))"
            }
            try await run("/bin/bash", ["-c", zipArgs], processControl: processControl)
            return
        }

        var arguments = [script.path, destination.path]
        arguments += items.map(\.path)

        try await run(
            "/usr/bin/python3",
            arguments,
            environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"],
            sourceBytes: sourceBytes,
            progressDetail: progressDetail,
            progressParser: Self.reporterBytesHandled(in:),
            reportsAbsoluteValue: true,
            fileParser: Self.reporterFileProgress(in:),
            fileProgress: fileProgress,
            processControl: processControl
        )
    }

    /// The progress reporter that ships inside the app bundle.
    private static func progressReporterURL(named name: String = "progress_zip") -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: name, withExtension: "py") {
            return url
        }
        // When the app runs from the build folder the resource sits next
        // to the executable.
        let beside = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/\(name).py")
        if FileManager.default.fileExists(atPath: beside.path) {
            return beside
        }
        // The scripts live in the Tools folder of the project, so the tests
        // and the tools that run from the command line find them there.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // the project
            .appendingPathComponent("Tools/\(name).py")
        if FileManager.default.fileExists(atPath: source.path) {
            return source
        }
        return nil
    }

    /// Reads the number of bytes the reporter says have been handled.
    ///
    /// The reporter prints a line like this:
    ///
    ///     PROGRESS 1048576 1426607415
    ///
    /// The first number is how much has been handled and the second is how
    /// much there is in all. Both are returned, because the total is what
    /// the progress is measured against.
    private static func reporterBytesHandled(in line: String) -> (done: UInt64, total: UInt64)? {
        guard line.hasPrefix("PROGRESS ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, let done = UInt64(fields[1]) else { return nil }
        let total = fields.count >= 3 ? (UInt64(fields[2]) ?? 0) : 0
        return (done, total)
    }

    /// Reads the state of one file that the reporter prints.
    ///
    /// The reporter prints two kinds of line:
    ///
    ///     FILE <name> <original-bytes> <compressed-bytes>
    ///     FILEPROGRESS <name> <bytes-done> <original-bytes> <compressed-bytes>
    ///
    /// The first says how big the file is and how big it is in the archive.
    /// The second says how far along the file is.
    private static func reporterFileProgress(in line: String) -> ArchiveFileProgress? {
        if line.hasPrefix("FILEPROGRESS ") {
            let rest = String(line.dropFirst("FILEPROGRESS ".count))
            guard let (name, done, original, compressed) = splitProgressLine(rest) else { return nil }
            return ArchiveFileProgress(
                name: name,
                originalBytes: original,
                compressedBytes: compressed,
                completedBytes: done
            )
        }

        guard line.hasPrefix("FILE ") else { return nil }
        let rest = String(line.dropFirst("FILE ".count))
        guard let (name, original, compressed) = splitFileLine(rest) else { return nil }
        return ArchiveFileProgress(
            name: name,
            originalBytes: original,
            compressedBytes: compressed,
            // The line only says how big the file is. It has not been read
            // yet, so the progress starts at nothing.
            completedBytes: 0
        )
    }

    /// Splits a file line into its name and its numbers.
    ///
    /// The name is the first part and the numbers are the last ones, because
    /// a name may hold spaces. The last two numbers are always there; the
    /// third from the end is there too, but only in the progress lines.
    private static func splitFileLine(_ text: String) -> (String, UInt64, UInt64)? {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return nil }
        guard let first = UInt64(fields[fields.count - 2]),
              let second = UInt64(fields[fields.count - 1]) else { return nil }
        let name = fields[0..<(fields.count - 2)].joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return (name, first, second)
    }

    /// Splits a progress line into its name and its numbers.
    ///
    /// The line holds the name and three numbers: how much has been read,
    /// how big the file is and how big it is in the archive.
    private static func splitProgressLine(
        _ text: String
    ) -> (String, UInt64, UInt64, UInt64)? {
        let fields = text.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        guard let done = UInt64(fields[fields.count - 3]),
              let original = UInt64(fields[fields.count - 2]),
              let compressed = UInt64(fields[fields.count - 1]) else { return nil }
        let name = fields[0..<(fields.count - 3)].joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return (name, done, original, compressed)
    }

    /// Move the `name.z01`, `name.z02`, … parts of a split archive into the
    /// folder, next to the archive itself.
    private static func moveSplitParts(from outputDir: URL, to destination: URL) {
        let fm = FileManager.default
        let destParent = destination.standardizedFileURL.deletingLastPathComponent()
        let destStem = destination.deletingPathExtension().lastPathComponent

        guard let files = try? fm.contentsOfDirectory(atPath: outputDir.path) else { return }
        for name in files {
            guard isNumericSplitPart(name, stem: destStem) else { continue }
            let suffix = String(name.dropFirst(destStem.count)) // .z01
            let target = destParent.appendingPathComponent(destStem + suffix)
            if fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
            }
            try? fm.moveItem(at: outputDir.appendingPathComponent(name), to: target)
        }
    }

    /// Move a newly built archive (and optional `name.z01` split parts) into place.
    /// Replaces the destination only after the new file is complete.
    private static func publishArchive(from outputDir: URL, primary: URL, to destination: URL) throws {
        let fm = FileManager.default
        let dest = destination.standardizedFileURL
        let destParent = dest.deletingLastPathComponent()
        let destStem = dest.deletingPathExtension().lastPathComponent
        try fm.createDirectory(at: destParent, withIntermediateDirectories: true)

        removeNumericSplitParts(stem: destStem, in: destParent)

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: primary, to: dest)

        let outStem = primary.deletingPathExtension().lastPathComponent
        if let files = try? fm.contentsOfDirectory(atPath: outputDir.path) {
            for name in files {
                guard isNumericSplitPart(name, stem: outStem) else { continue }
                let suffix = String(name.dropFirst(outStem.count)) // .z01
                let target = destParent.appendingPathComponent(destStem + suffix)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.moveItem(at: outputDir.appendingPathComponent(name), to: target)
            }
        }
    }

    /// Info-ZIP split parts are `name.z01`, `name.z02`, … — not `name.zip`.
    private static func isNumericSplitPart(_ fileName: String, stem: String) -> Bool {
        let prefix = stem + ".z"
        guard fileName.hasPrefix(prefix) else { return false }
        let digits = fileName.dropFirst(prefix.count)
        return !digits.isEmpty && digits.count <= 3 && digits.allSatisfy(\.isNumber)
    }

    private static func removeNumericSplitParts(stem: String, in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in files where isNumericSplitPart(name, stem: stem) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
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

    private static func compressTarGz(
        items: [URL],
        to destination: URL,
        sourceBytes: UInt64,
        progressDetail: ((ArchiveProgress) -> Void)?,
        processControl: ((Process) -> Void)?
    ) async throws {
        let fm = FileManager.default
        let outputDir = fm.temporaryDirectory
            .appendingPathComponent("NewFinder-tarout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: outputDir)
        }

        // The archive is written straight to its final name, so the file
        // shows up in the folder right away and grows as the work goes on.
        let destination = destination.standardizedFileURL
        let backupURL = fm.fileExists(atPath: destination.path)
            ? outputDir.appendingPathComponent("previous-archive")
            : nil
        if let backupURL {
            try fm.moveItem(at: destination, to: backupURL)
        }
        var workFinished = false
        defer {
            if workFinished {
                // The new archive is good; the old one is not needed.
                if let backupURL { try? fm.removeItem(at: backupURL) }
            } else {
                // The work was stopped or failed, so the half-written
                // archive is taken away and the old one goes back.
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                if let backupURL {
                    try? fm.moveItem(at: backupURL, to: destination)
                }
            }
        }

        let tempArchive = destination

        // The reporter reads the source in chunks, so the progress moves
        // along even while one big file is being compressed.
        if let script = progressReporterURL(named: "progress_tar") {
            var arguments = [script.path, tempArchive.path]
            arguments += items.map(\.path)

            try await run(
                "/usr/bin/python3",
                arguments,
                environment: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"],
                sourceBytes: sourceBytes,
                progressDetail: progressDetail,
                progressParser: Self.reporterBytesHandled(in:),
                reportsAbsoluteValue: true,
                processControl: processControl
            )
        } else {
            let staging = fm.temporaryDirectory
                .appendingPathComponent("NewFinder-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(at: staging)
            }

            for item in items {
                try fm.copyItem(
                    at: item,
                    to: staging.appendingPathComponent(item.lastPathComponent)
                )
            }

            // The verbose mode lists every file as it is added, so the size of
            // each one can be added up to make the progress.
            try await run("/usr/bin/tar", [
                "-czvf", tempArchive.path,
                "-C", staging.path,
                "."
            ], sourceBytes: sourceBytes, progressDetail: progressDetail, progressParser: { line in
                Self.tarBytesHandled(in: line, staging: staging)
            }, processControl: processControl)
        }

        guard fm.fileExists(atPath: tempArchive.path) else {
            throw ArchiveError.toolFailed("压缩完成但未生成 TAR.GZ 文件")
        }
        workFinished = true
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
            return out.split(whereSeparator: { $0.isNewline }).map(String.init).filter { !$0.isEmpty }
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

    /// Reads the number of source bytes a `zip -v` line reports.
    ///
    /// The lines look like this:
    ///
    ///     adding: src/file.bin ..    (in=20971520) (out=20974720) (deflated 0%)
    ///
    /// The `in=` number is the size of the file before it was compressed, so
    /// it is the amount of source that has been handled.
    private static func zipBytesHandled(in line: String) -> (done: UInt64, total: UInt64)? {
        guard let range = line.range(of: "(in=") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(where: { $0 == ")" }) else { return nil }
        let number = rest[..<end]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        guard let done = UInt64(number) else { return nil }
        return (done, 0)
    }

    /// Reads the size of a file a `tar -v` line reports.
    ///
    /// The lines look like this:
    ///
    ///     -rw-r--r--  0 0  0  20971520 Nov 15 07:55 src/file.bin
    ///
    /// The number before the date is the size of the file.
    private static func tarBytesHandled(in line: String, staging: URL) -> (done: UInt64, total: UInt64)? {
        // The path is at the end of the line, after the date.
        let fields = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard fields.count >= 6 else { return nil }
        guard fields[0].hasPrefix("-") else { return nil } // a folder, no data

        let name = fields[fields.count - 1]
        let url = staging.appendingPathComponent(name)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, size >= 0 else { return nil }
        return (UInt64(size), 0)
    }

    @discardableResult
    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        sourceBytes: UInt64 = 0,
        progressDetail: ((ArchiveProgress) -> Void)? = nil,
        progressParser: ((String) -> (done: UInt64, total: UInt64)?)? = nil,
        reportsAbsoluteValue: Bool = false,
        fileParser: ((String) -> ArchiveFileProgress?)? = nil,
        fileProgress: ((ArchiveFileProgress) -> Void)? = nil,
        processControl: ((Process) -> Void)? = nil,
        keepsOutputOnFailure: Bool = false
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

        // The caller can hold the tool back or stop it.
        processControl?(process)

        // Read the tool's output while it runs. The lines it prints say how
        // much of the source has been handled, which is the progress.
        let reader = OutputReader(
            pipes: [outPipe, errPipe],
            sourceBytes: sourceBytes,
            progressDetail: progressDetail,
            progressParser: progressParser,
            reportsAbsoluteValue: reportsAbsoluteValue,
            fileParser: fileParser,
            fileProgress: fileProgress
        )
        reader.start()

        // Wait without blocking the cooperative thread pool forever
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        let outText = reader.finish()

        if process.terminationStatus != 0 {
            // Some tools print what they managed to read and then stop with
            // an error — a zip that was cut short lists its first files and
            // then gives up. What was printed is worth keeping, so the
            // caller can show it instead of nothing.
            if keepsOutputOnFailure {
                return outText
            }

            // The progress lines are dropped, so the message only says what
            // really went wrong. It is kept short, because a long message
            // would make the dialog unreadable.
            let detail = reader.errorText()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ArchiveError.toolFailed(
                detail.isEmpty
                    ? "命令失败：\(launchPath)（退出码 \(process.terminationStatus)）"
                    : Self.readableReason(detail)
            )
        }

        return outText
    }

    /// Keeps an error message to a readable length.
    ///
    /// Long messages are cut off at the end, where the last line usually
    /// says what went wrong.
    private static func shortened(_ text: String, limit: Int = 600) -> String {
        guard text.count > limit else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var kept: [String] = []
        var length = 0
        for line in lines {
            let piece = String(line)
            if length + piece.count > limit {
                break
            }
            kept.append(piece)
            length += piece.count + 1
        }
        let shown = kept.joined(separator: "\n")
        return shown + "\n…（输出过长，已省略）"
    }

    /// Turns the output of a failed tool into a short, readable reason.
    ///
    /// A Python traceback is a stack of lines that says very little to the
    /// person who pressed the button, so only the line with the error is
    /// kept.
    private static func readableReason(_ text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // The last line of a Python traceback names the error, e.g.
        // `PermissionError: [Errno 13] Permission denied: '/tmp/out.zip'`.
        if let last = lines.last,
           last.contains(": "),
           !last.hasPrefix("File \""),
           !last.hasPrefix("Traceback") {
            return last
        }

        // Otherwise the last few lines are the best guess.
        let tail = lines.suffix(5).joined(separator: "\n")
        return shortened(tail)
    }
}

/// Reads the output of a compression tool while it runs, and turns the
/// lines it prints into a progress percentage.
///
/// The `zip` tool reports how much of each file it has handled, so the
/// handled bytes are added up as the lines arrive. The progress reporter
/// reports the total handled so far, so its numbers are used as they are.
private final class OutputReader {
    private let pipes: [Pipe]
    private let sourceBytes: UInt64
    private let progressDetail: ((ArchiveProgress) -> Void)?
    /// Reads the amount that has been handled out of a line, and the total
    /// there is in all, when the line says so.
    private let progressParser: ((String) -> (done: UInt64, total: UInt64)?)?
    /// True when the parser reports the total handled so far, rather than
    /// the amount handled by one line.
    private let reportsAbsoluteValue: Bool
    /// Reads the state of a single file out of a line.
    private let fileParser: ((String) -> ArchiveFileProgress?)?
    /// Called with the state of a file as it changes.
    private let fileProgress: ((ArchiveFileProgress) -> Void)?

    private let lock = NSLock()
    private var collected = Data()
    private var handledBytes: UInt64 = 0
    /// The total the tool says there is. It is used when it is known,
    /// because the size of the archive on disk is not the size of what
    /// comes out of it.
    private var reportedTotalBytes: UInt64 = 0
    private var lastPercent = -1
    private var group: DispatchGroup?

    /// What is known about each file, by name.
    ///
    /// The reporter sends the size of a file first and then says how far
    /// along it is, so the two are put together here.
    private var files: [String: ArchiveFileProgress] = [:]
    /// The order the files were mentioned in, so the list keeps its order.
    private var fileOrder: [String] = []

    init(
        pipes: [Pipe],
        sourceBytes: UInt64,
        progressDetail: ((ArchiveProgress) -> Void)?,
        progressParser: ((String) -> (done: UInt64, total: UInt64)?)?,
        reportsAbsoluteValue: Bool = false,
        fileParser: ((String) -> ArchiveFileProgress?)? = nil,
        fileProgress: ((ArchiveFileProgress) -> Void)? = nil
    ) {
        self.pipes = pipes
        self.sourceBytes = sourceBytes
        self.progressDetail = progressDetail
        self.progressParser = progressParser
        self.reportsAbsoluteValue = reportsAbsoluteValue
        self.fileParser = fileParser
        self.fileProgress = fileProgress
    }

    /// Starts reading the pipes in the background.
    func start() {
        let group = DispatchGroup()
        self.group = group

        for pipe in pipes {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    group.leave()
                    return
                }
                self.consumePipe(pipe)
                group.leave()
            }
        }
    }

    /// Waits for the output to be fully read, and returns it as text.
    ///
    /// The progress lines are left out, because they are not a useful
    /// error message — they would fill the dialog with hundreds of lines.
    func finish() -> String {
        group?.wait()
        lock.lock()
        let data = collected
        lock.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The output without the progress lines, so it can be shown as the
    /// reason the work failed.
    func errorText() -> String {
        group?.wait()
        lock.lock()
        let data = collected
        lock.unlock()
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { !isProgressLine(String($0)) }
        return kept.joined(separator: "\n")
    }

    /// True when the line is one of the progress reports, not an error.
    private func isProgressLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("PROGRESS ")
            || trimmed.hasPrefix("FILE ")
            || trimmed.hasPrefix("FILEPROGRESS ")
    }
    /// Reads the pipe line by line while the tool is still running.
    ///
    /// The output is read in pieces rather than all at once, because reading
    /// it all would only return when the tool is done — and then the
    /// progress would never be seen.
    private func consumePipe(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        var pending = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                // The end of the file. Whatever is left is the last line.
                if !pending.isEmpty {
                    handleLine(pending)
                }
                return
            }

            lock.lock()
            collected.append(chunk)
            lock.unlock()

            pending.append(chunk)

            // Only whole lines are handled; the rest waits for more output.
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                handleLine(Data(line))
            }
        }
    }

    /// Handles one line of the tool's output.
    private func handleLine(_ line: Data) {
        let text = String(data: line, encoding: .utf8) ?? ""
        guard !text.isEmpty else { return }

        // The line may be about one file.
        if let fileParser, let fileProgress {
            if let file = fileParser(text) {
                report(file: file, to: fileProgress)
                return
            }
        }

        guard let progressParser, let progressDetail else { return }
        guard let (handled, total) = progressParser(text) else { return }
        report(handled: handled, total: total, detail: progressDetail)
    }

    /// Puts together what is known about a file and tells the caller.
    ///
    /// The reporter sends the size of a file in one line and the progress
    /// in another, so the two are joined here. The list of files is kept in
    /// the order they were mentioned in.
    private func report(file: ArchiveFileProgress, to detail: (ArchiveFileProgress) -> Void) {
        lock.lock()
        var merged = files[file.name] ?? file
        if file.originalBytes > 0 { merged.originalBytes = file.originalBytes }
        if file.compressedBytes > 0 { merged.compressedBytes = file.compressedBytes }
        if file.completedBytes > 0 { merged.completedBytes = file.completedBytes }
        if merged.originalBytes == 0 { merged.originalBytes = merged.completedBytes }

        let isNew = files[file.name] == nil
        files[file.name] = merged
        if isNew { fileOrder.append(file.name) }
        lock.unlock()

        detail(merged)
    }

    private func report(handled: UInt64, total: UInt64, detail: (ArchiveProgress) -> Void) {
        lock.lock()
        // The reporter gives the total handled so far; the tools that print
        // per file give the amount handled by that one file.
        if reportsAbsoluteValue {
            handledBytes = handled
        } else {
            handledBytes += handled
        }
        // The tool may say how much there is in all. That number is used
        // when it is there, because the size of the archive on disk is not
        // the size of what comes out of it.
        if total > 0 { reportedTotalBytes = total }
        let whole = reportedTotalBytes > 0 ? reportedTotalBytes : sourceBytes
        guard whole > 0 else {
            lock.unlock()
            return
        }
        let done = handledBytes
        let fraction = min(1, Double(done) / Double(whole))
        let percent = Int((fraction * 100).rounded())
        let changed = percent != lastPercent
        lastPercent = percent
        lock.unlock()

        guard changed else { return }
        detail(ArchiveProgress(
            fraction: fraction,
            completedBytes: done,
            totalBytes: whole
        ))
    }
}
