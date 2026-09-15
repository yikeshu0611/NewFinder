import AppKit

/// Mount disk images and locate installable .app bundles for the in-app installer.
enum DMGInstallSupport {
    struct MountedImage {
        var device: String
        var mountURL: URL
        var sourceDMG: URL?
    }

    static func isDiskImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "dmg" || ext == "iso" || ext == "img"
    }

    static func looksLikeInstallerVolume(_ url: URL) -> Bool {
        guard FinderVolumeGuard.urlLooksLikeMountedVolume(url) else { return false }
        return !findApps(in: url).isEmpty
    }

    static func findApps(in directory: URL) -> [URL] {
        let fm = FileManager.default
        // Shallow listing only — do not recurse into .app bundles.
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isApplicationKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.filter { $0.pathExtension.lowercased() == "app" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Attach without opening Finder. `-noverify` skips image checksums (often the slow part).
    static func attach(dmgURL: URL) throws -> MountedImage {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach",
            dmgURL.path,
            "-nobrowse",
            "-readonly",
            "-noverify",
            "-plist"
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "NewFinder.DMG",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false
                    ? message!
                    : "无法挂载磁盘映像"]
            )
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw NSError(
                domain: "NewFinder.DMG",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法解析挂载结果"]
            )
        }

        var device = ""
        var mountPath: String?
        for entity in entities {
            if let dev = entity["dev-entry"] as? String, device.isEmpty {
                device = dev
            }
            if let mount = entity["mount-point"] as? String {
                mountPath = mount
            }
        }

        guard let mountPath, !mountPath.isEmpty else {
            throw NSError(
                domain: "NewFinder.DMG",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "磁盘映像没有可访问的卷"]
            )
        }
        if device.isEmpty { device = mountPath }

        return MountedImage(
            device: device,
            mountURL: URL(fileURLWithPath: mountPath),
            sourceDMG: dmgURL.standardizedFileURL
        )
    }

    static func detach(_ mounted: MountedImage) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let target = mounted.device.hasPrefix("/dev/") ? mounted.device : mounted.mountURL.path
        process.arguments = ["detach", target, "-quiet", "-force"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Install via `ditto` with a determinate 0…1 progress bar.
    /// Size is measured once up front; destination size is sampled infrequently so
    /// progress stays accurate without thrashing the disk (no bouncing bar).
    static func installApp(
        _ appURL: URL,
        toApplications replace: Bool,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> URL {
        let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let dest = apps.appendingPathComponent(appURL.lastPathComponent)
        let fm = FileManager.default

        progress?(0, "正在准备…")
        let totalKB = max(1, diskUsageKilobytes(of: appURL))

        if fm.fileExists(atPath: dest.path) {
            if replace {
                progress?(0, "正在移除旧版本…")
                try fm.removeItem(at: dest)
            } else {
                throw NSError(
                    domain: "NewFinder.DMG",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "「\(dest.lastPathComponent)」已存在于应用程序文件夹"]
                )
            }
        }

        progress?(0, "正在拷贝…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [appURL.path, dest.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Sample ~2×/sec — enough for a smooth bar, cheap enough not to stall the copy.
        let pollQueue = DispatchQueue(label: "com.zhangjing.NewFinder.dmgCopyProgress")
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        var lastFraction = 0.0
        timer.schedule(deadline: .now() + 0.4, repeating: .milliseconds(500))
        timer.setEventHandler {
            let copiedKB = diskUsageKilobytes(of: dest)
            let fraction = min(0.99, Double(copiedKB) / Double(totalKB))
            if fraction + 0.005 >= lastFraction {
                lastFraction = fraction
                progress?(fraction, "正在拷贝…")
            }
        }

        try process.run()
        timer.resume()
        process.waitUntilExit()
        timer.cancel()

        guard process.terminationStatus == 0 else {
            try? fm.removeItem(at: dest)
            throw NSError(
                domain: "NewFinder.DMG",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "拷贝到「应用程序」失败"]
            )
        }

        progress?(0.97, "正在完成安装…")
        stripQuarantine(from: dest)
        NSWorkspace.shared.noteFileSystemChanged(dest.path)
        progress?(1, "安装完成")
        return dest
    }

    /// `du -sk` once — kilobytes on disk.
    private static func diskUsageKilobytes(of url: URL) -> UInt64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", url.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let token = text.split(whereSeparator: { $0.isWhitespace || $0 == "\t" }).first.map(String.init) ?? ""
        return UInt64(token) ?? 0
    }

    /// Remove download/DMG quarantine so the app launches as a normal /Applications install.
    static func stripQuarantine(from appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        // Non-recursive: Gatekeeper tags the bundle root; `-dr` on large apps is very slow.
        process.arguments = ["-d", "com.apple.quarantine", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// Launch an installed app from disk (not from a mounted DMG).
    static func openInstalledApp(_ appURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }
}
