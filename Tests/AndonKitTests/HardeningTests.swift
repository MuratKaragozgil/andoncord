import Darwin
import XCTest
@testable import AndonKit

/// The socket hardening: a client that connects and never speaks must be cut
/// loose, and the pidfile claim must be a real lock, not check-then-write.
final class HardeningTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hard-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Stalled clients

    func testStalledClientIsDisconnectedByDeadline() throws {
        let server = HookServer(readTimeout: 0.2, readDeadline: 0.5)
        try server.start()
        defer { server.stop() }

        // Connect and send nothing — the slowloris posture.
        let fd = try SocketTransport.connect(to: Paths.socket.path, timeout: 5)
        defer { close(fd) }

        // The server must hang up on us. Reading EOF is the proof; getting
        // stuck here (test timeout) would mean the deadline never fired.
        let start = Date()
        var byte: UInt8 = 0
        let count = Darwin.read(fd, &byte, 1)
        XCTAssertEqual(count, 0, "server should close a silent connection")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3,
                          "the deadline is 0.5s — a multi-second wait means it leaked")
    }

    func testPromptClientStillRoundTrips() throws {
        // The same timeouts must not clip a normal, immediate exchange.
        let server = HookServer(readTimeout: 0.2, readDeadline: 0.5)
        let received = expectation(description: "event delivered")
        server.onEvent = { envelope, _ in
            XCTAssertEqual(envelope.payload.sessionId, "quick-1")
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let fd = try SocketTransport.connect(to: Paths.socket.path, timeout: 5)
        defer { close(fd) }
        var payload = HookPayload()
        payload.sessionId = "quick-1"
        payload.hookEventName = "Stop"
        let envelope = HookEnvelope(blocking: false, payload: payload,
                                    raw: .object([:]), terminal: nil, shimPid: 1)
        try SocketTransport.writeLine(try JSONEncoder().encode(envelope), to: fd)
        wait(for: [received], timeout: 5)
    }

    // MARK: - Pidfile lock

    func testPidfileClaimHoldsARealLock() throws {
        try PidGuard.claim()
        defer { PidGuard.release() }

        // A second descriptor must not be able to take the lock — this is
        // what a second app instance (or a spoofer) would attempt.
        let fd = open(Paths.pidFile.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0,
                          "the pidfile lock must be exclusive while claimed")
    }

    func testReleaseFreesTheLockForTheNextInstance() throws {
        try PidGuard.claim()
        PidGuard.release()

        let fd = open(Paths.pidFile.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0,
                       "after release the lock must be claimable again")
    }

    func testStalePidContentCannotBlockStartup() throws {
        // Old scheme: a live pid written into the file blocked launch. Now
        // only the lock matters — plant launchd's pid and claim anyway.
        try Paths.ensureDirectories()
        try "1\n".write(to: Paths.pidFile, atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try PidGuard.claim(),
                         "an unlocked pidfile is stale regardless of its content")
        PidGuard.release()
    }
}
