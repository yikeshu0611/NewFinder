import AppKit
import Foundation

/// One running extraction.
///
/// The job owns the tool process, so it can pause it (SIGSTOP) and let it
/// go on again (SIGCONT), and it can stop it (SIGTERM).
final class ArchiveExtractJob {
    /// The archive that is being opened.
    let archiveURL: URL
    /// The name of that archive, for the window.
    let archiveName: String
    /// The folder the files are written into.
    let destinationURL: URL
    /// How many bytes are going to be read from the archive.
    ///
    /// This is not known until the archive has been read, so it starts at
    /// zero and is filled in as soon as the listing is there.
    private(set) var totalBytes: UInt64

    private let lock = NSLock()
    private var process: Process?
    private var paused = false
    private var cancelled = false
    private var task: Task<Void, Never>?

    /// Called with the progress while the work runs.
    var onProgress: ((ArchiveProgress) -> Void)?
    /// Called with the state of each file while the work runs.
    var onFileProgress: ((ArchiveExtractFileProgress) -> Void)?
    /// Called when the work is over, successfully or not.
    var onFinish: ((Result<Void, Error>) -> Void)?

    init(archiveURL: URL, destinationURL: URL, totalBytes: UInt64) {
        self.archiveURL = archiveURL
        self.archiveName = archiveURL.lastPathComponent
        self.destinationURL = destinationURL
        self.totalBytes = totalBytes
    }

    /// True while the work is held back.
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    /// True once the work has been stopped by the user.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Running

    /// Starts the extraction.
    func start(password: String?) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // The size of the files that are inside the archive is
                // worked out first, so the window knows how much there is
                // to unpack before it starts.
                let total = await ArchiveEngine.totalSize(ofArchiveContents: archiveURL)
                lock.lock()
                totalBytes = total
                lock.unlock()

                try await ArchiveEngine.extract(
                    archive: archiveURL,
                    to: destinationURL,
                    password: password,
                    progress: { _ in },
                    progressDetail: { [weak self] progress in
                        self?.onProgress?(progress)
                    },
                    fileProgress: { [weak self] file in
                        self?.onFileProgress?(file)
                    },
                    processControl: { [weak self] process in
                        self?.attach(process: process)
                    }
                )
                await MainActor.run { [weak self] in
                    self?.onFinish?(.success(()))
                }
            } catch {
                // A job that was stopped by the user is not an error.
                var isCancelled = self.isCancelled
                if let archiveError = error as? ArchiveError,
                   case .cancelled = archiveError {
                    isCancelled = true
                }
                if error is CancellationError {
                    isCancelled = true
                }
                await MainActor.run { [weak self] in
                    if isCancelled {
                        self?.onFinish?(.failure(ArchiveError.cancelled))
                    } else {
                        self?.onFinish?(.failure(error))
                    }
                }
            }
        }
    }

    /// Remembers the running process, so it can be paused or stopped.
    private func attach(process: Process) {
        lock.lock()
        let alreadyCancelled = cancelled
        self.process = process
        lock.unlock()

        if alreadyCancelled {
            process.terminate()
        }
    }

    // MARK: - Pause / resume / cancel

    /// Holds the work back, or lets it go on again.
    func togglePause() {
        lock.lock()
        let current = process
        let shouldPause = !paused
        paused = shouldPause
        lock.unlock()

        guard let current, current.isRunning else { return }
        if shouldPause {
            // SIGSTOP freezes the tool where it is.
            kill(current.processIdentifier, SIGSTOP)
        } else {
            // SIGCONT lets it carry on.
            kill(current.processIdentifier, SIGCONT)
        }
    }

    /// Stops the work for good.
    func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()

        if let current, current.isRunning {
            // A paused process has to be woken up before it can be stopped.
            kill(current.processIdentifier, SIGCONT)
            current.terminate()
        }
        task?.cancel()
    }
}
