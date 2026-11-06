import AppKit

// Exercises the Option tap state machine with synthetic flag changes, so
// the gesture rules can be verified without a physical tap.
//
// The double tap is *deferred*: the recognizer cannot know whether a third
// press is coming until the resolution delay has passed.
//
// The recognizer works on a virtual clock — the timestamps of the events it
// is fed — because the deadline of a pending double tap lives in that same
// coordinate system. The detector's timer is what turns the virtual deadline
// into a real one, and the tests drive the same path directly.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

/// Feeds one flags change into the recognizer and then resolves any pending
/// double tap whose deadline has passed.
func feed(
    _ recognizer: OptionTapRecognizer,
    at time: Date,
    optionDown: Bool,
    shiftDown: Bool = false,
    controlDown: Bool = false,
    commandDown: Bool = false
) {
    recognizer.process(
        optionDown: optionDown,
        shiftDown: shiftDown,
        controlDown: controlDown,
        commandDown: commandDown,
        now: time
    )
    recognizer.flushPendingDoubleTap(at: time)
}

/// The moment a pending double tap is due, moved past so that it fires.
func dueTime(for recognizer: OptionTapRecognizer, after time: Date) -> Date {
    guard let deadline = recognizer.pendingResolutionDeadline else { return time }
    return max(deadline, time).addingTimeInterval(0.01)
}

/// Replays a sequence of Option presses and returns the tap counts that
/// were reported.
func tapCounts(
    presses: [TimeInterval],
    shiftDown: Bool = false,
    controlDown: Bool = false,
    commandDown: Bool = false
) -> [Int] {
    let recognizer = OptionTapRecognizer()
    var reported: [Int] = []
    recognizer.onTapCount = { count in reported.append(count) }

    let start = Date()
    var now = start
    for press in presses {
        // Press.
        feed(
            recognizer,
            at: start.addingTimeInterval(press),
            optionDown: true,
            shiftDown: shiftDown,
            controlDown: controlDown,
            commandDown: commandDown
        )
        // Release.
        feed(
            recognizer,
            at: start.addingTimeInterval(press + 0.02),
            optionDown: false
        )
        now = start.addingTimeInterval(press + 0.02)
    }

    // Resolve the pending double tap, the way the detector's timer would.
    recognizer.flushPendingDoubleTap(at: dueTime(for: recognizer, after: now))
    return reported
}

print("== a double tap fires ==")
do {
    check(tapCounts(presses: [0, 0.15]) == [2], "two presses in quick succession report a double tap")
}

print("== a single tap does not fire ==")
do {
    check(tapCounts(presses: [0]).isEmpty, "one press never fires")
}

print("== two slow presses do not fire ==")
do {
    check(
        tapCounts(presses: [0, 1.5]).isEmpty,
        "presses more than 0.4 s apart are not a double tap"
    )
}

print("== a triple tap fires as a triple ==")
do {
    check(
        tapCounts(presses: [0, 0.15, 0.3]) == [3],
        "three presses in a row report a triple tap, not a double tap"
    )
}

print("== a triple tap does not also report a double tap ==")
do {
    let counts = tapCounts(presses: [0, 0.15, 0.3])
    check(counts == [3], "the deferred double tap is cancelled by the third press")
}

print("== a slow third press does not turn it into a triple ==")
do {
    // The third press comes after the double tap has already been resolved,
    // so it starts a new gesture instead of extending the old one.
    let counts = tapCounts(presses: [0, 0.15, 0.6])
    check(counts == [2], "a late third press is a new gesture, the double tap still fires")
}

print("== holding the key does not fire ==")
do {
    let recognizer = OptionTapRecognizer()
    var fired = false
    recognizer.onTapCount = { _ in fired = true }
    let start = Date()
    // The key goes down and stays down — no release in between.
    for step in 0..<4 {
        feed(
            recognizer,
            at: start.addingTimeInterval(Double(step) * 0.1),
            optionDown: true
        )
    }
    recognizer.flushPendingDoubleTap(
        at: dueTime(for: recognizer, after: start.addingTimeInterval(0.3))
    )
    check(!fired, "holding Option down never fires")
}

print("== a modified Option press does not fire ==")
do {
    check(tapCounts(presses: [0, 0.15], shiftDown: true).isEmpty, "⌥⇧ does not trigger the gesture")
    check(tapCounts(presses: [0, 0.15], controlDown: true).isEmpty, "⌥⌃ does not trigger the gesture")
    check(tapCounts(presses: [0, 0.15], commandDown: true).isEmpty, "⌥⌘ does not trigger the gesture")
}

print("== a release does not count as a press ==")
do {
    let recognizer = OptionTapRecognizer()
    var fired = false
    recognizer.onTapCount = { _ in fired = true }
    let start = Date()
    // Option goes down, up, and up again (a modifier change that did not
    // involve a press).
    feed(recognizer, at: start, optionDown: true)
    feed(recognizer, at: start.addingTimeInterval(0.05), optionDown: false)
    feed(recognizer, at: start.addingTimeInterval(0.1), optionDown: false)
    recognizer.flushPendingDoubleTap(
        at: dueTime(for: recognizer, after: start.addingTimeInterval(0.1))
    )
    check(!fired, "releasing the key never fires")
}

print("== a reset cancels a pending double tap ==")
do {
    let recognizer = OptionTapRecognizer()
    var fired = false
    recognizer.onTapCount = { _ in fired = true }
    let start = Date()
    feed(recognizer, at: start, optionDown: true)
    feed(recognizer, at: start.addingTimeInterval(0.02), optionDown: false)
    feed(recognizer, at: start.addingTimeInterval(0.15), optionDown: true)
    recognizer.reset()
    recognizer.flushPendingDoubleTap(
        at: dueTime(for: recognizer, after: start.addingTimeInterval(0.15))
    )
    check(!fired, "resetting the recognizer cancels the pending double tap")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
