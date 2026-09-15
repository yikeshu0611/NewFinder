import AppKit

/// Compare workspace UI: one panel per open file (unlimited), horizontally split.
final class CompareViewController: NSViewController, NSTextViewDelegate {
    var onSummaryChange: ((String) -> Void)?

    private(set) var workspaceIndex = 1
    private var isActive = false
    private var observer: NSObjectProtocol?
    private var focusedPaneIndex = 0
    private var applyingText = false

    private var splitView: CompareSplitView!
    private var paneViews: [ComparePaneView] = []
    private var syncScrollHost: NSView!
    private var syncScrollButton: NSButton!
    private var syncHostCenterX: NSLayoutConstraint!
    private var syncHostTop: NSLayoutConstraint!
    private var headerDividerShield: DividerCursorShieldView!
    private var shieldCenterX: NSLayoutConstraint!
    private var scrollSyncEnabled = true
    private var isSyncingScroll = false
    private var clipObservers: [NSObjectProtocol] = []
    private var lastPaneCount = -1
    private var diffRefreshWork: DispatchWorkItem?
    private let syncButtonSize: CGFloat = 22
    private let paneHeaderHeight: CGFloat = 28

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        configureUI()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        removeClipObservers()
    }

    func activate(workspace index: Int) {
        flushEditorsToSession()
        workspaceIndex = max(1, min(CompareSession.workspaceCount, index))
        isActive = true
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .compareWorkspacesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, self.isActive else { return }
                let changed = note.userInfo?["workspace"] as? Int
                if changed == nil || changed == self.workspaceIndex {
                    self.reloadFromSession()
                }
            }
        }
        reloadFromSession()
    }

    func deactivate() {
        flushEditorsToSession()
        isActive = false
    }

    func reloadFromSession() {
        let ws = CompareSession.shared.workspace(at: workspaceIndex) ?? CompareWorkspace()
        rebuildPanes(for: ws)
        onSummaryChange?("")
    }

    private func configureUI() {
        let root = view
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        let split = CompareSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.wantsLayer = true
        split.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        split.headerClearance = paneHeaderHeight
        split.onLayout = { [weak self] in self?.positionSyncScrollButton() }
        splitView = split

        syncScrollHost = makeSyncScrollControl()
        headerDividerShield = DividerCursorShieldView()
        headerDividerShield.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(split)
        root.addSubview(headerDividerShield)
        root.addSubview(syncScrollHost)
        syncScrollHost.translatesAutoresizingMaskIntoConstraints = false
        syncHostCenterX = syncScrollHost.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: 0)
        syncHostTop = syncScrollHost.topAnchor.constraint(
            equalTo: root.topAnchor,
            constant: (paneHeaderHeight - syncButtonSize) / 2
        )
        shieldCenterX = headerDividerShield.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            headerDividerShield.topAnchor.constraint(equalTo: root.topAnchor),
            headerDividerShield.heightAnchor.constraint(equalToConstant: paneHeaderHeight),
            headerDividerShield.widthAnchor.constraint(equalToConstant: 28),
            shieldCenterX,

            syncHostCenterX,
            syncHostTop,
            syncScrollHost.widthAnchor.constraint(equalToConstant: syncButtonSize),
            syncScrollHost.heightAnchor.constraint(equalToConstant: syncButtonSize)
        ])

        updateSyncScrollButtonAppearance()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, self.view.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "s" {
                self.saveFocused()
                return nil
            }
            return event
        }
    }

    private func rebuildPanes(for ws: CompareWorkspace) {
        flushEditorsToSession()
        removeClipObservers()

        let ids = ws.paneDocIDs
        // Reuse existing pane views when count matches to preserve scroll position where possible.
        while paneViews.count > ids.count {
            let removed = paneViews.removeLast()
            removed.removeFromSuperview()
        }
        while paneViews.count < ids.count {
            let pane = ComparePaneView(headerHeight: paneHeaderHeight)
            pane.autoresizingMask = [.width, .height]
            pane.editor.delegate = self
            pane.onClose = { [weak self] docID in
                self?.closeDocument(docID)
            }
            pane.onSave = { [weak self] docID in
                self?.saveDocument(docID)
            }
            pane.onFocus = { [weak self] index in
                self?.focusedPaneIndex = index
            }
            pane.onDropDocument = { [weak self] docID, paneIndex in
                self?.acceptDrop(documentID: docID, ontoPane: paneIndex)
            }
            paneViews.append(pane)
            splitView.addSubview(pane)
        }

        // Ensure split only has current panes as arranged subviews.
        for sub in splitView.subviews where !paneViews.contains(where: { $0 === sub }) {
            sub.removeFromSuperview()
        }
        for pane in paneViews where pane.superview !== splitView {
            splitView.addSubview(pane)
        }

        for (index, docID) in ids.enumerated() {
            let pane = paneViews[index]
            pane.paneIndex = index
            pane.documentID = docID
            if let doc = ws.document(id: docID) {
                pane.setTitle(doc.title)
                applyingText = true
                if pane.editor.string != doc.text {
                    pane.editor.string = doc.text
                }
                pane.enforceNoLineWrap()
                pane.editor.isEditable = true
                applyingText = false
            }
        }

        if ids.isEmpty {
            // Keep one empty placeholder pane.
            if paneViews.isEmpty {
                let pane = ComparePaneView(headerHeight: paneHeaderHeight)
                pane.autoresizingMask = [.width, .height]
                pane.paneIndex = 0
                pane.setPlaceholder("右键文件 → 比对 → 打开到此通道")
                paneViews.append(pane)
                splitView.addSubview(pane)
            } else {
                paneViews[0].documentID = nil
                paneViews[0].setPlaceholder("右键文件 → 比对 → 打开到此通道")
                paneViews[0].editor.string = ""
                paneViews[0].editor.isEditable = false
            }
        }

        installScrollSyncObservers()
        focusedPaneIndex = min(focusedPaneIndex, max(0, paneViews.count - 1))
        applyCodeCompare(fromSession: true)

        let countChanged = paneViews.count != lastPaneCount
        lastPaneCount = paneViews.count
        DispatchQueue.main.async { [weak self] in
            if countChanged { self?.equalizeSplitPositions() }
            self?.positionSyncScrollButton()
        }
    }

    private func equalizeSplitPositions() {
        guard let split = splitView, split.subviews.count >= 2, split.bounds.width > 1 else { return }
        let n = split.subviews.count
        let each = split.bounds.width / CGFloat(n)
        for i in 0 ..< (n - 1) {
            split.setPosition(each * CGFloat(i + 1), ofDividerAt: i)
        }
    }

    private func makeSyncScrollControl() -> NSView {
        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.cornerRadius = 4
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor

        let image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: "联动滚动"
        )
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(toggleScrollSync(_:)))
        button.setButtonType(.toggle)
        button.bezelStyle = .shadowlessSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.state = .on
        button.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            button.topAnchor.constraint(equalTo: host.topAnchor),
            button.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        syncScrollButton = button
        return host
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionSyncScrollButton()
    }

    private func positionSyncScrollButton() {
        guard syncHostCenterX != nil, let split = splitView, split.subviews.count >= 2 else {
            syncScrollHost?.isHidden = true
            headerDividerShield?.isHidden = true
            return
        }
        syncScrollHost.isHidden = false
        headerDividerShield.isHidden = false
        // Center on the first divider's left-pane vertical scroller (or seam).
        let leftPane = split.subviews[0]
        let midX: CGFloat
        if let scroll = (leftPane as? ComparePaneView)?.editorScroll,
           let scroller = scroll.verticalScroller,
           scroller.superview != nil,
           scroller.frame.width > 1 {
            midX = scroller.convert(scroller.bounds, to: view).midX
        } else {
            let edge = leftPane.convert(NSPoint(x: leftPane.bounds.maxX, y: 0), to: view).x
            midX = edge + split.dividerThickness * 0.5
        }
        syncHostCenterX.constant = midX
        shieldCenterX.constant = midX
        view.window?.invalidateCursorRects(for: headerDividerShield)
    }

    @objc private func toggleScrollSync(_ sender: NSButton) {
        scrollSyncEnabled = sender.state == .on
        updateSyncScrollButtonAppearance()
        if scrollSyncEnabled, let source = paneViews[safe: focusedPaneIndex]?.editorScroll {
            syncScroll(from: source)
        }
    }

    private func updateSyncScrollButtonAppearance() {
        let on = scrollSyncEnabled
        syncScrollButton.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        syncScrollButton.toolTip = on
            ? "联动滚动已开启（点击关闭）"
            : "联动滚动已关闭（点击开启）"
    }

    private func removeClipObservers() {
        for token in clipObservers {
            NotificationCenter.default.removeObserver(token)
        }
        clipObservers.removeAll()
    }

    private func installScrollSyncObservers() {
        removeClipObservers()
        for pane in paneViews {
            let scroll = pane.editorScroll
            scroll.contentView.postsBoundsChangedNotifications = true
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self, weak scroll] _ in
                guard let self, let scroll else { return }
                self.syncScroll(from: scroll)
            }
            clipObservers.append(token)
        }
    }

    private func syncScroll(from source: NSScrollView) {
        guard scrollSyncEnabled, !isSyncingScroll, isActive else { return }
        isSyncingScroll = true
        defer { isSyncingScroll = false }
        let origin = source.contentView.bounds.origin
        for pane in paneViews {
            let target = pane.editorScroll
            guard target !== source else { continue }
            let clip = target.contentView
            var next = origin
            if let doc = target.documentView {
                let maxX = max(0, doc.bounds.width - clip.bounds.width)
                let maxY = max(0, doc.bounds.height - clip.bounds.height)
                next.x = min(max(0, next.x), maxX)
                next.y = min(max(0, next.y), maxY)
            }
            if clip.bounds.origin != next {
                clip.scroll(to: next)
                target.reflectScrolledClipView(clip)
            }
        }
    }

    private func acceptDrop(documentID: UUID, ontoPane paneIndex: Int) {
        flushEditorsToSession()
        CompareSession.shared.swapPanes(workspace: workspaceIndex, documentID: documentID, withPaneAt: paneIndex)
        focusedPaneIndex = paneIndex
    }

    private func closeDocument(_ docID: UUID) {
        flushEditorsToSession()
        CompareSession.shared.closeDocument(workspace: workspaceIndex, documentID: docID)
    }

    @objc private func saveFocused() {
        guard let pane = paneViews[safe: focusedPaneIndex], let id = pane.documentID else { return }
        saveDocument(id)
    }

    private func saveDocument(_ docID: UUID) {
        flushEditorsToSession()
        guard let doc = CompareSession.shared.workspace(at: workspaceIndex)?.document(id: docID) else { return }
        do {
            try doc.text.write(to: doc.url, atomically: true, encoding: .utf8)
            CompareSession.shared.markSaved(workspace: workspaceIndex, documentID: docID)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func flushEditorsToSession() {
        for pane in paneViews {
            guard let id = pane.documentID else { continue }
            CompareSession.shared.updateText(
                workspace: workspaceIndex,
                documentID: id,
                text: pane.realText()
            )
        }
    }

    /// Independent per-file highlight (no spacer rows — edits are not linked across panes).
    private func applyCodeCompare(fromSession: Bool) {
        let live = paneViews.filter { $0.documentID != nil }
        guard live.count >= 2 else {
            for pane in paneViews where pane.documentID != nil {
                pane.applyPlainHighlight()
            }
            return
        }
        // Always use each pane's own buffer (or its session copy). Never rewrite one file from another.
        let texts: [String] = paneViews.map { pane in
            guard let id = pane.documentID else { return "" }
            if fromSession {
                return CompareSession.shared.workspace(at: workspaceIndex)?.document(id: id)?.text ?? pane.realText()
            }
            return pane.realText()
        }
        let marks = TextDiffEngine.independentHighlights(texts)
        applyingText = true
        for (i, pane) in paneViews.enumerated() where i < marks.count && pane.documentID != nil {
            let sel = pane.editor.selectedRange()
            pane.applyIndependentHighlight(
                text: texts[i],
                kinds: marks[i].kinds,
                intras: marks[i].intras,
                allowReplaceString: fromSession && pane.editor.string != texts[i]
            )
            let maxLen = (pane.editor.string as NSString).length
            if sel.location <= maxLen {
                let len = min(sel.length, max(0, maxLen - sel.location))
                pane.editor.setSelectedRange(NSRange(location: sel.location, length: len))
            }
        }
        applyingText = false
    }

    private func scheduleCodeCompareRefresh() {
        diffRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            // Re-color only; do not flush or rewrite other panes' text.
            self.applyCodeCompare(fromSession: false)
        }
        diffRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !applyingText, let tv = notification.object as? NSTextView else { return }
        guard let pane = paneViews.first(where: { $0.editor === tv }),
              let id = pane.documentID else { return }
        focusedPaneIndex = pane.paneIndex
        CompareSession.shared.updateText(workspace: workspaceIndex, documentID: id, text: pane.realText())
        scheduleCodeCompareRefresh()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView,
              let pane = paneViews.first(where: { $0.editor === tv }) else { return }
        focusedPaneIndex = pane.paneIndex
    }
}

