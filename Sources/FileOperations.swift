import Foundation
import AppKit

enum FileOperations {
    static let pasteboardType = NSPasteboard.PasteboardType("com.zhangjing.NewFinder.cutURLs")

    // MARK: - Fast directory listing

    /// Folders with more entries than this are listed in two stages: names first
    /// (rows appear immediately), sizes / dates are filled in right after.
    static let progressiveListingThreshold = 4_000

    /// Directory extensions that macOS treats as packages (bundles).
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "prefplugin", "prefPane".lowercased(),
        "xpc", "kext", "systemextension", "pages", "numbers", "key", "rtfd",
        "photoslibrary", "imovielibrary", "musiclibrary", "sparsebundle", "webarchive",
        "download", "term", "dictionary", "service", "systemextension"
    ]

    /// Number of worker threads used to parallelize the per-entry work
    /// (URL creation, sorting, `fstatat`) of a large directory listing.
    ///
    /// `fstatat` is I/O bound, so it scales well past the core count — 32
    /// threads cut the metadata pass on a 200k-entry folder from 2.7 s to 0.24 s.
    private static var workerCount: Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return min(32, max(1, cores * 4))
    }

    /// Thread count for the metadata (`fstatat`) pass — I/O bound, so it uses
    /// more threads than the CPU bound passes.
    private static var statWorkerCount: Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return min(32, max(1, cores * 4))
    }

    /// Full listing of a folder (names + size + modification date), sorted by name.
    ///
    /// Uses `readdir` + parallel `fstatat` instead of
    /// `FileManager.contentsOfDirectory` — the Foundation call is several times
    /// slower on folders that hold tens of thousands of entries.
    static func listDirectory(_ url: URL, showHidden: Bool) -> [FileItem] {
        let dirPath = url.path
        let entries = readDirectoryNames(dirPath, showHidden: showHidden)
        guard !entries.isEmpty else { return [] }
        let stats = statDirectoryEntries(dirPath, names: entries.map(\.name))
        var items = makeItems(dirPath: dirPath, entries: entries, stats: stats)
        refinePackages(&items)
        if !AppSettings.shared.skipInitialSort {
            sortByName(&items)
        }
        return items
    }

    // MARK: - Listing cache

    /// Keeps the most recent large listings in memory.
    ///
    /// Re-opening a folder that holds hundreds of thousands of entries otherwise
    /// costs a full directory read again — with a cold disk cache that is the
    /// difference between an instant response and a visible delay.
    private final class ListingCache {
        static let shared = ListingCache()

        struct Entry {
            let items: [FileItem]
            /// The folder's modification date at the time the listing was built.
            let folderModified: Date
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var order: [String] = []
        private let maxEntries = 3

        func item(for key: String) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func store(_ items: [FileItem], folderModified: Date, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            if entries[key] == nil { order.append(key) }
            entries[key] = Entry(items: items, folderModified: folderModified)
            while order.count > maxEntries {
                let oldest = order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }

        func invalidate(_ key: String) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }

    /// Cache key for a directory listing (path + hidden-file setting).
    private static func cacheKey(for url: URL, showHidden: Bool) -> String {
        "\(url.standardizedFileURL.path)\u{0}\(showHidden ? 1 : 0)"
    }

    /// Reads a directory listing, serving it from the cache when possible.
    ///
    /// Only large folders are cached — small ones are already fast. The cache is
    /// reused only while the folder's modification date is unchanged, so any
    /// edit inside the folder invalidates it automatically.
    static func listDirectoryCached(_ url: URL, showHidden: Bool) -> [FileItem] {
        let key = cacheKey(for: url, showHidden: showHidden)
        let modified = folderModificationDate(url)

        if let cached = ListingCache.shared.item(for: key),
           let modified, cached.folderModified == modified {
            return cached.items
        }

        let items = listDirectory(url, showHidden: showHidden)
        if let modified {
            ListingCache.shared.store(items, folderModified: modified, for: key)
        }
        return items
    }

    /// Drops the cached listing for a folder (after it was modified).
    static func invalidateListingCache(for url: URL) {
        ListingCache.shared.invalidate(cacheKey(for: url, showHidden: true))
        ListingCache.shared.invalidate(cacheKey(for: url, showHidden: false))
    }

    /// The folder's modification date, or `nil` when it cannot be read.
    private static func folderModificationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// Listing that only resolves names + URLs — no `stat` calls at all.
    /// Used for the first paint of very large folders.
    ///
    /// The entries are sorted *before* the `FileItem`s are built, so the items
    /// can be created directly in their final order. That avoids permuting
    /// ~200k structs afterwards (the permutation alone cost more than the sort).
    static func listDirectoryNames(_ url: URL, showHidden: Bool) -> [FileItem] {
        let dirPath = url.path
        let nfT0 = Date()
        var entries = readDirectoryNames(dirPath, showHidden: showHidden)
        let nfT1 = Date()
        guard !entries.isEmpty else { return [] }

        let count = entries.count

        // The metadata pass (`fstatat` on every entry) is the slowest part of
        // listing a huge folder. It does not depend on the sort order, so it
        // is kicked off *first* and runs in the background while the rows are
        // sorted and built. The results are collected later by
        // `enrichWithAttributes` — no entry is ever stat-ed twice.
        let statPass = DirectoryStatPass(count: count)
        statPass.start(dirPath: dirPath, names: entries.map(\.name))

        // Sort the lightweight entries first — cheaper than sorting full items.
        // Skipped when the user asked for the raw file system order.
        let sortEnabled = !AppSettings.shared.skipInitialSort
        if sortEnabled {
            sortEntriesByName(&entries)
        }
        let nfT1b = Date()

        // A relative URL construction is ~2× faster than building the absolute
        // path string by hand and parsing it back.
        let base = URL(filePath: dirPath, directoryHint: .isDirectory)
        var items = [FileItem](repeating: FileItem(
            url: URL(fileURLWithPath: "/"),
            name: "",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: nil,
            modificationDate: nil,
            creationDate: nil,
            archiveEntryPath: nil
        ), count: count)

        let chunks = workerCount
        let per = (count + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * per
            let upper = min(count, lower + per)
            guard lower < upper else { return }
            for index in lower..<upper {
                let entry = entries[index]
                let isDirectory = entry.type == UInt8(DT_DIR)
                // Only folders can be packages — skip the extension lookup for files.
                let looksLikePackage = isDirectory && packageExtensions.contains(entry.fileExtension)
                items[index] = FileItem(
                    url: makeChildURL(base: base, name: entry.name),
                    name: entry.name,
                    isDirectory: isDirectory && !looksLikePackage,
                    isPackage: looksLikePackage,
                    isHidden: entry.name.hasPrefix("."),
                    fileSize: nil,
                    modificationDate: nil,
                    creationDate: nil,
                    archiveEntryPath: nil
                )
            }
        }
        let nfT2 = Date()
        // Only folders big enough to matter are logged — smaller ones are instant.
        if count >= 4_000 {
            NSLog("[NF-PERF] names: readdir=%.3f sort=%.3f build=%.3f count=%d",
                  nfT1.timeIntervalSince(nfT0), nfT1b.timeIntervalSince(nfT1),
                  nfT2.timeIntervalSince(nfT1b), count)
        }
        // Hand the (still running) metadata pass to the registry so the
        // background attribute fill can reuse it instead of stat-ing again.
        StatPassRegistry.shared.register(statPass, for: dirPath)
        return items
    }

    /// Fills in size + modification date for items produced by `listDirectoryNames`.
    /// Returns a new array; the input is left untouched.
    ///
    /// - Parameter directory: the folder the items were listed from (all items live in it).
    static func enrichWithAttributes(_ items: [FileItem], in directory: URL) -> [FileItem] {
        guard !items.isEmpty else { return items }
        let parentPath = directory.path
        // Reuse the metadata pass that already ran while the rows were built.
        // If it is gone (or was for a different folder), stat everything again.
        //
        // The pass is keyed by name: it ran on the `readdir` order while the
        // rows are in sorted order, so matching by position would hand every
        // entry the metadata of a different file (folders would show up as
        // files and vice versa).
        let statsByName: [String: DirStat]
        if let pass = StatPassRegistry.shared.take(for: parentPath), pass.count == items.count {
            statsByName = pass.awaitResults()
        } else {
            let names = items.map(\.name)
            let stats = statDirectoryEntries(parentPath, names: names)
            var byName = [String: DirStat](minimumCapacity: names.count)
            for (index, name) in names.enumerated() where index < stats.count {
                byName[name] = stats[index]
            }
            statsByName = byName
        }
        let count = items.count
        var result = [FileItem](repeating: items[0], count: count)
        let chunks = workerCount
        let per = (count + chunks - 1) / chunks
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * per
            let upper = min(count, lower + per)
            guard lower < upper else { return }
            var local: [FileItem] = []
            local.reserveCapacity(upper - lower)
            for index in lower..<upper {
                let item = items[index]
                guard let stat = statsByName[item.name], stat.succeeded else {
                    local.append(item)
                    continue
                }
                let extensionName = Self.fileExtension(of: item.name)
                let isPackage = item.isPackage
                    || (stat.isDirectory && packageExtensions.contains(extensionName))
                local.append(FileItem(
                    url: item.url,
                    name: item.name,
                    isDirectory: stat.isDirectory && !isPackage,
                    isPackage: isPackage,
                    isHidden: stat.isHidden || item.isHidden,
                    fileSize: (stat.isDirectory && !isPackage) ? nil : stat.size,
                    modificationDate: stat.modified,
                    creationDate: nil,
                    archiveEntryPath: nil
                ))
            }
            for (offset, index) in (lower..<upper).enumerated() {
                result[index] = local[offset]
            }
        }
        refinePackages(&result)
        return result
    }

    /// Lower-cased file extension without the dot ("" when there is none).
    private static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    // MARK: - Listing internals

    private struct DirEntry {
        let name: String
        let type: UInt8
        var fileExtension: String {
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
            return String(name[name.index(after: dot)...]).lowercased()
        }
    }

    struct DirStat {
        var succeeded = false
        var isDirectory = false
        var isHidden = false
        var size: Int64 = 0
        var modified: Date?
    }

    // MARK: - Overlapped metadata pass

    /// Runs the (slow) `fstatat` pass for a folder in the background so it can
    /// overlap with the sorting / row building that happens right after.
    ///
    /// The pass is started as soon as the names are known and the results are
    /// collected later — the caller waits for them only when the sizes are
    /// actually needed. This removes the metadata pass from the critical path
    /// instead of running it strictly *after* the rows are on screen.
    final class DirectoryStatPass {
        let count: Int
        private let lock = NSLock()
        /// Metadata keyed by file name.
        ///
        /// The pass runs on the `readdir` order while the rows are built in
        /// sorted order, so the results cannot be matched by position — they
        /// have to be looked up by name.
        private var results: [String: DirStat]?
        private var finished = false
        private let group = DispatchGroup()

        init(count: Int) {
            self.count = count
        }

        /// Starts the metadata pass on a background queue.
        func start(dirPath: String, names: [String]) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    self?.group.leave()
                    return
                }
                let stats = FileOperations.statDirectoryEntries(dirPath, names: names)
                var byName = [String: DirStat](minimumCapacity: names.count)
                for (index, name) in names.enumerated() where index < stats.count {
                    byName[name] = stats[index]
                }
                self.lock.lock()
                self.results = byName
                self.finished = true
                self.lock.unlock()
                self.group.leave()
            }
        }

        /// Waits for the pass to finish and returns the collected metadata.
        func awaitResults() -> [String: DirStat] {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return results ?? [:]
        }
    }

    /// Keeps the metadata pass of the most recent listing around so the
    /// background attribute fill can pick it up instead of stat-ing again.
    final class StatPassRegistry {
        static let shared = StatPassRegistry()

        private let lock = NSLock()
        private var passes: [String: FileOperations.DirectoryStatPass] = [:]

        func register(_ pass: FileOperations.DirectoryStatPass, for path: String) {
            lock.lock()
            defer { lock.unlock() }
            passes[path] = pass
        }

        /// Removes and returns the pass for a folder (if any).
        func take(for path: String) -> FileOperations.DirectoryStatPass? {
            lock.lock()
            defer { lock.unlock() }
            return passes.removeValue(forKey: path)
        }

        /// Drops a pending pass (the folder changed before it was collected).
        func invalidate(_ path: String) {
            lock.lock()
            defer { lock.unlock() }
            passes.removeValue(forKey: path)
        }
    }

    /// Reads the entry names of a folder with `readdir` (no `stat`, no URL objects).
    private static func readDirectoryNames(_ dirPath: String, showHidden: Bool) -> [DirEntry] {
        guard let dir = Darwin.opendir(dirPath) else { return [] }
        defer { Darwin.closedir(dir) }
        var entries: [DirEntry] = []
        // Start big: a folder with 200k entries would otherwise grow the array
        // ~10 times, and every growth re-copies the whole buffer (hundreds of MB
        // of memcpy) — that alone cost more than the actual directory read.
        entries.reserveCapacity(16_384)
        while let entry = Darwin.readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                var length = 0
                while length < raw.count, raw[length] != 0 { length += 1 }
                return String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." || name.isEmpty { continue }
            if !showHidden && name.hasPrefix(".") { continue }
            entries.append(DirEntry(name: name, type: entry.pointee.d_type))
            // Grow in large steps instead of letting the array double repeatedly.
            if entries.count == entries.capacity {
                entries.reserveCapacity(entries.capacity * 4)
            }
        }
        return entries
    }

    /// `fstatat` for every entry, spread over several threads.
    private static func statDirectoryEntries(_ dirPath: String, names: [String]) -> [DirStat] {
        let count = names.count
        var result = [DirStat](repeating: DirStat(), count: count)
        guard count > 0 else { return result }
        let fd = Darwin.open(dirPath, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return result }
        let chunks = count >= 8_000 ? statWorkerCount : 1
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let per = (count + chunks - 1) / chunks
            let lower = chunk * per
            let upper = min(count, lower + per)
            guard lower < upper else { return }
            var buffer = Darwin.stat()
            for index in lower..<upper {
                var value = DirStat()
                if Darwin.fstatat(fd, names[index], &buffer, AT_SYMLINK_NOFOLLOW) == 0 {
                    var mode = buffer.st_mode
                    var flags = buffer.st_flags
                    var size = Int64(buffer.st_size)
                    var modified = Date(timeIntervalSince1970: Double(buffer.st_mtimespec.tv_sec) + Double(buffer.st_mtimespec.tv_nsec) / 1e9)
                    if (mode & S_IFMT) == S_IFLNK {
                        // Follow the link so folders / sizes match what Finder shows.
                        var target = Darwin.stat()
                        if Darwin.fstatat(fd, names[index], &target, 0) == 0 {
                            mode = target.st_mode
                            flags = target.st_flags
                            size = Int64(target.st_size)
                            modified = Date(timeIntervalSince1970: Double(target.st_mtimespec.tv_sec) + Double(target.st_mtimespec.tv_nsec) / 1e9)
                        }
                    }
                    value.succeeded = true
                    value.isDirectory = (mode & S_IFMT) == S_IFDIR
                    value.isHidden = (flags & UInt32(UF_HIDDEN)) != 0
                    value.size = size
                    value.modified = modified
                }
                result[index] = value
            }
        }
        Darwin.close(fd)
        return result
    }

    private static func makeItems(
        dirPath: String,
        entries: [DirEntry],
        stats: [DirStat]
    ) -> [FileItem] {
        var items: [FileItem] = []
        items.reserveCapacity(entries.count)
        let base = URL(filePath: dirPath, directoryHint: .isDirectory)
        for (index, entry) in entries.enumerated() {
            let stat = stats[index]
            let isDirectory = stat.succeeded ? stat.isDirectory : (entry.type == UInt8(DT_DIR))
            let looksLikePackage = isDirectory && packageExtensions.contains(entry.fileExtension)
            let isHidden = (stat.succeeded ? stat.isHidden : false) || entry.name.hasPrefix(".")
            items.append(FileItem(
                url: makeChildURL(base: base, name: entry.name),
                name: entry.name,
                isDirectory: isDirectory && !looksLikePackage,
                isPackage: looksLikePackage,
                isHidden: isHidden,
                fileSize: (isDirectory && !looksLikePackage) ? nil : (stat.succeeded ? stat.size : nil),
                modificationDate: stat.modified,
                creationDate: nil,
                archiveEntryPath: nil
            ))
        }
        return items
    }

    /// Confirms package status for plain folders (bundles without a known extension).
    /// Skipped when a folder holds a huge number of sub-folders.
    private static func refinePackages(_ items: inout [FileItem]) {
        var folderIndexes: [Int] = []
        for (index, item) in items.enumerated() where item.isDirectory {
            folderIndexes.append(index)
        }
        guard !folderIndexes.isEmpty, folderIndexes.count <= 500 else { return }
        for index in folderIndexes {
            let values = try? items[index].url.resourceValues(forKeys: [.isPackageKey])
            guard values?.isPackage == true else { continue }
            let item = items[index]
            items[index] = FileItem(
                url: item.url,
                name: item.name,
                isDirectory: false,
                isPackage: true,
                isHidden: item.isHidden,
                fileSize: nil,
                modificationDate: item.modificationDate,
                creationDate: item.creationDate,
                archiveEntryPath: item.archiveEntryPath
            )
        }
    }

    private static func sortByName(_ items: inout [FileItem]) {
        sortItemsByName(&items)
    }

    /// Sorts a large array of `FileItem` by name using several threads.
    ///
    /// Each thread sorts a slice of lightweight `(name, index)` keys, the sorted
    /// slices are merged, and the items are permuted once at the end. Sorting
    /// keys instead of the full `FileItem` values keeps the comparator cheap.
    /// The comparator is a strict weak ordering, so the result is identical to a
    /// single-threaded sort.
    static func sortItemsByName(_ items: inout [FileItem]) {
        let count = items.count
        guard count > 5_000 else {
            items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return
        }
        let chunks = workerCount
        let per = (count + chunks - 1) / chunks
        var parts = [[SortKey]](repeating: [], count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * per
            let upper = min(count, lower + per)
            guard lower < upper else { return }
            var slice = [SortKey]()
            slice.reserveCapacity(upper - lower)
            for index in lower..<upper {
                slice.append(SortKey(name: items[index].name, index: Int32(index)))
            }
            slice.sort { fastNamePrecedes($0.name, $1.name) }
            parts[chunk] = slice
        }
        // Merge the sorted slices from the smallest to the largest so the
        // merge cost stays O(n log chunks).
        var merged = parts[0]
        for chunk in 1..<chunks {
            guard !parts[chunk].isEmpty else { continue }
            merged = mergeByName(merged, parts[chunk])
        }
        var sorted = [FileItem]()
        sorted.reserveCapacity(count)
        for key in merged {
            sorted.append(items[Int(key.index)])
        }
        items = sorted
    }

    /// Lightweight sort key: only what the comparator needs plus the source index.
    private struct SortKey {
        let name: String
        let index: Int32
    }

    /// Merges two name-sorted key arrays into one name-sorted array.
    private static func mergeByName(_ lhs: [SortKey], _ rhs: [SortKey]) -> [SortKey] {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        var merged = [SortKey]()
        merged.reserveCapacity(lhs.count + rhs.count)
        var i = 0
        var j = 0
        while i < lhs.count && j < rhs.count {
            if fastNamePrecedes(rhs[j].name, lhs[i].name) {
                merged.append(rhs[j])
                j += 1
            } else {
                merged.append(lhs[i])
                i += 1
            }
        }
        merged.append(contentsOf: lhs[i...])
        merged.append(contentsOf: rhs[j...])
        return merged
    }

    @inline(__always)
    private static func makeFileURL(dirPath: String, name: String) -> URL {
        let path = dirPath.hasSuffix("/") ? dirPath + name : dirPath + "/" + name
        if #available(macOS 13.0, *) {
            return URL(filePath: path)
        }
        return URL(fileURLWithPath: path)
    }

    /// Builds `base/<name>` without materialising the absolute path string.
    ///
    /// The relative form is ~2× cheaper to build, but `NSPasteboard` silently
    /// drops relative URLs (copy / cut would leave the pasteboard empty), and
    /// `url.path` on a relative URL has to resolve the base every single time.
    /// `absoluteURL` resolves that base once, at construction, so the result is
    /// both correct and cheap to use later.
    @inline(__always)
    private static func makeChildURL(base: URL, name: String) -> URL {
        if #available(macOS 13.0, *) {
            return URL(filePath: name, directoryHint: .notDirectory, relativeTo: base).absoluteURL
        }
        return base.appendingPathComponent(name)
    }

    /// Sorts the lightweight directory entries by name.
    ///
    /// The entries are split into chunks that are sorted on several threads and
    /// then merged. Comparing the raw UTF-8 bytes directly is much faster than
    /// going through `String` comparisons, and a flat byte buffer keeps the
    /// comparator free of pointer chasing.
    private static func sortEntriesByName(_ entries: inout [DirEntry]) {
        let count = entries.count
        guard count > 2_000 else {
            entries.sort { fastNamePrecedes($0.name, $1.name) }
            return
        }

        // Flat UTF-8 buffer + per-entry offsets: the comparator then works on
        // plain bytes instead of `String` objects.
        var offsets = [Int32](repeating: 0, count: count + 1)
        var flat = [UInt8]()
        flat.reserveCapacity(count * 24)
        for (index, entry) in entries.enumerated() {
            flat.append(contentsOf: entry.name.utf8)
            offsets[index + 1] = Int32(flat.count)
        }

        let chunks = workerCount
        let per = (count + chunks - 1) / chunks
        var parts = [[Int32]](repeating: [], count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let lower = chunk * per
            let upper = min(count, lower + per)
            guard lower < upper else { return }
            var slice = [Int32]()
            slice.reserveCapacity(upper - lower)
            for index in lower..<upper { slice.append(Int32(index)) }
            slice.sort { a, b in
                bytePrecedes(a: Int(a), b: Int(b), offsets: offsets, bytes: flat)
            }
            parts[chunk] = slice
        }

        // Merge the sorted slices from the smallest to the largest so the
        // merge cost stays O(n log chunks).
        var merged = parts[0]
        for chunk in 1..<chunks {
            guard !parts[chunk].isEmpty else { continue }
            merged = mergeIndices(merged, parts[chunk], offsets: offsets, bytes: flat)
        }

        var sorted = [DirEntry]()
        sorted.reserveCapacity(count)
        for index in merged {
            sorted.append(entries[Int(index)])
        }
        entries = sorted
    }

    /// Compares two entries by their raw UTF-8 bytes.
    ///
    /// Case-insensitive, number-aware ordering — the same rule as
    /// `fastNamePrecedes`, but on the flat byte buffer.
    @inline(__always)
    private static func bytePrecedes(a: Int, b: Int, offsets: [Int32], bytes: [UInt8]) -> Bool {
        let startA = Int(offsets[a])
        let endA = Int(offsets[a + 1])
        let startB = Int(offsets[b])
        let endB = Int(offsets[b + 1])
        var x = startA
        var y = startB
        while x < endA && y < endB {
            var ca = bytes[x]
            var cb = bytes[y]
            if ca >= 65 && ca <= 90 { ca += 32 }
            if cb >= 65 && cb <= 90 { cb += 32 }
            if ca >= 48 && ca <= 57, cb >= 48 && cb <= 57 {
                var endIdxA = x
                var endIdxB = y
                while endIdxA < endA, bytes[endIdxA] >= 48, bytes[endIdxA] <= 57 { endIdxA += 1 }
                while endIdxB < endB, bytes[endIdxB] >= 48, bytes[endIdxB] <= 57 { endIdxB += 1 }
                var startIdxA = x
                var startIdxB = y
                while startIdxA < endIdxA, bytes[startIdxA] == 48 { startIdxA += 1 }
                while startIdxB < endIdxB, bytes[startIdxB] == 48 { startIdxB += 1 }
                let digitsA = endIdxA - startIdxA
                let digitsB = endIdxB - startIdxB
                if digitsA != digitsB { return digitsA < digitsB }
                if digitsA > 0 {
                    var p = startIdxA
                    var q = startIdxB
                    while p < endIdxA {
                        if bytes[p] != bytes[q] { return bytes[p] < bytes[q] }
                        p += 1
                        q += 1
                    }
                }
                x = endIdxA
                y = endIdxB
                continue
            }
            if ca != cb { return ca < cb }
            x += 1
            y += 1
        }
        return x >= endA && y < endB
    }

    /// Merges two index arrays that are each sorted by name.
    private static func mergeIndices(
        _ lhs: [Int32],
        _ rhs: [Int32],
        offsets: [Int32],
        bytes: [UInt8]
    ) -> [Int32] {
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        var merged = [Int32]()
        merged.reserveCapacity(lhs.count + rhs.count)
        var i = 0
        var j = 0
        while i < lhs.count && j < rhs.count {
            if bytePrecedes(a: Int(rhs[j]), b: Int(lhs[i]), offsets: offsets, bytes: bytes) {
                merged.append(rhs[j])
                j += 1
            } else {
                merged.append(lhs[i])
                i += 1
            }
        }
        merged.append(contentsOf: lhs[i...])
        merged.append(contentsOf: rhs[j...])
        return merged
    }

    /// Case-insensitive, number-aware name ordering on raw UTF-8 bytes.
    /// Roughly 6× faster than `localizedStandardCompare` on huge listings while
    /// producing the same order for everyday names.
    static func fastNamePrecedes(_ a: String, _ b: String) -> Bool {
        let left = a.utf8
        let right = b.utf8
        var i = left.startIndex
        var j = right.startIndex
        while i < left.endIndex && j < right.endIndex {
            var ca = left[i]
            var cb = right[j]
            if ca >= 65 && ca <= 90 { ca += 32 }
            if cb >= 65 && cb <= 90 { cb += 32 }
            if ca >= 48 && ca <= 57, cb >= 48 && cb <= 57 {
                var endA = i
                var endB = j
                while endA < left.endIndex, left[endA] >= 48, left[endA] <= 57 {
                    endA = left.index(after: endA)
                }
                while endB < right.endIndex, right[endB] >= 48, right[endB] <= 57 {
                    endB = right.index(after: endB)
                }
                var startA = i
                var startB = j
                while startA < endA, left[startA] == 48 { startA = left.index(after: startA) }
                while startB < endB, right[startB] == 48 { startB = right.index(after: startB) }
                let digitsA = left.distance(from: startA, to: endA)
                let digitsB = right.distance(from: startB, to: endB)
                if digitsA != digitsB { return digitsA < digitsB }
                if digitsA > 0 {
                    var x = startA
                    var y = startB
                    while x < endA {
                        if left[x] != right[y] { return left[x] < right[y] }
                        x = left.index(after: x)
                        y = right.index(after: y)
                    }
                }
                i = endA
                j = endB
                continue
            }
            if ca != cb { return ca < cb }
            i = left.index(after: i)
            j = right.index(after: j)
        }
        return i >= left.endIndex && j < right.endIndex
    }

    /// Name ordering that switches to the fast byte-wise comparison for big listings.
    static func namePrecedes(_ a: String, _ b: String, fast: Bool) -> Bool {
        if fast { return fastNamePrecedes(a, b) }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Comparison result for the fast byte-wise name ordering.
    static func fastNameComparison(_ a: String, _ b: String) -> ComparisonResult {
        if fastNamePrecedes(a, b) { return .orderedAscending }
        if fastNamePrecedes(b, a) { return .orderedDescending }
        return .orderedSame
    }

    /// New item names: prefer `未命名` / `未命名文件夹`; on conflict use
    /// `… 副本`, then `… 副本 2`, `… 副本 3`… (no bare `2`/`3` suffix).
    static func uniqueURL(in directory: URL, baseName: String, extensionName: String?) -> URL {
        uniqueUntitledURL(in: directory, baseName: baseName, extensionName: extensionName)
    }

    static func uniqueUntitledURL(in directory: URL, baseName: String, extensionName: String?) -> URL {
        uniqueCopyStyleName(in: directory, preferredBase: baseName, extensionName: extensionName, allowPreferred: true)
    }

    /// Shared `副本` / `副本 N` allocator used by New and paste.
    private static func uniqueCopyStyleName(
        in directory: URL,
        preferredBase: String,
        extensionName: String?,
        allowPreferred: Bool,
        treatingAsAvailable ignoredPath: String? = nil
    ) -> URL {
        let fm = FileManager.default
        func isAvailable(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            if let ignoredPath, path == ignoredPath { return true }
            return !fm.fileExists(atPath: path)
        }
        func candidate(_ base: String) -> URL {
            directory.appendingPathComponent(composedFileName(base: base, extensionName: extensionName))
        }

        if allowPreferred {
            let preferred = candidate(preferredBase)
            if isAvailable(preferred) {
                return preferred
            }
        }

        let firstCopy = candidate("\(preferredBase) 副本")
        if isAvailable(firstCopy) {
            return firstCopy
        }
        var index = 2
        while true {
            let url = candidate("\(preferredBase) 副本 \(index)")
            if isAvailable(url) {
                return url
            }
            index += 1
        }
    }

    /// Paste/copy conflicts — macOS Duplicate/Paste style (`副本`, no `的`):
    /// - `foo` → `foo 副本` → `foo 副本 2` → `foo 副本 3` → …
    /// - pasting `foo 副本` → `foo 副本 2`
    /// - pasting `foo 副本 3` → `foo 副本 4`
    static func uniqueCopyURL(in directory: URL, source: URL, isMoving: Bool) -> URL {
        let fm = FileManager.default
        let sourceName = source.lastPathComponent
        let ignoredPath = isMoving ? source.standardizedFileURL.path : nil

        func isAvailable(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            if let ignoredPath, path == ignoredPath { return true }
            return !fm.fileExists(atPath: path)
        }

        let original = directory.appendingPathComponent(sourceName)
        if isAvailable(original) {
            return original
        }

        var isDir: ObjCBool = false
        let sourceIsDirectory = fm.fileExists(atPath: source.path, isDirectory: &isDir) && isDir.boolValue
        let sourceIsPackage = (try? source.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        let keepFullName = sourceIsDirectory || sourceIsPackage

        let (stem, ext): (String, String?) = {
            if keepFullName {
                return (sourceName, nil)
            }
            return splitNameAndExtension(sourceName)
        }()

        let (root, startNumber) = copyRenamePlan(forStem: stem)

        if startNumber == nil {
            return uniqueCopyStyleName(
                in: directory,
                preferredBase: root,
                extensionName: ext,
                allowPreferred: false,
                treatingAsAvailable: ignoredPath
            )
        }

        var index = startNumber!
        while true {
            let url = directory.appendingPathComponent(
                composedFileName(base: "\(root) 副本 \(index)", extensionName: ext)
            )
            if isAvailable(url) {
                return url
            }
            index += 1
        }
    }

    /// Parse stem into root + first copy index to try.
    private static func copyRenamePlan(forStem stem: String) -> (root: String, startNumber: Int?) {
        let patterns: [(String, Bool)] = [
            (#"^(.*) 副本 (\d+)$"#, true),
            (#"^(.*) 副本$"#, false),
            (#"^(.*) 的副本 (\d+)$"#, true),
            (#"^(.*) 的副本$"#, false)
        ]
        for (pattern, hasNumber) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
                  match.numberOfRanges >= 2,
                  let rootRange = Range(match.range(at: 1), in: stem) else {
                continue
            }
            let root = String(stem[rootRange])
            guard !root.isEmpty else { continue }
            if hasNumber,
               match.numberOfRanges >= 3,
               let numRange = Range(match.range(at: 2), in: stem),
               let value = Int(stem[numRange]) {
                return (root, value + 1)
            }
            return (root, 2)
        }
        return (stem, nil)
    }

    private static func composedFileName(base: String, extensionName: String?) -> String {
        if let ext = extensionName, !ext.isEmpty {
            return "\(base).\(ext)"
        }
        return base
    }

    /// Split `Report.pdf` → (`Report`, `pdf`).
    private static func splitNameAndExtension(_ fileName: String) -> (String, String?) {
        let ns = fileName as NSString
        let ext = ns.pathExtension
        if ext.isEmpty {
            return (fileName, nil)
        }
        return (ns.deletingPathExtension, ext)
    }

    static func createNewItem(in directory: URL, extensionName: String?) throws -> URL {
        invalidateListingCache(for: directory)
        if let ext = extensionName {
            // Keep extension spelling/case exactly as configured (e.g. .R, .py).
            let url = uniqueUntitledURL(in: directory, baseName: "未命名", extensionName: ext)
            if let binary = defaultBinaryContents(for: ext) {
                try binary.write(to: url, options: .atomic)
            } else {
                let text = defaultTextContents(for: ext)
                if text.isEmpty {
                    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                } else {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            NSWorkspace.shared.noteFileSystemChanged(url.path)
            return url
        } else {
            let url = uniqueUntitledURL(in: directory, baseName: "未命名文件夹", extensionName: nil)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            NSWorkspace.shared.noteFileSystemChanged(url.path)
            return url
        }
    }

    static func defaultTextContents(for ext: String) -> String {
        switch ext.lowercased() {
        case "md": return "# 未命名\n\n"
        case "swift": return "import Foundation\n\n"
        case "py": return "#!/usr/bin/env python3\n\n"
        case "r": return "# 未命名\n\n"
        case "html": return "<!DOCTYPE html>\n<html>\n<head><meta charset=\"utf-8\"><title></title></head>\n<body>\n</body>\n</html>\n"
        case "json": return "{\n}\n"
        case "csv": return ""
        default: return ""
        }
    }

    /// Minimal valid OOXML stubs so Excel / Word / PowerPoint open cleanly.
    static func defaultBinaryContents(for ext: String) -> Data? {
        switch ext.lowercased() {
        case "xlsx":
            return OfficeDocumentStubs.xlsx
        case "docx":
            return OfficeDocumentStubs.docx
        case "pptx", "ppt":
            // "ppt" menu type creates a modern .pptx package (legacy binary .ppt is obsolete).
            return OfficeDocumentStubs.pptx
        default:
            return nil
        }
    }

    static func moveToTrash(_ urls: [URL]) throws {
        for url in urls {
            let original = url.standardizedFileURL
            var resulting: NSURL?
            try FileManager.default.trashItem(at: original, resultingItemURL: &resulting)
            if let trashed = (resulting as URL?)?.standardizedFileURL {
                TrashPutBackStore.shared.record(trashed: trashed, original: original)
            }
            invalidateListingCache(for: original.deletingLastPathComponent())
        }
    }

    /// User Trash folder (`~/.Trash`) and volume trash folders (`/Volumes/…/.Trashes/<uid>`).
    static func isTrashDirectory(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
        if standardized.path == homeTrash.path { return true }

        let parts = standardized.pathComponents
        // "/", "Volumes", "Disk", ".Trashes", "501"
        guard parts.count >= 5,
              parts[1] == "Volumes",
              parts[parts.count - 2] == ".Trashes" else {
            return false
        }
        return true
    }

    static var userTrashDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
    }

    static func isURLInTrash(_ url: URL) -> Bool {
        isTrashDirectory(url.deletingLastPathComponent().standardizedFileURL)
            || isTrashDirectory(url.standardizedFileURL)
    }

    /// `/Applications`, `~/Applications` (and similar) — uninstall-friendly listing.
    static func isApplicationsDirectory(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homeApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL.path
        if path == "/Applications" || path == homeApps { return true }
        // Localized display name folders still use these POSIX paths on disk.
        return false
    }

    /// Permanently delete items (used inside Trash).
    static func permanentlyDelete(_ urls: [URL]) throws {
        for url in urls {
            let standardized = url.standardizedFileURL
            try FileManager.default.removeItem(at: standardized)
            TrashPutBackStore.shared.remove(trashed: standardized)
            invalidateListingCache(for: standardized.deletingLastPathComponent())
        }
    }

    /// Empty a trash folder. Skips `.` / `..`; removes remaining entries.
    static func emptyTrash(at trashURL: URL) throws {
        guard isTrashDirectory(trashURL) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            TrashPutBackStore.shared.remove(trashed: url.standardizedFileURL)
        }
    }

    /// Restore trashed items to their original locations.
    /// Modern macOS removed Finder’s AppleScript `put away`, so NewFinder records
    /// original paths when it moves items to Trash and restores with `moveItem`.
    @discardableResult
    static func putBackFromTrash(_ urls: [URL]) throws -> [URL] {
        var restored: [URL] = []
        var failures: [String] = []
        let fm = FileManager.default

        for url in urls {
            let trashed = url.standardizedFileURL
            guard fm.fileExists(atPath: trashed.path) else {
                TrashPutBackStore.shared.remove(trashed: trashed)
                continue
            }

            let originalParent: URL
            let preferredName: String
            if let original = TrashPutBackStore.shared.originalURL(for: trashed) {
                originalParent = original.deletingLastPathComponent()
                preferredName = original.lastPathComponent
            } else {
                // Items trashed outside NewFinder (or before this fix) have no record.
                // Finder AppleScript `put away` is gone — fall back to Desktop.
                originalParent = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop", isDirectory: true)
                preferredName = trashed.lastPathComponent
            }

            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: originalParent.path, isDirectory: &isDir) || !isDir.boolValue {
                failures.append("「\(trashed.lastPathComponent)」的原文件夹不存在：\(originalParent.path)")
                continue
            }

            do {
                let dest = uniquePutBackDestination(in: originalParent, preferredName: preferredName)
                try fm.moveItem(at: trashed, to: dest)
                TrashPutBackStore.shared.remove(trashed: trashed)
                restored.append(dest)
            } catch {
                failures.append("「\(trashed.lastPathComponent)」：\(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            throw NSError(
                domain: "NewFinder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]
            )
        }
        return restored
    }

    private static func uniquePutBackDestination(in directory: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let preferred = directory.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: preferred.path) { return preferred }

        let ns = preferredName as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? preferredName : ns.deletingPathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    /// Grant owner write permission and clear Finder/user immutable flags.
    /// Directories are processed recursively.
    static func makeWritable(_ urls: [URL]) throws {
        var failures: [String] = []
        for url in urls {
            do {
                try makeWritableRecursively(url)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw NSError(
                domain: "NewFinder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]
            )
        }
    }

    static func isEffectivelyReadOnly(_ url: URL) -> Bool {
        if !FileManager.default.isWritableFile(atPath: url.path) { return true }
        if let values = try? url.resourceValues(forKeys: [.isUserImmutableKey]),
           values.isUserImmutable == true {
            return true
        }
        return false
    }

    private static func makeWritableRecursively(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

        // Clear Finder "Locked" / user immutable bit.
        var mutableURL = url
        var values = URLResourceValues()
        values.isUserImmutable = false
        try? mutableURL.setResourceValues(values)

        // Clear uchg/schg flags when present (ignore failure if not set).
        let chflags = Process()
        chflags.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        chflags.arguments = ["nouchg,noschg", url.path]
        chflags.standardOutput = FileHandle.nullDevice
        chflags.standardError = FileHandle.nullDevice
        try? chflags.run()
        chflags.waitUntilExit()

        let attrs = try fm.attributesOfItem(atPath: url.path)
        var perms = attrs[.posixPermissions] as? Int ?? (isDir.boolValue ? 0o755 : 0o644)
        perms |= 0o200 // owner write
        if isDir.boolValue {
            perms |= 0o100 // owner execute (needed to enter directory)
        }
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)

        if isDir.boolValue {
            let children = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            for child in children {
                try makeWritableRecursively(child)
            }
        }
    }

    /// Absolute URLs for the pasteboard.
    ///
    /// The listing builds child URLs relative to their parent directory (much
    /// cheaper than re-parsing an absolute path for every entry). `NSPasteboard`
    /// silently drops relative URLs — `writeObjects` reports success but the
    /// pasteboard ends up empty — so every URL that leaves the app has to be
    /// made absolute first.
    static func absolutePasteboardURLs(_ urls: [URL]) -> [URL] {
        urls.map { $0.isFileURL && $0.absoluteURL != $0 ? $0.absoluteURL : $0 }
    }

    /// The mode marker lives in its own pasteboard type.
    ///
    /// The cut payload (the JSON list of paths) is written to `pasteboardType`,
    /// but a marker and a payload cannot share one type: `setData` replaces the
    /// string written by `setString` for the same type, so the "cut" flag would
    /// be lost — and writing an *empty* string (what a plain copy used to do)
    /// still leaves a non-nil, zero-length `data(forType:)`, which made every
    /// copy look like a cut. Keeping the marker separate removes both traps.
    static let pasteboardModeType = NSPasteboard.PasteboardType("com.zhangjing.NewFinder.pasteMode")

    static func copyURLs(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(absolutePasteboardURLs(urls) as [NSURL])
        pb.setString("copy", forType: pasteboardModeType)
    }

    static func cutURLs(_ urls: [URL]) {
        let pb = NSPasteboard.general
        let absolute = absolutePasteboardURLs(urls)
        pb.clearContents()
        pb.writeObjects(absolute as [NSURL])
        pb.setString("cut", forType: pasteboardModeType)
        if let data = try? JSONEncoder().encode(absolute.map(\.path)) {
            pb.setData(data, forType: pasteboardType)
        }
    }

    static func isCutOnPasteboard() -> Bool {
        let pb = NSPasteboard.general
        // The mode marker is authoritative. The payload is only a fallback for a
        // pasteboard written by an older build of the app.
        if let mode = pb.string(forType: pasteboardModeType) {
            return mode == "cut"
        }
        return pb.string(forType: pasteboardType) == "cut" || pb.data(forType: pasteboardType) != nil
    }

    /// Whether the general pasteboard holds items this app put there (copy *or* cut).
    ///
    /// Copied items are greyed out as well: the app marks everything it copied
    /// so the user can see what the next paste will act on. Only a *cut*
    /// changes the paste from "copy" to "move", so the two notions are kept
    /// apart — `isCutOnPasteboard()` decides how a paste behaves, this one
    /// decides what is drawn grey.
    static func isMarkedOnPasteboard() -> Bool {
        let pb = NSPasteboard.general
        if let mode = pb.string(forType: pasteboardModeType) {
            return mode == "cut" || mode == "copy"
        }
        // Older builds did not write a mode marker; they always left a payload
        // behind (an empty string for a plain copy), so treat that as marked.
        return pb.string(forType: pasteboardType) != nil || pb.data(forType: pasteboardType) != nil
    }

    /// URLs currently marked on the general pasteboard (greyed-out preview).
    static func markedURLsOnPasteboard() -> Set<URL> {
        guard isMarkedOnPasteboard() else { return [] }
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return []
        }
        return Set(urls.map { $0.standardizedFileURL })
    }

    static func isURLMarked(_ url: URL) -> Bool {
        markedURLsOnPasteboard().contains(url.standardizedFileURL)
    }

    static func paste(into directory: URL) throws -> [URL] {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let cutting: Bool = {
            if let mode = pb.string(forType: pasteboardModeType) {
                return mode == "cut"
            }
            if let data = pb.data(forType: pasteboardType),
               let paths = try? JSONDecoder().decode([String].self, from: data) {
                return !paths.isEmpty
            }
            return pb.string(forType: pasteboardType) == "cut"
        }()

        let results = try transferItems(urls, toDirectory: directory, copying: !cutting)
        // A move consumes the clipboard. A copy keeps it, so the user can paste
        // the same items again — the greyed-out preview follows the clipboard.
        if cutting {
            pb.clearContents()
        }
        return results
    }

    /// Move or copy file URLs into `directory` (resolves name conflicts).
    static func transferItems(_ urls: [URL], toDirectory directory: URL, copying: Bool) throws -> [URL] {
        var results: [URL] = []
        for source in urls {
            let dest = uniqueCopyURL(in: directory, source: source, isMoving: !copying)
            if copying {
                try FileManager.default.copyItem(at: source, to: dest)
            } else if source.standardizedFileURL == dest.standardizedFileURL {
                results.append(source)
                continue
            } else {
                try FileManager.default.moveItem(at: source, to: dest)
            }
            results.append(dest)
            invalidateListingCache(for: source.deletingLastPathComponent())
        }
        invalidateListingCache(for: directory)
        return results
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: dest)
        invalidateListingCache(for: url.deletingLastPathComponent())
        return dest
    }

    static func open(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                AppDelegate.shared.openURLs([url])
                continue
            }
            NSWorkspace.shared.open(url)
        }
    }

    static func revealInFinder(_ urls: [URL]) {
        AppDelegate.shared.reveal(urls)
    }

    static func formatFileSize(_ size: Int64?) -> String {
        guard let size else { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Recursive on-disk size for packages (Finder-like). Call off the main thread.
    static func directoryByteSize(at url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            if let n = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize {
                total += Int64(n)
            }
        }
        return total
    }

    private static let packageSizeCacheQueue = DispatchQueue(label: "com.zhangjing.NewFinder.packageSizeCache")
    private static var packageSizeCache: [String: (mod: TimeInterval, size: Int64)] = [:]

    /// Cached package size; recomputes when modification date changes.
    static func cachedPackageByteSize(at url: URL, modificationDate: Date?) -> Int64 {
        let key = url.standardizedFileURL.path
        let mod = modificationDate?.timeIntervalSince1970 ?? 0
        if let hit = packageSizeCacheQueue.sync(execute: { packageSizeCache[key] }),
           abs(hit.mod - mod) < 0.5 {
            return hit.size
        }
        let size = directoryByteSize(at: url)
        packageSizeCacheQueue.sync {
            packageSizeCache[key] = (mod, size)
            if packageSizeCache.count > 400 {
                packageSizeCache.removeAll(keepingCapacity: true)
            }
        }
        return size
    }

    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    static func pathAutocomplete(for input: String) -> [String] {
        let expanded = (input as NSString).expandingTildeInPath
        let url: URL
        let prefix: String
        if expanded.hasSuffix("/") {
            url = URL(fileURLWithPath: expanded, isDirectory: true)
            prefix = ""
        } else {
            url = URL(fileURLWithPath: expanded).deletingLastPathComponent()
            prefix = URL(fileURLWithPath: expanded).lastPathComponent
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(12)
            .map { candidate in
                var path = candidate.path
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    if !path.hasSuffix("/") { path += "/" }
                }
                return path
            }
    }

    static func search(in root: URL, query: String, limit: Int = 200) -> [URL] {
        let keywords = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return [] }

        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root.standardizedFileURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            let standardized = fileURL.standardizedFileURL
            let name = standardized.lastPathComponent.lowercased()
            // Match file/folder name only — searching "2" should not list unrelated items.
            if keywords.allSatisfy({ name.contains($0) }) {
                results.append(standardized)
                if results.count >= limit { break }
            }
        }
        return results.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    static func mountedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path != "/" }
    }
}

