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

        // Read selection BEFORE closing — same as UI path; skip /Volumes (DMG installers).
        let context = probeFinderContext()
        if contextInvolvesMountedVolume(context) || finderHasVolumeWindow() {
            leaveFinderAloneUntil = Date().addingTimeInterval(600)
            return
        }

        lastLaunchAt = Date()

        if context.select.isEmpty && context.folder == nil {
            // First DMG open: wait for mount window before closing anything.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, !self.isUIInstanceRunning() else { return }
                if let until = self.leaveFinderAloneUntil, Date() < until { return }
                let again = self.probeFinderContext()
                if self.contextInvolvesMountedVolume(again) || self.finderHasVolumeWindow() {
                    self.leaveFinderAloneUntil = Date().addingTimeInterval(600)
                    return
                }
                self.closeFinderWindowsPreservingVolumes()
                self.launchUIInstance(select: again.select, folder: again.folder)
            }
            return
        }

        closeFinderWindowsPreservingVolumes()
        launchUIInstance(select: context.select, folder: context.folder)
    }

    private func contextInvolvesMountedVolume(_ context: FinderContext) -> Bool {
        if let folder = context.folder, FinderVolumeGuard.urlLooksLikeMountedVolume(folder) {
            return true
        }
        return FinderVolumeGuard.urlsInvolveMountedVolume(context.select)
    }

    private func finderHasVolumeWindow() -> Bool {
        var error: NSDictionary?
        let raw = NSAppleScript(source: FinderVolumeGuard.listWindowTargetsScript)?
            .executeAndReturnError(&error)
            .stringValue
        return FinderVolumeGuard.windowTargetsInvolveMountedVolume(scriptResult: raw)
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
        var error: NSDictionary?
        let raw = NSAppleScript(source: source)?
            .executeAndReturnError(&error)
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = raw, !text.isEmpty else {
            return FinderContext(select: [], folder: nil)
        }

        if text.hasPrefix("SEL:") {
            let body = String(text.dropFirst(4))
            let paths = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            return FinderContext(select: paths.map { URL(fileURLWithPath: $0) }, folder: nil)
        }
        if text.hasPrefix("DIR:") {
            let path = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return FinderContext(select: [], folder: nil) }
            return FinderContext(select: [], folder: URL(fileURLWithPath: path))
        }
        return FinderContext(select: [], folder: nil)
    }

    private func closeFinderWindowsPreservingVolumes() {
        var error: NSDictionary?
        NSAppleScript(source: FinderVolumeGuard.closeNonVolumeWindowsScript)?
            .executeAndReturnError(&error)
    }

    private func launchUIInstance(select: [URL], folder: URL?) {
        // Do not use `open -n` — that spawned duplicate UI windows/processes.
        var args = [
            WatchAgentMain.uiAppURL().path,
            "--args",
            "--steal-finder"
        ]
        for url in select {
            args.append(contentsOf: ["--reveal", url.path])
        }
        if select.isEmpty, let folder {
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
