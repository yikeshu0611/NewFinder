import AppKit

/// The window that shows how far along a compression is.
///
/// It has its own progress bar, a list of the files that are being
/// compressed, and buttons to pause the work or to cancel it. Every row of
/// the list says how far along that file is, how big it was, how big it
/// became and how much smaller it got. It is styled like the rest of
/// NewFinder.
final class ArchiveProgressWindow: NSWindowController, NSWindowDelegate {
    /// The compression that is running. The window drives it.
    private let job: ArchiveJob

    /// The size of the window. It is wide enough for the name, the numbers
    /// and the size of the archive all on one line, and tall enough for a
    /// list of files.
    private static let contentSize = NSSize(width: 560, height: 380)

    private var progressBar: NFProgressBarView!
    private var percentLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var fileLabel: NSTextField!
    private var fileIcon: NSImageView!
    private var fileSizeLabel: NSTextField!
    private var pauseButton: NSButton!
    private var cancelButton: NSButton!
    private var spinner: NSProgressIndicator!

    /// The list of the files that are being compressed.
    private var fileTable: NSTableView!
    private var fileScrollView: NSScrollView!

    /// The state of each file, by name. The order is kept, so the list does
    /// not jump around while the work runs.
    private var fileStates: [String: ArchiveFileProgress] = [:]
    private var fileOrder: [String] = []

    /// The chrome at the top of the panel, drawn like the browser's tab bar.
    private var chromeView: ChromeStripView!
    /// The line between the chrome and the body.
    private var separator: NSBox!

    /// Set when the window is closed by hand, so the work is cancelled.
    private var closedByUser = false
    /// True once the work is done, so the window can close itself without
    /// stopping anything.
    private var isFinished = false

