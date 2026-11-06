import AppKit

// Exercises SwipeDownDetector with synthetic touch frames, so the gesture
// rules can be verified without a physical trackpad.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

typealias Touch = SwipeDownDetector.Touch

func touch(_ id: String, x: CGFloat, y: CGFloat, began: Bool = false, down: Bool = true) -> Touch {
    Touch(id: id, position: NSPoint(x: x, y: y), isBegan: began, isDown: down)
}

/// A three-finger swipe down: fingers start high (y large) and move to low y.
func swipeDownFrames() -> [[Touch]] {
    [
        // Frame 1: three fingers down at the top of the pad.
        [touch("a", x: 0.3, y: 0.8, began: true), touch("b", x: 0.5, y: 0.8, began: true), touch("c", x: 0.7, y: 0.8, began: true)],
        // Frame 2: moved a little down.
        [touch("a", x: 0.3, y: 0.75), touch("b", x: 0.5, y: 0.75), touch("c", x: 0.7, y: 0.75)],
        // Frame 3: moved past the threshold.
        [touch("a", x: 0.3, y: 0.65), touch("b", x: 0.5, y: 0.65), touch("c", x: 0.7, y: 0.65)]
    ]
}

print("== three-finger swipe down fires ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    for frame in swipeDownFrames() {
        if detector.handle(frame) { fired = true }
    }
    check(fired, "the gesture fires when three fingers move down")
}

print("== it fires only once per swipe ==")
do {
    var detector = SwipeDownDetector()
    var count = 0
    for frame in swipeDownFrames() {
        if detector.handle(frame) { count += 1 }
    }
    // A fourth frame continuing the same swipe must not fire again.
    if detector.handle([touch("a", x: 0.3, y: 0.55), touch("b", x: 0.5, y: 0.55), touch("c", x: 0.7, y: 0.55)]) {
        count += 1
    }
    check(count == 1, "the gesture fires exactly once (fired \(count)x)")
}

print("== two fingers do not fire ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    for frame in swipeDownFrames() {
        let two = Array(frame.prefix(2))
        if detector.handle(two) { fired = true }
    }
    check(!fired, "two fingers never fire the gesture")
}

print("== four fingers do not fire ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.2, y: 0.8, began: true), touch("b", x: 0.4, y: 0.8, began: true), touch("c", x: 0.6, y: 0.8, began: true), touch("d", x: 0.8, y: 0.8, began: true)],
        [touch("a", x: 0.2, y: 0.65), touch("b", x: 0.4, y: 0.65), touch("c", x: 0.6, y: 0.65), touch("d", x: 0.8, y: 0.65)]
    ]
    for frame in frames {
        if detector.handle(frame) { fired = true }
    }
    check(!fired, "four fingers never fire the gesture")
}

print("== swipe up does not fire ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.3, began: true), touch("b", x: 0.5, y: 0.3, began: true), touch("c", x: 0.7, y: 0.3, began: true)],
        [touch("a", x: 0.3, y: 0.5), touch("b", x: 0.5, y: 0.5), touch("c", x: 0.7, y: 0.5)]
    ]
    for frame in frames {
        if detector.handle(frame) { fired = true }
    }
    check(!fired, "swiping up never fires the gesture")
}

print("== a sideways swipe does not fire ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.5, began: true), touch("b", x: 0.5, y: 0.5, began: true), touch("c", x: 0.7, y: 0.5, began: true)],
        [touch("a", x: 0.5, y: 0.5), touch("b", x: 0.7, y: 0.5), touch("c", x: 0.9, y: 0.5)]
    ]
    for frame in frames {
        if detector.handle(frame) { fired = true }
    }
    check(!fired, "swiping sideways never fires the gesture")
}

print("== a tiny movement does not fire ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.5, began: true), touch("b", x: 0.5, y: 0.5, began: true), touch("c", x: 0.7, y: 0.5, began: true)],
        [touch("a", x: 0.3, y: 0.495), touch("b", x: 0.5, y: 0.495), touch("c", x: 0.7, y: 0.495)]
    ]
    for frame in frames {
        if detector.handle(frame) { fired = true }
    }
    check(!fired, "a movement below the threshold never fires the gesture")
}

print("== a finger joining mid-swipe re-bases the measurement ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    let frames: [[Touch]] = [
        // Two fingers first.
        [touch("a", x: 0.3, y: 0.8, began: true), touch("b", x: 0.5, y: 0.8, began: true)],
        // A third joins — the measurement restarts from here.
        [touch("a", x: 0.3, y: 0.75), touch("b", x: 0.5, y: 0.75), touch("c", x: 0.7, y: 0.75, began: true)],
        // Now they travel down together.
        [touch("a", x: 0.3, y: 0.6), touch("b", x: 0.5, y: 0.6), touch("c", x: 0.7, y: 0.6)]
    ]
    for frame in frames {
        if detector.handle(frame) { fired = true }
    }
    check(fired, "a three-finger swipe still fires when the third finger joins late")
}

print("== lifting the fingers re-arms the gesture ==")
do {
    var detector = SwipeDownDetector()
    // First swipe fires.
    for frame in swipeDownFrames() { _ = detector.handle(frame) }
    // All fingers lift.
    _ = detector.handle([touch("a", x: 0.3, y: 0.65, down: false)])
    // A second swipe fires again.
    var fired = false
    for frame in swipeDownFrames() {
        if detector.handle(frame) { fired = true }
    }
    check(fired, "a second swipe after lifting the fingers fires again")
}

print("== a lifted finger's stale position is not reused ==")
do {
    var detector = SwipeDownDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.8, began: true), touch("b", x: 0.5, y: 0.8, began: true), touch("c", x: 0.7, y: 0.8, began: true)],
        // Finger "c" lifts; "a" and "b" move only slightly.
        [touch("a", x: 0.3, y: 0.79), touch("b", x: 0.5, y: 0.79), touch("c", x: 0.7, y: 0.8, down: false)],
        // A new finger with the *recycled* identity "c" appears far away.
        [touch("a", x: 0.3, y: 0.79), touch("b", x: 0.5, y: 0.79), touch("c", x: 0.9, y: 0.2, began: true)]
    ]
    for frame in frames {
        if detector.handle(frame) { fired = true }
    }
    check(!fired, "a recycled identity does not produce a bogus distance")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
