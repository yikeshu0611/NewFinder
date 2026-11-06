import AppKit

/// Implements「隐藏所有 App，显示桌面」— the action behind the three-finger
/// swipe down gesture.
///
/// Two things have to happen, and the order matters:
///
/// 1. Every other application is hidden, so nothing is left on screen.
/// 2. The Finder desktop is brought forward, so the icons are visible instead
///    of the wallpaper alone.
///
/// Finder is deliberately *not* hidden: it owns the desktop. Hiding it takes the
/// desktop icons with it, which is exactly what the user asked to see.
enum ShowDesktopAction {

    /// Apps that must never be hidden — hiding them would break the desktop or
    /// the menu bar.
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter"
    ]

    /// Hides every other app and shows the desktop.
    ///
    /// - Parameter hidingOwnWindows: called to push NewFinder's own windows
    ///   out of the way. They are ordered out, not closed, so the session
    ///   survives and the app can be brought back from the status-bar item.
    /// - Returns: `true` when something was actually changed.
    @discardableResult
    static func perform(hidingOwnWindows: () -> Void = {}) -> Bool {
        let me = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"

        // NewFinder's own windows go first: they are the ones the user is
        // looking at, and the desktop cannot be seen through them.
        hidingOwnWindows()

        let changed = hideOtherApps(excluding: [me])
        showDesktop()
        return changed
    }

    /// Hides every running application except the given bundle identifiers.
    @discardableResult
    private static func hideOtherApps(excluding excluded: Set<String>) -> Bool {
        var changed = false
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            guard !excluded.contains(bundleID) else { continue }
            guard !protectedBundleIdentifiers.contains(bundleID) else { continue }
            // Only real, user-facing apps — agents and accessory apps have no
            // windows to show anyway, and hiding some of them breaks the Dock.
            guard app.activationPolicy == .regular else { continue }
            guard !app.isHidden else { continue }
            // `hide()` reports whether the request was *sent*, not whether it
            // succeeded — the app is hidden asynchronously. So the request is
            // counted here, not by its return value.
            app.hide()
            changed = true
            PerfLog.log("[NF-DESKTOP] hiding \(bundleID)")
        }
        return changed
    }

    /// Brings the Finder desktop forward.
    private static func showDesktop() {
        // Finder owns the desktop. Activating it puts the desktop icons on
        // screen. Any Finder window that was open stays open behind the
        // desktop, which is the same result the system's own Show Desktop
        // gesture gives.
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            return
        }
        finder.activate(options: [.activateIgnoringOtherApps])
    }
}
