import AppKit

/// NewFinder’s own DMG installer window (avoids the fragile system Finder install sheet).
final class DMGInstallWindowController: NSWindowController {
    private(set) var mountURL: URL
    var mountedSourceDMG: URL? { mounted.sourceDMG }
    private var mounted: DMGInstallSupport.MountedImage
    private var apps: [URL]
    private var selectedApp: URL?
    private var didDetach = false

    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var installButton: NSButton!
    private var installAndOpenButton: NSButton!
    private var statusLabel: NSTextField!
    private var appsPopup: NSPopUpButton?

    init(mounted: DMGInstallSupport.MountedImage) {
        self.mounted = mounted
        self.mountURL = mounted.mountURL.standardizedFileURL
        self.apps = DMGInstallSupport.findApps(in: mounted.mountURL)
        self.selectedApp = apps.first

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = mounted.mountURL.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI() {
        guard let window, let content = window.contentView else { return }

        let root = NSView(frame: content.bounds)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.autoresizingMask = [.width, .height]
        content.addSubview(root)

        let title = NSTextField(labelWithString: "安装 \(mounted.mountURL.lastPathComponent)")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let arrow = NSImageView()
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        arrow.contentTintColor = .secondaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false

        let appsIcon = NSImageView()
        appsIcon.image = NSWorkspace.shared.icon(forFile: "/Applications")
        appsIcon.image?.size = NSSize(width: 96, height: 96)
        appsIcon.imageScaling = .scaleProportionallyUpOrDown
        appsIcon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel = NSTextField(labelWithString: "")
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

        installButton = NSButton(title: "安装", target: self, action: #selector(installClicked))
        installButton.bezelStyle = .rounded
        installButton.translatesAutoresizingMaskIntoConstraints = false

        installAndOpenButton = NSButton(title: "安装并打开", target: self, action: #selector(installAndOpenClicked))
        installAndOpenButton.bezelStyle = .rounded
        installAndOpenButton.keyEquivalent = "\r"
        installAndOpenButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(iconView)
        root.addSubview(arrow)
        root.addSubview(appsIcon)
        root.addSubview(nameLabel)
        root.addSubview(hintLabel)
        root.addSubview(statusLabel)
        root.addSubview(installButton)
        root.addSubview(installAndOpenButton)

        var constraints: [NSLayoutConstraint] = [
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

            installButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            installButton.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -8),

            installAndOpenButton.bottomAnchor.constraint(equalTo: installButton.bottomAnchor),
            installAndOpenButton.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 8)
        ]

        if apps.count > 1 {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            for app in apps {
                popup.addItem(withTitle: app.deletingPathExtension().lastPathComponent)
            }
            popup.target = self
            popup.action = #selector(appSelectionChanged(_:))
            root.addSubview(popup)
            appsPopup = popup
            constraints.append(contentsOf: [
                popup.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
                popup.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        refreshSelectionUI()
    }

    private func refreshSelectionUI() {
        guard let app = selectedApp else {
            iconView.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
            nameLabel.stringValue = "未找到可安装的应用程序"
            installButton.isEnabled = false
            installAndOpenButton.isEnabled = false
            return
        }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 96, height: 96)
        iconView.image = icon
        nameLabel.stringValue = app.deletingPathExtension().lastPathComponent
        installButton.isEnabled = true
        installAndOpenButton.isEnabled = true
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
        guard let app = selectedApp else { return }
        installButton.isEnabled = false
        installAndOpenButton.isEnabled = false
        statusLabel.stringValue = "正在安装…"
        statusLabel.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let dest = try DMGInstallSupport.installApp(app, toApplications: true)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusLabel.textColor = .systemGreen
                    self.statusLabel.stringValue = "已安装到 \(dest.path)"
                    if openAfter {
                        NSWorkspace.shared.open(dest)
                    }
                    // Always eject the disk image after a successful install.
                    self.closeAndEject()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusLabel.textColor = .systemRed
                    self?.statusLabel.stringValue = error.localizedDescription
                    self?.installButton.isEnabled = true
                    self?.installAndOpenButton.isEnabled = true
                }
            }
        }
    }

    private func closeAndEject() {
        let image = mounted
        window?.close()
        detachIfNeeded(image)
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
        detachIfNeeded(mounted)
        AppDelegate.shared.dmgInstallWindowDidClose(self)
    }
}