// MARK: - Pane view

private final class ComparePaneView: NSView {
    var paneIndex = 0
    var documentID: UUID?
    var onClose: ((UUID) -> Void)?
    var onSave: ((UUID) -> Void)?
    var onFocus: ((Int) -> Void)?
    var onDropDocument: ((UUID, Int) -> Void)?

    let editor = NSTextView(usingTextLayoutManager: false)
    let editorScroll = NSScrollView()
    private let titleLabel = PassThroughLabel(labelWithString: "")
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)
    private let saveButton = NSButton(image: ComparePaneView.rstudioSaveImage(), target: nil, action: nil)
    private let header = ComparePaneHeaderDropView()
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(headerHeight: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        header.translatesAutoresizingMaskIntoConstraints = false
        header.onAcceptDrop = { [weak self] docID in
            guard let self else { return }
            self.onDropDocument?(docID, self.paneIndex)
        }

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.toolTip = "拖动文件名可调整面板顺序"

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 10, weight: .semibold)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "关闭"

        saveButton.bezelStyle = .inline
        saveButton.isBordered = false
        saveButton.imagePosition = .imageOnly
        saveButton.imageScaling = .scaleProportionallyDown
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.toolTip = "保存 (⌘S)"

        let chip = NSView()
        chip.identifier = NSUserInterfaceItemIdentifier("compare-chip")
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = NSColor.selectedControlColor.withAlphaComponent(0.35).cgColor
        chip.addSubview(titleLabel)
        chip.addSubview(closeButton)
        chip.addSubview(saveButton)

        header.addSubview(chip)
        header.registerForDraggedTypes([CompareDrag.pasteboardType])

        editor.isEditable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.backgroundColor = .textBackgroundColor
        editor.drawsBackground = true
        editor.focusRingType = .none
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.height]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let noWrap = NSMutableParagraphStyle()
        noWrap.lineBreakMode = .byClipping
        editor.defaultParagraphStyle = noWrap
        editor.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .paragraphStyle: noWrap
        ]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainer?.lineFragmentPadding = 4

        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.borderType = .noBorder
        editorScroll.focusRingType = .none
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = .textBackgroundColor
        editorScroll.scrollerStyle = .legacy
        editorScroll.documentView = editor
        editorScroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(editorScroll)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),

            chip.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            chip.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            chip.heightAnchor.constraint(equalToConstant: 24),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -8),

            titleLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 2),
            closeButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            saveButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 0),
            saveButton.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
            saveButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 16),
            saveButton.heightAnchor.constraint(equalToConstant: 16),

            editorScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.textColor = .labelColor
        closeButton.isHidden = false
        saveButton.isHidden = false
    }

    func setPlaceholder(_ text: String) {
        titleLabel.stringValue = text
        titleLabel.textColor = .tertiaryLabelColor
        closeButton.isHidden = true
        saveButton.isHidden = true
        documentID = nil
    }

    func enforceNoLineWrap() {
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.height]
    }

    func realText() -> String {
        editor.string
    }

    func applyPlainHighlight() {
        let text = editor.string
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let noWrap = NSMutableParagraphStyle()
        noWrap.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: noWrap,
            .backgroundColor: NSColor.textBackgroundColor
        ]
        editor.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        editor.typingAttributes = attrs
        enforceNoLineWrap()
    }

    /// Highlight this file's own lines only; never inserts alignment blank rows.
    func applyIndependentHighlight(
        text: String,
        kinds: [CompareLineKind],
        intras: [[NSRange]],
        allowReplaceString: Bool = true
    ) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let noWrap = NSMutableParagraphStyle()
        noWrap.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: noWrap,
            .backgroundColor: NSColor.textBackgroundColor
        ]
        guard let storage = editor.textStorage else { return }

        if allowReplaceString, storage.string != text {
            storage.setAttributedString(NSAttributedString(string: text, attributes: base))
        }

        let ns = storage.string as NSString
        storage.beginEditing()
        if ns.length > 0 {
            storage.addAttributes(base, range: NSRange(location: 0, length: ns.length))
        }
        var lineIndex = 0
        var loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let kind = lineIndex < kinds.count ? kinds[lineIndex] : .equal
            storage.addAttribute(.backgroundColor, value: CompareHighlight.lineColor(kind), range: lineRange)
            var content = lineRange
            if content.length > 0 {
                let last = ns.character(at: NSMaxRange(content) - 1)
                if last == 10 || last == 13 { content.length -= 1 }
            }
            if lineIndex < intras.count {
                for intra in intras[lineIndex] {
                    let abs = NSRange(location: lineRange.location + intra.location, length: intra.length)
                    let clipped = NSIntersectionRange(abs, content)
                    if clipped.length > 0 {
                        storage.addAttribute(
                            .backgroundColor,
                            value: CompareHighlight.intraColor(kind),
                            range: clipped
                        )
                    }
                }
            }
            loc = NSMaxRange(lineRange)
            lineIndex += 1
        }
        storage.endEditing()
        editor.typingAttributes = base
        enforceNoLineWrap()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?(paneIndex)
        let hit = window?.contentView?.hitTest(event.locationInWindow)
        if hit === closeButton || hit === saveButton {
            super.mouseDown(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if header.frame.contains(local), documentID != nil {
            mouseDownPoint = local
            didDrag = false
            return
        }
        mouseDownPoint = nil
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let docID = documentID else {
            super.mouseDragged(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        didDrag = true
        let item = NSDraggingItem(pasteboardWriter: CompareDrag.Writer(documentID: docID, fromPane: paneIndex))
        let rect = NSRect(x: 8, y: bounds.height - 28, width: min(180, bounds.width - 16), height: 24)
        item.setDraggingFrame(rect, contents: Self.dragImage(title: titleLabel.stringValue, size: rect.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        didDrag = false
        super.mouseUp(with: event)
    }

    private static func dragImage(title: String, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.selectedControlColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
            let text = title as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(x: rect.minX + 8, y: rect.midY - textSize.height / 2),
                withAttributes: attrs
            )
            return true
        }
    }

    private static func rstudioSaveImage() -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            let blue = NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.78, alpha: 1)
            blue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 12, height: 12), xRadius: 1.2, yRadius: 1.2).fill()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 3.5, y: 8.2, width: 7, height: 3.2)).fill()
            NSBezierPath(roundedRect: NSRect(x: 3.2, y: 2.2, width: 7.6, height: 4.6), xRadius: 0.6, yRadius: 0.6).fill()
            blue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 5.7, y: 3.4, width: 2.6, height: 2.6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func closeClicked() {
        guard let id = documentID else { return }
        onClose?(id)
    }

    @objc private func saveClicked() {
        guard let id = documentID else { return }
        onFocus?(paneIndex)
        onSave?(id)
    }
}

