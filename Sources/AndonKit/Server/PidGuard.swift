import Darwin
import Foundation

/// Single-instance guard.
///
/// Two copies of the app would both try to bind the socket, and the second
/// would silently win by unlinking the first one's socket file — leaving the
/// original running but unreachable, with hooks failing open and no visible
/// symptom. Holding an exclusive `flock` on the pidfile makes that case loud
/// instead.
///
/// The lock, not the pid written inside, is the actual guard: an flock is
/// atomic (no check-then-write race between two launching instances), cannot
/// be spoofed by writing someone else's pid into the file, and the kernel
/// drops it on process death — even SIGKILL — so a crash can never wedge the
/// next launch behind a stale pidfile. The pid content is diagnostics only.
public enum PidGuard {
    public struct AlreadyRunning: Error {
        public let pid: pid_t
    }

    /// Kept open for the app's lifetime; the lock lives on this descriptor.
    private nonisolated(unsafe) static var lockFD: Int32 = -1

    /// Throws if another live instance holds the pidfile lock; otherwise
    /// claims it. Idempotent within a process.
    public static func claim() throws {
        guard lockFD < 0 else { return }
        try Paths.ensureDirectories()

        let fd = open(Paths.pidFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }  // best effort — never block startup on this

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let owner = currentOwner()
            close(fd)
            throw AlreadyRunning(pid: owner ?? 0)
        }

        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        lockFD = fd
    }

    public static func release() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
        try? FileManager.default.removeItem(at: Paths.pidFile)
    }

    /// The pid recorded in the pidfile, for the "already running" message.
    /// Informational: liveness is the lock's job now, not this pid's.
    public static func currentOwner() -> pid_t? {
        guard let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }
        return pid
    }
}
