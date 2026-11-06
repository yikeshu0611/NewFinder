import AppKit
import CoreGraphics

/// Detects a three-finger swipe down on the trackpad and reports it.
///
/// How it works
/// ------------
/// macOS delivers a stream of *gesture* events (type 29) for every frame in
/// which a finger touches the trackpad. Each event carries the touches that
/// changed; converting it to an `NSEvent` and asking for `allTouches()` yields
/// `NSTouch` objects with a position on the trackpad surface
/// (`normalizedPosition`, 0…1, origin bottom-left).
///
/// The tap is **listen-only**. An active tap makes the window server wait for
/// our callback on every gesture event, which gates cursor movement for as long
/// as a finger is down — a well-known AppKit trap. We only ever observe, never
/// swallow, so the focused app still receives the gesture.
///
/// The decision itself lives in `SwipeDownDetector`, which is pure and can be
/// exercised without a trackpad.
final class TrackpadGestureMonitor {

    /// Called on the main queue when the gesture completes.
    var onSwipeDown: (() -> Void)?

    /// The gesture state machine.
    private var detector = SwipeDownDetector()

    private var tap: CFMachPort?

    /// The tap callbacks run on a private thread, so `detector` is only ever
    /// touched there — no locking needed. `onSwipeDown` hops to the main queue.
    static var shared: TrackpadGestureMonitor?

    /// Timer that re-installs the tap once the「输入监控」permission is granted.
    ///
    /// The permission can only be granted in System Settings, and the tap that
    /// was created before the grant stays silent — so it has to be replaced.
    private var permissionTimer: Timer?

    // MARK: - Lifecycle

    /// Starts observing. Safe to call repeatedly; only the first call matters.
    static func start() {
        guard shared == nil else { return }
        let monitor = TrackpadGestureMonitor()
        shared = monitor
        monitor.installTap()
    }

    /// Stops observing and releases the tap.
    static func stop() {
        guard let monitor = shared else { return }
        shared = nil
        monitor.removeTap()
    }

    var isRunning: Bool { tap != nil }

    private init() {}

    deinit {
        removeTap()
    }

    // MARK: - Tap

    private func installTap() {
        // Gesture events are type 29. `CGEventType` has no named case for it,
        // so the raw value is used.
        let gestureMask = CGEventMask(1 << 29)

        // The tap needs two permissions:
        //
        // *「辅助功能」(Accessibility) — required to create a working event tap.
        // *「输入监控」(Input Monitoring) — required to *observe* the events;
        //   without it the tap is created but never receives a single frame.
        //
        // Both prompts are raised here so the user is not left with a gesture
        // that silently does nothing.
        if !NFHasAccessibilityAccess() {
            NFRequestAccessibilityAccess()
            PerfLog.log("[NF-GESTURE] accessibility permission requested")
        }
        if !NFHasListenEventAccess() {
            NFRequestListenEventAccess()
            PerfLog.log("[NF-GESTURE] input monitoring permission requested")
        }
        PerfLog.log(
            "[NF-GESTURE] permissions accessibility=\(NFHasAccessibilityAccess())"
            + " inputMonitoring=\(NFHasListenEventAccess())"
        )

        // A *session* tap is what sees the trackpad frames. The tap is
        // listen-only, so the focused app still receives the gesture and the
        // window server never waits for our callback.
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureMask,
            callback: { _, type, event, _ in
                TrackpadGestureMonitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let created else {
            // Without the permission the tap is created but never delivers
            // events. `start()` still succeeds; the settings row explains
            // that the permission is needed.
            PerfLog.log("[NF-GESTURE] tap creation failed")
            return
        }

        NFAddMachPortSourceToCurrentRunLoop(created)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        PerfLog.log("[NF-GESTURE] tap installed")
        startPermissionWatch()
    }

    /// Watches for the permissions being granted and swaps the tap for a fresh
    /// one, because a tap created before the grant never delivers events.
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        // Only watch while a permission is still missing — otherwise the timer
        // would reinstall the tap forever.
        guard !NFHasAccessibilityAccess() || !NFHasListenEventAccess() else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let accessibilityReady = NFHasAccessibilityAccess()
            let inputMonitoringReady = NFHasListenEventAccess()
            guard accessibilityReady && inputMonitoringReady else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            // The old tap was created while a permission was missing; replace it.
            self.removeTap()
            self.installTap()
            PerfLog.log("[NF-GESTURE] permissions granted, tap reinstalled")
        }
    }

    /// Polls the permission state so the settings UI can show it live.
    static func currentPermissionState() -> Bool {
        NFHasAccessibilityAccess() && NFHasListenEventAccess()
    }

    private func removeTap() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        detector.reset()
    }

    // MARK: - Detection

    /// The tap callback. Static because the C function pointer has no context.
    private static func handle(type: CGEventType, event: CGEvent) {
        guard type.rawValue == 29 else { return }
        guard let monitor = shared else { return }
        monitor.process(event)
    }

    private func process(_ cgEvent: CGEvent) {
        // `NSEvent(cgEvent:)` must run on the main thread or AppKit crashes.
        // The tap callback is not on the main thread, so the conversion is
        // deferred; the touch data is copied out of the event first.
        let touches = Self.decodeTouches(from: cgEvent)
        DispatchQueue.main.async { [weak self] in
            self?.handleTouches(touches)
        }
    }

    private static func decodeTouches(from cgEvent: CGEvent) -> [SwipeDownDetector.Touch] {
        // `NSEvent(cgEvent:)` is only safe on the main thread.
        guard Thread.isMainThread else {
            var result: [SwipeDownDetector.Touch] = []
            DispatchQueue.main.sync {
                result = decodeTouchesOnMainThread(from: cgEvent)
            }
            return result
        }
        return decodeTouchesOnMainThread(from: cgEvent)
    }

    private static func decodeTouchesOnMainThread(from cgEvent: CGEvent) -> [SwipeDownDetector.Touch] {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return [] }
        // Only indirect touches are trackpad fingers. Direct ones come from a
        // touchscreen and have no `normalizedPosition`.
        let touches = nsEvent.allTouches().filter { $0.type == .indirect }
        return touches.map { touch in
            var position = NSPoint.zero
            let readable = NFReadNormalizedPosition(touch, &position)
            let phase = touch.phase
            return SwipeDownDetector.Touch(
                id: "\(touch.identity)",
                position: readable ? position : nil,
                isBegan: phase == .began,
                isDown: phase == .began || phase == .moved || phase == .stationary
            )
        }
    }

    /// Feeds one frame of touches into the detector.
    private func handleTouches(_ touches: [SwipeDownDetector.Touch]) {
        guard detector.handle(touches) else { return }
        PerfLog.log("[NF-GESTURE] three-finger swipe down")
        DispatchQueue.main.async { [weak self] in
            self?.onSwipeDown?()
        }
    }
}