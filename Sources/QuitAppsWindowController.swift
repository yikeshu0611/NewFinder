import AppKit

/// Lists regular running apps so the user can quit or force-quit them.
final class QuitAppsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = QuitAppsWindowController()

    private var apps: [NSRunningApplication] = []
    private var table: NSTableView!
    private var quitButton: NSButton!
    private var forceQuitButton: NSButton!
    private var statusLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "退出程序"
        window.minSize = NSSize(width: 360, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        reloadApps()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureUI() {
        guard let content = window?.contentView else { return }

        let hint = NSTextField(wrappingLabelWithString: "选择正在运行的程序，然后退出。未保存的内容可能会丢失。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 420
        hint.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 28
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(quitClicked)
        let column = NSTableColumn(identifier: .init("app"))
        column.title = "程序"
        table.addTableColumn(column)
        scroll.documentView = table

        quitButton = NSButton(title: "退出", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .rounded
        quitButton.isEnabled = false
        forceQuitButton = NSButton(title: "强制退出", target: self, action: #selector(forceQuitClicked))
        forceQuitButton.bezelStyle = .rounded
        forceQuitButton.isEnabled = false
        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [refreshButton, NSView(), quitButton, forceQuitButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(buttonRow)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    @objc private func refreshClicked() {
        reloadApps()
    }

    @objc private func quitClicked() {
        terminateSelected(force: false)
    }

    @objc private func forceQuitClicked() {
        terminateSelected(force: true)
    }

    private func selectedApps() -> [NSRunningApplication] {
        table.selectedRowIndexes.compactMap { apps.indices.contains($0) ? apps[$0] : nil }
    }

    private func terminateSelected(force: Bool) {
        let selected = selectedApps()
        guard !selected.isEmpty else { return }
        let names = selected.prefix(3).map { $0.localizedName ?? "未知程序" }.joined(separator: "、")
        let extra = selected.count > 3 ? " 等 \(selected.count) 个程序" : ""
        let alert = NSAlert()
        alert.messageText = force ? "强制退出选中的程序？" : "退出选中的程序？"
        alert.informativeText = "将退出：\(names)\(extra)\n未保存的更改可能会丢失。"
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: force ? "强制退出" : "退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selfID = Bundle.main.bundleIdentifier
        var quitSelf = false
        for app in selected {
            if app.bundleIdentifier == selfID {
                quitSelf = true
                continue
            }
            if force {
                app.forceTerminate()
            } else if !app.terminate() {
                app.forceTerminate()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reloadApps()
            if quitSelf {
                NSApp.terminate(nil)
            }
        }
    }

    private func reloadApps() {
        let selfID = Bundle.main.bundleIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && !app.isTerminated
                    && app.bundleIdentifier != selfID
            }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
        table.reloadData()
        updateButtons()
        statusLabel.stringValue = apps.isEmpty ? "没有其他正在运行的程序" : "\(apps.count) 个正在运行的程序"
    }

    private func updateButtons() {
        let enabled = !table.selectedRowIndexes.isEmpty
        quitButton.isEnabled = enabled
        forceQuitButton.isEnabled = enabled
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        apps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("quit.app")
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
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let app = apps[row]
        let icon = app.icon ?? NSImage(named: NSImage.applicationIconName)
        icon?.size = NSSize(width: 18, height: 18)
        cell.imageView?.image = icon
        cell.textField?.stringValue = app.localizedName ?? app.bundleIdentifier ?? "未知程序"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}