extension ComparePaneView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }
}

// MARK: - Split / shield / drag helpers

private enum CompareHighlight {
    static func lineColor(_ kind: CompareLineKind) -> NSColor {
        switch kind {
        case .equal:
            return .textBackgroundColor
        case .insert:
            return NSColor(calibratedRed: 0.78, green: 0.96, blue: 0.82, alpha: 1)
        case .delete:
            return NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.84, alpha: 1)
        case .replace:
            return NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.72, alpha: 1)
        case .spacer:
            return NSColor(calibratedWhite: 0.93, alpha: 1)
        }
    }

    static func intraColor(_ kind: CompareLineKind) -> NSColor {
        switch kind {
        case .insert, .replace:
            return NSColor(calibratedRed: 0.48, green: 0.90, blue: 0.58, alpha: 1)
        case .delete:
            return NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.66, alpha: 1)
        default:
            return lineColor(kind)
        }
    }
}

private final class CompareSplitView: NSSplitView, NSSplitViewDelegate {
    var onLayout: (() -> Void)?
    var headerClearance: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        rect.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw all dividers excluding header band.
        guard subviews.count >= 2 else { return }
        for i in 0 ..< (subviews.count - 1) {
            let left = subviews[i].frame
            let height = max(0, bounds.height - headerClearance)
            let rect = NSRect(x: left.maxX, y: bounds.minY, width: dividerThickness, height: height)
            drawDivider(in: rect)
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard subviews.count >= 2 else { return }
        for i in 0 ..< (subviews.count - 1) {
            let left = subviews[i].frame
            let height = max(0, bounds.height - headerClearance)
            let rect = NSRect(x: left.maxX, y: bounds.minY, width: dividerThickness, height: height)
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if local.y >= bounds.height - headerClearance {
            NSCursor.arrow.set()
            return
        }
        for i in 0 ..< max(0, subviews.count - 1) {
            let left = subviews[i].frame
            let rect = NSRect(x: left.maxX - 5, y: bounds.minY, width: dividerThickness + 10, height: max(0, bounds.height - headerClearance))
            if rect.contains(local) {
                NSCursor.resizeLeftRight.set()
                return
            }
        }
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if local.y >= bounds.height - headerClearance {
            for subview in subviews.reversed() {
                if let hit = subview.hitTest(point) { return hit }
            }
            return nil
        }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        onLayout?()
        window?.invalidateCursorRects(for: self)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
        window?.invalidateCursorRects(for: self)
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        var rect = proposedEffectiveRect
        let maxY = bounds.height - headerClearance
        if rect.minY < maxY {
            rect.size.height = max(0, min(rect.maxY, maxY) - rect.minY)
        } else {
            rect = .zero
        }
        return rect
    }
}

private final class DividerCursorShieldView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
}

