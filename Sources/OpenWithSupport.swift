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

    /// 仅「曾经打开过」的 app（按名称排序），供「打开方式」子菜单使用。
    /// 合并当前文件类型的历史 + 全局历史，仅保留能打开此文件的 app，
    /// 去掉系统推荐和其他未用过的 app。
    static func historyApps(for fileURL: URL) -> (
        apps: [AppInfo],
        defaultURL: URL?
    ) {
        let defaultURL = defaultApp(for: fileURL)?.standardizedFileURL
        // 能打开此文件的 app 身份集合，用来过滤全局历史。
        let canOpen = Set(dedupe(NSWorkspace.shared.urlsForApplications(toOpen: fileURL)).map(\.identity))
        let selfBundle = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [AppInfo] = []
        let typeKey = AppSettings.openWithTypeKey(for: fileURL)
        let typedKeys = AppSettings.shared.openWithAppHistoryByType[typeKey] ?? []
        var keys = typedKeys
        for k in AppSettings.shared.openWithAppHistory where !keys.contains(k) {
            keys.append(k)
        }
        for key in keys {
            guard let info = appInfo(forHistoryKey: key) else { continue }
            if let bid = info.bundleIdentifier, bid == selfBundle { continue }
            guard !seen.contains(info.identity) else { continue }
            guard canOpen.contains(info.identity) else { continue }
            seen.insert(info.identity)
            result.append(info)
        }
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (result, defaultURL)
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

// MARK: - Row view (一行三个胶囊: app / 默认 / 删除)

/// 单个胶囊:平时无背景,悬停时才显示 209,209,212 胶囊,点击触发回调。
final class OpenWithCapsule: NSView {
    var onClick: (() -> Void)?
    private static let hoverColor = NSColor(red: 209.0 / 255.0, green: 209.0 / 255.0, blue: 212.0 / 255.0, alpha: 1.0)
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Self.hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = Self.hoverColor.cgColor
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OpenWithRowView: NSView {
    var appURL: URL!
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSetDefault: (() -> Void)?
    private(set) var displayName: String = ""

    private let appCapsule = OpenWithCapsule()
    private let defaultCapsule = OpenWithCapsule()
    private let deleteCapsule = OpenWithCapsule()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let defaultLabel = NSTextField(labelWithString: "")
    private let deleteLabel = NSTextField(labelWithString: "✕")
    private var isCurrentDefault = false
    private var deleteWidthConstraint: NSLayoutConstraint!
    private var defaultDeleteGapConstraint: NSLayoutConstraint!

    static let rowWidth: CGFloat = 316
    static let rowHeight: CGFloat = 28
    private static let capsuleHeight: CGFloat = 22

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 行底不透明纯白:盖住系统菜单选中蓝,整行不再有 hover,只有胶囊自己变色。
        layer?.backgroundColor = NSColor.white.cgColor

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.textColor = .black
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        defaultLabel.font = .systemFont(ofSize: 11)
        defaultLabel.textColor = .black
        defaultLabel.alignment = .center
        defaultLabel.translatesAutoresizingMaskIntoConstraints = false

        deleteLabel.font = .systemFont(ofSize: 11)
        deleteLabel.textColor = .black
        deleteLabel.alignment = .center
        deleteLabel.translatesAutoresizingMaskIntoConstraints = false

        appCapsule.translatesAutoresizingMaskIntoConstraints = false
        defaultCapsule.translatesAutoresizingMaskIntoConstraints = false
        deleteCapsule.translatesAutoresizingMaskIntoConstraints = false

        addSubview(appCapsule)
        addSubview(defaultCapsule)
        addSubview(deleteCapsule)
        appCapsule.addSubview(iconView)
        appCapsule.addSubview(titleLabel)
        defaultCapsule.addSubview(defaultLabel)
        deleteCapsule.addSubview(deleteLabel)

        let gap: CGFloat = 6
        deleteWidthConstraint = deleteCapsule.widthAnchor.constraint(equalToConstant: 30)
        defaultDeleteGapConstraint = deleteCapsule.leadingAnchor.constraint(equalTo: defaultCapsule.trailingAnchor, constant: gap)
        NSLayoutConstraint.activate([
            appCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            appCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            appCapsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),

            defaultCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            defaultCapsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),
            defaultCapsule.widthAnchor.constraint(equalToConstant: 76),

            deleteCapsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            deleteCapsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteCapsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),
            deleteWidthConstraint,

            defaultCapsule.leadingAnchor.constraint(equalTo: appCapsule.trailingAnchor, constant: gap),
            defaultDeleteGapConstraint,

            iconView.leadingAnchor.constraint(equalTo: appCapsule.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: appCapsule.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: appCapsule.trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: appCapsule.centerYAnchor),

            defaultLabel.leadingAnchor.constraint(equalTo: defaultCapsule.leadingAnchor, constant: 4),
            defaultLabel.trailingAnchor.constraint(equalTo: defaultCapsule.trailingAnchor, constant: -4),
            defaultLabel.centerYAnchor.constraint(equalTo: defaultCapsule.centerYAnchor),

            deleteLabel.leadingAnchor.constraint(equalTo: deleteCapsule.leadingAnchor),
            deleteLabel.trailingAnchor.constraint(equalTo: deleteCapsule.trailingAnchor),
            deleteLabel.centerYAnchor.constraint(equalTo: deleteCapsule.centerYAnchor),
        ])
        // app 胶囊可压缩,右边两颗宽度固定。
        appCapsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appCapsule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        defaultCapsule.setContentCompressionResistancePriority(.required, for: .horizontal)
        deleteCapsule.setContentCompressionResistancePriority(.required, for: .horizontal)

        appCapsule.onClick = { [weak self] in
            guard let self else { return }
            self.onOpen?()
            self.enclosingMenuItem?.menu?.cancelTracking()
        }
        defaultCapsule.onClick = { [weak self] in
            guard let self, !self.isCurrentDefault else { return }
            self.onSetDefault?()
        }
        deleteCapsule.onClick = { [weak self] in
            self?.onDelete?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, icon: NSImage, isDefault: Bool) {
        displayName = name
        titleLabel.stringValue = name
        titleLabel.textColor = .black
        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: 16, height: 16)
        iconView.image = sized
        isCurrentDefault = isDefault
        if isDefault {
            defaultLabel.stringValue = "默认 ✓"
            defaultLabel.textColor = .black
            deleteCapsule.isHidden = true
            deleteWidthConstraint.constant = 0
            defaultDeleteGapConstraint.constant = 0
        } else {
            defaultLabel.stringValue = "设为默认"
            defaultLabel.textColor = .black
            deleteCapsule.isHidden = false
            deleteWidthConstraint.constant = 30
            defaultDeleteGapConstraint.constant = 6
        }
        deleteLabel.textColor = .black
        layer?.backgroundColor = NSColor.white.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
