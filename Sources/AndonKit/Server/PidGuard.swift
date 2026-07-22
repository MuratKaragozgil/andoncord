import Darwin
import Foundation

/// Single-instance guard.
///
/// Two copies of the app would both try to bind the socket, and the second
/// would silently win by unlinking the first one's socket file — leaving the
/// original running but unreachable, with hooks failing open and no visible
/// symptom. Checking the pidfile up front makes that case loud instead.
public enum PidGuard {
    public struct AlreadyRunning: Error {
        public let pid: pid_t
    }

    /// Throws if another live instance owns the pidfile; otherwise claims it.
    public static func claim() throws {
        try Paths.ensureDirectories()

        if let existing = currentOwner(), existing != getpid() {
            throw AlreadyRunning(pid: existing)
        }
        let pid = String(getpid())
        try? pid.write(to: Paths.pidFile, atomically: true, encoding: .utf8)
    }

    public static func release() {
        guard let existing = currentOwner(), existing == getpid() else { return }
        try? FileManager.default.removeItem(at: Paths.pidFile)
    }

    /// The pid in the pidfile, but only if that process is actually alive.
    /// A stale pidfile from a crash must not block startup forever.
    public static func currentOwner() -> pid_t? {
        guard let text = try? String(contentsOf: Paths.pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }

        // Signal 0 tests for existence without delivering anything. EPERM
        // means it exists but belongs to someone else, which still counts.
        if kill(pid, 0) == 0 { return pid }
        return errno == EPERM ? pid : nil
    }
}
