import AppKit

// Exercises SwipeDetector with synthetic touch frames, so the gesture
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

typealias Touch = SwipeDetector.Touch

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

/// A three-finger swipe up: fingers start low (y small) and move to high y.
func swipeUpFrames() -> [[Touch]] {
    [
        [touch("a", x: 0.3, y: 0.2, began: true), touch("b", x: 0.5, y: 0.2, began: true), touch("c", x: 0.7, y: 0.2, began: true)],
        [touch("a", x: 0.3, y: 0.25), touch("b", x: 0.5, y: 0.25), touch("c", x: 0.7, y: 0.25)],
        [touch("a", x: 0.3, y: 0.35), touch("b", x: 0.5, y: 0.35), touch("c", x: 0.7, y: 0.35)]
    ]
}

/// Feeds frames in and returns the direction the gesture fired with.
func direction(of frames: [[Touch]]) -> SwipeDirection? {
    var detector = SwipeDetector()
    for frame in frames {
        if let fired = detector.handle(frame) { return fired }
    }
    return nil
}

print("== three-finger swipe down fires ==")
do {
    check(direction(of: swipeDownFrames()) == .down, "the gesture fires downward when three fingers move down")
}

print("== three-finger swipe up fires ==")
do {
    check(direction(of: swipeUpFrames()) == .up, "the gesture fires upward when three fingers move up")
}

print("== it fires only once per swipe ==")
do {
    var detector = SwipeDetector()
    var count = 0
    for frame in swipeDownFrames() {
        if detector.handle(frame) != nil { count += 1 }
    }
    // A fourth frame continuing the same swipe must not fire again.
    if detector.handle([touch("a", x: 0.3, y: 0.55), touch("b", x: 0.5, y: 0.55), touch("c", x: 0.7, y: 0.55)]) != nil {
        count += 1
    }
    check(count == 1, "the gesture fires exactly once (fired \(count)x)")
}

print("== two fingers do not fire ==")
do {
    var detector = SwipeDetector()
    var fired = false
    for frame in swipeDownFrames() {
        let two = Array(frame.prefix(2))
        if detector.handle(two) != nil { fired = true }
    }
    check(!fired, "two fingers never fire the gesture")
}

print("== four fingers do not fire ==")
do {
    var detector = SwipeDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.2, y: 0.8, began: true), touch("b", x: 0.4, y: 0.8, began: true), touch("c", x: 0.6, y: 0.8, began: true), touch("d", x: 0.8, y: 0.8, began: true)],
        [touch("a", x: 0.2, y: 0.65), touch("b", x: 0.4, y: 0.65), touch("c", x: 0.6, y: 0.65), touch("d", x: 0.8, y: 0.65)]
    ]
    for frame in frames {
        if detector.handle(frame) != nil { fired = true }
    }
    check(!fired, "four fingers never fire the gesture")
}

print("== a sideways swipe does not fire ==")
do {
    var detector = SwipeDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.5, began: true), touch("b", x: 0.5, y: 0.5, began: true), touch("c", x: 0.7, y: 0.5, began: true)],
        [touch("a", x: 0.5, y: 0.5), touch("b", x: 0.7, y: 0.5), touch("c", x: 0.9, y: 0.5)]
    ]
    for frame in frames {
        if detector.handle(frame) != nil { fired = true }
    }
    check(!fired, "swiping sideways never fires the gesture")
}

print("== a tiny movement does not fire ==")
do {
    var detector = SwipeDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.5, began: true), touch("b", x: 0.5, y: 0.5, began: true), touch("c", x: 0.7, y: 0.5, began: true)],
        [touch("a", x: 0.3, y: 0.495), touch("b", x: 0.5, y: 0.495), touch("c", x: 0.7, y: 0.495)]
    ]
    for frame in frames {
        if detector.handle(frame) != nil { fired = true }
    }
    check(!fired, "a movement below the threshold never fires the gesture")
}

print("== a finger joining mid-swipe re-bases the measurement ==")
do {
    var detector = SwipeDetector()
    var fired: SwipeDirection?
    let frames: [[Touch]] = [
        // Two fingers first.
        [touch("a", x: 0.3, y: 0.8, began: true), touch("b", x: 0.5, y: 0.8, began: true)],
        // A third joins — the measurement restarts from here.
        [touch("a", x: 0.3, y: 0.75), touch("b", x: 0.5, y: 0.75), touch("c", x: 0.7, y: 0.75, began: true)],
        // Now they travel down together.
        [touch("a", x: 0.3, y: 0.6), touch("b", x: 0.5, y: 0.6), touch("c", x: 0.7, y: 0.6)]
    ]
    for frame in frames {
        if let d = detector.handle(frame) { fired = d }
    }
    check(fired == .down, "a three-finger swipe still fires when the third finger joins late")
}

print("== lifting the fingers re-arms the gesture ==")
do {
    var detector = SwipeDetector()
    // First swipe fires.
    for frame in swipeDownFrames() { _ = detector.handle(frame) }
    // All fingers lift.
    _ = detector.handle([touch("a", x: 0.3, y: 0.65, down: false)])
    // A second swipe fires again.
    var fired: SwipeDirection?
    for frame in swipeUpFrames() {
        if let d = detector.handle(frame) { fired = d }
    }
    check(fired == .up, "a second swipe after lifting the fingers fires again")
}

print("== a lifted finger's stale position is not reused ==")
do {
    var detector = SwipeDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.8, began: true), touch("b", x: 0.5, y: 0.8, began: true), touch("c", x: 0.7, y: 0.8, began: true)],
        // Finger "c" lifts; "a" and "b" move only slightly.
        [touch("a", x: 0.3, y: 0.79), touch("b", x: 0.5, y: 0.79), touch("c", x: 0.7, y: 0.8, down: false)],
        // A new finger with the *recycled* identity "c" appears far away.
        [touch("a", x: 0.3, y: 0.79), touch("b", x: 0.5, y: 0.79), touch("c", x: 0.9, y: 0.2, began: true)]
    ]
    for frame in frames {
        if detector.handle(frame) != nil { fired = true }
    }
    check(!fired, "a recycled identity does not produce a bogus distance")
}

print("== fingers moving in opposite directions do not fire ==")
do {
    var detector = SwipeDetector()
    var fired = false
    let frames: [[Touch]] = [
        [touch("a", x: 0.3, y: 0.5, began: true), touch("b", x: 0.5, y: 0.5, began: true), touch("c", x: 0.7, y: 0.5, began: true)],
        // "a" and "b" go up, "c" goes down.
        [touch("a", x: 0.3, y: 0.6), touch("b", x: 0.5, y: 0.6), touch("c", x: 0.7, y: 0.4)]
    ]
    for frame in frames {
        if detector.handle(frame) != nil { fired = true }
    }
    check(!fired, "fingers travelling in opposite directions never fire the gesture")
}

print("== the two directions are independent ==")
do {
    // A swipe down followed by a swipe up must report both, in order.
    var detector = SwipeDetector()
    var seen: [SwipeDirection] = []
    for frame in swipeDownFrames() {
        if let d = detector.handle(frame) { seen.append(d) }
    }
    for frame in swipeUpFrames() {
        if let d = detector.handle(frame) { seen.append(d) }
    }
    check(seen == [.down, .up], "a swipe down then a swipe up reports both directions (got \(seen))")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
