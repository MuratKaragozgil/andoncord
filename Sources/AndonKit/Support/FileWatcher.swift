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

    public init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { cancel() }

    public func cancel() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    private func arm() {
        queue.async { [weak self] in self?.armLocked() }
    }

    private func armLocked() {
        source?.cancel()
        source = nil

        // The file may not exist yet — nothing has written a statusline
        // payload until Claude Code runs at least once. Retry on a slow timer
        // rather than giving up permanently.
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.armLocked() }
            return
        }
        descriptor = fd

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
