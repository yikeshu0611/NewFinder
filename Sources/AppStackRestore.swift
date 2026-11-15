import AppKit

/// Restores the stacking order of the applications that were hidden by
///「隐藏所有 App，显示桌面」.
///
/// The problem this solves: `unhide()` brings an application back on screen,
/// but it does *not* put it back where it was. The system unhides the apps in
/// whatever order it gets to them, and the user is left looking at the wrong
/// window — the front-most app ends up behind another one.
///
/// The order is therefore forced, by bringing the applications forward one
/// after the other. Bringing an app forward is a one-way operation, so the
/// apps are brought forward *back-to-front*: the one that was in front before
/// is brought forward last, and ends up in front again.
///
/// Two things are needed to put an application forward:
///
/// * `activate` brings the app forward — but it brings *all* of the app's
///   sessions forward. Two RStudio windows are one application as far as the
///   system is concerned, so activating one of them brings both along, and
///   the two end up next to each other instead of in their own places.
/// * Raising a window through the accessibility API moves one window only,
///   so it separates the sessions of the same app again.
///
/// Both are used, one after the other: the app is activated and then its
/// front window is raised.
enum AppStackRestore {

    /// How long to wait between two activations.
    ///
    /// Activating is asynchronous — the system has to bring the app forward
    /// before the next one is activated. Too short a pause and the two race
    /// each other, and the apps end up in the wrong order.
    private static let activatePause: TimeInterval = 0.45

    /// The order in which the items have to be brought forward.
    ///
    /// - Parameter frontToBack: the items, front-most first.
    /// - Returns: the same items, back-most first.
    static func raiseOrder<Element>(frontToBack: [Element]) -> [Element] {
        frontToBack.reversed()
    }

    /// Brings an application forward.
    ///
    /// The other apps are ignored, so the app ends up in front of them — the
    /// same result as clicking on its window.
    ///
    /// - Parameter app: the application to bring forward.
    /// - Returns: `true` when the request was sent.
    @discardableResult
    static func activate(_ app: NSRunningApplication) -> Bool {
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    /// Raises the front window of an application.
    ///
    /// The window that is raised is the one the window server reports as the
    /// app's front window — the one the user was looking at. It is found by
    /// its title, because the window list of the accessibility API is not in
    /// stacking order and its first entry is not necessarily the window on
    /// top.
    ///
    /// - Parameter app: the application whose window should be raised.
    /// - Returns: `true` when a window was found and raised.
    @discardableResult
    static func raiseFrontWindow(of app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              !windows.isEmpty else {
            return false
        }

        // The title the window server reports for the front window of the app.
        let frontTitle = serverFrontWindowTitle(of: app)

        let target: AXUIElement?
        if !frontTitle.isEmpty {
            target = windows.first { title(of: $0) == frontTitle }
        } else {
            target = windows.first
        }
        guard let target else { return false }

        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    /// The title of the front window of an application, as the window server
    /// sees it.
    private static func serverFrontWindowTitle(of app: NSRunningApplication) -> String {
        let info = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]) ?? []

        for window in info {
            // Only the normal application windows — the menu bar and the Dock
            // live on their own layers.
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier else { continue }
            return window[kCGWindowName as String] as? String ?? ""
        }
        return ""
    }

    /// The title of a window.
    private static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let text = value as? String else {
            return ""
        }
        return text
    }

    /// The pause between two activations.
    ///
    /// - Returns: how long to wait, in seconds.
    static func pause() -> TimeInterval {
        activatePause
    }

    /// Brings an application forward and puts it at the right place.
    ///
    /// The activation brings the app forward, and the raise separates it from
    /// the other sessions of the same app.
    ///
    /// - Parameter app: the application to bring forward.
    static func bringForward(_ app: NSRunningApplication) {
        activate(app)

        // The activation is asynchronous — the system has to bring the app
        // forward before its window can be raised. Without a pause the two
        // fight over the same window.
        let wait = activatePause
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }

        raiseFrontWindow(of: app)
    }
}
