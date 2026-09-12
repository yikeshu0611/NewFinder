import AppKit

/// Embeddable temperature monitor (browser tab).
final class TemperatureViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSummaryChange: ((String) -> Void)?

    private var readings: [TemperatureSensorReader.Reading] = []
    private var refreshTimer: Timer?
    private var isActive = false
    private var isRefreshing = false

    private var tableView: NSTableView!
    private var summaryStack: NSStackView!
    private var emptyLabel: NSTextField!
    private var thermalLabel: NSTextField!
    private var listColumnWidth: CGFloat { 380 }

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

    private func configure() {
        let content = view

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "硬件温度")
        title.font = .boldSystemFont(ofSize: 13)

        thermalLabel = NSTextField(labelWithString: "")
        thermalLabel.font = .systemFont(ofSize: 12)
        thermalLabel.textColor = .secondaryLabelColor

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small

        toolbar.addArrangedSubview(title)
        toolbar.addArrangedSubview(thermalLabel)
        toolbar.addArrangedSubview(NSView())
        toolbar.addArrangedSubview(refreshButton)

        summaryStack = NSStackView()
        summaryStack.orientation = .horizontal
        summaryStack.spacing = 6
        summaryStack.alignment = .centerY
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        summaryStack.distribution = .fillEqually

        tableView = NSTableView()
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnSelection = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = NSSize(width: 10, height: 2)
        tableView.delegate = self
        tableView.dataSource = self

        addColumn(id: "category", title: "部件", width: 68, min: 56, flexible: false)
        addColumn(id: "name", title: "传感器", width: 200, min: 120, flexible: false)
        addColumn(id: "temp", title: "温度", width: 88, min: 72, flexible: false)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.documentView = tableView

        emptyLabel = NSTextField(labelWithString: "未读取到温度传感器（部分机型或系统版本可能不暴露读数）")
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(summaryStack)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)

        let listLeading: CGFloat = 24

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: listLeading),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -listLeading),

            // Summary cards sit directly above the list, same width.
            summaryStack.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            summaryStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: listLeading),
            summaryStack.widthAnchor.constraint(equalToConstant: listColumnWidth),
            summaryStack.heightAnchor.constraint(equalToConstant: 38),

            scroll.topAnchor.constraint(equalTo: summaryStack.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: summaryStack.leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: listColumnWidth),
            scroll.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -listLeading),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat, flexible: Bool) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        column.maxWidth = flexible ? 400 : width + 20
        column.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
        column.headerCell.alignment = .left
        tableView.addTableColumn(column)
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sampled = TemperatureSensorReader.sample()
            let thermal = TemperatureSensorReader.thermalStateText()
            DispatchQueue.main.async {
                guard let self, self.isActive else {
                    self?.isRefreshing = false
                    return
                }
                self.readings = sampled
                self.thermalLabel.stringValue = "系统热状态：\(thermal)"
                self.reloadSummary()
                self.tableView.reloadData()
                self.emptyLabel.isHidden = !sampled.isEmpty
                let hottest = TemperatureSensorReader.maximum(of: sampled)
                if let hottest {
                    self.onSummaryChange?(
                        "传感器 \(sampled.count) · 最高 \(Self.formatTemp(hottest.celsius))（\(hottest.category.rawValue)）· 热状态 \(thermal)"
                    )
                } else {
                    self.onSummaryChange?("未读取到温度 · 热状态 \(thermal)")
                }
                self.isRefreshing = false
            }
        }
    }

    private func reloadSummary() {
        summaryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cards: [(String, Double?, Bool)] = [
            ("CPU", TemperatureSensorReader.summaryAverage(of: readings, category: .cpu)?.value, false),
            {
                let g = TemperatureSensorReader.summaryAverage(of: readings, category: .gpu)
                return ("GPU", g?.value, g?.estimated ?? false)
            }(),
            ("存储", TemperatureSensorReader.summaryAverage(of: readings, category: .ssd)?.value, false),
            ("电池", TemperatureSensorReader.summaryAverage(of: readings, category: .battery)?.value, false),
            ("最高", TemperatureSensorReader.maximum(of: readings)?.celsius, false)
        ]
        for (title, value, estimated) in cards {
            summaryStack.addArrangedSubview(makeSummaryCard(title: title, value: value, estimated: estimated))
        }
    }

    private func makeSummaryCard(title: String, value: Double?, estimated: Bool) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let titleText = estimated ? "\(title)≈" : title
        let titleLabel = NSTextField(labelWithString: titleText)
        titleLabel.font = .systemFont(ofSize: 9)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.toolTip = estimated ? "本机无独立 GPU 传感器，使用同芯片封装温度估算" : nil
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: value.map(Self.formatTemp) ?? "—")
        valueLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        if let value {
            valueLabel.textColor = Self.color(for: value)
        }
        if estimated {
            box.toolTip = "本机无独立 GPU 传感器，使用同芯片封装温度估算"
        }

        box.addSubview(titleLabel)
        box.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            titleLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -2),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 0),
            valueLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -2),
            valueLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3)
        ])
        return box
    }

    private static func formatTemp(_ value: Double) -> String {
        String(format: "%.1f℃", value)
    }

    private static func color(for value: Double) -> NSColor {
        if value >= 90 { return .systemRed }
        if value >= 75 { return .systemOrange }
        if value >= 60 { return .systemYellow }
        return .labelColor
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        readings.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard readings.indices.contains(row), let column = tableColumn else { return nil }
        let item = readings[row]
        let id = column.identifier.rawValue
        let cellID = NSUserInterfaceItemIdentifier("temp.cell.\(id)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
            ?? {
                let view = NSTableCellView()
                view.identifier = cellID
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.font = .systemFont(ofSize: 12)
                field.lineBreakMode = .byTruncatingTail
                view.addSubview(field)
                view.textField = field
                let trailingPad: CGFloat = (id == "temp") ? 14 : 8
                let leadingPad: CGFloat = (id == "category") ? 10 : 6
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leadingPad),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -trailingPad),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor)
                ])
                return view
            }()

        // Recreate padding if cell was pooled from another column id — set via constraints already at make time.
        switch id {
        case "category":
            cell.textField?.stringValue = item.category.rawValue
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .left
        case "name":
            cell.textField?.stringValue = item.name
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .left
        case "temp":
            cell.textField?.stringValue = Self.formatTemp(item.celsius)
            cell.textField?.textColor = Self.color(for: item.celsius)
            cell.textField?.alignment = .left
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }
}
