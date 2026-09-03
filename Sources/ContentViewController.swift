import AppKit
import UniformTypeIdentifiers

final class ContentViewController: NSViewController {
    var onOpen: ((FileItem) -> Void)?
    var onSelectionChange: (([FileItem]) -> Void)?
    var onCutRequest: (() -> Void)?
    var onCopyRequest: (() -> Void)?
    var onPasteRequest: (() -> Void)?
    var onRenameRequest: ((FileItem) -> Void)?
    var onCommitRename: ((FileItem, String) -> Void)?
    var onGoEnclosingFolder: (() -> Void)?
    /// Called after compress/extract so the browser can reload the folder.
    var onDirectoryNeedsReload: (() -> Void)?
    /// Open one or more archives in Chrome-style tabs.
    var onOpenArchives: (([URL]) -> Void)?
    /// Current window directory (drop onto empty area / non-folder rows).
    var directoryForDrop: (() -> URL)?
    /// Handle a file drop: sources, destination folder, whether to copy (true) or move (false).
    var onPerformFileDrop: (([URL], URL, Bool) -> Void)?

    private(set) var items: [FileItem] = []
    /// Top-level items for the current folder (tree root).
    private var rootItems: [FileItem] = []
    private var rowDepths: [Int] = []
    private var expandedURLs: Set<URL> = []
    private var childrenCache: [URL: [FileItem]] = [:]
    private var loadingExpandURLs: Set<URL> = []
    private var zoomFactor: CGFloat = 1

    private var listScroll: NSScrollView!
    private var listView: NSTableView!
    private var emptyLabel: NSTextField!
    private weak var renamingField: NSTextField?
    private var renamingItem: FileItem?
    private var renamingOriginalName: String?
    private weak var openWithMenuItem: NSMenuItem?

    /// Ordered sort keys: index 0 is primary. Shift-click adds secondary keys.
    private struct SortKey: Equatable {
        var columnID: String
        var ascending: Bool
    }
    private var sortKeys: [SortKey] = [SortKey(columnID: "name", ascending: true)]
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        emptyLabel = NSTextField(labelWithString: "文件夹为空")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.autohidesScrollers = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(listDoubleClicked)
        table.target = self

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "名称"
        nameCol.width = 320
        nameCol.minWidth = 140
        nameCol.headerCell.alignment = .left
        table.addTableColumn(nameCol)

