import AppKit

enum UpdateChecker {
    static let repository = "yikeshu0611/NewFinder"

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
        let releaseNotes: String
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func fetchLatest(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("NewFinder-UpdateChecker", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                DispatchQueue.main.async {
                    completion(.failure(CocoaError(.fileReadUnknown)))
                }
                return
            }
            do {
                let info = try parseReleaseJSON(data)
                DispatchQueue.main.async { completion(.success(info)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        compareVersions(candidate, installed) == .orderedDescending
    }

    static func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, Error>) -> Void) {
        _ = download(release, progress: { _ in }, completion: completion)
    }

    /// 带进度的下载，用于更新弹窗/设置页的进度条。返回 task 可用于取消。
    @discardableResult
    static func download(
        _ release: ReleaseInfo,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> URLSessionTask? {
        let delegate = DownloadDelegate(
            progress: progress,
            completion: completion,
            fileName: release.downloadURL.lastPathComponent.isEmpty
                ? "NewFinder-\(release.version).dmg"
                : release.downloadURL.lastPathComponent
        )
        // session 强引用 delegate，delegate 强引用 session，打破循环靠 finish 后 invalidate。
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.session = session
        var request = URLRequest(url: release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.setValue("NewFinder-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        delegate.task = task
        task.resume()
        return task
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        var session: URLSession?
        var task: URLSessionDownloadTask?
        let progress: (Double) -> Void
        let completion: (Result<URL, Error>) -> Void
        let fileName: String

        init(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void, fileName: String) {
            self.progress = progress
            self.completion = completion
            self.fileName = fileName
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async { self.progress(min(1, max(0, fraction))) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                DispatchQueue.main.async { self.completion(.success(dest)) }
            } catch {
                DispatchQueue.main.async { self.completion(.failure(error)) }
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                DispatchQueue.main.async { self.completion(.failure(error)) }
                session.finishTasksAndInvalidate()
            }
        }
    }

    /// 挂载 dmg 并把里面的 NewFinder.app 装到 /Applications（覆盖旧版）。
    /// 返回安装后的 app 路径。调用方负责 detach 失败时的清理。
    static func installDMGToApplications(_ dmgURL: URL, progress: ((Double, String) -> Void)? = nil) throws -> URL {
        let mounted = try DMGInstallSupport.attach(dmgURL: dmgURL)
        defer { DMGInstallSupport.detach(mounted) }
        let apps = DMGInstallSupport.findApps(in: mounted.mountURL)
        // 优先 NewFinder.app，否则取第一个。
        let app = apps.first(where: { $0.lastPathComponent == "NewFinder.app" }) ?? apps.first
        guard let app else {
            throw NSError(
                domain: "NewFinder.Update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "安装包中没有找到 NewFinder.app"]
            )
        }
        return try DMGInstallSupport.installApp(app, toApplications: true, progress: progress)
    }

    /// 安装完成后重启到 /Applications 的新版本。
    /// 当前是开发目录的 build 包时只打开安装包，不自动重启，避免把调试进程杀掉。
    static func relaunchInstalledApp(at installedURL: URL) {
        let currentPath = Bundle.main.bundleURL.standardizedFileURL.path
        let isDevBuild = currentPath.contains("/build/") || !currentPath.hasPrefix("/Applications/")
        if isDevBuild {
            // 开发包：装好就行，不杀掉当前进程。
            NSWorkspace.shared.open(installedURL)
            return
        }
        // 用小脚本等旧进程退出后再拉起新版，避免覆盖运行中包时的竞态。
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = true
        NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        }
    }

    private static func parseReleaseJSON(_ data: Data) throws -> ReleaseInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !tag.isEmpty else { throw CocoaError(.propertyListReadCorrupt) }

        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmgAsset = assets.first { item in
            (item["name"] as? String)?.lowercased().hasSuffix(".dmg") == true
        }
        guard let urlString = dmgAsset?["browser_download_url"] as? String,
              let downloadURL = URL(string: urlString) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let notes = json["body"] as? String ?? ""
        return ReleaseInfo(version: tag, downloadURL: downloadURL, releaseNotes: notes)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }
}
