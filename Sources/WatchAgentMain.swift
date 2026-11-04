import AppKit

/// Always-on helper process (`NewFinderWatch` / `NewFinder --watch-agent`).
/// Uses a separate bundle ID so Launch Services does not treat it as the UI app.
/// When the UI instance is not running and Finder is activated (e.g. Dock click),
/// capture Finder selection, close Finder windows, and relaunch NewFinder with
/// `--steal-finder` plus `--reveal` / `--reveal-dir` so the file stays selected.
enum WatchAgentMain {
    static func run() {
        let app = NSApplication.shared
        let delegate = WatchAgentDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.prohibited)
        app.run()
    }

    /// Parent `NewFinder.app` whether we run as nested helper or `--watch-agent` inside UI app.
    static func uiAppURL() -> URL {
        let bundle = Bundle.main.bundleURL
        if Bundle.main.bundleIdentifier == "com.zhangjing.NewFinder.Watch" {
            // …/NewFinder.app/Contents/Helpers/NewFinderWatch.app
            return bundle
                .deletingLastPathComponent() // Helpers
                .deletingLastPathComponent() // Contents
                .deletingLastPathComponent() // NewFinder.app
        }
        return bundle
    }
}

private final class WatchAgentDelegate: NSObject, NSApplicationDelegate {
    private var lastLaunchAt: Date?
    private var leaveFinderAloneUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleFinderNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleFinderNote(note)
        }
        center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  FinderVolumeGuard.urlLooksLikeMountedVolume(url) else { return }
            self?.leaveFinderAloneUntil = Date().addingTimeInterval(600)
        }
        center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if !FinderVolumeGuard.hasMountedVolumes() {
                self?.leaveFinderAloneUntil = nil
            }
        }
    }

    private func handleFinderNote(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.finder" else { return }
        guard !isUIInstanceRunning() else { return }
        if let until = leaveFinderAloneUntil, Date() < until { return }
        if let last = lastLaunchAt, Date().timeIntervalSince(last) < 1.0 { return }

        // Read the selection and close the Finder windows in ONE AppleScript round
        // trip. The script has a 2 second timeout, so an unresponsive Finder can
        // never stall the hand-off — we fall back to letting the UI app (which owns
        // the "control Finder" automation grant) do the work.
        guard let context = readAndCloseFinderContext() else {
            // Finder did not answer in time: let the UI app work it out itself.
            lastLaunchAt = Date()
            launchUIInstance(select: nil, folder: nil)
            return
        }
        if contextInvolvesMountedVolume(context) || finderContextHasVolumeWindow(context) {
            leaveFinderAloneUntil = Date().addingTimeInterval(600)
            return
        }

        lastLaunchAt = Date()

        if context.select.isEmpty && context.folder == nil {
            // First DMG open: wait for mount window before closing anything.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, !self.isUIInstanceRunning() else { return }
                if let until = self.leaveFinderAloneUntil, Date() < until { return }
                guard let again = self.readFinderContext() else {
                    self.launchUIInstance(select: nil, folder: nil)
                    return
                }
                if self.contextInvolvesMountedVolume(again) || self.finderContextHasVolumeWindow(again) {
                    self.leaveFinderAloneUntil = Date().addingTimeInterval(600)
                    return
                }
                self.closeFinderWindowsPreservingVolumes()
                self.launchUIInstance(select: again.select, folder: again.folder)
            }
            return
        }

        launchUIInstance(select: context.select, folder: context.folder)
    }

    private func contextInvolvesMountedVolume(_ context: FinderContext) -> Bool {
        if let folder = context.folder, FinderVolumeGuard.urlLooksLikeMountedVolume(folder) {
            return true
        }
        return FinderVolumeGuard.urlsInvolveMountedVolume(context.select)
    }

    /// A Finder window sitting on a mounted volume — derived from the state that
    /// was read in the same AppleScript round trip as the selection.
    private func finderContextHasVolumeWindow(_ context: FinderContext) -> Bool {
        FinderVolumeGuard.pathsInvolveMountedVolume(context.windowTargets)
    }

    /// True when the NewFinder UI app is running.
    private func isUIInstanceRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.zhangjing.NewFinder"
                && !$0.isTerminated
        }
    }

    private struct FinderContext {
        var select: [URL]
        var folder: URL?
        /// POSIX paths of every open Finder window target (same round trip).
        var windowTargets: [String] = []

        init(state: FinderVolumeGuard.FinderState) {
            windowTargets = state.windowTargets
            if !state.selection.isEmpty {
                select = state.selection.map { URL(fileURLWithPath: $0) }
                folder = nil
            } else if let dir = state.frontDirectory, !dir.isEmpty {
                select = []
                folder = URL(fileURLWithPath: dir)
            } else {
                select = []
                folder = nil
            }
        }
    }

    /// One AppleScript round trip: selection + front window target + all window
    /// targets. Returns nil when Finder did not answer (timeout / error).
    private func readFinderContext() -> FinderContext? {
        var error: NSDictionary?
        let raw = NSAppleScript(source: FinderVolumeGuard.readFinderStateScript)?
            .executeAndReturnError(&error)
            .stringValue
        if error != nil { return nil }
        return FinderContext(state: FinderVolumeGuard.parseFinderState(raw))
    }

    /// Read + close in a single round trip. Returns nil when Finder did not answer.
    private func readAndCloseFinderContext() -> FinderContext? {
        var error: NSDictionary?
        let raw = NSAppleScript(source: FinderVolumeGuard.readAndCloseFinderStateScript)?
            .executeAndReturnError(&error)
            .stringValue
        if error != nil { return nil }
        return FinderContext(state: FinderVolumeGuard.parseFinderState(raw))
    }

    private func closeFinderWindowsPreservingVolumes() {
        var error: NSDictionary?
        NSAppleScript(source: FinderVolumeGuard.closeNonVolumeWindowsScript)?
            .executeAndReturnError(&error)
    }

    private func launchUIInstance(select: [URL]?, folder: URL?) {
        // Do not use `open -n` — that spawned duplicate UI windows/processes.
        var args = [
            WatchAgentMain.uiAppURL().path,
            "--args",
            "--steal-finder"
        ]
        for url in select ?? [] {
            args.append(contentsOf: ["--reveal", url.path])
        }
        if (select ?? []).isEmpty, let folder {
            args.append(contentsOf: ["--reveal-dir", folder.path])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
