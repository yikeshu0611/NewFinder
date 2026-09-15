import AppKit

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let settings = AppSettings.shared
    private var tabs: [BrowserTab] = []
    private var activeTabID: UUID!

    private var history: NavigationHistory {
        activeTab.history
    }

    private var activeTab: BrowserTab {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    private var chromeHeader: ChromeHeaderView!
    private var contentController: ContentViewController!
    private var activityMonitorController: ActivityMonitorViewController!
    private var temperatureController: TemperatureViewController!
    private var compareController: CompareViewController!
    private var statusBarView: NSView!
    private var favoritesSidebar: FavoritesSidebarViewController!
    private var mainSplitView: NSSplitView!
    private var pathBarContainer: NSView!
    private var pathField: NSTextField!
    private var breadcrumbClip: BreadcrumbClipView!
    private var breadcrumbStack: NSStackView!
    private var recentHistoryButton: NSButton!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    private var titlebarNewToolsStack: NSStackView!
    private var titlebarUtilityStack: NSStackView!
    private var showHiddenButton: NSButton!
    private var columnViewButton: NSButton!
    /// When Finder column view is on, New/paste target follows the selected column folder.
    private var columnViewTargetDirectory: URL?
    private var copyPathButton: NSButton!
    private var copyPathFlashToken = 0
    private var pathBookmarkButton: NSButton!
    private var pathTrailingStack: NSStackView!
    private var favoritesTrailingToolsStack: NSStackView!
    private var pathBarVisible = true
    private var statusLabel: NSTextField!
    private var autocompletePanel: NSPanel?
    private var autocompleteList: NSTableView?
    private var autocompleteCandidates: [String] = []
    private var isEditingPath = false
    private var pathEditClickMonitor: Any?
    private var favoritesKeyMonitor: Any?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var pendingSelectURLs: [URL] = []
    private var pendingRenameURL: URL?
    private var suppressDirectoryWatchUntil: Date?
    private var contentLoadGeneration = 0
    private var pendingReloadWorkItem: DispatchWorkItem?
    private var packageSizeWorkItem: DispatchWorkItem?
    private var searchField: NSSearchField!
    private var pathBarTopConstraint: NSLayoutConstraint!
    private var pathBarHeightConstraint: NSLayoutConstraint!
    private var statusBarHeightConstraint: NSLayoutConstraint!
    private var compareBottomToStatusConstraint: NSLayoutConstraint!
    private var compareBottomToColumnConstraint: NSLayoutConstraint!
    private var contentBottomToStatusConstraint: NSLayoutConstraint!
    private var amBottomToStatusConstraint: NSLayoutConstraint!
    private var tempBottomToStatusConstraint: NSLayoutConstraint!
    private var bookmarkEditorPanel: NSPanel?
    private weak var bookmarkFolderField: NSTextField?
    private weak var bookmarkFolderPicker: NSPopUpButton?
    private weak var bookmarkNameField: NSTextField?
    private weak var bookmarkPathField: NSTextField?
    private weak var bookmarkPlacementControl: NSSegmentedControl?
    private var favoritesTopBar: NSView!
    private var favoritesTopStack: NSStackView!
    private var favoritesTopBarHeightConstraint: NSLayoutConstraint!
    private var isApplyingFavoritesLayout = false
    private var editingBookmarkID: UUID?
    private var editingBookmarkPlacement: FavoritesPlacement = .left
    private var editingBookmarkFolderName: String?
    private var editingBookmarkFolderPlacement: FavoritesPlacement = .left

    /// Extra in-window browser columns (primary is always present; count is unlimited).
    private var columnSplitView: NSSplitView!
    private var primaryColumnHost: NSView!
    private var rightColumn: NSView!
    private var extraPanes: [BrowserPaneController] = []
    /// 0 = primary column; 1… = `extraPanes[index - 1]`.
    private var focusedColumnIndex = 0
    private weak var titlebarAddColumnButton: NSButton?
    private weak var titlebarCloseColumnButton: NSButton?
    private(set) var currentDirectory: URL {
        get { activeTab.directory }
        set { activeTab.directory = newValue.standardizedFileURL }
    }

    convenience init(directory: URL, select: [URL] = []) {
        let initial = directory.standardizedFileURL
        let tab = BrowserTab(directory: initial)
        self.init(tabs: [tab], activeID: tab.id, selectAfterLoad: select)
    }

    init(tabs: [BrowserTab], activeID: UUID, selectAfterLoad: [URL] = []) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = .zero
        window.contentMinSize = .zero
        // Keep only close; embed it in the trailing titlebar tools (macOS traffic-light style).
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.documentIconButton)?.isHidden = true
        // Follow the user when Chrome / Finder reveal a file on another Space.
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        super.init(window: window)
        window.delegate = self

        self.tabs = tabs
        self.activeTabID = activeID
        // Must be set before navigate → reloadContents captures pending selection.
        self.pendingSelectURLs = selectAfterLoad.map(\.standardizedFileURL)

        configureUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentTrash),
            name: .contentRequestTrash,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsWindowController.didChangeNotification,
            object: nil
        )
        if activeTab.isActivityMonitorTab {
            showActivityMonitorTab()
        } else if activeTab.isTemperatureTab {
            showTemperatureTab()
        } else if activeTab.isCompareTab {
            showCompareTab()
        } else if activeTab.isArchiveTab {
            updatePathChrome()
            reloadContents()
        } else {
            navigate(to: activeTab.directory, recordHistory: false)
        }
        refreshTabBar()
    }

    @objc private func handleContentTrash(_ note: Notification) {
        guard let sender = note.object as? ContentViewController else { return }
        if sender === contentController {
            focusedColumnIndex = 0
        } else if let idx = extraPanes.firstIndex(where: { $0.contentController === sender }) {
            focusedColumnIndex = idx + 1
        } else {
            return
        }
        moveToTrash(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI() {
        guard let window else { return }

        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        window.toolbar = nil

        chromeHeader = ChromeHeaderView()
        chromeHeader.translatesAutoresizingMaskIntoConstraints = false
        chromeHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chromeHeader.bind(target: self)
        chromeHeader.onSelectTab = { [weak self] id in self?.selectTab(id) }
        chromeHeader.onCloseTab = { [weak self] id in self?.closeTab(id) }
        chromeHeader.onNewTab = { [weak self] in self?.newTab(nil) }
        chromeHeader.onNewTabRelative = { [weak self] id, side in
            self?.newTab(relativeTo: id, side: side == .left ? .left : .right)
        }
        chromeHeader.onCloseTabsRelative = { [weak self] id, scope in
            switch scope {
            case .thisTab: self?.closeTabs(relativeTo: id, scope: .this)
            case .left: self?.closeTabs(relativeTo: id, scope: .left)
            case .right: self?.closeTabs(relativeTo: id, scope: .right)
            case .others: self?.closeTabs(relativeTo: id, scope: .others)
            }
        }
        chromeHeader.onDetachTab = { [weak self] id, screenPoint, sideBySide in
            self?.detachTabToNewWindow(id, screenPoint: screenPoint, sideBySide: sideBySide)
        }
        chromeHeader.onDoubleClickEmptyArea = { [weak self] in
            self?.toggleFillScreenFromTitlebar()
        }
        searchField = chromeHeader.searchFieldView

        pathBarContainer = ClickablePathBarView()
        pathBarContainer.translatesAutoresizingMaskIntoConstraints = false
        pathBarContainer.wantsLayer = true
        pathBarContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        (pathBarContainer as? ClickablePathBarView)?.onBackgroundClick = { [weak self] in
            guard let self else { return }
            self.focusedColumnIndex = 0
            if self.isEditingPath {
                self.endPathEditing(commit: false)
            } else {
                self.beginPathEditing()
            }
        }

        backButton = makePathBarNavButton(
            symbol: "chevron.left",
            tip: "后退",
            action: #selector(goBack(_:))
        )
        forwardButton = makePathBarNavButton(
            symbol: "chevron.right",
            tip: "前进",
            action: #selector(goForward(_:))
        )
        upButton = makePathBarNavButton(
            symbol: "chevron.up",
            tip: "上层文件夹 (⌘↑)",
            action: #selector(goEnclosingFolder(_:))
        )

        titlebarUtilityStack = makeTitlebarUtilityStack()
        columnViewButton = makeColumnViewButton()
        titlebarNewToolsStack = NSStackView()
        titlebarNewToolsStack.orientation = .horizontal
        titlebarNewToolsStack.alignment = .centerY
        titlebarNewToolsStack.spacing = 2
        titlebarNewToolsStack.translatesAutoresizingMaskIntoConstraints = false
        titlebarNewToolsStack.setContentHuggingPriority(.required, for: .horizontal)
        titlebarNewToolsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        recentHistoryButton = NSButton()
        recentHistoryButton.bezelStyle = .inline
        recentHistoryButton.isBordered = false
        let historyConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        recentHistoryButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "历史")?
            .withSymbolConfiguration(historyConfig)
        recentHistoryButton.image?.isTemplate = true
        recentHistoryButton.contentTintColor = .labelColor
        recentHistoryButton.toolTip = "最近打开的历史"
        recentHistoryButton.target = self
        recentHistoryButton.action = #selector(toggleHistoryPage(_:))
        recentHistoryButton.translatesAutoresizingMaskIntoConstraints = false
        recentHistoryButton.focusRingType = .none
        recentHistoryButton.setContentHuggingPriority(.required, for: .horizontal)
        recentHistoryButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
        recentHistoryButton.heightAnchor.constraint(equalToConstant: 20).isActive = true

        pathBookmarkButton = NSButton()
        pathBookmarkButton.bezelStyle = .inline
        pathBookmarkButton.isBordered = false
        pathBookmarkButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "收藏当前地址")
        pathBookmarkButton.image?.isTemplate = true
        pathBookmarkButton.contentTintColor = .labelColor
        pathBookmarkButton.toolTip = "收藏当前地址"
        pathBookmarkButton.target = self
        pathBookmarkButton.action = #selector(showBookmarkEditor(_:))
        pathBookmarkButton.translatesAutoresizingMaskIntoConstraints = false
        pathBookmarkButton.focusRingType = .none
        pathBookmarkButton.setContentHuggingPriority(.required, for: .horizontal)
        pathBookmarkButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        pathBookmarkButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        pathTrailingStack = NSStackView(views: [pathBookmarkButton, searchField])
        pathTrailingStack.orientation = .horizontal
        pathTrailingStack.spacing = 6
        pathTrailingStack.alignment = .centerY
        pathTrailingStack.translatesAutoresizingMaskIntoConstraints = false
        pathTrailingStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathTrailingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chromeMenuButton = chromeHeader.makeChromeMenuButton()
        let titlebarCloseButton = makeTitlebarCloseButton()
        let titlebarAddColumnButton = makeTitlebarAddColumnButton()
        let titlebarCloseColumnButton = makeTitlebarCloseColumnButton()

        // Favorites bar trailing: New… · 分栏视图 · 隐藏 · 历史 · 设置
        favoritesTrailingToolsStack = NSStackView(views: [
            titlebarNewToolsStack,
            columnViewButton,
            titlebarUtilityStack,
            recentHistoryButton,
            chromeMenuButton
        ])
        favoritesTrailingToolsStack.orientation = .horizontal
        favoritesTrailingToolsStack.alignment = .centerY
        favoritesTrailingToolsStack.spacing = 4
        favoritesTrailingToolsStack.translatesAutoresizingMaskIntoConstraints = false
        favoritesTrailingToolsStack.setContentHuggingPriority(.required, for: .horizontal)
        favoritesTrailingToolsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Tab bar trailing: 新增分栏 · 关闭分栏 · window close
        let titlebarCloseStack = NSStackView(views: [
            titlebarAddColumnButton,
            titlebarCloseColumnButton,
            titlebarCloseButton
        ])
        titlebarCloseStack.orientation = .horizontal
        titlebarCloseStack.alignment = .centerY
        titlebarCloseStack.spacing = 4
        titlebarCloseStack.translatesAutoresizingMaskIntoConstraints = false
        titlebarCloseStack.setContentHuggingPriority(.required, for: .horizontal)

        // Populate New after bind(target:) already ran.
        chromeHeader.attachNewTools(to: titlebarNewToolsStack)
        chromeHeader.attachLeadingTools(titlebarCloseStack)

        copyPathButton = NSButton()
        copyPathButton.bezelStyle = .inline
        copyPathButton.isBordered = false
        copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制路径")
        copyPathButton.image?.isTemplate = true
        copyPathButton.contentTintColor = .labelColor
        copyPathButton.toolTip = "复制路径 (⌘⇧C)"
        copyPathButton.target = self
        copyPathButton.action = #selector(copyPath(_:))
        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.focusRingType = .none

        breadcrumbStack = PassThroughStackView()
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.spacing = 2
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbStack.setHuggingPriority(.defaultHigh, for: .horizontal)
        breadcrumbStack.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)

        let breadcrumbClip = BreadcrumbClipView()
        breadcrumbClip.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbClip.wantsLayer = true
        breadcrumbClip.clipsToBounds = true
        breadcrumbClip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbClip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbClip.embed(breadcrumbStack)
        self.breadcrumbClip = breadcrumbClip

        pathField = NSTextField()
        pathField.placeholderString = "输入路径后回车前往，Esc 取消"
        pathField.isBordered = true
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.delegate = self
        pathField.isHidden = true
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pathBarContainer.addSubview(backButton)
        pathBarContainer.addSubview(forwardButton)
        pathBarContainer.addSubview(upButton)
        pathBarContainer.addSubview(copyPathButton)
        pathBarContainer.addSubview(breadcrumbClip)
        pathBarContainer.addSubview(pathField)
        pathBarContainer.addSubview(pathTrailingStack)
        pathBarContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentController = ContentViewController()
        contentController.onOpen = { [weak self] item in
            guard let self else { return }
            if self.contentController.isShowingHistory {
                self.openHistoryURL(item.url)
            } else {
                self.openItem(item)
            }
        }
        contentController.onSelectionChange = { [weak self] items in
            self?.focusedColumnIndex = 0
            self?.updateStatus(selection: items)
        }
        contentController.onViewModeChange = { [weak self] isColumn in
            self?.syncColumnViewButton(isColumn)
            if !isColumn {
                self?.columnViewTargetDirectory = nil
            }
        }
        contentController.onColumnViewDirectoryChange = { [weak self] url in
            self?.columnViewTargetDirectory = url.standardizedFileURL
            self?.updateStatus(selection: self?.contentController.selectedItems ?? [])
        }
        contentController.onRenameRequest = { [weak self] item in
            self?.contentController.beginInlineRename(item)
        }
        contentController.onCutRequest = { [weak self] in
            self?.cut(nil)
        }
        contentController.onCopyRequest = { [weak self] in
            self?.copy(nil)
        }
        contentController.onPasteRequest = { [weak self] in
            self?.paste(nil)
        }
        contentController.onGoEnclosingFolder = { [weak self] in
            self?.goEnclosingFolder(nil)
        }
        contentController.onToggleFavoritesSidebar = { [weak self] in
            self?.toggleFavoritesSidebar(nil)
        }
        contentController.onToggleFavoritesTopBar = { [weak self] in
            self?.toggleFavoritesTopBar(nil)
        }
        contentController.onCopyPathRequest = { [weak self] in
            self?.copyPath(nil)
        }
        contentController.onCommitRename = { [weak self] item, newName in
            self?.commitRename(item, to: newName)
        }
        contentController.onDirectoryNeedsReload = { [weak self] in
            self?.reloadAfterMutation()
        }
        contentController.onOpenArchives = { [weak self] urls in
            self?.openArchivesInTabs(urls)
        }
        contentController.directoryForDrop = { [weak self] in
            self?.currentDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        contentController.onPerformFileDrop = { [weak self] urls, destination, copying in
            self?.handleFileDrop(urls: urls, destination: destination, copying: copying)
        }
        contentController.onClearSearch = { [weak self] in
            self?.searchField.stringValue = ""
            self?.contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
            self?.reloadContents()
        }
        contentController.onClearOpenHistory = { [weak self] in
            self?.clearRecentOpenHistory(nil)
        }
        contentController.onDismissHistoryPage = { [weak self] in
            self?.closeHistoryPage()
        }
        contentController.onRevealInEnclosingFolder = { [weak self] url in
            guard let self else { return }
            let target = url.standardizedFileURL
            self.suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
            self.pendingSelectURLs = [target]
            self.navigate(to: target.deletingLastPathComponent())
        }
        contentController.onEmptyTrash = { [weak self] in
            self?.emptyTrash(nil)
        }
        contentController.onPutBackFromTrash = { [weak self] in
            self?.putBackFromTrash(nil)
        }
        contentController.onDeleteFromTrash = { [weak self] in
            self?.deleteForeverFromTrash(nil)
        }
        contentController.onUninstallApps = { [weak self] in
            self?.uninstallSelectedApps(nil)
        }
        contentController.view.translatesAutoresizingMaskIntoConstraints = false

        favoritesSidebar = FavoritesSidebarViewController()
        favoritesSidebar.onOpenBookmark = { [weak self] bookmark in
            self?.navigate(to: URL(fileURLWithPath: bookmark.path))
        }
        favoritesSidebar.onEditBookmark = { [weak self] bookmark in
            self?.presentBookmarkEditor(for: bookmark, preferredPlacement: .left)
        }
        favoritesSidebar.onRemoveBookmark = { [weak self] bookmark in
            self?.removeBookmark(id: bookmark.id)
        }
        favoritesSidebar.onRenameFolder = { [weak self] folder in
            self?.showBookmarkFolderEditor(folder, placement: .left)
        }
        favoritesSidebar.onDeleteFolder = { [weak self] folder in
            self?.deleteBookmarkFolder(folder, placement: .left)
        }
        favoritesSidebar.onAddCurrentToFolder = { [weak self] folder in
            self?.addCurrentDirectoryToFolder(folder, placement: .left)
        }
        _ = favoritesSidebar.view
        // Titlebar cluster is hosted on the window root (same row as the close button).

        let rightColumn = NSView()
        self.rightColumn = rightColumn
        // NSSplitView manages child frames; keep autoresizing masks on.

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusBar.addSubview(statusLabel)
        statusBarView = statusBar

        let primaryHost = NSView()
        primaryColumnHost = primaryHost
        primaryHost.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        primaryHost.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)

        // Primary browser column: path + files + status (chrome + favorites sit above).
        pathBarContainer.translatesAutoresizingMaskIntoConstraints = false
        primaryHost.addSubview(pathBarContainer)
        primaryHost.addSubview(contentController.view)

        activityMonitorController = ActivityMonitorViewController()
        activityMonitorController.onSummaryChange = { [weak self] text in
            self?.statusLabel.stringValue = text
        }
        let amView = activityMonitorController.view
        amView.translatesAutoresizingMaskIntoConstraints = false
        amView.isHidden = true
        primaryHost.addSubview(amView)

        temperatureController = TemperatureViewController()
        temperatureController.onSummaryChange = { [weak self] text in
            self?.statusLabel.stringValue = text
        }
        let tempView = temperatureController.view
        tempView.translatesAutoresizingMaskIntoConstraints = false
        tempView.isHidden = true
        primaryHost.addSubview(tempView)

        compareController = CompareViewController()
        compareController.onSummaryChange = { [weak self] text in
            self?.statusLabel.stringValue = text
        }
        let compareView = compareController.view
        compareView.translatesAutoresizingMaskIntoConstraints = false
        compareView.isHidden = true
        primaryHost.addSubview(compareView)

        primaryHost.addSubview(statusBar)

        let columnSplit = NSSplitView()
        columnSplit.isVertical = true
        columnSplit.dividerStyle = .thin
        columnSplit.translatesAutoresizingMaskIntoConstraints = false
        columnSplit.arrangesAllSubviews = true
        columnSplit.delegate = self
        columnSplit.addSubview(primaryHost)
        columnSplitView = columnSplit

        rightColumn.addSubview(columnSplit)

        pathBarTopConstraint = pathBarContainer.topAnchor.constraint(equalTo: primaryHost.topAnchor)
        pathBarHeightConstraint = pathBarContainer.heightAnchor.constraint(equalToConstant: 29)
        statusBarHeightConstraint = statusBar.heightAnchor.constraint(equalToConstant: 22)
        contentBottomToStatusConstraint = contentController.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        amBottomToStatusConstraint = amView.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        tempBottomToStatusConstraint = tempView.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        compareBottomToStatusConstraint = compareView.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        compareBottomToColumnConstraint = compareView.bottomAnchor.constraint(equalTo: primaryHost.bottomAnchor)
        compareBottomToColumnConstraint.isActive = false

        NSLayoutConstraint.activate([
            columnSplit.topAnchor.constraint(equalTo: rightColumn.topAnchor),
            columnSplit.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            columnSplit.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
            columnSplit.bottomAnchor.constraint(equalTo: rightColumn.bottomAnchor),

            pathBarTopConstraint,
            pathBarContainer.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            pathBarContainer.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            pathBarHeightConstraint,

            backButton.leadingAnchor.constraint(equalTo: pathBarContainer.leadingAnchor, constant: 6),
            backButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 20),
            backButton.heightAnchor.constraint(equalToConstant: 20),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 20),
            forwardButton.heightAnchor.constraint(equalToConstant: 20),

            upButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            upButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 20),
            upButton.heightAnchor.constraint(equalToConstant: 20),

            copyPathButton.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 6),
            copyPathButton.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            copyPathButton.widthAnchor.constraint(equalToConstant: 22),
            copyPathButton.heightAnchor.constraint(equalToConstant: 22),

            breadcrumbClip.leadingAnchor.constraint(equalTo: copyPathButton.trailingAnchor, constant: 6),
            breadcrumbClip.trailingAnchor.constraint(equalTo: pathTrailingStack.leadingAnchor, constant: -8),
            breadcrumbClip.topAnchor.constraint(equalTo: pathBarContainer.topAnchor),
            breadcrumbClip.bottomAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),

            pathField.leadingAnchor.constraint(equalTo: copyPathButton.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: pathTrailingStack.leadingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            pathField.heightAnchor.constraint(equalToConstant: 22),

            pathTrailingStack.trailingAnchor.constraint(equalTo: pathBarContainer.trailingAnchor, constant: -8),
            pathTrailingStack.centerYAnchor.constraint(equalTo: pathBarContainer.centerYAnchor),
            pathTrailingStack.heightAnchor.constraint(equalToConstant: 22),

            contentController.view.topAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
            contentController.view.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            contentController.view.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            contentBottomToStatusConstraint,

            amView.topAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
            amView.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            amView.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            amBottomToStatusConstraint,

            tempView.topAnchor.constraint(equalTo: pathBarContainer.bottomAnchor),
            tempView.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            tempView.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            tempBottomToStatusConstraint,

            compareView.topAnchor.constraint(equalTo: primaryHost.topAnchor),
            compareView.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            compareView.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            compareBottomToStatusConstraint,

            statusBar.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: primaryHost.bottomAnchor),
            statusBarHeightConstraint,

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])

        mainSplitView = NSSplitView()
        mainSplitView.isVertical = true
        mainSplitView.dividerStyle = .thin
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.delegate = self

        chromeHeader.translatesAutoresizingMaskIntoConstraints = false
        chromeHeader.attachNewTools(to: titlebarNewToolsStack)

        favoritesTopBar = NSView()
        favoritesTopBar.translatesAutoresizingMaskIntoConstraints = false
        favoritesTopBar.wantsLayer = true
        favoritesTopBar.clipsToBounds = true
        updateFavoritesTopBarAppearance()

        favoritesTopStack = NSStackView()
        favoritesTopStack.orientation = .horizontal
        favoritesTopStack.alignment = .centerY
        favoritesTopStack.spacing = 8
        favoritesTopStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        favoritesTopStack.translatesAutoresizingMaskIntoConstraints = false
        favoritesTopStack.setHuggingPriority(.required, for: .horizontal)
        favoritesTopStack.setContentHuggingPriority(.required, for: .horizontal)
        favoritesTopBar.addSubview(favoritesTopStack)
        favoritesTopBar.addSubview(favoritesTrailingToolsStack)

        // Right of the window-level sidebar: tabs + favorites bar + browser content.
        let mainColumn = NSView()
        rightColumn.translatesAutoresizingMaskIntoConstraints = false
        mainColumn.addSubview(chromeHeader)
        mainColumn.addSubview(favoritesTopBar)
        mainColumn.addSubview(rightColumn)

        favoritesSidebar.view.frame = NSRect(x: 0, y: 0, width: settings.favoritesSidebarWidth, height: 700)
        mainColumn.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        mainSplitView.addSubview(favoritesSidebar.view)
        mainSplitView.addSubview(mainColumn)
        // Sidebar keeps its width; content column absorbs window resize.
        mainSplitView.setHoldingPriority(NSLayoutConstraint.Priority(270), forSubviewAt: 0)
        mainSplitView.setHoldingPriority(NSLayoutConstraint.Priority(249), forSubviewAt: 1)

        root.addSubview(mainSplitView)

        favoritesTopBarHeightConstraint = favoritesTopBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            mainSplitView.topAnchor.constraint(equalTo: root.topAnchor),
            mainSplitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mainSplitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mainSplitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            chromeHeader.topAnchor.constraint(equalTo: mainColumn.topAnchor),
            chromeHeader.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            chromeHeader.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            chromeHeader.heightAnchor.constraint(equalToConstant: 32),

            favoritesTopBar.topAnchor.constraint(equalTo: chromeHeader.bottomAnchor),
            favoritesTopBar.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            favoritesTopBar.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            favoritesTopBarHeightConstraint,

            favoritesTopStack.leadingAnchor.constraint(equalTo: favoritesTopBar.leadingAnchor, constant: 8),
            favoritesTopStack.trailingAnchor.constraint(
                lessThanOrEqualTo: favoritesTrailingToolsStack.leadingAnchor,
                constant: -8
            ),
            favoritesTopStack.centerYAnchor.constraint(equalTo: favoritesTopBar.centerYAnchor),
            favoritesTopStack.heightAnchor.constraint(equalTo: favoritesTopBar.heightAnchor),

            favoritesTrailingToolsStack.trailingAnchor.constraint(
                equalTo: favoritesTopBar.trailingAnchor,
                constant: -10
            ),
            favoritesTrailingToolsStack.centerYAnchor.constraint(equalTo: favoritesTopBar.centerYAnchor),
            favoritesTrailingToolsStack.heightAnchor.constraint(equalToConstant: 24),

            rightColumn.topAnchor.constraint(equalTo: favoritesTopBar.bottomAnchor),
            rightColumn.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            rightColumn.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            rightColumn.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor)
        ])

        updatePathChrome()
        applyContentZoom(settings.uiZoomPercent)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyFavoritesLayout(animated: false)
        }
        NotificationCenter.default.addObserver(
            forName: .uiZoomDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applyContentZoom(self.settings.uiZoomPercent)
        }
        installFavoritesKeyMonitor()
    }

    /// Accessory apps don't reliably deliver hidden-menu key equivalents; handle ⌘O / ⌘⇧O / ⌘W directly.
    private func installFavoritesKeyMonitor() {
        if let favoritesKeyMonitor {
            NSEvent.removeMonitor(favoritesKeyMonitor)
            self.favoritesKeyMonitor = nil
        }
        favoritesKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased()

            let isW = event.keyCode == 13 || chars == "w"
            if isW, flags == .command {
                self.closeActiveTabOrWindow(nil)
                return nil
            }

            let isO = event.keyCode == 31 || chars == "o"
            guard isO else { return event }
            if flags == [.command, .shift] {
                self.toggleFavoritesTopBar(nil)
                return nil
            }
            if flags == .command {
                self.toggleFavoritesSidebar(nil)
                return nil
            }
            return event
        }
    }

    private func applySidebarWidth(_ width: CGFloat) {
        guard let split = mainSplitView else { return }
        let total = split.bounds.width
        guard total > 1 else { return }
        let maxWidth = max(0, total - 120)
        let clamped = min(maxWidth, max(0, width))
        isApplyingFavoritesLayout = true
        split.setPosition(clamped, ofDividerAt: 0)
        isApplyingFavoritesLayout = false
    }

    private func applySidebarVisibility(animated: Bool) {
        applyFavoritesLayout(animated: animated)
    }

    private func applyFavoritesLayout(animated: Bool) {
        guard let split = mainSplitView else { return }
        let showLeft = settings.favoritesSidebarVisible
        let showTop = settings.favoritesTopBarVisible

        let apply = {
            self.isApplyingFavoritesLayout = true
            defer { self.isApplyingFavoritesLayout = false }

            self.favoritesSidebar.view.isHidden = !showLeft
            if showLeft {
                let width = max(0, self.settings.favoritesSidebarWidth)
                let total = split.bounds.width
                if total > 1 {
                    let maxWidth = max(0, total - 120)
                    let clamped = min(maxWidth, width)
                    split.setPosition(clamped, ofDividerAt: 0)
                }
            } else {
                split.setPosition(0, ofDividerAt: 0)
            }

            self.favoritesTopBar.isHidden = !showTop
            self.favoritesTopBarHeightConstraint.constant = showTop ? 29 : 0
            if showTop {
                self.reloadFavoritesTopBar()
            }
            self.updateFavoritesTopBarAppearance()

            split.adjustSubviews()
            self.window?.contentView?.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    @objc func toggleFavoritesSidebar(_ sender: Any?) {
        let opening = !settings.favoritesSidebarVisible
        settings.favoritesSidebarVisible.toggle()
        if opening, settings.favoritesSidebarWidth < 10 {
            settings.favoritesSidebarWidth = 100
        }
        applyFavoritesLayout(animated: true)
    }

    @objc func toggleFavoritesTopBar(_ sender: Any?) {
        settings.favoritesTopBarVisible.toggle()
        applyFavoritesLayout(animated: true)
    }

    /// Favorites bar uses the system window background (pre-tweak look).
    private func updateFavoritesTopBarAppearance() {
        guard favoritesTopBar != nil else { return }
        favoritesTopBar.effectiveAppearance.performAsCurrentDrawingAppearance {
            favoritesTopBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private var titlebarCloseHost: NSView?
    /// Frame before double-click maximize; restored on the next double-click.
    private var frameBeforeFillScreen: NSRect?

    func windowDidBecomeKey(_ notification: Notification) {
        restoreFavoritesSidebarWidthIfNeeded()
        hideSystemTrafficLights()
        updateFavoritesTopBarAppearance()
        (titlebarCloseHost as? MacStyleCloseButton)?.refreshAppearance()
    }

    func windowDidResignKey(_ notification: Notification) {
        hideSystemTrafficLights()
        (titlebarCloseHost as? MacStyleCloseButton)?.refreshAppearance()
    }

    func windowDidResize(_ notification: Notification) {
        restoreFavoritesSidebarWidthIfNeeded()
        hideSystemTrafficLights()
        clearFillScreenMemoryIfManuallyResized()
    }

    func windowDidUpdate(_ notification: Notification) {
        // AppKit periodically re-shows / repositions the native traffic lights.
        hideSystemTrafficLights()
    }

    /// Keep native traffic lights invisible — we use a trailing Mac-style close instead.
    private func hideSystemTrafficLights() {
        guard let window else { return }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            if !button.isHidden { button.isHidden = true }
            if button.alphaValue != 0 { button.alphaValue = 0 }
        }
    }

    /// Double-click empty titlebar chrome: fill the screen, or restore previous size.
    private func toggleFillScreenFromTitlebar() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        if isFilledToScreen {
            if let previous = frameBeforeFillScreen {
                window.setFrame(previous, display: true, animate: true)
            } else if let screen = window.screen {
                var frame = window.frame
                frame.size = NSSize(
                    width: min(1100, screen.visibleFrame.width * 0.85),
                    height: min(700, screen.visibleFrame.height * 0.85)
                )
                frame.origin.x = screen.visibleFrame.midX - frame.width / 2
                frame.origin.y = screen.visibleFrame.midY - frame.height / 2
                window.setFrame(frame, display: true, animate: true)
            }
            frameBeforeFillScreen = nil
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        frameBeforeFillScreen = window.frame
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    private var isFilledToScreen: Bool {
        guard let window, let screen = window.screen else { return false }
        let visible = screen.visibleFrame
        let frame = window.frame
        return abs(frame.minX - visible.minX) < 6
            && abs(frame.minY - visible.minY) < 6
            && abs(frame.width - visible.width) < 6
            && abs(frame.height - visible.height) < 6
    }

    private func clearFillScreenMemoryIfManuallyResized() {
        guard let previous = frameBeforeFillScreen,
              let window,
              let screen = window.screen,
              !isFilledToScreen else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let nearPrevious = abs(frame.width - previous.width) < 8
            && abs(frame.height - previous.height) < 8
        let nearFill = abs(frame.width - visible.width) < 8
            && abs(frame.height - visible.height) < 8
        if !nearPrevious && !nearFill {
            frameBeforeFillScreen = nil
        }
    }

    /// Trailing Mac traffic-light close (custom — system button keeps jumping back to the leading titlebar).
    private func makeTitlebarCloseButton() -> NSView {
        let button = MacStyleCloseButton()
        button.target = self
        button.action = #selector(closeWindowFromTitlebar(_:))
        button.toolTip = "关闭"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20)
        ])
        titlebarCloseHost = button
        hideSystemTrafficLights()
        return button
    }

    /// 新增分栏 — append another in-window browser column (unlimited).
    private func makeTitlebarAddColumnButton() -> NSView {
        let button = makeTitlebarColumnToolButton(
            symbol: "plus.rectangle.on.rectangle",
            tip: "新增分栏",
            action: #selector(addBrowserColumn(_:))
        )
        titlebarAddColumnButton = button
        return button
    }

    /// 关闭分栏 — remove the focused extra column (or the last one if primary is focused).
    private func makeTitlebarCloseColumnButton() -> NSView {
        let button = makeTitlebarColumnToolButton(
            symbol: "minus.rectangle",
            tip: "关闭分栏",
            action: #selector(closeBrowserColumn(_:))
        )
        titlebarCloseColumnButton = button
        updateColumnButtonAppearance()
        return button
    }

    private func makeTitlebarColumnToolButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.image?.isTemplate = true
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20)
        ])
        return button
    }

    @objc private func addBrowserColumn(_ sender: Any?) {
        if activeTab.isSpecialContentTab {
            NSSound.beep()
            return
        }
        let seed = directoryForNewBrowserColumn()
        let pane = BrowserPaneController(directory: seed)
        wireExtraPane(pane)
        extraPanes.append(pane)
        _ = pane.view
        pane.view.translatesAutoresizingMaskIntoConstraints = true
        pane.view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        pane.view.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        pane.applyZoom(settings.uiZoomPercent)
        columnSplitView.addSubview(pane.view)
        focusedColumnIndex = extraPanes.count
        updateColumnButtonAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.equalizeColumnWidths()
        }
    }

    @objc private func closeBrowserColumn(_ sender: Any?) {
        guard !extraPanes.isEmpty else {
            NSSound.beep()
            return
        }
        let removeIndex: Int
        if focusedColumnIndex > 0 {
            removeIndex = focusedColumnIndex - 1
        } else {
            removeIndex = extraPanes.count - 1
        }
        guard extraPanes.indices.contains(removeIndex) else {
            NSSound.beep()
            return
        }
        let pane = extraPanes.remove(at: removeIndex)
        pane.view.removeFromSuperview()
        if focusedColumnIndex > removeIndex + 1 {
            focusedColumnIndex -= 1
        } else if focusedColumnIndex == removeIndex + 1 {
            focusedColumnIndex = min(removeIndex, extraPanes.count)
        }
        if focusedColumnIndex > extraPanes.count {
            focusedColumnIndex = extraPanes.count
        }
        updateColumnButtonAppearance()
        DispatchQueue.main.async { [weak self] in
            self?.equalizeColumnWidths()
        }
    }

    /// Used when switching to special tabs that need the primary column full-width.
    private func clearAllExtraColumns() {
        guard !extraPanes.isEmpty else {
            focusedColumnIndex = 0
            updateColumnButtonAppearance()
            return
        }
        for pane in extraPanes {
            pane.view.removeFromSuperview()
        }
        extraPanes.removeAll()
        focusedColumnIndex = 0
        updateColumnButtonAppearance()
        columnSplitView?.adjustSubviews()
    }

    private func equalizeColumnWidths() {
        guard let split = columnSplitView, split.bounds.width > 1 else { return }
        let n = split.subviews.count
        guard n >= 2 else {
            split.adjustSubviews()
            return
        }
        let each = split.bounds.width / CGFloat(n)
        for i in 0 ..< (n - 1) {
            split.setPosition(each * CGFloat(i + 1), ofDividerAt: i)
        }
        split.adjustSubviews()
    }

    private func updateColumnButtonAppearance() {
        let canClose = !extraPanes.isEmpty
        titlebarCloseColumnButton?.isEnabled = canClose
        titlebarCloseColumnButton?.contentTintColor = canClose ? .secondaryLabelColor : .tertiaryLabelColor
        titlebarAddColumnButton?.contentTintColor = .secondaryLabelColor
    }

    private func wireExtraPane(_ pane: BrowserPaneController) {
        pane.onFocus = { [weak self, weak pane] in
            guard let self, let pane,
                  let idx = self.extraPanes.firstIndex(where: { $0 === pane }) else { return }
            self.focusedColumnIndex = idx + 1
        }
        pane.onOpenFile = { url in
            if DMGInstallSupport.isDiskImage(url) {
                _ = AppDelegate.shared.openDiskImage(url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        pane.onOpenArchives = { [weak self] urls in
            self?.focusedColumnIndex = 0
            self?.openArchivesInTabs(urls)
        }
        pane.onCutRequest = { [weak self, weak pane] in
            self?.focusExtraPane(pane)
            self?.cut(nil)
        }
        pane.onCopyRequest = { [weak self, weak pane] in
            self?.focusExtraPane(pane)
            self?.copy(nil)
        }
        pane.onPasteRequest = { [weak self, weak pane] in
            self?.focusExtraPane(pane)
            self?.paste(nil)
        }
        pane.onRenameCommit = { [weak self, weak pane] item, name in
            self?.focusExtraPane(pane)
            self?.commitRename(item, to: name)
        }
        pane.onDirectoryNeedsReload = { [weak self] in
            self?.reloadContents(preservingOutline: true)
            self?.reloadAllExtraPanes()
        }
        pane.onPerformFileDrop = { [weak self] urls, destination, copying in
            self?.handleFileDrop(urls: urls, destination: destination, copying: copying)
        }
        pane.onBookmarkDirectory = { [weak self] url in
            guard let self else { return }
            let previous = self.currentDirectory
            self.currentDirectory = url
            self.showBookmarkEditor(nil)
            self.currentDirectory = previous
        }
        pane.onCopyPath = { [weak self] selected, folder in
            let urls = selected.isEmpty ? [folder] : selected
            let text = urls.map(\.path).joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self?.flashCopyPathSuccess()
        }
        pane.onToggleFavoritesSidebar = { [weak self] in self?.toggleFavoritesSidebar(nil) }
        pane.onToggleFavoritesTopBar = { [weak self] in self?.toggleFavoritesTopBar(nil) }
    }

    private func focusExtraPane(_ pane: BrowserPaneController?) {
        guard let pane, let idx = extraPanes.firstIndex(where: { $0 === pane }) else { return }
        focusedColumnIndex = idx + 1
    }

    private func directoryForNewBrowserColumn() -> URL {
        // Prefer the selected folder so “新增分栏” opens into it.
        if let folder = selectedDirectoryURL(in: activeContentController) {
            return folder
        }
        if let focused = focusedExtraPane() {
            return focused.directory.standardizedFileURL
        }
        let tab = activeTab
        if tab.isSpecialContentTab {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
                .standardizedFileURL
        }
        return tab.directory.standardizedFileURL
    }

    /// First selected real folder (not package / archive entry), if any.
    private func selectedDirectoryURL(in content: ContentViewController) -> URL? {
        content.selectedItems.first {
            $0.isDirectory && !$0.isPackage && !$0.isArchiveEntry
        }?.url.standardizedFileURL
    }

    private func focusedExtraPane() -> BrowserPaneController? {
        guard focusedColumnIndex > 0 else { return nil }
        let i = focusedColumnIndex - 1
        guard extraPanes.indices.contains(i) else { return nil }
        return extraPanes[i]
    }

    private func reloadAllExtraPanes() {
        for pane in extraPanes {
            pane.reloadContents()
        }
    }

    /// Content list for the focused column (copy/cut/paste/delete).
    private var activeContentController: ContentViewController {
        focusedExtraPane()?.contentController ?? contentController
    }

    private var activeBrowserDirectory: URL {
        if focusedColumnIndex == 0,
           contentController.isColumnView,
           let target = columnViewTargetDirectory {
            return target
        }
        if let pane = focusedExtraPane() {
            return pane.directory
        }
        return currentDirectory
    }

    @objc private func closeWindowFromTitlebar(_ sender: Any?) {
        guard let window else { return }
        // performClose can no-op if AppKit thinks the (hidden) system close is disabled;
        // close() always dismisses our accessory-style browser window.
        window.close()
    }

    /// Keep the remembered sidebar width after layout / window resize.
    private func restoreFavoritesSidebarWidthIfNeeded() {
        guard !isApplyingFavoritesLayout else { return }
        guard settings.favoritesSidebarVisible,
              favoritesSidebar?.view.isHidden == false,
              let split = mainSplitView,
              split.bounds.width > 1,
              let current = split.subviews.first?.bounds.width else { return }
        let target = max(0, settings.favoritesSidebarWidth)
        guard abs(current - target) > 2 else { return }
        applySidebarWidth(target)
    }

    private func reloadFavoritesTopBar() {
        guard favoritesTopStack != nil else { return }
        favoritesTopStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Direct bar links first (Chrome bookmark bar), then real folders.
        for bookmark in settings.rootBookmarks(in: .top) {
            let button = BookmarkFolderButton(frame: .zero)
            button.title = bookmark.name
            button.bookmarkID = bookmark.id
            button.bookmarkPath = bookmark.path
            button.toolTip = bookmark.path
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.onClick = { [weak self] in
                let url = URL(fileURLWithPath: (bookmark.path as NSString).expandingTildeInPath)
                    .standardizedFileURL
                self?.navigate(to: url)
            }
            button.onRightClick = { [weak self] in
                self?.presentBookmarkEditor(for: bookmark, preferredPlacement: .top)
            }
            button.onOrderChanged = { [weak self] in
                self?.persistTopFavoritesBarOrder()
            }
            favoritesTopStack.addArrangedSubview(button)
        }

        for folder in settings.orderedBookmarkFolders(for: .top) {
            let button = BookmarkFolderButton(frame: .zero)
            button.title = folder
            button.folderName = folder
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                DispatchQueue.main.async {
                    self.showTopFavoritesFolderMenu(button.folderName, from: button)
                }
            }
            button.onRightClick = { [weak self] in
                self?.showBookmarkFolderEditor(folder, placement: .top)
            }
            button.onOrderChanged = { [weak self] in
                self?.persistTopFavoritesBarOrder()
            }
            favoritesTopStack.addArrangedSubview(button)
        }
    }

    private func persistTopFavoritesBarOrder() {
        var folderOrder: [String] = []
        var rootIDs: [UUID] = []
        for view in favoritesTopStack.arrangedSubviews {
            guard let button = view as? BookmarkFolderButton else { continue }
            if let id = button.bookmarkID {
                rootIDs.append(id)
            } else if !button.folderName.isEmpty {
                folderOrder.append(button.folderName)
            }
        }
        settings.topBookmarkFolderOrder = folderOrder

        guard !rootIDs.isEmpty else { return }
        var byID = Dictionary(
            uniqueKeysWithValues: settings.bookmarks
                .filter { $0.placement == .top && AppSettings.isFavoritesBarFolder($0.folder) }
                .map { ($0.id, $0) }
        )
        var reorderedRoot: [Bookmark] = []
        for id in rootIDs {
            if var item = byID.removeValue(forKey: id) {
                item.folder = ""
                reorderedRoot.append(item)
            }
        }
        reorderedRoot.append(contentsOf: byID.values.map { item in
            var copy = item
            copy.folder = ""
            return copy
        })

        var result: [Bookmark] = []
        var inserted = false
        for bookmark in settings.bookmarks {
            if bookmark.placement == .top && AppSettings.isFavoritesBarFolder(bookmark.folder) {
                if !inserted {
                    result.append(contentsOf: reorderedRoot)
                    inserted = true
                }
            } else {
                result.append(bookmark)
            }
        }
        if !inserted {
            result.append(contentsOf: reorderedRoot)
        }
        settings.bookmarks = result
    }

    private func showTopFavoritesFolderMenu(_ folder: String, from source: NSView) {
        let bookmarks = settings.bookmarks(in: folder, placement: .top)
        let menu = NSMenu(title: folder)
        let itemFont = NSFont.systemFont(ofSize: 13)
        let rowWidth = max(
            160,
            ceil(
                (bookmarks.map { ($0.name as NSString).size(withAttributes: [.font: itemFont]).width }.max() ?? 80) + 24
            )
        )

        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: "暂无收藏", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for bookmark in bookmarks {
                let item = NSMenuItem(title: bookmark.name, action: nil, keyEquivalent: "")
                let row = BookmarkMenuRowView(
                    title: bookmark.name,
                    path: bookmark.path,
                    font: itemFont,
                    width: rowWidth
                )
                row.onOpen = { [weak self, weak menu] in
                    menu?.cancelTracking()
                    let url = URL(fileURLWithPath: (bookmark.path as NSString).expandingTildeInPath)
                        .standardizedFileURL
                    DispatchQueue.main.async {
                        self?.navigate(to: url)
                    }
                }
                row.onEdit = { [weak self, weak menu] in
                    menu?.cancelTracking()
                    DispatchQueue.main.async {
                        self?.presentBookmarkEditor(for: bookmark, preferredPlacement: .top)
                    }
                }
                item.view = row
                menu.addItem(item)
            }
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: source.bounds.height + 4), in: source)
    }

    private func makePathBarNavButton(symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Finder column-view toggle (分栏): click folder → next column on the right.
    private func makeColumnViewButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(
            systemSymbolName: "rectangle.split.3x1",
            accessibilityDescription: "分栏视图"
        )?.withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = .labelColor
        button.toolTip = "分栏视图（点击文件夹在右侧打开）"
        button.target = self
        button.action = #selector(toggleColumnView(_:))
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 20)
        ])
        return button
    }

    @objc private func toggleColumnView(_ sender: Any?) {
        if activeTab.isSpecialContentTab || activeTab.isArchiveTab {
            NSSound.beep()
            return
        }

        if contentController.isColumnView {
            contentController.setColumnViewEnabled(false)
            columnViewTargetDirectory = nil
            return
        }

        // Keep current directory as the column-view root. Reveal the current selection so a
        // selected folder opens in the next column (do not navigate into / “open” it).
        let selected = contentController.selectedItems.first
        let revealURL = selected.map(\.url.standardizedFileURL)
        contentController.setColumnViewEnabled(true, reveal: revealURL)
        if let item = selected, item.isDirectory, !item.isPackage {
            columnViewTargetDirectory = item.url.standardizedFileURL
        } else {
            columnViewTargetDirectory = currentDirectory.standardizedFileURL
        }
    }

    private func syncColumnViewButton(_ isColumn: Bool) {
        columnViewButton?.contentTintColor = isColumn ? .controlAccentColor : .labelColor
        columnViewButton?.toolTip = isColumn ? "列表视图" : "分栏视图（点击文件夹在右侧打开）"
    }

    private func makeTitlebarUtilityStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        showHiddenButton = makePathBarNavButton(
            symbol: settings.showHiddenFiles ? "dot.circle.fill" : "dot.circle",
            tip: settings.showHiddenFiles ? "隐藏隐藏项 (⌘.)" : "显示隐藏项 (⌘.)",
            action: #selector(toggleHiddenFiles(_:))
        )
        showHiddenButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        showHiddenButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if settings.showHiddenFiles {
            showHiddenButton.contentTintColor = .controlAccentColor
        }
        stack.addArrangedSubview(showHiddenButton)
        return stack
    }

    private func syncShowHiddenFilesButton(_ showHidden: Bool) {
        let symbol = showHidden ? "dot.circle.fill" : "dot.circle"
        showHiddenButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: showHidden ? "隐藏隐藏项" : "显示隐藏项")
        showHiddenButton.image?.isTemplate = true
        showHiddenButton.contentTintColor = showHidden ? .controlAccentColor : .labelColor
        showHiddenButton.toolTip = showHidden ? "隐藏隐藏项 (⌘.)" : "显示隐藏项 (⌘.)"
    }

    private func applyContentZoom(_ percent: Int) {
        let clamped = min(500, max(30, percent))
        contentController.applyZoomFactor(CGFloat(clamped) / 100)
        for pane in extraPanes {
            pane.applyZoom(clamped)
        }
    }

    // MARK: - Tabs

    private func refreshTabBar() {
        chromeHeader.setTabs(tabs, activeID: activeTabID)
    }

    @objc func newTab(_ sender: Any?) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let tab = BrowserTab(directory: desktop.standardizedFileURL)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
    }

    /// Open a directory as a new tab (or switch to an existing tab with the same path).
    func openDirectoryInTab(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        let standardized = url.standardizedFileURL
        if let existing = tabs.first(where: {
            !$0.isActivityMonitorTab
                && !$0.isTemperatureTab
                && !$0.isCompareTab
                && !$0.isArchiveTab
                && $0.directory.standardizedFileURL == standardized
        }) {
            if existing.id == activeTabID {
                window?.makeKeyAndOrderFront(nil)
                searchField.stringValue = ""
                contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
                // Revealing a file (pending select) or an empty/stale list must reload.
                if !pendingSelectURLs.isEmpty || contentController.items.isEmpty {
                    reloadContents()
                } else {
                    applyPendingSelection(clearIfSelected: true)
                }
                return
            }
            selectTab(existing.id)
            return
        }
        let tab = BrowserTab(directory: standardized)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
    }

    private enum TabSide { case left, right }
    private enum TabCloseScope { case this, left, right, others }

    private func newTab(relativeTo id: UUID, side: TabSide) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            let tab = BrowserTab(directory: currentDirectory)
            tabs.append(tab)
            selectTab(tab.id)
            return
        }
        let directory = tabs[index].directory
        let tab = BrowserTab(directory: directory)
        let insertAt = side == .left ? index : index + 1
        tabs.insert(tab, at: insertAt)
        selectTab(tab.id)
    }

    private func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        focusedColumnIndex = 0
        activeTabID = id
        refreshTabBar()

        if contentController.isShowingHistory {
            contentController.setHistoryMode(active: false, itemCount: 0)
            syncHistoryButtonAppearance(active: false)
        }

        if tab.isActivityMonitorTab {
            showActivityMonitorTab()
            return
        }
        if tab.isTemperatureTab {
            showTemperatureTab()
            return
        }
        if tab.isCompareTab {
            showCompareTab()
            return
        }

        hideSpecialContentTabsIfNeeded()
        if tab.isArchiveTab {
            stopWatching()
            window?.title = tab.archiveInternalPath.isEmpty
                ? tab.title
                : "\(tab.title) — \(tab.archiveInternalPath)"
            updatePathChrome()
            reloadContents()
        } else {
            navigate(to: tab.directory, recordHistory: false)
        }
    }

    /// Open (or focus) the Activity Monitor as a browser tab.
    func openActivityMonitorInTab() {
        if let existing = tabs.first(where: { $0.isActivityMonitorTab }) {
            selectTab(existing.id)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let tab = BrowserTab(activityMonitor: ())
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open (or focus) the Temperature monitor as a browser tab.
    func openTemperatureInTab() {
        if let existing = tabs.first(where: { $0.isTemperatureTab }) {
            selectTab(existing.id)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let tab = BrowserTab(temperature: ())
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open (or focus) code compare workspace as a browser tab.
    func openCompareInTab(workspace index: Int) {
        let ws = max(1, min(CompareSession.workspaceCount, index))
        if let existing = tabs.first(where: { $0.isCompareTab && $0.compareWorkspaceIndex == ws }) {
            selectTab(existing.id)
            window?.makeKeyAndOrderFront(nil)
            compareController.activate(workspace: ws)
            refreshTabBar()
            return
        }
        let tab = BrowserTab(compareWorkspace: ws)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
        window?.makeKeyAndOrderFront(nil)
    }

    private func showActivityMonitorTab() {
        clearAllExtraColumns()
        contentController.setColumnViewEnabled(false)
        stopWatching()
        searchField.stringValue = ""
        contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
        contentController.setTrashMode(active: false, itemCount: 0)
        contentController.setApplicationsMode(active: false)
        hideTemperatureTabIfNeeded()
        hideCompareTabIfNeeded()
        contentController.view.isHidden = true
        activityMonitorController.view.isHidden = false
        activityMonitorController.activate()
        window?.title = "活动监视器"
        statusLabel.stringValue = "活动监视器"
        updatePathBarCoverage()
        refreshTabBar()
    }

    private func showTemperatureTab() {
        clearAllExtraColumns()
        contentController.setColumnViewEnabled(false)
        stopWatching()
        searchField.stringValue = ""
        contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
        contentController.setTrashMode(active: false, itemCount: 0)
        contentController.setApplicationsMode(active: false)
        hideActivityMonitorTabIfNeeded()
        hideCompareTabIfNeeded()
        contentController.view.isHidden = true
        temperatureController.view.isHidden = false
        temperatureController.activate()
        window?.title = "温度"
        statusLabel.stringValue = "温度"
        updatePathBarCoverage()
        refreshTabBar()
    }

    private func showCompareTab() {
        clearAllExtraColumns()
        contentController.setColumnViewEnabled(false)
        stopWatching()
        searchField.stringValue = ""
        contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
        contentController.setTrashMode(active: false, itemCount: 0)
        contentController.setApplicationsMode(active: false)
        hideActivityMonitorTabIfNeeded()
        hideTemperatureTabIfNeeded()
        contentController.view.isHidden = true
        compareController.view.isHidden = false
        let ws = activeTab.compareWorkspaceIndex
        compareController.activate(workspace: ws)
        window?.title = "比对\(ws)"
        statusLabel.stringValue = ""
        updatePathBarCoverage()
        refreshTabBar()
    }

    private func hideActivityMonitorTabIfNeeded() {
        guard !activityMonitorController.view.isHidden else { return }
        activityMonitorController.deactivate()
        activityMonitorController.view.isHidden = true
    }

    private func hideTemperatureTabIfNeeded() {
        guard !temperatureController.view.isHidden else { return }
        temperatureController.deactivate()
        temperatureController.view.isHidden = true
    }

    private func hideCompareTabIfNeeded() {
        guard !compareController.view.isHidden else { return }
        compareController.deactivate()
        compareController.view.isHidden = true
    }

    private func hideSpecialContentTabsIfNeeded() {
        hideActivityMonitorTabIfNeeded()
        hideTemperatureTabIfNeeded()
        hideCompareTabIfNeeded()
        contentController.view.isHidden = false
    }

    private func closeTab(_ id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }), tab.isCompareTab {
            compareController.deactivate()
            CompareSession.shared.clearWorkspace(tab.compareWorkspaceIndex)
        }
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else {
            // Last tab: dismiss the window (same path as the titlebar red close).
            closeWindowFromTitlebar(nil)
            return
        }
        let wasActive = id == activeTabID
        tabs.remove(at: index)
        if wasActive {
            let next = tabs[min(index, tabs.count - 1)]
            selectTab(next.id)
        } else {
            refreshTabBar()
        }
    }

    private func detachTabToNewWindow(_ id: UUID, screenPoint: NSPoint, sideBySide: Bool) {
        guard let tab = extractTab(id) else { return }
        let shouldCloseSource = tabs.isEmpty
        if sideBySide {
            let added = AppDelegate.shared.openNewWindowSideBySide(from: self, with: tab)
            if !added {
                // Group full — put tab back.
                tabs.append(tab)
                activeTabID = tab.id
                navigate(to: tab.directory, recordHistory: false)
                refreshTabBar()
                return
            }
        } else {
            AppDelegate.shared.openNewWindow(with: tab, screenPoint: screenPoint, matching: window?.frame)
        }
        if shouldCloseSource {
            window?.close()
        }
    }

    /// Remove a tab from this window and return it.
    private func extractTab(_ id: UUID) -> BrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if tabs.isEmpty {
            refreshTabBar()
            return tab
        }
        let wasActive = id == activeTabID
        if wasActive {
            let next = tabs[min(index, tabs.count - 1)]
            activeTabID = next.id
            navigate(to: next.directory, recordHistory: false)
        }
        refreshTabBar()
        return tab
    }

    private func closeTabs(relativeTo id: UUID, scope: TabCloseScope) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch scope {
        case .this:
            closeTab(id)
        case .left:
            guard index > 0 else { return }
            let keep = Array(tabs[index...])
            let closingActive = tabs[..<index].contains(where: { $0.id == activeTabID })
            tabs = keep
            if closingActive { selectTab(id) } else { refreshTabBar() }
        case .right:
            guard index < tabs.count - 1 else { return }
            let keep = Array(tabs[...index])
            let closingActive = tabs[(index + 1)...].contains(where: { $0.id == activeTabID })
            tabs = keep
            if closingActive { selectTab(id) } else { refreshTabBar() }
        case .others:
            guard tabs.count > 1 else { return }
            let keep = tabs[index]
            tabs = [keep]
            selectTab(keep.id)
        }
    }

    @objc func closeActiveTabOrWindow(_ sender: Any?) {
        if tabs.count > 1 {
            closeTab(activeTabID)
        } else {
            window?.close()
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        if activeTab.isActivityMonitorTab {
            hideSpecialContentTabsIfNeeded()
            activeTab.isActivityMonitorTab = false
        } else if activeTab.isTemperatureTab {
            hideSpecialContentTabsIfNeeded()
            activeTab.isTemperatureTab = false
        } else if activeTab.isCompareTab {
            hideSpecialContentTabsIfNeeded()
            activeTab.isCompareTab = false
        } else {
            hideSpecialContentTabsIfNeeded()
        }
        let standardized = url.standardizedFileURL
        currentDirectory = standardized
        if recordHistory {
            history.navigate(to: standardized)
        }
        window?.title = FileOperations.isTrashDirectory(standardized)
            ? "废纸篓"
            : FileOperations.isApplicationsDirectory(standardized)
            ? "应用程序"
            : (standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent)
        updatePathChrome()
        searchField.stringValue = ""
        contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
        contentController.setHistoryMode(active: false, itemCount: 0)
        syncHistoryButtonAppearance(active: false)
        if !FileOperations.isTrashDirectory(standardized) {
            contentController.setTrashMode(active: false, itemCount: 0)
        }
        if !FileOperations.isApplicationsDirectory(standardized) {
            contentController.setApplicationsMode(active: false)
        }
        updatePathBarCoverage()
        hideAutocomplete()
        // Always reload the file list so address/tab and table contents stay in sync.
        watchDirectory(standardized)
        reloadContents()
        refreshTabBar()
    }

    func selectAfterNavigate(_ urls: [URL]) {
        let targets = urls.map(\.standardizedFileURL)
        guard !targets.isEmpty else { return }
        pendingSelectURLs = targets
        // Keep pending until reload finishes so setItems cannot leave an empty unselected list.
        applyPendingSelection(clearIfSelected: false)
    }

    private func applyPendingSelection(clearIfSelected: Bool) {
        guard !pendingSelectURLs.isEmpty else { return }
        contentController.select(urls: pendingSelectURLs)
        if clearIfSelected, !contentController.selectedItems.isEmpty {
            pendingSelectURLs = []
        }
    }

    private func reloadContents(preservingOutline: Bool = false) {
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        packageSizeWorkItem?.cancel()
        packageSizeWorkItem = nil

        // Keep the in-window history page until the user navigates away / toggles it off.
        if contentController.isShowingHistory {
            refreshHistoryPage()
            return
        }

        if activeTab.isActivityMonitorTab {
            showActivityMonitorTab()
            return
        }
        if activeTab.isTemperatureTab {
            showTemperatureTab()
            return
        }
        if activeTab.isCompareTab {
            showCompareTab()
            return
        }

        contentLoadGeneration += 1
        let generation = contentLoadGeneration
        let showHidden = settings.showHiddenFiles
        statusLabel.stringValue = "正在加载…"

        if let archive = activeTab.archiveURL {
            let internalPath = activeTab.archiveInternalPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let items: [FileItem]
                do {
                    items = try ArchiveSupport.browseChildren(archive: archive, internalPath: internalPath)
                        .filter { showHidden || !$0.isHidden }
                } catch {
                    DispatchQueue.main.async {
                        guard let self, generation == self.contentLoadGeneration else { return }
                        self.contentController.setItems([], alreadySortedByName: true)
                        self.statusLabel.stringValue = "无法读取压缩包：\(error.localizedDescription)"
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard generation == self.contentLoadGeneration else { return }
                    self.contentController.setItems(items, alreadySortedByName: true)
                    self.updateStatus(selection: self.contentController.selectedItems)
                }
            }
            return
        }

        let directory = currentDirectory
        let keepOutline = preservingOutline
        let pendingSelect = pendingSelectURLs
        let pendingRename = pendingRenameURL
        let inTrash = FileOperations.isTrashDirectory(directory)
        pendingSelectURLs = []
        pendingRenameURL = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Trash items may be marked hidden; always list them in trash mode.
            var items = FileOperations.listDirectory(directory, showHidden: showHidden || inTrash)
            if inTrash {
                items = items.filter { $0.name != ".DS_Store" }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.contentLoadGeneration else { return }
                guard self.currentDirectory.standardizedFileURL == directory.standardizedFileURL else { return }
                if keepOutline {
                    self.contentController.replaceRootListing(
                        items,
                        preservingOutline: true,
                        alreadySortedByName: true,
                        select: pendingSelect,
                        beginRename: pendingRename
                    )
                } else {
                    self.contentController.setItems(
                        items,
                        alreadySortedByName: true,
                        select: pendingSelect
                    )
                    if let renameURL = pendingRename,
                       let item = self.contentController.items.first(where: {
                           $0.url.standardizedFileURL.path == renameURL.standardizedFileURL.path
                       }) {
                        DispatchQueue.main.async {
                            self.contentController.beginInlineRename(item)
                        }
                    }
                }
                // Directory refresh must not wipe an active search with the raw folder listing.
                let query = self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !query.isEmpty, !inTrash {
                    self.applySearch(query: query)
                } else {
                    self.contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
                    self.contentController.setTrashMode(active: inTrash, itemCount: items.count)
                    self.contentController.setApplicationsMode(
                        active: !inTrash && FileOperations.isApplicationsDirectory(directory)
                    )
                    self.updatePathBarCoverage()
                    // Re-apply selection after search mode clears / layout settles.
                    if !pendingSelect.isEmpty {
                        self.contentController.select(urls: pendingSelect)
                        DispatchQueue.main.async {
                            self.contentController.select(urls: pendingSelect)
                        }
                    }
                    self.updateStatus(selection: self.contentController.selectedItems)
                }
                self.schedulePackageSizeFill(items: items, generation: generation)
            }
        }
    }

    /// Compute .app / package sizes in the background and patch the table progressively.
    private func schedulePackageSizeFill(items: [FileItem], generation: Int) {
        packageSizeWorkItem?.cancel()
        let packages = items.filter { $0.isPackage && $0.fileSize == nil }
        guard !packages.isEmpty else { return }

        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            let lock = NSLock()
            var batch: [URL: Int64] = [:]
            let pool = DispatchQueue(label: "com.zhangjing.NewFinder.packageSize", attributes: .concurrent)
            let group = DispatchGroup()
            let limit = DispatchSemaphore(value: 3)

            func flush(force: Bool) {
                lock.lock()
                let shouldFlush = force ? !batch.isEmpty : batch.count >= 4
                guard shouldFlush else {
                    lock.unlock()
                    return
                }
                let snapshot = batch
                batch.removeAll(keepingCapacity: true)
                lock.unlock()
                DispatchQueue.main.async {
                    guard let self, generation == self.contentLoadGeneration else { return }
                    self.contentController.applyFileSizes(snapshot)
                    self.updateStatus(selection: self.contentController.selectedItems)
                }
            }

            for item in packages {
                group.enter()
                pool.async {
                    defer { group.leave() }
                    limit.wait()
                    defer { limit.signal() }
                    if work.isCancelled { return }
                    let size = FileOperations.cachedPackageByteSize(
                        at: item.url,
                        modificationDate: item.modificationDate
                    )
                    if work.isCancelled { return }
                    lock.lock()
                    batch[item.url.standardizedFileURL] = size
                    lock.unlock()
                    flush(force: false)
                }
            }

            group.wait()
            guard !work.isCancelled else { return }
            flush(force: true)
        }
        packageSizeWorkItem = work
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func applySearch(query: String) {
        contentController.setHistoryMode(active: false, itemCount: 0)
        syncHistoryButtonAppearance(active: false)
        updatePathBarCoverage()
        let urls = FileOperations.search(in: currentDirectory, query: query)
        let items = urls.compactMap(FileItem.from)
        let scope = currentDirectory.path == "/" ? "Macintosh HD" : currentDirectory.lastPathComponent
        // Enable search mode before setItems so name-column sort uses full paths.
        contentController.setSearchResultsMode(
            query: query,
            scopeName: scope,
            resultCount: items.count,
            searchRoot: currentDirectory
        )
        contentController.setItems(items, alreadySortedByName: true)
        updateStatus(selection: [])
    }

    /// Mutations that should keep outline expansion (rename / trash / paste / New in root).
    private func reloadAfterMutation(select: [URL] = [], beginRename: URL? = nil) {
        pendingSelectURLs = select
        pendingRenameURL = beginRename
        suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
        pendingReloadWorkItem?.cancel()
        pendingReloadWorkItem = nil
        reloadContents(preservingOutline: true)
        reloadAllExtraPanes()
    }

    private func scheduleReloadContents() {
        if let until = suppressDirectoryWatchUntil, Date() < until {
            return
        }
        pendingReloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadContents(preservingOutline: true)
        }
        pendingReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func updatePathChrome() {
        if contentController.isShowingHistory {
            updateHistoryPathChrome()
            return
        }
        if let archive = activeTab.archiveURL {
            let internalPath = activeTab.archiveInternalPath
            pathField.stringValue = internalPath.isEmpty
                ? archive.path
                : archive.path + " :: " + internalPath
            breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            let rootBtn = BreadcrumbButton(
                title: "📦 " + archive.lastPathComponent,
                target: self,
                action: #selector(archiveRootClicked)
            )
            breadcrumbStack.addArrangedSubview(rootBtn)

            if !internalPath.isEmpty {
                let parts = internalPath.split(separator: "/").map(String.init)
                var built = ""
                for part in parts {
                    let chevron = BreadcrumbChevronButton()
                    breadcrumbStack.addArrangedSubview(chevron)
                    built = built.isEmpty ? part : built + "/" + part
                    let button = BreadcrumbButton(
                        title: part,
                        target: self,
                        action: #selector(archiveBreadcrumbClicked(_:))
                    )
                    button.identifier = NSUserInterfaceItemIdentifier(built)
                    breadcrumbStack.addArrangedSubview(button)
                }
            }

            pathBookmarkButton.isHidden = true
            breadcrumbClip.isHidden = isEditingPath
            pathField.isHidden = !isEditingPath
            breadcrumbClip.refreshLayout()
            refreshBookmarkUI()
            return
        }

        pathBookmarkButton.isHidden = false
        pathField.stringValue = currentDirectory.path

        let pathSignature = currentDirectory.standardizedFileURL.path
        let existingSignature: String = {
            if let last = breadcrumbStack.arrangedSubviews.last as? BreadcrumbButton {
                return last.identifier?.rawValue ?? ""
            }
            return ""
        }()
        let needsRebuild = pathSignature != existingSignature
            || breadcrumbStack.arrangedSubviews.isEmpty

        if needsRebuild {
            breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

            if FileOperations.isTrashDirectory(currentDirectory) {
                let button = BreadcrumbButton(title: "废纸篓", target: self, action: #selector(breadcrumbClicked(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(currentDirectory.path)
                breadcrumbStack.addArrangedSubview(button)
                pathBookmarkButton.isHidden = true
                breadcrumbClip.isHidden = isEditingPath
                pathField.isHidden = !isEditingPath
                breadcrumbClip.refreshLayout()
                refreshBookmarkUI()
                return
            }

            if FileOperations.isApplicationsDirectory(currentDirectory) {
                let button = BreadcrumbButton(title: "应用程序", target: self, action: #selector(breadcrumbClicked(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(currentDirectory.path)
                breadcrumbStack.addArrangedSubview(button)
                pathBookmarkButton.isHidden = false
                breadcrumbClip.isHidden = isEditingPath
                pathField.isHidden = !isEditingPath
                breadcrumbClip.refreshLayout()
                refreshBookmarkUI()
                return
            }

            let components = currentDirectory.pathComponents
            var built = ""
            for (index, component) in components.enumerated() {
                if index == 0 {
                    built = "/"
                } else if built == "/" {
                    built += component
                } else {
                    built += "/" + component
                }

                let title = index == 0 ? "Macintosh HD" : component
                let button = BreadcrumbButton(title: title, target: self, action: #selector(breadcrumbClicked(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(built)
                breadcrumbStack.addArrangedSubview(button)

                if index < components.count - 1 {
                    let chevron = BreadcrumbChevronButton()
                    chevron.directoryPath = built
                    chevron.onClick = { [weak self, weak chevron] in
                        guard let self, let chevron else { return }
                        DispatchQueue.main.async {
                            self.showBreadcrumbDirectoryMenu(at: built, from: chevron)
                        }
                    }
                    breadcrumbStack.addArrangedSubview(chevron)
                }
            }
        }

        breadcrumbClip.isHidden = isEditingPath
        pathField.isHidden = !isEditingPath
        if needsRebuild {
            breadcrumbClip.refreshLayout()
        }
        refreshBookmarkUI()
    }

    @objc private func archiveRootClicked() {
        guard activeTab.isArchiveTab else { return }
        activeTab.archiveInternalPath = ""
        reloadContents()
        updatePathChrome()
        window?.title = activeTab.title
    }

    @objc private func archiveBreadcrumbClicked(_ sender: NSButton) {
        guard activeTab.isArchiveTab else { return }
        activeTab.archiveInternalPath = sender.identifier?.rawValue ?? ""
        reloadContents()
        updatePathChrome()
        window?.title = "\(activeTab.title) — \(activeTab.archiveInternalPath)"
    }

    private func refreshBookmarkUI() {
        let path = currentDirectory.standardizedFileURL.path
        let isBookmarked = settings.bookmarks(in: .left).contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }
        updatePathBookmarkButton(isBookmarked: isBookmarked)
        // Navigating must not rebuild/re-expand the sidebar — only update selection.
        favoritesSidebar?.setCurrentPath(path)
    }

    private func reloadFavoritesSidebar() {
        favoritesSidebar?.reload(highlighting: currentDirectory.standardizedFileURL.path)
        applyFavoritesLayout(animated: true)
    }

    private func updatePathBookmarkButton(isBookmarked: Bool) {
        let symbol = isBookmarked ? "star.fill" : "star"
        let tip = isBookmarked ? "编辑收藏" : "收藏当前地址"
        pathBookmarkButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        pathBookmarkButton.image?.isTemplate = true
        pathBookmarkButton.contentTintColor = isBookmarked ? .systemYellow : .secondaryLabelColor
        pathBookmarkButton.toolTip = tip
    }

    private func orderedBookmarkFolders() -> [String] {
        settings.orderedBookmarkFolders()
    }

    @objc private func breadcrumbClicked(_ sender: Any?) {
        let button = (sender as? BreadcrumbButton) ?? (sender as? NSButton)
        if NSApp.currentEvent?.clickCount ?? 0 >= 2 {
            beginPathEditing()
            return
        }
        guard let path = button?.identifier?.rawValue else { return }
        navigate(to: URL(fileURLWithPath: path))
    }

    private func showBreadcrumbDirectoryMenu(at directoryPath: String, from source: NSView) {
        let dirURL = URL(fileURLWithPath: directoryPath)
        let items = FileOperations.listDirectory(dirURL, showHidden: false)
        let menu = NSMenu()
        menu.autoenablesItems = false

        if items.isEmpty {
            let empty = NSMenuItem(title: "空文件夹", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in items {
                let item = NSMenuItem(
                    title: entry.name,
                    action: #selector(breadcrumbMenuItemClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.url
                item.image = NSWorkspace.shared.icon(forFile: entry.url.path)
                item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
        }

        // Anchor at the bottom of the path bar so the menu sits below it (AppKit y=0 is bottom).
        let x = source.convert(NSPoint(x: 0, y: 0), to: pathBarContainer).x
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: 0), in: pathBarContainer)
    }

    @objc private func breadcrumbMenuItemClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent())
            selectAfterNavigate([url])
        }
    }

    @objc private func toggleHistoryPage(_ sender: Any?) {
        if contentController.isShowingHistory {
            closeHistoryPage()
        } else {
            openHistoryPage()
        }
    }

    private func openHistoryPage() {
        refreshHistoryPage()
    }

    private func refreshHistoryPage() {
        // History overlays the file list; pause special tabs while it is open.
        if !activityMonitorController.view.isHidden
            || !temperatureController.view.isHidden
            || !compareController.view.isHidden {
            hideSpecialContentTabsIfNeeded()
        }

        searchField.stringValue = ""
        contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
        contentController.setTrashMode(active: false, itemCount: 0)
        contentController.setApplicationsMode(active: false)

        let visits = AppSettings.shared.recentOpenHistory
        let items = visits.map(Self.fileItem(forHistoryVisit:))
        contentController.setHistoryMode(active: true, itemCount: items.count)
        contentController.setItems(items, alreadySortedByName: true)
        window?.title = "最近打开"
        statusLabel.stringValue = items.isEmpty
            ? "暂无打开历史"
            : "最近打开 \(items.count) 项"
        updateHistoryPathChrome()
        syncHistoryButtonAppearance(active: true)
        updatePathBarCoverage()
    }

    private func closeHistoryPage() {
        guard contentController.isShowingHistory else { return }
        contentController.setHistoryMode(active: false, itemCount: 0)
        syncHistoryButtonAppearance(active: false)
        updatePathBarCoverage()
        updatePathChrome()
        reloadContents()
        window?.title = FileOperations.isTrashDirectory(currentDirectory)
            ? "废纸篓"
            : FileOperations.isApplicationsDirectory(currentDirectory)
            ? "应用程序"
            : (currentDirectory.lastPathComponent.isEmpty ? currentDirectory.path : currentDirectory.lastPathComponent)
    }

    /// Hide the address bar while history / Applications / Activity Monitor covers that space.
    private func updatePathBarCoverage() {
        let covered = contentController.isShowingHistory
            || contentController.isShowingApplications
            || activeTab.isActivityMonitorTab
            || activeTab.isTemperatureTab
            || activeTab.isCompareTab
        if covered {
            pathBarContainer.isHidden = true
            pathBarHeightConstraint.constant = 0
        } else {
            pathBarContainer.isHidden = !pathBarVisible
            pathBarHeightConstraint.constant = pathBarVisible ? 29 : 0
        }
        // Compare: drop the status strip entirely (no 0-height hairline).
        let hideStatus = activeTab.isCompareTab
        statusBarView.isHidden = hideStatus
        statusBarHeightConstraint.constant = hideStatus ? 0 : 22
        if hideStatus {
            statusLabel.stringValue = ""
            compareBottomToStatusConstraint.isActive = false
            compareBottomToColumnConstraint.isActive = true
        } else {
            compareBottomToColumnConstraint.isActive = false
            compareBottomToStatusConstraint.isActive = true
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func syncHistoryButtonAppearance(active: Bool) {
        recentHistoryButton.contentTintColor = active ? .controlAccentColor : .labelColor
    }

    private func updateHistoryPathChrome() {
        // Address bar is hidden while history covers it; keep chrome ready for restore.
        breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let button = BreadcrumbButton(title: "最近打开", target: nil, action: nil)
        button.isEnabled = false
        breadcrumbStack.addArrangedSubview(button)
        pathField.isHidden = true
        breadcrumbClip?.isHidden = false
    }

    private static func fileItem(forHistoryVisit visit: VisitRecord) -> FileItem {
        if let item = FileItem.from(url: visit.url) {
            return FileItem(
                url: item.url,
                name: item.name,
                isDirectory: item.isDirectory,
                isPackage: item.isPackage,
                isHidden: item.isHidden,
                fileSize: item.fileSize,
                modificationDate: visit.visitedAt,
                creationDate: item.creationDate,
                archiveEntryPath: nil
            )
        }
        let name = visit.url.lastPathComponent
        let isPackage = visit.url.pathExtension.lowercased() == "app"
        return FileItem(
            url: visit.url.standardizedFileURL,
            name: name.isEmpty ? visit.url.path : name,
            isDirectory: false,
            isPackage: isPackage,
            isHidden: name.hasPrefix("."),
            fileSize: nil,
            modificationDate: visit.visitedAt,
            creationDate: nil,
            archiveEntryPath: nil
        )
    }

    @objc private func clearRecentOpenHistory(_ sender: Any?) {
        AppSettings.shared.clearOpenHistory()
        if contentController.isShowingHistory {
            refreshHistoryPage()
        }
    }

    private func openHistoryURL(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else {
            NSSound.beep()
            return
        }
        if isDir.boolValue {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent())
            selectAfterNavigate([url])
            AppSettings.shared.recordOpenHistory(url)
        }
    }

    private func openItem(_ item: FileItem) {
        if activeTab.isArchiveTab {
            openArchiveItem(item, in: activeTab)
            return
        }
        if !item.isDirectory, DMGInstallSupport.isDiskImage(item.url) {
            AppSettings.shared.recordOpenHistory(item.url)
            _ = AppDelegate.shared.openDiskImage(item.url)
            return
        }
        if !item.isDirectory, ArchiveSupport.looksLikeArchive(item.url) {
            AppSettings.shared.recordOpenHistory(item.url)
            openArchiveInTab(item.url)
            return
        }
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            AppSettings.shared.recordOpenHistory(item.url)
            NSWorkspace.shared.open(item.url)
        }
    }

    func openArchivesInTabs(_ urls: [URL]) {
        for url in urls {
            openArchiveInTab(url)
        }
    }

    func openArchiveInTab(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let existing = tabs.first(where: { $0.archiveURL?.standardizedFileURL == standardized }) {
            selectTab(existing.id)
            return
        }
        let tab = BrowserTab(archive: standardized)
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        selectTab(tab.id)
    }

    private func openArchiveItem(_ item: FileItem, in tab: BrowserTab) {
        guard let archive = tab.archiveURL, let entry = item.archiveEntryPath else { return }
        if item.isDirectory {
            tab.archiveInternalPath = entry
            reloadContents()
            updatePathChrome()
            refreshTabBar()
            window?.title = "\(archive.lastPathComponent) — \(entry)"
        } else {
            // Extract single file to temp and open.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("NewFinder-ArchiveOpen-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let options = ArchiveExtractOptions(
                directory: temp,
                folderName: "",
                password: "",
                deleteSource: false
            )
            ArchiveSupport.extract(urls: [archive], options: options) { result in
                switch result {
                case .success:
                    let target = temp.appendingPathComponent(entry)
                    if FileManager.default.fileExists(atPath: target.path) {
                        NSWorkspace.shared.open(target)
                    } else {
                        // Some archives flatten oddly; try basename.
                        let fallback = temp.appendingPathComponent(item.name)
                        NSWorkspace.shared.open(fallback)
                    }
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "无法打开压缩包内文件"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func updateStatus(selection: [FileItem]) {
        guard !activeTab.isCompareTab else {
            statusLabel.stringValue = ""
            return
        }
        let items = contentController.items
        let total = items.count
        let totalSize = formattedTotalSize(of: items)
        let selectedCount = selection.count
        let selectedSize = formattedTotalSize(of: selection)
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if contentController.isShowingHistory {
            statusLabel.stringValue = items.isEmpty
                ? "暂无打开历史"
                : "最近打开 \(total) 项，已选中 \(selectedCount) 个"
        } else if !query.isEmpty {
            statusLabel.stringValue = "搜索到 \(total) 个结果，\(totalSize)，已选中 \(selectedCount) 个，\(selectedSize) · 「\(query)」"
        } else {
            statusLabel.stringValue = "\(total) 个项目，\(totalSize)，已选中 \(selectedCount) 个，\(selectedSize)"
        }
    }

    private func formattedTotalSize(of items: [FileItem]) -> String {
        let bytes = items.compactMap(\.fileSize).reduce(Int64(0), +)
        return FileOperations.formatFileSize(bytes)
    }

    // MARK: - Directory watching

    private func watchDirectory(_ url: URL) {
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReloadContents()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        directoryWatcher = source
        source.resume()
    }

    private func stopWatching() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        watchedFD = -1
    }

    // MARK: - Actions

    @objc func goBack(_ sender: Any?) {
        if let url = history.goBack() {
            navigate(to: url, recordHistory: false)
        }
    }

    @objc func goForward(_ sender: Any?) {
        if let url = history.goForward() {
            navigate(to: url, recordHistory: false)
        }
    }

    @objc func goEnclosingFolder(_ sender: Any?) {
        if activeTab.isArchiveTab {
            let path = activeTab.archiveInternalPath
            if path.isEmpty {
                // Leave archive: go to containing folder and select the archive.
                if let archive = activeTab.archiveURL {
                    pendingSelectURLs = [archive]
                    navigate(to: archive.deletingLastPathComponent())
                }
            } else {
                let parent = (path as NSString).deletingLastPathComponent
                activeTab.archiveInternalPath = parent == "." ? "" : parent
                reloadContents()
                updatePathChrome()
                window?.title = activeTab.archiveInternalPath.isEmpty
                    ? activeTab.title
                    : "\(activeTab.title) — \(activeTab.archiveInternalPath)"
            }
            return
        }
        if FileOperations.isTrashDirectory(currentDirectory) {
            goHome(nil)
            return
        }
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent.path != currentDirectory.path else { return }
        let left = currentDirectory
        pendingSelectURLs = [left]
        navigate(to: parent)
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func goDesktop(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    }

    @objc func goDocuments(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
    }

    @objc func goDownloads(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
    }

    @objc func goComputer(_ sender: Any?) {
        navigate(to: URL(fileURLWithPath: "/"))
    }

    @objc func focusPathBar(_ sender: Any?) {
        beginPathEditing()
    }

    @objc func togglePathBar(_ sender: Any?) {
        pathBarVisible.toggle()
        updatePathBarCoverage()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        settings.showHiddenFiles.toggle()
        syncShowHiddenFilesButton(settings.showHiddenFiles)
        reloadContents(preservingOutline: true)
    }

    @objc func newFolder(_ sender: Any?) {
        createNewItem(extensionName: nil, openAfterCreate: false)
    }

    @objc func newItemMenuClicked(_ sender: NSMenuItem) {
        let types = settings.newItemTypes
        guard sender.tag >= 0, sender.tag < types.count else { return }
        let type = types[sender.tag]
        let ext: String? = type.lowercased() == "dir" ? nil : type
        let openAfterCreate = NSEvent.modifierFlags.contains(.option)
        createNewItem(extensionName: ext, openAfterCreate: openAfterCreate)
    }

    @objc func toolbarNewItemClicked(_ sender: NSButton) {
        let type: String
        if let button = sender as? ToolbarNewTypeButton {
            type = button.itemType
        } else {
            type = sender.title
        }
        let trimmed = type.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }
        let canonical = AppSettings.canonicalFixedType(trimmed) ?? trimmed
        let ext: String? = canonical.lowercased() == "dir" ? nil : canonical
        let openAfterCreate = NSEvent.modifierFlags.contains(.option)
        createNewItem(extensionName: ext, openAfterCreate: openAfterCreate)
    }

    private func createNewItem(extensionName: String?, openAfterCreate: Bool) {
        let targetDir = contentController.createTargetDirectory(fallback: currentDirectory)
        let createdInsideOutline =
            targetDir.standardizedFileURL != currentDirectory.standardizedFileURL
        do {
            let url = try FileOperations.createNewItem(in: targetDir, extensionName: extensionName)
            suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
            pendingReloadWorkItem?.cancel()
            pendingReloadWorkItem = nil
            if openAfterCreate {
                if extensionName == nil {
                    navigate(to: url)
                } else {
                    NSWorkspace.shared.open(url)
                    if createdInsideOutline {
                        contentController.refreshAfterCreate(at: url, parent: targetDir, beginRename: false)
                    } else {
                        reloadAfterMutation(select: [url])
                    }
                }
            } else if createdInsideOutline {
                contentController.refreshAfterCreate(at: url, parent: targetDir, beginRename: true)
            } else {
                reloadAfterMutation(select: [url], beginRename: url)
            }
        } catch {
            showError(error)
        }
    }

    @objc func rename(_ sender: Any?) {
        guard let item = contentController.selectedItems.first else {
            NSSound.beep()
            return
        }
        contentController.beginInlineRename(item)
    }

    private func commitRename(_ item: FileItem, to newName: String) {
        let wasExpanded = item.isDirectory && contentController.isExpanded(item.url)
        do {
            let dest = try FileOperations.rename(item.url, to: newName)
            contentController.noteRemovedURLs([item.url])
            if wasExpanded {
                contentController.markExpanded(dest)
            }
            reloadAfterMutation(select: [dest.standardizedFileURL])
        } catch {
            showError(error)
            reloadAfterMutation(select: [item.url.standardizedFileURL])
        }
    }

    @objc func copy(_ sender: Any?) {
        let urls = activeContentController.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileOperations.copyURLs(urls)
        activeContentController.refreshCutAppearance()
    }

    @objc func cut(_ sender: Any?) {
        let urls = activeContentController.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        FileOperations.cutURLs(urls)
        activeContentController.refreshCutAppearance()
    }

    @objc func paste(_ sender: Any?) {
        let dir = activeBrowserDirectory
        let targetDir = activeContentController.createTargetDirectory(fallback: dir)
        do {
            let urls = try FileOperations.paste(into: targetDir)
            if targetDir.standardizedFileURL != dir.standardizedFileURL {
                activeContentController.markExpanded(targetDir)
            }
            reloadAfterMutation(select: urls)
            activeContentController.refreshCutAppearance()
        } catch {
            NSSound.beep()
        }
    }

    @objc func openSelectedItems(_ sender: Any?) {
        let items = contentController.selectedItems
        guard !items.isEmpty else { return }
        items.forEach { openItem($0) }
    }

    @objc func moveToTrash(_ sender: Any?) {
        let dir = activeBrowserDirectory
        let list = activeContentController
        if FileOperations.isTrashDirectory(dir) {
            deleteForeverFromTrash(sender)
            return
        }
        if FileOperations.isApplicationsDirectory(dir) {
            uninstallSelectedApps(sender)
            return
        }
        let urls = list.selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let nextURL = list.selectionURLAfterRemovingSelected()
        do {
            try FileOperations.moveToTrash(urls)
            list.noteRemovedURLs(urls)
            if let pane = focusedExtraPane() {
                suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
                reloadContents(preservingOutline: true)
                reloadAllExtraPanes()
                if let next = nextURL {
                    DispatchQueue.main.async { [weak pane] in
                        pane?.contentController.select(urls: [next])
                    }
                }
            } else {
                reloadAfterMutation(select: nextURL.map { [$0] } ?? [])
            }
        } catch {
            showError(error)
        }
    }

    @objc func uninstallSelectedApps(_ sender: Any?) {
        guard FileOperations.isApplicationsDirectory(currentDirectory) else { return }
        let apps = contentController.packagesForUninstall
        guard !apps.isEmpty else {
            NSSound.beep()
            return
        }

        statusLabel.stringValue = "正在扫描关联文件…"
        let appURLs = apps.map(\.url.standardizedFileURL)
        let nextURL = contentController.selectionURLAfterRemovingSelected()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plans = AppUninstallSupport.buildPlans(for: appURLs)
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStatus(selection: self.contentController.selectedItems)

                let removable = plans.filter { !$0.isProtectedSystemApp }
                if removable.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "无法卸载"
                    alert.informativeText = "所选项目均为系统应用，或没有可移除的内容。"
                    alert.runModal()
                    return
                }

                let alert = NSAlert()
                alert.messageText = removable.count == 1
                    ? "彻底卸载「\(removable[0].displayName)」？"
                    : "彻底卸载 \(removable.count) 个项目？"
                alert.informativeText = AppUninstallSupport.summaryText(for: plans)
                alert.alertStyle = .critical
                alert.addButton(withTitle: "卸载")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }

                self.statusLabel.stringValue = "正在彻底卸载…"
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        let result = try AppUninstallSupport.performUninstall(plans)
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.contentController.clearUninstallChecks(for: appURLs)
                            self.contentController.noteRemovedURLs(appURLs)
                            self.reloadAfterMutation(select: nextURL.map { [$0] } ?? [])
                            if result.failures.isEmpty {
                                self.statusLabel.stringValue = "已彻底卸载，删除 \(result.removed) 项"
                            } else {
                                let detail = result.failures.prefix(6).map {
                                    "\($0.0.lastPathComponent)：\($0.1)"
                                }.joined(separator: "\n")
                                let failAlert = NSAlert()
                                failAlert.messageText = "部分项目未能删除"
                                failAlert.informativeText =
                                    "已删除 \(result.removed) 项。失败 \(result.failures.count) 项（可能需要管理员权限）：\n\(detail)"
                                failAlert.runModal()
                                self.updateStatus(selection: self.contentController.selectedItems)
                            }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self?.showError(error)
                        }
                    }
                }
            }
        }
    }

    @objc func putBackFromTrash(_ sender: Any?) {
        let dir = activeBrowserDirectory
        let list = activeContentController
        guard FileOperations.isTrashDirectory(dir) else { return }
        let urls = list.selectedItems.map(\.url.standardizedFileURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let nextURL = list.selectionURLAfterRemovingSelected()
        FileOperations.putBackFromTrash(urls)
        list.noteRemovedURLs(urls)
        // Finder Put Away can be slightly async; refresh shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if let pane = self.focusedExtraPane() {
                self.suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
                self.reloadContents(preservingOutline: true)
                self.reloadAllExtraPanes()
                if let next = nextURL {
                    pane.contentController.select(urls: [next])
                }
            } else {
                self.reloadAfterMutation(select: nextURL.map { [$0] } ?? [])
            }
        }
    }

    @objc func deleteForeverFromTrash(_ sender: Any?) {
        let dir = activeBrowserDirectory
        let list = activeContentController
        guard FileOperations.isTrashDirectory(dir) else { return }
        let urls = list.selectedItems.map(\.url.standardizedFileURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let nextURL = list.selectionURLAfterRemovingSelected()
        do {
            try FileOperations.permanentlyDelete(urls)
            list.noteRemovedURLs(urls)
            if let pane = focusedExtraPane() {
                suppressDirectoryWatchUntil = Date().addingTimeInterval(1.2)
                reloadContents(preservingOutline: true)
                reloadAllExtraPanes()
                if let next = nextURL {
                    DispatchQueue.main.async { [weak pane] in
                        pane?.contentController.select(urls: [next])
                    }
                }
            } else {
                reloadAfterMutation(select: nextURL.map { [$0] } ?? [])
            }
        } catch {
            showError(error)
        }
    }

    @objc func emptyTrash(_ sender: Any?) {
        guard FileOperations.isTrashDirectory(currentDirectory) else { return }
        let alert = NSAlert()
        alert.messageText = "确定清空废纸篓？"
        alert.informativeText = "废纸篓中的所有项目将被永久删除，此操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileOperations.emptyTrash(at: currentDirectory)
            reloadAfterMutation()
        } catch {
            showError(error)
        }
    }

    private func handleFileDrop(urls: [URL], destination: URL, copying: Bool) {
        let sources = urls
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return }
        do {
            let results = try FileOperations.transferItems(
                sources,
                toDirectory: destination.standardizedFileURL,
                copying: copying
            )
            if !copying {
                contentController.noteRemovedURLs(sources)
            }
            if destination.standardizedFileURL != currentDirectory.standardizedFileURL {
                contentController.markExpanded(destination)
            }
            // Prefer revealing dropped items; fall back to destination folder in column view.
            let select = results.isEmpty ? [destination.standardizedFileURL] : results
            reloadAfterMutation(select: select)
        } catch {
            showError(error)
        }
    }

    @objc func selectAllItems(_ sender: Any?) {
        if contentController.selectAllInRenameFieldIfNeeded() {
            return
        }
        if isEditingPath, let editor = pathField.currentEditor() {
            editor.selectAll(nil)
            return
        }
        contentController.selectAll()
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = contentController.selectedItems.map(\.url)
        let text: String
        if urls.isEmpty {
            text = currentDirectory.path
        } else {
            text = urls.map(\.path).joined(separator: "\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopyPathSuccess()
    }

    private func flashCopyPathSuccess() {
        copyPathFlashToken += 1
        let token = copyPathFlashToken
        copyPathButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "已复制")
        copyPathButton.image?.isTemplate = true
        copyPathButton.contentTintColor = .systemGreen
        copyPathButton.toolTip = "已复制"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.copyPathFlashToken == token else { return }
            self.copyPathButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制路径")
            self.copyPathButton.image?.isTemplate = true
            self.copyPathButton.contentTintColor = .labelColor
            self.copyPathButton.toolTip = "复制路径"
        }
    }

    @objc func goClipboardPath(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            NSSound.beep()
            return
        }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
            if isDir.boolValue {
                navigate(to: URL(fileURLWithPath: expanded))
            } else {
                let file = URL(fileURLWithPath: expanded)
                pendingSelectURLs = [file]
                navigate(to: file.deletingLastPathComponent())
            }
        } else {
            NSSound.beep()
        }
    }

    @objc func showBookmarkEditor(_ sender: Any?) {
        let path = currentDirectory.standardizedFileURL.path
        // Path-bar star edits / adds the left-sidebar favorite only.
        let existing = settings.bookmarks(in: .left).first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }
        presentBookmarkEditor(for: existing, preferredPlacement: .left)
    }

    private func presentBookmarkEditor(for existingBookmark: Bookmark?, preferredPlacement: FavoritesPlacement) {
        let path = existingBookmark?.path ?? currentDirectory.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            statusLabel.stringValue = "没有可收藏的文件夹"
            return
        }

        let placement = existingBookmark?.placement ?? preferredPlacement
        let existing = existingBookmark ?? settings.bookmarks(in: placement).first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }
        cancelBookmarkEditor()
        editingBookmarkID = existing?.id
        editingBookmarkPlacement = existing?.placement ?? preferredPlacement

        let editor = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        editor.title = existing == nil ? "添加收藏" : "编辑收藏"
        editor.isReleasedWhenClosed = false
        editor.isFloatingPanel = true
        editor.level = .floating

        let content = NSView()
        let defaultFolder = Self.normalizedFavoritesFolderDisplay(existing?.folder)
        let folderField = NSTextField(string: defaultFolder)
        let folderPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        folderPicker.target = self
        folderPicker.action = #selector(bookmarkFolderPickerChanged(_:))
        Self.populateFavoritesFolderPicker(
            folderPicker,
            folders: settings.orderedBookmarkFolders(for: editingBookmarkPlacement),
            selected: defaultFolder
        )

        let defaultName: String = {
            if let existing { return existing.name }
            if path == "/" { return "Macintosh HD" }
            let n = URL(fileURLWithPath: path).lastPathComponent
            return n.isEmpty ? path : n
        }()
        let nameField = NSTextField(string: defaultName)
        let pathField = NSTextField(string: existing?.path ?? path)
        [folderField, folderPicker, nameField, pathField].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let folderLabel = NSTextField(labelWithString: "放置的文件夹")
        let nameLabel = NSTextField(labelWithString: "收藏的地址名字")
        let pathLabel = NSTextField(labelWithString: "收藏的地址")
        let placementLabel = NSTextField(labelWithString: "收藏夹位置")
        [folderLabel, nameLabel, pathLabel, placementLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let placementControl = NSSegmentedControl(
            labels: ["左侧", "顶部"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(bookmarkPlacementChanged(_:))
        )
        placementControl.segmentStyle = .rounded
        placementControl.selectedSegment = editingBookmarkPlacement == .top ? 1 : 0
        placementControl.translatesAutoresizingMaskIntoConstraints = false
        placementControl.toolTip = "左侧与顶部是两套独立收藏，互不影响"

        folderField.placeholderString = Self.favoritesBarFolderName
        folderField.toolTip = "选「收藏栏」时地址会直接出现在顶栏/侧栏（类似 Chrome），不会新建文件夹"
        folderPicker.toolTip = "第一项「收藏栏」= 直接放在栏上；其余为子文件夹"

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelBookmarkEditor))
        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveBookmarkEditor))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"
        saveButton.bezelColor = .controlAccentColor

        let removeButton: NSButton? = existing == nil
            ? nil
            : NSButton(title: "取消收藏", target: self, action: #selector(removeBookmarkFromEditor))
        removeButton?.translatesAutoresizingMaskIntoConstraints = false
        removeButton?.contentTintColor = .systemRed

        content.addSubview(placementLabel)
        content.addSubview(placementControl)
        content.addSubview(folderLabel)
        content.addSubview(folderField)
        content.addSubview(folderPicker)
        content.addSubview(nameLabel)
        content.addSubview(nameField)
        content.addSubview(pathLabel)
        content.addSubview(pathField)
        content.addSubview(cancelButton)
        content.addSubview(saveButton)
        if let removeButton {
            content.addSubview(removeButton)
        }
        editor.contentView = content

        NSLayoutConstraint.activate([
            placementLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            placementLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            placementLabel.widthAnchor.constraint(equalToConstant: 112),
            placementControl.leadingAnchor.constraint(equalTo: placementLabel.trailingAnchor, constant: 12),
            placementControl.centerYAnchor.constraint(equalTo: placementLabel.centerYAnchor),
            placementControl.widthAnchor.constraint(equalToConstant: 160),

            folderLabel.leadingAnchor.constraint(equalTo: placementLabel.leadingAnchor),
            folderLabel.topAnchor.constraint(equalTo: placementLabel.bottomAnchor, constant: 18),
            folderLabel.widthAnchor.constraint(equalTo: placementLabel.widthAnchor),
            folderField.leadingAnchor.constraint(equalTo: placementControl.leadingAnchor),
            folderField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            folderField.centerYAnchor.constraint(equalTo: folderLabel.centerYAnchor),

            folderPicker.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            folderPicker.topAnchor.constraint(equalTo: folderField.bottomAnchor, constant: 8),
            folderPicker.widthAnchor.constraint(equalToConstant: 180),

            nameLabel.leadingAnchor.constraint(equalTo: folderLabel.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: folderPicker.bottomAnchor, constant: 16),
            nameLabel.widthAnchor.constraint(equalTo: folderLabel.widthAnchor),
            nameField.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: folderField.trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: folderLabel.leadingAnchor),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 18),
            pathLabel.widthAnchor.constraint(equalTo: folderLabel.widthAnchor),
            pathField.leadingAnchor.constraint(equalTo: folderField.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: folderField.trailingAnchor),
            pathField.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),

            pathLabel.bottomAnchor.constraint(lessThanOrEqualTo: saveButton.topAnchor, constant: -16),

            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
        ])
        if let removeButton {
            NSLayoutConstraint.activate([
                removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                removeButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor)
            ])
        }

        bookmarkEditorPanel = editor
        bookmarkFolderField = folderField
        bookmarkFolderPicker = folderPicker
        bookmarkNameField = nameField
        bookmarkPathField = pathField
        bookmarkPlacementControl = placementControl
        if let host = window {
            let frame = editor.frame
            editor.setFrameOrigin(NSPoint(
                x: host.frame.midX - frame.width / 2,
                y: host.frame.midY - frame.height / 2
            ))
        } else {
            editor.center()
        }
        editor.makeKeyAndOrderFront(nil)
        editor.makeFirstResponder(nameField)
    }

    /// Default UI label for bar placement (stored as empty folder string).
    private static let favoritesBarFolderName = "收藏栏"

    private static func normalizedFavoritesFolderDisplay(_ raw: String?) -> String {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if AppSettings.isFavoritesBarFolder(name) {
            return favoritesBarFolderName
        }
        return name
    }

    /// Persist empty folder for「收藏栏」so the address sits on the bar, not in a folder chip.
    private static func storageFolder(fromDisplay raw: String?) -> String {
        let display = normalizedFavoritesFolderDisplay(raw)
        return display == favoritesBarFolderName ? "" : display
    }

    private static func populateFavoritesFolderPicker(
        _ picker: NSPopUpButton,
        folders: [String],
        selected: String
    ) {
        picker.removeAllItems()
        picker.addItem(withTitle: favoritesBarFolderName)
        picker.item(at: 0)?.toolTip = "直接显示在收藏栏上（类似 Chrome），不放进文件夹"

        var seen = Set([favoritesBarFolderName])
        for folder in folders {
            let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !AppSettings.isFavoritesBarFolder(name), !seen.contains(name) else { continue }
            picker.addItem(withTitle: name)
            seen.insert(name)
        }

        let target = normalizedFavoritesFolderDisplay(selected)
        if let index = picker.itemTitles.firstIndex(of: target) {
            picker.selectItem(at: index)
        } else if !AppSettings.isFavoritesBarFolder(target) {
            picker.addItem(withTitle: target)
            picker.selectItem(withTitle: target)
        } else {
            picker.selectItem(at: 0)
        }
        picker.isEnabled = true
    }

    @objc private func bookmarkPlacementChanged(_ sender: NSSegmentedControl) {
        editingBookmarkPlacement = sender.selectedSegment == 1 ? .top : .left
        refreshBookmarkFolderPicker(for: editingBookmarkPlacement)
    }

    private func refreshBookmarkFolderPicker(for placement: FavoritesPlacement) {
        guard let folderPicker = bookmarkFolderPicker else { return }
        let current = Self.normalizedFavoritesFolderDisplay(bookmarkFolderField?.stringValue)
        let keepCustom = editingBookmarkID != nil
            && current != Self.favoritesBarFolderName
            && !settings.orderedBookmarkFolders(for: placement).contains(current)
        let selected = keepCustom ? current : Self.favoritesBarFolderName
        Self.populateFavoritesFolderPicker(
            folderPicker,
            folders: settings.orderedBookmarkFolders(for: placement),
            selected: selected
        )
        bookmarkFolderField?.stringValue = folderPicker.titleOfSelectedItem ?? Self.favoritesBarFolderName
    }

    @objc private func cancelBookmarkEditor() {
        bookmarkEditorPanel?.orderOut(nil)
        bookmarkEditorPanel = nil
        editingBookmarkID = nil
        editingBookmarkPlacement = .left
    }

    @objc private func bookmarkFolderPickerChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem, !title.isEmpty else { return }
        bookmarkFolderField?.stringValue = title
    }

    @objc private func saveBookmarkEditor() {
        let folder = Self.storageFolder(fromDisplay: bookmarkFolderField?.stringValue)
        let name = bookmarkNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawPath = bookmarkPathField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        // folder may be empty when saving to the bar itself
        guard !name.isEmpty, !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            statusLabel.stringValue = "请填写有效的文件夹收藏"
            return
        }

        let placement: FavoritesPlacement =
            bookmarkPlacementControl?.selectedSegment == 1 ? .top : .left
        editingBookmarkPlacement = placement

        var updated = settings.bookmarks
        // Keep left/top independent: same path may exist once per surface.
        let bookmarkID = editingBookmarkID
            ?? updated.first(where: {
                $0.placement == placement
                    && URL(fileURLWithPath: $0.path).standardizedFileURL.path
                    == URL(fileURLWithPath: path).standardizedFileURL.path
            })?.id
            ?? UUID()
        let bookmark = Bookmark(
            id: bookmarkID,
            name: name,
            path: path,
            folder: folder,
            placement: placement
        )
        if let index = updated.firstIndex(where: { $0.id == bookmarkID }) {
            updated[index] = bookmark
        } else {
            updated.append(bookmark)
        }
        settings.bookmarks = updated
        appendFolder(folder, to: placement)
        applyFavoritesLayout(animated: true)
        reloadFavoritesSidebar()
        statusLabel.stringValue = placement == .top ? "已收藏到顶部" : "已收藏到左侧"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.updateStatus(selection: self.contentController.selectedItems)
        }
        cancelBookmarkEditor()
    }

    private func appendFolder(_ folder: String, to placement: FavoritesPlacement) {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !AppSettings.isFavoritesBarFolder(name) else { return }
        if placement == .top {
            if !settings.topBookmarkFolderOrder.contains(name) {
                settings.topBookmarkFolderOrder = settings.topBookmarkFolderOrder + [name]
            }
        } else if !settings.bookmarkFolderOrder.contains(name) {
            settings.bookmarkFolderOrder = settings.bookmarkFolderOrder + [name]
        }
    }

    @objc private func removeBookmarkFromEditor() {
        guard let editingBookmarkID else { return }
        removeBookmark(id: editingBookmarkID)
        statusLabel.stringValue = "已取消收藏"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.updateStatus(selection: self.contentController.selectedItems)
        }
        cancelBookmarkEditor()
    }

    private func removeBookmark(id: UUID) {
        var bookmarks = settings.bookmarks
        bookmarks.removeAll { $0.id == id }
        settings.bookmarks = bookmarks
        reloadFavoritesSidebar()
    }

    private func deleteBookmarkFolder(_ folder: String, placement: FavoritesPlacement) {
        let alert = NSAlert()
        alert.messageText = "删除收藏夹"
        let side = placement == .top ? "顶部" : "左侧"
        alert.informativeText = "将删除\(side)「\(folder)」及其全部收藏，不会影响另一侧。此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var bookmarks = settings.bookmarks
        bookmarks.removeAll { $0.folder == folder && $0.placement == placement }
        settings.bookmarks = bookmarks
        if placement == .top {
            settings.topBookmarkFolderOrder = settings.topBookmarkFolderOrder.filter { $0 != folder }
        } else {
            settings.bookmarkFolderOrder = settings.bookmarkFolderOrder.filter { $0 != folder }
        }
        reloadFavoritesSidebar()
    }

    private func addCurrentDirectoryToFolder(_ folder: String, placement: FavoritesPlacement) {
        let path = currentDirectory.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        var bookmarks = settings.bookmarks
        if let index = bookmarks.firstIndex(where: {
            $0.placement == placement
                && URL(fileURLWithPath: $0.path).standardizedFileURL.path == path
        }) {
            bookmarks[index].folder = folder
            if bookmarks[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bookmarks[index].name = currentDirectory.lastPathComponent
            }
        } else {
            let name = path == "/" ? "Macintosh HD" : currentDirectory.lastPathComponent
            bookmarks.append(
                Bookmark(
                    name: name.isEmpty ? path : name,
                    path: path,
                    folder: folder,
                    placement: placement
                )
            )
        }
        settings.bookmarks = bookmarks
        appendFolder(folder, to: placement)
        reloadFavoritesSidebar()
        let side = placement == .top ? "顶部" : "左侧"
        statusLabel.stringValue = "已加入\(side)「\(folder)」"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.updateStatus(selection: self.contentController.selectedItems)
        }
    }

    private func createBookmarkFolder(placement: FavoritesPlacement) {
        let alert = NSAlert()
        alert.messageText = placement == .top ? "新建顶部收藏夹" : "新建收藏夹"
        alert.informativeText = "输入收藏夹名称："
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "收藏夹")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            return
        }
        appendFolder(name, to: placement)
        reloadFavoritesSidebar()
        statusLabel.stringValue = "已创建收藏夹「\(name)」"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            self.updateStatus(selection: self.contentController.selectedItems)
        }
    }

    private func showBookmarkFolderEditor(_ folder: String, placement: FavoritesPlacement) {
        let alert = NSAlert()
        alert.messageText = "重命名收藏夹"
        alert.informativeText = placement == .top ? "顶部收藏夹名称：" : "左侧收藏夹名称："
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "删除收藏夹")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: folder)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        editingBookmarkFolderName = folder
        editingBookmarkFolderPlacement = placement
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != folder else {
                editingBookmarkFolderName = nil
                return
            }
            var bookmarks = settings.bookmarks
            for i in bookmarks.indices where bookmarks[i].folder == folder && bookmarks[i].placement == placement {
                bookmarks[i].folder = newName
            }
            settings.bookmarks = bookmarks
            if placement == .top {
                settings.topBookmarkFolderOrder = settings.topBookmarkFolderOrder.map { $0 == folder ? newName : $0 }
            } else {
                settings.bookmarkFolderOrder = settings.bookmarkFolderOrder.map { $0 == folder ? newName : $0 }
            }
            reloadFavoritesSidebar()
        } else if response == .alertSecondButtonReturn {
            deleteBookmarkFolder(folder, placement: placement)
        }
        editingBookmarkFolderName = nil
    }

    @objc func openBookmarkMenuItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, !path.isEmpty else {
            NSSound.beep()
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        navigate(to: url)
    }

    @objc func openSettings(_ sender: Any?) {
        AppDelegate.shared.showPreferences(nil)
    }

    @objc private func settingsChanged() {
        // New-type /「单独展示」changes only affect the titlebar New cluster.
        // Avoid reloading favorites / contents — that causes the top favorites bar to flash.
        chromeHeader.rebuildNewItemTypes(settings.newItemTypes)
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        if activeTab.isActivityMonitorTab || activeTab.isTemperatureTab || activeTab.isCompareTab { return }
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
            reloadContents()
            return
        }
        applySearch(query: query)
    }

    // MARK: - Path editing

    private func beginPathEditing() {
        guard !isEditingPath else {
            window?.makeFirstResponder(pathField)
            return
        }
        isEditingPath = true
        pathField.stringValue = currentDirectory.path
        breadcrumbClip.isHidden = true
        pathField.isHidden = false
        window?.makeFirstResponder(pathField)
        installPathEditClickMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.pathField.currentEditor()?.selectAll(nil)
        }
    }

    private func endPathEditing(commit: Bool) {
        removePathEditClickMonitor()
        hideAutocomplete()
        guard isEditingPath else { return }
        if commit {
            let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                navigate(to: URL(fileURLWithPath: expanded))
            } else if FileManager.default.fileExists(atPath: expanded) {
                let file = URL(fileURLWithPath: expanded)
                pendingSelectURLs = [file]
                navigate(to: file.deletingLastPathComponent())
            } else {
                NSSound.beep()
            }
        }
        isEditingPath = false
        pathField.isHidden = true
        breadcrumbClip.isHidden = false
        updatePathChrome()
        if window?.firstResponder === pathField || window?.firstResponder is NSText {
            window?.makeFirstResponder(contentController.view)
        }
    }

    private func installPathEditClickMonitor() {
        removePathEditClickMonitor()
        pathEditClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isEditingPath else { return event }
            if self.isEventInsidePathEditingUI(event) {
                return event
            }
            self.endPathEditing(commit: false)
            return event
        }
    }

    private func removePathEditClickMonitor() {
        if let pathEditClickMonitor {
            NSEvent.removeMonitor(pathEditClickMonitor)
            self.pathEditClickMonitor = nil
        }
    }

    private func isEventInsidePathEditingUI(_ event: NSEvent) -> Bool {
        if let panel = autocompletePanel, panel.isVisible, event.window === panel {
            return true
        }
        guard let window = event.window, window === self.window else { return false }
        let location = event.locationInWindow
        let fieldFrame = pathField.convert(pathField.bounds, to: nil)
        if fieldFrame.insetBy(dx: -2, dy: -2).contains(location) {
            return true
        }
        return false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === pathField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                _ = applySelectedAutocomplete(partial: false)
                endPathEditing(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                endPathEditing(commit: false)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                selectAutocomplete(offset: 1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                selectAutocomplete(offset: -1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                _ = applySelectedAutocomplete(partial: true)
                return true
            }
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        let candidates = FileOperations.pathAutocomplete(for: pathField.stringValue)
        showAutocomplete(candidates)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        if isEditingPath {
            endPathEditing(commit: false)
        }
    }

    private func showAutocomplete(_ candidates: [String]) {
        autocompleteCandidates = candidates
        guard !candidates.isEmpty, let window else {
            hideAutocomplete()
            return
        }

        if autocompletePanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .controlBackgroundColor
            panel.hasShadow = true

            let scroll = NSScrollView(frame: panel.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let table = NSTableView(frame: scroll.bounds)
            let column = NSTableColumn(identifier: .init("path"))
            column.width = 380
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 22
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.action = #selector(autocompleteClicked)
            scroll.documentView = table
            panel.contentView?.addSubview(scroll)

            autocompletePanel = panel
            autocompleteList = table
        }

        autocompleteList?.reloadData()
        let fieldRect = pathField.convert(pathField.bounds, to: nil)
        let screenRect = window.convertToScreen(fieldRect)
        let height = min(CGFloat(candidates.count) * 22 + 8, 180)
        autocompletePanel?.setFrame(
            NSRect(x: screenRect.minX, y: screenRect.minY - height - 2, width: max(screenRect.width, 320), height: height),
            display: true
        )
        autocompletePanel?.orderFront(nil)
    }

    private func hideAutocomplete() {
        autocompletePanel?.orderOut(nil)
        autocompleteCandidates = []
    }

    @objc private func autocompleteClicked() {
        guard let row = autocompleteList?.selectedRow, row >= 0, row < autocompleteCandidates.count else { return }
        pathField.stringValue = autocompleteCandidates[row]
        endPathEditing(commit: true)
    }

    private func selectAutocomplete(offset: Int) {
        guard let table = autocompleteList, !autocompleteCandidates.isEmpty else { return }
        let next = max(0, min(autocompleteCandidates.count - 1, table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
        pathField.stringValue = autocompleteCandidates[next]
    }

    /// Apply highlighted autocomplete candidate. `partial` keeps editing with the chosen path.
    @discardableResult
    private func applySelectedAutocomplete(partial: Bool) -> Bool {
        guard !autocompleteCandidates.isEmpty else { return false }
        let row = max(0, autocompleteList?.selectedRow ?? 0)
        guard autocompleteCandidates.indices.contains(row) else { return false }
        pathField.stringValue = autocompleteCandidates[row]
        if !partial {
            hideAutocomplete()
        }
        return true
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        activityMonitorController?.deactivate()
        temperatureController?.deactivate()
        compareController?.deactivate()
        for tab in tabs where tab.isCompareTab {
            CompareSession.shared.clearWorkspace(tab.compareWorkspaceIndex)
        }
        stopWatching()
        hideAutocomplete()
    }
}

/// macOS traffic-light close (red disk + × on hover). Drawn ourselves so AppKit cannot
/// yank the real `.closeButton` back to the leading titlebar.
final class MacStyleCloseButton: NSControl {
    private let disk = CALayer()
    private let mark = CATextLayer()
    private var hover = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = false
        isEnabled = true

        disk.cornerRadius = 6
        disk.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        layer?.addSublayer(disk)

        mark.string = "×"
        mark.alignmentMode = .center
        mark.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        mark.foregroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        mark.frame = CGRect(x: 0, y: -0.5, width: 12, height: 12)
        mark.isHidden = true
        // CATextLayer uses UI-style fonts via CFString.
        mark.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        mark.fontSize = 9
        disk.addSublayer(mark)

        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }

    override func layout() {
        super.layout()
        let size: CGFloat = 12
        disk.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        disk.position = CGPoint(x: bounds.midX, y: bounds.midY)
        mark.frame = CGRect(x: 0, y: -0.5, width: size, height: size)
        mark.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        updateColors()
    }

    override func mouseExited(with event: NSEvent) {
        hover = false
        pressed = false
        updateColors()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Track until mouseUp so the click still fires even if AppKit wouldn't
        // deliver mouseUp after a custom mouseDown (NSButton pitfall).
        pressed = true
        updateColors()
        var keepTracking = true
        while keepTracking {
            guard let next = window?.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            let local = convert(next.locationInWindow, from: nil)
            let inside = bounds.contains(local)
            switch next.type {
            case .leftMouseDragged:
                pressed = inside
                updateColors()
            case .leftMouseUp:
                pressed = false
                updateColors()
                if inside {
                    sendAction(action, to: target)
                }
                keepTracking = false
            default:
                keepTracking = false
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshAppearance()
    }

    func refreshAppearance() {
        updateColors()
    }

    private func updateColors() {
        let key = window?.isKeyWindow ?? true
        let fill: NSColor
        let border: NSColor
        if !key {
            fill = NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.75, alpha: 1)
            border = NSColor(calibratedRed: 0.65, green: 0.65, blue: 0.65, alpha: 1)
        } else if pressed {
            fill = NSColor(calibratedRed: 0.75, green: 0.14, blue: 0.11, alpha: 1)
            border = NSColor(calibratedRed: 0.60, green: 0.10, blue: 0.08, alpha: 1)
        } else {
            fill = NSColor(calibratedRed: 1.0, green: 0.373, blue: 0.341, alpha: 1)
            border = NSColor(calibratedRed: 0.878, green: 0.267, blue: 0.243, alpha: 1)
        }
        disk.backgroundColor = fill.cgColor
        disk.borderColor = border.cgColor
        disk.borderWidth = 0.5
        mark.isHidden = !(hover && key)
    }
}

/// Path bar that enters edit mode when clicking empty space (Finder-like).
final class ClickablePathBarView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Clips long breadcrumbs so they cannot force the window wider.
/// Hides whole leading segments (never mid-glyph) and shows "…" when collapsed,
/// keeping the trailing (current folder) crumb visible.
final class BreadcrumbClipView: NSView {
    private weak var stack: NSStackView?
    private var lastCollapseWidth: CGFloat = -1
    private var lastArrangedCount = -1
    private let ellipsisLabel: NSTextField = {
        let label = NSTextField(labelWithString: "…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = true
        return label
    }()

    func embed(_ stack: NSStackView) {
        self.stack?.removeFromSuperview()
        self.stack = stack
        if ellipsisLabel.superview == nil {
            addSubview(ellipsisLabel)
        }
        addSubview(stack)
        // Frame-based layout in layout(); avoid Auto Layout fighting the clip.
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.autoresizingMask = []
        lastCollapseWidth = -1
        lastArrangedCount = -1
    }

    func refreshLayout() {
        lastCollapseWidth = -1
        lastArrangedCount = -1
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let stack else { return }

        let views = stack.arrangedSubviews
        let available = bounds.width
        let height = max(bounds.height, 20)

        // Column-view rebuilds can transiently pass a near-zero width; collapsing
        // crumbs then would flash the whole path. Keep the previous arrangement.
        guard available > 8 else { return }

        let widthChanged = abs(available - lastCollapseWidth) > 0.5
        let countChanged = views.count != lastArrangedCount
        if widthChanged || countChanged {
            lastCollapseWidth = available
            lastArrangedCount = views.count
            recomputeCollapsedSegments(stack: stack, views: views, available: available)
        }

        positionBreadcrumbStack(stack: stack, views: views, available: available, height: height)
    }

    private func recomputeCollapsedSegments(stack: NSStackView, views: [NSView], available: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for view in views {
                view.isHidden = false
            }
            ellipsisLabel.isHidden = true

            // Hide whole leading crumbs until the trail fits. Never clip mid-label.
            while true {
                stack.layoutSubtreeIfNeeded()
                let width = max(stack.fittingSize.width, 0)
                if width <= available { break }

                let visibleButtons = views.enumerated().filter {
                    !$0.element.isHidden && $0.element is BreadcrumbButton
                }
                guard visibleButtons.count > 1 else { break }

                let idx = visibleButtons[0].offset
                views[idx].isHidden = true
                if idx + 1 < views.count, views[idx + 1] is BreadcrumbChevronButton {
                    views[idx + 1].isHidden = true
                }
            }
        }
    }

    private func positionBreadcrumbStack(stack: NSStackView, views: [NSView], available: CGFloat, height: CGFloat) {
        let collapsed = views.contains(where: \.isHidden)
        var leading: CGFloat = 0
        if collapsed {
            ellipsisLabel.isHidden = false
            ellipsisLabel.sizeToFit()
            let eSize = ellipsisLabel.fittingSize
            ellipsisLabel.frame = NSRect(
                x: 0,
                y: (height - eSize.height) / 2,
                width: eSize.width,
                height: eSize.height
            )
            leading = eSize.width + 4
        } else {
            ellipsisLabel.isHidden = true
        }

        stack.layoutSubtreeIfNeeded()
        var size = stack.fittingSize
        if size.width < 1 {
            size.width = max(0, available - leading)
        }
        size.height = height

        // Prefer leading alignment; if still slightly over, pin trailing so leaf stays visible.
        let contentWidth = available - leading
        let x: CGFloat
        if size.width <= contentWidth {
            x = leading
        } else {
            x = leading + (contentWidth - size.width)
        }
        stack.frame = NSRect(x: x, y: 0, width: size.width, height: height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Empty clip area → fall through to path bar for edit-on-click.
        return hit === self ? nil : hit
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }
}

/// Stack that lets empty-area clicks fall through to the path bar.
final class PassThroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override var intrinsicContentSize: NSSize {
        // Natural width for clip positioning; height follows content.
        let size = super.intrinsicContentSize
        return size
    }
}

/// Breadcrumb segment with a light hover background.
final class BreadcrumbButton: NSButton {
    private var tracking: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        isTransparent = false
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 12)
        focusRingType = .none
        sendAction(on: [.leftMouseUp])
        wantsLayer = true
        layer?.cornerRadius = 4
        lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 10
        size.height = max(size.height, 20)
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            // Light hover — works in light & dark appearance
            let fill = NSColor.labelColor.withAlphaComponent(0.08)
            fill.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Path-bar chevron: hover highlight + click to list directory contents.
final class BreadcrumbChevronButton: NSView {
    var directoryPath = ""
    var onClick: (() -> Void)?

    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3

        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "目录内容")!
        imageView.image = image
        imageView.contentTintColor = .tertiaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 8),
            imageView.heightAnchor.constraint(equalToConstant: 10),
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        imageView.contentTintColor = .secondaryLabelColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        imageView.contentTintColor = .tertiaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        // Consume so path bar doesn't treat this as empty-area click.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
        super.draw(dirtyRect)
    }
}

extension BrowserWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        0
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Favorites sidebar: keep a sliver of content. Column split: no floor.
        if splitView === mainSplitView {
            return max(0, splitView.bounds.width - 40)
        }
        return max(0, splitView.bounds.width)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        if splitView === mainSplitView {
            return subview === favoritesSidebar.view
        }
        // Extra browser columns may shrink to zero; primary stays via max/min of siblings.
        return subview !== primaryColumnHost
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        guard splitView === mainSplitView else { return false }
        return favoritesSidebar.view.isHidden || !settings.favoritesSidebarVisible
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingFavoritesLayout else { return }
        guard let split = mainSplitView, split === (notification.object as? NSSplitView) else { return }
        guard split.subviews.count >= 1 else { return }
        guard settings.favoritesSidebarVisible,
              !favoritesSidebar.view.isHidden else { return }
        let width = split.subviews[0].bounds.width
        // Skip only fully collapsed (e.g. transient layout); any positive width is remembered.
        guard width > 0 else { return }
        settings.favoritesSidebarWidth = width
    }
}

extension BrowserWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        autocompleteCandidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        cell.textField?.stringValue = autocompleteCandidates[row]
        cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return cell
    }
}
