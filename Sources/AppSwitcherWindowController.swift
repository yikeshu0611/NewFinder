import AppKit

/// A floating launcher with two tabs:
///
/// 1. **正在运行** — the applications that are running right now. Clicking
///    one brings it to the front.
/// 2. **所有程序** — every application installed on the computer. Clicking
///    one launches it.
///
/// It is opened by double-tapping the Command key, and it is also reachable
/// from the status-bar menu, so the gesture is never the only way in.
///
/// The window is a plain `NSWindowController` singleton — it keeps itself
/// alive, exactly like `QuitAppsWindowController`.
final class AppSwitcherWindowController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate {

    static let shared = AppSwitcherWindowController()

    /// A running application, as listed in the first tab.
    private struct RunningApp {
        let application: NSRunningApplication
        let name: String
    }

    /// An installed application, as listed in the second tab.
    private struct InstalledApp {
        let info: OpenWithCatalog.AppInfo
        let name: String
        let icon: NSImage
        /// True when the app is currently running — shown as a small dot so
        /// the user can tell at a glance which apps are already open.
        let isRunning: Bool
    }

    private var runningApps: [RunningApp] = []
    private var installedApps: [InstalledApp] = []

    /// The installed apps after the search filter has been applied.
    private var filteredInstalledApps: [InstalledApp] = []

    private var tabView: NSTabView!
    private var runningTable: NSTableView!
    private var installedTable: NSTableView!
    private var searchField: NSSearchField!
    private var statusLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "启动程序"
        window.minSize = NSSize(width: 380, height: 340)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Showing

    /// Shows the window, refreshing both tabs.
    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Put the caret in the search field so the user can type right away.
        window?.makeFirstResponder(searchField)
    }

    /// Brings the already-open window to the front instead of reloading it.
    func toggle() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            show()
        }
    }

    // MARK: - Layout

    private func configureUI() {
        guard let content = window?.contentView else { return }

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder
        content.addSubview(tabView)

        let runningItem = NSTabViewItem(identifier: "running")
        runningItem.label = "正在运行"
        runningItem.view = makeRunningTab()
        tabView.addTabViewItem(runningItem)

        let installedItem = NSTabViewItem(identifier: "installed")
        installedItem.label = "所有程序"
        installedItem.view = makeInstalledTab()
        tabView.addTabViewItem(installedItem)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    /// The first tab — the applications that are running right now.
    private func makeRunningTab() -> NSView {
        let container = NSView()

        let hint = NSTextField(wrappingLabelWithString: "双击可以切换到该程序。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        runningTable = makeTable(identifier: "switcher.running")
        runningTable.doubleAction = #selector(activateRunningApp)
        runningTable.target = self

        let scroll = makeScrollView(document: runningTable)

        container.addSubview(hint)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// The second tab — every application installed on the computer.
    private func makeInstalledTab() -> NSView {
        let container = NSView()

        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索程序"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)

        installedTable = makeTable(identifier: "switcher.installed")
        installedTable.doubleAction = #selector(launchInstalledApp)
        installedTable.target = self

        let scroll = makeScrollView(document: installedTable)

        container.addSubview(searchField)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeTable(identifier: String) -> NSTableView {
        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 26
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = "程序"
        table.addTableColumn(column)
        return table
    }

    private func makeScrollView(document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.documentView = document
        return scroll
    }

    // MARK: - Data

    private func reload() {
        reloadRunningApps()
        reloadInstalledApps()
        updateStatus()
    }

    private func reloadRunningApps() {
        let selfID = Bundle.main.bundleIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && !app.isTerminated
                    && app.bundleIdentifier != selfID
            }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
            .map { app in
                RunningApp(
                    application: app,
                    name: app.localizedName ?? app.bundleIdentifier ?? "未知程序"
                )
            }
        runningTable.reloadData()
    }

    private func reloadInstalledApps() {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )

        let all = OpenWithCatalog.allInstalledApps()
        installedApps = all
            .map { info in
                let name = OpenWithCatalog.disambiguatedName(for: info, among: all)
                return InstalledApp(
                    info: info,
                    name: name,
                    icon: NSWorkspace.shared.icon(forFile: info.url.path),
                    isRunning: info.bundleIdentifier.map { runningBundleIDs.contains($0) } ?? false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        applySearchFilter()
    }

    /// Applies the search field's text to the installed-apps list.
    private func applySearchFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredInstalledApps = installedApps
        } else {
            filteredInstalledApps = installedApps.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.info.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        installedTable.reloadData()
    }

    private func updateStatus() {
        let runningCount = runningApps.count
        let installedCount = filteredInstalledApps.count
        if installedCount == installedApps.count {
            statusLabel.stringValue = "\(runningCount) 个正在运行 · \(installedCount) 个已安装程序"
        } else {
            statusLabel.stringValue = "\(runningCount) 个正在运行 · 找到 \(installedCount) / \(installedApps.count) 个程序"
        }
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        applySearchFilter()
        updateStatus()
    }

    @objc private func searchChanged() {
        applySearchFilter()
        updateStatus()
    }

    // MARK: - Actions

    /// Brings the selected running application to the front.
    @objc private func activateRunningApp() {
        let row = runningTable.selectedRow
        guard runningApps.indices.contains(row) else { return }
        let app = runningApps[row].application
        app.activate(options: [.activateIgnoringOtherApps])
    }

    /// Launches the selected installed application.
    @objc private func launchInstalledApp() {
        let row = installedTable.selectedRow
        guard filteredInstalledApps.indices.contains(row) else { return }
        let app = filteredInstalledApps[row]

        // An app that is already running is brought to the front instead of
        // being launched a second time.
        if app.isRunning,
           let running = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == app.info.bundleIdentifier
           }) {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.info.url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Table data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === runningTable {
            return runningApps.count
        }
        if tableView === installedTable {
            return filteredInstalledApps.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableView === runningTable ? "switcher.running" : "switcher.installed"
        let id = NSUserInterfaceItemIdentifier(identifier)
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

        if tableView === runningTable {
            guard runningApps.indices.contains(row) else { return nil }
            let app = runningApps[row]
            cell.imageView?.image = sizedIcon(app.application.icon)
            cell.textField?.stringValue = app.name
        } else {
            guard filteredInstalledApps.indices.contains(row) else { return nil }
            let app = filteredInstalledApps[row]
            cell.imageView?.image = sizedIcon(app.icon)
            cell.textField?.stringValue = app.name
        }
        return cell
    }

    /// A copy of the icon at the size the row uses.
    ///
    /// The icon objects that `NSWorkspace` hands out are shared, so their
    /// size must not be changed in place.
    private func sizedIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return NSImage(named: NSImage.applicationIconName) }
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let tableView = notification.object as? NSTableView, tableView === runningTable {
            // Selecting a running app clears the selection in the other tab,
            // so the two tabs never look out of sync.
            installedTable.deselectAll(nil)
        } else if let tableView = notification.object as? NSTableView, tableView === installedTable {
            runningTable.deselectAll(nil)
        }
    }
}
