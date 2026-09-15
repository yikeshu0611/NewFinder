import AppKit

/// One in-window file-browser column (path bar + list + status). Used for the dual-pane split.
final class BrowserPaneController: NSViewController, NSSearchFieldDelegate {
    var onFocus: (() -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onOpenDirectory: ((URL) -> Void)?
    var onCutRequest: (() -> Void)?
    var onCopyRequest: (() -> Void)?
    var onPasteRequest: (() -> Void)?
    var onRenameCommit: ((FileItem, String) -> Void)?
    var onDirectoryNeedsReload: (() -> Void)?
    var onOpenArchives: (([URL]) -> Void)?
    var onPerformFileDrop: (([URL], URL, Bool) -> Void)?
    var onBookmarkDirectory: ((URL) -> Void)?
    var onCopyPath: (([URL], URL) -> Void)?
    var onGoEnclosingFolder: (() -> Void)?
    var onToggleFavoritesSidebar: (() -> Void)?
    var onToggleFavoritesTopBar: (() -> Void)?

    private(set) var directory: URL
    private let history = NavigationHistory()
    private(set) var contentController = ContentViewController()

    private var pathBar: ClickablePathBarView!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var upButton: NSButton!
    private var copyPathButton: NSButton!
    private var breadcrumbClip: BreadcrumbClipView!
    private var breadcrumbStack: PassThroughStackView!
    private var pathField: NSTextField!
    private var pathBookmarkButton: NSButton!
    private var searchField: NSSearchField!
    private var statusLabel: NSTextField!
    private var statusBar: NSView!

    private var loadGeneration = 0
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var pendingReload: DispatchWorkItem?
    private var isEditingPath = false

    private var pathFieldDelegate: PathFieldDelegateProxy!

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        super.init(nibName: nil, bundle: nil)
        history.navigate(to: self.directory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopWatching()
    }

    override func loadView() {
        let root = FocusCaptureView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        root.onMouseDown = { [weak self] in self?.onFocus?() }
        view = root
        configureUI()
        wireContent()
        navigate(to: directory, recordHistory: false)
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            NSSound.beep()
            return
        }
        onFocus?()
        let standardized = url.standardizedFileURL
        directory = standardized
        if recordHistory {
            history.navigate(to: standardized)
        }
        searchField.stringValue = ""
        contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
        updatePathChrome()
        watchDirectory(standardized)
        reloadContents()
    }

