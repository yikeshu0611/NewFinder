import AppKit
import Foundation

/// One running compression.
///
/// The job owns the tool process, so it can pause it (SIGSTOP) and let it
/// go on again (SIGCONT), and it can stop it (SIGTERM).
final class ArchiveJob {
    /// The file that is being written.
    let destinationURL: URL
    /// The name of that file, for the window.
    let destinationName: String
    /// How many bytes are going to be read from the source.
    let totalBytes: UInt64

    private let lock = NSLock()
    private var process: Process?
    private var paused = false
    private var cancelled = false
    private var task: Task<Void, Never>?

    /// Called with the progress while the work runs.
    var onProgress: ((ArchiveProgress) -> Void)?
    /// Called with the state of each file while the work runs.
    var onFileProgress: ((ArchiveFileProgress) -> Void)?
    /// Called when the work is over, successfully or not.
    var onFinish: ((Result<Void, Error>) -> Void)?

    init(destinationURL: URL, totalBytes: UInt64) {
        self.destinationURL = destinationURL
        self.destinationName = destinationURL.lastPathComponent
        self.totalBytes = totalBytes
    }

    /// True while the work is held back.
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    // MARK: - Running

    /// Starts the compression.
    func start(
        items: [URL],
        format: CompressFormat,
        password: String?,
        split: SplitVolumeSize
    ) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await ArchiveEngine.compress(
                    items: items,
                    to: destinationURL,
                    format: format,
                    password: password,
                    split: split,
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

    /// Starts the extraction.
    ///
    /// The archives are read into their folders one after another, and the
    /// window follows along the same way it does for a compression.
    func startExtract(
        archives: [URL],
        destinations: [URL],
        password: String?,
        protecting otherArchives: [URL] = []
    ) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for (index, archive) in archives.enumerated() {
                    let destination = destinations.indices.contains(index)
                        ? destinations[index]
                        : destinations.last ?? archive.deletingLastPathComponent()
                    try await ArchiveEngine.extract(
                        archive: archive,
                        to: destination,
                        password: password,
                        protecting: otherArchives,
                        progressDetail: { [weak self] progress in
                            self?.onProgress?(progress)
                        },
                        fileProgress: { [weak self] file in
                            self?.onFileProgress?(file)
                        },
                        processControl: { [weak self] process in
                            self?.attach(process: process)
                        },
                        progress: { _ in }
                    )
                }
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

    /// True once the work has been stopped by the user.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
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
