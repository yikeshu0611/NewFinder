import Foundation

/// macOS ships its own three-finger vertical swipe — the one that opens Mission
/// Control (swipe up) and App Exposé (swipe down).
///
/// That built-in gesture is recognised by the window server *before* any event
/// tap ever sees the frames, so it fires together with ours and the two fight
/// over the same swipe: Mission Control opens and the app never gets to act.
/// The built-in gesture therefore has to be turned off for the swipe up to
/// work at all.
///
/// The previous value is remembered so it can be put back when the feature is
/// switched off again — the user must not be left with a changed system
/// setting they cannot undo.
enum TrackpadGesturePreferences {

    /// The preference domains that hold the setting. There is one for the
    /// built-in trackpad and one for Bluetooth ones, and both have to agree.
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]

    /// The key that switches the three-finger vertical swipe on and off.
    ///
    /// `0` = off, `2` = on.
    private static let key = "TrackpadThreeFingerVertSwipeGesture"

    /// Where the original value is kept, so it can be restored.
    private static let savedValueKey = "savedSystemThreeFingerVertSwipeGesture"

    /// True when macOS's own three-finger vertical swipe is currently on.
    static var isSystemGestureEnabled: Bool {
        for domain in domains {
            let value = UserDefaults(suiteName: domain)?.integer(forKey: key) ?? 0
            if value != 0 { return true }
        }
        return false
    }

    /// Turns the built-in gesture off and remembers the value it had.
    ///
    /// - Returns: `true` when something was changed.
    @discardableResult
    static func disableSystemGesture() -> Bool {
        // Remember the current value only the first time, so repeated calls do
        // not overwrite the original with the already-disabled `0`.
        if UserDefaults.standard.object(forKey: savedValueKey) == nil {
            let current = UserDefaults(suiteName: domains[0])?.integer(forKey: key) ?? 0
            UserDefaults.standard.set(current, forKey: savedValueKey)
        }

        var changed = false
        for domain in domains {
            guard let defaults = UserDefaults(suiteName: domain) else { continue }
            guard defaults.integer(forKey: key) != 0 else { continue }
            defaults.set(0, forKey: key)
            changed = true
        }
        return changed
    }

    /// Puts the built-in gesture back the way it was before we touched it.
    ///
    /// - Returns: `true` when something was changed.
    @discardableResult
    static func restoreSystemGesture() -> Bool {
        guard let saved = UserDefaults.standard.object(forKey: savedValueKey) as? Int else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: savedValueKey)

        var changed = false
        for domain in domains {
            guard let defaults = UserDefaults(suiteName: domain) else { continue }
            guard defaults.integer(forKey: key) != saved else { continue }
            defaults.set(saved, forKey: key)
            changed = true
        }
        return changed
    }
}
