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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
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

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

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
        updateStatusLabel.preferredMaxLayoutWidth = 520
        updateStatusLabel.isHidden = true
        stack.addArrangedSubview(updateStatusLabel)

        let newTitle = NSTextField(labelWithString: "新建类型")
        newTitle.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(newTitle)

        let newHint = NSTextField(wrappingLabelWithString: "文件夹 / txt / docx / pptx / xlsx 名称不可改。勾选「展示在工具栏」后会出现在 New 右侧；删除后可用「添加类型」恢复。")
        newHint.font = .systemFont(ofSize: 11)
        newHint.textColor = .secondaryLabelColor
        newHint.preferredMaxLayoutWidth = 520
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
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            typeRowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
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
            checkboxWithTitle: "展示在工具栏",
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
