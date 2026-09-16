import AppKit
import CoreGraphics
import CoreServices
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showUINotification = Notification.Name("com.zhangjing.NewFinder.showUI")
    static let stealFinderNotification = Notification.Name("com.zhangjing.NewFinder.stealFinder")

    private var windowControllers: [BrowserWindowController] = []
    private var dmgInstallWindows: [DMGInstallWindowController] = []
    private var archiveWindows: [ArchiveWindowController] = []
    private var isRedirectingFinder = false
    private var lastFinderRedirectAt: Date?
    /// Ignore Finder activation storms right after we steal focus (policy / close-window churn).
    private var suppressFinderRedirectUntil: Date?
    /// While a DMG /Volumes window is in use — do not steal at all (prevents Finder↔NF ping-pong).
    private var leaveFinderAloneUntil: Date?
    private var finderWindowPollTimer: Timer?
    private var pendingRedirectWorkItem: DispatchWorkItem?
    private var didWarnFinderAutomation = false
    /// Last chrome-menu zoom title item (gear / status bar), for live % updates.
    private weak var chromeZoomMenuItem: NSMenuItem?

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always accessory: no Dock icon, no app name in the system menu bar.
        NSApp.setActivationPolicy(.accessory)

        // Agent-style apps can spawn many instances; keep a single UI process.
        if handOffToExistingUIInstanceIfNeeded() {
            NSApp.terminate(nil)
            return
        }

        NSApp.mainMenu = buildMainMenu()
        StatusBarController.shared.install()
        registerAsDefaultFolderViewer()
        applyLaunchAtLoginSetting()
        installWatchAgent()
        startFinderRedirectObserver()
        registerExternalShowObservers()

        let stealFinder = CommandLine.arguments.contains("--steal-finder")
        let revealFiles = Self.commandLineRevealURLs()
        let revealDir = Self.commandLineRevealDirectory()

        if !revealFiles.isEmpty {
            // Cold launch from Chrome "Show in Finder" (via WatchAgent --reveal).
            reveal(revealFiles)
            bringUIToFront()
        } else if let revealDir {
            openNewWindow(at: revealDir)
            bringUIToFront()
        } else if stealFinder {
            // Relaunched after Dock-Finder click: steal immediately, then ensure a window.
            scheduleFinderRedirect(settle: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.showFrontBrowserOrOpenDesktop()
                self.bringUIToFront()
            }
        } else {
            // `open` may also call applicationShouldHandleReopen — only create one window.
            showFrontBrowserOrOpenDesktop()
            bringUIToFront()
        }
    }

    /// Files to select after cold launch (`--reveal /path`).
    private static func commandLineRevealURLs() -> [URL] {
        let args = CommandLine.arguments
        var urls: [URL] = []
        var index = 0
        while index < args.count {
            if args[index] == "--reveal", index + 1 < args.count {
                urls.append(URL(fileURLWithPath: args[index + 1]).standardizedFileURL)
                index += 2
            } else {
                index += 1
            }
        }
        return urls
    }

    /// Folder only (`--reveal-dir /path`) when Finder had no selection.
    private static func commandLineRevealDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--reveal-dir"),
              index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1]).standardizedFileURL
    }

    /// If another UI instance is already running, ask it to show and exit this process.
    private func handOffToExistingUIInstanceIfNeeded() -> Bool {
        guard let existing = otherUIInstances().first else { return false }
        let center = DistributedNotificationCenter.default()
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        if CommandLine.arguments.contains("--steal-finder") {
            center.postNotificationName(Self.stealFinderNotification, object: bid, userInfo: nil, deliverImmediately: true)
        } else {
            center.postNotificationName(Self.showUINotification, object: bid, userInfo: nil, deliverImmediately: true)
        }
        existing.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    private func otherUIInstances() -> [NSRunningApplication] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != selfPID && !$0.isTerminated }
    }

    private func registerExternalShowObservers() {
        let center = DistributedNotificationCenter.default()
        let bid = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"
        center.addObserver(
            self,
            selector: #selector(handleExternalShowUI(_:)),
            name: Self.showUINotification,
            object: bid
        )
        center.addObserver(
            self,
            selector: #selector(handleExternalStealFinder(_:)),
            name: Self.stealFinderNotification,
            object: bid
        )
    }

    @objc private func handleExternalShowUI(_ notification: Notification) {
        userRequestedShowUI()
    }

    @objc private func handleExternalStealFinder(_ notification: Notification) {
        scheduleFinderRedirect(settle: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.userRequestedShowUI()
        }
    }

    private func showFrontBrowserOrOpenDesktop() {
        if let front = keyBrowser() {
            front.window?.makeKeyAndOrderFront(nil)
        } else {
            openNewWindow(
                at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            )
        }
    }

    /// Menu bar / reopen / external show — bring NF forward without closing a DMG installer.
    func userRequestedShowUI() {
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.0)
        pendingRedirectWorkItem?.cancel()
        pendingRedirectWorkItem = nil
        isRedirectingFinder = false
        showFrontBrowserOrOpenDesktop()
        bringUIToFront()
        // Keep any open DMG installer above the browser if present.
        dmgInstallWindows.last?.window?.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func openDiskImage(_ dmgURL: URL) -> Bool {
        let standardized = dmgURL.standardizedFileURL
        guard DMGInstallSupport.isDiskImage(standardized) else { return false }

        if let existing = dmgInstallWindows.first(where: { $0.mountedSourceDMG == standardized }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        // Show the installer immediately; mount on a background queue (hdiutil was blocking UI).
        beginLeavingFinderAlone()
        let controller = DMGInstallWindowController(loadingDMG: standardized)
        dmgInstallWindows.append(controller)
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.5)
        pendingRedirectWorkItem?.cancel()
        isRedirectingFinder = false
        controller.showWindow(nil)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let mounted = try DMGInstallSupport.attach(dmgURL: standardized)
                DispatchQueue.main.async {
                    guard let self,
                          self.dmgInstallWindows.contains(where: { $0 === controller }) else {
                        DMGInstallSupport.detach(mounted)
                        return
                    }
                    controller.finishMounting(mounted: mounted)
                }
            } catch {
                DispatchQueue.main.async {
                    controller.showMountError(error)
                }
            }
        }
        return true
    }

    /// Show installer for an already-mounted volume (e.g. after Finder opened a DMG).
    @discardableResult
    func presentInstallerForMountedVolume(_ volumeURL: URL) -> Bool {
        let volume = volumeURL.standardizedFileURL
        guard DMGInstallSupport.looksLikeInstallerVolume(volume) else { return false }
        if let existing = dmgInstallWindows.first(where: { $0.mountURL == volume }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        let mounted = DMGInstallSupport.MountedImage(
            device: volume.path,
            mountURL: volume,
            sourceDMG: nil
        )
        beginLeavingFinderAlone()
        presentDMGInstaller(mounted: mounted)
        return true
    }

    private func presentDMGInstaller(mounted: DMGInstallSupport.MountedImage) {
        let controller = DMGInstallWindowController(mounted: mounted)
        dmgInstallWindows.append(controller)
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.5)
        pendingRedirectWorkItem?.cancel()
        isRedirectingFinder = false
        controller.showWindow(nil)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func dmgInstallWindowDidClose(_ controller: DMGInstallWindowController) {
        dmgInstallWindows.removeAll { $0 === controller }
    }

    /// Keep a background watch process so Dock-Finder still routes to NewFinder after Quit.
    private func installWatchAgent() {
        let label = "com.zhangjing.NewFinder.Watch"
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistURL = agents.appendingPathComponent("\(label).plist")
        // Separate helper app → different bundle ID, so `open NewFinder` is not blocked.
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NewFinderWatch.app/Contents/MacOS/NewFinderWatch")
            .path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return }

        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive"
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return
        }

        // Load or kick the agent (ignore errors if already loaded).
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", plistURL.path]
        unload.standardOutput = FileHandle.nullDevice
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()

        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["load", plistURL.path]
        load.standardOutput = FileHandle.nullDevice
        load.standardError = FileHandle.nullDevice
        try? load.run()
        load.waitUntilExit()
    }

    /// Stay alive with no windows so Finder interception keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Accessory apps sometimes report `flag == false` even with a visible window.
        userRequestedShowUI()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openURLs(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openURLs(filenames.map { URL(fileURLWithPath: $0) })
        NSApp.reply(toOpenOrPrint: .success)
    }

    /// Open folders in NewFinder; reveal files by showing their parent and selecting them.
    func openURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let standardized = urls.map { $0.standardizedFileURL }

        var directories: [URL] = []
        var files: [URL] = []
        for url in standardized {
            if DMGInstallSupport.isDiskImage(url), !((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) {
                _ = openDiskImage(url)
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isPackage == true {
                NSWorkspace.shared.open(url)
                continue
            }
            if values?.isDirectory == true {
                directories.append(url)
            } else {
                files.append(url)
            }
        }

        for dir in directories {
            openDirectory(dir)
        }
        if !files.isEmpty {
            reveal(files)
        }

        bringUIToFront()
    }

    /// Show items inside NewFinder (replaces system Finder reveal).
    func reveal(_ urls: [URL]) {
        guard let first = urls.first?.standardizedFileURL else { return }
        let values = try? first.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true, urls.count == 1 {
            openDirectory(first)
            bringUIToFront()
            return
        }

        let parent = first.deletingLastPathComponent()
        let select = urls.map(\.standardizedFileURL)

        // Set pending selection BEFORE navigating so async reload still selects the file.
        if let front = keyBrowser() {
            front.selectAfterNavigate(select)
            front.openDirectoryInTab(parent)
        } else {
            openNewWindow(at: parent, select: select)
        }
        bringUIToFront()
    }

    @objc func newWindow(_ sender: Any?) {
        let url = keyBrowser()?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        openDirectory(url)
    }

    @objc func showPreferences(_ sender: Any?) {
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.0)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Do not call bringUIToFront() — it re-orders browser windows above Settings.
        SettingsWindowController.shared.show()
    }

    @discardableResult
    func openDirectory(_ url: URL) -> BrowserWindowController {
        if let front = keyBrowser() {
            front.openDirectoryInTab(url)
            front.window?.makeKeyAndOrderFront(nil)
            return front
        }
        return openNewWindow(at: url)
    }

    @discardableResult
    func openNewWindow(at url: URL, select: [URL] = []) -> BrowserWindowController {
        let controller = BrowserWindowController(directory: url, select: select)
        register(controller)
        controller.showWindow(nil)
        return controller
    }

    /// Browse a compressed archive in a dedicated WinRAR-style window.
    @discardableResult
    func openArchiveWindow(at url: URL) -> ArchiveWindowController {
        let standardized = url.standardizedFileURL
        if let existing = archiveWindows.first(where: {
            $0.archiveURL.standardizedFileURL == standardized
        }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let controller = ArchiveWindowController(archive: standardized)
        archiveWindows.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    func archiveWindowDidClose(_ controller: ArchiveWindowController) {
        archiveWindows.removeAll { $0 === controller }
    }

    /// Open/focus the in-browser code compare tab for a workspace (比对1…比对10).
    func openCompareInKeyBrowser(workspace index: Int) {
        if let browser = keyBrowser() {
            browser.openCompareInTab(workspace: index)
            return
        }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let browser = openNewWindow(at: desktop)
        browser.openCompareInTab(workspace: index)
    }

    @discardableResult
    func openNewWindowSideBySide(from source: BrowserWindowController, with tab: BrowserTab) -> Bool {
        let controller = BrowserWindowController(tabs: [tab], activeID: tab.id)
        register(controller)
        controller.showWindow(nil)
        guard SideBySideManager.shared.attachSideBySide(source: source, new: controller) else {
            windowControllers.removeAll { $0 === controller }
            controller.window?.close()
            return false
        }
        return true
    }

    @discardableResult
    func openNewWindow(with tab: BrowserTab, screenPoint: NSPoint, matching sourceFrame: NSRect? = nil) -> BrowserWindowController {
        let controller = BrowserWindowController(tabs: [tab], activeID: tab.id)
        register(controller)
        controller.showWindow(nil)
        if let window = controller.window {
            var frame = window.frame
            if let sourceFrame {
                frame.size = sourceFrame.size
            }
            frame.origin = NSPoint(
                x: screenPoint.x - min(120, frame.width / 4),
                y: screenPoint.y - frame.height + 40
            )
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
            }
            let applyFrame = {
                window.setFrame(frame, display: true)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            applyFrame()
            DispatchQueue.main.async(execute: applyFrame)
        }
        return controller
    }

    private func register(_ controller: BrowserWindowController) {
        windowControllers.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            SideBySideManager.shared.windowWillClose(controller)
            self.windowControllers.removeAll { $0 === controller }
        }
    }

    private func keyBrowser() -> BrowserWindowController? {
        if let key = NSApp.keyWindow,
           let match = windowControllers.first(where: { $0.window === key }) {
            return match
        }
        return windowControllers.last
    }

    /// True when at least one browser window is still open (not closed).
    private func hasActiveBrowserWindow() -> Bool {
        !windowControllers.isEmpty
    }

    /// Used by the menu-bar status item.
    func keyBrowserForStatusBar() -> BrowserWindowController? {
        keyBrowser()
    }

    func browserWindowsForStatusBar() -> [BrowserWindowController] {
        windowControllers
    }

    func applyZoomFromStatusBar(_ percent: Int) {
        applyZoomFromMenu(percent)
    }

    func checkForUpdatesFromStatusBar() {
        checkForUpdatesFromMenu(nil)
    }

    // MARK: - Default folder handler

    func registerAsDefaultFolderViewer() {
        let appURL = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"

        let types: [UTType] = [.folder, .directory, .volume]
        // Do not claim public.symlink / alias-file — those often point at documents, not folders.

        for type in types {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { _ in }
            LSSetDefaultRoleHandlerForContentType(
                type.identifier as CFString,
                LSRolesMask.viewer,
                bundleID as CFString
            )
            LSSetDefaultRoleHandlerForContentType(
                type.identifier as CFString,
                LSRolesMask.all,
                bundleID as CFString
            )
        }

        // Force Launch Services to re-scan this build.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsregister) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregister)
            process.arguments = ["-f", appURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    func applyLaunchAtLoginSetting() {
        let enabled = AppSettings.shared.launchAtLogin
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // User may need to allow in System Settings → Login Items.
        }
    }

    // MARK: - Finder interception

    private func startFinderRedirectObserver() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleWorkspaceAppNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleWorkspaceAppNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleWorkspaceAppNote(note)
        }
        // Opening a DMG mounts under /Volumes/ — stop stealing until the volume goes away.
        center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  FinderVolumeGuard.urlLooksLikeMountedVolume(url) else { return }
            self?.beginLeavingFinderAlone()
        }
        center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Resume normal interception once nothing remains under /Volumes/.
            if !FinderVolumeGuard.hasMountedVolumes() {
                self.leaveFinderAloneUntil = nil
            }
        }
        updateFinderWindowPollTimer()
    }

    private func beginLeavingFinderAlone(for duration: TimeInterval = 600) {
        let until = Date().addingTimeInterval(duration)
        leaveFinderAloneUntil = until
        suppressFinderRedirectUntil = until
        pendingRedirectWorkItem?.cancel()
        pendingRedirectWorkItem = nil
        isRedirectingFinder = false
    }

    /// True while a DMG/installer session should not be stolen.
    private func isLeavingFinderAloneForVolumes() -> Bool {
        if let until = leaveFinderAloneUntil, Date() < until { return true }
        return false
    }

    private func shouldSuppressRedirect() -> Bool {
        if isLeavingFinderAloneForVolumes() { return false }
        if let until = suppressFinderRedirectUntil, Date() < until { return true }
        return false
    }

    private func handleWorkspaceAppNote(_ note: Notification) {
        guard AppSettings.shared.redirectFinderClicks else { return }
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.finder" else { return }
        if shouldSuppressRedirect() { return }
        // Tiny settle so selection exists; keep short to avoid visible lag.
        scheduleFinderRedirect(settle: 0.04)
    }

    func updateFinderWindowPollTimer() {
        finderWindowPollTimer?.invalidate()
        finderWindowPollTimer = nil
        guard AppSettings.shared.redirectFinderClicks else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.pollFinderWindowsIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        finderWindowPollTimer = timer
    }

    private func scheduleFinderRedirect(settle: TimeInterval) {
        guard AppSettings.shared.redirectFinderClicks else { return }
        if shouldSuppressRedirect() { return }
        pendingRedirectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.redirectFinderActivationToNewFinder()
        }
        pendingRedirectWorkItem = work
        if settle <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        }
    }

    private func pollFinderWindowsIfNeeded() {
        guard AppSettings.shared.redirectFinderClicks else { return }
        guard !isRedirectingFinder else { return }
        if shouldSuppressRedirect() { return }
        // Only when Finder is frontmost — a background DMG window must not yank focus from NF.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        guard finderLooksLikeItHasBrowserWindows() else { return }
        scheduleFinderRedirect(settle: 0)
    }

    /// Fast path: detect Finder browser windows without AppleScript.
    private func finderLooksLikeItHasBrowserWindows() -> Bool {
        let finderPID = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .processIdentifier
        guard let finderPID else { return false }

        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let screenH = NSScreen.main?.frame.height ?? 900
        let screenW = NSScreen.main?.frame.width ?? 1400

        for win in info {
            guard let pid = win[kCGWindowOwnerPID as String] as? pid_t, pid == finderPID else { continue }
            let layer = win[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let bounds = win[kCGWindowBounds as String] as? [String: Any] else { continue }
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            // Ignore menu-sized chrome; ignore full-screen desktop window.
            if height < 120 || width < 160 { continue }
            if height >= screenH - 40 && width >= screenW - 40 { continue }
            return true
        }
        return false
    }

    private func redirectFinderActivationToNewFinder() {
        guard AppSettings.shared.redirectFinderClicks else { return }
        guard !isRedirectingFinder else { return }
        if let last = lastFinderRedirectAt, Date().timeIntervalSince(last) < 0.8 {
            return
        }

        let frontIsFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        guard frontIsFinder || finderLooksLikeItHasBrowserWindows() else { return }

        // During a DMG session: probe without stealing. Stay on installer if still on /Volumes/.
        if isLeavingFinderAloneForVolumes() {
            let context = probeFinderContext()
            if finderContextInvolvesMountedVolume(context) || finderHasVolumeWindow() {
                return
            }
            // Finder moved to a normal folder — resume interception.
            leaveFinderAloneUntil = nil
        } else if let until = suppressFinderRedirectUntil, Date() < until {
            return
        }

        isRedirectingFinder = true
        lastFinderRedirectAt = Date()
        // Closing Finder / activating NF can re-fire Finder notifications — pause briefly.
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.2)

        // Switch focus first so the Finder flash is as short as possible (same as before).
        forceActivateNewFinder()

        let context = probeFinderContext()
        if finderContextInvolvesMountedVolume(context) || finderHasVolumeWindow() {
            beginLeavingFinderAlone()
            // Prefer NewFinder's installer UI over the fragile system Finder sheet.
            if let volume = volumeURLForInstaller(from: context) {
                _ = presentInstallerForMountedVolume(volume)
                closeFinderWindowsPreservingVolumes()
            } else {
                reactivateFinder()
            }
            isRedirectingFinder = false
            return
        }

        if context.selectURLs.isEmpty && context.folderURL == nil {
            // First DMG open: mount + installer often arrive after Finder activates.
            // Do NOT close windows yet — wait and re-check for /Volumes/.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self else { return }
                defer { self.isRedirectingFinder = false }

                let again = self.probeFinderContext()
                if self.finderContextInvolvesMountedVolume(again) || self.finderHasVolumeWindow() {
                    self.beginLeavingFinderAlone()
                    if let volume = self.volumeURLForInstaller(from: again) {
                        _ = self.presentInstallerForMountedVolume(volume)
                        self.closeFinderWindowsPreservingVolumes()
                    } else {
                        self.reactivateFinder()
                    }
                    return
                }

                self.closeFinderWindowsPreservingVolumes()
                self.applyFinderContext(again)
                self.forceActivateNewFinder()
                if again.selectURLs.isEmpty && again.folderURL == nil,
                   self.finderLooksLikeItHasBrowserWindows() || self.finderHasOpenWindows() {
                    self.noteFinderAutomationFailureIfNeeded()
                }
            }
            return
        }

        closeFinderWindowsPreservingVolumes()
        applyFinderContext(context)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.isRedirectingFinder = false
        }
    }

    private func finderContextInvolvesMountedVolume(_ context: FinderContext) -> Bool {
        if let folder = context.folderURL, FinderVolumeGuard.urlLooksLikeMountedVolume(folder) {
            return true
        }
        return FinderVolumeGuard.urlsInvolveMountedVolume(context.selectURLs)
    }

    /// Finder window target under /Volumes/ (works even before FileManager lists the mount).
    private func finderHasVolumeWindow() -> Bool {
        let (raw, _) = runAppleScript(FinderVolumeGuard.listWindowTargetsScript)
        return FinderVolumeGuard.windowTargetsInvolveMountedVolume(scriptResult: raw)
    }

    private func volumeURLForInstaller(from context: FinderContext) -> URL? {
        let candidates = context.selectURLs.map { url -> URL in
            FinderVolumeGuard.urlLooksLikeMountedVolume(url) ? url : url.deletingLastPathComponent()
        } + [context.folderURL].compactMap { $0 }

        for url in candidates {
            var volume = url.standardizedFileURL
            // Climb to /Volumes/Name
            let parts = volume.pathComponents
            if parts.count >= 3, parts[1] == "Volumes" {
                volume = URL(fileURLWithPath: "/" + parts[1] + "/" + parts[2], isDirectory: true)
            }
            if DMGInstallSupport.looksLikeInstallerVolume(volume) {
                return volume
            }
        }

        // Fall back to any Finder window on /Volumes that looks like an installer.
        let (raw, _) = runAppleScript(FinderVolumeGuard.listWindowTargetsScript)
        let paths = (raw ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        for path in paths where FinderVolumeGuard.pathLooksLikeMountedVolume(path) {
            var volume = URL(fileURLWithPath: path, isDirectory: true)
            let parts = volume.pathComponents
            if parts.count >= 3, parts[1] == "Volumes" {
                volume = URL(fileURLWithPath: "/" + parts[1] + "/" + parts[2], isDirectory: true)
            }
            if DMGInstallSupport.looksLikeInstallerVolume(volume) {
                return volume
            }
        }
        return nil
    }

    private func reactivateFinder() {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .activate(options: [.activateIgnoringOtherApps])
    }

    /// Close Finder windows except those on `/Volumes/` (DMG installers, USB, etc.).
    /// Always filter by path — never `close every window` while a mount may still be appearing.
    private func closeFinderWindowsPreservingVolumes() {
        _ = runAppleScript(FinderVolumeGuard.closeNonVolumeWindowsScript)
    }

    private func applyFinderContext(_ context: FinderContext) {
        if finderContextInvolvesMountedVolume(context) {
            reactivateFinder()
            return
        }
        // Dock / Finder Trash → open NewFinder's trash UI.
        if let folder = context.folderURL, FileOperations.isTrashDirectory(folder) {
            openTrash(at: folder)
            forceActivateNewFinder()
            return
        }
        if !context.selectURLs.isEmpty,
           context.selectURLs.contains(where: { FileOperations.isURLInTrash($0) }) {
            let trash = context.selectURLs
                .first(where: { FileOperations.isURLInTrash($0) })
                .map { FileOperations.isTrashDirectory($0) ? $0 : $0.deletingLastPathComponent() }
                ?? FileOperations.userTrashDirectory
            openTrash(at: trash)
            reveal(context.selectURLs)
            forceActivateNewFinder()
            return
        }
        if !context.selectURLs.isEmpty {
            reveal(context.selectURLs)
        } else if hasActiveBrowserWindow() {
            // NF already open: steal focus only; do not open Desktop / new tab from Finder dock click.
            keyBrowser()?.window?.makeKeyAndOrderFront(nil)
        } else if let folder = context.folderURL {
            openNewWindow(at: folder)
        } else {
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            openNewWindow(at: desktop)
        }
        forceActivateNewFinder()
    }

    /// Open the Trash in a new tab (or focus an existing Trash tab) — never replace the current tab.
    func openTrash(at url: URL = FileOperations.userTrashDirectory) {
        _ = openDirectory(url.standardizedFileURL)
    }

    private func forceActivateNewFinder() {
        bringUIToFront()
    }

    /// Bring NewFinder windows forward without switching to `.regular` (keeps Dock / menu bar clear).
    func bringUIToFront() {
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.5)
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        for controller in windowControllers {
            guard let window = controller.window else { continue }
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])

        // One short retry — Chrome/Finder may reclaim focus for a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.keyBrowser()?.window?.orderFrontRegardless()
            self.keyBrowser()?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func noteFinderAutomationFailureIfNeeded() {
        guard !didWarnFinderAutomation else { return }
        didWarnFinderAutomation = true
        let alert = NSAlert()
        alert.messageText = "需要允许控制 Finder"
        alert.informativeText = """
        Chrome 等应用的「在文件夹中显示」会打开系统 Finder。NewFinder 需要「自动化」权限才能接管。

        请打开：系统设置 → 隐私与安全性 → 自动化 → NewFinder → 勾选 Finder。
        然后重试 Chrome 里的文件夹按钮。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private struct FinderContext {
        var folderURL: URL?
        var selectURLs: [URL]
    }

    private func runAppleScript(_ source: String) -> (string: String?, error: NSDictionary?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return (nil, ["status": "compile failed"] as NSDictionary)
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            return (result.stringValue, error)
        }
        return (result.stringValue, nil)
    }

    private func probeFinderContext() -> FinderContext {
        let source = """
        tell application "Finder"
          set output to ""
          try
            set sel to the selection
            if (count of sel) > 0 then
              repeat with s in sel
                try
                  set output to output & POSIX path of (s as alias) & linefeed
                end try
              end repeat
              if output is not "" then return "SEL:" & output
            end if
          end try
          try
            if (count of Finder windows) > 0 then
              set t to target of front Finder window
              return "DIR:" & POSIX path of (t as alias)
            end if
          end try
          return ""
        end tell
        """
        let (raw, _) = runAppleScript(source)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return FinderContext(folderURL: nil, selectURLs: [])
        }

        if text.hasPrefix("SEL:") {
            let body = String(text.dropFirst(4))
            let paths = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return FinderContext(folderURL: nil, selectURLs: paths.map { URL(fileURLWithPath: $0) })
        }
        if text.hasPrefix("DIR:") {
            let path = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return FinderContext(folderURL: nil, selectURLs: []) }
            return FinderContext(folderURL: URL(fileURLWithPath: path), selectURLs: [])
        }
        return FinderContext(folderURL: nil, selectURLs: [])
    }

    private func finderHasOpenWindows() -> Bool {
        let (value, error) = runAppleScript("""
        tell application "Finder"
          try
            return (count of Finder windows) as string
          end try
          return "0"
        end tell
        """)
        if error != nil { return false }
        return Int(value ?? "0") ?? 0 > 0
    }

    private func closeFinderWindowsViaAppleScript() {
        _ = runAppleScript("""
        tell application "Finder"
          try
            close every window
          end try
        end tell
        """)
    }

    private func buildMainMenu() -> NSMenu {
        // Accessory apps do not own the system menu bar. Keep only hidden items for shortcuts.
        let mainMenu = NSMenu()

        let shortcutsMenuItem = NSMenuItem()
        shortcutsMenuItem.isHidden = true
        mainMenu.addItem(shortcutsMenuItem)
        let shortcutsMenu = NSMenu(title: "快捷键")
        shortcutsMenuItem.submenu = shortcutsMenu
        shortcutsMenu.addItem(withTitle: "剪切", action: #selector(BrowserWindowController.cut(_:)), keyEquivalent: "x")
        shortcutsMenu.addItem(withTitle: "拷贝", action: #selector(BrowserWindowController.copy(_:)), keyEquivalent: "c")
        shortcutsMenu.addItem(withTitle: "粘贴", action: #selector(BrowserWindowController.paste(_:)), keyEquivalent: "v")
        shortcutsMenu.addItem(withTitle: "全选", action: #selector(BrowserWindowController.selectAllItems(_:)), keyEquivalent: "a")
        let upItem = shortcutsMenu.addItem(
            withTitle: "上层文件夹",
            action: #selector(BrowserWindowController.goEnclosingFolder(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        upItem.keyEquivalentModifierMask = .command
        let renameItem = shortcutsMenu.addItem(
            withTitle: "重命名",
            action: #selector(BrowserWindowController.rename(_:)),
            keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!)
        )
        renameItem.keyEquivalentModifierMask = []
        shortcutsMenu.addItem(
            withTitle: "显示/隐藏左侧收藏栏",
            action: #selector(BrowserWindowController.toggleFavoritesSidebar(_:)),
            keyEquivalent: "o"
        )
        let topFavoritesItem = shortcutsMenu.addItem(
            withTitle: "显示/隐藏上方收藏栏",
            action: #selector(BrowserWindowController.toggleFavoritesTopBar(_:)),
            keyEquivalent: "o"
        )
        topFavoritesItem.keyEquivalentModifierMask = [.command, .shift]
        shortcutsMenu.addItem(
            withTitle: "关闭标签页",
            action: #selector(BrowserWindowController.closeActiveTabOrWindow(_:)),
            keyEquivalent: "w"
        )
        let prefs = shortcutsMenu.addItem(
            withTitle: "设置",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        prefs.target = self
        shortcutsMenu.addItem(withTitle: "退出 NewFinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        NSApp.windowsMenu = nil
        return mainMenu
    }

    /// Shared chrome menu for the toolbar gear and status-item (显示 / 窗口 / 缩放 / 更新 / 设置).
    /// - Parameters:
    ///   - includeShowAndWindows: status-item keeps「显示 / 窗口」; in-window gear omits them.
    ///   - includeQuit: status-item adds Quit.
    @discardableResult
    func populateChromeMenu(
        _ menu: NSMenu,
        includeQuit: Bool = false,
        includeShowAndWindows: Bool = true
    ) -> [AnyObject] {
        var helpers: [AnyObject] = []
        menu.removeAllItems()

        if includeShowAndWindows {
            let show = menu.addItem(
                withTitle: "显示 NewFinder",
                action: #selector(showNewFinderFromMenu(_:)),
                keyEquivalent: ""
            )
            show.target = self

            let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
            let windowMenu = NSMenu(title: "窗口")
            let windowHelper = WindowListMenuHelper { [weak self] in
                self?.windowControllers ?? []
            }
            windowMenu.delegate = windowHelper
            helpers.append(windowHelper)
            windowItem.submenu = windowMenu
            menu.addItem(windowItem)
        }

        let percent = AppSettings.shared.uiZoomPercent
        let zoomItem = NSMenuItem(title: "缩放（\(percent)%）", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu(title: "缩放")
        let sliderView = ZoomSliderMenuView(percent: percent) { [weak self, weak zoomItem] value in
            self?.applyZoomFromMenu(value)
            zoomItem?.title = "缩放（\(value)%）"
        }
        let sliderItem = NSMenuItem()
        sliderItem.view = sliderView
        zoomMenu.addItem(sliderItem)
        zoomMenu.delegate = sliderView
        zoomItem.submenu = zoomMenu
        chromeZoomMenuItem = zoomItem
        helpers.append(sliderView)
        menu.addItem(zoomItem)

        let version = UpdateChecker.currentVersion
        let update = menu.addItem(
            withTitle: "更新（\(version)）",
            action: #selector(checkForUpdatesFromMenu(_:)),
            keyEquivalent: ""
        )
        update.target = self

        let settings = menu.addItem(
            withTitle: "设置",
            action: #selector(showPreferences(_:)),
            keyEquivalent: ","
        )
        settings.target = self

        let goToItem = NSMenuItem(title: "转到", action: nil, keyEquivalent: "")
        let goToMenu = NSMenu(title: "转到")
        let activity = goToMenu.addItem(
            withTitle: "活动监视器",
            action: #selector(goToActivityMonitor(_:)),
            keyEquivalent: ""
        )
        activity.target = self
        let temperature = goToMenu.addItem(
            withTitle: "温度",
            action: #selector(goToTemperature(_:)),
            keyEquivalent: ""
        )
        temperature.target = self
        let uninstall = goToMenu.addItem(
            withTitle: "卸载软件",
            action: #selector(goToUninstallSoftware(_:)),
            keyEquivalent: ""
        )
        uninstall.target = self
        let terminal = goToMenu.addItem(
            withTitle: "终端",
            action: #selector(goToTerminal(_:)),
            keyEquivalent: ""
        )
        terminal.target = self
        goToItem.submenu = goToMenu
        menu.addItem(goToItem)

        if includeQuit {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "退出 NewFinder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        return helpers
    }

    @objc private func goToActivityMonitor(_ sender: Any?) {
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.0)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let browser = keyBrowser() {
            browser.openActivityMonitorInTab()
            return
        }
        let browser = openNewWindow(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        )
        browser.openActivityMonitorInTab()
    }

    @objc private func goToTemperature(_ sender: Any?) {
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.0)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let browser = keyBrowser() {
            browser.openTemperatureInTab()
            return
        }
        let browser = openNewWindow(
            at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        )
        browser.openTemperatureInTab()
    }

    @objc private func goToTerminal(_ sender: Any?) {
        openSystemApp(at: "/System/Applications/Utilities/Terminal.app")
    }

    @objc private func goToUninstallSoftware(_ sender: Any?) {
        // Open Applications so apps can be deleted / moved to Trash (macOS “uninstall”).
        bringUIToFront()
        openDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    private func openSystemApp(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func applyZoomFromMenu(_ percent: Int) {
        let clamped = min(500, max(30, percent))
        AppSettings.shared.uiZoomPercent = clamped
        chromeZoomMenuItem?.title = "缩放（\(clamped)%）"
        StatusBarController.shared.refreshZoomTitle(clamped)
        NotificationCenter.default.post(name: .uiZoomDidChange, object: nil)
    }

    @objc func showNewFinderFromMenu(_ sender: Any?) {
        userRequestedShowUI()
    }

    @objc func focusBrowserWindowFromMenu(_ sender: NSMenuItem) {
        guard let controller = sender.representedObject as? BrowserWindowController else { return }
        suppressFinderRedirectUntil = Date().addingTimeInterval(1.0)
        controller.window?.makeKeyAndOrderFront(nil)
        bringUIToFront()
    }

    @objc private func checkForUpdatesFromMenu(_ sender: Any?) {
        UpdateChecker.fetchLatest { [weak self] result in
            guard self != nil else { return }
            switch result {
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "检查更新失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
            case .success(let release):
                let current = UpdateChecker.currentVersion
                if UpdateChecker.isVersion(release.version, newerThan: current) {
                    let alert = NSAlert()
                    alert.messageText = "发现新版本 \(release.version)"
                    alert.informativeText = release.releaseNotes.isEmpty
                        ? "当前版本 \(current)。是否下载更新包？"
                        : release.releaseNotes
                    alert.addButton(withTitle: "下载更新")
                    alert.addButton(withTitle: "取消")
                    if alert.runModal() == .alertFirstButtonReturn {
                        self?.downloadUpdateFromMenu(release)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "已是最新版本"
                    alert.informativeText = "当前版本 \(current)"
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    private func downloadUpdateFromMenu(_ release: UpdateChecker.ReleaseInfo) {
        UpdateChecker.download(release) { result in
            switch result {
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "下载失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            case .success(let dmgURL):
                NSWorkspace.shared.open(dmgURL)
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
}

final class WindowListMenuHelper: NSObject, NSMenuDelegate {
    private let controllers: () -> [BrowserWindowController]

    init(controllers: @escaping () -> [BrowserWindowController]) {
        self.controllers = controllers
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = controllers()
        if list.isEmpty {
            let empty = menu.addItem(withTitle: "无打开的窗口", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        let keyWindow = NSApp.keyWindow
        for controller in list {
            let title = controller.window?.title.isEmpty == false
                ? (controller.window?.title ?? "窗口")
                : "窗口"
            let item = NSMenuItem(
                title: title,
                action: #selector(AppDelegate.focusBrowserWindowFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = AppDelegate.shared
            item.representedObject = controller
            item.state = (controller.window === keyWindow) ? .on : .off
            menu.addItem(item)
        }
    }
}

/// Zoom control under the menu-bar「缩放」item: editable % + slider + preset buttons.
final class ZoomSliderMenuView: NSView, NSMenuDelegate, NSTextFieldDelegate {
    private let field = ClickToFocusTextField()
    private let slider = NSSlider()
    private let onChange: (Int) -> Void
    private var presetButtons: [NSButton] = []

    init(percent: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 78))

        field.stringValue = "\(percent)%"
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.alignment = .center
        field.isEditable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.refusesFirstResponder = true
        field.focusRingType = .default
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.toolTip = "滚轮或上下键调节；点击后可输入，回车确认"
        field.onScrollStep = { [weak self] step in
            guard let self else { return }
            self.clearFieldFocus()
            let current = Int(self.slider.doubleValue.rounded())
            self.applyPercent(current + step, notify: true)
        }
        field.onArrowStep = { [weak self] step in
            guard let self else { return }
            let current = Int(self.slider.doubleValue.rounded())
            self.applyPercent(current + step, notify: true)
        }


        slider.minValue = 30
        slider.maxValue = 500
        slider.doubleValue = Double(percent)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false

        let presets = NSStackView()
        presets.orientation = .horizontal
        presets.spacing = 6
        presets.distribution = .fillEqually
        presets.translatesAutoresizingMaskIntoConstraints = false

        for value in [50, 100, 150, 200] {
            let button = NSButton(title: "\(value)%", target: self, action: #selector(presetClicked(_:)))
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 11)
            button.tag = value
            button.setButtonType(.momentaryPushIn)
            presets.addArrangedSubview(button)
            presetButtons.append(button)
        }

        addSubview(field)
        addSubview(slider)
        addSubview(presets)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            field.widthAnchor.constraint(equalToConstant: 56),
            field.heightAnchor.constraint(equalToConstant: 22),

            slider.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: field.centerYAnchor),

            presets.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            presets.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            presets.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            presets.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            presets.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        clearFieldFocus()
        applyPercent(AppSettings.shared.uiZoomPercent, notify: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        clearFieldFocus()
    }

    func menuDidClose(_ menu: NSMenu) {
        clearFieldFocus()
    }

    private func clearFieldFocus() {
        field.refusesFirstResponder = true
        if field.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
        // Drop any lingering selection highlight.
        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        clearFieldFocus()
        applyPercent(snap(Int(sender.doubleValue.rounded())), notify: true)
    }

    @objc private func fieldAction(_ sender: NSTextField) {
        commitField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as AnyObject? === field else { return }
        commitField()
        field.refusesFirstResponder = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === field else { return false }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            nudgePercent(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            nudgePercent(by: -1)
            return true
        }
        return false
    }

    private func nudgePercent(by delta: Int) {
        let current = Int(slider.doubleValue.rounded())
        applyPercent(current + delta, notify: true)
    }

    @objc private func presetClicked(_ sender: NSButton) {
        clearFieldFocus()
        applyPercent(sender.tag, notify: true)
    }

    private func commitField() {
        let raw = field.stringValue
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(raw) else {
            applyPercent(AppSettings.shared.uiZoomPercent, notify: false)
            return
        }
        applyPercent(snap(value), notify: true)
    }

    private func snap(_ value: Int) -> Int {
        min(500, max(30, value))
    }

    private func applyPercent(_ percent: Int, notify: Bool) {
        let clamped = snap(percent)
        slider.doubleValue = Double(clamped)
        field.stringValue = "\(clamped)%"
        if notify {
            onChange(clamped)
        }
    }
}

/// Text field that only takes focus after an explicit click (menus otherwise auto-select it).
private final class ClickToFocusTextField: NSTextField {
    /// +1 / −1 per mouse-wheel notch (or trackpad line).
    var onScrollStep: ((Int) -> Void)?
    /// +1 / −1 for ↑ / ↓ while editing.
    var onArrowStep: ((Int) -> Void)?
    private var preciseScrollAccumulator: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        refusesFirstResponder = false
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Catch arrows even before / outside the field editor path.
        if let onArrowStep {
            switch event.keyCode {
            case 126: // up arrow
                onArrowStep(1)
                return
            case 125: // down arrow
                onArrowStep(-1)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let onScrollStep else {
            super.scrollWheel(with: event)
            return
        }

        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }

        if event.hasPreciseScrollingDeltas {
            // Trackpad: accumulate ~one line before stepping, so it doesn't fly.
            preciseScrollAccumulator += dy
            let line: CGFloat = 4
            while preciseScrollAccumulator >= line {
                onScrollStep(1)
                preciseScrollAccumulator -= line
            }
            while preciseScrollAccumulator <= -line {
                onScrollStep(-1)
                preciseScrollAccumulator += line
            }
        } else {
            // Mouse wheel: one event ≈ one notch → ±1.
            onScrollStep(dy > 0 ? 1 : -1)
        }
    }
}