private final class ComparePaneHeaderDropView: NSView {
    var onAcceptDrop: ((UUID) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([CompareDrag.pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        CompareDrag.payload(from: sender) != nil ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        CompareDrag.payload(from: sender) != nil ? .move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let payload = CompareDrag.payload(from: sender) else { return false }
        onAcceptDrop?(payload.documentID)
        return true
    }
}

private final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum CompareDrag {
    static let pasteboardType = NSPasteboard.PasteboardType("com.newfinder.compare-pane-doc")

    struct Payload {
        let documentID: UUID
        let fromPane: Int
    }

    final class Writer: NSObject, NSPasteboardWriting {
        let documentID: UUID
        let fromPane: Int

        init(documentID: UUID, fromPane: Int) {
            self.documentID = documentID
            self.fromPane = fromPane
        }

        func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            [CompareDrag.pasteboardType]
        }

        func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            guard type == CompareDrag.pasteboardType else { return nil }
            return "\(documentID.uuidString)|\(fromPane)"
        }
    }

    static func payload(from info: NSDraggingInfo) -> Payload? {
        guard let raw = info.draggingPasteboard.string(forType: pasteboardType) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let id = UUID(uuidString: parts[0]),
              let pane = Int(parts[1]) else { return nil }
        return Payload(documentID: id, fromPane: pane)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
