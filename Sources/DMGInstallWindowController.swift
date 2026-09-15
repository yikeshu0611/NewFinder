import AppKit

/// NewFinder’s own DMG installer window (avoids the fragile system Finder install sheet).
final class DMGInstallWindowController: NSWindowController {
    private(set) var mountURL: URL
    var mountedSourceDMG: URL? { mounted?.sourceDMG ?? pendingSourceDMG }
    private var mounted: DMGInstallSupport.MountedImage?
    private var pendingSourceDMG: URL?
    private var apps: [URL] = []
    private var selectedApp: URL?
    private var didDetach = false
    private var isBusy = false

    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var installButton: NSButton!
    private var installAndOpenButton: NSButton!
    private var statusLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var appsPopup: NSPopUpButton?

    /// Show a window immediately while the DMG mounts in the background.
    convenience init(loadingDMG dmgURL: URL) {
        self.init(
            mounted: nil,
            sourceDMG: dmgURL.standardizedFileURL,
            mountTitle: dmgURL.deletingPathExtension().lastPathComponent,
            apps: []
        )
        setBusy(true, status: "正在打开磁盘映像…", indeterminate: true)
    }

    convenience init(mounted: DMGInstallSupport.MountedImage) {
        let apps = DMGInstallSupport.findApps(in: mounted.mountURL)
        self.init(
            mounted: mounted,
            sourceDMG: mounted.sourceDMG,
            mountTitle: mounted.mountURL.lastPathComponent,
            apps: apps
        )
    }

