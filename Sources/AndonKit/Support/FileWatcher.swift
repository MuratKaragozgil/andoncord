import Darwin
import Foundation

/// Watches a single file for writes.
///
/// The statusline shim rewrites the rate-limit cache atomically, which means
/// the original inode is replaced rather than modified — so a plain
/// `.write` watch on the file descriptor stops firing after the first update.
/// This handles that by also watching for `.delete`/`.rename` and re-arming on
/// the new inode.
public final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "app.andoncord.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    /// Guards against a rename storm re-arming faster than it can settle.
    private var isRearming = false
    /// Set by `cancel`. Without it a retry already parked on `queue` would
    /// reopen the file and re-arm a watcher the caller has just torn down.
    private var isCancelled = false

    /// Backoff for a file that does not exist yet.
    ///
    /// The statusline payload is only written once Claude Code has run at
    /// least once, so on a fresh install this can miss indefinitely. A flat
    /// retry is a poll that never ends; backing off keeps the common case
    /// (the file appears within seconds of the first session) responsive
    /// while an install that is never used settles to once a minute.
    private static let minimumRetry: TimeInterval = 2
    private static let maximumRetry: TimeInterval = 60
    private var retryDelay: TimeInterval = minimumRetry

    public init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { cancel() }

    public func cancel() {
        queue.sync {
            isCancelled = true
            source?.cancel()
            source = nil
        }
    }

    private func arm() {
        queue.async { [weak self] in self?.armLocked() }
    }

    private func armLocked() {
        guard !isCancelled else { return }
        source?.cancel()
        source = nil

        // The file may not exist yet — nothing has written a statusline
        // payload until Claude Code runs at least once. Retry on a slow timer
        // rather than giving up permanently.
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, Self.maximumRetry)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.armLocked() }
            return
        }
        descriptor = fd
        // The file exists; a later atomic replace should be picked up promptly
        // rather than inheriting a minute-long backoff.
        retryDelay = Self.minimumRetry

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = newSource.data
            self.onChange()
            if mask.contains(.delete) || mask.contains(.rename) {
                guard !self.isRearming else { return }
                self.isRearming = true
                // Let the atomic replace finish before reopening.
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.isRearming = false
                    self?.armLocked()
                }
            }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
    }
}