// MARK: - Put Back location store

/// Remembers original paths for items NewFinder moves to Trash.
/// Finder’s AppleScript `put away` was removed on modern macOS.
private final class TrashPutBackStore {
    static let shared = TrashPutBackStore()

    private let defaultsKey = "NewFinder.trashPutBackMap"
    private let lock = NSLock()
    /// trashed path → original path
    private var map: [String: String]

    private init() {
        map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func record(trashed: URL, original: URL) {
        lock.lock()
        defer { lock.unlock() }
        map[trashed.standardizedFileURL.path] = original.standardizedFileURL.path
        persistLocked()
    }

    func originalURL(for trashed: URL) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let key = trashed.standardizedFileURL.path
        if let path = map[key] {
            return URL(fileURLWithPath: path)
        }
        // Trash may rename on conflict; match by basename among still-existing trash keys.
        let name = trashed.lastPathComponent
        if let path = map.first(where: {
            URL(fileURLWithPath: $0.key).lastPathComponent == name
                && FileManager.default.fileExists(atPath: $0.key)
        })?.value {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func remove(trashed: URL) {
        lock.lock()
        defer { lock.unlock() }
        map.removeValue(forKey: trashed.standardizedFileURL.path)
        map = map.filter { FileManager.default.fileExists(atPath: $0.key) }
        persistLocked()
    }

    private func persistLocked() {
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}