    init(job: ArchiveJob) {
        self.job = job

        // A panel that floats above the browser windows. It is a plain
        // titled window on purpose: a `utilityWindow` is squeezed down to
        // fit its content, which would hide the name and the numbers.
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "正在压缩"
        window.isReleasedWhenClosed = false
        // The size is fixed, so the panel does not shrink to the content.
        window.setContentSize(Self.contentSize)
        window.minSize = Self.contentSize
        window.maxSize = Self.contentSize
        // The chrome is drawn by the app, so the system title bar is hidden.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // It stays above NF and does not take the keyboard away from the
        // file list, so the user can keep working while it compresses.
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.hidesOnDeactivate = false
        // A floating panel resizes itself to fit its content, which would
        // squeeze the name and the numbers away, so it is left off.
        window.becomesKeyOnlyIfNeeded = true
        window.isMovableByWindowBackground = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureUI()
        updateAppearance()
        // The size is set again after the views are in place, because the
        // layout can shrink the window down to what it needs.
        window.setContentSize(Self.contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - UI

    private func configureUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        // The body follows the system appearance, so it is repainted when
        // the appearance changes.
        let body = AppearanceAwareView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.onAppearanceChange = { [weak self] in self?.updateAppearance() }
        content.addSubview(body)

        // The chrome at the top, like the browser's tab bar.
        chromeView = ChromeStripView()
        chromeView.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(chromeView)

        let titleLabel = NSTextField(labelWithString: "正在压缩")
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        chromeView.addSubview(titleLabel)

        // The first row holds the name of the file, how much has been
        // handled, the percentage and the size of the archive.
        fileIcon = NSImageView()
        fileIcon.imageScaling = .scaleProportionallyDown
        fileIcon.translatesAutoresizingMaskIntoConstraints = false

        fileLabel = NSTextField(labelWithString: "")
        fileLabel.font = NFStyle.statusFont(size: 12, weight: .medium)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = NFStyle.statusFont(size: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        percentLabel = NSTextField(labelWithString: "0%")
        percentLabel.font = NFStyle.statusFont(size: 12, weight: .semibold)
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        fileSizeLabel = NSTextField(labelWithString: "")
        fileSizeLabel.font = NFStyle.statusFont(size: 12)
        fileSizeLabel.textColor = .secondaryLabelColor
        fileSizeLabel.alignment = .right
        fileSizeLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar = NFProgressBarView()
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // The buttons look like the ones in the browser's title bar.
        pauseButton = NFStyle.makeFlatButton(
            title: "暂停",
            target: self,
            action: #selector(pauseClicked)
        )
        pauseButton.contentTintColor = NFStyle.accent

        cancelButton = NFStyle.makeFlatButton(
            title: "取消",
            target: self,
            action: #selector(cancelClicked)
        )
        cancelButton.contentTintColor = .secondaryLabelColor

        // The list of the files that are being compressed.
        fileTable = NSTableView()
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.rowHeight = 22
        fileTable.allowsEmptySelection = true
        fileTable.selectionHighlightStyle = .none
        // The plain style keeps the headings visible; the inset style hides
        // them behind the rows.
        fileTable.style = .plain
        // The columns keep the widths they are given, so the numbers stay
        // in the same place.
        fileTable.columnAutoresizingStyle = .noColumnAutoresizing

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "文件"
        nameColumn.width = 176
        nameColumn.minWidth = 100
        fileTable.addTableColumn(nameColumn)

        let percentColumn = NSTableColumn(identifier: .init("percent"))
        percentColumn.title = "进度"
        percentColumn.width = 42
        percentColumn.minWidth = 38
        fileTable.addTableColumn(percentColumn)

        let originalColumn = NSTableColumn(identifier: .init("original"))
        originalColumn.title = "原始大小"
        originalColumn.width = 72
        originalColumn.minWidth = 60
        fileTable.addTableColumn(originalColumn)

        let compressedColumn = NSTableColumn(identifier: .init("compressed"))
        compressedColumn.title = "压缩后"
        compressedColumn.width = 72
        compressedColumn.minWidth = 60
        fileTable.addTableColumn(compressedColumn)

        let ratioColumn = NSTableColumn(identifier: .init("ratio"))
        ratioColumn.title = "压缩率"
        ratioColumn.width = 52
        ratioColumn.minWidth = 46
        fileTable.addTableColumn(ratioColumn)

        // A slim bar in the middle of each row, behind the name, so the
        // person can see how far along the file is.
        let barColumn = NSTableColumn(identifier: .init("bar"))
        barColumn.width = 76
        barColumn.minWidth = 56
        fileTable.addTableColumn(barColumn)

        // The headings sit above the list, so the numbers say what they
        // are. The bar column has no heading.
        let header = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 490, height: 20))
        fileTable.headerView = header
        // The bar is not a number, so it has no heading.
        barColumn.title = ""

        fileScrollView = NSScrollView()
        fileScrollView.documentView = fileTable
        fileScrollView.hasVerticalScroller = true
        fileScrollView.hasHorizontalScroller = false
        fileScrollView.autohidesScrollers = true
        fileScrollView.drawsBackground = false
        fileScrollView.borderType = .noBorder
        fileScrollView.translatesAutoresizingMaskIntoConstraints = false
        let views: [NSView] = [fileIcon, fileLabel, detailLabel, percentLabel, fileSizeLabel,
                               progressBar, spinner, fileScrollView, pauseButton, cancelButton]
        for view in views {
            body.addSubview(view)
        }

        separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(separator)

        // The name and the numbers keep their room, the percentage and the
        // size stay where they are.
        fileLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        percentLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        fileSizeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            // The body fills the window, and the window keeps its size.
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: Self.contentSize.width),