        // Finder-style disclosure column (no title) between name and date.
        let expandCol = NSTableColumn(identifier: .init("expand"))
        expandCol.title = ""
        expandCol.width = 15
        expandCol.minWidth = 15
        expandCol.maxWidth = 15
        expandCol.resizingMask = []
        table.addTableColumn(expandCol)
        // Avoid default inter-column padding making the expand strip look wider than intended.
        table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "修改日期"
        dateCol.width = 160
        dateCol.headerCell.alignment = .left
        table.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "大小"
        sizeCol.width = 90
        sizeCol.headerCell.alignment = .left
        table.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = "种类"
        kindCol.width = 120
        kindCol.headerCell.alignment = .left
        table.addTableColumn(kindCol)

        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .delete], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        listView = table
        listScroll.documentView = table
        updateSortIndicator()

        root.addSubview(listScroll)
        root.addSubview(emptyLabel)
        view = root

        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: root.topAnchor),
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "打开", action: #selector(contextOpen), keyEquivalent: "")
        let openWith = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        openWith.submenu = NSMenu()
        openWithMenuItem = openWith
        menu.addItem(openWith)
        menu.addItem(withTitle: "显示简介", action: #selector(contextGetInfo), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "压缩…", action: #selector(contextCompress), keyEquivalent: "")
        menu.addItem(withTitle: "解压…", action: #selector(contextExtract), keyEquivalent: "")
        menu.addItem(withTitle: "打开压缩包", action: #selector(contextOpenArchive), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "赋予修改权限", action: #selector(contextMakeWritable), keyEquivalent: "")
        listView.menu = menu

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Must not use `self?.handleKey(event) ?? event`: when handleKey returns nil
            // (consume), optional chaining yields nil and `?? event` redispatches — causing a beep.
            guard let self else { return event }
            return self.handleKey(event)
        }

        applyZoomFactor(CGFloat(AppSettings.shared.uiZoomPercent) / 100)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pasteboardMayHaveChanged),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Re-tint rows after cut / copy / paste changes the pasteboard.
    func refreshCutAppearance() {
        guard isViewLoaded, listView != nil else { return }
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        listView.reloadData()
    }

    @objc private func pasteboardMayHaveChanged() {
        let count = NSPasteboard.general.changeCount
        guard count != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = count
        refreshCutAppearance()
    }

    private func isItemCut(_ item: FileItem) -> Bool {
        FileOperations.isURLCut(item.url)
    }

    private func applyCutAppearance(to cell: NSTableCellView, item: FileItem, nameColumn: Bool) {
        let cut = isItemCut(item)
        if nameColumn {
            cell.imageView?.alphaValue = cut ? 0.45 : 1
        }
        cell.textField?.textColor = cut ? .tertiaryLabelColor : .labelColor
    }

    private func nameTextColor(for item: FileItem) -> NSColor {
        if isItemCut(item) { return .tertiaryLabelColor }
        let isExpandedFolder = item.isDirectory
            && !item.isArchiveEntry
            && expandedURLs.contains(item.url.standardizedFileURL)
        return isExpandedFolder ? .systemRed : .labelColor
    }

    /// Scale list row height, fonts, and icons (30%…500%).
    func applyZoomFactor(_ factor: CGFloat) {
        zoomFactor = min(5, max(0.3, factor))
        guard isViewLoaded, listView != nil else { return }
        listView.rowHeight = max(16, round(22 * zoomFactor))
        if let expand = listView.tableColumn(withIdentifier: .init("expand")) {
            let w = max(11, round(15 * zoomFactor))
            expand.width = w
            expand.minWidth = w
            expand.maxWidth = w
        }
        // Drop icon cache so icons are regenerated at the new size.
        Self.iconCache.removeAll(keepingCapacity: true)
        listView.reloadData()
        listView.tile()
    }

    func setItems(_ items: [FileItem], alreadySortedByName: Bool = false) {
        replaceRootListing(
            items,
            preservingOutline: false,
            alreadySortedByName: alreadySortedByName,
            select: selectedItems.map(\.url.standardizedFileURL)
        )
    }

    /// Keep outline expansion while refreshing listings (after New / rename / trash / paste / watch).
    func replaceRootListing(
        _ items: [FileItem],
        preservingOutline: Bool,
        alreadySortedByName: Bool = false,
        select: [URL] = [],
        beginRename: URL? = nil
    ) {
        emptyLabel.isHidden = !items.isEmpty
        let previousSelection = select.isEmpty
            ? selectedItems.map(\.url.standardizedFileURL)
            : select.map(\.standardizedFileURL)

        if !preservingOutline {
            rootItems = items
            expandedURLs.removeAll()
            childrenCache.removeAll()
            loadingExpandURLs.removeAll()
            finishListingUpdate(
                alreadySortedByName: alreadySortedByName,
                select: previousSelection,
                beginRename: beginRename
            )
            return
        }

        rootItems = items
        // Drop expansions whose folders no longer exist.
        expandedURLs = Set(expandedURLs.filter { FileManager.default.fileExists(atPath: $0.path) })
        let keys = Array(expandedURLs)
        let showHidden = AppSettings.shared.showHiddenFiles
        let sortKeysSnapshot = sortKeys

        guard !keys.isEmpty else {
            childrenCache.removeAll()
            finishListingUpdate(
                alreadySortedByName: alreadySortedByName,
                select: previousSelection,
                beginRename: beginRename
            )
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var cache: [URL: [FileItem]] = [:]
            for key in keys {
                cache[key] = FileOperations.listDirectory(key, showHidden: showHidden)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var sortedCache: [URL: [FileItem]] = [:]
                for (url, kids) in cache {
                    sortedCache[url] = self.sortedItems(kids, keys: sortKeysSnapshot)
                }
                self.childrenCache = sortedCache
                self.finishListingUpdate(
                    alreadySortedByName: alreadySortedByName,
                    select: previousSelection,
                    beginRename: beginRename
                )
            }
        }
    }

    private func finishListingUpdate(
        alreadySortedByName: Bool,
        select: [URL],
        beginRename: URL?
    ) {
        let defaultNameSort = sortKeys == [SortKey(columnID: "name", ascending: true)]
        if alreadySortedByName, defaultNameSort {
            rebuildVisibleRows(preservingSelection: false)
        } else {
            applySort(preservingSelection: false)
        }
        if !select.isEmpty {
            self.select(urls: select)
        }
        onSelectionChange?(selectedItems)
        if let renameURL = beginRename?.standardizedFileURL,
           let item = items.first(where: { $0.url.standardizedFileURL == renameURL }) {
            DispatchQueue.main.async { [weak self] in
                self?.beginInlineRename(item)
            }
        }
    }

    var hasExpandedOutline: Bool { !expandedURLs.isEmpty }

    /// 单击表头：按该列主排序；再点同一列切换升降序。
    /// Shift+单击：追加次要排序（多列同时排序）；已在排序链中则切换该列方向。
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let id = tableColumn.identifier.rawValue
        if id == "expand" { return }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true

        if shift {
            if let index = sortKeys.firstIndex(where: { $0.columnID == id }) {
                sortKeys[index].ascending.toggle()
            } else {
                sortKeys.append(SortKey(columnID: id, ascending: true))
            }
        } else if sortKeys.count == 1, sortKeys[0].columnID == id {
            sortKeys[0].ascending.toggle()
        } else {
            sortKeys = [SortKey(columnID: id, ascending: true)]
        }
        applySort(preservingSelection: true)
    }

    private func applySort(preservingSelection: Bool) {
        let selectedURLs = preservingSelection ? selectedItems.map(\.url) : []
        let keys = sortKeys
        let snapshotRoot = rootItems
        let snapshotCache = childrenCache

        let finish: ([FileItem], [URL: [FileItem]]) -> Void = { [weak self] sortedRoot, sortedCache in
            guard let self else { return }
            self.rootItems = sortedRoot
            self.childrenCache = sortedCache
            self.rebuildVisibleRows(preservingSelection: preservingSelection, selectedURLs: selectedURLs)
        }

        let sortWork = { [weak self] () -> ([FileItem], [URL: [FileItem]]) in
            guard let self else { return (snapshotRoot, snapshotCache) }
            let sortedRoot = self.sortedItems(snapshotRoot, keys: keys)
            var sortedCache: [URL: [FileItem]] = [:]
            for (url, kids) in snapshotCache {
                sortedCache[url] = self.sortedItems(kids, keys: keys)
            }
            return (sortedRoot, sortedCache)
        }

        if snapshotRoot.count > 8_000 {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = sortWork()
                DispatchQueue.main.async { finish(result.0, result.1) }
            }
        } else {
            let result = sortWork()
            finish(result.0, result.1)
        }
    }

    private func rebuildVisibleRows(preservingSelection: Bool, selectedURLs: [URL]? = nil) {
        let selected = selectedURLs ?? (preservingSelection ? selectedItems.map(\.url) : [])
        var display: [FileItem] = []
        var depths: [Int] = []

        func walk(_ nodes: [FileItem], depth: Int) {
            for item in nodes {
                display.append(item)
                depths.append(depth)
                let key = item.url.standardizedFileURL
                if item.isDirectory,
                   !item.isArchiveEntry,
                   expandedURLs.contains(key),
                   let kids = childrenCache[key] {
                    walk(kids, depth: depth + 1)
                }
            }
        }

        walk(rootItems, depth: 0)
        items = display
        rowDepths = depths
        listView.reloadData()
        updateSortIndicator()
        if preservingSelection || selectedURLs != nil, !selected.isEmpty {
            select(urls: selected)
        }
        onSelectionChange?(selectedItems)
    }

    private func sortedItems(_ items: [FileItem], keys: [SortKey]) -> [FileItem] {
        items.sorted { lhs, rhs in
            for key in keys {
                let result = compare(lhs, rhs, by: key.columnID)
                if result != .orderedSame {
                    return key.ascending
                        ? result == .orderedAscending
                        : result == .orderedDescending
                }
            }
            return false
        }
    }

    private func compare(_ lhs: FileItem, _ rhs: FileItem, by columnID: String) -> ComparisonResult {
        switch columnID {
        case "date":
            let l = lhs.modificationDate ?? .distantPast
            let r = rhs.modificationDate ?? .distantPast
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        case "size":
            let l = lhs.isDirectory ? Int64.min : (lhs.fileSize ?? 0)
            let r = rhs.isDirectory ? Int64.min : (rhs.fileSize ?? 0)
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        case "kind":
            return kindString(for: lhs).localizedStandardCompare(kindString(for: rhs))
        default:
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory ? .orderedAscending : .orderedDescending
            }
            return lhs.name.localizedStandardCompare(rhs.name)
        }
    }

    private func updateSortIndicator() {
        let titles: [String: String] = [
            "name": "名称",
            "expand": "",
            "date": "修改日期",
            "size": "大小",
            "kind": "种类"
        ]
        let ascending = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        let descending = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)

        for column in listView.tableColumns {
            let id = column.identifier.rawValue
            let base = titles[id] ?? column.title
            if id == "expand" {
                listView.setIndicatorImage(nil, in: column)
                column.title = ""
                continue
            }
            if let index = sortKeys.firstIndex(where: { $0.columnID == id }) {
                let key = sortKeys[index]
                listView.setIndicatorImage(key.ascending ? ascending : descending, in: column)
                // 多列时在标题上标优先级 1、2、3…
                column.title = sortKeys.count > 1 ? "\(base) \(index + 1)" : base
            } else {
                listView.setIndicatorImage(nil, in: column)
                column.title = base
            }
        }
    }

    @objc private func expandButtonClicked(_ sender: NSButton) {
        let row = listView.row(for: sender)
        guard row >= 0 else { return }
        toggleExpand(at: row)
    }

    private func toggleExpand(at row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        guard item.isDirectory, !item.isArchiveEntry else { return }
        let key = item.url.standardizedFileURL

        let finishSelecting: () -> Void = { [weak self] in
            guard let self else { return }
            self.rebuildVisibleRows(preservingSelection: false)
            self.select(urls: [key])
        }

        if expandedURLs.contains(key) {
            collapse(url: key)
            finishSelecting()
            return
        }

        if childrenCache[key] != nil {
            expandedURLs.insert(key)
            finishSelecting()
            return
        }

        guard !loadingExpandURLs.contains(key) else { return }
        loadingExpandURLs.insert(key)
        listView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
        // Select immediately while children load.
        select(urls: [key])

        let showHidden = AppSettings.shared.showHiddenFiles
        let sortKeysSnapshot = sortKeys
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let kids = FileOperations.listDirectory(key, showHidden: showHidden)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingExpandURLs.remove(key)
                self.childrenCache[key] = self.sortedItems(kids, keys: sortKeysSnapshot)
                self.expandedURLs.insert(key)
                finishSelecting()
            }
        }
    }

    private func collapse(url: URL) {
        expandedURLs.remove(url)
        // Also collapse descendants so re-expand starts clean.
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let descendantKeys = expandedURLs.filter { $0.path.hasPrefix(prefix) }
        for key in descendantKeys {
            expandedURLs.remove(key)
        }
    }

    func isExpanded(_ url: URL) -> Bool {
        expandedURLs.contains(url.standardizedFileURL)
    }

    func markExpanded(_ url: URL) {
        expandedURLs.insert(url.standardizedFileURL)
    }

    /// New / Paste target:
    /// - selected expanded folder → inside it
    /// - selected nested row → that row's parent folder
    /// - otherwise → current listing directory
    func createTargetDirectory(fallback: URL) -> URL {
        let fallback = fallback.standardizedFileURL
        let selected = selectedItems.filter { !$0.isArchiveEntry }
        guard !selected.isEmpty else { return fallback }

        if selected.count == 1, let item = selected.first {
            let key = item.url.standardizedFileURL
            if item.isDirectory, expandedURLs.contains(key) {
                return key
            }
            if !isRootItem(key) {
                return item.url.deletingLastPathComponent().standardizedFileURL
            }
            return fallback
        }

        // Multi-select: if all live under the same nested parent, use that parent.
        let parents = Set(selected.map { $0.url.deletingLastPathComponent().standardizedFileURL })
        if parents.count == 1, let parent = parents.first, parent != fallback {
            return parent
        }
        return fallback
    }

    private func isRootItem(_ url: URL) -> Bool {
        rootItems.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    /// Refresh outline children after creating inside an expanded folder (keeps expansion).
    func refreshAfterCreate(at url: URL, parent: URL, beginRename: Bool) {
        let parentKey = parent.standardizedFileURL
        expandedURLs.insert(parentKey)
        let showHidden = AppSettings.shared.showHiddenFiles
        let sortKeysSnapshot = sortKeys
        let created = url.standardizedFileURL
        // Also refresh root in case parent is at root level.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let kids = FileOperations.listDirectory(parentKey, showHidden: showHidden)
            DispatchQueue.main.async {
                guard let self else { return }
                self.childrenCache[parentKey] = self.sortedItems(kids, keys: sortKeysSnapshot)
                // If parent is a root row, keep rootItems in sync when the created item is under root's child only.
                self.rebuildVisibleRows(preservingSelection: false)
                self.select(urls: [created])
                if beginRename,
                   let item = self.items.first(where: { $0.url.standardizedFileURL == created }) {
                    DispatchQueue.main.async {
                        self.beginInlineRename(item)
                    }
                }
            }
        }
    }

    /// After delete/rename of outline rows: drop stale expansions and refresh caches.
    func noteRemovedURLs(_ urls: [URL]) {
        for url in urls {
            let key = url.standardizedFileURL
            expandedURLs.remove(key)
            childrenCache[key] = nil
            let prefix = key.path.hasSuffix("/") ? key.path : key.path + "/"
            for child in expandedURLs.filter({ $0.path.hasPrefix(prefix) }) {
                expandedURLs.remove(child)
                childrenCache[child] = nil
            }
        }
    }

    var selectedItems: [FileItem] {
        listView.selectedRowIndexes.compactMap { idx in
            guard items.indices.contains(idx) else { return nil }
            return items[idx]
        }
    }

    func select(urls: [URL]) {
        let set = Set(urls.map { $0.standardizedFileURL })
        var indexes = IndexSet()
        for (idx, item) in items.enumerated() where set.contains(item.url.standardizedFileURL) {
            indexes.insert(idx)
        }
        listView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first {
            listView.scrollRowToVisible(first)
        }
        // Inactive (gray) selection happens when the table is not first responder.
        if !indexes.isEmpty {
            view.window?.makeKeyAndOrderFront(nil)
            view.window?.makeFirstResponder(listView)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view.window?.makeFirstResponder(self.listView)
            }
        }
        onSelectionChange?(selectedItems)
    }

    func selectAll() {
        listView.selectAll(nil)
        onSelectionChange?(selectedItems)
    }

    /// When renaming inline, ⌘A should select the whole name, not every file.
    @discardableResult
    func selectAllInRenameFieldIfNeeded() -> Bool {
        guard renamingField != nil, let editor = renamingField?.currentEditor() else { return false }
        editor.selectAll(nil)
        return true
    }

    func beginInlineRename(_ item: FileItem) {
        guard let row = items.firstIndex(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) else {
            return
        }
        listView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        listView.scrollRowToVisible(row)
        listView.layoutSubtreeIfNeeded()

        guard let cell = listView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }

        endInlineRename(commit: false)

        renamingItem = item
        renamingOriginalName = item.name
        renamingField = field

        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .default
        field.delegate = self
        field.target = self
        field.action = #selector(nameFieldAction(_:))
        field.stringValue = item.name

        view.window?.makeFirstResponder(field)
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.renamingField === field else { return }
            self.selectRenameRange(in: field, for: item)
        }
    }

    private func selectRenameRange(in field: NSTextField, for item: FileItem) {
        let name = item.name as NSString
        let length: Int
        if !item.isDirectory && !item.isPackage {
            let ext = name.pathExtension
            if !ext.isEmpty, name.length > ext.count + 1 {
                length = name.length - ext.count - 1
            } else {
                length = name.length
            }
        } else {
            length = name.length
        }
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: length)
    }

    private func endInlineRename(commit: Bool) {
        guard let field = renamingField else { return }
        let item = renamingItem
        let original = renamingOriginalName
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        field.delegate = nil
        field.target = nil
        field.action = nil
        field.isEditable = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none

        renamingField = nil
        renamingItem = nil
        renamingOriginalName = nil

        if commit, let item, let original {
            if !newName.isEmpty, newName != original {
                onCommitRename?(item, newName)
            } else {
                field.stringValue = original
                // Keep the same file selected after confirming an unchanged name.
                select(urls: [item.url])
            }
        } else if let item, let original {
            field.stringValue = original
            select(urls: [item.url])
        } else if let original {
            field.stringValue = original
            view.window?.makeFirstResponder(listView)
        }
    }

    @objc private func nameFieldAction(_ sender: NSTextField) {
        endInlineRename(commit: true)
    }

    @objc private func listDoubleClicked() {
        let row = listView.clickedRow
        guard row >= 0, items.indices.contains(row) else { return }
        onOpen?(items[row])
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard view.window?.isKeyWindow == true else { return event }
        if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘C / ⌘X / ⌘V
        if flags == .command,
           let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "c":
                onCopyRequest?()
                return nil
            case "x":
                onCutRequest?()
                return nil
            case "v":
                onPasteRequest?()
                return nil
            default:
                break
            }
        }

        // ⌘↑ → enclosing folder (Finder)
        if flags == .command {
            let isUp = event.specialKey == .upArrow
                || event.keyCode == 126
                || event.charactersIgnoringModifiers?.utf16.first == UInt16(NSUpArrowFunctionKey)
            if isUp {
                onGoEnclosingFolder?()
                return nil
            }
        }

        // Return / keypad Enter → open
        if event.keyCode == 36 || event.keyCode == 76, flags.isEmpty {
            guard let item = selectedItems.first else { return event }
            onOpen?(item)
            return nil
        }
        // Delete / Forward Delete, or ⌘⌫ (Finder) → trash
        if event.keyCode == 51 || event.keyCode == 117 {
            let allow = flags.isEmpty || flags == .command
            guard allow, !selectedItems.isEmpty else { return event }
            NotificationCenter.default.post(name: .contentRequestTrash, object: self)
            return nil
        }
        // F2 → rename (keyCode 120 = kVK_F2; also match NSF2FunctionKey character)
        let isF2 = event.keyCode == 120
            || event.specialKey == .f2
            || event.charactersIgnoringModifiers?.utf16.first == UInt16(NSF2FunctionKey)
        if isF2, flags.isEmpty || flags == .function {
            if let item = selectedItems.first {
                onRenameRequest?(item)
                return nil
            }
        }
        return event
    }

    @objc private func contextOpen() {
        selectedItems.forEach { onOpen?($0) }
    }

    @objc private func contextOpenWithOther() {
        ensureClickedRowSelected()
        let urls = openWithTargetURLs()
        guard !urls.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "打开"
        panel.message = "选择用来打开的应用程序"
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        openURLs(urls, withApp: appURL)
    }

    private func openWithTargetURLs() -> [URL] {
        selectedItems
            .filter { !$0.isArchiveEntry }
            .map(\.url)
    }

    private func openURLs(_ urls: [URL], withApp appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                DispatchQueue.main.async {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    private func rebuildOpenWithSubmenu() {
        guard let openWithMenuItem else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let urls = openWithTargetURLs()
        guard let primary = urls.first else {
            let empty = NSMenuItem(title: "无可用应用", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            openWithMenuItem.submenu = submenu
            return
        }

        let sections = OpenWithCatalog.sectionedApps(for: primary)
        let namePool = ([sections.currentDefault].compactMap { $0 } + sections.history + sections.others)

        func addSection(_ apps: [OpenWithCatalog.AppInfo], defaultURL: URL?) {
            for app in apps {
                let item = NSMenuItem()
                item.isEnabled = true
                let row = OpenWithRowView(frame: NSRect(
                    x: 0, y: 0,
                    width: OpenWithRowView.rowWidth,
                    height: OpenWithRowView.rowHeight
                ))
                row.appURL = app.url
                let title = OpenWithCatalog.disambiguatedName(for: app, among: namePool)
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                let isDefault = app.url.standardizedFileURL == defaultURL
                row.configure(name: title, icon: icon, isDefault: isDefault)
                row.onOpen = { [weak self] in
                    self?.openURLs(urls, withApp: app.url)
                }
                row.onSetDefault = { [weak self, weak submenu] in
                    OpenWithCatalog.setDefaultApp(app.url, for: urls) { error in
                        if let error {
                            let alert = NSAlert(error: error)
                            alert.runModal()
                            return
                        }
                        let newDefault = app.url.standardizedFileURL
                        submenu?.items.forEach { menuItem in
                            guard let rowView = menuItem.view as? OpenWithRowView else { return }
                            rowView.setDefaultChecked(rowView.appURL.standardizedFileURL == newDefault)
                        }
                        // Next open will re-section (history moves). Keep menu usable now.
                        _ = self
                    }
                }
                item.view = row
                submenu.addItem(item)
            }
        }

        let defaultURL = sections.currentDefault?.url.standardizedFileURL
            ?? OpenWithCatalog.defaultApp(for: primary)

        if let current = sections.currentDefault {
            addSection([current], defaultURL: defaultURL)
        }

        if !sections.history.isEmpty {
            if sections.currentDefault != nil {
                submenu.addItem(NSMenuItem.separator())
            }
            addSection(sections.history, defaultURL: defaultURL)
        }

        if !sections.others.isEmpty {
            if sections.currentDefault != nil || !sections.history.isEmpty {
                submenu.addItem(NSMenuItem.separator())
            }
            addSection(sections.others, defaultURL: defaultURL)
        }

        submenu.addItem(NSMenuItem.separator())
        let other = NSMenuItem(
            title: "其他…",
            action: #selector(contextOpenWithOther),
            keyEquivalent: ""
        )
        other.target = self
        other.isEnabled = true
        submenu.addItem(other)

        openWithMenuItem.submenu = submenu
    }

    @objc private func contextRename() {
        if let item = selectedItems.first {
            onRenameRequest?(item)
        }
    }

    @objc private func contextMakeWritable() {
        ensureClickedRowSelected()
        let urls = selectedItems.filter { !$0.isArchiveEntry }.map(\.url)
        guard !urls.isEmpty else { return }
        do {
            try FileOperations.makeWritable(urls)
            onDirectoryNeedsReload?()
        } catch {
            let alert = NSAlert()
            alert.messageText = "赋予权限失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func contextTrash() {
        NotificationCenter.default.post(name: .contentRequestTrash, object: self)
    }

    @objc private func contextGetInfo() {
        guard let item = selectedItems.first else { return }
        let values = try? item.url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ])
        let alert = NSAlert()
        alert.messageText = item.name
        let size: String
        if item.isDirectory {
            size = "文件夹"
        } else {
            let bytes = values?.fileSize.map(Int64.init) ?? item.fileSize ?? 0
            size = FileOperations.formatFileSize(bytes)
        }
        alert.informativeText = """
        路径：\(item.url.path)
        大小：\(size)
        修改：\(FileOperations.formatDate(values?.contentModificationDate ?? item.modificationDate))
        创建：\(FileOperations.formatDate(values?.creationDate ?? item.creationDate))
        """
        alert.runModal()
    }

    @objc private func contextCompress() {
        ensureClickedRowSelected()
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let base = urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory())
        guard let options = ArchiveDialogs.runCompressDialog(for: urls, relativeTo: base) else { return }
        ArchiveSupport.compress(urls: urls, options: options) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if options.deleteSource {
                    do { try FileOperations.moveToTrash(urls) }
                    catch { self.presentArchiveError(title: "压缩成功，但删除原文件失败", error: error) }
                }
                self.onDirectoryNeedsReload?()
            case .failure(let error):
                self.presentArchiveError(title: "压缩失败", error: error)
            }
        }
    }

    @objc private func contextExtract() {
        ensureClickedRowSelected()
        let urls = selectedItems.map(\.url).filter { ArchiveSupport.looksLikeArchive($0) }
        guard !urls.isEmpty else { return }
        let base = urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSHomeDirectory())
        guard let options = ArchiveDialogs.runExtractDialog(for: urls, relativeTo: base) else { return }
        try? FileManager.default.createDirectory(at: options.destinationURL, withIntermediateDirectories: true)
        ArchiveSupport.extract(urls: urls, options: options) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if options.deleteSource {
                    do { try FileOperations.moveToTrash(urls) }
                    catch { self.presentArchiveError(title: "解压成功，但删除压缩包失败", error: error) }
                }
                self.onDirectoryNeedsReload?()
            case .failure(let error):
                self.presentArchiveError(title: "解压失败", error: error)
            }
        }
    }

    @objc private func contextOpenArchive() {
        ensureClickedRowSelected()
        let urls = selectedItems.map(\.url).filter { ArchiveSupport.looksLikeArchive($0) }
        guard !urls.isEmpty else { return }
        onOpenArchives?(urls)
    }

    private func presentArchiveError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func ensureClickedRowSelected() {
        let row = listView.clickedRow
        guard row >= 0, items.indices.contains(row) else { return }
        if !listView.selectedRowIndexes.contains(row) {
            listView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onSelectionChange?(selectedItems)
        }
    }
}

