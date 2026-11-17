import AppKit
import ApplicationServices

/// Swallows left-clicks on the Dock's Finder and Trash tiles so Finder never
/// sees them.
///
/// Why this exists: opening NF on mouse-down (via the `NSEvent` global
/// monitor) still lets the click through to the Dock — Finder activates and
/// paints one frame of its own window before the redirect closes it, which
/// is the visible flash. An `NSEvent` monitor is observe-only and cannot
/// stop the click. A `CGEvent` tap with `.defaultTap` can: returning `nil`
/// discards the event before the Dock receives it, so Finder never opens
/// anything and only NF appears.
///
/// This matters twice:
/// * Trash tile — Finder would open its Trash window for one frame;
/// * Finder tile — the first click from another app feels instant (NF just
///   comes forward), but repeat clicks each pop a real Finder window that
///   the redirect then has to close. Swallowing the click removes the
///   window entirely, so repeat clicks are as seamless as the first.
///
/// Only left-clicks that hit one of the two tiles are swallowed. Everything
/// else (including right-clicks — a different event type the tap does not
/// even listen for) passes through untouched.
///
/// Speed matters: the tap callback must return immediately, or the window
/// server disables the tap and the click gets through (the flash). So the
/// tap thread NEVER does AX or window-list lookups — it only tests the
/// click point against cached rects. The rects are refreshed on a
/// background queue by `refreshDockRectCache()`, which does the slow AX
/// walk over the Dock's children.
///
/// When the cache is empty (first seconds after launch, no permission) the
/// tap passes everything through and the old mouse-down pre-raise path
/// remains as fallback (with the flash).
final class DockTrashClickInterceptor {
    static let shared = DockTrashClickInterceptor()

    /// Called on the main thread when a Trash-tile left-click was swallowed.
    var onTrashClick: (() -> Void)?
    /// Called on the main thread when the Finder-tile left-click was swallowed.
    var onFinderIconClick: (() -> Void)?

    private var tap: CFMachPort?
    private var permissionTimer: Timer?
    private var refreshTimer: Timer?

    /// Set when a tile mouse-down was swallowed — the matching mouse-up must
    /// be swallowed too, otherwise the Dock still opens its window on
    /// mouse-up (a click completes on up, not down).
    private var swallowNextUp = false
    private var swallowedUpDeadline: Date = .distantPast

    /// Primary display height, captured on the main thread — used to try
    /// both Quartz orientations for the tap location (the tap thread must
    /// not touch AppKit).
    private var primaryMaxY: CGFloat = 0

    /// Cached tile frames in Quartz coordinates. Written on a background
    /// queue, read on the tap thread — `NSLock` guarded.
    private let rectLock = NSLock()
    private var _cachedTrashRect: CGRect?
    private var _cachedFinderRect: CGRect?
    private var cachedTrashRect: CGRect? {
        get { rectLock.lock(); defer { rectLock.unlock() }; return _cachedTrashRect }
        set { rectLock.lock(); _cachedTrashRect = newValue; rectLock.unlock() }
    }
    private var cachedFinderRect: CGRect? {
        get { rectLock.lock(); defer { rectLock.unlock() }; return _cachedFinderRect }
        set { rectLock.lock(); _cachedFinderRect = newValue; rectLock.unlock() }
    }

    private init() {}

