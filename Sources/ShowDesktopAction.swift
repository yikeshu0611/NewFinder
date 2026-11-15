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
///
/// The apps are put back in the order they were stacked in before, not in an
/// arbitrary one — otherwise the user is left looking at the wrong window.
/// Unhiding alone does *not* restore the order: the system brings the apps
/// back in whatever order it gets to them, so the order is forced afterwards
/// by bringing the apps forward one after the other.
///
/// The apps are tracked by *process identifier*, not by bundle identifier:
/// two sessions of the same app — two RStudio windows, say — are two
/// separate applications on screen, and each one has its own place in the
/// stack.
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
    /// in the order they were stacked on screen — the front-most one first.
    ///
    /// Only apps hidden *by us* are remembered. Apps the user hid on their own
    /// stay hidden — a swipe up must not undo something the user did
    /// deliberately.
    ///
    /// The list is *not* cleared when a second swipe down comes. That swipe
    /// finds the apps already hidden and hides nothing new, so clearing the
    /// list would throw away the only record of what has to be restored.
    private static var hiddenProcessIdentifiers: [pid_t] = []

    /// The apps that had a window on screen when the desktop was shown, in
    /// the order they were stacked — the front-most one first.
    ///
    /// This is the whole stack, not just the apps we hid: NewFinder's own
    /// window is in it too, and it has to go back to the same place.
    ///
    /// Like the hidden list, it survives a second swipe down.
    private static var recordedStack: [pid_t] = []

    /// Hides every other app and shows the desktop.
    ///
    /// - Parameter hidingOwnWindows: called to push NewFinder's own windows
    ///   out of the way. They are ordered out, not closed, so the session
    ///   survives and the app can be brought back from the status-bar item.
    /// - Returns: `true` when something was actually changed.
    @discardableResult
    static func perform(hidingOwnWindows: () -> Void = {}) -> Bool {
        let me = Bundle.main.bundleIdentifier ?? "com.zhangjing.NewFinder"

        // The stacking order is read *before* anything is hidden, while the
        // windows are still on screen. Afterwards there is nothing left to
        // read it from.
        let windowInfo = AppStackOrder.currentWindowInfo()
        let ordered = AppStackOrder.frontToBack(
            applications: NSWorkspace.shared.runningApplications,
            windowInfo: windowInfo
        )

        // NewFinder's own windows go first: they are the ones the user is
        // looking at, and the desktop cannot be seen through them.
        hidingOwnWindows()

        // The order the user is looking at right now, recorded so it can be
        // compared with the order after the restore.
        PerfLog.log("[NF-DESKTOP] order before: \(AppStackOrder.orderNames(in: windowInfo).joined(separator: " > "))")

        let changed = hideOtherApps(excluding: [me], ordered: ordered)

        // The whole stack is remembered, so the restore can put every window
        // back where it was.
        //
        // The stack is only recorded when this swipe actually hid something.
        // A second swipe down finds every app already hidden and hides
        // nothing new — and by then the windows are gone, so there is no
        // order left to read. The stack from the first swipe is kept, it is
        // still the one the user was looking at.
        if changed {
            let onScreenPIDs = Set(windowInfo.compactMap {
                ($0[kCGWindowOwnerPID as String] as? pid_t)
            })
            recordedStack = ordered
                .filter { onScreenPIDs.contains($0.processIdentifier) }
                .map(\.processIdentifier)
        }

        showDesktop()
        return changed
    }

    /// Hides every running application except the given bundle identifiers.
    ///
    /// - Parameters:
    ///   - excluded: the bundle identifiers that are left alone.
    ///   - ordered: the applications, in the order they are stacked on screen.
    /// - Returns: `true` when something was actually changed.
    @discardableResult
    private static func hideOtherApps(
        excluding excluded: Set<String>,
        ordered: [NSRunningApplication]
    ) -> Bool {
        var changed = false

        // The apps are hidden in the order they are stacked, so the list
        // that is kept for the restore holds the same order the user saw.
        for app in ordered {
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
            // The app is remembered at the position it had in the stack, so
            // the restore can put it back there.
            if !hiddenProcessIdentifiers.contains(app.processIdentifier) {
                hiddenProcessIdentifiers.append(app.processIdentifier)
            }
            changed = true
            PerfLog.log("[NF-DESKTOP] hiding \(bundleID) pid=\(app.processIdentifier)")
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

    /// The applications that were hidden, in the order they were stacked.
    ///
    /// The applications are looked up by process identifier, so two sessions
    /// of the same app are both found.
    private static func hiddenApplications() -> [NSRunningApplication] {
        let running = NSWorkspace.shared.runningApplications
        return hiddenProcessIdentifiers.compactMap { pid in
            running.first { $0.processIdentifier == pid }
        }
    }

    /// Undoes `perform(hidingOwnWindows:)` — the apps hidden by it are unhidden
    /// again and the stack is put back the way it was.
    ///
    /// - Parameter restoringOwnWindows: called to bring NewFinder's own windows
    ///   back, if they were pushed away by the swipe down.
    /// - Returns: `true` when something was actually changed.
    @discardableResult
    static func restore(restoringOwnWindows: () -> Void = {}) -> Bool {
        var changed = false

        // The apps we hid come back.
        //
        // The order they are unhidden in does not decide the final order —
        // the system unhides them wherever it likes. The order is forced in
        // the next step, once they are all back on screen.
        let hidden = hiddenApplications()
        let hiddenPIDs = Set(hiddenProcessIdentifiers)
        hiddenProcessIdentifiers = []
        for app in hidden {
            app.unhide()
            changed = true
            PerfLog.log("[NF-DESKTOP] restoring \(app.bundleIdentifier ?? "?") pid=\(app.processIdentifier)")
        }

        // And now the stack is put back.
        //
        // The recorded stack is walked back-to-front, and every app in it is
        // brought forward. The app that is brought forward last ends up in
        // front, so the order comes back the way it was.
        //
        // NewFinder's own window is in the recorded stack too, and it is
        // ordered in at the place it had — its own windows are brought
        // forward at that point, so the apps that were in front of it end up
        // in front of it again.
        let myPID = ProcessInfo.processInfo.processIdentifier
        var ownWindowsRestored = false

        for pid in recordedStack.reversed() {
            if pid == myPID {
                restoringOwnWindows()
                ownWindowsRestored = true
                continue
            }
            // Only the apps we hid are brought forward. An app that was never
            // hidden is still where it was, and bringing it forward would
            // move it — with the Finder in particular that would open a
            // NewFinder window out of nowhere.
            guard hiddenPIDs.contains(pid) else { continue }
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier == pid
            }) else { continue }
            AppStackRestore.bringForward(app)
            // The activation is asynchronous — without a pause the system may
            // still be busy with the previous one, and the two end up
            // fighting over the same window.
            let wait = AppStackRestore.pause()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }

        // NewFinder had no window on screen when the desktop was shown, so
        // its windows are brought back first and the apps that were hidden
        // end up in front of it.
        if !ownWindowsRestored {
            restoringOwnWindows()
        }

        // The stack is used up — a second swipe up has nothing left to put
        // back.
        recordedStack = []

        changed = true
        PerfLog.log("[NF-DESKTOP] order restored")

        // The order after the restore, so it can be compared with the order
        // the user was looking at before the desktop was shown.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            PerfLog.log("[NF-DESKTOP] order after: \(AppStackOrder.currentOrderNames().joined(separator: " > "))")
        }

        return changed
    }

    /// True when there is something to restore — used to decide whether the
    /// swipe up should do anything at all.
    static var hasSomethingToRestore: Bool {
        !hiddenProcessIdentifiers.isEmpty || !recordedStack.isEmpty
    }
}