extension ContentViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        ensureClickedRowSelected()
        let hasSelection = !selectedItems.isEmpty
        let archives = selectedItems.filter { !$0.isArchiveEntry && ArchiveSupport.looksLikeArchive($0.url) }
        let showExtractOrOpen = !archives.isEmpty
        let showCompress = hasSelection && selectedItems.contains(where: { !$0.isArchiveEntry })
        let showArchiveSection = showCompress || showExtractOrOpen
        let showOpenWith = !openWithTargetURLs().isEmpty

        openWithMenuItem?.isHidden = !showOpenWith
        openWithMenuItem?.isEnabled = showOpenWith
        if showOpenWith {
            rebuildOpenWithSubmenu()
        }

        var sawArchiveItem = false
        var archiveLeadingSeparator: NSMenuItem?
        var archiveTrailingSeparator: NSMenuItem?

        for item in menu.items {
            if item.isSeparatorItem {
                if !sawArchiveItem {
                    archiveLeadingSeparator = item
                } else if archiveTrailingSeparator == nil {
                    archiveTrailingSeparator = item
                }
                continue
            }
            switch item.action {
            case #selector(contextCompress),
                 #selector(contextExtract),
                 #selector(contextOpenArchive):
                sawArchiveItem = true
            default:
                break
            }
        }

        archiveLeadingSeparator?.isHidden = !showArchiveSection
        archiveTrailingSeparator?.isHidden = !showArchiveSection

        for item in menu.items {
            switch item.action {
            case #selector(contextOpen),
                 #selector(contextGetInfo):
                item.isHidden = false
                item.isEnabled = hasSelection
            case #selector(contextMakeWritable):
                let targets = selectedItems.filter { !$0.isArchiveEntry }
                item.isHidden = targets.isEmpty
                item.isEnabled = !targets.isEmpty
            case #selector(contextCompress):
                item.isHidden = !showCompress
                item.isEnabled = showCompress
                item.title = "压缩…"
            case #selector(contextExtract):
                item.isHidden = !showExtractOrOpen
                item.isEnabled = showExtractOrOpen
                item.title = "解压…"
            case #selector(contextOpenArchive):
                item.isHidden = !showExtractOrOpen
                item.isEnabled = showExtractOrOpen
                item.title = "打开压缩包"
            default:
                break
            }
        }
    }
}

