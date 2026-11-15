import AppKit

/// Works out the order the applications are stacked on screen.
///
/// The order matters for「三指上推复原」: when the hidden apps come back they
/// have to end up in the same order they were in before, with the same app
/// in front. Restoring them in an arbitrary order leaves the user looking at
/// the wrong window, which is the whole point of putting them back.
///
/// The window list is sorted from front to back, so walking it once gives
/// the stacking order of the apps that have a window on screen. The apps
/// without one — minimized, hidden, or plain background helpers — sit behind
/// everything that has one.
///
/// Only the *normal* windows count. The window list is sorted by layer
/// before it is sorted by depth, and the higher layers hold the menu bar
/// items, the status items and the panels — the small helpers that have no
/// window the user would call "the app". Counting them would put an input
/// method or a menu bar utility in front of everything, which is not what
/// the user was looking at.
enum AppStackOrder {

    /// The window layer the normal application windows live on.
    ///
    /// Everything above it belongs to the menu bar, the Dock or a panel.
    private static let normalWindowLayer = 0

    /// A running application, reduced to what the ordering needs.
    struct App: Equatable {
        /// The process identifier of the application.
        let processIdentifier: pid_t
        /// The bundle identifier of the application.
        let bundleIdentifier: String
    }

    /// The applications, ordered the way they are stacked on screen — the
    /// front-most one first.
    ///
    /// - Parameters:
    ///   - apps: the applications to order.
    ///   - windowInfo: the window list, front-most window first.
    /// - Returns: the applications in stacking order.
    static func frontToBack(
        apps: [App],
        windowInfo: [[String: Any]]
    ) -> [App] {
        // The first window of an app is that app's place in the stack, so
        // only the first sighting of a process counts.
        //
        // The process identifier is used, not the bundle identifier: two
        // windows of the same app — two RStudio sessions, say — are two
        // separate applications as far as the stack is concerned, and each
        // one has its own place in it.
        var order: [pid_t] = []
        var seen = Set<pid_t>()

        for window in windowInfo {
            guard isNormalWindow(window) else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let app = apps.first(where: { $0.processIdentifier == pid }) else { continue }
            guard !seen.contains(pid) else { continue }
            seen.insert(pid)
            order.append(pid)
        }

        var ordered: [App] = []
        for pid in order {
            if let app = apps.first(where: { $0.processIdentifier == pid }) {
                ordered.append(app)
            }
        }

        // Apps without a window on screen — minimized, hidden, or only
        // background helpers — sit behind everything that has one.
        for app in apps where !seen.contains(app.processIdentifier) {
            ordered.append(app)
        }

        return ordered
    }

    /// The running applications, ordered the way they are stacked on screen.
    ///
    /// - Parameters:
    ///   - applications: the applications to order.
    ///   - windowInfo: the window list, front-most window first.
    /// - Returns: the applications in stacking order.
    static func frontToBack(
        applications: [NSRunningApplication],
        windowInfo: [[String: Any]]
    ) -> [NSRunningApplication] {
        let apps = applications.compactMap { app -> App? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return App(processIdentifier: app.processIdentifier, bundleIdentifier: bundleID)
        }

        let order = frontToBack(apps: apps, windowInfo: windowInfo)
        // The applications are looked up by process identifier, so two
        // sessions of the same app keep their own place in the stack.
        return order.compactMap { entry in
            applications.first { $0.processIdentifier == entry.processIdentifier }
        }
    }

    /// True when the window is a normal application window — not a menu bar
    /// item, a status item, a panel or the Dock.
    private static func isNormalWindow(_ window: [String: Any]) -> Bool {
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        return layer == normalWindowLayer
    }

    /// The window list of the whole system, front-most window first.
    ///
    /// Only the owner of each window is needed, and that is available
    /// without the「屏幕录制」permission.
    static func currentWindowInfo() -> [[String: Any]] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return info
    }

    /// The applications that have a window on screen, in the order they are
    /// stacked — the front-most one first.
    ///
    /// The process identifier is part of the name, because two sessions of
    /// the same app have the same name but are two separate applications on
    /// screen.
    ///
    /// Used to record what the user was looking at, so a restore can be
    /// checked against it.
    static func currentOrderNames() -> [String] {
        orderNames(in: currentWindowInfo())
    }

    /// The applications that have a window on screen, in the order they are
    /// stacked — the front-most one first.
    ///
    /// - Parameter windowInfo: the window list, front-most window first.
    /// - Returns: the names of the applications, with the process identifier
    ///   appended.
    static func orderNames(in windowInfo: [[String: Any]]) -> [String] {
        // The running applications are looked up in the list rather than
        // through `NSRunningApplication(processIdentifier:)`: an application
        // built from a process identifier has not resolved its name yet, so
        // `localizedName` comes back empty.
        let running = NSWorkspace.shared.runningApplications
        var seen = Set<pid_t>()
        var order: [String] = []

        for window in windowInfo {
            guard isNormalWindow(window) else { continue }
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let app = running.first(where: { $0.processIdentifier == pid }) else { continue }
            guard let name = app.localizedName else { continue }
            guard seen.insert(pid).inserted else { continue }
            order.append("\(name)#\(pid)")
        }
        return order
    }
}
