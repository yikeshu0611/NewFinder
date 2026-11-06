import AppKit
import CoreGraphics

/// Recognises a double or triple tap of the Command key.
///
/// The state machine is separated from the event tap so it can be exercised
/// without a live tap — the tap needs the system and the permissions, the
/// decision does not.
///
/// Distinguishing two taps from three is the interesting part. When the
/// second press arrives there is no way to know yet whether a third one is
/// coming, so the decision is *deferred*: the double tap only fires once the
/// resolution delay has passed without a third press. A third press inside
/// that window cancels the pending double tap and turns the gesture into a
/// triple tap, which fires straight away.
///
/// The deferral is expressed as a *deadline* rather than as a timer, so the
/// state machine stays pure and deterministic: the caller decides when the
/// deadline is reached (`flushPendingDoubleTap`) and everything is decided
/// against the timestamps of the events themselves. That matters because the
/// event timestamps and the wall clock are not guaranteed to agree.
final class CommandTapRecognizer {

    /// The maximum gap between two presses for them to count as part of the
    /// same gesture.
    static let tapInterval: TimeInterval = 0.4

    /// How long to wait after the second press before deciding that it was a
    /// double tap. A third press within this window makes it a triple tap.
    static let resolutionDelay: TimeInterval = 0.28

    /// Called on the main queue when the gesture is recognised.
    var onTapCount: ((Int) -> Void)?

    /// The presses seen so far, with their timestamps.
    private var pressTimes: [Date] = []

    /// Set while the Command key is held down, so that holding it does not
    /// look like a second press.
    private var commandIsDown = false

    /// The moment the pending double tap has to be resolved by, if there is
    /// one waiting for a possible third press.
    private var pendingDoubleTapDeadline: Date?

    /// The deadline of the pending double tap, if there is one.
    ///
    /// The caller schedules its resolution for this moment.
    var pendingResolutionDeadline: Date? { pendingDoubleTapDeadline }

    /// Feeds one flags change into the state machine.
    ///
    /// - Parameters:
    ///   - commandDown: whether the Command key is held.
    ///   - shiftDown / controlDown / optionDown: the other modifiers. A
    ///     modified Command press is a different shortcut and must not
    ///     trigger the gesture.
    ///   - now: the moment of the event.
    func process(
        commandDown: Bool,
        shiftDown: Bool = false,
        controlDown: Bool = false,
        optionDown: Bool = false,
        now: Date = Date()
    ) {
        // A pending double tap that is already due fires before anything
        // else happens, so that a late third press starts a new gesture
        // instead of turning the old one into a triple tap.
        flushPendingDoubleTap(at: now)

        // A Command press on its own.
        let isPlainCommand = commandDown && !shiftDown && !controlDown && !optionDown

        if isPlainCommand && !commandIsDown {
            // Command went down — this is one press of the gesture.
            commandIsDown = true

            // A press that is far away from the previous one starts a new
            // gesture, and any pending double tap is now void.
            if let last = pressTimes.last, now.timeIntervalSince(last) > Self.tapInterval {
                pressTimes.removeAll()
                pendingDoubleTapDeadline = nil
            }

            pressTimes.append(now)

            switch pressTimes.count {
            case 1:
                break
            case 2:
                // The second press may be the last one. Wait and see whether
                // a third press arrives before the gesture is fired.
                pendingDoubleTapDeadline = now.addingTimeInterval(Self.resolutionDelay)
            case 3:
                // The third press turns this into a triple tap. Any pending
                // double tap is cancelled.
                pendingDoubleTapDeadline = nil
                pressTimes.removeAll()
                onTapCount?(3)
            default:
                pressTimes.removeAll()
                pendingDoubleTapDeadline = nil
            }
            return
        }

        if !commandDown && commandIsDown {
            // Command came back up.
            commandIsDown = false
        }
    }

    /// Fires the pending double tap if its deadline has passed.
    ///
    /// - Parameter now: the moment the deadline is checked against.
    func flushPendingDoubleTap(at now: Date = Date()) {
        guard let deadline = pendingDoubleTapDeadline, now >= deadline else { return }
        pendingDoubleTapDeadline = nil
        guard pressTimes.count == 2 else { return }
        pressTimes.removeAll()
        onTapCount?(2)
    }

    /// Forgets everything — used when the tap is removed.
    func reset() {
        pressTimes.removeAll()
        commandIsDown = false
        pendingDoubleTapDeadline = nil
    }
}

/// Detects a double or triple tap of the Command key.
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
/// The tap is listen-only, so the Command key keeps working normally for the
/// focused application.
final class CommandTapDetector {

    /// Called on the main queue when the Command key is tapped twice or
    /// three times.
    var onCommandTap: ((Int) -> Void)?
    /// The event mask — flags changes are all that is needed.
    private static let eventMask = CGEventMask(1 << (CGEventType.flagsChanged.rawValue))

    private var tap: CFMachPort?

    /// The state machine that recognises the taps.
    private let recognizer = CommandTapRecognizer()

    /// Timer that re-installs the tap once the permission is granted.
    ///
    /// The permission can only be granted in System Settings, and a tap that
    /// was created before the grant stays silent — so it has to be replaced.
    private var permissionTimer: Timer?

    /// Timer that resolves a pending double tap.
    private var resolutionTimer: Timer?

    /// The detector is a singleton — there is only ever one Command key.
    static var shared: CommandTapDetector?

    // MARK: - Lifecycle

    /// Starts observing. Safe to call repeatedly; only the first call matters.
    static func start() {
        guard shared == nil else { return }
        let detector = CommandTapDetector()
        shared = detector
        detector.installTap()
    }

    /// Stops observing and releases the tap.
    static func stop() {
        guard let detector = shared else { return }
        shared = nil
        detector.removeTap()
    }

    private init() {
        // The recognizer is the source of truth; the detector forwards what
        // it reports.
        recognizer.onTapCount = { [weak self] count in
            self?.onCommandTap?(count)
        }
    }

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
                CommandTapDetector.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let created else {
            // Without the「输入监控」permission the tap is created but never
            // delivers events. The gesture simply does not fire; everything
            // else keeps working.
            PerfLog.log("[NF-CMDTAP] tap creation failed")
            return
        }

        NFAddMachPortSourceToCurrentRunLoop(created)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        PerfLog.log("[NF-CMDTAP] tap installed")
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
            PerfLog.log("[NF-CMDTAP] permissions granted, tap reinstalled")
        }
    }

    private func removeTap() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        resolutionTimer?.invalidate()
        resolutionTimer = nil
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
        // The tap callback runs on a private thread. The recognizer is only
        // ever touched on the main thread — the deferred double tap needs
        // to change its state — so the event is handed over rather than
        // processed here.
        DispatchQueue.main.async {
            detector.process(event)
        }
    }

    private func process(_ event: CGEvent) {
        let flags = event.flags
        recognizer.process(
            commandDown: flags.contains(.maskCommand),
            shiftDown: flags.contains(.maskShift),
            controlDown: flags.contains(.maskControl),
            optionDown: flags.contains(.maskAlternate)
        )
        schedulePendingResolution()
    }

    /// Schedules the resolution of a pending double tap.
    ///
    /// The recognizer only says *when* the pending double tap is due — it
    /// does not fire it on its own, so that the state machine stays pure and
    /// the event timestamps stay authoritative.
    private func schedulePendingResolution() {
        resolutionTimer?.invalidate()
        resolutionTimer = nil

        guard let deadline = recognizer.pendingResolutionDeadline else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        resolutionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.resolutionTimer = nil
            self.recognizer.flushPendingDoubleTap()
        }
    }
}
