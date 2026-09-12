import AppKit
import Foundation

/// CleanMyMac-style thorough uninstall: remove the .app plus common leftover files
/// matched primarily by bundle identifier (and exact app-name folders).
enum AppUninstallSupport {
    struct Plan {
        var appURL: URL
        var displayName: String
        var bundleID: String?
        var relatedURLs: [URL]
        var isProtectedSystemApp: Bool

        var allRemovalURLs: [URL] {
            ([appURL] + relatedURLs).map(\.standardizedFileURL)
        }
    }

    static func buildPlans(for appURLs: [URL]) -> [Plan] {
        appURLs.map { buildPlan(for: $0.standardizedFileURL) }
    }

    static func buildPlan(for appURL: URL) -> Plan {
        let standardized = appURL.standardizedFileURL
        let isAppBundle = standardized.pathExtension.lowercased() == "app"
        let displayName = isAppBundle
            ? standardized.deletingPathExtension().lastPathComponent
            : standardized.lastPathComponent
        let protected = isProtectedSystemApp(standardized)

        var bundleIDs: [String] = []
        if let bid = Bundle(url: standardized)?.bundleIdentifier, !bid.isEmpty {
            bundleIDs.append(bid)
        }
        let nestedApps = isAppBundle ? [] : nestedAppBundles(in: standardized)
        for nested in nestedApps {
            if let bid = Bundle(url: nested)?.bundleIdentifier, !bid.isEmpty, !bundleIDs.contains(bid) {
                bundleIDs.append(bid)
            }
        }

        var related: [URL] = []
        if !protected {
            var seen = Set<String>()
            func appendRelated(from urls: [URL]) {
                for url in urls {
                    let path = url.standardizedFileURL.path
                    guard path != standardized.path,
                          !path.hasPrefix(standardized.path + "/"),
                          !seen.contains(path) else { continue }
                    seen.insert(path)
                    related.append(url.standardizedFileURL)
                }
            }

            appendRelated(from: findRelatedFiles(appName: displayName, bundleID: bundleIDs.first))
            for bid in bundleIDs.dropFirst() {
                appendRelated(from: findRelatedFiles(appName: displayName, bundleID: bid))
            }
            for nested in nestedApps {
                let nestedName = nested.deletingPathExtension().lastPathComponent
                let nestedID = Bundle(url: nested)?.bundleIdentifier
                appendRelated(from: findRelatedFiles(appName: nestedName, bundleID: nestedID))
            }
            related.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }

        return Plan(
            appURL: standardized,
            displayName: displayName,
            bundleID: bundleIDs.first,
            relatedURLs: related,
            isProtectedSystemApp: protected
        )
    }

