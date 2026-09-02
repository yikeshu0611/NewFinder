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

    static func sectionedApps(for fileURL: URL) -> (
        currentDefault: AppInfo?,
        history: [AppInfo],
        others: [AppInfo]
    ) {
        let all = allInstalledApps()
        let defaultURL = defaultApp(for: fileURL)
        let current = all.first { $0.url.standardizedFileURL == defaultURL }

        let historyKeys = Set(AppSettings.shared.openWithDefaultHistory)
        let history = all
            .filter { app in
                guard app.url.standardizedFileURL != defaultURL else { return false }
                if let bid = app.bundleIdentifier, historyKeys.contains(bid) { return true }
                return historyKeys.contains(app.url.path)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let used = Set(
            ([current].compactMap { $0 } + history).map(\.identity)
        )
        let others = all
            .filter { !used.contains($0.identity) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return (current, history, others)
    }
}

// MARK: - Row view (icon + name + checkbox on the right)

final class OpenWithRowView: NSView {
    var appURL: URL!
    var onOpen: (() -> Void)?
    var onSetDefault: (() -> Void)?
    private(set) var displayName: String = ""

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    static let rowWidth: CGFloat = 300
    static let rowHeight: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.toolTip = "勾选：设为默认打开方式"
        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(checkbox)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, icon: NSImage, isDefault: Bool) {
        displayName = name
        titleLabel.stringValue = name
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        iconView.image = sized
        checkbox.state = isDefault ? .on : .off
    }

    func setDefaultChecked(_ on: Bool) {
        checkbox.state = on ? .on : .off
    }

    @objc private func checkboxClicked() {
        checkbox.state = .on
        onSetDefault?()
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if checkbox.frame.insetBy(dx: -4, dy: -4).contains(loc) {
            return
        }
        onOpen?()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
