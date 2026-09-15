import AppKit

final class BrowserTab {
    let id = UUID()
    var directory: URL
    let history = NavigationHistory()
    /// When set, this tab browses inside an archive instead of the filesystem.
    var archiveURL: URL?
    /// Path inside the archive ("" = root). Use `/` separators, no leading slash.
    var archiveInternalPath: String = ""
    /// Virtual tab hosting the in-app Activity Monitor.
    var isActivityMonitorTab = false
    /// Virtual tab hosting the temperature monitor.
    var isTemperatureTab = false
    /// Virtual tab hosting the in-app code compare view.
    var isCompareTab = false
    /// 1-based workspace index when `isCompareTab` (比对1…比对10).
    var compareWorkspaceIndex: Int = 1

    var isArchiveTab: Bool { archiveURL != nil }
    var isSpecialContentTab: Bool { isActivityMonitorTab || isTemperatureTab || isCompareTab }

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
        history.navigate(to: self.directory)
    }

    init(archive: URL) {
        self.archiveURL = archive.standardizedFileURL
        self.directory = archive.deletingLastPathComponent().standardizedFileURL
        self.archiveInternalPath = ""
        history.navigate(to: archive.standardizedFileURL)
    }

    init(activityMonitor: Void) {
        isActivityMonitorTab = true
        // Sentinel path — never listed; excluded from directory-tab matching.
        directory = URL(fileURLWithPath: "/NewFinder/ActivityMonitor", isDirectory: true)
    }

    init(temperature: Void) {
        isTemperatureTab = true
        directory = URL(fileURLWithPath: "/NewFinder/Temperature", isDirectory: true)
    }

    init(compareWorkspace index: Int) {
        isCompareTab = true
        compareWorkspaceIndex = max(1, min(CompareSession.workspaceCount, index))
        directory = URL(fileURLWithPath: "/NewFinder/Compare/\(compareWorkspaceIndex)", isDirectory: true)
    }

    var title: String {
        if isActivityMonitorTab {
            return "活动监视器"
        }
        if isTemperatureTab {
            return "温度"
        }
        if isCompareTab {
            return CompareSession.shared.workspace(at: compareWorkspaceIndex)?.summaryTitle(index: compareWorkspaceIndex)
                ?? "比对\(compareWorkspaceIndex)"
        }
        if let archiveURL {
            return archiveURL.lastPathComponent
        }
        if FileOperations.isTrashDirectory(directory) {
            return "废纸篓"
        }
        if FileOperations.isApplicationsDirectory(directory) {
            return "应用程序"
        }
        if directory.path == "/" { return "Macintosh HD" }
        let name = directory.lastPathComponent
        return name.isEmpty ? directory.path : name
    }
}

/// Chrome-like header: tab strip.
enum TabInsertSide {
    case left, right
}

enum TabCloseScope {
    case thisTab, left, right, others
}

