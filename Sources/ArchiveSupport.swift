import AppKit
import Foundation

struct ArchiveCompressOptions {
    var directory: URL
    var fileName: String
    var format: String // zip | tar.gz
    var split: String // none | 1m | ...
    var password: String
    var deleteSource: Bool

    var archiveURL: URL {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = format == "tar.gz" ? "tar.gz" : "zip"
        if !name.lowercased().hasSuffix(".\(ext)") {
            if name.lowercased().hasSuffix(".zip") || name.lowercased().hasSuffix(".tar.gz") {
                // keep user extension
            } else {
                name += ".\(ext)"
            }
        }
        return directory.appendingPathComponent(name)
    }

    var compressFormat: CompressFormat {
        format == "tar.gz" ? .tarGz : .zip
    }

    var splitVolume: SplitVolumeSize {
        SplitVolumeSize.fromDialogValue(split)
    }
}

struct ArchiveExtractOptions {
    var directory: URL
    var folderName: String // empty = extract into directory directly
    var password: String
    var deleteSource: Bool
    /// When true, each archive extracts into a subfolder named after the archive stem.
    var useArchiveName: Bool = false

    var destinationURL: URL {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return directory }
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    func destinationURL(for archive: URL) -> URL {
        if useArchiveName {
            let name = ArchiveEngine.stemName(for: archive)
            return directory.appendingPathComponent(name, isDirectory: true)
        }
        return destinationURL
    }
}

/// Built-in archive helpers (ZIP / TAR.GZ compress; broader extract via system tools).
enum ArchiveSupport {
    static func looksLikeArchive(_ url: URL) -> Bool {
        ArchiveEngine.looksLikeArchive(url)
    }

    static func extractFolderName(for archive: URL) -> String {
        ArchiveEngine.stemName(for: archive)
    }

    /// Suggested ZIP name that does not collide with the selected files.
    static func suggestedCompressFileName(for urls: [URL], in directory: URL) -> String {
        let proposed = ArchiveEngine.defaultArchiveName(for: urls, format: .zip)
        let avoid = Set(urls.map { $0.standardizedFileURL.path })
        var name = proposed
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent(name).standardizedFileURL
            if !avoid.contains(candidate.path), !FileManager.default.fileExists(atPath: candidate.path) {
                return name
            }
            let stem = (proposed as NSString).deletingPathExtension
            name = "\(stem) \(index).zip"
            index += 1
        }
    }

    static func compress(
        urls: [URL],
        options: ArchiveCompressOptions,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let password = options.password.isEmpty ? nil : options.password
        Task {
            do {
                try await ArchiveEngine.compress(
                    items: urls,
                    to: options.archiveURL,
                    format: options.compressFormat,
                    password: password,
                    split: options.splitVolume,
                    progress: { _ in }
                )
                await MainActor.run { completion(.success(())) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    static func extract(
        urls: [URL],
        options: ArchiveExtractOptions,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let password = options.password.isEmpty ? nil : options.password
        let archives = urls.map(\.standardizedFileURL)
        Task {
            do {
                for archive in archives {
                    let destination = options.destinationURL(for: archive).standardizedFileURL
                    if destination.path == archive.path {
                        throw ArchiveError.toolFailed("解压目标不能是压缩包本身")
                    }
                    try FileManager.default.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                    try await ArchiveEngine.extract(
                        archive: archive,
                        to: destination,
                        password: password,
                        protecting: archives,
                        progress: { _ in }
                    )
                }
                await MainActor.run { completion(.success(())) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Blocking list for background-queue archive browsing.
    static func listEntries(in archive: URL) throws -> [ArchiveListEntry] {
        try runBlocking {
            try await ArchiveEngine.listEntries(in: archive)
        }
    }

    /// Children of `internalPath` ("" = archive root) as FileItems for the table.
    static func browseChildren(archive: URL, internalPath: String) throws -> [FileItem] {
        let entries = try listEntries(in: archive)
        let prefix = internalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var children: [String: FileItem] = [:]

        for entry in entries {
            let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { continue }

            let relative: String
            if prefix.isEmpty {
                relative = path
            } else if path == prefix {
                continue
            } else if path.hasPrefix(prefix + "/") {
                relative = String(path.dropFirst(prefix.count + 1))
            } else {
                continue
            }

            let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            let name = String(first)
            let isDirectDirectory = parts.count > 1 || entry.isDirectory
            let childPath = prefix.isEmpty ? name : "\(prefix)/\(name)"

            if children[name] == nil {
                children[name] = FileItem.archiveEntry(
                    archive: archive,
                    entryPath: childPath,
                    name: name,
                    isDirectory: isDirectDirectory,
                    size: parts.count == 1 && !entry.isDirectory ? entry.size : nil
                )
            } else if isDirectDirectory, let existing = children[name], !existing.isDirectory {
                children[name] = FileItem.archiveEntry(
                    archive: archive,
                    entryPath: childPath,
                    name: name,
                    isDirectory: true,
                    size: nil
                )
            }
        }

        return children.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
        let box = ArchiveBlockingBox<T>()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                box.result = .success(try await work())
            } catch {
                box.result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()
        return try box.result!.get()
    }
}

private final class ArchiveBlockingBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}
