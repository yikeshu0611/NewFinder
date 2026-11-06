import AppKit
import CoreGraphics

/// Recognises a double tap of the Command key.
///
/// The state machine is separated from the event tap so it can be exercised
/// without a live tap — the tap needs the system and the permissions, the
/// decision does not.
struct DoubleCommandRecognizer {

    /// The maximum gap between two presses for them to count as a double tap.
    static let doubleTapInterval: TimeInterval = 0.4

    /// The moment the last Command press was seen, if it was recent enough
    /// to be the first half of a double tap.
    private var lastPressAt: Date?

    /// Set while the Command key is held down, so that holding it does not
    /// look like a second press.
    private var commandIsDown = false

    /// Feeds one flags change into the state machine.
    ///
    /// - Parameters:
    ///   - commandDown: whether the Command key is held.
    ///   - shiftDown / controlDown / optionDown: the other modifiers. A
    ///     modified Command press is a different shortcut and must not
    ///     trigger the gesture.
    ///   - now: the moment of the event.
    /// - Returns: `true` when this completes a double tap.
    mutating func process(
        commandDown: Bool,
        shiftDown: Bool = false,
        controlDown: Bool = false,
        optionDown: Bool = false,
        now: Date = Date()
    ) -> Bool {
        // A Command press on its own.
        let isPlainCommand = commandDown && !shiftDown && !controlDown && !optionDown

        if isPlainCommand && !commandIsDown {
            // Command went down — this may be the second half of a double tap.
            if let previous = lastPressAt, now.timeIntervalSince(previous) < Self.doubleTapInterval {
                lastPressAt = nil
                commandIsDown = true
                return true
            }
            lastPressAt = now
            commandIsDown = true
            return false
        }

        if !commandDown && commandIsDown {
            // Command came back up.
            commandIsDown = false
        }
        return false
    }

    /// Forgets everything — used when the tap is removed.
    mutating func reset() {
        lastPressAt = nil
        commandIsDown = false
    }
}

/// Detects a double tap of the Command key.
///
/// A bare Command press produces a **flagsChanged** event, not a keyDown —
/// so the usual `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` cannot
/// see it at all. Two things follow from that:
///
/// * the event has to be watched through a `CGEvent` tap, and
/// * the tap has to be a *session* tap, so the gesture works no matter which
///   application is frontmost. The same reasoning (and the same machinery)
///   is used by `TrackpadGestureMonitor` for the three-finger swipe.
///
/// The detector counts Command presses: two presses within
/// `doubleTapInterval` of each other count as a double tap. A press that is
/// held down does not count twice — only a *release* followed by another
/// *press* does, which is what makes it a double tap rather than a long
/// press.
///
/// The tap is listen-only, so the Command key keeps working normally for the
/// focused application.
final class DoubleCommandDetector {

    /// Called on the main queue when the Command key is double-tapped.
    var onDoubleCommand: (() -> Void)?

    /// The event mask — flags changes are all that is needed.
    private static let eventMask = CGEventMask(1 << (CGEventType.flagsChanged.rawValue))

    private var tap: CFMachPort?

    /// The state machine that recognises the double tap.
    private var recognizer = DoubleCommandRecognizer()

    /// Timer that re-installs the tap once the permission is granted.
    ///
    /// The permission can only be granted in System Settings, and a tap that
    /// was created before the grant stays silent — so it has to be replaced.
    private var permissionTimer: Timer?

    /// The detector is a singleton — there is only ever one Command key.
    static var shared: DoubleCommandDetector?

    // MARK: - Lifecycle

    /// Starts observing. Safe to call repeatedly; only the first call matters.
    static func start() {
        guard shared == nil else { return }
        let detector = DoubleCommandDetector()
        shared = detector
        detector.installTap()
    }

    /// Stops observing and releases the tap.
    static func stop() {
        guard let detector = shared else { return }
        shared = nil
        detector.removeTap()
    }

    private init() {}

    deinit {
        removeTap()
    }

    // MARK: - Tap

    private func installTap() {
        // A session tap spans the whole login session, so the Command key is
        // seen no matter which application is frontmost. Listen-only means the
        // focused app still receives the key events untouched.
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, _ in
                DoubleCommandDetector.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let created else {
            // Without the「输入监控」permission the tap is created but never
            // delivers events. The gesture simply does not fire; everything
            // else keeps working.
            PerfLog.log("[NF-DOUBLECMD] tap creation failed")
            return
        }

        NFAddMachPortSourceToCurrentRunLoop(created)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        PerfLog.log("[NF-DOUBLECMD] tap installed")
        startPermissionWatch()
    }

    /// Watches for the「输入监控」permission being granted and swaps the tap
    /// for a fresh one, because a tap created before the grant never
    /// delivers events.
    private func startPermissionWatch() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        // Only watch while the permission is still missing — otherwise the
        // timer would reinstall the tap forever.
        guard !NFHasListenEventAccess() else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard NFHasListenEventAccess() else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            // The old tap was created while the permission was missing.
            self.removeTap()
            self.installTap()
            PerfLog.log("[NF-DOUBLECMD] permissions granted, tap reinstalled")
        }
    }

    private func removeTap() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        recognizer.reset()
    }

    // MARK: - Detection

    /// The tap callback. Static because the C function pointer has no context.
    private static func handle(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        guard let detector = shared else { return }
        detector.process(event)
    }

    private func process(_ event: CGEvent) {
        let flags = event.flags
        let shouldFire = recognizer.process(
            commandDown: flags.contains(.maskCommand),
            shiftDown: flags.contains(.maskShift),
            controlDown: flags.contains(.maskControl),
            optionDown: flags.contains(.maskAlternate)
        )

        guard shouldFire else { return }
        DispatchQueue.main.async { [weak self] in
            PerfLog.log("[NF-DOUBLECMD] double command detected")
            self?.onDoubleCommand?()
        }
    }
}
