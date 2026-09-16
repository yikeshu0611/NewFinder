import AppKit

/// Dedicated WinRAR-style archive browser: folder tree + file list + extract toolbar.
final class ArchiveWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate
{
    let archiveURL: URL

    private var internalPath = ""
    private var allEntries: [ArchiveListEntry] = []
    private var items: [FileItem] = []
    private var rootNode = ArchiveTreeNode(path: "", name: "")
    private var isLoading = false
    private var suppressOutlineSelect = false

    private var outline: NSOutlineView!
    private var table: NSTableView!
    private var statusLabel: NSTextField!
    private var extractAllButton: NSButton!
    private var progressIndicator: NSProgressIndicator!
    private var splitView: NSSplitView!

    init(archive: URL) {
        self.archiveURL = archive.standardizedFileURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(archive.lastPathComponent) — 压缩包"
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureUI()
        reloadArchive()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func configureUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let commandBar = NSView()
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        commandBar.wantsLayer = true
        commandBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        extractAllButton = makeCommandButton(
            title: "解压到",
            symbol: "arrow.down.doc.fill",
            tint: NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.92, alpha: 1),
            action: #selector(extractAllClicked)
        )

        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .regular
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        commandBar.addSubview(extractAllButton)
        commandBar.addSubview(progressIndicator)

        // —— Split: folder tree | file list ——
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let treeHost = NSView()
        treeHost.translatesAutoresizingMaskIntoConstraints = false
        treeHost.wantsLayer = true
        treeHost.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let treeTitle = NSTextField(labelWithString: "目录")
        treeTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        treeTitle.textColor = .secondaryLabelColor
        treeTitle.translatesAutoresizingMaskIntoConstraints = false

        let treeScroll = NSScrollView()
        treeScroll.translatesAutoresizingMaskIntoConstraints = false
        treeScroll.hasVerticalScroller = true
        treeScroll.hasHorizontalScroller = false
        treeScroll.borderType = .noBorder
        treeScroll.drawsBackground = false
        treeScroll.autohidesScrollers = true

        outline = NSOutlineView()
        outline.headerView = nil
        outline.rowHeight = 24
        outline.allowsEmptySelection = false
        outline.allowsMultipleSelection = false
        outline.focusRingType = .none
        outline.backgroundColor = .clear
        let treeCol = NSTableColumn(identifier: .init("folder"))
        treeCol.title = "文件夹"
        treeCol.width = 180
        outline.addTableColumn(treeCol)
        outline.outlineTableColumn = treeCol
        treeScroll.documentView = outline

        treeHost.addSubview(treeTitle)
        treeHost.addSubview(treeScroll)

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.borderType = .noBorder
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = true
        listScroll.backgroundColor = .textBackgroundColor

        table = NSTableView()
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.focusRingType = .none
        table.doubleAction = #selector(tableDoubleClicked)
        table.target = self
        table.dataSource = self
        table.delegate = self
        table.style = .inset

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "名称"
        nameCol.width = 340
        nameCol.minWidth = 140
        table.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "大小"
        sizeCol.width = 100
        sizeCol.minWidth = 70
        table.addTableColumn(sizeCol)

        let kindCol = NSTableColumn(identifier: .init("kind"))
        kindCol.title = "种类"
        kindCol.width = 110
        kindCol.minWidth = 70
        table.addTableColumn(kindCol)

        listScroll.documentView = table

        outline.dataSource = self
        outline.delegate = self

