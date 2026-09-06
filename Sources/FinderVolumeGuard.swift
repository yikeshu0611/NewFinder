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

    /// AppleScript: list POSIX paths of all Finder window targets.
    static let listWindowTargetsScript = """
    tell application "Finder"
      set output to ""
      try
        repeat with w in Finder windows
          try
            set output to output & POSIX path of ((target of w) as alias) & linefeed
          end try
        end repeat
      end try
      return output
    end tell
    """

    /// Close only non-/Volumes/ windows (safe while a DMG mount is still appearing).
    static let closeNonVolumeWindowsScript = """
    tell application "Finder"
      try
        repeat with w in (get every Finder window)
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
