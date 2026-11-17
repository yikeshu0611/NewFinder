import AppKit

/// 「打开方式 → 其他…」的自制选择窗口（非模态，右键菜单里 нельзя runModal）。
///
/// 上面是地址栏（目录路径 + 浏览），下面是该目录下的 app 列表，
/// 选中后底部有两个按钮：打开 / 默认打开。
final class OpenWithPickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let fileURLs: [URL]
    private var apps: [OpenWithCatalog.AppInfo] = []
    private var table: NSTableView!
    private var pathField: NSTextField!
    private var searchField: NSSearchField!
    private var openButton: NSButton!
    private var defaultButton: NSButton!
    private var statusLabel: NSTextField!
    /// 地址栏目录下的全部 app；表格实际显示的是过滤后的 filteredApps。
    private var filteredApps: [OpenWithCatalog.AppInfo] = []
    private let onOpenAction: (URL) -> Void
    private let onOpenDefaultAction: (URL) -> Void
    /// 非模态窗口靠它续命，关闭后移除。
    private static var active: [OpenWithPickerWindowController] = []

    /// 非模态弹出（右键菜单里跑 runModal 会卡死，直接用回调）。
    static func show(for fileURLs: [URL], onOpen: @escaping (URL) -> Void, onOpenDefault: @escaping (URL) -> Void) {
        let controller = OpenWithPickerWindowController(fileURLs: fileURLs, onOpen: onOpen, onOpenDefault: onOpenDefault)
        active.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(fileURLs: [URL], onOpen: @escaping (URL) -> Void, onOpenDefault: @escaping (URL) -> Void) {
        self.fileURLs = fileURLs
        self.onOpenAction = onOpen
        self.onOpenDefaultAction = onOpenDefault
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "选择应用程序"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureUI()
        pathField.stringValue = "/Applications"
        reloadApps()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.active.removeAll { $0 === self }
    }

    private func configureUI() {
        guard let content = window?.contentView else { return }

        let addressLabel = NSTextField(labelWithString: "位置")
        addressLabel.font = .systemFont(ofSize: 12)
        addressLabel.translatesAutoresizingMaskIntoConstraints = false

        pathField = NSTextField(string: "")
        pathField.font = .systemFont(ofSize: 12)
        pathField.isEditable = true
        pathField.isSelectable = true
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(pathChanged)
        pathField.translatesAutoresizingMaskIntoConstraints = false

        let browseButton = NSButton(title: "浏览…", target: self, action: #selector(browseClicked))
        browseButton.bezelStyle = .rounded
        browseButton.translatesAutoresizingMaskIntoConstraints = false

        searchField = NSSearchField(string: "")
        searchField.placeholderString = "搜索应用程序"
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 28
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        let column = NSTableColumn(identifier: .init("app"))
        column.title = "应用程序"
        table.addTableColumn(column)
        scroll.documentView = table

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        openButton = NSButton(title: "打开", target: self, action: #selector(openClicked))
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.isEnabled = false
        defaultButton = NSButton(title: "默认打开", target: self, action: #selector(defaultOpenClicked))
        defaultButton.bezelStyle = .rounded
        defaultButton.isEnabled = false
        defaultButton.toolTip = "设为此类文件的默认打开方式并打开"

        let buttonRow = NSStackView(views: [statusLabel, NSView(), cancelButton, openButton, defaultButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(addressLabel)
        content.addSubview(pathField)
        content.addSubview(browseButton)
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            addressLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            addressLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            addressLabel.widthAnchor.constraint(equalToConstant: 32),

            pathField.centerYAnchor.constraint(equalTo: addressLabel.centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: addressLabel.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -8),

            browseButton.centerYAnchor.constraint(equalTo: addressLabel.centerYAnchor),
            browseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            browseButton.widthAnchor.constraint(equalToConstant: 70),

            searchField.topAnchor.constraint(equalTo: addressLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window?.initialFirstResponder = table
    }

    // MARK: - 目录列表

    @objc private func pathChanged() {
        reloadApps()
    }

    @objc private func browseClicked() {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = false
        open.prompt = "选择"
        open.message = "选择包含应用程序的目录"
        if !pathField.stringValue.isEmpty {
            open.directoryURL = URL(fileURLWithPath: pathField.stringValue)
        }
        open.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = open.url else { return }
            self.pathField.stringValue = url.path
            self.reloadApps()
        }
    }

    private func reloadApps() {
        let dir = URL(fileURLWithPath: pathField.stringValue.isEmpty ? "/Applications" : pathField.stringValue)
        apps = Self.apps(in: dir)
        applyFilter()
    }

    @objc private func searchChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredApps = apps
        } else {
            filteredApps = apps.filter {
                $0.name.lowercased().contains(query)
                    || $0.url.deletingPathExtension().lastPathComponent.lowercased().contains(query)
            }
        }
        table.reloadData()
        updateButtons()
        if apps.isEmpty {
            statusLabel.stringValue = "该目录下没有应用程序"
        } else if filteredApps.count == apps.count {
            statusLabel.stringValue = "\(apps.count) 个应用程序"
        } else {
            statusLabel.stringValue = "\(filteredApps.count) / \(apps.count) 个应用程序"
        }
    }

    /// 列出目录下的 .app（顶层 + 下一级子目录），按名称排序。
    private static func apps(in directory: URL) -> [OpenWithCatalog.AppInfo] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        var candidates: [URL] = []
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for url in items {
            if url.pathExtension.lowercased() == "app" {
                candidates.append(url.standardizedFileURL)
                continue
            }
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            if let nested = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for child in nested where child.pathExtension.lowercased() == "app" {
                    candidates.append(child.standardizedFileURL)
                }
            }
        }
        let selfBundle = Bundle.main.bundleIdentifier
        let deduped = OpenWithCatalog.dedupe(candidates).filter { $0.bundleIdentifier != selfBundle }
        return deduped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - 按钮

    @objc private func cancelClicked() {
        window?.close()
    }

    @objc private func openClicked() {
        guard let app = selectedApp() else { NSSound.beep(); return }
        let url = app.url
        let action = onOpenAction
        window?.close()
        action(url)
    }

    @objc private func defaultOpenClicked() {
        guard let app = selectedApp() else { NSSound.beep(); return }
        let url = app.url
        let action = onOpenDefaultAction
        window?.close()
        action(url)
    }

    private func selectedApp() -> OpenWithCatalog.AppInfo? {
        let row = table.selectedRow
        guard row >= 0, filteredApps.indices.contains(row) else { return nil }
        return filteredApps[row]
    }

    private func updateButtons() {
        let hasSelection = table.selectedRow >= 0
        openButton.isEnabled = hasSelection
        defaultButton.isEnabled = hasSelection
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("openwith.pick")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: 13)
            cell.addSubview(imageView)
            cell.addSubview(text)
            cell.imageView = imageView
            cell.textField = text
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 20),
                imageView.heightAnchor.constraint(equalToConstant: 20),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let app = filteredApps[row]
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = NSSize(width: 20, height: 20)
        cell.imageView?.image = icon
        cell.textField?.stringValue = OpenWithCatalog.disambiguatedName(for: app, among: filteredApps)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField, field === searchField {
            applyFilter()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSSearchField, field === searchField {
            applyFilter()
        } else {
            reloadApps()
        }
    }
}
