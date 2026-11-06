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
/// The distinction is made from the click itself. A global mouse monitor
/// records where the user actually clicked, and the accessibility hit test
/// says what was under the pointer at that exact spot:
///
/// * a click **on the Dock** is deliberate (the Finder icon, a stack, or the
///   Desktop folder) — the redirect must follow through;
/// * a click **on a desktop icon** hits an `AXImage` owned by Finder — Finder
///   selects the item, so the normal path picks it up;
/// * a click **on the blank desktop** hits the full-screen desktop container —
///   there is nothing to show, so NF must stay out of the way.
///
/// Recording the click is much more reliable than asking where the pointer
/// happens to be when an activation notification arrives: by then the user
/// may have moved the mouse, and the notification may even be about a
/// different window altogether.
///
/// IMPORTANT: the hit test is performed **per application** (Finder, Dock),
/// never system-wide. A system-wide hit test returns whichever overlay window
/// happens to be on top — an IDE, a panel, another app — which would make the
/// classification meaningless. App-scoped hit tests always report the element
/// that belongs to the app that was asked about.
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

    /// A click the user made, and what it landed on.
    struct Click {
        /// The click position, in Quartz coordinates.
        let location: CGPoint
        /// What the click landed on.
        let intent: Intent
        /// When the click happened.
        let date: Date
    }

    /// How long a click stays relevant. Long enough to cover the delay
    /// between the click and the activation notification it causes, short
    /// enough that a click from a while ago does not classify a later event.
    static let clickValidity: TimeInterval = 2.0

    /// The most recent click, if it is one.
    private static var lastClick: Click?

    /// The position and time of the last blank-desktop click that was already
    /// reported, so the burst of activation notifications that macOS sends
    /// for a single click only produces one report.
    private static var lastBlankDesktopPosition: CGPoint?
    private static var lastBlankDesktopAt: Date?

    /// How long the same spot counts as "the same click".
    private static let blankDesktopRepeatWindow: TimeInterval = 3

    /// The monitor that watches for clicks. Held so it can be removed again.
    private static var globalMonitor: Any?
    private static var localMonitor: Any?

    // MARK: - Public API

    /// Starts watching for clicks.
    ///
    /// Safe to call repeatedly — only the first call installs the monitors.
    static func startMonitoringClicks() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        // Global — clicks that go to other applications (the desktop, the
        // Dock, a Finder window). This is the interesting case.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            record(event)
        }

        // Local — clicks that land in NewFinder's own windows. They do not
        // cause a Finder activation, but recording them keeps the state
        // consistent (a stale click must not classify a later event).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            record(event)
            return event
        }
    }

    /// Stops watching for clicks.
    static func stopMonitoringClicks() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        lastClick = nil
    }

    /// The most recent click, if it is still recent enough to be relevant.
    static func recentClick(now: Date = Date()) -> Click? {
        guard let lastClick else { return nil }
        guard now.timeIntervalSince(lastClick.date) < clickValidity else { return nil }
        return lastClick
    }

    /// The intent of the click that is happening right now, if there is one.
    ///
    /// Returns `nil` when Finder was activated *without* a click — an app
    /// asking Finder to reveal a file, for example. Such an activation must
    /// always be redirected, whatever the mouse happens to be resting on.
    static func currentClickIntent(now: Date = Date()) -> Intent? {
        guard let lastClick, now.timeIntervalSince(lastClick.date) < clickValidity else {
            return nil
        }
        return lastClick.intent
    }

    /// Forgets the recorded click — used when a redirect has been handled, so
    /// that the same click is not classified twice.
    static func clearLastClick() {
        lastClick = nil
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
        guard let click = recentClick() else { return false }
        return Date().timeIntervalSince(at) < blankDesktopRepeatWindow
            && abs(position.x - click.location.x) < 2
            && abs(position.y - click.location.y) < 2
    }

    /// Remembers a blank-desktop click as reported.
    static func noteBlankDesktopClickReported() {
        guard let click = recentClick() else { return }
        lastBlankDesktopPosition = click.location
        lastBlankDesktopAt = Date()
    }

    /// Classifies the click that is currently under the mouse pointer.
    ///
    /// Used when no click was recorded (for instance when Finder was
    /// activated by something other than a click) — the pointer position is
    /// the best guess available then.
    static func currentIntent() -> Intent {
        if let click = recentClick() {
            return click.intent
        }
        return classify(at: quartzMouseLocation())
    }

    // MARK: - Recording

    private static func record(_ event: NSEvent) {
        let location = quartzLocation(of: event)
        let intent = classify(at: location)
        lastClick = Click(location: location, intent: intent, date: Date())
    }

    // MARK: - Classification

    private static func classify(at point: CGPoint) -> Intent {
        let dockHit = applicationElement(for: "com.apple.dock")
            .flatMap { hitTest(application: $0, at: point) }
        let finderHit = applicationElement(for: "com.apple.finder")
            .flatMap { hitTest(application: $0, at: point) }

        let displaySize = displayBounds(containing: point)?.size
            ?? NSScreen.main?.frame.size
            ?? .zero

        return intent(dockHit: dockHit, finderHit: finderHit, displaySize: displaySize)
    }

    // MARK: - Coordinates

    /// The position of a mouse event, in Quartz coordinates (origin at the
    /// top-left of the primary display), which is the space the accessibility
    /// API uses.
    private static func quartzLocation(of event: NSEvent) -> CGPoint {
        // A global monitor reports an event that belongs to no window, and
        // `locationInWindow` is then in screen (Cocoa) coordinates. A local
        // monitor reports window-relative coordinates instead, so the screen
        // position is read from the current mouse location — the event is
        // handled as the click happens, so the two agree.
        let cocoa: NSPoint
        if event.window == nil {
            cocoa = event.locationInWindow
        } else {
            cocoa = NSEvent.mouseLocation
        }
        return quartzLocation(cocoa: cocoa)
    }

    /// Converts a Cocoa point (origin at the bottom-left of the primary
    /// display) to Quartz coordinates (origin at the top-left).
    ///
    /// The two spaces share the x axis, so only y has to be flipped: the
    /// Quartz y is the distance from the top of the primary display.
    /// `primary.frame.maxY` is that distance for the bottom edge of the
    /// primary display, and the same formula holds for every other display —
    /// Cocoa already encodes its position in the frame.
    ///
    /// - Parameters:
    ///   - cocoa: the point in Cocoa (bottom-left origin) coordinates.
    ///   - primaryMaxY: the height of the primary display, in points.
    static func quartzLocation(cocoa: NSPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: cocoa.x, y: primaryMaxY - cocoa.y)
    }

    private static func quartzLocation(cocoa: NSPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else {
            return CGPoint(x: cocoa.x, y: cocoa.y)
        }
        return quartzLocation(cocoa: cocoa, primaryMaxY: primary.frame.maxY)
    }

    /// The mouse position in Quartz coordinates.
    private static func quartzMouseLocation() -> CGPoint {
        // `CGEvent.location` is already in Quartz coordinates.
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
    struct Hit {
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
        func coversScreen(displaySize: CGSize) -> Bool {
            guard role == "AXGroup" || role == "AXScrollArea" || role == "AXUnknown" else {
                return false
            }
            guard displaySize.width > 0, displaySize.height > 0 else { return false }
            return frame.width >= displaySize.width * 0.9 && frame.height >= displaySize.height * 0.9
        }
    }

    /// Decides the intent from the elements that were hit.
    ///
    /// Split out from `classify(at:)` so the decision can be exercised
    /// without a live Finder — the hit testing needs a running system, the
    /// decision does not.
    ///
    /// - Parameters:
    ///   - dockHit: what the Dock's hit test found, if anything.
    ///   - finderHit: what Finder's hit test found, if anything.
    ///   - displaySize: the size of the display the click was on.
    static func intent(dockHit: Hit?, finderHit: Hit?, displaySize: CGSize) -> Intent {
        // The Dock sits on top of the desktop, so it has to be asked first —
        // otherwise a Dock click would be reported as a click on the blank
        // desktop underneath it.
        if let dockHit, dockHit.isDockItem {
            return .dock
        }
        guard let finderHit else {
            // Without a hit test nothing can be said — let the normal path run.
            return .content
        }
        if finderHit.isDesktopIcon {
            return .content
        }
        if finderHit.coversScreen(displaySize: displaySize) {
            return .blankDesktop
        }
        // Anything else (a Finder window, an unknown element) — follow the
        // normal path and let the Finder context decide.
        return .content
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
