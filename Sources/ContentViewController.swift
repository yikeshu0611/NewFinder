import AppKit
import QuickLookUI
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
    var onToggleFavoritesSidebar: (() -> Void)?
    var onToggleFavoritesTopBar: (() -> Void)?
    /// Copy selected item path(s), or the current folder path when nothing is selected.
    var onCopyPathRequest: (() -> Void)?
    /// Called after compress/extract so the browser can reload the folder.
    var onDirectoryNeedsReload: (() -> Void)?
    /// Open one or more archives in Chrome-style tabs.
    var onOpenArchives: (([URL]) -> Void)?
    /// Current window directory (drop onto empty area / non-folder rows).
    var directoryForDrop: (() -> URL)?
    /// Handle a file drop: sources, destination folder, whether to copy (true) or move (false).
    var onPerformFileDrop: (([URL], URL, Bool) -> Void)?

    /// Clear the active search (called from the search-results banner).
    var onClearSearch: (() -> Void)?
    /// Clear recent-open history (history page banner).
    var onClearOpenHistory: (() -> Void)?
    /// Dismiss the in-window history page (Esc / toggle).
    var onDismissHistoryPage: (() -> Void)?
    /// From search results: open the item's enclosing folder and select it.
    var onRevealInEnclosingFolder: ((URL) -> Void)?
    /// Empty the trash folder (NF trash mode).
    var onEmptyTrash: (() -> Void)?
    /// Put selected trash items back (Finder Put Away).
    var onPutBackFromTrash: (() -> Void)?
    /// Permanently delete selected trash items.
    var onDeleteFromTrash: (() -> Void)?
    /// Uninstall selected apps from an Applications folder.
    var onUninstallApps: (() -> Void)?

    private(set) var items: [FileItem] = []
    /// Top-level items for the current folder (tree root).
    private var rootItems: [FileItem] = []
    private var rowDepths: [Int] = []
    private var expandedURLs: Set<URL> = []
    private var childrenCache: [URL: [FileItem]] = [:]
    private var loadingExpandURLs: Set<URL> = []
    private var zoomFactor: CGFloat = 1
    private var isShowingSearchResults = false
    private var isShowingTrash = false
    private(set) var isShowingApplications = false
    private(set) var isShowingHistory = false
    private var searchQuery: String = ""
    /// Local filter for Applications uninstall mode (banner search field).
    private var applicationsFilterQuery: String = ""
    /// Apps marked via the list checkboxes for thorough uninstall.
    private var checkedUninstallURLs: Set<URL> = []
    /// Trailing-slash path of the search root so results can strip this prefix when displayed.
    private var searchRootPath: String = ""

    private var listScroll: NSScrollView!
    private var listView: NSTableView!
    private var columnBrowser: ColumnBrowserView!
    private var emptyLabel: NSTextField!
    private(set) var isColumnView = false
    var onColumnViewDirectoryChange: ((URL) -> Void)?
    var onViewModeChange: ((Bool) -> Void)?
    private var searchBanner: NSView!
    private var searchBannerLabel: NSTextField!
    private var applicationsFilterField: NSSearchField!
    private var searchBannerActionButton: NSButton!
    private var headerCheckButton: NSButton!
    private var searchBannerHeight: NSLayoutConstraint!
    private var listTopToRoot: NSLayoutConstraint!
    private var listTopToBanner: NSLayoutConstraint!
    /// Banner layouts: apps = uninstall left + search; other = label left + action right.
    private var bannerDefaultConstraints: [NSLayoutConstraint] = []
    private var bannerApplicationsConstraints: [NSLayoutConstraint] = []
    private weak var renamingField: NSTextField?
    private var renamingItem: FileItem?
    private var renamingOriginalName: String?
    private weak var openWithMenuItem: NSMenuItem?
    private weak var compareMenuItem: NSMenuItem?
    private weak var putBackMenuItem: NSMenuItem?
    private weak var deleteForeverMenuItem: NSMenuItem?
    private weak var uninstallMenuItem: NSMenuItem?
    /// URLs currently fed to QLPreviewPanel (non-archive files/folders).
    private var previewItems: [URL] = []

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

        searchBanner = NSView()
        searchBanner.translatesAutoresizingMaskIntoConstraints = false
        searchBanner.wantsLayer = true
        searchBanner.isHidden = true
        searchBannerLabel = NSTextField(labelWithString: "")
        searchBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        searchBannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        searchBannerLabel.textColor = .labelColor
        searchBannerLabel.lineBreakMode = .byTruncatingTail
        applicationsFilterField = NSSearchField()
        applicationsFilterField.translatesAutoresizingMaskIntoConstraints = false
        applicationsFilterField.placeholderString = "搜索应用名称"
        applicationsFilterField.controlSize = .small
        applicationsFilterField.font = .systemFont(ofSize: 12)
        applicationsFilterField.sendsSearchStringImmediately = true
        applicationsFilterField.sendsWholeSearchString = false
        applicationsFilterField.target = self
        applicationsFilterField.action = #selector(applicationsFilterChanged(_:))
        applicationsFilterField.isHidden = true
        applicationsFilterField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        applicationsFilterField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let clearSearch = NSButton(title: "清除搜索", target: self, action: #selector(clearSearchClicked))
        clearSearch.bezelStyle = .recessed
        clearSearch.controlSize = .small
        clearSearch.font = .systemFont(ofSize: 11)
        clearSearch.translatesAutoresizingMaskIntoConstraints = false
        searchBannerActionButton = clearSearch
        searchBanner.addSubview(searchBannerLabel)
        searchBanner.addSubview(applicationsFilterField)
        searchBanner.addSubview(clearSearch)

        bannerDefaultConstraints = [
            searchBannerLabel.leadingAnchor.constraint(equalTo: searchBanner.leadingAnchor, constant: 12),
            searchBannerLabel.centerYAnchor.constraint(equalTo: searchBanner.centerYAnchor),
            searchBannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearSearch.leadingAnchor, constant: -8),
            clearSearch.trailingAnchor.constraint(equalTo: searchBanner.trailingAnchor, constant: -10),
            clearSearch.centerYAnchor.constraint(equalTo: searchBanner.centerYAnchor)
        ]
        bannerApplicationsConstraints = [
            clearSearch.leadingAnchor.constraint(equalTo: searchBanner.leadingAnchor, constant: 10),
            clearSearch.centerYAnchor.constraint(equalTo: searchBanner.centerYAnchor),
            applicationsFilterField.leadingAnchor.constraint(equalTo: clearSearch.trailingAnchor, constant: 8),
            applicationsFilterField.centerYAnchor.constraint(equalTo: searchBanner.centerYAnchor),
            applicationsFilterField.trailingAnchor.constraint(equalTo: searchBanner.trailingAnchor, constant: -10),
            applicationsFilterField.heightAnchor.constraint(equalToConstant: 22)
        ]
        NSLayoutConstraint.activate(bannerDefaultConstraints)

        listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.borderType = .noBorder
        listScroll.autohidesScrollers = true
        listScroll.allowsMagnification = false
        listScroll.usesPredominantAxisScrolling = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(listDoubleClicked)
        table.target = self
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 29))

        let checkCol = NSTableColumn(identifier: .init("check"))
        checkCol.title = ""
        checkCol.width = 0
        checkCol.minWidth = 0
        checkCol.maxWidth = 0
        checkCol.resizingMask = []
        checkCol.isHidden = true
        table.addTableColumn(checkCol)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "名称"
        nameCol.width = 320
        nameCol.minWidth = 0
        nameCol.headerCell.alignment = .left
        table.addTableColumn(nameCol)

        // Finder-style disclosure column (no title) between name and date.
        let expandCol = NSTableColumn(identifier: .init("expand"))
        expandCol.title = ""
        expandCol.width = 15
        expandCol.minWidth = 0
        expandCol.maxWidth = 15
        expandCol.resizingMask = []
        table.addTableColumn(expandCol)
        // Avoid default inter-column padding making the expand strip look wider than intended.
        table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "修改日期"
        dateCol.width = 160
        dateCol.minWidth = 0
        dateCol.headerCell.alignment = .left
        table.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "大小"
        sizeCol.width = 90
        sizeCol.minWidth = 0
        sizeCol.headerCell.alignment = .left
        table.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = "种类"
        kindCol.width = 120
        kindCol.minWidth = 0
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

        headerCheckButton = NSButton(checkboxWithTitle: "", target: self, action: #selector(headerCheckToggled(_:)))
        headerCheckButton.controlSize = .regular
        headerCheckButton.focusRingType = .none
        headerCheckButton.allowsMixedState = true
        headerCheckButton.isHidden = true
        headerCheckButton.toolTip = "取消全选"
        table.headerView?.addSubview(headerCheckButton)

        root.addSubview(searchBanner)
        root.addSubview(listScroll)
        root.addSubview(emptyLabel)

        columnBrowser = ColumnBrowserView()
        columnBrowser.translatesAutoresizingMaskIntoConstraints = false
        columnBrowser.isHidden = true
        columnBrowser.onSelectionChange = { [weak self] items in
            self?.onSelectionChange?(items)
        }
        columnBrowser.onOpen = { [weak self] item in
            self?.onOpen?(item)
        }
        columnBrowser.onActivateDirectory = { [weak self] url in
            self?.onColumnViewDirectoryChange?(url)
        }
        columnBrowser.onPerformFileDrop = { [weak self] urls, destination, copying in
            self?.onPerformFileDrop?(urls, destination, copying)
        }
        columnBrowser.onDirectoryNeedsReload = { [weak self] in
            self?.onDirectoryNeedsReload?()
        }
        root.addSubview(columnBrowser)

        view = root

        searchBannerHeight = searchBanner.heightAnchor.constraint(equalToConstant: 0)
        listTopToRoot = listScroll.topAnchor.constraint(equalTo: root.topAnchor)
        listTopToBanner = listScroll.topAnchor.constraint(equalTo: searchBanner.bottomAnchor)
        listTopToBanner.isActive = false

        NSLayoutConstraint.activate([
            searchBanner.topAnchor.constraint(equalTo: root.topAnchor),
            searchBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchBannerHeight,

            listTopToRoot,
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            columnBrowser.topAnchor.constraint(equalTo: root.topAnchor),
            columnBrowser.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            columnBrowser.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            columnBrowser.bottomAnchor.constraint(equalTo: root.bottomAnchor),

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
        let compare = NSMenuItem(title: "比对", action: nil, keyEquivalent: "")
        compare.submenu = NSMenu()
        compareMenuItem = compare
        menu.addItem(compare)
        menu.addItem(withTitle: "打开所在位置", action: #selector(contextRevealInEnclosingFolder), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        let putBack = NSMenuItem(title: "放回原处", action: #selector(contextPutBack), keyEquivalent: "")
        putBackMenuItem = putBack
        menu.addItem(putBack)
        let deleteForever = NSMenuItem(title: "彻底删除", action: #selector(contextDeleteForever), keyEquivalent: "")
        deleteForeverMenuItem = deleteForever
        menu.addItem(deleteForever)
        let uninstall = NSMenuItem(title: "卸载…", action: #selector(contextUninstallApps), keyEquivalent: "")
        uninstallMenuItem = uninstall
        menu.addItem(uninstall)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "压缩…", action: #selector(contextCompress), keyEquivalent: "")
        menu.addItem(withTitle: "解压…", action: #selector(contextExtract), keyEquivalent: "")
        menu.addItem(withTitle: "打开压缩包", action: #selector(contextOpenArchive), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "赋予修改权限", action: #selector(contextMakeWritable), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "拷贝当前地址", action: #selector(contextCopyPath), keyEquivalent: "")
        listView.menu = menu

        // Keep NSTableView → NSScrollView intact so mouse-wheel scrolling works.
        // Insert this controller *after* the scroll view so QLPreviewPanel can still
        // find us via the responder chain (Space / Quick Look).
        let previous = listScroll.nextResponder
        listScroll.nextResponder = self
        nextResponder = previous

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

    /// If we remain in the responder chain between a hit-tested subview and the
    /// scroll view, still forward wheel events so scrolling never dies.
    override func scrollWheel(with event: NSEvent) {
        if let scroll = listScroll {
            scroll.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
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
        let baseRow: CGFloat = isShowingApplications ? 28 : 22
        listView.rowHeight = max(16, round(baseRow * zoomFactor))
        updateApplicationsCheckColumn()
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

    func setItems(_ items: [FileItem], alreadySortedByName: Bool = false, select: [URL]? = nil) {
        replaceRootListing(
            items,
            preservingOutline: false,
            alreadySortedByName: alreadySortedByName,
            select: select ?? selectedItems.map(\.url.standardizedFileURL)
        )
    }

    /// Patch sizes onto matching rows (used while package sizes fill in after a fast listing).
    func applyFileSizes(_ sizes: [URL: Int64]) {
        guard !sizes.isEmpty else { return }
        let selected = selectedItems.map(\.url.standardizedFileURL)
        var changed = false

        func patch(_ item: FileItem) -> FileItem {
            let key = item.url.standardizedFileURL
            guard let size = sizes[key], item.fileSize != size else { return item }
            changed = true
            return item.withFileSize(size)
        }

        rootItems = rootItems.map(patch)
        if !childrenCache.isEmpty {
            var nextCache: [URL: [FileItem]] = [:]
            for (key, kids) in childrenCache {
                nextCache[key] = kids.map(patch)
            }
            childrenCache = nextCache
        }
        guard changed else { return }
        rebuildVisibleRows(preservingSelection: true, selectedURLs: selected)
        onSelectionChange?(selectedItems)
    }

    /// Show or hide the search-results chrome so search mode is visually distinct.
    func setSearchResultsMode(query: String?, scopeName: String, resultCount: Int, searchRoot: URL? = nil) {
        let active = !(query?.isEmpty ?? true)
        if active {
            isShowingTrash = false
        }
        let wasActive = isShowingSearchResults
        isShowingSearchResults = active
        searchQuery = query ?? ""
        if let root = searchRoot?.standardizedFileURL {
            var path = root.path
            if path != "/", !path.hasSuffix("/") {
                path += "/"
            }
            searchRootPath = path
        } else {
            searchRootPath = ""
        }

        if active, let query {
            isShowingApplications = false
            isShowingHistory = false
            if isColumnView { setColumnViewEnabled(false) }
            checkedUninstallURLs.removeAll()
            applicationsFilterQuery = ""
            applicationsFilterField.stringValue = ""
            setBannerPrimaryContent(isApplicationsFilter: false)
            applyBannerChrome(active: true)
            let scope = scopeName.isEmpty ? "当前文件夹" : scopeName
            searchBannerLabel.stringValue = "搜索结果 · 「\(query)」 · \(resultCount) 项 · 在「\(scope)」中"
            emptyLabel.stringValue = "无匹配结果"
            searchBannerActionButton.title = "清除搜索"
            searchBannerActionButton.action = #selector(clearSearchClicked)
            searchBannerActionButton.target = self
            searchBannerActionButton.isEnabled = true
            let tint = NSColor.systemYellow.withAlphaComponent(0.18)
            searchBanner.layer?.backgroundColor = tint.cgColor
            view.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.06).cgColor
        } else if !isShowingTrash && !isShowingApplications && !isShowingHistory {
            applyBannerChrome(active: false)
            emptyLabel.stringValue = "文件夹为空"
            view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
        // Avoid reloadData when already leaving search — it clears the table selection.
        if active || wasActive {
            listView?.reloadData()
        }
        view.needsLayout = true
    }

    /// Finder-like Trash chrome inside NewFinder.
    func setTrashMode(active: Bool, itemCount: Int) {
        let wasActive = isShowingTrash
        isShowingTrash = active
        if active {
            isShowingApplications = false
            isShowingHistory = false
            checkedUninstallURLs.removeAll()
            applicationsFilterQuery = ""
            applicationsFilterField.stringValue = ""
            isShowingSearchResults = false
            searchQuery = ""
            setBannerPrimaryContent(isApplicationsFilter: false)
            applyBannerChrome(active: true)
            searchBannerLabel.stringValue = itemCount == 0
                ? "废纸篓为空"
                : "废纸篓 · \(itemCount) 项"
            emptyLabel.stringValue = "废纸篓为空"
            searchBannerActionButton.title = "清空废纸篓"
            searchBannerActionButton.action = #selector(emptyTrashClicked)
            searchBannerActionButton.target = self
            searchBannerActionButton.isEnabled = itemCount > 0
            let tint = NSColor.systemGray.withAlphaComponent(0.22)
            searchBanner.layer?.backgroundColor = tint.cgColor
            view.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.06).cgColor
        } else if !isShowingSearchResults && !isShowingApplications && !isShowingHistory {
            applyBannerChrome(active: false)
            emptyLabel.stringValue = "文件夹为空"
            view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            searchBannerActionButton.isEnabled = true
        }
        if active || wasActive {
            listView?.reloadData()
        }
        view.needsLayout = true
    }

    /// Applications folder: checkbox multi-select + filter + uninstall chrome.
    func setApplicationsMode(active: Bool) {
        let wasActive = isShowingApplications
        isShowingApplications = active
        if active {
            isShowingTrash = false
            isShowingSearchResults = false
            isShowingHistory = false
            searchQuery = ""
            if !wasActive {
                applicationsFilterQuery = ""
                applicationsFilterField.stringValue = ""
                checkedUninstallURLs.removeAll()
            }
            setBannerPrimaryContent(isApplicationsFilter: true)
            applyBannerChrome(active: true)
            emptyLabel.stringValue = applicationsFilterQuery.isEmpty ? "没有应用程序" : "无匹配应用"
            let tint = NSColor.systemBlue.withAlphaComponent(0.12)
            searchBanner.layer?.backgroundColor = tint.cgColor
            view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.04).cgColor
            refreshApplicationsBanner()
        } else {
            applicationsFilterQuery = ""
            applicationsFilterField.stringValue = ""
            checkedUninstallURLs.removeAll()
            setBannerPrimaryContent(isApplicationsFilter: false)
            if !isShowingSearchResults && !isShowingTrash && !isShowingHistory {
                applyBannerChrome(active: false)
                emptyLabel.stringValue = "文件夹为空"
                view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                searchBannerActionButton.isEnabled = true
            }
        }
        if active || wasActive {
            applyZoomFactor(zoomFactor)
            updateApplicationsCheckColumn()
            if !active, wasActive {
                rebuildVisibleRows(preservingSelection: true)
            } else {
                listView?.reloadData()
            }
        }
        view.needsLayout = true
    }

    func refreshApplicationsBanner() {
        guard isShowingApplications else { return }
        setBannerPrimaryContent(isApplicationsFilter: true)
        let count = checkedUninstallURLs.count
        if count == 0 {
            searchBannerActionButton.title = "卸载"
            searchBannerActionButton.isEnabled = false
        } else {
            searchBannerActionButton.title = count == 1 ? "卸载" : "卸载（\(count)）"
            searchBannerActionButton.isEnabled = true
        }
        searchBannerActionButton.action = #selector(uninstallAppsClicked)
        searchBannerActionButton.target = self
        updateHeaderCheckButton()
    }

    /// Recent-open history page chrome (in-window list, not a dropdown).
    func setHistoryMode(active: Bool, itemCount: Int) {
        let wasActive = isShowingHistory
        isShowingHistory = active
        if active {
            isShowingTrash = false
            isShowingSearchResults = false
            isShowingApplications = false
            if isColumnView { setColumnViewEnabled(false) }
            searchQuery = ""
            checkedUninstallURLs.removeAll()
            applicationsFilterQuery = ""
            applicationsFilterField.stringValue = ""
            setBannerPrimaryContent(isApplicationsFilter: false)
            applyBannerChrome(active: true)
            searchBannerLabel.stringValue = itemCount == 0
                ? "最近打开 · 暂无记录"
                : "最近打开 · \(itemCount) 项"
            emptyLabel.stringValue = "暂无打开历史"
            searchBannerActionButton.title = "清除历史"
            searchBannerActionButton.action = #selector(clearOpenHistoryClicked)
            searchBannerActionButton.target = self
            searchBannerActionButton.isEnabled = itemCount > 0
            let tint = NSColor.systemPurple.withAlphaComponent(0.14)
            searchBanner.layer?.backgroundColor = tint.cgColor
            view.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.04).cgColor
            if let dateCol = listView?.tableColumn(withIdentifier: .init("date")) {
                dateCol.title = "打开时间"
            }
        } else {
            if let dateCol = listView?.tableColumn(withIdentifier: .init("date")) {
                dateCol.title = "修改日期"
            }
            if !isShowingSearchResults && !isShowingTrash && !isShowingApplications {
                applyBannerChrome(active: false)
                emptyLabel.stringValue = "文件夹为空"
                view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                searchBannerActionButton.isEnabled = true
            }
        }
        updateApplicationsCheckColumn()
        if active || wasActive {
            listView?.reloadData()
        }
        view.needsLayout = true
    }

    @objc private func clearOpenHistoryClicked() {
        onClearOpenHistory?()
    }

    private func setBannerPrimaryContent(isApplicationsFilter: Bool) {
        applicationsFilterField.isHidden = !isApplicationsFilter
        searchBannerLabel.isHidden = isApplicationsFilter
        if isApplicationsFilter {
            NSLayoutConstraint.deactivate(bannerDefaultConstraints)
            NSLayoutConstraint.activate(bannerApplicationsConstraints)
        } else {
            NSLayoutConstraint.deactivate(bannerApplicationsConstraints)
            NSLayoutConstraint.activate(bannerDefaultConstraints)
        }
    }

    private func applyBannerChrome(active: Bool) {
        searchBanner.isHidden = !active
        searchBannerHeight.constant = active ? 32 : 0
        listTopToRoot.isActive = !active
        listTopToBanner.isActive = active
    }

    private func updateApplicationsCheckColumn() {
        guard let listView,
              let col = listView.tableColumn(withIdentifier: .init("check")) else { return }
        if isShowingApplications {
            let side = max(24, round(16 * zoomFactor) + 10)
            col.isHidden = false
            col.width = side
            col.minWidth = side
            col.maxWidth = side
        } else {
            col.isHidden = true
            col.width = 0
            col.minWidth = 0
            col.maxWidth = 0
        }
        updateHeaderCheckButton()
    }

    private func visiblePackagesForCheck() -> [FileItem] {
        items.filter { $0.isPackage || $0.isDirectory || $0.url.pathExtension.lowercased() == "app" }
    }

    private func updateHeaderCheckButton() {
        guard isViewLoaded, headerCheckButton != nil, let listView, let header = listView.headerView else { return }
        let colIndex = listView.column(withIdentifier: .init("check"))
        guard isShowingApplications, colIndex >= 0,
              let col = listView.tableColumn(withIdentifier: .init("check")),
              !col.isHidden else {
            headerCheckButton.isHidden = true
            return
        }

        let rect = header.headerRect(ofColumn: colIndex)
        let side: CGFloat = 18
        headerCheckButton.frame = NSRect(
            x: floor(rect.midX - side / 2),
            y: floor(rect.midY - side / 2),
            width: side,
            height: side
        )
        headerCheckButton.isHidden = false

        let packages = visiblePackagesForCheck()
        let checkedCount = packages.reduce(into: 0) { count, item in
            if checkedUninstallURLs.contains(item.url.standardizedFileURL) {
                count += 1
            }
        }
        headerCheckButton.isEnabled = !packages.isEmpty
        // Setting mixed/on/off while allowsMixedState can fight user clicks; sync carefully.
        if packages.isEmpty || checkedCount == 0 {
            headerCheckButton.state = .off
        } else if checkedCount == packages.count {
            headerCheckButton.state = .on
        } else {
            headerCheckButton.state = .mixed
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateHeaderCheckButton()
    }

    @objc private func headerCheckToggled(_ sender: NSButton) {
        guard isShowingApplications else { return }
        // Header control always clears checks (never select-all).
        checkedUninstallURLs.removeAll()
        listView.reloadData()
        refreshApplicationsBanner()
        DispatchQueue.main.async { [weak self] in
            self?.updateHeaderCheckButton()
        }
    }

    @objc private func applicationsFilterChanged(_ sender: NSSearchField) {
        guard isShowingApplications else { return }
        applicationsFilterQuery = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildVisibleRows(preservingSelection: true)
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.stringValue = applicationsFilterQuery.isEmpty ? "没有应用程序" : "无匹配应用"
    }

    @objc private func appCheckToggled(_ sender: NSButton) {
        let row = sender.tag
        guard items.indices.contains(row) else { return }
        let url = items[row].url.standardizedFileURL
        if sender.state == .on {
            checkedUninstallURLs.insert(url)
        } else {
            checkedUninstallURLs.remove(url)
        }
        refreshApplicationsBanner()
    }

    /// Packages / app folders marked for thorough uninstall (checkboxes preferred, else table selection).
    var packagesForUninstall: [FileItem] {
        if !checkedUninstallURLs.isEmpty {
            return checkedUninstallURLs.compactMap { url -> FileItem? in
                if let item = rootItems.first(where: { $0.url.standardizedFileURL == url }) {
                    return item
                }
                return FileItem.from(url: url)
            }.filter { $0.isPackage || $0.isDirectory }
        }
        return selectedItems.filter { $0.isPackage || $0.isDirectory }
    }

    func clearUninstallChecks(for urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        checkedUninstallURLs = checkedUninstallURLs.filter { !paths.contains($0.path) }
        refreshApplicationsBanner()
        listView?.reloadData()
    }

    @objc private func clearSearchClicked() {
        onClearSearch?()
    }

    @objc private func emptyTrashClicked() {
        onEmptyTrash?()
    }

    @objc private func uninstallAppsClicked() {
        onUninstallApps?()
    }

    @objc private func contextPutBack() {
        ensureClickedRowSelected()
        onPutBackFromTrash?()
    }

    @objc private func contextDeleteForever() {
        ensureClickedRowSelected()
        onDeleteFromTrash?()
    }

    @objc private func contextUninstallApps() {
        ensureClickedRowSelected()
        onUninstallApps?()
    }

    private func attributedName(for item: FileItem) -> NSAttributedString {
        let fontSize = max(10, round(13 * zoomFactor))
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let color = nameTextColor(for: item)
        let display: String
        if isShowingHistory {
            display = item.url.path
        } else if isShowingSearchResults {
            display = searchResultPath(for: item)
        } else {
            display = item.name
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.lineSpacing = 0

        guard isShowingSearchResults, !searchQuery.isEmpty else {
            return NSAttributedString(string: display, attributes: [
                .font: baseFont,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ])
        }

        let result = NSMutableAttributedString(string: display, attributes: [
            .font: baseFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        let keywords = searchQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        let lower = display.lowercased()
        for keyword in keywords {
            let key = keyword.lowercased()
            var searchStart = lower.startIndex
            while let range = lower.range(of: key, range: searchStart..<lower.endIndex) {
                let nsRange = NSRange(range, in: display)
                if nsRange.location != NSNotFound {
                    result.addAttributes([
                        .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.55),
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .paragraphStyle: paragraph
                    ], range: nsRange)
                }
                searchStart = range.upperBound
            }
        }
        return result
    }

    /// Path relative to the search root (current folder prefix omitted), e.g. `子文件夹/jing-2.zip`.
    private func searchResultPath(for item: FileItem) -> String {
        let absolute = item.url.standardizedFileURL.path
        guard !searchRootPath.isEmpty else { return absolute }
        if searchRootPath == "/" {
            return absolute.hasPrefix("/") ? String(absolute.dropFirst()) : absolute
        }
        guard absolute.hasPrefix(searchRootPath) else { return absolute }
        let relative = String(absolute.dropFirst(searchRootPath.count))
        return relative.isEmpty ? item.name : relative
    }

    /// Keep outline expansion while refreshing listings (after New / rename / trash / paste / watch).
    func replaceRootListing(
        _ items: [FileItem],
        preservingOutline: Bool,
        alreadySortedByName: Bool = false,
        select: [URL] = [],
        beginRename: URL? = nil
    ) {
        emptyLabel.isHidden = isColumnView || !items.isEmpty
        let previousSelection = select.isEmpty
            ? selectedItems.map(\.url.standardizedFileURL)
            : select.map(\.standardizedFileURL)

        if isColumnView, let root = directoryForDrop?() {
            let reveal = (beginRename.map { [$0] } ?? []) + previousSelection
            columnBrowser.refreshAfterMutation(root: root, select: reveal)
        }

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
        if id == "expand" || id == "check" { return }
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let preferredAscending = Self.preferredAscending(for: id)

        if shift {
            if let index = sortKeys.firstIndex(where: { $0.columnID == id }) {
                sortKeys[index].ascending.toggle()
            } else {
                sortKeys.append(SortKey(columnID: id, ascending: preferredAscending))
            }
        } else if sortKeys.count == 1, sortKeys[0].columnID == id {
            sortKeys[0].ascending.toggle()
        } else {
            sortKeys = [SortKey(columnID: id, ascending: preferredAscending)]
        }
        applySort(preservingSelection: true)
    }

    /// Name / kind default to ascending; date / size default to descending.
    private static func preferredAscending(for columnID: String) -> Bool {
        switch columnID {
        case "date", "size":
            return false
        default:
            return true
        }
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

        let roots: [FileItem]
        if isShowingApplications, !applicationsFilterQuery.isEmpty {
            let query = applicationsFilterQuery
            roots = rootItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
        } else {
            roots = rootItems
        }
        walk(roots, depth: 0)
        items = display
        rowDepths = depths
        listView.reloadData()
        updateSortIndicator()
        updateHeaderCheckButton()
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
            let l = lhs.fileSize ?? 0
            let r = rhs.fileSize ?? 0
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        case "kind":
            return kindString(for: lhs).localizedStandardCompare(kindString(for: rhs))
        default:
            if isShowingSearchResults {
                return searchResultPath(for: lhs)
                    .localizedStandardCompare(searchResultPath(for: rhs))
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

    /// Expand a folder row in place (no-op if already expanded / not a folder).
    private func expandFolder(at row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        guard item.isDirectory, !item.isArchiveEntry else { return }
        let key = item.url.standardizedFileURL
        guard !expandedURLs.contains(key) else {
            select(urls: [key])
            return
        }
        guard !loadingExpandURLs.contains(key) else { return }

        let finishSelecting: () -> Void = { [weak self] in
            guard let self else { return }
            self.rebuildVisibleRows(preservingSelection: false)
            self.select(urls: [key])
        }

        if childrenCache[key] != nil {
            expandedURLs.insert(key)
            finishSelecting()
            return
        }

        loadingExpandURLs.insert(key)
        listView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
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

    private func toggleExpand(at row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        guard item.isDirectory, !item.isArchiveEntry else { return }
        let key = item.url.standardizedFileURL

        if expandedURLs.contains(key) {
            collapse(url: key)
            rebuildVisibleRows(preservingSelection: false)
            select(urls: [key])
            return
        }
        expandFolder(at: row)
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
    /// - column view: selected folder (or parent of selected file)
    /// - selected expanded folder → inside it
    /// - selected nested row → that row's parent folder
    /// - otherwise → current listing directory
    func createTargetDirectory(fallback: URL) -> URL {
        let fallback = fallback.standardizedFileURL
        let selected = selectedItems.filter { !$0.isArchiveEntry }

        if isColumnView {
            guard let item = selected.first else { return fallback }
            if item.isDirectory, !item.isPackage {
                return item.url.standardizedFileURL
            }
            return item.url.deletingLastPathComponent().standardizedFileURL
        }

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
        if isColumnView {
            return columnBrowser?.selectedItems ?? []
        }
        return listView.selectedRowIndexes.compactMap { idx in
            guard items.indices.contains(idx) else { return nil }
            return items[idx]
        }
    }

    /// Finder-style horizontal column view (分栏): click folder → next column on the right.
    /// - Parameter reveal: optional item to select after entering column view (folder opens the next column).
    func setColumnViewEnabled(_ enabled: Bool, reveal: URL? = nil) {
        let want = enabled && !isShowingSearchResults && !isShowingHistory
        guard want != isColumnView else {
            if want, let reveal {
                columnBrowser.select(urls: [reveal.standardizedFileURL])
                onSelectionChange?(selectedItems)
            }
            onViewModeChange?(isColumnView)
            return
        }
        isColumnView = want
        listScroll.isHidden = want
        columnBrowser.isHidden = !want
        emptyLabel.isHidden = want || !items.isEmpty
        if want {
            // Leave list outline collapsed so switching back is clean.
            expandedURLs.removeAll()
            let root = directoryForDrop?() ?? FileManager.default.homeDirectoryForCurrentUser
            columnBrowser.setRootURL(root)
            if let reveal {
                columnBrowser.select(urls: [reveal.standardizedFileURL])
            }
        } else {
            rebuildVisibleRows(preservingSelection: true)
        }
        onViewModeChange?(isColumnView)
        onSelectionChange?(selectedItems)
    }

    func toggleColumnView() {
        setColumnViewEnabled(!isColumnView)
    }

    /// After deleting the current selection: prefer the next row below, else the previous above.
    func selectionURLAfterRemovingSelected() -> URL? {
        let selected = listView.selectedRowIndexes
        guard let bottom = selected.last else { return nil }

        if bottom + 1 < items.count {
            for idx in (bottom + 1)..<items.count where !selected.contains(idx) {
                return items[idx].url
            }
        }
        if let top = selected.first, top > 0 {
            for idx in stride(from: top - 1, through: 0, by: -1) where !selected.contains(idx) {
                return items[idx].url
            }
        }
        return nil
    }

    func select(urls: [URL]) {
        if isColumnView {
            columnBrowser.select(urls: urls)
            onSelectionChange?(selectedItems)
            return
        }
        // Compare by path string — file URL Hashable/equality can miss matches across listing vs search.
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        var indexes = IndexSet()
        for (idx, item) in items.enumerated() where paths.contains(item.url.standardizedFileURL.path) {
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
        if isColumnView {
            NSSound.beep()
            return
        }
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

        guard let nameColumnIndex = listView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }),
              let cell = listView.view(atColumn: nameColumnIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
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

        // ⌘C / ⌘X / ⌘V / ⌘A / ⌘O (left favorites) / ⌘⇧O (top favorites)
        if let ch = event.charactersIgnoringModifiers?.lowercased() {
            if flags == .command {
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
                case "a":
                    selectAll()
                    return nil
                case "o":
                    onToggleFavoritesSidebar?()
                    return nil
                default:
                    break
                }
            }
            if flags == [.command, .shift], ch == "o" {
                onToggleFavoritesTopBar?()
                return nil
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

        // Esc → dismiss history page
        if event.keyCode == 53, flags.isEmpty, isShowingHistory {
            onDismissHistoryPage?()
            return nil
        }

        // Space → Quick Look (Finder)
        if event.keyCode == 49, flags.isEmpty {
            toggleQuickLook()
            return nil
        }

        // Return / keypad Enter → open (column view: folders already open next column)
        if event.keyCode == 36 || event.keyCode == 76, flags.isEmpty {
            guard let item = selectedItems.first else { return event }
            if isColumnView, item.isDirectory, !item.isPackage {
                return nil
            }
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
        for item in selectedItems {
            if isColumnView, item.isDirectory, !item.isPackage {
                continue
            }
            onOpen?(item)
        }
    }

    @objc private func contextQuickLook() {
        ensureClickedRowSelected()
        showQuickLook()
    }

    private var previewableURLs: [URL] {
        selectedItems
            .filter { !$0.isArchiveEntry }
            .map(\.url.standardizedFileURL)
    }

    private func refreshPreviewItems() {
        previewItems = previewableURLs
    }

    private func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let panel = QLPreviewPanel.shared(),
           panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showQuickLook()
    }

    private func showQuickLook() {
        refreshPreviewItems()
        guard !previewItems.isEmpty else {
            NSSound.beep()
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        view.window?.makeFirstResponder(listView)
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
    }

    private func syncQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        refreshPreviewItems()
        if previewItems.isEmpty {
            panel.orderOut(nil)
            return
        }
        panel.reloadData()
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

    private func compareTargetURLs() -> [URL] {
        let nonArchive = selectedItems.filter { !$0.isArchiveEntry }
        guard !nonArchive.isEmpty else { return [] }
        let urls = nonArchive
            .filter {
                !$0.isDirectory
                    && CompareFileSupport.isComparable($0.url, isDirectory: $0.isDirectory)
            }
            .map(\.url)
        // Any number of comparable text files; selection must be all comparable files.
        guard !urls.isEmpty, urls.count == nonArchive.count else { return [] }
        return urls
    }

    private func rebuildCompareSubmenu() {
        guard let compareMenuItem else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let session = CompareSession.shared
        let canAssign = !compareTargetURLs().isEmpty
        for ws in 1 ... CompareSession.workspaceCount {
            let item = NSMenuItem(
                title: session.menuTitle(forWorkspace: ws),
                action: #selector(contextAssignCompareWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = ws
            item.isEnabled = canAssign
            submenu.addItem(item)
        }
        compareMenuItem.submenu = submenu
    }

    @objc private func contextAssignCompareWorkspace(_ sender: NSMenuItem) {
        ensureClickedRowSelected()
        let urls = compareTargetURLs()
        guard !urls.isEmpty else { return }
        let workspace = sender.tag
        CompareSession.shared.open(urls, inWorkspace: workspace)
        AppDelegate.shared.openCompareInKeyBrowser(workspace: workspace)
    }

    private func openURLs(_ urls: [URL], withApp appURL: URL) {
        let bid = Bundle(url: appURL)?.bundleIdentifier ?? ""
        AppSettings.shared.rememberOpenWithApp(
            bundleID: bid,
            path: appURL.path,
            forFile: urls.first
        )
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
        let namePool = [sections.currentDefault].compactMap { $0 }
            + sections.history
            + sections.recommended

        func addSection(_ apps: [OpenWithCatalog.AppInfo]) {
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
                row.configure(name: title, icon: icon)
                row.onOpen = { [weak self] in
                    self?.openURLs(urls, withApp: app.url)
                }
                item.view = row
                submenu.addItem(item)
            }
        }

        var didAddApps = false
        if let current = sections.currentDefault {
            addSection([current])
            didAddApps = true
        }
        if !sections.history.isEmpty {
            if didAddApps { submenu.addItem(NSMenuItem.separator()) }
            addSection(sections.history)
            didAddApps = true
        }
        if !sections.recommended.isEmpty {
            if didAddApps { submenu.addItem(NSMenuItem.separator()) }
            addSection(sections.recommended)
            didAddApps = true
        }

        if didAddApps {
            submenu.addItem(NSMenuItem.separator())
        }
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
                    let archivePath = options.archiveURL.standardizedFileURL.path
                    let toTrash = urls.filter { $0.standardizedFileURL.path != archivePath }
                    if !toTrash.isEmpty {
                        do { try FileOperations.moveToTrash(toTrash) }
                        catch { self.presentArchiveError(title: "压缩成功，但删除原文件失败", error: error) }
                    }
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
        ArchiveSupport.extract(urls: urls, options: options) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if options.deleteSource {
                    let destPath = options.destinationURL.standardizedFileURL.path
                    let toTrash = urls.filter { $0.standardizedFileURL.path != destPath }
                    if !toTrash.isEmpty {
                        do { try FileOperations.moveToTrash(toTrash) }
                        catch { self.presentArchiveError(title: "解压成功，但删除压缩包失败", error: error) }
                    }
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

    @objc private func contextCopyPath() {
        ensureClickedRowSelected()
        onCopyPathRequest?()
    }

    @objc private func contextRevealInEnclosingFolder() {
        ensureClickedRowSelected()
        guard let item = selectedItems.first(where: { !$0.isArchiveEntry }) else { return }
        onRevealInEnclosingFolder?(item.url)
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

        if isShowingTrash {
            for item in menu.items {
                if item.action == #selector(contextPutBack)
                    || item.action == #selector(contextDeleteForever) {
                    item.isHidden = false
                    item.isEnabled = hasSelection
                    if item.action == #selector(contextDeleteForever) {
                        item.title = "彻底删除"
                    }
                } else {
                    item.isHidden = true
                }
            }
            return
        }

        let archives = selectedItems.filter { !$0.isArchiveEntry && ArchiveSupport.looksLikeArchive($0.url) }
        let showExtractOrOpen = !archives.isEmpty
        let showCompress = hasSelection && selectedItems.contains(where: { !$0.isArchiveEntry })
        let showArchiveSection = showCompress || showExtractOrOpen
        let showOpenWith = !openWithTargetURLs().isEmpty
        let uninstallable = isShowingApplications
            ? (checkedUninstallURLs.isEmpty
                ? selectedItems.filter { $0.isPackage || $0.isDirectory }
                : packagesForUninstall)
            : selectedItems.filter { $0.isPackage || $0.isDirectory }
        let showUninstall = isShowingApplications && !uninstallable.isEmpty

        openWithMenuItem?.isHidden = !showOpenWith
        openWithMenuItem?.isEnabled = showOpenWith
        if showOpenWith {
            rebuildOpenWithSubmenu()
        }

        let canCompare = !compareTargetURLs().isEmpty
        compareMenuItem?.isHidden = false
        rebuildCompareSubmenu()
        compareMenuItem?.isEnabled = canCompare

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
            case #selector(contextOpen):
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
            case #selector(contextCopyPath):
                item.isHidden = false
                item.isEnabled = true
            case #selector(contextRevealInEnclosingFolder):
                let canReveal = (isShowingSearchResults || isShowingHistory)
                    && selectedItems.contains(where: { !$0.isArchiveEntry })
                item.isHidden = !(isShowingSearchResults || isShowingHistory)
                item.isEnabled = canReveal
            case #selector(contextPutBack),
                 #selector(contextDeleteForever):
                item.isHidden = true
            case #selector(contextUninstallApps):
                item.isHidden = !showUninstall
                item.isEnabled = showUninstall
                item.title = uninstallable.count > 1
                    ? "彻底卸载（\(uninstallable.count)）…"
                    : "彻底卸载…"
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
        // .app / packages each have their own icon — cache by path, not extension.
        let key: String
        if item.isPackage || item.url.pathExtension.lowercased() == "app" {
            key = "\(item.url.path)@\(Int(size))"
        } else {
            let ext = item.url.pathExtension.lowercased()
            key = "\(ext.isEmpty ? "._file" : ext)@\(Int(size))"
        }
        if let cached = iconCache[key] {
            return cached
        }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: size, height: size)
        if iconCache.count < 512 {
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

        if id.rawValue == "check" {
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCheckCell()
            configureCheckColumnCell(cell, item: item, row: row, iconSide: iconSide)
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeListCell(id: id)
        cell.textField?.font = .systemFont(ofSize: fontSize)
        cell.alphaValue = 1

        switch id.rawValue {
        case "name":
            cell.textField?.attributedStringValue = attributedName(for: item)
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.textField?.maximumNumberOfLines = 1
            cell.textField?.usesSingleLineMode = true
            if let textCell = cell.textField?.cell as? NSTextFieldCell {
                textCell.wraps = false
                textCell.lineBreakMode = .byTruncatingMiddle
                textCell.truncatesLastVisibleLine = true
            }
            cell.imageView?.image = Self.cachedIcon(for: item, side: iconSide)
            cell.constraints.first(where: { $0.identifier == "iconW" })?.constant = iconSide
            cell.constraints.first(where: { $0.identifier == "iconH" })?.constant = iconSide
            let depth = rowDepths.indices.contains(row) ? rowDepths[row] : 0
            // Flatten tree indent in search results; show relative path instead.
            let indentStep = max(10, round(14 * zoomFactor))
            cell.constraints.first(where: { $0.identifier == "nameIndent" })?.constant =
                (isShowingSearchResults || isShowingHistory) ? 2 : (2 + CGFloat(depth) * indentStep)
            cell.imageView?.alphaValue = isItemCut(item) ? 0.45 : 1
            cell.toolTip = nil
            cell.textField?.toolTip = nil
            cell.imageView?.toolTip = nil
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
        if !isShowingApplications {
            refreshApplicationsBanner()
        }
        onSelectionChange?(selectedItems)
        syncQuickLookIfVisible()
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

    private func configureCheckColumnCell(
        _ cell: NSTableCellView,
        item: FileItem,
        row: Int,
        iconSide: CGFloat
    ) {
        guard let check = cell.subviews.first(where: { $0.identifier?.rawValue == "appCheck" }) as? NSButton else {
            return
        }
        let show = item.isPackage || item.isDirectory
        check.isHidden = !show
        check.isEnabled = show
        let side = max(16, round(iconSide))
        cell.constraints.first(where: { $0.identifier == "checkW" })?.constant = side
        cell.constraints.first(where: { $0.identifier == "checkH" })?.constant = side
        guard show else {
            check.state = .off
            return
        }
        check.controlSize = .regular
        check.tag = row
        check.target = self
        check.action = #selector(appCheckToggled(_:))
        check.state = checkedUninstallURLs.contains(item.url.standardizedFileURL) ? .on : .off
    }

    private func makeCheckCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("check")
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        check.identifier = NSUserInterfaceItemIdentifier("appCheck")
        check.translatesAutoresizingMaskIntoConstraints = false
        check.controlSize = .regular
        check.focusRingType = .none
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(check)
        let checkW = check.widthAnchor.constraint(equalToConstant: 18)
        checkW.identifier = "checkW"
        let checkH = check.heightAnchor.constraint(equalToConstant: 18)
        checkH.identifier = "checkH"
        NSLayoutConstraint.activate([
            check.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            checkW,
            checkH
        ])
        return cell
    }

    private func makeListCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.alignment = .left
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let textCell = field.cell as? NSTextFieldCell {
            textCell.wraps = false
            textCell.isScrollable = false
            textCell.lineBreakMode = .byTruncatingMiddle
            textCell.truncatesLastVisibleLine = true
        }
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
        if item.isDirectory { return "dir" }
        if item.isPackage { return "应用程序" }
        let ext = item.url.pathExtension
        if ext.isEmpty { return "文件" }
        return ext.lowercased()
    }
}

extension ContentViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !previewableURLs.isEmpty || !previewItems.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        refreshPreviewItems()
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        previewItems = []
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave Space to the panel so it can dismiss (Finder behavior).
        if event.keyCode == 49, flags.isEmpty {
            return false
        }
        // Arrow / Home / End / Page keys → move selection in the file list.
        let navKeys: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
        if navKeys.contains(event.keyCode), flags.isEmpty || flags == .shift {
            listView.keyDown(with: event)
            return true
        }
        return false
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