final class ChromeHeaderView: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewTabRelative: ((UUID, TabInsertSide) -> Void)?
    var onCloseTabsRelative: ((UUID, TabCloseScope) -> Void)?
    var onDetachTab: ((UUID, NSPoint, Bool) -> Void)?
    /// Double-click empty titlebar / tab-strip chrome → maximize / restore.
    var onDoubleClickEmptyArea: (() -> Void)?

    private let tabRow = NSView()
    private let tabStrip = TabStripView()
    private let trailingToolsHost = NSView()
    private var searchField: NSSearchField!
    private var searchWidthConstraint: NSLayoutConstraint?
    private weak var actionTarget: AnyObject?
    private weak var externalNewToolsStack: NSStackView?
    private var tabStripTrailingToToolsConstraint: NSLayoutConstraint!
    private var tabStripTrailingEdgeConstraint: NSLayoutConstraint!

    private(set) var tabs: [BrowserTab] = []
    private(set) var activeTabID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
        rebuildTabs()
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks that land on empty header chrome (not tabs / tools) toggle fill-screen.
        if event.clickCount == 2 {
            onDoubleClickEmptyArea?()
            return
        }
        super.mouseDown(with: event)
    }

    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let chrome = dark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.82, alpha: 1)
        layer?.backgroundColor = chrome.cgColor
        tabRow.layer?.backgroundColor = chrome.cgColor
    }

    func bind(target: AnyObject) {
        actionTarget = target
        rebuildTools()
    }

    /// Host New / toolbar-type buttons in an external stack (titlebar trailing cluster).
    func attachNewTools(to stack: NSStackView) {
        externalNewToolsStack = stack
        rebuildTools()
    }

    /// Places trailing controls (e.g. window close) on the tab strip's right edge.
    func attachLeadingTools(_ tools: NSView) {
        trailingToolsHost.subviews.forEach { $0.removeFromSuperview() }
        tools.removeFromSuperview()
        tools.translatesAutoresizingMaskIntoConstraints = false
        trailingToolsHost.addSubview(tools)
        trailingToolsHost.isHidden = false
        tabStripTrailingEdgeConstraint.isActive = false
        tabStripTrailingToToolsConstraint.isActive = true
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: trailingToolsHost.leadingAnchor),
            tools.trailingAnchor.constraint(equalTo: trailingToolsHost.trailingAnchor),
            tools.centerYAnchor.constraint(equalTo: trailingToolsHost.centerYAnchor),
            tools.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    func setTabs(_ tabs: [BrowserTab], activeID: UUID?) {
        self.tabs = tabs
        self.activeTabID = activeID
        rebuildTabs()
    }

    func rebuildNewItemTypes(_ types: [String]) {
        rebuildTools(types: types)
    }

    var searchFieldView: NSSearchField { searchField }

    private func configure() {
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        tabRow.wantsLayer = true

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelectTab = { [weak self] id in self?.onSelectTab?(id) }
        tabStrip.onCloseTab = { [weak self] id in self?.onCloseTab?(id) }
        tabStrip.onNewTab = { [weak self] in self?.onNewTab?() }
        tabStrip.onDoubleClickEmptyArea = { [weak self] in self?.onDoubleClickEmptyArea?() }
        tabStrip.onDetachTab = { [weak self] id, screenPoint, sideBySide in
            self?.onDetachTab?(id, screenPoint, sideBySide)
        }
        tabStrip.onContextAction = { [weak self] id, action in
            guard let self else { return }
            switch action {
            case .newLeft: self.onNewTabRelative?(id, .left)
            case .newRight: self.onNewTabRelative?(id, .right)
            case .close: self.onCloseTabsRelative?(id, .thisTab)
            case .closeLeft: self.onCloseTabsRelative?(id, .left)
            case .closeRight: self.onCloseTabsRelative?(id, .right)
            case .closeOthers: self.onCloseTabsRelative?(id, .others)
            }
        }

        trailingToolsHost.translatesAutoresizingMaskIntoConstraints = false
        trailingToolsHost.setContentHuggingPriority(.required, for: .horizontal)
        trailingToolsHost.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailingToolsHost.isHidden = true

        addSubview(tabRow)
        tabRow.addSubview(tabStrip)
        tabRow.addSubview(trailingToolsHost)

        tabStripTrailingToToolsConstraint = tabStrip.trailingAnchor.constraint(
            equalTo: trailingToolsHost.leadingAnchor,
            constant: -6
        )
        tabStripTrailingToToolsConstraint.isActive = false

        tabStripTrailingEdgeConstraint = tabStrip.trailingAnchor.constraint(
            equalTo: tabRow.trailingAnchor,
            constant: -6
        )

        NSLayoutConstraint.activate([
            tabRow.topAnchor.constraint(equalTo: topAnchor),
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabRow.heightAnchor.constraint(equalToConstant: 32),

            tabStrip.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor, constant: 0),
            tabStrip.topAnchor.constraint(equalTo: tabRow.topAnchor, constant: 0),
            tabStrip.bottomAnchor.constraint(equalTo: tabRow.bottomAnchor),
            tabStripTrailingEdgeConstraint,

            trailingToolsHost.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor, constant: -10),
            trailingToolsHost.centerYAnchor.constraint(equalTo: tabRow.centerYAnchor),
            trailingToolsHost.heightAnchor.constraint(equalToConstant: 24)
        ])

        searchField = NSSearchField()
        searchField.placeholderString = "搜索"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 140)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        searchWidthConstraint = searchWidth
    }

    private func rebuildTabs() {
        let items: [TabStripView.Item] = tabs.map { tab in
            let icon: NSImage?
            if tab.isActivityMonitorTab {
                icon = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: nil)
            } else if tab.isTemperatureTab {
                icon = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)
            } else if tab.isCompareTab {
                icon = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
            } else {
                icon = NSWorkspace.shared.icon(forFile: tab.directory.path)
            }
            return TabStripView.Item(
                id: tab.id,
                title: tab.title,
                icon: icon,
                isActive: tab.id == activeTabID,
                canClose: true
            )
        }
        tabStrip.setItems(items)
    }

    private func rebuildTools(types: [String]? = nil) {
        guard let toolRow = externalNewToolsStack, let target = actionTarget else { return }
        toolRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for type in AppSettings.shared.toolbarNewItemTypes {
            toolRow.addArrangedSubview(makeToolbarNewTypeButton(type: type, target: target))
        }
        toolRow.addArrangedSubview(makeNewMenuButton(types: types ?? AppSettings.shared.newItemTypes, target: target))

        searchField.target = target
        searchField.action = #selector(BrowserWindowController.searchChanged(_:))
        // Bookmark star + search stay on the path bar; New / tools sit on the favorites bar.
    }

    func makeChromeMenuButton() -> NSButton {
        makeAppChromeMenuButton()
    }

    func makeNewMenuButton(types: [String], target: AnyObject) -> NSButton {
        let button = NewMenuButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.title = "New"
        button.attributedTitle = NSAttributedString(
            string: "New",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1)
            ]
        )
        button.toolTip = "新建文件夹或文件"
        button.focusRingType = .none
        button.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setButtonType(.momentaryPushIn)
        button.actionTarget = target
        button.items = types.enumerated().map { index, type in
            let isDir = type.lowercased() == "dir"
            return NewMenuButton.Item(
                title: AppSettings.displayName(forNewItemType: type),
                tag: index,
                toolTip: isDir ? "新建文件夹" : "新建 .\(type) 文件（按住 Option 并打开）"
            )
        }
        let fixedCount = AppSettings.shared.enabledFixedNewItemTypes.count
        button.separatorBeforeIndex = (fixedCount > 0 && types.count > fixedCount) ? fixedCount : nil
        return button
    }

    func makeToolbarNewTypeButton(type: String, target: AnyObject) -> NSButton {
        let button = ToolbarNewTypeButton()
        button.itemType = type
        let title = AppSettings.displayName(forNewItemType: type)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.title = title
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(calibratedWhite: 0.32, alpha: 1)
            ]
        )
        let isDir = type.lowercased() == "dir"
        button.toolTip = isDir ? "新建文件夹" : "新建 .\(type) 文件（按住 Option 并打开）"
        button.focusRingType = .none
        button.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setButtonType(.momentaryPushIn)
        button.target = target
        button.action = #selector(BrowserWindowController.toolbarNewItemClicked(_:))
        return button
    }

    private func makeAppChromeMenuButton() -> NSButton {
        let button = AppChromeMenuButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "菜单")?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = .labelColor
        button.toolTip = "菜单（缩放 / 更新 / 设置 / 转到）"
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = target
        button.action = action
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }
}

