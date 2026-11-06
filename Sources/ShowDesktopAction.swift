import AppKit

/// Implements「隐藏所有 App，显示桌面」— the action behind the three-finger
/// swipe down gesture — and「恢复之前的界面」— the action behind the three-finger
/// swipe up gesture.
///
/// Two things have to happen on a swipe down, and the order matters:
///
/// 1. Every other application is hidden, so nothing is left on screen.
/// 2. The Finder desktop is brought forward, so the icons are visible instead
///    of the wallpaper alone.
///
/// Finder is deliberately *not* hidden: it owns the desktop. Hiding it takes the
/// desktop icons with it, which is exactly what the user asked to see.
///
/// A swipe up undoes the swipe down: the apps that were hidden are unhidden
/// again and the one that was in front before is brought back. The list of
/// hidden apps is remembered, so apps the user hid *by hand* stay hidden.
enum ShowDesktopAction {

    /// Apps that must never be hidden — hiding them would break the desktop or
    /// the menu bar.
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter"
    ]

    /// The apps that were hidden by the last `perform(hidingOwnWindows:)` call,
    /// in the order they were hidden.
    ///
    /// Only apps hidden *by us* are remembered. Apps the user hid on their own
    /// stay hidden — a swipe up must not undo something the user did
    /// deliberately.
    private static var hiddenBundleIdentifiers: [String] = []

    /// The app that was in front when the desktop was shown. It is the one
    /// brought back by a swipe up.
    private static var previousFrontmostBundleIdentifier: String?

    /// Hides every other app and shows the desktop.
    ///
    /// - Parameter hidingOwnWindows: called to push NewFinder's own windows
    ///   out of the way. They are ordered out, not closed, so the session
    ///   survives and the app can be brought back from the status-bar item.
    /// - Returns: `true` when something was actually changed.
    @discardableResult
    static func perform(hidingOwnWindows: () -> Void = {}) -> Bool {
        let me = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"

        // Remember who was in front, so a swipe up can bring that app back.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost, frontmost.bundleIdentifier != me {
            previousFrontmostBundleIdentifier = frontmost.bundleIdentifier
        }

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
        // Start from a clean list — a second swipe down replaces the first.
        hiddenBundleIdentifiers = []
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
            hiddenBundleIdentifiers.append(bundleID)
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

    /// Undoes `perform(hidingOwnWindows:)` — the apps hidden by it are unhidden
    /// again and the app that was in front is brought back.
    ///
    /// - Parameter restoringOwnWindows: called to bring NewFinder's own windows
    ///   back, if they were pushed away by the swipe down.
    /// - Returns: `true` when something was actually changed.
    @discardableResult
    static func restore(restoringOwnWindows: () -> Void = {}) -> Bool {
        var changed = false

        // The apps we hid come back.
        let toRestore = hiddenBundleIdentifiers
        hiddenBundleIdentifiers = []
        for bundleID in toRestore {
            guard let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first else { continue }
            app.unhide()
            changed = true
            PerfLog.log("[NF-DESKTOP] restoring \(bundleID)")
        }

        // NewFinder's own windows come back.
        restoringOwnWindows()

        // And the app that was in front before goes back to the front.
        if let previous = previousFrontmostBundleIdentifier,
           let app = NSRunningApplication.runningApplications(
               withBundleIdentifier: previous
           ).first {
            app.activate(options: [.activateIgnoringOtherApps])
            changed = true
            PerfLog.log("[NF-DESKTOP] reactivating \(previous)")
        }
        previousFrontmostBundleIdentifier = nil

        return changed
    }

    /// True when there is something to restore — used to decide whether the
    /// swipe up should do anything at all.
    static var hasSomethingToRestore: Bool {
        !hiddenBundleIdentifiers.isEmpty || previousFrontmostBundleIdentifier != nil
    }
}
