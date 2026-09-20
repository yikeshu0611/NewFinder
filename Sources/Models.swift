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
    /// Non-nil when this row is inside an opened archive tab.
    let archiveEntryPath: String?

    var displayName: String { name }
    var isArchiveEntry: Bool { archiveEntryPath != nil }

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
        let size: Int64?
        if isDirectory && !isPackage {
            size = nil
        } else if isPackage {
            // Package totals are filled asynchronously after listing (keeps /Applications fast).
            size = nil
        } else {
            size = Int64(values?.fileSize ?? 0)
        }
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden == true || name.hasPrefix("."),
            fileSize: size,
            modificationDate: values?.contentModificationDate,
            creationDate: nil,
            archiveEntryPath: nil
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
        let size: Int64?
        if isDirectory && !isPackage {
            size = nil
        } else if isPackage {
            size = nil
        } else {
            size = Int64(values?.fileSize ?? 0)
        }
        return FileItem(
            url: url,
            name: values?.localizedName ?? url.lastPathComponent,
            isDirectory: isDirectory && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden == true || url.lastPathComponent.hasPrefix("."),
            fileSize: size,
            modificationDate: values?.contentModificationDate,
            creationDate: values?.creationDate,
            archiveEntryPath: nil
        )
    }

    func withFileSize(_ size: Int64?) -> FileItem {
        FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: isHidden,
            fileSize: size,
            modificationDate: modificationDate,
            creationDate: creationDate,
            archiveEntryPath: archiveEntryPath
        )
    }

    static func archiveEntry(
        archive: URL,
        entryPath: String,
        name: String,
        isDirectory: Bool,
        size: Int64?
    ) -> FileItem {
        // Synthetic URL for selection identity only.
        var components = URLComponents()
        components.scheme = "nf-archive"
        components.host = archive.path.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        components.path = "/" + entryPath
        let url = components.url ?? archive.appendingPathComponent(entryPath)
        return FileItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: false,
            isHidden: name.hasPrefix("."),
            fileSize: isDirectory ? nil : size,
            modificationDate: nil,
            creationDate: nil,
            archiveEntryPath: entryPath
        )
    }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var folder: String
    /// Left sidebar and top bar keep completely separate bookmark sets.
    var placement: FavoritesPlacement

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        folder: String = "收藏",
        placement: FavoritesPlacement = .left
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.folder = folder
        self.placement = placement
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, folder, placement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        folder = try container.decodeIfPresent(String.self, forKey: .folder) ?? "收藏"
        // Migrate legacy "both" → left; top copies are not auto-created.
        let raw = try container.decodeIfPresent(String.self, forKey: .placement) ?? FavoritesPlacement.left.rawValue
        if raw == "both" {
            placement = .left
        } else {
            placement = FavoritesPlacement(rawValue: raw) ?? .left
        }
    }
}

enum FavoritesPlacement: String, Codable {
    case left
    case top
}