    func reloadContents() {
        pendingReload?.cancel()
        pendingReload = nil
        loadGeneration += 1
        let generation = loadGeneration
        let showHidden = AppSettings.shared.showHiddenFiles
        let dir = directory
        statusLabel.stringValue = "正在加载…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = FileOperations.listDirectory(dir, showHidden: showHidden)
            DispatchQueue.main.async {
                guard let self, generation == self.loadGeneration else { return }
                self.contentController.setItems(items, alreadySortedByName: true)
                self.updateStatus(selection: self.contentController.selectedItems)
            }
        }
    }

    func applyZoom(_ percent: Int) {
        contentController.applyZoomFactor(CGFloat(min(500, max(30, percent))) / 100)
    }

    // MARK: - UI

    private func configureUI() {
        pathBar = ClickablePathBarView()
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.wantsLayer = true
        pathBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        pathBar.onBackgroundClick = { [weak self] in
            guard let self else { return }
            if self.isEditingPath {
                self.endPathEditing(commit: false)
            } else {
                self.beginPathEditing()
            }
        }

        backButton = makeNavButton("chevron.left", tip: "后退", action: #selector(goBack))
        forwardButton = makeNavButton("chevron.right", tip: "前进", action: #selector(goForward))
        upButton = makeNavButton("chevron.up", tip: "上层文件夹", action: #selector(goUp))
        copyPathButton = makeNavButton("doc.on.doc", tip: "复制路径", action: #selector(copyPathClicked))

        breadcrumbStack = PassThroughStackView()
        breadcrumbStack.orientation = .horizontal
        breadcrumbStack.spacing = 2
        breadcrumbStack.alignment = .centerY
        breadcrumbStack.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbStack.setHuggingPriority(.defaultHigh, for: .horizontal)
        breadcrumbStack.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)

        breadcrumbClip = BreadcrumbClipView()
        breadcrumbClip.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbClip.wantsLayer = true
        breadcrumbClip.clipsToBounds = true
        breadcrumbClip.setContentHuggingPriority(.defaultLow, for: .horizontal)
        breadcrumbClip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbClip.embed(breadcrumbStack)

        pathField = NSTextField()
        pathField.placeholderString = "输入路径后回车前往，Esc 取消"
        pathField.isBordered = true
        pathField.isBezeled = true
        pathField.bezelStyle = .roundedBezel
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.isHidden = true
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.target = self
        pathField.action = #selector(pathFieldAction)
        pathFieldDelegate = PathFieldDelegateProxy(owner: self)
        pathField.delegate = pathFieldDelegate

        pathBookmarkButton = makeNavButton("star", tip: "收藏当前地址", action: #selector(bookmarkClicked))
        pathBookmarkButton.setContentHuggingPriority(.required, for: .horizontal)

        searchField = NSSearchField()
        searchField.placeholderString = "搜索"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true

        let trailing = NSStackView(views: [pathBookmarkButton, searchField])
        trailing.orientation = .horizontal
        trailing.spacing = 6
        trailing.alignment = .centerY
        trailing.translatesAutoresizingMaskIntoConstraints = false

        pathBar.addSubview(backButton)
        pathBar.addSubview(forwardButton)
        pathBar.addSubview(upButton)
        pathBar.addSubview(copyPathButton)
        pathBar.addSubview(breadcrumbClip)
        pathBar.addSubview(pathField)
        pathBar.addSubview(trailing)

        contentController.view.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        statusBar.addSubview(statusLabel)

        view.addSubview(pathBar)
        view.addSubview(contentController.view)
        view.addSubview(statusBar)

        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: view.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: 29),

            backButton.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: 6),
            backButton.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 20),
            backButton.heightAnchor.constraint(equalToConstant: 20),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 20),
            forwardButton.heightAnchor.constraint(equalToConstant: 20),

            upButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            upButton.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 20),
            upButton.heightAnchor.constraint(equalToConstant: 20),

            copyPathButton.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 6),
            copyPathButton.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),
            copyPathButton.widthAnchor.constraint(equalToConstant: 22),
            copyPathButton.heightAnchor.constraint(equalToConstant: 22),

            breadcrumbClip.leadingAnchor.constraint(equalTo: copyPathButton.trailingAnchor, constant: 6),
            breadcrumbClip.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8),
            breadcrumbClip.topAnchor.constraint(equalTo: pathBar.topAnchor),
            breadcrumbClip.bottomAnchor.constraint(equalTo: pathBar.bottomAnchor),

            pathField.leadingAnchor.constraint(equalTo: copyPathButton.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),

            trailing.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: pathBar.centerYAnchor),

            contentController.view.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            contentController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentController.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])
    }

    private func wireContent() {
        contentController.onOpen = { [weak self] item in
            guard let self else { return }
            self.onFocus?()
            if item.isDirectory {
                self.navigate(to: item.url)
                self.onOpenDirectory?(item.url)
            } else if ArchiveSupport.looksLikeArchive(item.url) {
                AppSettings.shared.recordOpenHistory(item.url)
                self.onOpenArchives?([item.url])
            } else {
                AppSettings.shared.recordOpenHistory(item.url)
                self.onOpenFile?(item.url)
            }
        }
        contentController.onSelectionChange = { [weak self] items in
            self?.onFocus?()
            self?.updateStatus(selection: items)
        }
        contentController.onRenameRequest = { [weak self] item in
            self?.contentController.beginInlineRename(item)
        }
        contentController.onCommitRename = { [weak self] item, name in
            self?.onRenameCommit?(item, name)
        }
        contentController.onCutRequest = { [weak self] in self?.onCutRequest?() }
        contentController.onCopyRequest = { [weak self] in self?.onCopyRequest?() }
        contentController.onPasteRequest = { [weak self] in self?.onPasteRequest?() }
        contentController.onGoEnclosingFolder = { [weak self] in
            self?.onFocus?()
            self?.goUp()
            self?.onGoEnclosingFolder?()
        }
        contentController.onToggleFavoritesSidebar = { [weak self] in self?.onToggleFavoritesSidebar?() }
        contentController.onToggleFavoritesTopBar = { [weak self] in self?.onToggleFavoritesTopBar?() }
        contentController.onCopyPathRequest = { [weak self] in self?.copyPathClicked() }
        contentController.onDirectoryNeedsReload = { [weak self] in
            self?.reloadContents()
            self?.onDirectoryNeedsReload?()
        }
        contentController.onOpenArchives = { [weak self] urls in self?.onOpenArchives?(urls) }
        contentController.directoryForDrop = { [weak self] in
            self?.directory ?? FileManager.default.homeDirectoryForCurrentUser
        }
        contentController.onPerformFileDrop = { [weak self] urls, dest, copying in
            self?.onPerformFileDrop?(urls, dest, copying)
        }
        contentController.onClearSearch = { [weak self] in
            self?.searchField.stringValue = ""
            self?.contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
            self?.reloadContents()
        }
        contentController.onRevealInEnclosingFolder = { [weak self] url in
            guard let self else { return }
            self.navigate(to: url.deletingLastPathComponent())
            self.contentController.select(urls: [url.standardizedFileURL])
        }
    }

    private func makeNavButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.image?.isTemplate = true
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.focusRingType = .none
        return button
    }

    private func updatePathChrome() {
        pathField.stringValue = directory.path
        breadcrumbStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let components = directory.pathComponents
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
                        self.showBreadcrumbMenu(at: built, from: chevron)
                    }
                }
                breadcrumbStack.addArrangedSubview(chevron)
            }
        }
        breadcrumbClip.isHidden = isEditingPath
        pathField.isHidden = !isEditingPath
        breadcrumbClip.refreshLayout()
    }

    private func updateStatus(selection: [FileItem]) {
        let items = contentController.items
        let total = items.count
        let totalBytes = items.compactMap(\.fileSize).reduce(Int64(0), +)
        let selectedBytes = selection.compactMap(\.fileSize).reduce(Int64(0), +)
        statusLabel.stringValue = String(
            format: "%d 个项目, %@, 已选中 %d 个, %@",
            total,
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file),
            selection.count,
            ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
        )
    }

    // MARK: - Actions

    func navigateBack() { goBack() }
    func navigateForward() { goForward() }
    func navigateUp() { goUp() }

    @objc private func goBack() {
        onFocus?()
        if let url = history.goBack() {
            navigate(to: url, recordHistory: false)
        }
    }

    @objc private func goForward() {
        onFocus?()
        if let url = history.goForward() {
            navigate(to: url, recordHistory: false)
        }
    }

    @objc private func goUp() {
        onFocus?()
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        let left = directory
        navigate(to: parent)
        contentController.select(urls: [left])
    }

    @objc private func copyPathClicked() {
        onFocus?()
        let selected = contentController.selectedItems.map(\.url)
        onCopyPath?(selected, directory)
    }

    @objc private func bookmarkClicked() {
        onFocus?()
        onBookmarkDirectory?(directory)
    }

    @objc private func breadcrumbClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        navigate(to: URL(fileURLWithPath: path))
    }

    private func showBreadcrumbMenu(at path: String, from source: NSView) {
        let url = URL(fileURLWithPath: path)
        let showHidden = AppSettings.shared.showHiddenFiles
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            return
        }
        let menu = NSMenu()
        for child in children.prefix(80) {
            let item = NSMenuItem(title: child.lastPathComponent, action: #selector(breadcrumbMenuClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = child
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: source)
    }

    @objc private func breadcrumbMenuClicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        navigate(to: url)
    }

    private func beginPathEditing() {
        isEditingPath = true
        pathField.stringValue = directory.path
        breadcrumbClip.isHidden = true
        pathField.isHidden = false
        view.window?.makeFirstResponder(pathField)
    }

    private func endPathEditing(commit: Bool) {
        defer {
            isEditingPath = false
            breadcrumbClip.isHidden = false
            pathField.isHidden = true
            updatePathChrome()
        }
        guard commit else { return }
        let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: expanded))
    }

    @objc private func pathFieldAction() {
        endPathEditing(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endPathEditing(commit: false)
            return true
        }
        return false
    }

    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        applySearch(sender.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        applySearch("")
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        applySearch(field.stringValue)
    }

    private func applySearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            contentController.setSearchResultsMode(query: nil, scopeName: "", resultCount: 0)
            reloadContents()
            return
        }
        let dir = directory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let urls = FileOperations.search(in: dir, query: trimmed)
            let items = urls.compactMap { FileItem.from(url: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.contentController.setItems(items, alreadySortedByName: false)
                self.contentController.setSearchResultsMode(
                    query: trimmed,
                    scopeName: dir.lastPathComponent,
                    resultCount: items.count
                )
                self.updateStatus(selection: self.contentController.selectedItems)
            }
        }
    }

    // MARK: - Watch

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
            self?.scheduleReload()
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

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadContents() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

// MARK: - Helpers

private final class FocusCaptureView: NSView {
    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
}

private final class PathFieldDelegateProxy: NSObject, NSTextFieldDelegate {
    weak var owner: BrowserPaneController?

    init(owner: BrowserPaneController) {
        self.owner = owner
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        owner?.control(control, textView: textView, doCommandBy: commandSelector) ?? false
    }
}
