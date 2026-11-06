import AppKit
import ApplicationServices

/// Works out *why* Finder became the frontmost application, so that NF can
/// tell an intentional "show me this folder" request apart from the user
/// merely clicking on the desktop.
///
/// The problem this solves: clicking the blank desktop activates Finder
/// without producing any context — no selection, no window. NF used to treat
/// "no context" as "open the Desktop folder", so a stray click on the desktop
/// popped an NF window open.
///
/// The distinction is made from the click position, via the accessibility hit
/// test — the same mechanism the system uses to route a click to its target:
///
/// * a click **on the Dock** is deliberate (the Finder icon, a stack, or the
///   Desktop folder) — the redirect must follow through;
/// * a click **on a desktop icon** hits an `AXImage` owned by Finder — Finder
///   selects the item, so the normal path picks it up;
/// * a click **on the blank desktop** hits the full-screen desktop container —
///   there is nothing to show, so NF must stay out of the way.
///
/// IMPORTANT: the hit test is performed **per application** (Finder, Dock),
/// never system-wide. A system-wide hit test returns whichever overlay window
/// happens to be on top — an IDE, a panel, another app — which would make the
/// classification meaningless. App-scoped hit tests always report the element
/// that belongs to the app that was asked about, and they are what the
/// classification actually needs.
///
/// IMPORTANT: the accessibility API uses **Quartz coordinates** (origin at the
/// top-left of the primary display), while `NSEvent.mouseLocation` uses
/// **Cocoa coordinates** (origin at the bottom-left). Mixing them up makes the
/// hit test land on the wrong element entirely — a click on a desktop icon
/// would be reported as a click on the blank background, and the other way
/// round. Every coordinate handed to the accessibility API here goes through
/// `quartzLocation` first.
///
/// NF already needs the Accessibility permission for the trackpad gesture, so
/// the hit test is available without asking for anything extra. If the
/// permission is missing the hit test simply fails and every click is treated
/// as "content" — the old behaviour, which is a safe fallback.
enum FinderActivationIntent {

    /// What the click turned out to be.
    enum Intent {
        /// The user clicked the blank desktop — do nothing.
        case blankDesktop
        /// The user clicked the Dock — Finder is being asked for something,
        /// so the redirect must follow through.
        case dock
        /// The user clicked a desktop icon, a Finder window, or anything else
        /// that produced context — follow the normal path.
        case content
    }

    // MARK: - Cache

    /// The last classification, together with the mouse position it was made
    /// for. The Finder poll timer runs every 120 ms and would otherwise redo
    /// the same hit test over and over — and log the same line over and over.
    private static var cachedPosition: NSPoint?
    private static var cachedIntent: Intent?
    private static var cachedAt: Date?

    /// How long a classification stays valid for the same mouse position.
    private static let cacheLifetime: TimeInterval = 0.8

    /// How far the mouse may drift before the cached answer is discarded.
    private static let cachePositionTolerance: CGFloat = 2

    /// The position and time of the last blank-desktop click that was already
    /// reported, so the burst of activation notifications that macOS sends
    /// for a single click only produces one report.
    private static var lastBlankDesktopPosition: NSPoint?
    private static var lastBlankDesktopAt: Date?

    /// How long the same spot counts as "the same click".
    private static let blankDesktopRepeatWindow: TimeInterval = 3

    // MARK: - Public API

    /// Classifies the click that is currently under the mouse pointer.
    ///
    /// Called right after Finder was activated, so the pointer is still where
    /// the user clicked.
    static func currentIntent() -> Intent {
        let mouse = quartzMouseLocation()

        if let position = cachedPosition,
           let intent = cachedIntent,
           let at = cachedAt,
           Date().timeIntervalSince(at) < cacheLifetime,
           abs(position.x - mouse.x) < cachePositionTolerance,
           abs(position.y - mouse.y) < cachePositionTolerance {
            return intent
        }

        let intent = classify(at: mouse)
        cachedPosition = mouse
        cachedIntent = intent
        cachedAt = Date()
        return intent
    }

