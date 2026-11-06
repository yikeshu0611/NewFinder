import AppKit

// Exercises the double-Command state machine with synthetic flag changes,
// so the gesture rules can be verified without a physical double tap.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

/// Replays a sequence of Command presses and returns how many times the
/// gesture fired.
func fireCount(
    presses: [TimeInterval],
    shiftDown: Bool = false,
    controlDown: Bool = false,
    optionDown: Bool = false
) -> Int {
    var recognizer = DoubleCommandRecognizer()
    let start = Date()
    var fired = 0
    for press in presses {
        // Press.
        if recognizer.process(
            commandDown: true,
            shiftDown: shiftDown,
            controlDown: controlDown,
            optionDown: optionDown,
            now: start.addingTimeInterval(press)
        ) {
            fired += 1
        }
        // Release.
        _ = recognizer.process(
            commandDown: false,
            now: start.addingTimeInterval(press + 0.02)
        )
    }
    return fired
}

print("== a double tap fires ==")
do {
    check(fireCount(presses: [0, 0.15]) == 1, "two presses in quick succession fire once")
}

print("== a single tap does not fire ==")
do {
    check(fireCount(presses: [0]) == 0, "one press never fires")
}

print("== two slow presses do not fire ==")
do {
    check(fireCount(presses: [0, 1.5]) == 0, "presses more than 0.4 s apart are not a double tap")
}

print("== three quick taps fire once ==")
do {
    check(fireCount(presses: [0, 0.15, 0.3]) == 1, "three presses in a row fire once, not twice")
}

print("== holding the key does not fire ==")
do {
    var recognizer = DoubleCommandRecognizer()
    let start = Date()
    var fired = false
    // The key goes down and stays down — no release in between.
    for step in 0..<4 {
        if recognizer.process(
            commandDown: true,
            now: start.addingTimeInterval(Double(step) * 0.1)
        ) {
            fired = true
        }
    }
    check(!fired, "holding Command down never fires")
}

print("== a modified Command press does not fire ==")
do {
    check(fireCount(presses: [0, 0.15], shiftDown: true) == 0, "⌘⇧ does not trigger the gesture")
    check(fireCount(presses: [0, 0.15], controlDown: true) == 0, "⌘⌃ does not trigger the gesture")
    check(fireCount(presses: [0, 0.15], optionDown: true) == 0, "⌘⌥ does not trigger the gesture")
}

print("== a release does not count as a press ==")
do {
    var recognizer = DoubleCommandRecognizer()
    let start = Date()
    var fired = false
    // Command goes down, up, and up again (a modifier change that did not
    // involve a press).
    _ = recognizer.process(commandDown: true, now: start)
    if recognizer.process(commandDown: false, now: start.addingTimeInterval(0.05)) { fired = true }
    if recognizer.process(commandDown: false, now: start.addingTimeInterval(0.1)) { fired = true }
    check(!fired, "releasing the key never fires")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