// MARK: - Tab strip (single view owns all hit-testing — Chrome-like)

final class TabStripView: NSView {
    struct Item {
        let id: UUID
        let title: String
        let icon: NSImage?
        let isActive: Bool
        let canClose: Bool
    }

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onDetachTab: ((UUID, NSPoint, Bool) -> Void)?
    var onDoubleClickEmptyArea: (() -> Void)?
    var onContextAction: ((UUID, TabContextAction) -> Void)?

    enum TabContextAction {
        case newLeft, newRight, close, closeLeft, closeRight, closeOthers
    }

    private var items: [Item] = []
    private var tabFrames: [UUID: NSRect] = [:]
    private var closeFrames: [UUID: NSRect] = [:]
    private var plusFrame: NSRect = .zero
    private var hoveredID: UUID?
    private var plusHovered = false
    private var tracking: NSTrackingArea?
    private var contextTabID: UUID?
    // System clickCount does not reach 3 while ⌘ is held — track manually.
    private var tabClickCount = 0
    private var tabClickTabID: UUID?
    private var tabClickHadCommand = false
    private var tabClickTimestamp: TimeInterval = 0
    private let tabClickInterval: TimeInterval = 0.55

    private let tabHeight: CGFloat = 32
    private let tabFixedWidth: CGFloat = 140
    private let overlap: CGFloat = 0
    private let corner: CGFloat = 0
    private let ear: CGFloat = 0
    private let plusSize: CGFloat = 20
    private let plusGap: CGFloat = 4

