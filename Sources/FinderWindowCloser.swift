import AppKit
import ApplicationServices

/// Closes the window that the real Finder opened for a reveal, without
/// waiting for Finder.
///
/// The problem this solves: when another app asks Finder to show a file —
/// "Show in Finder" in WeChat, Chrome's download list — the real Finder opens
/// a window and comes to the front. NF takes over and shows the file itself,
/// but that window is still sitting behind NF, and the user has to close it
/// by hand.
///
/// The obvious way to close it is AppleScript, but AppleScript has to wait
/// for Finder's main thread — and Finder is busy opening the very window
/// that is to be closed. That wait is what made "Show in Finder" freeze for
/// two seconds.
///
/// The accessibility API does not go through Finder's AppleScript queue, so
/// the window is closed through it: the close button is found and pressed.
/// That takes a couple of milliseconds.
///
/// Only the window that belongs to the reveal is closed. The windows the
/// user had open before it stay open, and so do the windows on a mounted
/// volume — a DMG install window has to survive, or the installer would
/// lose its window.
enum FinderWindowCloser {

    /// Closes the Finder window that shows the given folder.
    ///
    /// - Parameter folder: the folder the reveal was showing.
    /// - Returns: `true` when a window was closed.
    @discardableResult
    static func closeWindowShowing(folder: URL) -> Bool {
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first else { return false }

        let axApp = AXUIElementCreateApplication(finder.processIdentifier)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return false
        }

        // The window is found by its title, which is the name of the folder
        // it shows. Finder uses the localized name for the system's own
        // folders — "Documents" is shown as "文稿" — so both names are
        // accepted.
        let names = displayNames(of: folder)
        guard !names.isEmpty else { return false }

        for window in windows {
            guard isStandardWindow(window) else { continue }
            let windowTitle = title(of: window)
            guard names.contains(windowTitle) else { continue }
            if pressCloseButton(of: window) {
                return true
            }
        }
        return false
    }

    /// The names a folder can be shown under.
    ///
    /// The name on disk, and the localized name Finder puts in the window
    /// title for the system's own folders.
    private static func displayNames(of folder: URL) -> Set<String> {
        var names: Set<String> = [folder.lastPathComponent]

        if let localized = try? folder.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localized.isEmpty {
            names.insert(localized)
        }
        return names
    }

    /// True when the element is an ordinary window — not the scroll area
    /// that Finder's desktop is reported as.
    private static func isStandardWindow(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) == "AXWindow"
    }

    /// The title of a window.
    private static func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXTitleAttribute as CFString,
            &value
        ) == .success, let text = value as? String else {
            return ""
        }
        return text
    }

    /// Finds the close button of a window and presses it.
    private static func pressCloseButton(of window: AXUIElement) -> Bool {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXChildrenAttribute as CFString,
            &children
        ) == .success, let list = children as? [AXUIElement] else {
            return false
        }

        for child in list {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(
                child,
                kAXSubroleAttribute as CFString,
                &subrole
            )
            guard (subrole as? String) == "AXCloseButton" else { continue }
            return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
        }
        return false
    }
}
