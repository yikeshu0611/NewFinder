import AppKit

/// Finder-style favorites sidebar: bookmark folders + saved paths.
final class FavoritesSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onOpenBookmark: ((Bookmark) -> Void)?
    var onEditBookmark: ((Bookmark) -> Void)?
    var onRemoveBookmark: ((Bookmark) -> Void)?
    var onRenameFolder: ((String) -> Void)?
    var onDeleteFolder: ((String) -> Void)?
    var onAddCurrentToFolder: ((String) -> Void)?

    private final class Node: NSObject {
        let folderName: String?
        let bookmark: Bookmark?

        var isFolder: Bool { folderName != nil }

        init(folder: String) {
            self.folderName = folder
            self.bookmark = nil
        }

        init(bookmark: Bookmark) {
            self.folderName = nil
            self.bookmark = bookmark
        }
    }

    private let settings = AppSettings.shared
    private var outline: NSOutlineView!
    private var scrollView: NSScrollView!
    private var folderNodes: [Node] = []
    private var rootBookmarkNodes: [Node] = []
    private var childrenByFolder: [String: [Node]] = [:]
    private var currentPath: String = ""
    private var expandedFolders: Set<String> = []
    private var suppressSelectionOpen = false
    private var ignoreExpansionEvents = false

    private let folderPasteboardType = NSPasteboard.PasteboardType("com.zhangjing.NewFinder.sidebarFolder")
    private let bookmarkPasteboardType = NSPasteboard.PasteboardType("com.zhangjing.NewFinder.sidebarBookmark")

    override func loadView() {
        let root = AppearanceAwareView()
        root.onAppearanceChange = { [weak self] in
            self?.applyOpaqueAppearance()
        }

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init(top: 2, left: 0, bottom: 2, right: 0)
        scrollView.scrollerInsets = .init(top: 0, left: 0, bottom: 0, right: 0)

        let column = NSTableColumn(identifier: .init("name"))
        column.title = "收藏"
        let outlineView = FavoritesOutlineView()
        outline = outlineView
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        // Indentation is applied manually in FavoritesOutlineView.frameOfCell.
        outline.indentationPerLevel = 0
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.focusRingType = .none
        if #available(macOS 11.0, *) {
            outline.style = .plain
        }
        outline.selectionHighlightStyle = .regular
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.autosaveExpandedItems = false
        outline.dataSource = self
        outline.delegate = self
        // Single-click opens a bookmark; drag still reorders (drag suppresses the click action).
        outline.action = #selector(outlineActivated)
        outline.doubleAction = #selector(outlineActivated)
        outline.target = self
        outline.menu = makeContextMenu()
        outline.registerForDraggedTypes([folderPasteboardType, bookmarkPasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        scrollView.documentView = outline

        root.addSubview(scrollView)
        view = root
        applyOpaqueAppearance()

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    private func applyOpaqueAppearance() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Match the original chrome / source-list gray (not plain white).
        let fill = dark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.82, alpha: 1)
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = fill
        outline.backgroundColor = fill
        outline.wantsLayer = true
        outline.layer?.backgroundColor = fill.cgColor
    }

    func reload(highlighting path: String? = nil) {
        if let path {
            currentPath = URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let folders = settings.orderedBookmarkFolders()
        let folderSet = Set(folders)

        rootBookmarkNodes = settings.rootBookmarks(in: .left).map(Node.init(bookmark:))
        folderNodes = folders.map(Node.init(folder:))
        childrenByFolder = [:]
        for folder in folders {
            childrenByFolder[folder] = settings.bookmarks(in: folder, placement: .left).map(Node.init(bookmark:))
        }

        // Keep groups collapsed unless the user already expanded them in this window.
        // Never auto-expand on first launch / new window.
        let foldersToExpand = expandedFolders.intersection(folderSet)
        expandedFolders = foldersToExpand

        suppressSelectionOpen = true
        ignoreExpansionEvents = true
        outline.reloadData()
        // Source-list outlines can leave items open after reloadData — force collapse first.
        for node in folderNodes {
            outline.collapseItem(node, collapseChildren: true)
        }
        for node in folderNodes {
            guard let name = node.folderName, foldersToExpand.contains(name) else { continue }
            outline.expandItem(node)
        }
        ignoreExpansionEvents = false
        highlightCurrentPath()
        suppressSelectionOpen = false
    }

    func setCurrentPath(_ path: String) {
        currentPath = URL(fileURLWithPath: path).standardizedFileURL.path
        suppressSelectionOpen = true
        // Only update selection when the containing group is already expanded.
        highlightCurrentPath()
        suppressSelectionOpen = false
    }

    private func highlightCurrentPath(expandMatchingFolder: Bool = true) {
        guard !currentPath.isEmpty else {
            outline.deselectAll(nil)
            return
        }
        let current = URL(fileURLWithPath: currentPath).standardizedFileURL

        // Prefer the most specific favorite (root bar links or folder children).
        var bestRoot: (item: Node, pathLength: Int)?
        for child in rootBookmarkNodes {
            guard let raw = child.bookmark?.path else { continue }
            let favorite = URL(fileURLWithPath: raw).standardizedFileURL
            guard isCurrent(current, underFavorite: favorite) else { continue }
            let length = favorite.path.count
            if bestRoot == nil || length > bestRoot!.pathLength {
                bestRoot = (child, length)
            }
        }

        var bestFolder: (folderNode: Node, item: Node, pathLength: Int)?
        for folderNode in folderNodes {
            guard let children = childrenByFolder[folderNode.folderName ?? ""] else { continue }
            for child in children {
                guard let raw = child.bookmark?.path else { continue }
                let favorite = URL(fileURLWithPath: raw).standardizedFileURL
                guard isCurrent(current, underFavorite: favorite) else { continue }
                let length = favorite.path.count
                if bestFolder == nil || length > bestFolder!.pathLength {
                    bestFolder = (folderNode, child, length)
                }
            }
        }

        if let bestRoot, bestFolder == nil || bestRoot.pathLength >= bestFolder!.pathLength {
            let row = outline.row(forItem: bestRoot.item)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
            return
        }

        guard let bestFolder else {
            outline.deselectAll(nil)
            return
        }

        let groupAlreadyOpen = outline.isItemExpanded(bestFolder.folderNode)
            || (bestFolder.folderNode.folderName.map { expandedFolders.contains($0) } ?? false)
        guard groupAlreadyOpen else {
            outline.deselectAll(nil)
            return
        }

        let row = outline.row(forItem: bestFolder.item)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    /// True when `current` is the favorite itself or a subdirectory under it.
    private func isCurrent(_ current: URL, underFavorite favorite: URL) -> Bool {
        let cur = current.path
        let fav = favorite.path
        if cur == fav { return true }
        let prefix = fav.hasSuffix("/") ? fav : fav + "/"
        return cur.hasPrefix(prefix)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "打开", action: #selector(contextOpen), keyEquivalent: "")
        menu.addItem(withTitle: "编辑…", action: #selector(contextEdit), keyEquivalent: "")
        menu.addItem(withTitle: "取消收藏", action: #selector(contextRemoveBookmark), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "添加当前位置到此夹", action: #selector(contextAddCurrentToFolder), keyEquivalent: "")
        menu.addItem(withTitle: "重命名收藏夹…", action: #selector(contextRenameFolder), keyEquivalent: "")
        menu.addItem(withTitle: "删除收藏夹", action: #selector(contextDeleteFolder), keyEquivalent: "")
        return menu
    }

    @objc private func outlineActivated() {
        guard !suppressSelectionOpen else { return }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node,
              let bookmark = node.bookmark else { return }
        onOpenBookmark?(bookmark)
    }

    private func clickedNode() -> Node? {
        let row = outline.clickedRow
        if row >= 0 { return outline.item(atRow: row) as? Node }
        return outline.item(atRow: outline.selectedRow) as? Node
    }

    @objc private func contextOpen() {
        if let bookmark = clickedNode()?.bookmark {
            onOpenBookmark?(bookmark)
        }
    }

    @objc private func contextEdit() {
        if let bookmark = clickedNode()?.bookmark {
            onEditBookmark?(bookmark)
        }
    }

    @objc private func contextRemoveBookmark() {
        if let bookmark = clickedNode()?.bookmark {
            onRemoveBookmark?(bookmark)
        }
    }

    @objc private func contextAddCurrentToFolder() {
        if let folder = folderName(for: clickedNode()) {
            onAddCurrentToFolder?(folder)
        }
    }

    @objc private func contextRenameFolder() {
        if let folder = folderName(for: clickedNode()) {
            onRenameFolder?(folder)
        }
    }

    @objc private func contextDeleteFolder() {
        if let folder = folderName(for: clickedNode()) {
            onDeleteFolder?(folder)
        }
    }

    private func folderName(for node: Node?) -> String? {
        if let folder = node?.folderName { return folder }
        return node?.bookmark?.folder
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Right-click folder → rename; right-click address → edit (no context menu).
        if let node = clickedNode() {
            if node.isFolder, let folder = node.folderName {
                menu.cancelTrackingWithoutAnimation()
                DispatchQueue.main.async { [weak self] in
                    self?.onRenameFolder?(folder)
                }
                return
            }
            if let bookmark = node.bookmark {
                menu.cancelTrackingWithoutAnimation()
                DispatchQueue.main.async { [weak self] in
                    self?.onEditBookmark?(bookmark)
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let node = clickedNode()
        let isBookmark = node?.bookmark != nil
        let isFolder = node?.isFolder == true
        let hasFolderTarget = folderName(for: node) != nil

        // Folder / bookmark right-click opens the editor directly — hide menu to avoid a flash.
        if isFolder || isBookmark {
            for menuItem in menu.items {
                menuItem.isHidden = true
            }
            return
        }

        for menuItem in menu.items {
            switch menuItem.action {
            case #selector(contextOpen), #selector(contextEdit), #selector(contextRemoveBookmark):
                menuItem.isHidden = !isBookmark
                menuItem.isEnabled = isBookmark
            case #selector(contextAddCurrentToFolder):
                menuItem.isHidden = !hasFolderTarget
                menuItem.isEnabled = hasFolderTarget
            case #selector(contextRenameFolder), #selector(contextDeleteFolder):
                menuItem.isHidden = true
            default:
                break
            }
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootBookmarkNodes.count + folderNodes.count }
        guard let node = item as? Node, let folder = node.folderName else { return 0 }
        return childrenByFolder[folder]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index < rootBookmarkNodes.count {
                return rootBookmarkNodes[index]
            }
            return folderNodes[index - rootBookmarkNodes.count]
        }
        let folder = (item as! Node).folderName!
        return childrenByFolder[folder]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        let pbItem = NSPasteboardItem()
        if let folder = node.folderName {
            pbItem.setString(folder, forType: folderPasteboardType)
            return pbItem
        }
        if let id = node.bookmark?.id.uuidString {
            pbItem.setString(id, forType: bookmarkPasteboardType)
            return pbItem
        }
        return nil
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pb = info.draggingPasteboard

        if pb.string(forType: folderPasteboardType) != nil {
            // Reorder folders only among folder rows at the root (after bar links).
            if item == nil, index != NSOutlineViewDropOnItemIndex {
                let folderIndex = max(0, index - rootBookmarkNodes.count)
                outlineView.setDropItem(nil, dropChildIndex: rootBookmarkNodes.count + folderIndex)
                return .move
            }
            if let node = item as? Node, node.isFolder,
               let folderIndex = folderNodes.firstIndex(where: { $0.folderName == node.folderName }) {
                outlineView.setDropItem(nil, dropChildIndex: rootBookmarkNodes.count + folderIndex)
                return .move
            }
            return []
        }

        guard pb.string(forType: bookmarkPasteboardType) != nil else { return [] }

        // Drop onto a folder row → append inside that folder.
        if let node = item as? Node, node.isFolder {
            if index == NSOutlineViewDropOnItemIndex {
                let count = childrenByFolder[node.folderName ?? ""]?.count ?? 0
                outlineView.setDropItem(node, dropChildIndex: count)
            }
            return .move
        }

        // Drop at root (or onto a root bar bookmark) → keep on the bar (no folder).
        if item == nil {
            return .move
        }
        if let node = item as? Node, let bookmark = node.bookmark, AppSettings.isFavoritesBarFolder(bookmark.folder) {
            if let siblingIndex = rootBookmarkNodes.firstIndex(where: { $0.bookmark?.id == bookmark.id }) {
                let dropIndex = (index == NSOutlineViewDropOnItemIndex) ? siblingIndex + 1 : index
                outlineView.setDropItem(nil, dropChildIndex: max(0, min(rootBookmarkNodes.count, dropIndex)))
            }
            return .move
        }

        // Drop onto/near a bookmark inside a folder → insert among siblings.
        if let node = item as? Node, let bookmark = node.bookmark {
            let parentName = bookmark.folder
            guard !AppSettings.isFavoritesBarFolder(parentName),
                  let parentNode = folderNodes.first(where: { $0.folderName == parentName }),
                  let siblings = childrenByFolder[parentName],
                  let siblingIndex = siblings.firstIndex(where: { $0.bookmark?.id == bookmark.id }) else {
                return []
            }
            let dropIndex: Int
            if index == NSOutlineViewDropOnItemIndex {
                dropIndex = siblingIndex + 1
            } else {
                dropIndex = index
            }
            outlineView.setDropItem(parentNode, dropChildIndex: max(0, min(siblings.count, dropIndex)))
            return .move
        }

        return []
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let pb = info.draggingPasteboard

        if let folderName = pb.string(forType: folderPasteboardType) {
            guard item == nil,
                  let from = folderNodes.firstIndex(where: { $0.folderName == folderName }) else {
                return false
            }
            var to = index - rootBookmarkNodes.count
            if to < 0 { to = 0 }
            if index == NSOutlineViewDropOnItemIndex { to = folderNodes.count }
            var nodes = folderNodes
            let moved = nodes.remove(at: from)
            if to > from { to -= 1 }
            to = max(0, min(nodes.count, to))
            nodes.insert(moved, at: to)
            folderNodes = nodes
            persistTreeOrder()
            reload(highlighting: currentPath.isEmpty ? nil : currentPath)
            return true
        }

        guard let idString = pb.string(forType: bookmarkPasteboardType),
              let bookmarkID = UUID(uuidString: idString) else {
            return false
        }

        // Move onto the bar (root) or into a folder.
        let targetIsBar = item == nil
            || ((item as? Node)?.bookmark.map { AppSettings.isFavoritesBarFolder($0.folder) } ?? false)
        let targetFolder: String
        var to = index
        if targetIsBar {
            targetFolder = ""
            if to == NSOutlineViewDropOnItemIndex { to = rootBookmarkNodes.count }
            // When dropping relative to combined root list, clamp to root bookmark range.
            to = max(0, min(rootBookmarkNodes.count, to))
        } else if let targetFolderNode = item as? Node, let name = targetFolderNode.folderName {
            targetFolder = name
            if to == NSOutlineViewDropOnItemIndex {
                to = childrenByFolder[targetFolder]?.count ?? 0
            }
        } else {
            return false
        }

        // Remove from root or current folder list.
        var dragged: Node?
        if let idx = rootBookmarkNodes.firstIndex(where: { $0.bookmark?.id == bookmarkID }) {
            dragged = rootBookmarkNodes.remove(at: idx)
            if targetIsBar, idx < to { to -= 1 }
        } else {
            for (folder, children) in childrenByFolder {
                if let idx = children.firstIndex(where: { $0.bookmark?.id == bookmarkID }) {
                    var copy = children
                    dragged = copy.remove(at: idx)
                    childrenByFolder[folder] = copy
                    if folder == targetFolder, idx < to {
                        to -= 1
                    }
                    break
                }
            }
        }
        guard var moved = dragged, var bookmark = moved.bookmark else { return false }
        bookmark.folder = targetFolder
        moved = Node(bookmark: bookmark)

        if targetIsBar {
            to = max(0, min(rootBookmarkNodes.count, to))
            rootBookmarkNodes.insert(moved, at: to)
        } else {
            var dest = childrenByFolder[targetFolder] ?? []
            to = max(0, min(dest.count, to))
            dest.insert(moved, at: to)
            childrenByFolder[targetFolder] = dest
            expandedFolders.insert(targetFolder)
        }

        persistTreeOrder()
        reload(highlighting: currentPath.isEmpty ? nil : currentPath)
        return true
    }

    /// Write folder order + bar / per-folder bookmark order back to settings.
    private func persistTreeOrder() {
        let folderOrder = folderNodes.compactMap(\.folderName)
        settings.bookmarkFolderOrder = folderOrder

        var reordered: [Bookmark] = []
        for node in rootBookmarkNodes {
            guard var bookmark = node.bookmark else { continue }
            bookmark.folder = ""
            bookmark.placement = .left
            reordered.append(bookmark)
        }
        for folder in folderOrder {
            for node in childrenByFolder[folder] ?? [] {
                guard var bookmark = node.bookmark else { continue }
                bookmark.folder = folder
                bookmark.placement = .left
                reordered.append(bookmark)
            }
        }
        // Keep any bookmarks not shown in this sidebar tree (e.g. top-bar only).
        let keptIDs = Set(reordered.map(\.id))
        for bookmark in settings.bookmarks where !keptIDs.contains(bookmark.id) {
            reordered.append(bookmark)
        }
        settings.bookmarks = reordered
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12)
            view.addSubview(image)
            view.addSubview(label)
            view.imageView = image
            view.textField = label

            let imageWidth = image.widthAnchor.constraint(equalToConstant: 14)
            imageWidth.identifier = "sidebarImageWidth"
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
                image.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                imageWidth,
                image.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()

        guard let node = item as? Node else { return cell }
        let imageWidth = cell.imageView?.constraints.first { $0.identifier == "sidebarImageWidth" }
            ?? cell.constraints.first { $0.identifier == "sidebarImageWidth" }

        cell.imageView?.image = nil
        cell.imageView?.isHidden = true
        imageWidth?.constant = 0

        if let folder = node.folderName {
            cell.textField?.stringValue = folder
            cell.textField?.font = .systemFont(ofSize: 12, weight: .semibold)
            cell.toolTip = "收藏夹「\(folder)」"
        } else if let bookmark = node.bookmark {
            cell.textField?.stringValue = bookmark.name
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.toolTip = bookmark.path
        }
        let row = outlineView.row(forItem: node)
        let selected = row >= 0 && outlineView.isRowSelected(row)
        Self.applySidebarLabelColor(cell.textField, selected: selected)
        return cell
    }

    fileprivate static func applySidebarLabelColor(_ label: NSTextField?, selected: Bool) {
        guard let label else { return }
        let color: NSColor = selected ? .white : .labelColor
        let font = label.font ?? .systemFont(ofSize: 12)
        let text = label.stringValue
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: font
            ]
        )
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        outline.enumerateAvailableRowViews { rowView, _ in
            (rowView as? FavoritesSidebarRowView)?.refreshLabelColors()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? Node)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("FavoritesSidebarRow")
        if let row = outlineView.makeView(withIdentifier: id, owner: self) as? FavoritesSidebarRowView {
            return row
        }
        let row = FavoritesSidebarRowView()
        row.identifier = id
        return row
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !ignoreExpansionEvents,
              let node = notification.userInfo?["NSObject"] as? Node,
              let folder = node.folderName else { return }
        expandedFolders.insert(folder)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !ignoreExpansionEvents,
              let node = notification.userInfo?["NSObject"] as? Node,
              let folder = node.folderName else { return }
        expandedFolders.remove(folder)
    }
}

/// Source-list style selection capsule; keeps highlight and label inset in sync.
private final class FavoritesSidebarRowView: NSTableRowView {
    /// Shared leading inset for selection pill and label text.
    static let leadingInset: CGFloat = 10

    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override var isSelected: Bool {
        didSet { refreshLabelColors() }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = Self.leadingInset
        let rect = NSRect(
            x: bounds.minX + inset,
            y: bounds.minY + 1,
            width: max(0, bounds.width - inset - 4),
            height: max(0, bounds.height - 2)
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (isEmphasized ? NSColor.controlAccentColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
        refreshLabelColors()
    }

    override func layout() {
        super.layout()
        refreshLabelColors()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        refreshLabelColors()
    }

    func refreshLabelColors() {
        for case let cell as NSTableCellView in subviews {
            FavoritesSidebarViewController.applySidebarLabelColor(cell.textField, selected: isSelected)
        }
    }
}

/// Reclaims the disclosure-triangle gutter; aligns cell text with selection pill.
private final class FavoritesOutlineView: NSOutlineView {
    private let childIndent: CGFloat = 12
    private var leadingInset: CGFloat { FavoritesSidebarRowView.leadingInset }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        guard let item = item(atRow: row), isExpandable(item) else {
            return .zero
        }
        return NSRect(x: leadingInset, y: 4, width: 12, height: max(0, rowHeight - 8))
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let folder = item(atRow: row).map { isExpandable($0) } ?? false
        let depth = CGFloat(max(0, level(forRow: row)))
        let targetX: CGFloat
        if folder {
            targetX = leadingInset + 14
        } else if depth > 0 {
            targetX = leadingInset + 6 + depth * childIndent
        } else {
            // Sit inside the selection pill, not flush to the window edge.
            targetX = leadingInset + 6
        }
        let delta = frame.origin.x - targetX
        if abs(delta) > 0.5 {
            frame.origin.x = targetX
            frame.size.width += delta
        }
        return frame
    }
}

private final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