    /// Quit running instances, then permanently delete app + leftovers.
    static func performUninstall(_ plans: [Plan]) throws -> (removed: Int, failures: [(URL, String)]) {
        let removable = plans.filter { !$0.isProtectedSystemApp }
        for plan in removable {
            quitRunningInstances(bundleID: plan.bundleID)
            if plan.appURL.pathExtension.lowercased() != "app" {
                for nested in nestedAppBundles(in: plan.appURL) {
                    quitRunningInstances(bundleID: Bundle(url: nested)?.bundleIdentifier)
                }
            }
        }

        // Give apps a moment to terminate.
        Thread.sleep(forTimeInterval: 0.4)

        var removed = 0
        var failures: [(URL, String)] = []
        let fm = FileManager.default

        for plan in removable {
            for url in plan.allRemovalURLs {
                do {
                    if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                        removed += 1
                    }
                } catch {
                    failures.append((url, error.localizedDescription))
                }
            }
        }
        return (removed, failures)
    }

    // MARK: - Discovery

    /// Top-level and one-level-nested `.app` bundles inside an application folder.
    private static func nestedAppBundles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var apps: [URL] = []
        for child in children {
            if child.pathExtension.lowercased() == "app" {
                apps.append(child.standardizedFileURL)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let nested = try? fm.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in nested where item.pathExtension.lowercased() == "app" {
                apps.append(item.standardizedFileURL)
            }
        }
        return apps
    }

    private static func isProtectedSystemApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/System/")
            || path.hasPrefix("/Library/Apple/")
    }

    private static func quitRunningInstances(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            _ = running.terminate()
        }
    }

    private static func findRelatedFiles(appName: String, bundleID: String?) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path),
                  FileManager.default.fileExists(atPath: path) else { return }
            // Never touch these roots.
            if path == "/" || path == NSHomeDirectory() || path.hasSuffix("/Library") { return }
            seen.insert(path)
            found.append(url.standardizedFileURL)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let userLibrary = home.appendingPathComponent("Library", isDirectory: true)
        let systemLibrary = URL(fileURLWithPath: "/Library", isDirectory: true)

        let libraryRoots = [userLibrary, systemLibrary]

        for library in libraryRoots {
            // Exact path candidates from bundle ID.
            if let bid = bundleID, !bid.isEmpty {
                let exact: [URL] = [
                    library.appendingPathComponent("Preferences/\(bid).plist"),
                    library.appendingPathComponent("Caches/\(bid)", isDirectory: true),
                    library.appendingPathComponent("Application Support/\(bid)", isDirectory: true),
                    library.appendingPathComponent("Saved Application State/\(bid).savedState", isDirectory: true),
                    library.appendingPathComponent("Containers/\(bid)", isDirectory: true),
                    library.appendingPathComponent("Application Scripts/\(bid)", isDirectory: true),
                    library.appendingPathComponent("HTTPStorages/\(bid)", isDirectory: true),
                    library.appendingPathComponent("WebKit/\(bid)", isDirectory: true),
                    library.appendingPathComponent("Logs/\(bid)", isDirectory: true),
                    library.appendingPathComponent("LaunchAgents/\(bid).plist"),
                    library.appendingPathComponent("LaunchDaemons/\(bid).plist"),
                    library.appendingPathComponent("PrivilegedHelperTools/\(bid)"),
                    library.appendingPathComponent("PreferencePanes/\(bid).prefPane", isDirectory: true)
                ]
                exact.forEach(add)

                // Preferences ByHost: com.foo.bar.*.plist
                addMatchingChildren(
                    in: library.appendingPathComponent("Preferences/ByHost", isDirectory: true),
                    to: &found,
                    seen: &seen
                ) { name in
                    name.hasPrefix(bid + ".") || name == "\(bid).plist"
                }

                // Group Containers: TEAMID.bundleid or bundleid
                addMatchingChildren(
                    in: library.appendingPathComponent("Group Containers", isDirectory: true),
                    to: &found,
                    seen: &seen
                ) { name in
                    name == bid || name.hasSuffix(".\(bid)") || name.contains(bid)
                }

                // Caches / Logs / HTTPStorages sometimes use prefixes
                for folder in ["Caches", "Logs", "HTTPStorages", "WebKit", "Cookies"] {
                    addMatchingChildren(
                        in: library.appendingPathComponent(folder, isDirectory: true),
                        to: &found,
                        seen: &seen
                    ) { name in
                        name == bid || name.hasPrefix(bid + ".") || name.hasPrefix(bid + "-")
                    }
                }
            }

            // Exact app-name folders (avoid very short names).
            if appName.count >= 3 {
                let nameExact: [URL] = [
                    library.appendingPathComponent("Application Support/\(appName)", isDirectory: true),
                    library.appendingPathComponent("Caches/\(appName)", isDirectory: true),
                    library.appendingPathComponent("Logs/\(appName)", isDirectory: true),
                    library.appendingPathComponent("Preferences/\(appName).plist"),
                    library.appendingPathComponent("Saved Application State/\(appName).savedState", isDirectory: true)
                ]
                nameExact.forEach(add)

                // Case-insensitive exact folder match under Application Support / Caches.
                for folder in ["Application Support", "Caches", "Logs"] {
                    addMatchingChildren(
                        in: library.appendingPathComponent(folder, isDirectory: true),
                        to: &found,
                        seen: &seen
                    ) { name in
                        name.caseInsensitiveCompare(appName) == .orderedSame
                    }
                }
            }
        }

        return found
    }

    private static func addMatchingChildren(
        in directory: URL,
        to found: inout [URL],
        seen: inout Set<String>,
        predicate: (String) -> Bool
    ) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            guard predicate(name) else { continue }
            let path = child.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            found.append(child.standardizedFileURL)
        }
    }

    static func summaryText(for plans: [Plan]) -> String {
        let apps = plans.count
        let related = plans.reduce(0) { $0 + $1.relatedURLs.count }
        let protected = plans.filter(\.isProtectedSystemApp)
        var lines: [String] = []
        lines.append("将永久删除 \(apps) 个项目及其关联文件（共 \(related) 项残留），无法从废纸篓恢复。")
        lines.append("")
        for plan in plans.prefix(8) {
            if plan.isProtectedSystemApp {
                lines.append("• \(plan.displayName) — 系统应用，已跳过")
            } else {
                lines.append("• \(plan.displayName)：应用 + \(plan.relatedURLs.count) 项残留")
            }
        }
        if plans.count > 8 {
            lines.append("…")
        }
        if !protected.isEmpty {
            lines.append("")
            lines.append("系统自带应用不会被卸载。")
        }
        return lines.joined(separator: "\n")
    }
}