            chromeView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: body.topAnchor),
            chromeView.heightAnchor.constraint(equalToConstant: 34),

            // The title sits in the middle of the chrome.
            titleLabel.centerXAnchor.constraint(equalTo: chromeView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: chromeView.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            separator.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            // The first row: name · handled · percentage · size.
            spinner.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),

            fileIcon.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            fileIcon.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),
            fileIcon.widthAnchor.constraint(equalToConstant: 16),
            fileIcon.heightAnchor.constraint(equalToConstant: 16),

            fileLabel.leadingAnchor.constraint(equalTo: fileIcon.trailingAnchor, constant: 6),
            fileLabel.topAnchor.constraint(equalTo: chromeView.bottomAnchor, constant: 14),
            // The name always has room, so it is not squeezed away.
            fileLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            detailLabel.leadingAnchor.constraint(equalTo: fileLabel.trailingAnchor, constant: 12),
            detailLabel.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),

            percentLabel.leadingAnchor.constraint(equalTo: detailLabel.trailingAnchor, constant: 12),
            percentLabel.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 44),

            fileSizeLabel.leadingAnchor.constraint(equalTo: percentLabel.trailingAnchor, constant: 12),
            fileSizeLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            fileSizeLabel.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            progressBar.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 14),
            progressBar.heightAnchor.constraint(equalToConstant: 6),

            // The list of files sits under the bar.
            fileScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            fileScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            fileScrollView.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 14),
            fileScrollView.bottomAnchor.constraint(equalTo: pauseButton.topAnchor, constant: -10),

            pauseButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -14),
            pauseButton.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            cancelButton.bottomAnchor.constraint(equalTo: pauseButton.bottomAnchor)
        ])
    }

    /// Paints the chrome and the body in the colours of the browser.
    private func updateAppearance() {
        guard let content = window?.contentView else { return }
        let appearance = content.effectiveAppearance
        content.layer?.backgroundColor = NFStyle.bodyColor(for: appearance).cgColor
        (content.subviews.first as? AppearanceAwareView)?
            .layer?.backgroundColor = NFStyle.bodyColor(for: appearance).cgColor
        // The table is not there yet while the window is being built, and
        // the appearance can change at that moment.
        fileTable?.backgroundColor = .clear
        fileTable?.enclosingScrollView?.backgroundColor = .clear
        styleFileHeader()
    }

    /// Paints the headings of the file list in the quiet grey of NF, so
    /// they read as captions and not as data.
    private func styleFileHeader() {
        guard let header = fileTable?.headerView else { return }
        for column in fileTable.tableColumns {
            guard let cell = column.headerCell as? NSTableHeaderCell else { continue }
            cell.font = NFStyle.statusFont(size: 10)
            cell.textColor = .secondaryLabelColor
            // The name and the numbers line up with the text in the rows.
            cell.alignment = column.identifier.rawValue == "name" ? .left : .right
        }
        header.needsDisplay = true
    }

    // MARK: - Running

    /// Shows the window and starts following the job.
    func start() {
        // The app puts its own windows forward now and then, so the progress
        // window is registered to be put back in front.
        (NSApp.delegate as? AppDelegate)?.registerProgressWindow(self)
        // `orderFrontRegardless` puts it on screen without taking the
        // keyboard away from the browser window.
        window?.orderFrontRegardless()
        spinner.startAnimation(nil)
        fileLabel.stringValue = job.destinationName
        // The icon of the file, the same one the file list shows.
        fileIcon.image = NSWorkspace.shared.icon(forFile: job.destinationURL.path)
        update(progress: ArchiveProgress(fraction: 0, completedBytes: 0, totalBytes: job.totalBytes))
    }

    /// Brings the window back in front of the browser windows.
    ///
    /// The app brings its own windows forward now and then, so the progress
    /// window has to say that it belongs on top.
    func raiseToFront() {
        guard let window else { return }
        window.orderFrontRegardless()
    }

    /// Updates the bar and the numbers.
    func update(progress: ArchiveProgress) {
        progressBar.fraction = progress.fraction
        percentLabel.stringValue = "\(progress.percent)%"

        // How much of the source has been handled so far.
        let done = Self.formatBytes(progress.completedBytes)
        let total = Self.formatBytes(progress.totalBytes)
        detailLabel.stringValue = "\(done) / \(total)"

        // The size of the file on disk, which grows while the work runs.
        let written = Self.sizeOnDisk(of: job.destinationURL)
        fileSizeLabel.stringValue = written > 0 ? Self.formatBytes(written) : ""
    }

    /// Updates the row of one file.
    ///
    /// The list is only changed when the row is really different, so the
    /// window does not flicker while the work runs.
    func update(file: ArchiveFileProgress) {
        let isNew = fileStates[file.name] == nil
        fileStates[file.name] = file
        if isNew {
            fileOrder.append(file.name)
        }
        guard let index = fileOrder.firstIndex(of: file.name) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A file that was not there before changes the number of rows,
            // so the whole list is drawn again. Otherwise only the row that
            // changed is redrawn, which is quicker.
            let expectedRows = self.fileOrder.count + 1
            guard self.fileTable.numberOfRows == expectedRows else {
                self.fileTable.reloadData()
                return
            }
            // The row past the last file is the total, so it is refreshed
            // together with the file that changed.
            let rows = IndexSet(integersIn: index..<expectedRows)
            self.fileTable.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<6))
        }
    }

    /// Shows that the work is done.
    func finish() {
        isFinished = true
        spinner.stopAnimation(nil)
        progressBar.fraction = 1
        percentLabel.stringValue = "100%"
        pauseButton.isEnabled = false
        pauseButton.contentTintColor = .tertiaryLabelColor
        cancelButton.title = "完成"
        cancelButton.contentTintColor = NFStyle.accent
        cancelButton.keyEquivalent = "\r"

        // The window closes itself a moment later, so the result can be
        // seen before it goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.close()
        }
    }

    /// Shows that the work was cancelled.
    func cancel() {
        isFinished = true
        spinner.stopAnimation(nil)
        pauseButton.isEnabled = false
        pauseButton.contentTintColor = .tertiaryLabelColor
        cancelButton.isEnabled = false
    }

    // MARK: - Actions

    @objc private func pauseClicked() {
        job.togglePause()
        if job.isPaused {
            pauseButton.title = "继续"
            detailLabel.stringValue = "已暂停"
            spinner.stopAnimation(nil)
        } else {
            pauseButton.title = "暂停"
            spinner.startAnimation(nil)
        }
    }

    @objc private func cancelClicked() {
        if cancelButton.title == "完成" {
            close()
            return
        }
        job.cancel()
        cancel()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        closedByUser = true
        // A finished job has nothing left to stop, so it is only cancelled
        // while it is still running.
        if !isFinished {
            job.cancel()
        }
        // The window is not needed any more.
        (NSApp.delegate as? AppDelegate)?.progressWindowDidClose(self)
    }

    // MARK: - Helpers

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useGB, .useTB, .useMB, .useKB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// The size of the file on disk, if it is there yet.
    private static func sizeOnDisk(of url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(max(0, values?.fileSize ?? 0))
    }
}

