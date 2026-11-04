import Foundation

/// Lightweight perf logger that appends to a file in /tmp.
///
/// The unified log filters our messages away, so the load timings are written
/// to a plain file that can be read back after reproducing a slow open.
enum PerfLog {
    private static let lock = NSLock()
    private static let url = URL(fileURLWithPath: "/tmp/nf-perf.log")
    private static var sessionToken = "s\(Int(Date().timeIntervalSince1970))"

    /// Sets the token that identifies the current app session in the log.
    static func setSession(_ token: String) {
        lock.lock()
        sessionToken = token
        lock.unlock()
    }

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Date().timeIntervalSince1970) [\(sessionToken)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        // Append without requiring the file to exist — `FileHandle(forWritingTo:)`
        // raises when the file is missing, so create it first.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Resets the log file (called when the app starts).
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? Data().write(to: url)
    }
}
