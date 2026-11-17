import AppKit

/// 统一的更新流程：30 天自动检查 + 手动检查共用。
/// 下载 dmg → 挂载 → 覆盖安装到 /Applications → 重启到新版。
final class AutoUpdateController: NSObject {
    static let shared = AutoUpdateController()

    private var window: NSWindow?
    private var titleLabel: NSTextField?
    private var versionInfoLabel: NSTextField?
    private var notesView: NSTextView?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var installButton: NSButton?
    private var laterButton: NSButton?
    private var autoCheckBox: NSButton?
    private var pendingRelease: UpdateChecker.ReleaseInfo?
    private var isBusy = false
    private var downloadTask: URLSessionTask?

    private override init() {}

    // MARK: - 入口

    /// 启动后延迟调用：只有满 30 天才真正发请求。
    func scheduleAutoCheckIfNeeded() {
        guard AppSettings.shared.shouldAutoCheckUpdates() else { return }
        // 等主窗口出来、工作空闲了再查，不挡启动。
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.check(manual: false)
        }
    }

    /// 手动检查（菜单、状态栏版本号、设置页）共用此入口。
    func check(manual: Bool) {
        UpdateChecker.fetchLatest { [weak self] result in
            guard let self else { return }
            AppSettings.shared.markUpdateCheckedNow()
            switch result {
            case .failure(let error):
                if manual {
                    let alert = NSAlert()
                    alert.messageText = "检查更新失败"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            case .success(let release):
                let current = UpdateChecker.currentVersion
                if UpdateChecker.isVersion(release.version, newerThan: current) {
                    self.showWindow(for: release)
                } else if manual {
                    let alert = NSAlert()
                    alert.messageText = "已是最新版本"
                    alert.informativeText = "当前版本 \(current)"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - 窗口

    private func showWindow(for release: UpdateChecker.ReleaseInfo) {
        pendingRelease = release
        isBusy = false
        downloadTask = nil

        if let window {
            updateWindowContent(release)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "软件更新"
        win.isReleasedWhenClosed = false
        win.center()

        guard let content = win.contentView else { return }
        let root = NSView(frame: content.bounds)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(root)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let version = NSTextField(labelWithString: "")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.translatesAutoresizingMaskIntoConstraints = false
        versionInfoLabel = version

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.backgroundColor = .textBackgroundColor
        scroll.documentView = textView

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false

        let install = NSButton(title: "下载并安装", target: self, action: #selector(installClicked))
        install.bezelStyle = .rounded
        install.keyEquivalent = "\r"
        install.translatesAutoresizingMaskIntoConstraints = false

        let later = NSButton(title: "稍后", target: self, action: #selector(laterClicked))
        later.bezelStyle = .rounded
        later.translatesAutoresizingMaskIntoConstraints = false

        let auto = NSButton(
            checkboxWithTitle: "每 30 天自动检查更新",
            target: self,
            action: #selector(autoCheckToggled(_:))
        )
        auto.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(version)
        root.addSubview(scroll)
        root.addSubview(status)
        root.addSubview(bar)
        root.addSubview(install)
        root.addSubview(later)
        root.addSubview(auto)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            version.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            version.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            version.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 170),

            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            bar.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            bar.heightAnchor.constraint(equalToConstant: 10),

            auto.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            auto.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),

            later.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            later.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            later.widthAnchor.constraint(equalToConstant: 90),

            install.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            install.trailingAnchor.constraint(equalTo: later.leadingAnchor, constant: -10),
            install.widthAnchor.constraint(equalToConstant: 110),
        ])

        self.window = win
        titleLabel = title
        notesView = textView
        progressBar = bar
        statusLabel = status
        installButton = install
        laterButton = later
        autoCheckBox = auto
        win.delegate = self

        updateWindowContent(release)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateWindowContent(_ release: UpdateChecker.ReleaseInfo) {
        let current = UpdateChecker.currentVersion
        titleLabel?.stringValue = "发现新版本 \(release.version)"
        versionInfoLabel?.stringValue = "当前 \(current) → 最新 \(release.version)"
        let notes = release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        notesView?.string = notes.isEmpty ? "本次更新暂无说明。" : String(notes.prefix(4000))
        statusLabel?.stringValue = "点击「下载并安装」自动完成更新并重启。"
        statusLabel?.textColor = .secondaryLabelColor
        progressBar?.isHidden = true
        progressBar?.doubleValue = 0
        installButton?.isEnabled = true
        installButton?.title = "下载并安装"
        autoCheckBox?.state = AppSettings.shared.autoCheckUpdates ? .on : .off
    }

    @objc private func autoCheckToggled(_ sender: NSButton) {
        AppSettings.shared.autoCheckUpdates = sender.state == .on
    }

    @objc private func laterClicked() {
        if isBusy {
            downloadTask?.cancel()
            setBusy(false, status: "已取消，可稍后重试。")
            return
        }
        window?.close()
    }

    @objc private func installClicked() {
        guard let release = pendingRelease, !isBusy else { return }
        setBusy(true, status: "正在下载 \(release.version)… 0%")
        progressBar?.isHidden = false
        progressBar?.doubleValue = 0

        downloadTask = UpdateChecker.download(
            release,
            progress: { [weak self] fraction in
                // 下载占 0…0.8
                self?.progressBar?.doubleValue = fraction * 0.8
                let pct = Int(round(fraction * 100))
                self?.statusLabel?.stringValue = "正在下载 \(release.version)… \(pct)%"
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    if (error as NSError).code == NSURLErrorCancelled {
                        self.setBusy(false, status: "已取消，可稍后重试。")
                    } else {
                        self.setBusy(false, status: "下载失败：\(error.localizedDescription)")
                        self.statusLabel?.textColor = .systemRed
                    }
                case .success(let dmgURL):
                    self.install(dmgURL: dmgURL, version: release.version)
                }
            }
        )
    }

    private func install(dmgURL: URL, version: String) {
        statusLabel?.stringValue = "下载完成，正在安装…"
        statusLabel?.textColor = .secondaryLabelColor
        laterButton?.title = "取消"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let installed = try UpdateChecker.installDMGToApplications(dmgURL) { fraction, text in
                    DispatchQueue.main.async {
                        // 安装占 0.8…1
                        self?.progressBar?.doubleValue = 0.8 + fraction * 0.2
                        self?.statusLabel?.stringValue = "\(text) \(Int(round((0.8 + fraction * 0.2) * 100)))%"
                    }
                }
                try? FileManager.default.removeItem(at: dmgURL)
                DispatchQueue.main.async {
                    self?.progressBar?.doubleValue = 1
                    self?.statusLabel?.stringValue = "安装完成，正在重启到 \(version)…"
                    self?.statusLabel?.textColor = .systemGreen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        UpdateChecker.relaunchInstalledApp(at: installed)
                        if Bundle.main.bundleURL.standardizedFileURL.path.contains("/build/") {
                            // 开发包不自动杀进程，关窗即可。
                            self?.setBusy(false, status: "已安装到 /Applications，请手动重启体验新版。")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setBusy(false, status: "安装失败：\(error.localizedDescription)")
                    self?.statusLabel?.textColor = .systemRed
                }
            }
        }
    }

    private func setBusy(_ busy: Bool, status: String) {
        isBusy = busy
        statusLabel?.stringValue = status
        if !busy { statusLabel?.textColor = .secondaryLabelColor }
        installButton?.isEnabled = !busy
        laterButton?.title = busy ? "取消" : "稍后"
        if !busy { downloadTask = nil }
    }
}

extension AutoUpdateController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if isBusy {
            downloadTask?.cancel()
            isBusy = false
        }
        // 保持单例可复用，只丢引用不销毁内容。
        window = nil
        titleLabel = nil
        versionInfoLabel = nil
        notesView = nil
        progressBar = nil
        statusLabel = nil
        installButton = nil
        laterButton = nil
        autoCheckBox = nil
        pendingRelease = nil
    }
}
