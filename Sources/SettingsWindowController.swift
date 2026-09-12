import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()
    static let didChangeNotification = Notification.Name("NewFinder.settingsChanged")

    private let settings = AppSettings.shared
    private var rowTypeKeys: [String] = []
    private var rowIsFixed: [Bool] = []
    private var rowNameFields: [NSTextField?] = []
    private var rowToolbarChecks: [NSButton] = []
    private var typeRowsStack: NSStackView!
    private var addTypeButton: NSButton!
    private var redirectFinderCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var versionLabel: NSTextField!
    private var updateStatusLabel: NSTextField!
    private var checkUpdateButton: NSButton!
    private var downloadUpdateButton: NSButton!
    private var pendingRelease: UpdateChecker.ReleaseInfo?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NewFinder 设置"
        window.center()
        super.init(window: window)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reloadValues()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppDelegate.shared.registerAsDefaultFolderViewer()
        // Menu-bar click can race with browser ordering; re-assert Settings on top.
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    private func configure() {
        guard let content = window?.contentView else { return }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder
        content.addSubview(tabView)

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "常规"
        generalItem.view = makeGeneralTab()
        tabView.addTabViewItem(generalItem)

        let shortcutsItem = NSTabViewItem(identifier: "shortcuts")
        shortcutsItem.label = "快捷键"
        shortcutsItem.view = makeShortcutsTab()
        tabView.addTabViewItem(shortcutsItem)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func makeGeneralTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let title = NSTextField(labelWithString: "常规")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)

        redirectFinderCheckbox = NSButton(
            checkboxWithTitle: "拦截系统 Finder，改用 NewFinder",
            target: self,
            action: #selector(toggleRedirectFinder)
        )
        stack.addArrangedSubview(redirectFinderCheckbox)

        launchAtLoginCheckbox = NSButton(
            checkboxWithTitle: "登录时打开 NewFinder（便于持续拦截）",
            target: self,
            action: #selector(toggleLaunchAtLogin)
        )
        stack.addArrangedSubview(launchAtLoginCheckbox)

        let updateRow = NSStackView()
        updateRow.orientation = .horizontal
        updateRow.spacing = 8
        updateRow.alignment = .centerY
        checkUpdateButton = NSButton(title: "检查更新", target: self, action: #selector(checkForUpdates))
        checkUpdateButton.bezelStyle = .rounded
        versionLabel = NSTextField(labelWithString: UpdateChecker.currentVersion)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        downloadUpdateButton = NSButton(title: "下载更新", target: self, action: #selector(downloadUpdate))
        downloadUpdateButton.bezelStyle = .rounded
        downloadUpdateButton.isHidden = true
        updateRow.addArrangedSubview(checkUpdateButton)
        updateRow.addArrangedSubview(versionLabel)
        updateRow.addArrangedSubview(downloadUpdateButton)
        stack.addArrangedSubview(updateRow)

        updateStatusLabel = NSTextField(wrappingLabelWithString: "")
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.preferredMaxLayoutWidth = 500
        updateStatusLabel.isHidden = true
        stack.addArrangedSubview(updateStatusLabel)

        let newTitle = NSTextField(labelWithString: "新建类型")
        newTitle.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(newTitle)

        let newHint = NSTextField(wrappingLabelWithString: "文件夹 / txt / docx / pptx / xlsx 名称不可改。勾选「单独展示」后会出现在 New 左侧；删除后可用「添加类型」恢复。")
        newHint.font = .systemFont(ofSize: 11)
        newHint.textColor = .secondaryLabelColor
        newHint.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(newHint)

        typeRowsStack = NSStackView()
        typeRowsStack.orientation = .vertical
        typeRowsStack.alignment = .leading
        typeRowsStack.spacing = 6
        typeRowsStack.translatesAutoresizingMaskIntoConstraints = false
        typeRowsStack.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.addArrangedSubview(typeRowsStack)

        addTypeButton = NSButton(title: "添加类型", target: self, action: #selector(addTypeClicked(_:)))
        addTypeButton.bezelStyle = .rounded
        stack.addArrangedSubview(addTypeButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            typeRowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    private func makeShortcutsTab() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let title = NSTextField(labelWithString: "文件操作快捷键")
        title.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(title)

        let hint = NSTextField(wrappingLabelWithString: "以下操作已从工具栏移除，请使用快捷键完成。先选中文件或文件夹，再按下对应按键。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 500
        stack.addArrangedSubview(hint)

        let rows: [(String, String, String)] = [
            ("重命名", "F2", "编辑选中项的名称"),
            ("拷贝", "⌘C", "复制选中项到剪贴板"),
            ("剪切", "⌘X", "剪切选中项（粘贴后移动）"),
            ("粘贴", "⌘V", "粘贴到当前文件夹或展开中的文件夹"),
            ("移到废纸篓", "Delete 或 ⌘⌫", "删除选中项")
        ]

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        list.wantsLayer = true
        list.layer?.cornerRadius = 8
        list.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        for (index, entry) in rows.enumerated() {
            list.addArrangedSubview(makeShortcutRow(name: entry.0, keys: entry.1, detail: entry.2))
            if index < rows.count - 1 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                list.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        stack.addArrangedSubview(list)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            list.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return container
    }

    private func makeShortcutRow(name: String, keys: String, detail: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keyLabel = NSTextField(labelWithString: keys)
        keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.textColor = .labelColor
        keyLabel.alignment = .right
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(nameLabel)
        row.addSubview(detailLabel)
        row.addSubview(keyLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            detailLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyLabel.leadingAnchor, constant: -12),

            keyLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            keyLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func reloadValues() {
        redirectFinderCheckbox.state = settings.redirectFinderClicks ? .on : .off
        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
        versionLabel.stringValue = UpdateChecker.currentVersion
        rebuildTypeRows()
    }

    private func setUpdateStatus(_ text: String) {
        updateStatusLabel.stringValue = text
        updateStatusLabel.isHidden = text.isEmpty
    }

    @objc private func checkForUpdates() {
        checkUpdateButton.isEnabled = false
        downloadUpdateButton.isHidden = true
        pendingRelease = nil
        setUpdateStatus("正在检查更新…")

        UpdateChecker.fetchLatest { [weak self] result in
            guard let self else { return }
            self.checkUpdateButton.isEnabled = true
            switch result {
            case .failure:
                self.setUpdateStatus("检查失败，请确认网络连接后重试。")
            case .success(let release):
                let current = UpdateChecker.currentVersion
                if UpdateChecker.isVersion(release.version, newerThan: current) {
                    self.pendingRelease = release
                    self.setUpdateStatus("发现新版本 \(release.version)。")
                    self.downloadUpdateButton.isHidden = false
                } else {
                    self.setUpdateStatus("已是最新版本。")
                }
            }
        }
    }

    @objc private func downloadUpdate() {
        guard let release = pendingRelease else { return }
        checkUpdateButton.isEnabled = false
        downloadUpdateButton.isEnabled = false
        setUpdateStatus("正在下载 \(release.version)…")

        UpdateChecker.download(release) { [weak self] result in
            guard let self else { return }
            self.checkUpdateButton.isEnabled = true
            self.downloadUpdateButton.isEnabled = true
            switch result {
            case .failure:
                self.setUpdateStatus("下载失败，请稍后重试或在 GitHub Releases 手动下载。")
            case .success(let dmgURL):
                NSWorkspace.shared.open(dmgURL)
                self.setUpdateStatus("已打开安装包，请拖入「应用程序」完成更新。")
                let alert = NSAlert()
                alert.messageText = "更新包已下载"
                alert.informativeText = """
                已打开 \(dmgURL.lastPathComponent)。
                将 NewFinder 拖入「应用程序」文件夹覆盖旧版本，然后重新打开即可。
                """
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    private func rebuildTypeRows() {
        typeRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowTypeKeys.removeAll()
        rowIsFixed.removeAll()
        rowNameFields.removeAll()
        rowToolbarChecks.removeAll()

        for type in settings.enabledFixedNewItemTypes {
            appendTypeRow(
                typeKey: type,
                displayName: AppSettings.displayName(forNewItemType: type),
                isFixed: true,
                showInToolbar: settings.isToolbarNewItemType(type),
                focus: false
            )
        }
        for type in settings.customNewItemTypes {
            appendTypeRow(
                typeKey: type,
                displayName: type,
                isFixed: false,
                showInToolbar: settings.isToolbarNewItemType(type),
                focus: false
            )
        }
    }

    private func appendTypeRow(
        typeKey: String,
        displayName: String,
        isFixed: Bool,
        showInToolbar: Bool,
        focus: Bool
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let field = NSTextField(string: displayName)
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "扩展名，如 R、py"
        field.isEditable = !isFixed
        field.isSelectable = !isFixed
        field.isBordered = !isFixed
        field.isBezeled = !isFixed
        field.drawsBackground = !isFixed
        if isFixed {
            field.textColor = .labelColor
            field.backgroundColor = .clear
            field.focusRingType = .none
        } else {
            field.delegate = self
            field.target = self
            field.action = #selector(typesChanged)
        }
        field.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let toolbarCheck = NSButton(
            checkboxWithTitle: "单独展示",
            target: self,
            action: #selector(typesChanged)
        )
        toolbarCheck.state = showInToolbar ? .on : .off

        let remove = NSButton(title: "删除", target: self, action: #selector(removeTypeRow(_:)))
        remove.bezelStyle = .rounded
        remove.setButtonType(.momentaryPushIn)

        row.addArrangedSubview(field)
        row.addArrangedSubview(toolbarCheck)
        row.addArrangedSubview(remove)
        typeRowsStack.addArrangedSubview(row)

        rowTypeKeys.append(typeKey)
        rowIsFixed.append(isFixed)
        rowNameFields.append(isFixed ? nil : field)
        rowToolbarChecks.append(toolbarCheck)

        if focus, !isFixed {
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(field)
            }
        }
    }

    @objc private func addTypeClicked(_ sender: NSButton) {
        let missingFixed = AppSettings.fixedNewItemTypes.filter { candidate in
            !settings.enabledFixedNewItemTypes.contains { $0.lowercased() == candidate.lowercased() }
        }

        if missingFixed.isEmpty {
            addCustomTypeRow()
            return
        }

        let menu = NSMenu()
        for type in missingFixed {
            let title = "恢复「\(AppSettings.displayName(forNewItemType: type))」"
            let item = NSMenuItem(title: title, action: #selector(restoreFixedType(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "自定义扩展名", action: #selector(addCustomTypeRow), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        let point = NSPoint(x: 0, y: sender.bounds.height + 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func restoreFixedType(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? String,
              AppSettings.canonicalFixedType(type) != nil else { return }
        var enabled = settings.enabledFixedNewItemTypes
        if !enabled.contains(where: { $0.lowercased() == type.lowercased() }) {
            enabled.append(type)
        }
        // Keep canonical order.
        settings.enabledFixedNewItemTypes = enabled
        rebuildTypeRows()
        notifyChange()
    }

    @objc private func addCustomTypeRow() {
        let customCount = rowIsFixed.filter { !$0 }.count
        guard customCount < 40 else { return }
        appendTypeRow(
            typeKey: "",
            displayName: "",
            isFixed: false,
            showInToolbar: false,
            focus: true
        )
        typesChanged()
    }

    @objc private func removeTypeRow(_ sender: NSButton) {
        guard let row = sender.superview as? NSStackView,
              let index = typeRowsStack.arrangedSubviews.firstIndex(of: row),
              rowTypeKeys.indices.contains(index) else { return }

        rowTypeKeys.remove(at: index)
        rowIsFixed.remove(at: index)
        rowNameFields.remove(at: index)
        rowToolbarChecks.remove(at: index)
        row.removeFromSuperview()
        typesChanged()
    }

    @objc private func toggleRedirectFinder() {
        settings.redirectFinderClicks = redirectFinderCheckbox.state == .on
        AppDelegate.shared.updateFinderWindowPollTimer()
        notifyChange()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin = launchAtLoginCheckbox.state == .on
        AppDelegate.shared.applyLaunchAtLoginSetting()
        notifyChange()
    }

    @objc private func typesChanged() {
        var enabledFixed: [String] = []
        var custom: [String] = []
        var toolbarKeys = Set<String>()

        for index in rowTypeKeys.indices {
            let isFixed = rowIsFixed[index]
            let checkOn = rowToolbarChecks.indices.contains(index) && rowToolbarChecks[index].state == .on

            if isFixed {
                let key = rowTypeKeys[index]
                enabledFixed.append(key)
                if checkOn {
                    toolbarKeys.insert(key.lowercased())
                }
            } else {
                let typed = rowNameFields[index]?.stringValue ?? rowTypeKeys[index]
                custom.append(typed)
                let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if checkOn, !trimmed.isEmpty, AppSettings.canonicalFixedType(trimmed) == nil {
                    toolbarKeys.insert(trimmed.lowercased())
                }
            }
        }

        settings.enabledFixedNewItemTypes = enabledFixed
        settings.customNewItemTypes = custom
        settings.toolbarNewItemTypeKeys = toolbarKeys

        // Keep rowTypeKeys for custom rows in sync with typed text (before normalize/sort).
        for index in rowTypeKeys.indices where !rowIsFixed[index] {
            rowTypeKeys[index] = rowNameFields[index]?.stringValue ?? ""
        }
        notifyChange()
    }

    func controlTextDidChange(_ obj: Notification) {
        typesChanged()
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
