import AppKit
import Foundation

/// Creates a second WeChat.app instance for dual login on macOS WeChat 4.0+.
/// Steps match the common clone + Bundle ID + ad-hoc codesign approach.
enum WeChatDualOpen {
    static let cloneURL = URL(fileURLWithPath: "/Applications/WeChat2.app")
    private static let cloneBundleID = "com.tencent.xinWeChat2"

    static func findInstalledWeChat() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/WeChat.app"),
            URL(fileURLWithPath: "/Applications/微信.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func createClone(from source: URL, recreate: Bool) -> Result<Void, Error> {
        let src = shellEscape(source.path)
        let dst = shellEscape(cloneURL.path)
        let remove = recreate ? "rm -rf \(dst) && " : ""
        let command = """
        \(remove)cp -R \(src) \(dst) && \
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier \(cloneBundleID)" \(dst)/Contents/Info.plist && \
        codesign --force --deep --sign - \(dst) && \
        xattr -cr \(dst)
        """
        return runAdminShell(command)
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAdminShell(_ command: String) -> Result<Void, Error> {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        do shell script "\(escaped)" with administrator privileges
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(NSError(
                domain: "NewFinder.WeChatDualOpen",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建提权脚本"]
            ))
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "需要管理员密码才能创建微信分身"
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 2
            // User cancelled password dialog
            if code == -128 {
                return .failure(NSError(
                    domain: "NewFinder.WeChatDualOpen",
                    code: -128,
                    userInfo: [NSLocalizedDescriptionKey: "已取消"]
                ))
            }
            return .failure(NSError(
                domain: "NewFinder.WeChatDualOpen",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
        return .success(())
    }
}
