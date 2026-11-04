import AppKit
import Foundation

/// Leave system Finder alone for DMG installers / external volumes under `/Volumes/`.
enum FinderVolumeGuard {
    static func pathLooksLikeMountedVolume(_ path: String) -> Bool {
        var p = path
        while p.count > 1, p.hasSuffix("/") {
            p = String(p.dropLast())
        }
        return p == "/Volumes" || p.hasPrefix("/Volumes/")
    }

    static func urlLooksLikeMountedVolume(_ url: URL) -> Bool {
        pathLooksLikeMountedVolume(url.standardizedFileURL.path)
    }

    /// Fast filesystem check — no AppleScript. False → skip volume guards entirely.
    static func hasMountedVolumes() -> Bool {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.contains { pathLooksLikeMountedVolume($0.path) }
    }

    /// True if any path is on a mounted volume (DMG, USB, network share under /Volumes).
    static func pathsInvolveMountedVolume(_ paths: [String]) -> Bool {
        paths.contains { pathLooksLikeMountedVolume($0) }
    }

    static func urlsInvolveMountedVolume(_ urls: [URL]) -> Bool {
        urls.contains { url in
            urlLooksLikeMountedVolume(url)
                || urlLooksLikeMountedVolume(url.deletingLastPathComponent())
        }
    }

    /// Snapshot of what Finder currently shows.
    struct FinderState {
        /// POSIX paths of the current Finder selection.
        var selection: [String] = []
        /// POSIX path of the front Finder window's target.
        var frontDirectory: String?
        /// POSIX paths of every open Finder window's target.
        var windowTargets: [String] = []

        var isEmpty: Bool { selection.isEmpty && frontDirectory == nil }
    }

    // MARK: - AppleScript

    /// Shared body of the two Finder scripts below.
    ///
    /// IMPORTANT: windows are always enumerated with `get every Finder window`
    /// (a snapshot) and never with the live `repeat with w in Finder windows`
    /// iterator — the live iterator re-resolves the window collection on every
    /// step and blocks on Finder's main thread for more than a second while
    /// Finder is busy opening a window.
    private static let readBody = """
      set out to ""
      try
        set sel to the selection
        if (count of sel) > 0 then
          repeat with s in sel
            try
              set out to out & "SEL " & (POSIX path of (s as alias)) & linefeed
            end try
          end repeat
        end if
      end try
      try
        if (count of Finder windows) > 0 then
          set out to out & "DIR " & (POSIX path of ((target of front Finder window) as alias)) & linefeed
        end if
      end try
      set winOut to ""
      set sawVolume to false
      try
        set ws to (get every Finder window)
        repeat with w in ws
          try
            set p to POSIX path of ((target of w) as alias)
            set winOut to winOut & "WIN " & p & linefeed
            if p starts with "/Volumes/" then set sawVolume to true
          end try
        end repeat
      end try
    """

    /// Read everything NF needs from Finder in ONE round trip:
    ///   `SEL <path>` — each selected item
    ///   `DIR <path>` — target of the front Finder window
    ///   `WIN <path>` — target of every open Finder window
    ///
    /// The `with timeout` guard keeps a busy or unresponsive Finder from
    /// stalling the hand-off: the script gives up and the caller falls back to
    /// the slower-but-safe path.
    static let readFinderStateScript = """
    with timeout of 2 seconds
      tell application "Finder"
        \(readBody)
        return out & winOut
      end tell
    end timeout
    """

    /// Same as `readFinderStateScript`, but also closes every Finder window that
    /// is not on a mounted volume — still a single round trip.
    ///
    /// Windows on `/Volumes/` are left alone, and if any such window exists
    /// nothing is closed at all (a DMG / USB window must survive).
    static let readAndCloseFinderStateScript = """
    with timeout of 2 seconds
      tell application "Finder"
        \(readBody)
        if sawVolume is false then
          try
            set ws2 to (get every Finder window)
            repeat with w in ws2
              try
                set p to POSIX path of ((target of w) as alias)
                if p does not start with "/Volumes/" then
                  close w
                end if
              end try
            end repeat
          end try
        end if
        return out & winOut
      end tell
    end timeout
    """

    /// Parse the output of `readFinderStateScript` / `readAndCloseFinderStateScript`.
    static func parseFinderState(_ raw: String?) -> FinderState {
        var state = FinderState()
        guard let raw, !raw.isEmpty else { return state }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("SEL "), line.count > 4 {
                state.selection.append(String(line.dropFirst(4)))
            } else if line.hasPrefix("DIR "), line.count > 4 {
                state.frontDirectory = String(line.dropFirst(4))
            } else if line.hasPrefix("WIN "), line.count > 4 {
                state.windowTargets.append(String(line.dropFirst(4)))
            }
        }
        return state
    }

    /// Close only non-/Volumes/ windows (safe while a DMG mount is still appearing).
    static let closeNonVolumeWindowsScript = """
    tell application "Finder"
      try
        set ws to (get every Finder window)
        repeat with w in ws
          try
            set p to POSIX path of ((target of w) as alias)
            if p does not start with "/Volumes/" then
              close w
            end if
          end try
        end repeat
      end try
    end tell
    """

    static func windowTargetsInvolveMountedVolume(scriptResult: String?) -> Bool {
        guard let raw = scriptResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let paths = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return pathsInvolveMountedVolume(paths)
    }
}
