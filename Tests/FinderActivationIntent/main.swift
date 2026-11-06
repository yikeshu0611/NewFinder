import AppKit

// Exercises the pure parts of FinderActivationIntent — the coordinate
// conversion and the classification decision — so they can be verified
// without a live Finder or a physical click.

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

typealias Intent = FinderActivationIntent.Intent
typealias Hit = FinderActivationIntent.Hit

/// The display size used in the tests.
let display = CGSize(width: 1352, height: 878)

/// A hit on a desktop icon — the AXImage of a 56×56 icon.
let desktopIcon = Hit(role: "AXImage", subrole: "", frame: CGRect(x: 168, y: 42, width: 56, height: 56))
/// A hit on the blank desktop — the full-screen container.
let desktopBackground = Hit(role: "AXGroup", subrole: "", frame: CGRect(x: 0, y: 0, width: 1352, height: 878))
/// A hit on a Dock item.
let dockItem = Hit(role: "AXDockItem", subrole: "AXApplicationDockItem", frame: CGRect(x: 1299, y: 414, width: 43, height: 34))
/// A hit on a Finder window's file list.
let finderList = Hit(role: "AXCell", subrole: "", frame: CGRect(x: 100, y: 200, width: 80, height: 22))

print("== a click on the blank desktop is not redirected ==")
do {
    let intent = FinderActivationIntent.intent(
        dockHit: nil,
        finderHit: desktopBackground,
        displaySize: display
    )
    check(intent == .blankDesktop, "the full-screen desktop container is the blank desktop")
}

print("== a click on a desktop icon is redirected ==")
do {
    let intent = FinderActivationIntent.intent(
        dockHit: nil,
        finderHit: desktopIcon,
        displaySize: display
    )
    check(intent == .content, "a desktop icon counts as content, so the redirect follows through")
}

print("== a click on the Dock is redirected ==")
do {
    let intent = FinderActivationIntent.intent(
        dockHit: dockItem,
        finderHit: desktopBackground,
        displaySize: display
    )
    check(intent == .dock, "a Dock item wins over the desktop underneath it")
}

print("== a click in a Finder window is redirected ==")
do {
    let intent = FinderActivationIntent.intent(
        dockHit: nil,
        finderHit: finderList,
        displaySize: display
    )
    check(intent == .content, "a cell inside a Finder window counts as content")
}

print("== without a hit test the old behaviour is kept ==")
do {
    let intent = FinderActivationIntent.intent(
        dockHit: nil,
        finderHit: nil,
        displaySize: display
    )
    check(intent == .content, "a missing hit test falls back to content")
}

print("== a container that does not cover the screen is not the blank desktop ==")
do {
    // A group that only covers part of the screen — a desktop folder's
    // selection rectangle, or a small overlay window.
    let small = Hit(role: "AXGroup", subrole: "", frame: CGRect(x: 10, y: 10, width: 200, height: 200))
    let intent = FinderActivationIntent.intent(
        dockHit: nil,
        finderHit: small,
        displaySize: display
    )
    check(intent == .content, "a small group is content, not the desktop background")
}

print("== a large cell is a list, not an icon ==")
do {
    let bigCell = Hit(role: "AXCell", subrole: "", frame: CGRect(x: 100, y: 100, width: 400, height: 300))
    let intent = FinderActivationIntent.intent(
        dockHit: nil,
        finderHit: bigCell,
        displaySize: display
    )
    check(intent == .content, "a large cell is content, not a desktop icon")
}

print("== Cocoa and Quartz coordinates are converted correctly ==")
do {
    // The Quartz y is the distance from the top of the primary display.
    let top = FinderActivationIntent.quartzLocation(cocoa: NSPoint(x: 10, y: 878), primaryMaxY: 878)
    check(top.y == 0, "the top of the screen is Quartz y = 0 (got \(top.y))")

    let bottom = FinderActivationIntent.quartzLocation(cocoa: NSPoint(x: 10, y: 0), primaryMaxY: 878)
    check(bottom.y == 878, "the bottom of the screen is Quartz y = 878 (got \(bottom.y))")

    let middle = FinderActivationIntent.quartzLocation(cocoa: NSPoint(x: 10, y: 439), primaryMaxY: 878)
    check(middle.y == 439, "the middle of the screen keeps its value (got \(middle.y))")

    let x = FinderActivationIntent.quartzLocation(cocoa: NSPoint(x: 123, y: 100), primaryMaxY: 878)
    check(x.x == 123, "the x axis is not flipped (got \(x.x))")
}

print("== the conversion round-trips ==")
do {
    for quartzY in stride(from: 0.0, through: 878.0, by: 97.0) {
        let cocoa = NSPoint(x: 42, y: 878 - quartzY)
        let back = FinderActivationIntent.quartzLocation(cocoa: cocoa, primaryMaxY: 878)
        if abs(back.y - quartzY) > 0.001 {
            check(false, "round trip failed for y = \(quartzY) (got \(back.y))")
            break
        }
    }
    check(true, "every point survives the Quartz -> Cocoa -> Quartz round trip")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