        splitView.addArrangedSubview(treeHost)
        splitView.addArrangedSubview(listScroll)

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)

        content.addSubview(commandBar)
        content.addSubview(splitView)
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            commandBar.topAnchor.constraint(equalTo: content.topAnchor),
            commandBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: 64),

            extractAllButton.leadingAnchor.constraint(equalTo: commandBar.leadingAnchor, constant: 12),
            extractAllButton.centerYAnchor.constraint(equalTo: commandBar.centerYAnchor),
            progressIndicator.leadingAnchor.constraint(equalTo: extractAllButton.trailingAnchor, constant: 10),
            progressIndicator.centerYAnchor.constraint(equalTo: commandBar.centerYAnchor),

            splitView.topAnchor.constraint(equalTo: commandBar.bottomAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            treeTitle.topAnchor.constraint(equalTo: treeHost.topAnchor, constant: 8),
            treeTitle.leadingAnchor.constraint(equalTo: treeHost.leadingAnchor, constant: 10),
            treeScroll.topAnchor.constraint(equalTo: treeTitle.bottomAnchor, constant: 4),
            treeScroll.leadingAnchor.constraint(equalTo: treeHost.leadingAnchor),
            treeScroll.trailingAnchor.constraint(equalTo: treeHost.trailingAnchor),
            treeScroll.bottomAnchor.constraint(equalTo: treeHost.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -12)
        ])

        DispatchQueue.main.async { [weak self] in
            self?.splitView.setPosition(210, ofDividerAt: 0)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "打开", action: #selector(openClicked), keyEquivalent: "")
        menu.addItem(withTitle: "解压所选…", action: #selector(extractSelectedClicked), keyEquivalent: "")
        menu.addItem(withTitle: "解压全部…", action: #selector(extractAllClicked), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "上层文件夹", action: #selector(goUpClicked), keyEquivalent: "")
        table.menu = menu

        updatePathChrome()
        updateActionEnabled()
    }

    private func makeCommandButton(title: String, symbol: String, tint: NSColor, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.font = .systemFont(ofSize: 11, weight: .medium)
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 64).isActive = true
        button.heightAnchor.constraint(equalToConstant: 56).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func archiveFormatLabel(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "TAR.GZ" }
        if name.hasSuffix(".tar.bz2") { return "TAR.BZ2" }
        if name.hasSuffix(".tar.xz") { return "TAR.XZ" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "ARCHIVE" : ext
    }

    // MARK: - Data

    private func reloadArchive() {
        guard !isLoading else { return }
        isLoading = true
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在读取压缩包…"
        let archive = archiveURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<[ArchiveListEntry], Error>
            do {
                result = .success(try ArchiveSupport.listEntries(in: archive))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.progressIndicator.stopAnimation(nil)
                switch result {
                case .success(let entries):
                    self.allEntries = entries
                    self.rootNode = Self.buildTree(from: entries, archiveName: self.archiveURL.lastPathComponent)
                    self.outline.reloadData()
                    self.outline.expandItem(self.rootNode, expandChildren: false)
                    self.selectTreePath(self.internalPath)
                    self.refreshFileList()
                case .failure(let error):
                    self.allEntries = []
                    self.items = []
                    self.rootNode = ArchiveTreeNode(path: "", name: self.archiveURL.lastPathComponent)
                    self.outline.reloadData()
                    self.table.reloadData()
                    self.statusLabel.stringValue = "无法读取：\(error.localizedDescription)"
                    self.updateActionEnabled()
                }
            }
        }
    }

    private static func buildTree(from entries: [ArchiveListEntry], archiveName: String) -> ArchiveTreeNode {
        let root = ArchiveTreeNode(path: "", name: archiveName)
        var folderPaths = Set<String>()
        for entry in entries {
            let path = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !path.isEmpty else { continue }
            let parts = path.split(separator: "/").map(String.init)
            let dirParts = entry.isDirectory ? parts : Array(parts.dropLast())
            var built = ""
            for part in dirParts {
                built = built.isEmpty ? part : built + "/" + part
                folderPaths.insert(built)
            }
        }

        var nodeByPath: [String: ArchiveTreeNode] = ["": root]
        let sorted = folderPaths.sorted {
            $0.split(separator: "/").count < $1.split(separator: "/").count
                || ($0.split(separator: "/").count == $1.split(separator: "/").count
                    && $0.localizedStandardCompare($1) == .orderedAscending)
        }
        for path in sorted {
            let name = (path as NSString).lastPathComponent
            let parentPath = (path as NSString).deletingLastPathComponent
            let parentKey = parentPath == "." ? "" : parentPath
            let node = ArchiveTreeNode(path: path, name: name)
            nodeByPath[path] = node
            nodeByPath[parentKey]?.children.append(node)
        }
        for node in nodeByPath.values {
            node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return root
    }

    private func refreshFileList() {
        guard table != nil else { return }
        let prefix = internalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var children: [String: FileItem] = [:]
        for entry in allEntries {
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
            let isDir = parts.count > 1 || entry.isDirectory
            let childPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if children[name] == nil {
                children[name] = FileItem.archiveEntry(
                    archive: archiveURL,
                    entryPath: childPath,
                    name: name,
                    isDirectory: isDir,
                    size: parts.count == 1 && !entry.isDirectory ? entry.size : nil
                )
            } else if isDir, let existing = children[name], !existing.isDirectory {
                children[name] = FileItem.archiveEntry(
                    archive: archiveURL,
                    entryPath: childPath,
                    name: name,
                    isDirectory: true,
                    size: nil
                )
            }
        }
        items = children.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        table.reloadData()
        updatePathChrome()
        updateStatus()
        updateActionEnabled()
    }

    private func updatePathChrome() {
        window?.title = internalPath.isEmpty
            ? "\(archiveURL.lastPathComponent) — 压缩包"
            : "\(archiveURL.lastPathComponent) — \(internalPath)"
    }

    private func updateStatus() {
        let selected = table.selectedRowIndexes.count
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        let format = archiveFormatLabel(for: archiveURL)
        let total = allEntries.filter { !$0.isDirectory }.count
        if selected == 0 {
            statusLabel.stringValue = "\(format) · 当前 \(items.count) 项（\(folders) 文件夹 / \(files) 文件）· 压缩包内共 \(total) 个文件"
        } else {
            statusLabel.stringValue = "\(format) · 已选中 \(selected) 个 · 当前 \(items.count) 项"
        }
    }

    private func updateActionEnabled() {
        extractAllButton.isEnabled = !allEntries.isEmpty || !isLoading
    }

    private var selectedItems: [FileItem] {
        table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    private func navigateTo(_ path: String) {
        internalPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        selectTreePath(internalPath)
        refreshFileList()
    }

    private func selectTreePath(_ path: String) {
        suppressOutlineSelect = true
        defer { suppressOutlineSelect = false }
        let target = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let node = findNode(path: target, under: rootNode) ?? rootNode
        // Expand ancestors
        var chain: [ArchiveTreeNode] = []
        var cursor: ArchiveTreeNode? = node
        while let current = cursor {
            chain.append(current)
            if current === rootNode { break }
            cursor = parentNode(of: current, under: rootNode)
        }
        for item in chain.reversed() {
            outline.expandItem(item)
        }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    private func findNode(path: String, under node: ArchiveTreeNode) -> ArchiveTreeNode? {
        if node.path == path { return node }
        for child in node.children {
            if let found = findNode(path: path, under: child) { return found }
        }
        return nil
    }

    private func parentNode(of target: ArchiveTreeNode, under node: ArchiveTreeNode) -> ArchiveTreeNode? {
        if node.children.contains(where: { $0 === target }) { return node }
        for child in node.children {
            if let found = parentNode(of: target, under: child) { return found }
        }
        return nil
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        reloadArchive()
    }

    @objc private func goUpClicked() {
        guard !internalPath.isEmpty else { return }
        let parent = (internalPath as NSString).deletingLastPathComponent
        navigateTo(parent == "." ? "" : parent)
    }

    @objc private func openClicked() {
        guard let item = selectedItems.first ?? items.first else { return }
        if item.isDirectory {
            navigateTo(item.archiveEntryPath ?? "")
        } else {
            openFile(item)
        }
    }

    @objc private func tableDoubleClicked() {
        let row = table.clickedRow
        guard items.indices.contains(row) else { return }
        let item = items[row]
        if item.isDirectory {
            navigateTo(item.archiveEntryPath ?? "")
        } else {
            openFile(item)
        }
    }

    private func openFile(_ item: FileItem) {
        guard !item.isDirectory, let entry = item.archiveEntryPath else { return }
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在打开 \(item.name)…"
        let archive = archiveURL
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewFinder-ArchiveOpen-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let options = ArchiveExtractOptions(
            directory: temp,
            folderName: "",
            password: "",
            deleteSource: false
        )
        ArchiveSupport.extract(urls: [archive], options: options) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressIndicator.stopAnimation(nil)
                switch result {
                case .success:
                    let target = temp.appendingPathComponent(entry)
                    if FileManager.default.fileExists(atPath: target.path) {
                        NSWorkspace.shared.open(target)
                    } else {
                        NSWorkspace.shared.open(temp.appendingPathComponent(item.name))
                    }
                    self.updateStatus()
                case .failure(let error):
                    self.presentError(title: "无法打开", error: error)
                    self.updateStatus()
                }
            }
        }
    }

    @objc private func extractAllClicked() {
        runExtract()
    }

    @objc private func extractSelectedClicked() {
        runExtract()
    }

    private func runExtract() {
        let base = archiveURL.deletingLastPathComponent()
        guard let options = ArchiveDialogs.runExtractDialog(for: [archiveURL], relativeTo: base) else { return }
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = "正在解压…"
        extractAllButton.isEnabled = false
        ArchiveSupport.extract(urls: [archiveURL], options: options) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressIndicator.stopAnimation(nil)
                self.updateActionEnabled()
                switch result {
                case .success:
                    let dest = options.destinationURL(for: self.archiveURL)
                    self.statusLabel.stringValue = "解压完成：\(dest.path)"
                    if options.deleteSource {
                        try? FileOperations.moveToTrash([self.archiveURL])
                    }
                    AppDelegate.shared.reveal([dest])
                case .failure(let error):
                    self.presentError(title: "解压失败", error: error)
                    self.updateStatus()
                }
            }
        }
    }

    private func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    // MARK: - Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return 1 }
        return (item as? ArchiveTreeNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ArchiveTreeNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootNode }
        return (item as? ArchiveTreeNode)?.children[index] ?? rootNode
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("archive.tree")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.name
        if node.path.isEmpty {
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: archiveURL.path)
            cell.imageView?.image?.size = NSSize(width: 16, height: 16)
        } else {
            cell.imageView?.image = NSImage(named: NSImage.folderName)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressOutlineSelect, table != nil else { return }
        guard let node = outline.item(atRow: outline.selectedRow) as? ArchiveTreeNode else { return }
        internalPath = node.path
        refreshFileList()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let tableColumn else { return nil }
        let item = items[row]
        let id = tableColumn.identifier
        let cellId = NSUserInterfaceItemIdentifier("archive.\(id.rawValue)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            if id.rawValue == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyDown
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(icon)
                cell.addSubview(label)
                cell.imageView = icon
                cell.textField = label
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            } else {
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
        }

        switch id.rawValue {
        case "name":
            cell.textField?.stringValue = item.name
            if item.isDirectory {
                cell.imageView?.image = NSImage(named: NSImage.folderName)
            } else {
                let icon = NSWorkspace.shared.icon(forFileType: (item.name as NSString).pathExtension)
                icon.size = NSSize(width: 16, height: 16)
                cell.imageView?.image = icon
            }
        case "size":
            cell.textField?.stringValue = item.isDirectory ? "--" : FileOperations.formatFileSize(item.fileSize)
        case "kind":
            if item.isDirectory {
                cell.textField?.stringValue = "文件夹"
            } else {
                let ext = (item.name as NSString).pathExtension
                cell.textField?.stringValue = ext.isEmpty ? "文件" : ext.lowercased()
            }
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        updateActionEnabled()
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.archiveWindowDidClose(self)
    }
}

/// Folder node inside an archive (outline tree).
private final class ArchiveTreeNode: NSObject {
    let path: String
    let name: String
    var children: [ArchiveTreeNode] = []

    init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}
