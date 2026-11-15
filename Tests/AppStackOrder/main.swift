import AppKit

// Exercises the stacking-order helper with a synthetic window list, so the
// order the apps are put back in can be verified without hiding anything.
//
// The window list the system hands out is sorted from front to back, and
// that order is what the restore has to reproduce. The tests below use the
// same shape: a list of dictionaries with a `kCGWindowOwnerPID` key.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

/// Builds a fake window list entry for the given owner.
func window(pid: pid_t, layer: Int = 0) -> [String: Any] {
    [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer]
}

// The pure-value ordering, which is the part that matters.
let safari = AppStackOrder.App(processIdentifier: 100, bundleIdentifier: "com.apple.Safari")
let mail = AppStackOrder.App(processIdentifier: 200, bundleIdentifier: "com.apple.mail")
let notes = AppStackOrder.App(processIdentifier: 300, bundleIdentifier: "com.apple.Notes")
let terminal = AppStackOrder.App(processIdentifier: 400, bundleIdentifier: "com.apple.Terminal")
let all = [safari, mail, notes, terminal]

print("AppStackOrder")

// The window list is front-most first.
let frontToBack = [window(pid: 300), window(pid: 100), window(pid: 400), window(pid: 200)]
let ordered = AppStackOrder.frontToBack(apps: all, windowInfo: frontToBack)
check(
    ordered.map(\.bundleIdentifier) == ["com.apple.Notes", "com.apple.Safari", "com.apple.Terminal", "com.apple.mail"],
    "the apps come back in the order they were stacked"
)

// Several windows of the same app count once — the app's front-most window
// is the one that decides its place in the stack.
let repeated = [window(pid: 300), window(pid: 300), window(pid: 100)]
let orderedRepeated = AppStackOrder.frontToBack(apps: all, windowInfo: repeated)
check(
    orderedRepeated.map(\.bundleIdentifier) == ["com.apple.Notes", "com.apple.Safari", "com.apple.mail", "com.apple.Terminal"],
    "an app with several windows keeps the place of its front-most one"
)

// An app without a window on screen — minimized or hidden — sits behind
// everything that has one. Among themselves they keep the order they came
// in, because there is nothing on screen to tell them apart.
let withoutWindow = AppStackOrder.frontToBack(apps: all, windowInfo: [window(pid: 200)])
check(
    withoutWindow.map(\.bundleIdentifier) == ["com.apple.mail", "com.apple.Safari", "com.apple.Notes", "com.apple.Terminal"],
    "an app without a window goes to the back"
)

// A window belonging to an app that is not in the list is ignored.
let unknown = AppStackOrder.frontToBack(apps: all, windowInfo: [window(pid: 999), window(pid: 100)])
check(
    unknown.map(\.bundleIdentifier) == ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.Terminal"],
    "a window of an unknown app is ignored"
)

// Two sessions of the same app are two separate applications on screen, and
// each one has its own place in the stack. Keying the order by the bundle
// identifier would collapse them into one and lose the second one.
let rstudioOne = AppStackOrder.App(processIdentifier: 500, bundleIdentifier: "com.rstudio.desktop")
let rstudioTwo = AppStackOrder.App(processIdentifier: 501, bundleIdentifier: "com.rstudio.desktop")
let twoSessions = AppStackOrder.frontToBack(
    apps: all + [rstudioOne, rstudioTwo],
    windowInfo: [window(pid: 500), window(pid: 100), window(pid: 501)]
)
check(
    twoSessions.map(\.processIdentifier).filter { $0 == 500 || $0 == 501 } == [500, 501],
    "two sessions of the same app keep their own places in the stack"
)

// The same, with the order of the two reversed.
let twoSessionsReversed = AppStackOrder.frontToBack(
    apps: all + [rstudioOne, rstudioTwo],
    windowInfo: [window(pid: 501), window(pid: 100), window(pid: 500)]
)
check(
    twoSessionsReversed.map(\.processIdentifier).filter { $0 == 500 || $0 == 501 } == [501, 500],
    "two sessions of the same app keep their own places when reversed"
)

// An empty window list leaves the order alone.
let empty = AppStackOrder.frontToBack(apps: all, windowInfo: [])
check(
    empty.map(\.bundleIdentifier) == all.map(\.bundleIdentifier),
    "an empty window list keeps the original order"
)

// A menu bar item is not the app — it has no window the user would call
// "the app", and it sits on a higher layer than the real windows. Counting
// it would put an input method in front of everything.
let menuBarOnly = AppStackOrder.frontToBack(
    apps: all,
    windowInfo: [window(pid: 200, layer: 25), window(pid: 100)]
)
check(
    menuBarOnly.map(\.bundleIdentifier) == ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.Terminal"],
    "a menu bar item does not count as the app's window"
)

// The Dock and the control centre live on their own layers as well.
let systemChrome = AppStackOrder.frontToBack(
    apps: all,
    windowInfo: [window(pid: 300, layer: 20), window(pid: 100)]
)
check(
    systemChrome.map(\.bundleIdentifier) == ["com.apple.Safari", "com.apple.mail", "com.apple.Notes", "com.apple.Terminal"],
    "the Dock does not count as an app window"
)

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All checks passed.")