// MARK: - The list of files

extension ArchiveProgressWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        // The last row is the total of all the files.
        fileOrder.isEmpty ? 0 : fileOrder.count + 1
    }

    /// The heading of a column.
    ///
    /// The headings are drawn like the rest of NF: small, in the grey of
    /// the secondary text.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // The row past the last file is the total.
        if row >= fileOrder.count {
            return totalCell(tableView: tableView, column: tableColumn)
        }

        guard row < fileOrder.count else { return nil }
        let state = fileStates[fileOrder[row]]

        let identifier = NSUserInterfaceItemIdentifier(rawValue: tableColumn?.identifier.rawValue ?? "name")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)

        guard let cell else { return nil }
        let textField = cell.textField

        switch tableColumn?.identifier.rawValue {
        case "name":
            textField?.stringValue = (state?.name as NSString?)?.lastPathComponent ?? ""
            textField?.font = NFStyle.statusFont(size: 11)
            textField?.textColor = .labelColor
        case "percent":
            textField?.stringValue = "\(state?.percent ?? 0)%"
            textField?.font = NFStyle.statusFont(size: 11)
            textField?.textColor = .secondaryLabelColor
            textField?.alignment = .right
        case "original":
            textField?.stringValue = state.map { Self.formatBytes($0.originalBytes) } ?? ""
            textField?.font = NFStyle.statusFont(size: 11)
            textField?.textColor = .secondaryLabelColor
            textField?.alignment = .right
        case "compressed":
            textField?.stringValue = state.map { Self.formatBytes($0.compressedBytes) } ?? ""
            textField?.font = NFStyle.statusFont(size: 11)
            textField?.textColor = .secondaryLabelColor
            textField?.alignment = .right
        case "ratio":
            if let state, state.originalBytes > 0 {
                let ratio = state.ratioPercent
                textField?.stringValue = ratio > 0 ? "\(ratio)%" : (ratio == 0 ? "0%" : "+\(-ratio)%")
                textField?.textColor = ratio > 0 ? .secondaryLabelColor : .systemOrange
            } else {
                textField?.stringValue = ""
                textField?.textColor = .secondaryLabelColor
            }
            textField?.font = NFStyle.statusFont(size: 11)
            textField?.alignment = .right
        case "bar":
            // The bar of the row, drawn in the colour of NF.
            let barCell = cell as? FileBarCellView
            barCell?.bar.fraction = state?.fraction ?? 0
        default:
            break
        }
        return cell
    }

    /// Makes the cell of the row that shows the total.
    ///
    /// The row sits below the files and adds up how big they were, how big
    /// they became and how well they compressed.
    private func totalCell(tableView: NSTableView, column: NSTableColumn?) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(
            rawValue: "total-" + (column?.identifier.rawValue ?? "name")
        )
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)

        guard let cell else { return nil }
        let textField = cell.textField
        textField?.font = NFStyle.statusFont(size: 11, weight: .semibold)
        textField?.textColor = .labelColor

        var original: UInt64 = 0
        var compressed: UInt64 = 0
        for name in fileOrder {
            guard let state = fileStates[name] else { continue }
            original += state.originalBytes
            compressed += state.compressedBytes
        }
        let ratio = original > 0
            ? Int(((Double(original) - Double(compressed)) * 100 / Double(original)).rounded())
            : 0

        switch column?.identifier.rawValue {
        case "name":
            textField?.stringValue = "共 \(fileOrder.count) 个文件"
            textField?.alignment = .left
        case "percent":
            textField?.stringValue = ""
            textField?.alignment = .right
        case "original":
            textField?.stringValue = Self.formatBytes(original)
            textField?.alignment = .right
        case "compressed":
            textField?.stringValue = Self.formatBytes(compressed)
            textField?.alignment = .right
        case "ratio":
            textField?.stringValue = "\(ratio)%"
            textField?.alignment = .right
        case "bar":
            let barCell = cell as? FileBarCellView
            barCell?.bar.fraction = 0
        default:
            break
        }
        return cell
    }

    /// Makes a cell that shows one piece of text.
    ///
    /// The bar column gets a cell of its own, because it holds a bar
    /// rather than text.
    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView? {
        if identifier.rawValue == "bar" {
            return FileBarCellView(identifier: identifier)
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

/// A cell that holds the bar of one file, so the person can see how far
/// along that file is.
private final class FileBarCellView: NSTableCellView {
    let bar = NFProgressBarView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4)
        ])
    }

    /// The cell that holds the bar of one file.
    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A view that tells its owner when the system appearance changes, so the
/// window can be repainted in the new colours.
private final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// A slim progress bar in the colour of NF, drawn like the one in Chrome.
private final class NFProgressBarView: NSView {
    /// How far along the work is, from 0 to 1.
    var fraction: Double = 0 {
        didSet {
            let clamped = min(1, max(0, fraction))
            if clamped != fraction {
                fraction = clamped
                return
            }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = bounds.height / 2

        // The track.
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        let trackColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25)
        trackColor.setFill()
        track.fill()

        // The part that is done.
        let done = CGFloat(fraction) * bounds.width
        if done > 0 {
            let fillRect = NSRect(x: 0, y: 0, width: max(done, radius * 2), height: bounds.height)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            NFStyle.accent.setFill()
            fill.fill()
        }
    }
}

/// The strip at the top of the progress window, drawn in the same colour as
/// the browser's tab bar.
private final class ChromeStripView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = NFStyle.chromeColor(for: effectiveAppearance).cgColor
    }
}
