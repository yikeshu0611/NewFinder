import AppKit
import UniformTypeIdentifiers

enum OpenWithCatalog {
    struct AppInfo: Hashable {
        let url: URL
        let name: String
        let bundleIdentifier: String?

        var identity: String {
            bundleIdentifier ?? url.standardizedFileURL.path
        }
    }

    /// Apps under Applications folders, deduped by bundle id (prefer /Applications).
    static func allInstalledApps() -> [AppInfo] {
        let fm = FileManager.default
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        var candidates: [URL] = []
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            guard let apps = try? fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in apps where url.pathExtension.lowercased() == "app" {
                candidates.append(url.standardizedFileURL)
            }
            for url in apps {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if url.pathExtension.lowercased() == "app" { continue }
                if let nested = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    for child in nested where child.pathExtension.lowercased() == "app" {
                        candidates.append(child.standardizedFileURL)
                    }
                }
            }
        }

        return dedupe(candidates)
    }

    static func dedupe(_ urls: [URL]) -> [AppInfo] {
        var best: [String: AppInfo] = [:]
        for url in urls {
            let name = FileManager.default.displayName(atPath: url.path)
            let bid = Bundle(url: url)?.bundleIdentifier
            let info = AppInfo(url: url, name: name, bundleIdentifier: bid)
            let key = info.identity
            if let existing = best[key] {
                if prefer(info.url, over: existing.url) {
                    best[key] = info
                }
            } else {
                best[key] = info
            }
        }
        return Array(best.values)
    }

    private static func prefer(_ lhs: URL, over rhs: URL) -> Bool {
        func rank(_ url: URL) -> Int {
            let p = url.path
            if p.hasPrefix("/Applications/") { return 0 }
            if p.hasPrefix(NSHomeDirectory() + "/Applications/") { return 1 }
            if p.hasPrefix("/System/Applications/") { return 2 }
            return 3
        }
        let lr = rank(lhs)
        let rr = rank(rhs)
        if lr != rr { return lr < rr }
        return lhs.path.count < rhs.path.count
    }

    static func disambiguatedName(for app: AppInfo, among apps: [AppInfo]) -> String {
        let sameName = apps.filter { $0.name.caseInsensitiveCompare(app.name) == .orderedSame }
        guard sameName.count > 1 else { return app.name }
        let parent = app.url.deletingLastPathComponent().lastPathComponent
        if !parent.isEmpty, parent != "Applications", parent != "Utilities" {
            return "\(app.name)（\(parent)）"
        }
        return app.name
    }

    static func defaultApp(for fileURL: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: fileURL)?.standardizedFileURL
    }

    static func setDefaultApp(_ appURL: URL, for fileURLs: [URL], completion: ((Error?) -> Void)? = nil) {
        guard let primary = fileURLs.first else {
            completion?(nil)
            return
        }

        let bid = Bundle(url: appURL)?.bundleIdentifier
        let remember = {
            AppSettings.shared.rememberOpenWithApp(
                bundleID: bid ?? "",
                path: appURL.path,
                forFile: primary
            )
            AppSettings.shared.rememberOpenWithDefaultApp(
                bundleID: bid ?? "",
                path: appURL.path
            )
        }

        if let type = try? primary.resourceValues(forKeys: [.contentTypeKey]).contentType {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                DispatchQueue.main.async {
                    if error == nil { remember() }
                    completion?(error)
                }
            }
            return
        }

        if let type = UTType(filenameExtension: primary.pathExtension) {
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
                DispatchQueue.main.async {
                    if error == nil { remember() }
                    completion?(error)
                }
            }
            return
        }

        if let bid, let type = UTType(filenameExtension: primary.pathExtension) {
            LSSetDefaultRoleHandlerForContentType(
                type.identifier as CFString,
                LSRolesMask.all,
                bid as CFString
            )
            remember()
        }
        completion?(nil)
    }

    /// Resolve an installed app from a stored bundle id or path.
    static func appInfo(forHistoryKey key: String) -> AppInfo? {
        if key.hasPrefix("/") {
            let url = URL(fileURLWithPath: key).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return AppInfo(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                bundleIdentifier: Bundle(url: url)?.bundleIdentifier
            )
        }
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: key)
        guard let url = urls.first?.standardizedFileURL else { return nil }
        return AppInfo(
            url: url,
            name: FileManager.default.displayName(atPath: url.path),
            bundleIdentifier: key
        )
    }

    /// Four-part「打开方式」list:
    /// 1) current default app for this file
    /// 2) apps that previously opened this file type
    /// 3) system-recommended apps for this type (not every installed app)
    /// 4) callers add action items (「其他…」)
    static func sectionedApps(for fileURL: URL) -> (
        currentDefault: AppInfo?,
        history: [AppInfo],
        recommended: [AppInfo],
        defaultURL: URL?
    ) {
        let defaultURL = defaultApp(for: fileURL)?.standardizedFileURL
        // Type-capable apps only — never scan all installed applications.
        let recommendedAll = dedupe(NSWorkspace.shared.urlsForApplications(toOpen: fileURL))

        let selfBundle = Bundle.main.bundleIdentifier
        var seen = Set<String>()

        // 1. Current default opener for this file / type.
        var currentDefault: AppInfo?
        if let defaultURL {
            let info = AppInfo(
                url: defaultURL,
                name: FileManager.default.displayName(atPath: defaultURL.path),
                bundleIdentifier: Bundle(url: defaultURL)?.bundleIdentifier
            )
            if info.bundleIdentifier != selfBundle {
                currentDefault = info
                seen.insert(info.identity)
            }
        }

        // 2. History of apps used to open this file type (newest first).
        var history: [AppInfo] = []
        let typeKey = AppSettings.openWithTypeKey(for: fileURL)
        let typedKeys = AppSettings.shared.openWithAppHistoryByType[typeKey] ?? []
        let historyKeys: [String]
        if !typedKeys.isEmpty {
            historyKeys = typedKeys
        } else {
            // First-run fallback: global open-with history, but only apps that can open this type.
            let canOpen = Set(recommendedAll.map(\.identity))
            historyKeys = AppSettings.shared.openWithAppHistory.filter { key in
                guard let info = appInfo(forHistoryKey: key) else { return false }
                return canOpen.contains(info.identity)
            }
        }
        for key in historyKeys {
            guard let info = appInfo(forHistoryKey: key) else { continue }
            if let bid = info.bundleIdentifier, bid == selfBundle { continue }
            guard !seen.contains(info.identity) else { continue }
            seen.insert(info.identity)
            history.append(info)
            if history.count >= 10 { break }
        }

        // 3. Recommended apps for this type only (system list), excluding 1 & 2.
        var recommended: [AppInfo] = []
        for info in recommendedAll {
            if let bid = info.bundleIdentifier, bid == selfBundle { continue }
            guard !seen.contains(info.identity) else { continue }
            seen.insert(info.identity)
            recommended.append(info)
            if recommended.count >= 12 { break }
        }

        return (currentDefault, history, recommended, defaultURL)
    }
}

// MARK: - Row view (icon + name)

final class OpenWithRowView: NSView {
    var appURL: URL!
    var onOpen: (() -> Void)?
    private(set) var displayName: String = ""

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var isHovered = false

    static let rowWidth: CGFloat = 220
    static let rowHeight: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseMoved(with event: NSEvent) {
        if !isHovered { setHovered(true) }
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        layer?.backgroundColor = hovered
            ? NSColor.selectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = hovered ? .selectedMenuItemTextColor : .labelColor
    }

    func configure(name: String, icon: NSImage) {
        displayName = name
        titleLabel.stringValue = name
        titleLabel.textColor = .labelColor
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        iconView.image = sized
        setHovered(false)
    }

    override func mouseUp(with event: NSEvent) {
        onOpen?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
