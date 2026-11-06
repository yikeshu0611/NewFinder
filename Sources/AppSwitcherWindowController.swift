import AppKit

/// The shared parts of the two launcher windows.
///
/// Both windows list applications in a table, with an icon and a name, and
/// both act on a double click. Only the data and the action differ, so the
/// table plumbing lives here.
class AppListWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// The applications shown in the table.
    private(set) var items: [AppListItem] = []

    /// The table that shows the applications.
    var table: NSTableView!

    /// The status line under the table.
    var statusLabel: NSTextField!

    /// A row in the table.
    struct AppListItem {
        /// The name shown in the table.
        let name: String
        /// The icon shown in the table.
        let icon: NSImage
        /// The running application this row stands for, if any.
        let running: NSRunningApplication?
        /// The bundle on disk, for an installed application.
        let appURL: URL?
        /// The bundle identifier, for an installed application.
        let bundleIdentifier: String?
        /// True when the application is currently running.
        let isRunning: Bool
    }

    init(title: String, size: NSSize) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 380, height: 300)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func configureUI() {
        guard let content = window?.contentView else { return }

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 26
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(itemActivated)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.title = "程序"
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.documentView = table

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    // MARK: - Data

    /// Replaces the contents of the table.
    func setItems(_ newItems: [AppListItem], status: String) {
        items = newItems
        table.reloadData()
        statusLabel.stringValue = status
    }

    // MARK: - Actions

    /// Called when a row is double-clicked. Subclasses override it.
    @objc func itemActivated() {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return }
        activate(items[row])
    }

    /// Performs the action for a row. Subclasses override it.
    func activate(_ item: AppListItem) {}

    /// The selected item, if any.
    var selectedItem: AppListItem? {
        let row = table.selectedRow
        guard items.indices.contains(row) else { return nil }
        return items[row]
    }

    // MARK: - Table data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("applist.row")
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
        let item = items[row]
        cell.imageView?.image = Self.sizedIcon(item.icon)
        cell.textField?.stringValue = item.name
        return cell
    }

    /// A copy of the icon at the size the row uses.
    ///
    /// The icon objects that `NSWorkspace` hands out are shared, so their
    /// size must not be changed in place.
    static func sizedIcon(_ icon: NSImage?) -> NSImage? {
        guard let icon else { return NSImage(named: NSImage.applicationIconName) }
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: 18, height: 18)
        return copy
    }
}

/// Lists the applications that are running right now.
///
/// Opened by double-tapping the Command key. Clicking an application brings
/// it to the front.
final class RunningAppsWindowController: AppListWindowController {

    static let shared = RunningAppsWindowController()

    private init() {
        super.init(title: "正在运行的程序", size: NSSize(width: 460, height: 460))
    }

    /// Shows the window, refreshing the list.
    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func reload() {
        let selfID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && !app.isTerminated
                    && app.bundleIdentifier != selfID
            }
            .sorted {
                ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending
            }
            .map { app in
                AppListItem(
                    name: app.localizedName ?? app.bundleIdentifier ?? "未知程序",
                    icon: app.icon ?? NSImage(named: NSImage.applicationIconName)!,
                    running: app,
                    appURL: nil,
                    bundleIdentifier: app.bundleIdentifier,
                    isRunning: true
                )
            }

        let status = running.isEmpty ? "没有其他正在运行的程序" : "\(running.count) 个正在运行的程序"
        setItems(running, status: status)
    }

    override func activate(_ item: AppListItem) {
        item.running?.activate(options: [.activateIgnoringOtherApps])
    }
}

/// Lists every application installed on the computer.
///
/// Opened by triple-tapping the Command key. Clicking an application
/// launches it; an application that is already running is brought to the
/// front instead of being launched a second time.
final class InstalledAppsWindowController: AppListWindowController, NSSearchFieldDelegate {

    static let shared = InstalledAppsWindowController()

    /// Every installed application.
    private var installedApps: [AppListItem] = []

    /// The applications after the search filter has been applied.
    private var filteredApps: [AppListItem] = []

    private var searchField: NSSearchField!

    /// The search field is added lazily, because the base class builds the
    /// layout before this subclass is initialised.
    private var searchFieldAdded = false

    private init() {
        super.init(title: "所有程序", size: NSSize(width: 460, height: 520))
    }

    // MARK: - Layout

    private func configureSearchField() {
        guard let content = window?.contentView else { return }
        searchField = NSSearchField()
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "搜索程序"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        content.addSubview(searchField)

        guard let scroll = content.subviews.first(where: { $0 is NSScrollView }) else { return }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            searchField.bottomAnchor.constraint(equalTo: scroll.topAnchor, constant: -8)
        ])
    }

    // MARK: - Showing

    /// Shows the window, refreshing the list.
    func show() {
        configureSearchFieldIfNeeded()
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

    private func configureSearchFieldIfNeeded() {
        guard !searchFieldAdded else { return }
        searchFieldAdded = true
        configureSearchField()
    }

    // MARK: - Data

    private func reload() {
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )

        let all = OpenWithCatalog.allInstalledApps()
        installedApps = all
            .map { info in
                let name = OpenWithCatalog.disambiguatedName(for: info, among: all)
                return AppListItem(
                    name: name,
                    icon: NSWorkspace.shared.icon(forFile: info.url.path),
                    running: nil,
                    appURL: info.url,
                    bundleIdentifier: info.bundleIdentifier,
                    isRunning: info.bundleIdentifier.map { runningBundleIDs.contains($0) } ?? false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        applySearchFilter()
    }

    /// Applies the search field's text to the installed-apps list.
    private func applySearchFilter() {
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            filteredApps = installedApps
        } else {
            filteredApps = installedApps.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        updateStatus()
    }

    private func updateStatus() {
        let status: String
        if filteredApps.count == installedApps.count {
            status = "\(installedApps.count) 个已安装程序"
        } else {
            status = "找到 \(filteredApps.count) / \(installedApps.count) 个程序"
        }
        setItems(filteredApps, status: status)
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        applySearchFilter()
    }

    @objc private func searchChanged() {
        applySearchFilter()
    }

    // MARK: - Actions

    override func activate(_ item: AppListItem) {
        // An app that is already running is brought to the front instead of
        // being launched a second time.
        if item.isRunning, let bundleIdentifier = item.bundleIdentifier,
           let running = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == bundleIdentifier
           }) {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }

        guard let appURL = item.appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                NSAlert(error: error).runModal()
            }
        }
    }
}