    func setItems(_ items: [Item]) {
        self.items = items
        hoveredID = nil
        plusHovered = false
        needsDisplay = true
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        recalculateFrames()
    }

    private func recalculateFrames() {
        tabFrames.removeAll()
        closeFrames.removeAll()
        plusFrame = .zero
        guard !items.isEmpty else {
            // Still show + at leading edge when empty (shouldn't happen)
            let y = bounds.height - tabHeight + (tabHeight - plusSize) / 2
            plusFrame = NSRect(x: 0, y: y, width: plusSize, height: plusSize)
            return
        }

        let width = tabFixedWidth
        var x: CGFloat = 0
        let y = bounds.height - tabHeight
        for item in items {
            let frame = NSRect(x: x, y: y, width: width, height: tabHeight)
            tabFrames[item.id] = frame
            closeFrames[item.id] = NSRect(
                x: frame.maxX - 28,
                y: frame.midY - 8,
                width: 16,
                height: 16
            )
            x += width
        }

        // + sits immediately to the right of the last tab
        let lastMaxX = (items.last.flatMap { tabFrames[$0.id]?.maxX }) ?? 0
        let plusY = y + (tabHeight - plusSize) / 2
        plusFrame = NSRect(x: lastMaxX + plusGap, y: plusY, width: plusSize, height: plusSize)
        // Keep + inside strip
        if plusFrame.maxX > bounds.width {
            plusFrame.origin.x = max(0, bounds.width - plusSize)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        recalculateFrames()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Draw left → right; no overlap, so active tab never covers neighbors.
        for item in items {
            guard let frame = tabFrames[item.id] else { continue }
            let isHovered = hoveredID == item.id
            let fill: NSColor
            if item.isActive {
                fill = dark ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
            } else if isHovered {
                fill = dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
            } else {
                fill = dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.80, alpha: 1)
            }

            let path = chromeTabPath(in: frame, corner: corner, ear: ear)
            fill.setFill()
            path.fill()

            // Hairline only between two inactive tabs — avoid a recessed look around the active tab.
            if let index = items.firstIndex(where: { $0.id == item.id }), index > 0 {
                let previous = items[index - 1]
                if !item.isActive && !previous.isActive {
                    let divider = dark
                        ? NSColor(calibratedWhite: 0.12, alpha: 1)
                        : NSColor(calibratedWhite: 0.72, alpha: 1)
                    divider.setStroke()
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: frame.minX + 0.5, y: frame.minY + 4))
                    line.line(to: NSPoint(x: frame.minX + 0.5, y: frame.maxY - 4))
                    line.lineWidth = 1
                    line.stroke()
                }
            }

            let iconRect = NSRect(x: frame.minX + 12, y: frame.midY - 7, width: 14, height: 14)
            if let icon = item.icon {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            let titleRect = NSRect(
                x: iconRect.maxX + 6,
                y: frame.minY,
                width: max(0, frame.maxX - 34 - (iconRect.maxX + 6)),
                height: frame.height
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleColor = dark
                ? NSColor(calibratedWhite: 0.82, alpha: 1)
                : NSColor.black
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: item.isActive ? .medium : .regular),
                .foregroundColor: titleColor,
                .paragraphStyle: paragraph
            ]
            let titleSize = (item.title as NSString).size(withAttributes: attrs)
            let textY = frame.minY + (frame.height - titleSize.height) / 2
            (item.title as NSString).draw(
                in: NSRect(x: titleRect.minX, y: textY, width: titleRect.width, height: titleSize.height),
                withAttributes: attrs
            )

