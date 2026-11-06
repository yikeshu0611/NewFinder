import AppKit

/// The direction of a three-finger swipe on the trackpad.
enum SwipeDirection {
    /// The fingers moved towards the top of the trackpad.
    case up
    /// The fingers moved towards the bottom of the trackpad.
    case down
}

/// The decision logic of the three-finger swipe gesture, kept free of AppKit
/// and of any event plumbing so it can be reasoned about (and tested) on its
/// own.
///
/// The rules it encodes come from how macOS delivers gesture frames:
///
/// * A frame carries only the touches that **changed**, so the finger count has
///   to be tracked across frames — counting per frame makes it flicker.
/// * `NSTouch.identity` is only unique *while the touch is down*. Identities
///   are recycled, so a start position left behind by a lifted finger would be
///   picked up by an unrelated finger later and produce a meaningless — usually
///   off-axis — distance.
/// * `normalizedPosition` has a bottom-left origin, so a swipe *down* is a
///   **negative** y change and a swipe *up* a **positive** one.
struct SwipeDetector {

    /// One finger of the current gesture, reduced to what detection needs.
    struct Touch {
        /// Identifies the touch while it is down. Never valid across gestures.
        let id: String
        /// Position on the trackpad surface, or `nil` when it could not be read.
        let position: NSPoint?
        /// `phase == .began` — the system saying this finger is new.
        let isBegan: Bool
        /// The finger is on the pad (`.began`, `.moved` or `.stationary`).
        let isDown: Bool
    }

    /// Travel required before the gesture fires, as a fraction of the trackpad
    /// surface. macOS's own three-finger Space swipe waits for a small distance
    /// too; imitating it keeps the gesture from firing on a stray tap.
    static let minSwipeDistance: CGFloat = 0.02

    /// Travelling this far *across* the gesture's axis cancels the gesture until
    /// the fingers are lifted. A diagonal drag is a horizontal gesture, not this
    /// one.
    static let maxSwipeDistanceInWrongDirection: CGFloat = 0.08

    /// How many fingers the gesture needs.
    static let requiredFingers = 3

    /// Start position of every finger currently down, keyed by identity.
    private var startPositions: [String: NSPoint] = [:]
    /// Whether the current finger-down session already travelled far enough
    /// off-axis to cancel the gesture.
    private var swipeStillPossible = true
    /// Set while the gesture fires so a single swipe cannot fire twice.
    private var didFire = false

    /// Feeds one frame of touches in and reports the direction of the gesture
    /// when it fires, or `nil` while the gesture is still inconclusive.
    mutating func handle(_ touches: [Touch]) -> SwipeDirection? {
        let down = touches.filter { $0.isDown }
        let fingersDown = down.count

        // A single finger is pointer mode — not a gesture. End the session.
        guard fingersDown > 1 else {
            reset()
            return nil
        }

        // Forget fingers that left the pad. Identities are recycled, so a stale
        // start position would otherwise be picked up by an unrelated finger
        // later and produce a bogus, usually off-axis, distance.
        let downIDs = Set(down.map { $0.id })
        if startPositions.keys.contains(where: { !downIDs.contains($0) }) {
            startPositions = startPositions.filter { downIDs.contains($0.key) }
        }

        // A new finger joined, or a finger has no start position yet (it joined
        // a gesture already under way): re-base, so the distance is measured
        // from here on.
        let isNew = touches.contains { $0.isBegan } || down.contains { startPositions[$0.id] == nil }
        if isNew {
            for touch in down {
                if let position = touch.position {
                    startPositions[touch.id] = position
                }
            }
            if fingersDown != Self.requiredFingers {
                // Not the finger count we want. The start positions are reset
                // above, but an off-axis wander from a previous attempt in this
                // session is *not* forgiven — only raising the fingers clears
                // that.
                didFire = false
            } else {
                // All three fingers are down and at least one of them is new —
                // this is the beginning of a fresh gesture, so the previous
                // one may fire again. Without this the detector would stay
                // latched after a single swipe and never report the next one.
                didFire = false
                swipeStillPossible = true
            }
        }

        guard fingersDown == Self.requiredFingers else { return nil }
        guard !didFire, swipeStillPossible else { return nil }

        // Measure the travel of every finger since the gesture began.
        var distances: [NSPoint] = []
        for touch in down {
            guard let position = touch.position, let start = startPositions[touch.id] else { continue }
            distances.append(NSPoint(x: position.x - start.x, y: position.y - start.y))
        }
        guard !distances.isEmpty else { return nil }

        for distance in distances {
            if abs(distance.x) >= Self.maxSwipeDistanceInWrongDirection {
                // Travelled sideways — this is not our gesture.
                swipeStillPossible = false
                return nil
            }
        }
        guard distances.allSatisfy({ abs($0.y) >= Self.minSwipeDistance }) else { return nil }

        // All the fingers have to travel the *same* way, otherwise the gesture
        // is a scuffle rather than a swipe.
        let allUp = distances.allSatisfy { $0.y > 0 }
        let allDown = distances.allSatisfy { $0.y < 0 }
        guard allUp || allDown else { return nil }

        // Swipe confirmed.
        didFire = true
        return allUp ? .up : .down
    }

    /// Clears all state, so the next gesture starts clean.
    mutating func reset() {
        startPositions.removeAll()
        swipeStillPossible = true
        didFire = false
    }
}