    private init(
        mounted: DMGInstallSupport.MountedImage?,
        sourceDMG: URL?,
        mountTitle: String,
        apps: [URL]
    ) {
        self.mounted = mounted
        self.pendingSourceDMG = sourceDMG
        self.mountURL = mounted?.mountURL.standardizedFileURL
            ?? sourceDMG?.standardizedFileURL
            ?? URL(fileURLWithPath: "/")
        self.apps = apps
        self.selectedApp = apps.first

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = mountTitle
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureUI(titleText: "安装 \(mountTitle)")
        if mounted != nil {
            refreshSelectionUI()
            setBusy(false, status: "", indeterminate: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called after background `hdiutil attach` succeeds.
    func finishMounting(mounted: DMGInstallSupport.MountedImage) {
        self.mounted = mounted
        self.mountURL = mounted.mountURL.standardizedFileURL
        self.apps = DMGInstallSupport.findApps(in: mounted.mountURL)
        self.selectedApp = apps.first
        window?.title = mounted.mountURL.lastPathComponent
        rebuildAppsPopupIfNeeded()
        refreshSelectionUI()
        setBusy(false, status: "", indeterminate: false)
    }

    func showMountError(_ error: Error) {
        setBusy(false, status: error.localizedDescription, indeterminate: false)
        statusLabel.textColor = .systemRed
        installButton.isEnabled = false
        installAndOpenButton.isEnabled = false
    }

    private func configureUI(titleText: String) {
        guard let window, let content = window.contentView else { return }

        let root = NSView(frame: content.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.autoresizingMask = [.width, .height]
        content.addSubview(root)

        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        title.tag = 9001

        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)

        let arrow = NSImageView()
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        arrow.contentTintColor = .secondaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false

        let appsIcon = NSImageView()
        appsIcon.image = NSWorkspace.shared.icon(forFile: "/Applications")
        appsIcon.image?.size = NSSize(width: 96, height: 96)
        appsIcon.imageScaling = .scaleProportionallyUpOrDown
        appsIcon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel = NSTextField(labelWithString: "准备中…")
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel = NSTextField(labelWithString: "安装到「应用程序」后会自动推出磁盘映像")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        installButton = NSButton(title: "安装", target: self, action: #selector(installClicked))
        installButton.bezelStyle = .rounded
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.isEnabled = false

        installAndOpenButton = NSButton(title: "安装并打开", target: self, action: #selector(installAndOpenClicked))
        installAndOpenButton.bezelStyle = .rounded
        installAndOpenButton.keyEquivalent = "\r"
        installAndOpenButton.translatesAutoresizingMaskIntoConstraints = false
        installAndOpenButton.isEnabled = false

        root.addSubview(title)
        root.addSubview(iconView)
        root.addSubview(arrow)
        root.addSubview(appsIcon)
        root.addSubview(nameLabel)
        root.addSubview(hintLabel)
        root.addSubview(statusLabel)
        root.addSubview(progressBar)
        root.addSubview(installButton)
        root.addSubview(installAndOpenButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            iconView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor, constant: -90),
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),

            arrow.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            arrow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 28),
            arrow.heightAnchor.constraint(equalToConstant: 28),

            appsIcon.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            appsIcon.centerXAnchor.constraint(equalTo: root.centerXAnchor, constant: 90),
            appsIcon.widthAnchor.constraint(equalToConstant: 96),
            appsIcon.heightAnchor.constraint(equalToConstant: 96),

            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            nameLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            hintLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 48),
            progressBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48),
            progressBar.heightAnchor.constraint(equalToConstant: 12),

            installButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            installButton.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -8),

            installAndOpenButton.bottomAnchor.constraint(equalTo: installButton.bottomAnchor),
            installAndOpenButton.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 8)
        ])

        rebuildAppsPopupIfNeeded()
    }

    private func rebuildAppsPopupIfNeeded() {
        appsPopup?.removeFromSuperview()
        appsPopup = nil
        guard apps.count > 1, let root = window?.contentView?.subviews.first else { return }

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        for app in apps {
            popup.addItem(withTitle: app.deletingPathExtension().lastPathComponent)
        }
        popup.target = self
        popup.action = #selector(appSelectionChanged(_:))
        root.addSubview(popup)
        appsPopup = popup
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            popup.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    private func refreshSelectionUI() {
        guard let app = selectedApp else {
            iconView.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            nameLabel.stringValue = mounted == nil ? "准备中…" : "未找到可安装的应用程序"
            installButton.isEnabled = false
            installAndOpenButton.isEnabled = false
            return
        }
        // Icon lookup can hitch; keep UI responsive.
        nameLabel.stringValue = app.deletingPathExtension().lastPathComponent
        let path = app.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 96, height: 96)
            DispatchQueue.main.async {
                guard let self, self.selectedApp?.path == path else { return }
                self.iconView.image = icon
            }
        }
        installButton.isEnabled = !isBusy
        installAndOpenButton.isEnabled = !isBusy
    }

    private func setBusy(_ busy: Bool, status: String, indeterminate: Bool) {
        isBusy = busy
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        progressBar.isHidden = !busy
        if busy {
            if indeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            } else {
                progressBar.stopAnimation(nil)
                progressBar.isIndeterminate = false
                progressBar.doubleValue = 0
            }
        } else {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = 0
        }
        let canInstall = !busy && selectedApp != nil && mounted != nil
        installButton.isEnabled = canInstall
        installAndOpenButton.isEnabled = canInstall
        appsPopup?.isEnabled = !busy
    }

    private func updateProgress(_ fraction: Double, status: String) {
        progressBar.isHidden = false
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        // Always determinate — never the bouncing indeterminate bar.
        if progressBar.isIndeterminate {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
        }
        progressBar.doubleValue = min(1, max(0, fraction))
    }

    @objc private func appSelectionChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard apps.indices.contains(index) else { return }
        selectedApp = apps[index]
        refreshSelectionUI()
    }

    @objc private func installClicked() {
        runInstall(openAfter: false)
    }

    @objc private func installAndOpenClicked() {
        runInstall(openAfter: true)
    }

    private func runInstall(openAfter: Bool) {
        guard let app = selectedApp, mounted != nil, !isBusy else { return }
        setBusy(true, status: "正在准备安装…", indeterminate: false)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let dest = try DMGInstallSupport.installApp(app, toApplications: true) { fraction, status in
                    DispatchQueue.main.async {
                        self?.updateProgress(fraction, status: status)
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.progressBar.doubleValue = 1
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = openAfter
                        ? "安装完成，正在推出磁盘映像…"
                        : "已安装到 \(dest.path)"
                    // Eject the DMG first, then open from /Applications — avoids apps
                    // detecting a still-mounted image / App Translocation path.
                    self.closeEjectThenOpen(dest, open: openAfter)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setBusy(false, status: error.localizedDescription, indeterminate: false)
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    private func closeEjectThenOpen(_ installedApp: URL, open: Bool) {
        let image = mounted
        mounted = nil
        didDetach = true
        window?.close()

        DispatchQueue.global(qos: .userInitiated).async {
            if let image {
                DMGInstallSupport.detach(image)
            }
            guard open else { return }
            // Give the volume a moment to disappear from the namespace.
            Thread.sleep(forTimeInterval: 0.25)
            DispatchQueue.main.async {
                DMGInstallSupport.openInstalledApp(installedApp)
            }
        }
    }

    private func closeAndEject() {
        let image = mounted
        window?.close()
        if let image {
            detachIfNeeded(image)
        }
    }

    private func detachIfNeeded(_ image: DMGInstallSupport.MountedImage) {
        guard !didDetach else { return }
        didDetach = true
        DispatchQueue.global(qos: .utility).async {
            DMGInstallSupport.detach(image)
        }
    }
}

extension DMGInstallWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let mounted {
            detachIfNeeded(mounted)
        }
        AppDelegate.shared.dmgInstallWindowDidClose(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't allow closing mid-copy; cancel isn't supported cleanly mid-ditto.
        !isBusy || mounted == nil
    }
}