            if item.canClose, let closeRect = closeFrames[item.id] {
                let xAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                let x = "✕" as NSString
                let xSize = x.size(withAttributes: xAttrs)
                x.draw(
                    at: NSPoint(
                        x: closeRect.midX - xSize.width / 2,
                        y: closeRect.midY - xSize.height / 2
                    ),
                    withAttributes: xAttrs
                )
            }
        }

        // New-tab + immediately after last tab
        if !plusFrame.isEmpty {
            if plusHovered {
                let bg = dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
                bg.setFill()
                NSBezierPath(roundedRect: plusFrame, xRadius: plusSize / 2, yRadius: plusSize / 2).fill()
            }
            let plusAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let plus = "+" as NSString
            let plusTextSize = plus.size(withAttributes: plusAttrs)
            plus.draw(
                at: NSPoint(
                    x: plusFrame.midX - plusTextSize.width / 2,
                    y: plusFrame.midY - plusTextSize.height / 2
                ),
                withAttributes: plusAttrs
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func isCommandHeld() -> Bool {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    private func resetTabClickSequence() {
        tabClickCount = 0
        tabClickTabID = nil
        tabClickHadCommand = false
    }

    private func registerTabClick(on item: Item, event: NSEvent) -> (detached: Bool, sideBySide: Bool) {
        let commandHeld = Self.isCommandHeld()
        let interval = event.timestamp - tabClickTimestamp

        if tabClickTabID == item.id, interval <= tabClickInterval {
            tabClickCount += 1
            tabClickHadCommand = tabClickHadCommand || commandHeld
        } else {
            tabClickCount = 1
            tabClickTabID = item.id
            tabClickHadCommand = commandHeld
        }
        tabClickTimestamp = event.timestamp

        guard tabClickCount >= 3 else { return (false, false) }

        let sideBySide = tabClickHadCommand || commandHeld
        resetTabClickSequence()
        return (true, sideBySide)
    }

    override func mouseDown(with event: NSEvent) {
        recalculateFrames()
        let point = convert(event.locationInWindow, from: nil)

        if plusFrame.insetBy(dx: -2, dy: -2).contains(point) {
            resetTabClickSequence()
            onNewTab?()
            return
        }

        // Prefer close hits before tab selection so the × always works (including the last tab).
        for item in items {
            guard item.canClose, let closeRect = closeFrames[item.id] else { continue }
            if closeRect.insetBy(dx: -4, dy: -4).contains(point) {
                resetTabClickSequence()
                onCloseTab?(item.id)
                return
            }
        }

        var seen = Set<UUID>()
        let ordered = (items.filter(\.isActive) + items.filter { !$0.isActive }.reversed())
            .filter { seen.insert($0.id).inserted }

        for item in ordered {
            guard let frame = tabFrames[item.id] else { continue }
            let path = chromeTabPath(in: frame, corner: corner, ear: ear)
            guard path.contains(point) else { continue }

            // Triple-click detaches the tab into a new NewFinder window.
            // ⌘ + triple-click tiles side-by-side (up to 3 windows).
            let detach = registerTabClick(on: item, event: event)
            if detach.detached {
                onDetachTab?(item.id, NSEvent.mouseLocation, detach.sideBySide)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                return
            }

            onSelectTab?(item.id)
            return
        }

        // Empty chrome (between tabs / after +) — double-click toggles fill-screen.
        if event.clickCount == 2 {
            onDoubleClickEmptyArea?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var seen = Set<UUID>()
        let ordered = (items.filter(\.isActive) + items.filter { !$0.isActive }.reversed())
            .filter { seen.insert($0.id).inserted }

        guard let item = ordered.first(where: { tab in
            guard let frame = tabFrames[tab.id] else { return false }
            return chromeTabPath(in: frame, corner: corner, ear: ear).contains(point)
        }) else { return }

        contextTabID = item.id
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let newRight = menu.addItem(withTitle: "在右侧新增标签页", action: #selector(contextNewRight), keyEquivalent: "")
        newRight.target = self
        let newLeft = menu.addItem(withTitle: "在左侧新增标签页", action: #selector(contextNewLeft), keyEquivalent: "")
        newLeft.target = self
        menu.addItem(.separator())

        let close = menu.addItem(withTitle: "关闭", action: #selector(contextClose), keyEquivalent: "")
        close.target = self
        close.isEnabled = true

        let closeLeft = menu.addItem(withTitle: "关闭左侧标签页", action: #selector(contextCloseLeft), keyEquivalent: "")
        closeLeft.target = self
        closeLeft.isEnabled = index > 0

        let closeRight = menu.addItem(withTitle: "关闭右侧标签页", action: #selector(contextCloseRight), keyEquivalent: "")
        closeRight.target = self
        closeRight.isEnabled = index < items.count - 1

        let closeOthers = menu.addItem(withTitle: "关闭其他标签页", action: #selector(contextCloseOthers), keyEquivalent: "")
        closeOthers.target = self
        closeOthers.isEnabled = items.count > 1

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextNewRight() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .newRight)
    }

    @objc private func contextNewLeft() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .newLeft)
    }

    @objc private func contextClose() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .close)
    }

    @objc private func contextCloseLeft() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .closeLeft)
    }

    @objc private func contextCloseRight() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .closeRight)
    }

    @objc private func contextCloseOthers() {
        guard let id = contextTabID else { return }
        onContextAction?(id, .closeOthers)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        var dirty = false
        if hoveredID != nil { hoveredID = nil; dirty = true }
        if plusHovered { plusHovered = false; dirty = true }
        if dirty { needsDisplay = true }
    }

    private func updateHover(at point: NSPoint) {
        let newPlus = plusFrame.insetBy(dx: -2, dy: -2).contains(point)
        var newHover: UUID?
        if !newPlus {
            let ordered = items.filter(\.isActive) + items.filter { !$0.isActive }.reversed()
            for item in ordered {
                guard let frame = tabFrames[item.id] else { continue }
                if chromeTabPath(in: frame, corner: corner, ear: ear).contains(point) {
                    newHover = item.id
                    break
                }
            }
        }
        if newHover != hoveredID || newPlus != plusHovered {
            hoveredID = newHover
            plusHovered = newPlus
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    private func chromeTabPath(in rect: NSRect, corner: CGFloat, ear: CGFloat) -> NSBezierPath {
        // Square tabs — no rounded corners / chrome ears.
        return NSBezierPath(rect: rect)
    }
}

/// Same interaction model as bookmark-folder chips: mouseUp → system NSMenu below the button.
final class NewMenuButton: NSButton {
    struct Item {
        let title: String
        let tag: Int
        let toolTip: String
    }

    var items: [Item] = []
    /// Insert a menu separator before this item index (e.g. after fixed New types).
    var separatorBeforeIndex: Int?
    weak var actionTarget: AnyObject?

    override func mouseDown(with event: NSEvent) {
        // Defer until mouseUp so the same event doesn't select a menu item.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showMenu()
        }
    }

    private func showMenu() {
        guard !items.isEmpty else { return }

        let menu = NSMenu()
        let itemFont = NSFont.systemFont(ofSize: 13)
        let rowWidth = max(
            72,
            ceil((items.map { ($0.title as NSString).size(withAttributes: [.font: itemFont]).width }.max() ?? 0) + 24)
        )

        for (index, item) in items.enumerated() {
            if let sep = separatorBeforeIndex, index == sep, sep > 0, sep < items.count {
                menu.addItem(.separator())
            }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let row = BookmarkMenuRowView(
                title: item.title,
                path: item.toolTip,
                font: itemFont,
                width: rowWidth
            )
            let tag = item.tag
            row.onOpen = { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard let self else { return }
                    let proxy = NSMenuItem()
                    proxy.tag = tag
                    _ = self.actionTarget?.perform(
                        #selector(BrowserWindowController.newItemMenuClicked(_:)),
                        with: proxy
                    )
                }
            }
            menuItem.view = row
            menu.addItem(menuItem)
        }

        // Same anchor as bookmark-folder menus.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}

/// Toolbar shortcut for a Settings「单独展示」custom New type.
final class ToolbarNewTypeButton: NSButton {
    var itemType: String = ""
}

/// Toolbar gear: pops chrome menu (缩放 / 更新 / 设置).
final class AppChromeMenuButton: NSButton {
    private var menuHelpers: [AnyObject] = []

    override func mouseDown(with event: NSEvent) {
        // Defer until mouseUp so the same event doesn't select a menu item.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menuHelpers = AppDelegate.shared.populateChromeMenu(menu, includeShowAndWindows: false)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