    /// True when the current blank-desktop click has already been reported.
    ///
    /// macOS fires several activation notifications for one click, and the
    /// Finder poll timer adds more, so the same click can be seen many times.
    /// Reporting it only once keeps the log readable — and keeps the redirect
    /// from being re-evaluated for no reason.
    static func isRepeatOfRecentBlankDesktopClick() -> Bool {
        guard let position = lastBlankDesktopPosition, let at = lastBlankDesktopAt else {
            return false
        }
        let mouse = quartzMouseLocation()
        return Date().timeIntervalSince(at) < blankDesktopRepeatWindow
            && abs(position.x - mouse.x) < cachePositionTolerance
            && abs(position.y - mouse.y) < cachePositionTolerance
    }

    /// Remembers a blank-desktop click as reported.
    static func noteBlankDesktopClickReported() {
        lastBlankDesktopPosition = quartzMouseLocation()
        lastBlankDesktopAt = Date()
    }

    // MARK: - Classification

    private static func classify(at point: CGPoint) -> Intent {
        // The Dock sits on top of the desktop, so it has to be asked first —
        // otherwise a Dock click would be reported as a click on the blank
        // desktop underneath it.
        if let dock = applicationElement(for: "com.apple.dock"),
           let hit = hitTest(application: dock, at: point),
           hit.isDockItem {
            return .dock
        }

        guard let finder = applicationElement(for: "com.apple.finder"),
              let hit = hitTest(application: finder, at: point) else {
            // Without a hit test nothing can be said — let the normal path run.
            return .content
        }

        if hit.isDesktopIcon {
            return .content
        }
        if hit.coversScreen(at: point) {
            return .blankDesktop
        }
        // Anything else (a Finder window, an unknown element) — follow the
        // normal path and let the Finder context decide.
        return .content
    }

    // MARK: - Coordinates

    /// The mouse position in Quartz coordinates (origin at the top-left of the
    /// primary display), which is the space the accessibility API uses.
    private static func quartzMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The bounds of the display that contains a Quartz point.
    ///
    /// `CGDisplayBounds` is already in Quartz coordinates, so it lines up with
    /// the accessibility frames.
    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }

        for display in displays {
            let bounds = CGDisplayBounds(display)
            if bounds.contains(point) { return bounds }
        }
        return CGDisplayBounds(displays.first ?? 0)
    }

    // MARK: - Accessibility plumbing

    /// The AX element of a running application, by bundle identifier.
    private static func applicationElement(for bundleIdentifier: String) -> AXUIElement? {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    /// The result of an accessibility hit test.
    private struct Hit {
        /// The element's role — `AXImage` for a desktop icon.
        let role: String
        /// The element's sub-role, when it has one.
        let subrole: String
        /// The element's frame, in Quartz coordinates.
        let frame: CGRect

        /// True when the element is a Dock item.
        var isDockItem: Bool {
            role == "AXDockItem" || subrole == "AXApplicationDockItem" || subrole == "AXDockItem"
        }

        /// True when the element is a desktop icon rather than the background.
        var isDesktopIcon: Bool {
            switch role {
            case "AXImage", "AXIcon":
                return true
            case "AXCell", "AXStaticText":
                // Icon labels and cells are small; a large one of the same role
                // is a list, not an icon.
                return frame.width < 240 && frame.height < 240
            default:
                return false
            }
        }

        /// True when the element is the desktop background — the container
        /// that covers the whole display.
        func coversScreen(at point: CGPoint) -> Bool {
            guard role == "AXGroup" || role == "AXScrollArea" || role == "AXUnknown" else {
                return false
            }
            guard let bounds = displayBounds(containing: point), bounds.width > 0 else {
                return false
            }
            return frame.width >= bounds.width * 0.9 && frame.height >= bounds.height * 0.9
        }
    }

    /// Runs the accessibility hit test at a Quartz point, restricted to one app.
    private static func hitTest(application: AXUIElement, at point: CGPoint) -> Hit? {
        var element: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            application,
            Float(point.x),
            Float(point.y),
            &element
        )
        guard status == .success, let element else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)

        return Hit(
            role: (roleRef as? String) ?? "",
            subrole: (subroleRef as? String) ?? "",
            frame: frame(of: element)
        )
    }

    /// The on-screen frame of an accessibility element, in Quartz coordinates.
    private static func frame(of element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success, let positionValue else { return .zero }

        var origin = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin) else { return .zero }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success, let sizeValue else { return .zero }

        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return .zero }

        return CGRect(origin: origin, size: size)
    }
}