final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let showHidden = "showHidden"
        static let newItemTypes = "newItemTypes"
        static let enabledFixedNewItemTypes = "enabledFixedNewItemTypes"
        static let toolbarNewItemTypes = "toolbarNewItemTypes"
        static let bookmarks = "bookmarks"
        static let bookmarkFolderOrder = "bookmarkFolderOrder"
        static let topBookmarkFolderOrder = "topBookmarkFolderOrder"
        static let favoritesSidebarWidth = "favoritesSidebarWidth"
        static let favoritesSidebarVisible = "favoritesSidebarVisible"
        static let favoritesTopBarVisible = "favoritesTopBarVisible"
        static let languageChinese = "languageChinese"
        static let redirectFinder = "redirectFinderClicks"
        static let launchAtLogin = "launchAtLogin"
        static let disableCommandMMinimize = "disableCommandMMinimize"
        static let disableCommandHHide = "disableCommandHHide"
        static let openWithDefaultHistory = "openWithDefaultHistory"
        static let openWithAppHistory = "openWithAppHistory"
        static let openWithAppHistoryByType = "openWithAppHistoryByType"
        static let uiZoomPercent = "uiZoomPercent"
        static let recentOpenHistory = "recentOpenHistory"
    }

    /// Content zoom 30%…500%. Default 100. Adjusted via menu-bar slider.
    var uiZoomPercent: Int {
        get {
            let value = defaults.object(forKey: Keys.uiZoomPercent) as? Int ?? 100
            return min(500, max(30, value))
        }
        set { defaults.set(min(500, max(30, newValue)), forKey: Keys.uiZoomPercent) }
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

    /// Swallow ⌘M so windows are not miniaturized.
    var disableCommandMMinimize: Bool {
        get { defaults.bool(forKey: Keys.disableCommandMMinimize) }
        set { defaults.set(newValue, forKey: Keys.disableCommandMMinimize) }
    }

    /// Swallow ⌘H so the app is not hidden.
    var disableCommandHHide: Bool {
        get { defaults.bool(forKey: Keys.disableCommandHHide) }
        set { defaults.set(newValue, forKey: Keys.disableCommandHHide) }
    }

    /// Built-in New types (canonical keys). Display name for `dir` is「文件夹」.
    static let fixedNewItemTypes = ["dir", "txt", "docx", "pptx", "xlsx"]

    /// Default extras (stored alphabetically as `py`, `R`).
    static let defaultCustomNewItemTypes = ["R", "py"]

    static func displayName(forNewItemType type: String) -> String {
        let key = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "dir" { return "文件夹" }
        return type.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map user input / aliases to a fixed canonical type, if any.
    static func canonicalFixedType(_ type: String) -> String? {
        let key = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        if key == "dir" || key == "folder" || key == "文件夹" { return "dir" }
        if key == "ppt" { return "pptx" }
        return fixedNewItemTypes.first { $0.lowercased() == key }
    }

    /// Fixed types currently shown in New / Settings (default: all), in fixed order.
    var enabledFixedNewItemTypes: [String] {
        get {
            if defaults.object(forKey: Keys.enabledFixedNewItemTypes) == nil {
                return Self.fixedNewItemTypes
            }
            let raw = defaults.stringArray(forKey: Keys.enabledFixedNewItemTypes) ?? []
            let enabled = Set(raw.map { $0.lowercased() })
            return Self.fixedNewItemTypes.filter { enabled.contains($0.lowercased()) }
        }
        set {
            let enabled = Set(newValue.map { $0.lowercased() })
            let ordered = Self.fixedNewItemTypes.filter { enabled.contains($0.lowercased()) }
            defaults.set(ordered, forKey: Keys.enabledFixedNewItemTypes)
            pruneToolbarNewItemTypes(allowed: ordered + customNewItemTypes)
        }
    }

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
        set {
            let normalized = normalizedCustomTypes(newValue)
            defaults.set(normalized, forKey: Keys.newItemTypes)
            pruneToolbarNewItemTypes(allowed: enabledFixedNewItemTypes + normalized)
        }
    }

    /// Lowercased type keys that also appear as toolbar buttons (right of New).
    var toolbarNewItemTypeKeys: Set<String> {
        get {
            Set((defaults.stringArray(forKey: Keys.toolbarNewItemTypes) ?? []).map { $0.lowercased() })
        }
        set {
            pruneToolbarNewItemTypes(
                allowed: enabledFixedNewItemTypes + customNewItemTypes,
                preferred: newValue
            )
        }
    }

    /// Types marked「单独展示」, New-menu order (fixed first, then custom A–Z).
    var toolbarNewItemTypes: [String] {
        let keys = toolbarNewItemTypeKeys
        return newItemTypes.filter { keys.contains($0.lowercased()) }
    }

    func isToolbarNewItemType(_ type: String) -> Bool {
        let key = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return false }
        return toolbarNewItemTypeKeys.contains(key)
    }

    /// Full New-menu list: enabled fixed types first, then custom types A–Z.
    var newItemTypes: [String] {
        enabledFixedNewItemTypes + customNewItemTypes
    }

    static func isFixedNewItemType(_ type: String) -> Bool {
        canonicalFixedType(type) != nil
    }

    private func pruneToolbarNewItemTypes(allowed: [String], preferred: Set<String>? = nil) {
        let allowedKeys = Set(allowed.map { $0.lowercased() })
        let source = preferred ?? toolbarNewItemTypeKeys
        let filtered = source
            .map { $0.lowercased() }
            .filter { allowedKeys.contains($0) }
            .sorted()
        defaults.set(filtered, forKey: Keys.toolbarNewItemTypes)
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

    /// Folder order for the top favorites bar only (independent from the left sidebar).
    var topBookmarkFolderOrder: [String] {
        get { defaults.stringArray(forKey: Keys.topBookmarkFolderOrder) ?? [] }
        set { defaults.set(newValue, forKey: Keys.topBookmarkFolderOrder) }
    }

    func bookmarks(in placement: FavoritesPlacement) -> [Bookmark] {
        bookmarks.filter { $0.placement == placement }
    }

    /// True when the bookmark sits on the bar itself (Chrome-style), not inside a folder.
    static func isFavoritesBarFolder(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "收藏栏" || name == "收藏夹" || name == "收藏"
    }

    /// Bookmarks placed directly on the favorites bar (no folder).
    func rootBookmarks(in placement: FavoritesPlacement) -> [Bookmark] {
        bookmarks(in: placement).filter { Self.isFavoritesBarFolder($0.folder) }
    }

    /// Bookmarks inside a real named folder (not the bar).
    func bookmarks(in folder: String, placement: FavoritesPlacement) -> [Bookmark] {
        let target = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.isFavoritesBarFolder(target) else {
            return rootBookmarks(in: placement)
        }
        return bookmarks(in: placement)
            .filter {
                let name = $0.folder.trimmingCharacters(in: .whitespacesAndNewlines)
                return !Self.isFavoritesBarFolder(name) && name == target
            }
    }

    /// Real folders only — never invents a「收藏栏」folder chip/group.
    func orderedBookmarkFolders(for placement: FavoritesPlacement) -> [String] {
        let order = placement == .top ? topBookmarkFolderOrder : bookmarkFolderOrder
        let surfaceBookmarks = bookmarks(in: placement)
        var result: [String] = []
        var seen = Set<String>()

        for folder in order {
            let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.isFavoritesBarFolder(name), !seen.contains(name) else { continue }
            result.append(name)
            seen.insert(name)
        }
        for bookmark in surfaceBookmarks {
            let name = bookmark.folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.isFavoritesBarFolder(name), !seen.contains(name) else { continue }
            result.append(name)
            seen.insert(name)
        }
        return result
    }

    /// Left sidebar folders (backward-compatible name).
    func orderedBookmarkFolders() -> [String] {
        orderedBookmarkFolders(for: .left)
    }

    /// Left favorites sidebar width (points). Default 220; no hard min/max.
    var favoritesSidebarWidth: CGFloat {
        get {
            let stored = defaults.object(forKey: Keys.favoritesSidebarWidth) as? Double
            return max(0, CGFloat(stored ?? 220))
        }
        set { defaults.set(Double(max(0, newValue)), forKey: Keys.favoritesSidebarWidth) }
    }

    var favoritesSidebarVisible: Bool {
        get {
            if defaults.object(forKey: Keys.favoritesSidebarVisible) == nil { return true }
            return defaults.bool(forKey: Keys.favoritesSidebarVisible)
        }
        set { defaults.set(newValue, forKey: Keys.favoritesSidebarVisible) }
    }

    /// Top favorites chip bar (independent from the left sidebar).
    var favoritesTopBarVisible: Bool {
        get {
            if defaults.object(forKey: Keys.favoritesTopBarVisible) == nil { return true }
            return defaults.bool(forKey: Keys.favoritesTopBarVisible)
        }
        set { defaults.set(newValue, forKey: Keys.favoritesTopBarVisible) }
    }

    var preferChinese: Bool {
        get {
            if defaults.object(forKey: Keys.languageChinese) == nil { return true }
            return defaults.bool(forKey: Keys.languageChinese)
        }
        set { defaults.set(newValue, forKey: Keys.languageChinese) }
    }

    /// Bundle IDs (or paths) the user has set as default via「打开方式」checkbox. Newest first.
    var openWithDefaultHistory: [String] {
        get { defaults.stringArray(forKey: Keys.openWithDefaultHistory) ?? [] }
        set { defaults.set(Array(newValue.prefix(30)), forKey: Keys.openWithDefaultHistory) }
    }

    func rememberOpenWithDefaultApp(bundleID: String, path: String) {
        let key = bundleID.isEmpty ? path : bundleID
        var list = openWithDefaultHistory.filter { $0 != key }
        list.insert(key, at: 0)
        openWithDefaultHistory = list
    }

    /// Apps recently used via「打开方式」(open or set-default). Newest first. Global fallback.
    var openWithAppHistory: [String] {
        get {
            let stored = defaults.stringArray(forKey: Keys.openWithAppHistory) ?? []
            if !stored.isEmpty { return stored }
            return openWithDefaultHistory
        }
        set { defaults.set(Array(newValue.prefix(30)), forKey: Keys.openWithAppHistory) }
    }

    /// Per file-type open-with history: typeKey → [bundleID or path], newest first.
    var openWithAppHistoryByType: [String: [String]] {
        get {
            guard let data = defaults.data(forKey: Keys.openWithAppHistoryByType),
                  let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.openWithAppHistoryByType)
            }
        }
    }

    static func openWithTypeKey(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        if !ext.isEmpty { return "ext.\(ext)" }
        if let type = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return "uti.\(type.identifier)"
        }
        return "unknown"
    }

    func openWithHistoryKeys(forFile fileURL: URL) -> [String] {
        let typeKey = Self.openWithTypeKey(for: fileURL)
        let typed = openWithAppHistoryByType[typeKey] ?? []
        if !typed.isEmpty { return typed }
        // Upgrade path: reuse global history until per-type entries exist.
        return openWithAppHistory
    }

    func rememberOpenWithApp(bundleID: String, path: String, forFile fileURL: URL? = nil) {
        let key = bundleID.isEmpty ? path : bundleID
        guard !key.isEmpty else { return }

        var global = openWithAppHistory.filter { $0 != key }
        global.insert(key, at: 0)
        openWithAppHistory = global

        guard let fileURL else { return }
        let typeKey = Self.openWithTypeKey(for: fileURL)
        var byType = openWithAppHistoryByType
        var list = (byType[typeKey] ?? []).filter { $0 != key }
        list.insert(key, at: 0)
        byType[typeKey] = Array(list.prefix(15))
        openWithAppHistoryByType = byType
    }

    /// Global recent open history (folders + files), most-recent first. Persisted.
    var recentOpenHistory: [VisitRecord] {
        get {
            guard let data = defaults.data(forKey: Keys.recentOpenHistory),
                  let items = try? JSONDecoder().decode([VisitRecord].self, from: data) else {
                return []
            }
            return items
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue.prefix(80))) {
                defaults.set(data, forKey: Keys.recentOpenHistory)
            }
        }
    }

    func recordOpenHistory(_ url: URL) {
        let standardized = url.standardizedFileURL
        var list = recentOpenHistory.filter { $0.url.standardizedFileURL != standardized }
        list.insert(VisitRecord(url: standardized, visitedAt: Date()), at: 0)
        if list.count > 80 {
            list = Array(list.prefix(80))
        }
        recentOpenHistory = list
    }

    func clearOpenHistory() {
        recentOpenHistory = []
    }
}

struct VisitRecord: Equatable, Codable {
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
        AppSettings.shared.recordOpenHistory(standardized)
    }
}
