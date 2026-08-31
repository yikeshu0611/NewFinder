import Foundation
import AppKit

struct FileItem: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    let creationDate: Date?

    var displayName: String { name }

    /// Keys prefetched by `FileOperations.listDirectory` (kept lean for large folders).
    static let listingKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    /// Build from URL that already had `listingKeys` prefetched (no extra existence check).
    static func fromListedURL(_ url: URL) -> FileItem? {
        let values = try? url.resourceValues(forKeys: Set(listingKeys))
        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden == true || name.hasPrefix("."),
            fileSize: (isDirectory && !isPackage) ? nil : Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            creationDate: nil
        )
    }

    static func from(url: URL) -> FileItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .localizedNameKey
        ])

        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        return FileItem(
            url: url,
            name: values?.localizedName ?? url.lastPathComponent,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix("."),
            fileSize: isDirectory ? nil : Int64(values?.fileSize ?? 0),
            modificationDate: values?.contentModificationDate,
            creationDate: values?.creationDate
        )
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var folder: String

    init(id: UUID = UUID(), name: String, path: String, folder: String = "收藏") {
        self.id = id
        self.name = name
        self.path = path
        self.folder = folder
    }
}

final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let showHidden = "showHidden"
        static let newItemTypes = "newItemTypes"
        static let bookmarks = "bookmarks"
        static let bookmarkFolderOrder = "bookmarkFolderOrder"
        static let languageChinese = "languageChinese"
        static let redirectFinder = "redirectFinderClicks"
        static let launchAtLogin = "launchAtLogin"
    }

    var showHiddenFiles: Bool {
        get { defaults.bool(forKey: Keys.showHidden) }
        set { defaults.set(newValue, forKey: Keys.showHidden) }
    }

    /// When Dock Finder is clicked / Finder windows open, switch to NewFinder.
    var redirectFinderClicks: Bool {
        get {
            if defaults.object(forKey: Keys.redirectFinder) == nil { return true }
            return defaults.bool(forKey: Keys.redirectFinder)
        }
        set { defaults.set(newValue, forKey: Keys.redirectFinder) }
    }

    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: Keys.launchAtLogin) == nil { return true }
            return defaults.bool(forKey: Keys.launchAtLogin)
        }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    /// Always pinned at the top of the New menu; not shown in Settings.
    static let fixedNewItemTypes = ["dir", "txt", "docx", "pptx", "xlsx"]

    /// Default extras (stored alphabetically as `py`, `R`).
    static let defaultCustomNewItemTypes = ["R", "py"]

    /// Custom types only (editable in Settings), A–Z, case preserved.
    var customNewItemTypes: [String] {
        get {
            if defaults.object(forKey: Keys.newItemTypes) == nil {
                let seeded = normalizedCustomTypes(Self.defaultCustomNewItemTypes)
                defaults.set(seeded, forKey: Keys.newItemTypes)
                return seeded
            }
            let raw = defaults.stringArray(forKey: Keys.newItemTypes) ?? []
            let custom = normalizedCustomTypes(raw)
            // One-time cleanup: drop fixed types that used to live in this key.
            if raw.contains(where: { Self.isFixedNewItemType($0) }) {
                defaults.set(custom, forKey: Keys.newItemTypes)
            }
            return custom
        }
        set { defaults.set(normalizedCustomTypes(newValue), forKey: Keys.newItemTypes) }
    }

    /// Full New-menu list: fixed types first, then custom types A–Z.
    var newItemTypes: [String] {
        Self.fixedNewItemTypes + customNewItemTypes
    }

    static func isFixedNewItemType(_ type: String) -> Bool {
        let key = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "ppt" { return true } // treat legacy ppt as the fixed pptx slot
        return fixedNewItemTypes.map { $0.lowercased() }.contains(key)
    }

    private func normalizedCustomTypes(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !Self.isFixedNewItemType(trimmed) else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
            if result.count >= 40 { break }
        }
        result.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return result
    }

    var bookmarks: [Bookmark] {
        get {
            guard let data = defaults.data(forKey: Keys.bookmarks),
                  let items = try? JSONDecoder().decode([Bookmark].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.bookmarks)
            }
        }
    }

    var bookmarkFolderOrder: [String] {
        get { defaults.stringArray(forKey: Keys.bookmarkFolderOrder) ?? [] }
        set { defaults.set(newValue, forKey: Keys.bookmarkFolderOrder) }
    }

    var preferChinese: Bool {
        get {
            if defaults.object(forKey: Keys.languageChinese) == nil { return true }
            return defaults.bool(forKey: Keys.languageChinese)
        }
        set { defaults.set(newValue, forKey: Keys.languageChinese) }
    }
}

struct VisitRecord: Equatable {
    var url: URL
    var visitedAt: Date
}

final class NavigationHistory {
    private(set) var stack: [URL] = []
    private(set) var index: Int = -1
    /// Most-recent-first visit list for the path-bar dropdown.
    private(set) var recentVisits: [VisitRecord] = []
    private let maxRecent = 40

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < stack.count - 1 }
    var current: URL? { (index >= 0 && index < stack.count) ? stack[index] : nil }

    func navigate(to url: URL) {
        let standardized = url.standardizedFileURL
        if let current, current == standardized {
            recordRecent(standardized)
            return
        }
        if index >= 0 && index < stack.count - 1 {
            stack = Array(stack.prefix(index + 1))
        }
        stack.append(standardized)
        index = stack.count - 1
        recordRecent(standardized)
    }

    func goBack() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        recordRecent(stack[index])
        return stack[index]
    }

    func goForward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        recordRecent(stack[index])
        return stack[index]
    }

    func jump(to index: Int) -> URL? {
        guard index >= 0, index < stack.count else { return nil }
        self.index = index
        recordRecent(stack[index])
        return stack[index]
    }

    private func recordRecent(_ url: URL) {
        let standardized = url.standardizedFileURL
        recentVisits.removeAll { $0.url.standardizedFileURL == standardized }
        recentVisits.insert(VisitRecord(url: standardized, visitedAt: Date()), at: 0)
        if recentVisits.count > maxRecent {
            recentVisits = Array(recentVisits.prefix(maxRecent))
        }
    }
}
