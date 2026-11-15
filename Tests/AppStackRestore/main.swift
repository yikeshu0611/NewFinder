import AppKit

// Exercises the restore-order helper, so the order the apps are put back in
// can be verified without hiding anything.
//
// The problem the helper solves: `unhide()` brings an app back on screen,
// but not in the order it was in. A probe showed the order coming back
// scrambled — so the order has to be forced afterwards.
//
// The tests below use plain values in place of the applications: the helper
// only ever passes them around, and the activation is what is replaced in
// the test.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

print("AppStackRestore")

// The order the apps are brought forward in decides the final order: the app
// brought forward last ends up in front. So the apps are brought forward
// back-to-front.
let front = ["A", "B", "C"]
check(
    AppStackRestore.raiseOrder(frontToBack: front) == ["C", "B", "A"],
    "the apps are brought forward back-to-front, so the front-most one ends up on top"
)

// A single app is brought forward on its own.
check(
    AppStackRestore.raiseOrder(frontToBack: ["A"]) == ["A"],
    "a single app is brought forward on its own"
)

// Nothing to restore is nothing to do.
check(
    AppStackRestore.raiseOrder(frontToBack: [String]()) == [],
    "an empty list brings nothing forward"
)

// Two sessions of the same app are two separate entries — they are tracked
// by their process identifier, not by their bundle identifier.
let rstudioOne = "RStudio#500"
let rstudioTwo = "RStudio#501"
check(
    AppStackRestore.raiseOrder(frontToBack: [rstudioOne, "WPS", rstudioTwo]) == [rstudioTwo, "WPS", rstudioOne],
    "two sessions of the same app keep their own places in the order"
)

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All checks passed.")
