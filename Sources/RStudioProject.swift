import AppKit

/// Works out which RStudio project a running RStudio has open.
///
/// RStudio shows the project name in its window title — "seerR - RStudio" —
/// but that is only a hint: the title also shows the modified-file marker
/// and the RStudio version in some states. So the title is used to *narrow
/// the search down*, and the actual project is confirmed by looking for a
/// `.Rproj` file with that name.
///
/// The window title is read through the accessibility API, which needs the
///「辅助功能」permission. When it is missing the plain application name is
/// used — a missing project name is much better than a wrong one.
enum RStudioProject {

    /// The bundle identifiers RStudio ships under.
    static let bundleIdentifiers = [
        "com.rstudio.desktop",
        "org.posit.rstudio",
        "com.posit.rstudio",
    ]

    /// True when the running application is RStudio.
    static func isRStudio(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundleIdentifier)
            || bundleIdentifier.contains("rstudio")
            || bundleIdentifier.contains("posit")
    }

    /// The name of the project a running RStudio has open, if it can be
    /// worked out.
    ///
    /// - Parameter application: the running RStudio.
    /// - Returns: the project name, or `nil` when it cannot be determined.
    static func projectName(for application: NSRunningApplication) -> String? {
        let candidates = titleCandidates(for: application)
        guard !candidates.isEmpty else { return nil }

        // The title is a hint; the project file is the truth. Looking the
        // name up among the known projects makes sure that a window title
        // like "RStudio" does not turn into a bogus project name.
        for name in candidates {
            if let url = projectURL(named: name) {
                return url.deletingPathExtension().lastPathComponent
            }
        }
        return candidates.first
    }

    /// The possible project names, taken from the window titles.
    ///
    /// RStudio's title is "<project> - RStudio", so the project name is
    /// everything in front of the separator.
    private static func titleCandidates(for application: NSRunningApplication) -> [String] {
        var names: [String] = []

        for title in windowTitles(of: application) {
            // "seerR - RStudio" → "seerR"
            let head = title.components(separatedBy: " - ").first ?? title
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // A title that names an open file rather than a project
            // ("script.R - RStudio") is not a project name. A title that is
            // just "RStudio" means no project is open at all.
            guard trimmed != "RStudio", !trimmed.hasSuffix(".R") else { continue }
            names.append(trimmed)
        }

        // The same name twice is just noise.
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The titles of the windows of an application, read through the
    /// accessibility API.
    private static func windowTitles(of application: NSRunningApplication) -> [String] {
        let axApp = AXUIElementCreateApplication(application.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let list = value as? [AXUIElement] else {
            return []
        }

        var titles: [String] = []
        for window in list {
            var titleValue: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            if titleResult == .success, let title = titleValue as? String, !title.isEmpty {
                titles.append(title)
            }
        }
        return titles
    }

    /// Looks for a `.Rproj` file with the given name in the places RStudio
    /// keeps its projects.
    ///
    /// The search is deliberately bounded — the project list is short, and
    /// walking the whole disk would be far too slow for a window that has to
    /// open instantly. Two levels are searched, which covers the usual
    /// "~/Desktop/<group>/<project>/<project>.Rproj" layout.
    static func projectURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home,
            home.appendingPathComponent("Downloads"),
        ]

        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                // "<name>.Rproj" sitting right in the root.
                let candidate = entry.appendingPathComponent("\(name).Rproj")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }

                guard isDirectory(entry) else { continue }

                // One level down — "~/Desktop/myselfR/seerR.Rproj".
                let nested = entry.appendingPathComponent("\(name).Rproj")
                if fileManager.fileExists(atPath: nested.path) {
                    return nested
                }

                // Two levels down — "~/Desktop/myselfR/seerR/seerR.Rproj".
                guard let children = try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children where isDirectory(child) {
                    let deeper = child.appendingPathComponent("\(name).Rproj")
                    if fileManager.fileExists(atPath: deeper.path) {
                        return deeper
                    }
                }
            }
        }
        return nil
    }

    /// True when the URL points at a directory.
    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// The display name for a running RStudio, with its project.
    ///
    /// "RStudio" on its own when the project cannot be found.
    static func displayName(for application: NSRunningApplication) -> String {
        let base = application.localizedName ?? "RStudio"
        guard let project = projectName(for: application) else { return base }
        return "\(base) — \(project)"
    }
}
