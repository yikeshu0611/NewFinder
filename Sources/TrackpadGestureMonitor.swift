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

    /// Timer that re-enables the tap when the system disables it.
    private var tapWatchdogTimer: Timer?

    /// Total number of touch frames received — used to tell a live tap from a
    /// disabled one.
    private var frameCounter = 0
    /// The frame counter at the last watchdog check.
    private var lastFrameCount = 0
    /// Set when the system reports that it disabled the tap.
    private var tapWasDisabled = false

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
        startTapWatchdog()
    }

    /// Re-enables the tap if the system disabled it.
    ///
    /// macOS disables an event tap that takes too long to service its callback.
    /// The tap's callback returns immediately, but the *conversion* of the event
    /// to `NSEvent` was originally done with `DispatchQueue.main.sync`, which
    /// blocked the callback while the main thread ran — and the main thread of
    /// this app regularly blocks for hundreds of milliseconds (the Finder
    /// polling runs AppleScript against Finder every 0.12 s). The window
    /// server therefore saw the tap as unresponsive and disabled it, after
    /// which the gesture was silently dead.
    ///
    /// Two mechanisms keep the tap alive:
    ///
    /// 1. The callback no longer waits for the main thread at all.
    /// 2. The system notifies us about a disable through the
    ///    `tapDisabledByTimeout` / `tapDisabledByUserInput` event types, which
    ///    are handled in `handle(type:event:)`.
    ///
    /// The watchdog below is the safety net for the case where the disable
    /// notification itself is missed. It watches the *frame counter* rather
    /// than `CGEvent.tapIsEnabled`, because that API reports `false` for a
    /// listen-only tap that is perfectly alive.
    private func startTapWatchdog() {
        tapWatchdogTimer?.invalidate()
        tapWatchdogTimer = nil
        tapWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            // Frames arrived since the last check → the tap is delivering.
            guard self.lastFrameCount == self.frameCounter else {
                self.lastFrameCount = self.frameCounter
                return
            }
            // No frames at all — that is expected when nobody touches the
            // trackpad, so nothing can be concluded. Only a *previous* disable
            // makes this worth acting on.
            guard self.tapWasDisabled else { return }
            self.tapWasDisabled = false
            CGEvent.tapEnable(tap: tap, enable: true)
            PerfLog.log("[NF-GESTURE] tap was disabled — re-enabled")
        }
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
        tapWatchdogTimer?.invalidate()
        tapWatchdogTimer = nil
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
        // The system tells us when it disables the tap (the callback took too
        // long, or the user interacted). Both must re-enable the tap, or the
        // gesture stays dead for the rest of the session.
        switch type {
        case .tapDisabledByTimeout:
            PerfLog.log("[NF-GESTURE] tap disabled by timeout — re-enabling")
            shared?.tapWasDisabled = true
            if let tap = shared?.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        case .tapDisabledByUserInput:
            PerfLog.log("[NF-GESTURE] tap disabled by user input — re-enabling")
            shared?.tapWasDisabled = true
            if let tap = shared?.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        default:
            break
        }

        guard type.rawValue == 29 else { return }
        guard let monitor = shared else { return }
        monitor.process(event)
    }

    private func process(_ cgEvent: CGEvent) {
        // The tap callback runs on a private thread, and the window server
        // disables a tap whose callback takes too long. Waiting for the main
        // thread here would be exactly that — the main thread of this app
        // regularly blocks for hundreds of milliseconds (the Finder polling
        // runs AppleScript against Finder on a 0.12 s timer).
        //
        // So the event is *handed over* to the main thread without waiting for
        // it. `NSEvent(cgEvent:)` is only safe on the main thread, and it
        // reads the touch list lazily — the `NSTouch` objects would go stale
        // once the callback returned — so the touch data is read on the main
        // thread, but the tap callback itself returns immediately.
        //
        // The frames are delivered in order, so the detector still sees a
        // consistent sequence even though the work happens a little later.
        DispatchQueue.main.async { [weak self] in
            let touches = Self.decodeTouchesOnMainThread(from: cgEvent)
            self?.handleTouches(touches)
        }
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
        frameCounter += 1

        guard detector.handle(touches) else { return }
        PerfLog.log("[NF-GESTURE] three-finger swipe down")
        DispatchQueue.main.async { [weak self] in
            self?.onSwipeDown?()
        }
    }
}