import AppKit

/// Finder-style column browser (分栏视图).
/// One full-width column for the current folder; clicking a folder opens the next column on the right.
final class ColumnBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectionChange: (([FileItem]) -> Void)?
    var onOpen: ((FileItem) -> Void)?
    var onActivateDirectory: ((URL) -> Void)?
    var onPerformFileDrop: (([URL], URL, Bool) -> Void)?
    var onDirectoryNeedsReload: (() -> Void)?

    private let scrollView = NSScrollView()
    private let columnsStack = NSStackView()
    private var rootURL = FileManager.default.homeDirectoryForCurrentUser
    private var childrenCache: [URL: [FileItem]] = [:]
    private var columnDirectories: [URL] = []
    private var columnTables: [NSTableView] = []
    private var columnSelections: [FileItem?] = []
    private var suppressSelectionEvent = false
    private var columnWidthConstraints: [NSLayoutConstraint] = []
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        redistributeColumnWidths()
    }

    func setRootURL(_ url: URL) {
        rootURL = url.standardizedFileURL
        childrenCache.removeAll(keepingCapacity: true)
        rebuildColumns(directories: [rootURL], selections: [nil], forceReload: true)
        notifySelection()
    }

    func reload() {
        childrenCache.removeAll(keepingCapacity: true)
        let dirs = columnDirectories.isEmpty ? [rootURL] : columnDirectories
        let sels = columnSelections
        rebuildColumns(directories: dirs, selections: sels, forceReload: true)
        notifySelection()
    }

    /// After move/copy/delete: drop cached listings, keep the open column path when possible, then reveal `select`.
    func refreshAfterMutation(root: URL, select urls: [URL]) {
        let standardized = root.standardizedFileURL
        childrenCache.removeAll(keepingCapacity: true)

        let sameRoot = standardized.path == rootURL.standardizedFileURL.path
        if sameRoot, !columnDirectories.isEmpty {
            var dirs: [URL] = []
            var sels: [FileItem?] = []
            for (index, dir) in columnDirectories.enumerated() {
                if index > 0, !FileManager.default.fileExists(atPath: dir.path) { break }
                dirs.append(dir.standardizedFileURL)
                sels.append(columnSelections.indices.contains(index) ? columnSelections[index] : nil)
            }
            if dirs.isEmpty {
                dirs = [standardized]
                sels = [nil]
            }
            rootURL = standardized
            rebuildColumns(directories: dirs, selections: sels, forceReload: true)
        } else {
            rootURL = standardized
            rebuildColumns(directories: [standardized], selections: [nil], forceReload: true)
        }

        if let target = urls.first {
            select(urls: [target])
        } else {
            notifySelection()
        }
    }

    var selectedItems: [FileItem] {
        guard let item = deepestSelection() else { return [] }
        return [item]
    }

    func select(urls: [URL]) {
        guard let target = urls.first?.standardizedFileURL else { return }
        let root = rootURL.standardizedFileURL
        if target.path == root.path {
            rebuildColumns(directories: [root], selections: [nil])
            notifySelection()
            return
        }

        var dirs: [URL] = [root]
        var sels: [FileItem?] = []
        var cursor = root
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard target.path.hasPrefix(prefix) || target.path.hasPrefix(root.path + "/") || target.path.hasPrefix(root.path) else {
            return
        }
        let relative: String
        if root.path == "/" {
            relative = String(target.path.dropFirst())
        } else if target.path.hasPrefix(prefix) {
            relative = String(target.path.dropFirst(prefix.count))
        } else {
            return
        }
        let parts = relative.split(separator: "/").map(String.init)

        for part in parts {
            let kids = children(of: cursor)
            guard let item = kids.first(where: { $0.name == part }) else { break }
            sels.append(item)
            if item.isDirectory, !item.isPackage {
                cursor = item.url.standardizedFileURL
                dirs.append(cursor)
            } else {
                break
            }
        }

        // selections index matches the column where the item was chosen
        while sels.count < dirs.count { sels.append(nil) }
        if sels.count > dirs.count {
            sels = Array(sels.prefix(dirs.count))
        }
        rebuildColumns(directories: dirs, selections: sels)
        notifySelection()
    }

    // MARK: - UI

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.spacing = 0
        columnsStack.distribution = .fill
        columnsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = columnsStack

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            columnsStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            columnsStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            columnsStack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            columnsStack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            columnsStack.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor)
        ])
    }

    private func rebuildColumns(directories: [URL], selections: [FileItem?], forceReload: Bool = false) {
        let newDirs = directories.map(\.standardizedFileURL)
        var newSels = selections
        while newSels.count < newDirs.count { newSels.append(nil) }
        if newSels.count > newDirs.count {
            newSels = Array(newSels.prefix(newDirs.count))
        }

        // Selection-only change: keep existing tables to avoid a full-window layout flash
        // (which also made the path bar blink).
        if !forceReload, newDirs == columnDirectories, columnTables.count == newDirs.count {
            columnSelections = newSels
            applySelectionHighlights()
            return
        }

        // Truncate trailing columns that are no longer needed.
        while columnDirectories.count > newDirs.count {
            columnsStack.arrangedSubviews.last?.removeFromSuperview()
            if !columnWidthConstraints.isEmpty {
                let constraint = columnWidthConstraints.removeLast()
                constraint.isActive = false
            }
            if !columnTables.isEmpty { columnTables.removeLast() }
            columnDirectories.removeLast()
            if !columnSelections.isEmpty { columnSelections.removeLast() }
        }

        // Update directories / reload data for columns that changed identity.
        for index in columnDirectories.indices {
            let dirChanged = columnDirectories[index] != newDirs[index]
            columnDirectories[index] = newDirs[index]
            columnSelections[index] = newSels[index]
            columnTables[index].tag = index
            if forceReload || dirChanged {
                if dirChanged {
                    childrenCache[newDirs[index]] = nil
                }
                columnTables[index].reloadData()
            }
        }

        // Append newly opened columns on the right.
        while columnDirectories.count < newDirs.count {
            let index = columnDirectories.count
            columnDirectories.append(newDirs[index])
            columnSelections.append(newSels[index])
            let column = makeColumn(index: index)
            columnsStack.addArrangedSubview(column)
            let width = column.widthAnchor.constraint(equalToConstant: 220)
            width.priority = .defaultHigh
            width.isActive = true
            columnWidthConstraints.append(width)
        }

        redistributeColumnWidths()
        applySelectionHighlights()
    }

    private func makeColumn(index: Int) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let table = NSTableView()
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsTypeSelect = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .textBackgroundColor
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.doubleAction = #selector(columnDoubleClicked(_:))
        table.target = self
        table.tag = index
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 29))

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "名称"
        nameCol.width = 220
        nameCol.minWidth = 80
        nameCol.headerCell.alignment = .left
        table.addTableColumn(nameCol)

        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .delete], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        scroll.documentView = table
        container.addSubview(scroll)

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        container.addSubview(divider)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])

        columnTables.append(table)
        table.reloadData()
        return container
    }

    private func redistributeColumnWidths() {
        let count = max(1, columnDirectories.count)
        guard bounds.width > 1, columnWidthConstraints.count == count else { return }
        let width = max(180, floor(bounds.width / CGFloat(count)))
        for constraint in columnWidthConstraints {
            constraint.constant = width
        }
    }

    private func children(of url: URL) -> [FileItem] {
        let key = url.standardizedFileURL
        if let cached = childrenCache[key] { return cached }
        let listed = FileOperations.listDirectory(key, showHidden: AppSettings.shared.showHiddenFiles)
        childrenCache[key] = listed
        return listed
    }

    private func items(inColumn index: Int) -> [FileItem] {
        guard columnDirectories.indices.contains(index) else { return [] }
        return children(of: columnDirectories[index])
    }

    private func deepestSelection() -> FileItem? {
        for item in columnSelections.reversed() {
            if let item { return item }
        }
        return nil
    }

    private func applySelectionHighlights() {
        suppressSelectionEvent = true
        defer { suppressSelectionEvent = false }
        for (index, table) in columnTables.enumerated() {
            let selected = columnSelections.indices.contains(index) ? columnSelections[index] : nil
            guard let selected else {
                table.deselectAll(nil)
                continue
            }
            let rows = items(inColumn: index)
            if let row = rows.firstIndex(where: { $0.url.standardizedFileURL == selected.url.standardizedFileURL }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
        }
    }

    private func notifySelection() {
        let selected = selectedItems
        onSelectionChange?(selected)
        if let item = selected.first {
            if item.isDirectory, !item.isPackage {
                onActivateDirectory?(item.url)
            } else {
                onActivateDirectory?(item.url.deletingLastPathComponent())
            }
        } else {
            onActivateDirectory?(rootURL)
        }
    }

    private func handleClick(column index: Int, row: Int) {
        let rows = items(inColumn: index)
        guard rows.indices.contains(row) else { return }
        let item = rows[row]

        var dirs = Array(columnDirectories.prefix(index + 1))
        var sels = Array(columnSelections.prefix(index + 1))
        while sels.count < dirs.count { sels.append(nil) }
        sels[index] = item

        if item.isDirectory, !item.isPackage {
            dirs.append(item.url.standardizedFileURL)
            sels.append(nil)
        }

        rebuildColumns(directories: dirs, selections: sels)
        notifySelection()
    }

    @objc private func columnDoubleClicked(_ sender: NSTableView) {
        let index = sender.tag
        let row = sender.clickedRow
        let rows = items(inColumn: index)
        guard rows.indices.contains(row) else { return }
        let item = rows[row]
        if item.isDirectory, !item.isPackage { return }
        onOpen?(item)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items(inColumn: tableView.tag).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = items(inColumn: tableView.tag)
        guard rows.indices.contains(row) else { return nil }
        return nameCell(tableView: tableView, item: rows[row])
    }

    private func nameCell(tableView: NSTableView, item: FileItem) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("nf.col.name")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
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
            label.font = .systemFont(ofSize: 12)
            let arrow = NSImageView()
            arrow.translatesAutoresizingMaskIntoConstraints = false
            arrow.tag = 9911
            arrow.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.addSubview(label)
            cell.addSubview(arrow)
            cell.imageView = icon
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                arrow.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                arrow.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                arrow.widthAnchor.constraint(equalToConstant: 10),
                arrow.heightAnchor.constraint(equalToConstant: 10)
            ])
        }

        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        cell.textField?.stringValue = item.name

        let arrow = cell.viewWithTag(9911) as? NSImageView
        if item.isDirectory, !item.isPackage {
            let img = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            img?.isTemplate = true
            arrow?.image = img
            arrow?.contentTintColor = .tertiaryLabelColor
            arrow?.isHidden = false
        } else {
            arrow?.isHidden = true
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionEvent, !isDragging else { return }
        guard let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        handleClick(column: table.tag, row: row)
    }

    // MARK: - Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let rows = items(inColumn: tableView.tag)
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        guard !item.isArchiveEntry else { return nil }
        return item.url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        isDragging = true
        let rows = items(inColumn: tableView.tag)
        let selected = tableView.selectedRowIndexes
        let urls: [URL]
        if !selected.isEmpty, rowIndexes.contains(where: { selected.contains($0) }) {
            urls = selected.compactMap { idx -> URL? in
                guard rows.indices.contains(idx), !rows[idx].isArchiveEntry else { return nil }
                return rows[idx].url
            }
        } else {
            urls = rowIndexes.compactMap { idx -> URL? in
                guard rows.indices.contains(idx), !rows[idx].isArchiveEntry else { return nil }
                return rows[idx].url
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
        isDragging = false
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

        let column = tableView.tag
        let rows = items(inColumn: column)
        let destination: URL
        if rows.indices.contains(row),
           rows[row].isDirectory,
           !rows[row].isPackage,
           !rows[row].isArchiveEntry {
            destination = rows[row].url.standardizedFileURL
            tableView.setDropRow(row, dropOperation: .on)
        } else if columnDirectories.indices.contains(column) {
            destination = columnDirectories[column].standardizedFileURL
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

        let column = tableView.tag
        let rows = items(inColumn: column)
        let destination: URL
        if dropOperation == .on,
           rows.indices.contains(row),
           rows[row].isDirectory,
           !rows[row].isPackage,
           !rows[row].isArchiveEntry {
            destination = rows[row].url.standardizedFileURL
        } else if columnDirectories.indices.contains(column) {
            destination = columnDirectories[column].standardizedFileURL
        } else {
            return false
        }

        guard isValidDrop(sources: urls, destination: destination) else { return false }
        onPerformFileDrop?(urls, destination, prefersCopy(for: info))
        return true
    }

    private func prefersCopy(for info: NSDraggingInfo) -> Bool {
        if NSEvent.modifierFlags.contains(.option) { return true }
        if let source = info.draggingSource as? NSTableView,
           columnTables.contains(where: { $0 === source }) {
            return false
        }
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
            let srcPath = src.path.hasSuffix("/") ? src.path : src.path + "/"
            if destPath.hasPrefix(srcPath) {
                return false
            }
        }
        return true
    }
}