extension Notification.Name {
    static let contentRequestTrash = Notification.Name("NewFinder.contentRequestTrash")
    static let uiZoomDidChange = Notification.Name("NewFinder.uiZoomDidChange")
}

extension ContentViewController: NSTableViewDataSource, NSTableViewDelegate {
    private static var iconCache: [String: NSImage] = [:]

    private static func cachedIcon(for item: FileItem, side: CGFloat) -> NSImage {
        let size = max(12, round(side))
        if item.isDirectory {
            let image = NSWorkspace.shared.icon(for: .folder)
            let copy = image.copy() as? NSImage ?? image
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        let ext = item.url.pathExtension.lowercased()
        let key = "\(ext.isEmpty ? "._file" : ext)@\(Int(size))"
        if let cached = iconCache[key] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: size, height: size)
        if iconCache.count < 256 {
            iconCache[key] = sized
        }
        return sized
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let id = tableColumn?.identifier ?? .init("name")
        let fontSize = max(10, round(13 * zoomFactor))
        let iconSide = max(12, round(16 * zoomFactor))

        if id.rawValue == "expand" {
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeExpandCell()
            configureExpandCell(cell, item: item)
            cell.alphaValue = isItemCut(item) ? 0.45 : 1
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeListCell(id: id)
        cell.textField?.font = .systemFont(ofSize: fontSize)
        cell.alphaValue = 1

        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = item.name
            cell.imageView?.image = Self.cachedIcon(for: item, side: iconSide)
            cell.constraints.first(where: { $0.identifier == "iconW" })?.constant = iconSide
            cell.constraints.first(where: { $0.identifier == "iconH" })?.constant = iconSide
            let depth = rowDepths.indices.contains(row) ? rowDepths[row] : 0
            let indentStep = max(10, round(14 * zoomFactor))
            cell.constraints.first(where: { $0.identifier == "nameIndent" })?.constant =
                2 + CGFloat(depth) * indentStep
            cell.imageView?.alphaValue = isItemCut(item) ? 0.45 : 1
            cell.textField?.textColor = nameTextColor(for: item)
        case "date":
            cell.textField?.stringValue = FileOperations.formatDate(item.modificationDate)
            cell.imageView?.image = nil
            applyCutAppearance(to: cell, item: item, nameColumn: false)
        case "size":
            cell.textField?.stringValue = item.isDirectory ? "--" : FileOperations.formatFileSize(item.fileSize)
            cell.imageView?.image = nil
            applyCutAppearance(to: cell, item: item, nameColumn: false)
        case "kind":
            cell.textField?.stringValue = kindString(for: item)
            cell.imageView?.image = nil
            applyCutAppearance(to: cell, item: item, nameColumn: false)
        default:
            break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedItems)
    }

