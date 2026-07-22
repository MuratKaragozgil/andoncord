import Darwin
import Foundation

/// A hook that is currently parked, waiting for a decision from the board.
///
/// While this object is alive the shim on the other end is blocked inside
/// `read()`, which means Claude Code itself is blocked. Every path out of the
/// UI must therefore end in either `resolve` or `abandon` — dropping one on the
/// floor would hang someone's session until the 24h hook timeout fires.
public final class PendingDecision {
    public let id: UUID
    public let envelope: HookEnvelope

    /// Receives the outcome exactly once. `nil` means "released with no
    /// opinion". Abstracted from the socket so the decision lifecycle can be
    /// tested without a live connection.
    private let sink: (HookResponse?) -> Void
    private let lock = NSLock()
    private var isSettled = false

    public init(
        id: UUID = UUID(),
        envelope: HookEnvelope,
        sink: @escaping (HookResponse?) -> Void
    ) {
        self.id = id
        self.envelope = envelope
        self.sink = sink
    }

    /// Send a decision back to Claude Code and release the hook.
    public func resolve(_ response: HookResponse) { settle(response) }

    /// Release the hook without an opinion. Claude Code falls back to its own
    /// terminal prompt, which is the correct degradation when we cannot
    /// answer — the user is still asked, just not in the notch.
    public func abandon() { settle(nil) }

    public var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return isSettled
    }

    private func settle(_ response: HookResponse?) {
        lock.lock()
        guard !isSettled else { lock.unlock(); return }
        isSettled = true
        lock.unlock()
        sink(response)
    }

    deinit {
        // A decision deallocated without an answer would leave Claude Code
        // blocked until the hook timeout, so treat it as an abandon.
        lock.lock()
        let settled = isSettled
        isSettled = true
        lock.unlock()
        if !settled { sink(nil) }
    }
}

/// Listens on the Unix domain socket and turns incoming shim connections into
/// events (and, where the hook is blocking, parked decisions).
public final class HookServer {
    public typealias EventHandler = (HookEnvelope, PendingDecision?) -> Void

    /// Delivered on the main queue.
    public var onEvent: EventHandler?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "app.andoncord.accept", qos: .userInitiated)
    private let ioQueue = DispatchQueue(
        label: "app.andoncord.io", qos: .userInitiated, attributes: .concurrent)

    private let pendingLock = NSLock()
    private var pending: [UUID: PendingDecision] = [:]

    public init() {}

    public var isRunning: Bool { listenFD >= 0 }

    public func start() throws {
        guard listenFD < 0 else { return }
        try Paths.ensureDirectories()

        guard Paths.socketPathFitsInSunPath else {
            throw SocketTransport.TransportError.pathTooLong
        }

        let fd = try SocketTransport.listen(at: Paths.socket.path)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source

        Log.server.info("Listening on \(Paths.socket.path, privacy: .public)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(Paths.socket.path)

        // Release anything still parked so no session is left hanging.
        pendingLock.lock()
        let inFlight = Array(pending.values)
        pending.removeAll()
        pendingLock.unlock()
        inFlight.forEach { $0.abandon() }
    }

    /// Release every parked decision belonging to a session. Called when a
    /// session ends so its hooks do not sit blocked until the timeout.
    public func abandonDecisions(forSession sessionId: String) {
        pendingLock.lock()
        let matching = pending.values.filter { $0.envelope.payload.sessionId == sessionId }
        pendingLock.unlock()
        matching.forEach { $0.abandon() }
    }

    // MARK: - Accept loop

    private func acceptPending() {
        // The read source fires once per readable event but several
        // connections can be queued, so drain until EAGAIN.
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one,
                       socklen_t(MemoryLayout<Int32>.size))
            ioQueue.async { [weak self] in self?.handleConnection(clientFD) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        guard let line = try? SocketTransport.readLine(from: fd), !line.isEmpty else {
            close(fd)
            return
        }
        guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: line) else {
            Log.server.error("Undecodable envelope, dropping")
            close(fd)
            return
        }

        if envelope.blocking {
            let id = UUID()
            let decision = PendingDecision(
                id: id, envelope: envelope,
                sink: { [weak self] response in
                    // Writing the reply is what unblocks the shim; closing the
                    // fd is what unblocks it when we have no opinion.
                    if let response, let data = try? JSONEncoder().encode(response) {
                        try? SocketTransport.writeLine(data, to: fd)
                    }
                    close(fd)
                    guard let self else { return }
                    self.pendingLock.lock()
                    self.pending.removeValue(forKey: id)
                    self.pendingLock.unlock()
                })
            pendingLock.lock()
            pending[id] = decision
            pendingLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self else { decision.abandon(); return }
                guard let handler = self.onEvent else { decision.abandon(); return }
                handler(envelope, decision)
            }
        } else {
            close(fd)
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(envelope, nil)
            }
        }
    }
}
