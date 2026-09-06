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
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.filter { app in
            app.pathExtension.lowercased() == "app"
                || ((try? app.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                    && app.pathExtension.lowercased() == "app")
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Attach without opening Finder (`-nobrowse`).
    static func attach(dmgURL: URL) throws -> MountedImage {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach",
            dmgURL.path,
            "-nobrowse",
            "-readonly",
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
        // Prefer device node; fall back to mount point.
        let target = mounted.device.hasPrefix("/dev/") ? mounted.device : mounted.mountURL.path
        process.arguments = ["detach", target, "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static func installApp(_ appURL: URL, toApplications replace: Bool) throws -> URL {
        let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let dest = apps.appendingPathComponent(appURL.lastPathComponent)
        let fm = FileManager.default

        if fm.fileExists(atPath: dest.path) {
            if replace {
                try fm.removeItem(at: dest)
            } else {
                throw NSError(
                    domain: "NewFinder.DMG",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "「\(dest.lastPathComponent)」已存在于应用程序文件夹"]
                )
            }
        }

        try fm.copyItem(at: appURL, to: dest)
        NSWorkspace.shared.noteFileSystemChanged(dest.path)
        return dest
    }
}