    // MARK: - Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard renamingField == nil else { return nil }
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        guard !item.isArchiveEntry else { return nil }
        return item.url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        // Prefer dragging the full selection when the drag starts inside it.
        let selected = tableView.selectedRowIndexes
        let urls: [URL]
        if !selected.isEmpty, rowIndexes.contains(where: { selected.contains($0) }) {
            urls = selected.compactMap { idx -> URL? in
                guard items.indices.contains(idx), !items[idx].isArchiveEntry else { return nil }
                return items[idx].url
            }
        } else {
            urls = rowIndexes.compactMap { idx -> URL? in
                guard items.indices.contains(idx), !items[idx].isArchiveEntry else { return nil }
                return items[idx].url
            }
        }
        guard !urls.isEmpty else { return }
        session.draggingPasteboard.clearContents()
        session.draggingPasteboard.writeObjects(urls as [NSURL])
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // External move / trash: refresh listing.
        if operation.contains(.move) || operation.contains(.delete) {
            onDirectoryNeedsReload?()
        }
    }

    // MARK: - Drop destination

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let urls = Self.fileURLs(from: info)
        guard !urls.isEmpty else { return [] }

        let destination: URL
        if items.indices.contains(row),
           items[row].isDirectory,
           !items[row].isArchiveEntry {
            destination = items[row].url.standardizedFileURL
            tableView.setDropRow(row, dropOperation: .on)
        } else if let fallback = directoryForDrop?() {
            destination = fallback.standardizedFileURL
            tableView.setDropRow(max(row, 0), dropOperation: .above)
        } else {
            return []
        }

        guard isValidDrop(sources: urls, destination: destination) else { return [] }
        return prefersCopy(for: info) ? .copy : .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let urls = Self.fileURLs(from: info)
        guard !urls.isEmpty else { return false }

        let destination: URL
        if dropOperation == .on,
           items.indices.contains(row),
           items[row].isDirectory,
           !items[row].isArchiveEntry {
            destination = items[row].url.standardizedFileURL
        } else if let fallback = directoryForDrop?() {
            destination = fallback.standardizedFileURL
        } else {
            return false
        }

        guard isValidDrop(sources: urls, destination: destination) else { return false }
        onPerformFileDrop?(urls, destination, prefersCopy(for: info))
        return true
    }

    private func prefersCopy(for info: NSDraggingInfo) -> Bool {
        if NSEvent.modifierFlags.contains(.option) { return true }
        if info.draggingSource as AnyObject === listView { return false }
        let mask = info.draggingSourceOperationMask
        if mask.contains(.move) { return false }
        return true
    }

    private static func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.map(\.standardizedFileURL)
    }

    private func isValidDrop(sources: [URL], destination: URL) -> Bool {
        let dest = destination.standardizedFileURL
        let destPath = dest.path.hasSuffix("/") ? dest.path : dest.path + "/"
        for source in sources {
            let src = source.standardizedFileURL
            if src == dest { return false }
            // Cannot drop a folder into itself or its descendant.
            let srcPath = src.path.hasSuffix("/") ? src.path : src.path + "/"
            if destPath.hasPrefix(srcPath) {
                return false
            }
        }
        return true
    }

    private func makeExpandCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("expand")

        let background = NSView()
        background.identifier = .init("expandBackground")
        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = 3
        background.layer?.masksToBounds = true
        background.isHidden = true
        cell.addSubview(background)

        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(expandButtonClicked(_:))
        button.setButtonType(.momentaryChange)
        button.imageScaling = .scaleProportionallyDown
        button.identifier = .init("expandButton")
        cell.addSubview(button)

        let bgW = background.widthAnchor.constraint(equalToConstant: 13)
        bgW.identifier = "expandBgW"
        let bgH = background.heightAnchor.constraint(equalToConstant: 13)
        bgH.identifier = "expandBgH"
        let btnW = button.widthAnchor.constraint(equalToConstant: 12)
        btnW.identifier = "expandBtnW"
        let btnH = button.heightAnchor.constraint(equalToConstant: 12)
        btnH.identifier = "expandBtnH"
        NSLayoutConstraint.activate([
            background.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            background.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            bgW,
            bgH,
            button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            btnW,
            btnH
        ])
        return cell
    }

    private func configureExpandCell(_ cell: NSTableCellView, item: FileItem) {
        let button = cell.subviews.first(where: { $0.identifier?.rawValue == "expandButton" }) as? NSButton
        let background = cell.subviews.first(where: { $0.identifier?.rawValue == "expandBackground" })
        guard let button else { return }

        let bgSide = max(11, round(13 * zoomFactor))
        let btnSide = max(10, round(12 * zoomFactor))
        cell.constraints.first(where: { $0.identifier == "expandBgW" })?.constant = bgSide
        cell.constraints.first(where: { $0.identifier == "expandBgH" })?.constant = bgSide
        cell.constraints.first(where: { $0.identifier == "expandBtnW" })?.constant = btnSide
        cell.constraints.first(where: { $0.identifier == "expandBtnH" })?.constant = btnSide
        // Constraints may be owned by the views themselves.
        background?.constraints.first(where: { $0.identifier == "expandBgW" })?.constant = bgSide
        background?.constraints.first(where: { $0.identifier == "expandBgH" })?.constant = bgSide
        button.constraints.first(where: { $0.identifier == "expandBtnW" })?.constant = btnSide
        button.constraints.first(where: { $0.identifier == "expandBtnH" })?.constant = btnSide

        let canExpand = item.isDirectory && !item.isArchiveEntry
        button.isHidden = !canExpand
        button.isEnabled = canExpand
        guard canExpand else {
            button.image = nil
            background?.isHidden = true
            return
        }

        let key = item.url.standardizedFileURL
        let expanded = expandedURLs.contains(key)
        let symbol = expanded ? "chevron.down" : "chevron.right"
        let pointSize = max(7, round(8 * zoomFactor))
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: expanded ? "折叠" : "展开")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = expanded ? "折叠" : "展开"

        // Expanded: show a subtle chip behind the chevron; collapsed: no background.
        if expanded {
            background?.isHidden = false
            background?.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        } else {
            background?.isHidden = true
            background?.layer?.backgroundColor = nil
        }

        if loadingExpandURLs.contains(key) {
            button.isEnabled = false
        }
    }

    private func makeListCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = .left
        cell.addSubview(field)
        cell.textField = field

        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            let indent = image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
            indent.identifier = "nameIndent"
            let iconW = image.widthAnchor.constraint(equalToConstant: 16)
            iconW.identifier = "iconW"
            let iconH = image.heightAnchor.constraint(equalToConstant: 16)
            iconH.identifier = "iconH"
            NSLayoutConstraint.activate([
                indent,
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconW,
                iconH,
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private func kindString(for item: FileItem) -> String {
        if item.isDirectory { return "文件夹" }
        if item.isPackage { return "应用程序" }
        let ext = item.url.pathExtension
        if ext.isEmpty { return "文稿" }
        return ext.lowercased() + " 文稿"
    }
}

extension ContentViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard renamingField != nil, obj.object as AnyObject? === renamingField else { return }
        let movement = obj.userInfo?["NSTextMovement"] as? Int ?? 0
        let cancelled = movement == NSTextMovement.cancel.rawValue
        endInlineRename(commit: !cancelled)
    }
}