    static func start() {
        if shared.primaryMaxY == 0 {
            shared.primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        }
        shared.installTap()
        shared.startCacheRefresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            shared.primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
            shared.refreshDockRectCache()
        }
    }

    // MARK: - Tap

    private func installTap() {
        if !NFHasAccessibilityAccess() {
            NFRequestAccessibilityAccess()
        }
        if !NFHasListenEventAccess() {
            NFRequestListenEventAccess()
        }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                DockTrashClickInterceptor.handle(type: type, event: event)
            },
            userInfo: nil
        ) else {
            PerfLog.log("[NF-TRASH] event tap creation failed — flash fallback")
            startPermissionWatch()
            return
        }
        NFAddMachPortSourceToCurrentRunLoop(created)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        PerfLog.log("[NF-TRASH] click-swallow tap installed")
        startPermissionWatch()
    }

    /// Re-installs the tap once「输入监控」is granted (a tap created before
    /// the grant stays silent forever).
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.tap == nil else {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                return
            }
            guard NFHasAccessibilityAccess(), NFHasListenEventAccess() else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.installTap()
        }
    }

    // MARK: - Tile rect cache

    private func startCacheRefresh() {
        refreshDockRectCache()
        refreshTimer?.invalidate()
        // The Dock tiles move when the Dock moves / magnifies / gains icons.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshDockRectCache()
        }
    }

    /// Re-reads the Finder / Trash tile frames off the main thread.
    ///
    /// Only AX-verified rects are used. The window-list-based approx
    /// fallbacks are deliberately NOT used: the window list lives in a
    /// different coordinate space, and a wrong-space rect would swallow
    /// clicks inside ordinary apps (breaking their "Show in Finder").
    /// When the AX walk misses there is simply no interception until the
    /// next refresh — the old mouse-down pre-raise remains as fallback.
    private func refreshDockRectCache() {
        DispatchQueue.global(qos: .utility).async {
            let (trash, finder) = Self.queryDockRects()
            if let trash {
                // Slop for magnification hover growth between refreshes.
                self.cachedTrashRect = trash.insetBy(dx: -10, dy: -10)
                PerfLog.log("[NF-TRASH] rect cached \(trash)")
            } else {
                self.cachedTrashRect = nil
                PerfLog.log("[NF-TRASH] AX walk missed — interception paused")
            }
            if let finder {
                self.cachedFinderRect = finder.insetBy(dx: -10, dy: -10)
                PerfLog.log("[NF-DOCK] Finder rect cached \(finder)")
            } else {
                self.cachedFinderRect = nil
                PerfLog.log("[NF-DOCK] AX walk missed — interception paused")
            }
        }
    }

    /// Walks the Dock's AX tree looking for the Finder and Trash tiles.
    /// Slow (dozens of AX round trips) — NEVER call on the tap thread.
    private static func queryDockRects() -> (trash: CGRect?, finder: CGRect?) {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?.processIdentifier else { return (nil, nil) }
        let dock = AXUIElementCreateApplication(pid)
        var queue: [AXUIElement] = [dock]
        var depth = 0
        var trash: CGRect?
        var finder: CGRect?
        while !queue.isEmpty, depth < 8 {
            var next: [AXUIElement] = []
            for element in queue {
                if isDockItem(element) {
                    if trash == nil, isTrashElement(element),
                       let rect = frame(of: element), rect.width > 2 {
                        trash = rect
                    }
                    if finder == nil, isFinderElement(element),
                       let rect = frame(of: element), rect.width > 2 {
                        finder = rect
                    }
                    if trash != nil, finder != nil { return (trash, finder) }
                }
                next.append(contentsOf: children(of: element))
            }
            queue = next
            depth += 1
        }
        return (trash, finder)
    }

    /// The Dock's own window rects — shared by the approx fallbacks.
    private static func dockBarRects() -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var rects: [CGRect] = []
        for window in windows {
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            guard ownerName == "Dock" || ownerName == "程序坞" else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if rect.width < 2 || rect.height < 2 { continue }
            rects.append(rect)
        }
        return rects
    }

    private static func largestDockBar() -> CGRect? {
        dockBarRects().max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// Fallback when the AX tree walk misses (the Dock's AX hierarchy varies
    /// by macOS version): the Trash tile always sits at the trailing end of
    /// the Dock bar itself, so take the Dock's own window rect and carve out
    /// a generous corner. Runs off the tap thread.
    private static func approximateTrashRect() -> CGRect? {
        guard let bar = largestDockBar() else { return nil }
        // Horizontal Dock (bottom): Trash at the far right end.
        if bar.width >= bar.height {
            return CGRect(x: bar.maxX - 110, y: bar.minY - 20,
                          width: 120, height: bar.height + 40)
        }
        // Vertical Dock (left/right side): Trash at the bottom end.
        return CGRect(x: bar.minX - 20, y: bar.maxY - 110,
                      width: bar.width + 40, height: 120)
    }

    /// Mirror fallback for the Finder tile: it always sits at the leading
    /// end of the Dock bar (far left / top), opposite the Trash.
    private static func approximateFinderRect() -> CGRect? {
        guard let bar = largestDockBar() else { return nil }
        if bar.width >= bar.height {
            return CGRect(x: bar.minX - 10, y: bar.minY - 20,
                          width: 130, height: bar.height + 40)
        }
        return CGRect(x: bar.minX - 20, y: bar.minY - 10,
                      width: bar.width + 40, height: 130)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &ref
        ) == .success, let ref else { return [] }
        if let arr = ref as? [AXUIElement] { return arr }
        if let ns = ref as? NSArray {
            var out: [AXUIElement] = []
            for item in ns {
                out.append(item as! AXUIElement)
            }
            return out
        }
        return []
    }

    private static func isDockItem(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let role = (roleRef as? String) ?? ""
        let subrole = (subroleRef as? String) ?? ""
        return role == "AXDockItem" || subrole == "AXApplicationDockItem" || subrole == "AXDockItem"
    }

    private static func dockItemText(_ element: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
        var descRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
        return (((titleRef as? String) ?? "") + " " + ((descRef as? String) ?? "")).lowercased()
    }

    private static func isTrashElement(_ element: AXUIElement) -> Bool {
        let text = dockItemText(element)
        return text.contains("废纸篓")
            || text.contains("垃圾")
            || text.contains("trash")
            || text.contains("ゴミ箱")
            || text.contains("휴지통")
            || text.contains("papierkorb")
            || text.contains("corbeille")
            || text.contains("papelera")
            || text.contains("cestino")
            || text.contains("prullenbak")
            || text.contains("lixeira")
    }

    private static func isFinderElement(_ element: AXUIElement) -> Bool {
        let text = dockItemText(element)
        return text.contains("finder") || text.contains("访达")
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posRef
        ) == .success, let posRef else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin) else { return nil }
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRef
        ) == .success, let sizeRef else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Tap callback (must stay FAST — cached rects only)

    private enum TileHit {
        case none
        case trash
        case finder
    }

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = shared.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            // Tap thread: NO logging / IO here — a slow callback gets the
            // tap disabled by the window server, the click then passes
            // through and Finder flashes. That is exactly what repeat
            // Finder-icon clicks were doing.
            let hit = shared.hitCachedTile(event.location)
            switch hit {
            case .trash:
                // Swallow: the Dock (and Finder) never sees this click.
                // The matching mouse-up is swallowed too — the Dock opens
                // its window on mouse-up, so swallowing down alone still
                // flashes Finder's window for one frame.
                shared.swallowNextUp = true
                shared.swallowedUpDeadline = Date().addingTimeInterval(1.0)
                DispatchQueue.main.async {
                    PerfLog.log("[NF-TRASH] Trash-tile click swallowed")
                    shared.onTrashClick?()
                }
                return nil
            case .finder:
                shared.swallowNextUp = true
                shared.swallowedUpDeadline = Date().addingTimeInterval(1.0)
                DispatchQueue.main.async {
                    PerfLog.log("[NF-DOCK] Finder-tile click swallowed")
                    shared.onFinderIconClick?()
                }
                return nil
            case .none:
                return Unmanaged.passUnretained(event)
            }
        case .leftMouseUp:
            if shared.swallowNextUp, Date() < shared.swallowedUpDeadline {
                shared.swallowNextUp = false
                return nil
            }
            shared.swallowNextUp = false
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Tap-thread hit test: point candidates vs the cached rects only.
    ///
    /// Coordinate space: `CGEvent.location` and AX frames are both Quartz
    /// (top-left origin), so they compare directly — NO y-flip. The flip
    /// that was here before created a mirrored "ghost" zone on the opposite
    /// screen edge that swallowed clicks inside third-party apps and broke
    /// their "Show in Finder" buttons.
    private func hitCachedTile(_ location: CGPoint) -> TileHit {
        if let rect = cachedFinderRect, rect.contains(location) {
            return .finder
        }
        if let rect = cachedTrashRect, rect.contains(location) {
            return .trash
        }
        return .none
    }
}
