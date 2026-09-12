import AppKit
import Darwin

/// Embeddable Activity Monitor content (hosted as a browser tab, not a separate window).
final class ActivityMonitorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    var onSummaryChange: ((String) -> Void)?

    private struct ProcessRow {
        let pid: pid_t
        let name: String
        let path: String
        let user: String
        let cpuPercent: Double
        let memoryBytes: UInt64
        let threadCount: Int32
    }

    private enum SortKey: String {
        case name, cpu, memory, pid, user, threads
    }

    private var allRows: [ProcessRow] = []
    private var filteredRows: [ProcessRow] = []
    private var previousCPU: [pid_t: (total: UInt64, at: CFAbsoluteTime)] = [:]
    private var sortKey: SortKey = .cpu
    private var sortAscending = false
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var isActive = false

    private var tableView: NSTableView!
    private var searchField: NSSearchField!
    private var quitButton: NSButton!
    private var forceQuitButton: NSButton!
    private var summaryLabel: NSTextField!
    private var emptyLabel: NSTextField!

    override func loadView() {
        view = NSView()
        configure()
    }

    deinit {
        stopRefreshing()
    }

    func activate() {
        isActive = true
        startRefreshing()
        refreshNow()
    }

    func deactivate() {
        isActive = false
        stopRefreshing()
    }

    // MARK: - UI

    private func configure() {
        let content = view

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        searchField = NSSearchField()
        searchField.placeholderString = "搜索进程名称 / PID / 用户"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 12)
        searchField.controlSize = .small
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small

        quitButton = NSButton(title: "结束进程", target: self, action: #selector(quitSelected))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.isEnabled = false

        forceQuitButton = NSButton(title: "强制退出", target: self, action: #selector(forceQuitSelected))
        forceQuitButton.bezelStyle = .rounded
        forceQuitButton.controlSize = .small
        forceQuitButton.isEnabled = false

        toolbar.addArrangedSubview(searchField)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(refreshButton)
        toolbar.addArrangedSubview(quitButton)
        toolbar.addArrangedSubview(forceQuitButton)

        tableView = NSTableView()
        tableView.style = .plain
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.menu = makeContextMenu()

        addColumn(id: SortKey.name.rawValue, title: "进程名称", width: 220, min: 120)
        addColumn(id: SortKey.cpu.rawValue, title: "% CPU", width: 72, min: 56)
        addColumn(id: SortKey.memory.rawValue, title: "内存", width: 90, min: 70)
        addColumn(id: SortKey.threads.rawValue, title: "线程", width: 56, min: 48)
        addColumn(id: SortKey.pid.rawValue, title: "PID", width: 72, min: 56)
        addColumn(id: SortKey.user.rawValue, title: "用户", width: 100, min: 70)

        if let cpuColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(SortKey.cpu.rawValue)) {
            let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            tableView.setIndicatorImage(chevron, in: cpuColumn)
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "没有匹配的进程")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])

        // Kept for filter-time rewrites; surfaced to the browser status bar via onSummaryChange.
        summaryLabel.isHidden = true
    }

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.resizingMask = [.userResizingMask, .autoresizingMask]
        tableView.addTableColumn(column)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "结束进程", action: #selector(quitSelected), keyEquivalent: "")
        menu.addItem(withTitle: "强制退出", action: #selector(forceQuitSelected), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealSelected), keyEquivalent: "")
        menu.addItem(withTitle: "拷贝 PID", action: #selector(copySelectedPIDs), keyEquivalent: "")
        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    // MARK: - Refresh

    private func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func refreshClicked() {
        refreshNow()
    }

    private func refreshNow() {
        guard isActive, !isRefreshing else { return }
        isRefreshing = true
        let previous = previousCPU
        let sortKey = self.sortKey
        let ascending = self.sortAscending
        let filter = searchField.stringValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sampled = Self.sampleProcesses(previousCPU: previous)
            DispatchQueue.main.async {
                guard let self, self.isActive else {
                    self?.isRefreshing = false
                    return
                }
                self.previousCPU = sampled.nextCPU
                self.allRows = sampled.rows
                self.applyFilterAndSort(filter: filter, sortKey: sortKey, ascending: ascending, preserveSelection: true)
                self.updateSummary(system: sampled.system)
                self.isRefreshing = false
            }
        }
    }

    private struct SystemStats {
        let processCount: Int
        let cpuPercent: Double
        let memoryUsedBytes: UInt64
        let memoryTotalBytes: UInt64
    }

    private struct SampleResult {
        let rows: [ProcessRow]
        let nextCPU: [pid_t: (total: UInt64, at: CFAbsoluteTime)]
        let system: SystemStats
    }

    private static func sampleProcesses(previousCPU: [pid_t: (total: UInt64, at: CFAbsoluteTime)]) -> SampleResult {
        let now = CFAbsoluteTimeGetCurrent()
        var nextCPU: [pid_t: (total: UInt64, at: CFAbsoluteTime)] = [:]
        var rows: [ProcessRow] = []

        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else {
            return SampleResult(
                rows: [],
                nextCPU: [:],
                system: SystemStats(processCount: 0, cpuPercent: 0, memoryUsedBytes: 0, memoryTotalBytes: 0)
            )
        }

        let capacity = Int(bytesNeeded) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let filledBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let filledCount = max(0, Int(filledBytes) / MemoryLayout<pid_t>.size)

        var totalCPU: Double = 0
        var totalResident: UInt64 = 0

        for index in 0..<filledCount {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }

            var bsd = proc_bsdshortinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
            _ = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, bsdSize)

            let cpuTotal = task.pti_total_user &+ task.pti_total_system
            nextCPU[pid] = (cpuTotal, now)

            var cpuPercent = 0.0
            if let prev = previousCPU[pid] {
                let dt = now - prev.at
                if dt > 0.05 {
                    let delta = Double(cpuTotal &- prev.total)
                    cpuPercent = max(0, (delta / dt) / 1_000_000_000.0 * 100.0)
                }
            }

            let name = processName(pid: pid, fallback: bsd)
            let path = processPath(pid: pid)
            let user = username(uid: bsd.pbsi_uid)
            let memory = UInt64(task.pti_resident_size)

            totalCPU += cpuPercent
            totalResident += memory

            rows.append(ProcessRow(
                pid: pid,
                name: name,
                path: path,
                user: user,
                cpuPercent: cpuPercent,
                memoryBytes: memory,
                threadCount: task.pti_threadnum
            ))
        }

        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        let system = SystemStats(
            processCount: rows.count,
            cpuPercent: totalCPU,
            memoryUsedBytes: totalResident,
            memoryTotalBytes: memoryTotal
        )
        return SampleResult(rows: rows, nextCPU: nextCPU, system: system)
    }

    private static func processName(pid: pid_t, fallback: proc_bsdshortinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }
        let path = processPath(pid: pid)
        if !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return withUnsafePointer(to: fallback.pbsi_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
    }

    private static func processPath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func username(uid: uid_t) -> String {
        if let pw = getpwuid(uid) {
            return String(cString: pw.pointee.pw_name)
        }
        return String(uid)
    }

    private func applyFilterAndSort(filter: String, sortKey: SortKey, ascending: Bool, preserveSelection: Bool) {
        let selectedPIDs = preserveSelection
            ? Set(tableView.selectedRowIndexes.compactMap { index -> pid_t? in
                guard filteredRows.indices.contains(index) else { return nil }
                return filteredRows[index].pid
            })
            : Set<pid_t>()

        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows = allRows
        if !query.isEmpty {
            rows = rows.filter { row in
                row.name.lowercased().contains(query)
                    || row.user.lowercased().contains(query)
                    || String(row.pid).contains(query)
                    || row.path.lowercased().contains(query)
            }
        }

        rows.sort { lhs, rhs in
            let result: ComparisonResult
            switch sortKey {
            case .name:
                result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .cpu:
                result = lhs.cpuPercent == rhs.cpuPercent ? .orderedSame
                    : (lhs.cpuPercent < rhs.cpuPercent ? .orderedAscending : .orderedDescending)
            case .memory:
                result = lhs.memoryBytes == rhs.memoryBytes ? .orderedSame
                    : (lhs.memoryBytes < rhs.memoryBytes ? .orderedAscending : .orderedDescending)
            case .pid:
                result = lhs.pid == rhs.pid ? .orderedSame
                    : (lhs.pid < rhs.pid ? .orderedAscending : .orderedDescending)
            case .user:
                result = lhs.user.localizedCaseInsensitiveCompare(rhs.user)
            case .threads:
                result = lhs.threadCount == rhs.threadCount ? .orderedSame
                    : (lhs.threadCount < rhs.threadCount ? .orderedAscending : .orderedDescending)
            }
            if result == .orderedSame {
                return ascending ? lhs.pid < rhs.pid : lhs.pid > rhs.pid
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        filteredRows = rows
        tableView.reloadData()
        emptyLabel.isHidden = !filteredRows.isEmpty

        if !selectedPIDs.isEmpty {
            var indexes = IndexSet()
            for (index, row) in filteredRows.enumerated() where selectedPIDs.contains(row.pid) {
                indexes.insert(index)
            }
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        updateActionButtons()
    }

    private func updateSummary(system: SystemStats) {
        let memUsed = Self.formatBytes(system.memoryUsedBytes)
        let memTotal = Self.formatBytes(system.memoryTotalBytes)
        let cpuText = String(
            format: "%.0f%%",
            min(system.cpuPercent, Double(ProcessInfo.processInfo.activeProcessorCount) * 100)
        )
        let text =
            "进程 \(system.processCount) · 显示 \(filteredRows.count) · CPU \(cpuText) · 内存 \(memUsed) / \(memTotal)"
        summaryLabel.stringValue = text
        onSummaryChange?(text)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private static func formatCPU(_ value: Double) -> String {
        if value < 0.05 { return "0.0" }
        if value < 10 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }

    // MARK: - Actions

    private func selectedRows() -> [ProcessRow] {
        tableView.selectedRowIndexes.compactMap { index in
            filteredRows.indices.contains(index) ? filteredRows[index] : nil
        }
    }

    private func updateActionButtons() {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        quitButton.isEnabled = hasSelection
        forceQuitButton.isEnabled = hasSelection
    }

    @objc private func rowDoubleClicked() {
        // Header clicks report clickedRow == -1; ignore so sort double-clicks
        // do not fire “结束进程” against the current selection.
        guard tableView.clickedRow >= 0 else { return }
        quitSelected()
    }

    @objc private func quitSelected() {
        terminateSelected(force: false)
    }

    @objc private func forceQuitSelected() {
        terminateSelected(force: true)
    }

    private func terminateSelected(force: Bool) {
        let rows = selectedRows()
        guard !rows.isEmpty else { return }

        let names = rows.prefix(3).map(\.name).joined(separator: "、")
        let extra = rows.count > 3 ? " 等 \(rows.count) 个进程" : ""
        let alert = NSAlert()
        alert.messageText = force ? "强制退出选中的进程？" : "结束选中的进程？"
        alert.informativeText = "将处理：\(names)\(extra)\n未保存的更改可能会丢失。"
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: force ? "强制退出" : "结束进程")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for row in rows {
            if let app = NSRunningApplication(processIdentifier: row.pid) {
                if force {
                    app.forceTerminate()
                } else if !app.terminate() {
                    kill(row.pid, SIGTERM)
                }
            } else {
                kill(row.pid, force ? SIGKILL : SIGTERM)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshNow()
        }
    }

    @objc private func revealSelected() {
        let urls = selectedRows()
            .map(\.path)
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func copySelectedPIDs() {
        let text = selectedRows().map { String($0.pid) }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredRows.indices.contains(row), let column = tableColumn else { return nil }
        let item = filteredRows[row]
        let id = column.identifier.rawValue

        let cellID = NSUserInterfaceItemIdentifier("am.cell.\(id)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? {
                let cellView = NSTableCellView()
                cellView.identifier = cellID
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.font = .systemFont(ofSize: 12)
                field.lineBreakMode = .byTruncatingTail
                field.cell?.truncatesLastVisibleLine = true
                cellView.addSubview(field)
                cellView.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
                ])
                return cellView
            }()

        switch SortKey(rawValue: id) {
        case .name:
            cell.textField?.stringValue = item.name
            cell.textField?.alignment = .left
            cell.toolTip = item.path.isEmpty ? item.name : item.path
        case .cpu:
            cell.textField?.stringValue = Self.formatCPU(item.cpuPercent)
            cell.textField?.alignment = .right
            cell.toolTip = nil
        case .memory:
            cell.textField?.stringValue = Self.formatBytes(item.memoryBytes)
            cell.textField?.alignment = .right
            cell.toolTip = nil
        case .threads:
            cell.textField?.stringValue = String(item.threadCount)
            cell.textField?.alignment = .right
            cell.toolTip = nil
        case .pid:
            cell.textField?.stringValue = String(item.pid)
            cell.textField?.alignment = .right
            cell.toolTip = nil
        case .user:
            cell.textField?.stringValue = item.user
            cell.textField?.alignment = .left
            cell.toolTip = nil
        case .none:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let key = SortKey(rawValue: tableColumn.identifier.rawValue) else { return }
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = (key == .name || key == .user)
        }
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        let symbol = sortAscending ? "chevron.up" : "chevron.down"
        tableView.setIndicatorImage(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
            in: tableColumn
        )
        applyFilterAndSort(
            filter: searchField.stringValue,
            sortKey: sortKey,
            ascending: sortAscending,
            preserveSelection: true
        )
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilterAndSort(
            filter: searchField.stringValue,
            sortKey: sortKey,
            ascending: sortAscending,
            preserveSelection: true
        )
        let parts = summaryLabel.stringValue.components(separatedBy: " · ")
        if let prefix = parts.first {
            let rest = parts.dropFirst(2).joined(separator: " · ")
            let text = "\(prefix) · 显示 \(filteredRows.count)" + (rest.isEmpty ? "" : " · \(rest)")
            summaryLabel.stringValue = text
            onSummaryChange?(text)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        let canReveal = selectedRows().contains {
            !$0.path.isEmpty && FileManager.default.fileExists(atPath: $0.path)
        }
        for item in menu.items {
            switch item.action {
            case #selector(quitSelected), #selector(forceQuitSelected), #selector(copySelectedPIDs):
                item.isEnabled = hasSelection
            case #selector(revealSelected):
                item.isEnabled = canReveal
            default:
                break
            }
        }
    }
}

// MARK: - Darwin process info shims

private let PROC_ALL_PIDS: Int32 = 1
private let PROC_PIDTASKINFO: Int32 = 4
private let PROC_PIDT_SHORTBSDINFO: Int32 = 13

private struct proc_taskinfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
}

private struct proc_bsdshortinfo {
    var pbsi_pid: UInt32 = 0
    var pbsi_ppid: UInt32 = 0
    var pbsi_pgid: UInt32 = 0
    var pbsi_status: UInt32 = 0
    var pbsi_comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var pbsi_flags: UInt32 = 0
    var pbsi_uid: uid_t = 0
    var pbsi_gid: gid_t = 0
    var pbsi_ruid: uid_t = 0
    var pbsi_rgid: gid_t = 0
    var pbsi_svuid: uid_t = 0
    var pbsi_svgid: gid_t = 0
    var pbsi_rfu: UInt32 = 0
}
