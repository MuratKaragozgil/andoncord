import AndonKit
import Darwin
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  andon-hook — the shim Claude Code executes.
//
//  Two rules govern everything in this file:
//
//  1. FAIL OPEN. This process sits on the user's critical path. If the app is
//     not running, is mid-update, or is wedged, Claude Code must carry on
//     exactly as if AndonCord were not installed. Every failure path exits 0
//     with no stdout, which Claude Code reads as "the hook had no opinion".
//
//  2. STAY CHEAP. This runs twice per tool call. No parsing beyond what is
//     needed, no network, no disk writes on the hot path.
//
//  It also exists as a real process, rather than the app registering an HTTP
//  hook, for one reason that cannot be worked around: Claude Code spawns it as
//  a child of the user's shell, so it inherits the controlling TTY and the
//  terminal's environment. That is the only reliable way to learn which tab a
//  session is in — the hook payload carries no terminal information at all.
// ─────────────────────────────────────────────────────────────────────────────

/// Exit without emitting a decision. Claude Code proceeds normally.
func failOpen(_ note: @autoclosure () -> String = "") -> Never {
    let message = note()
    if !message.isEmpty { Log.debugFile("hook fail-open: \(message)") }
    exit(0)
}

/// Best-effort controlling-terminal path.
///
/// stdin is the hook payload pipe, so it is never the tty. stderr is usually
/// still wired to the terminal; `/dev/tty` is the fallback when Claude Code
/// has captured both streams.
func currentTTYPath() -> String? {
    for fd in [Int32(2), Int32(1), Int32(0)] {
        if isatty(fd) == 1, let name = ttyname(fd) {
            return String(cString: name)
        }
    }
    let fd = open("/dev/tty", O_RDONLY | O_NONBLOCK)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    guard let name = ttyname(fd) else { return nil }
    return String(cString: name)
}

// MARK: - Argument parsing

let arguments = CommandLine.arguments.dropFirst()
let isStatusline = arguments.contains("--statusline")
/// Set by the installer only on the hooks where a human decision is expected,
/// so the common path never waits on a reply.
let isBlocking = arguments.contains("--blocking")

// MARK: - Read stdin

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
guard !stdinData.isEmpty else { failOpen("empty stdin") }

// MARK: - Statusline mode

if isStatusline {
    // Claude Code exposes `rate_limits` on the statusline payload and nowhere
    // else, which is the entire reason AndonCord installs a statusline at
    // all. Cache it, then hand control to whatever statusline the user had
    // before us so their own output is untouched.
    if let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: stdinData),
       snapshot.rateLimits?.isEmpty == false || snapshot.contextWindow != nil {
        try? Paths.ensureDirectories()
        if let encoded = try? JSONEncoder().encode(snapshot) {
            try? encoded.write(to: Paths.rateLimitsCache, options: .atomic)
        }
    }

    // Chain to the previous statusline command, passing the identical payload.
    if let chainData = try? Data(contentsOf: Paths.statuslineChain),
       let chain = try? JSONDecoder().decode(StatuslineChain.self, from: chainData),
       let command = chain.command, !command.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        if (try? process.run()) != nil {
            inputPipe.fileHandleForWriting.write(stdinData)
            try? inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }
    exit(0)
}

// MARK: - Hook mode

guard let raw = try? JSONDecoder().decode(JSONValue.self, from: stdinData) else {
    failOpen("stdin was not JSON")
}
// A payload we cannot model is still worth forwarding — `raw` is intact and
// the app can display it — so an empty decode is not fatal.
let payload = (try? JSONDecoder().decode(HookPayload.self, from: stdinData)) ?? HookPayload()

let terminal = TerminalContext.capture(
    environment: ProcessInfo.processInfo.environment,
    ttyPath: currentTTYPath(),
    parentPid: getppid()
)

let envelope = HookEnvelope(
    blocking: isBlocking,
    payload: payload,
    raw: raw,
    terminal: terminal,
    shimPid: getpid()
)

guard let encoded = try? JSONEncoder().encode(envelope) else { failOpen("encode failed") }

// Connect. A refused connection means the app is not running — the normal,
// expected case for anyone who has the hooks installed but the app closed.
let socketPath = Paths.socket.path
guard let fd = try? SocketTransport.connect(
    to: socketPath,
    // Blocking hooks are configured with a 24h timeout in settings.json so a
    // permission prompt can sit on the board as long as a terminal prompt
    // would. Non-blocking hooks must never delay a tool call.
    timeout: isBlocking ? 86_400 : 2
) else {
    failOpen("no listener at \(socketPath)")
}
defer { close(fd) }

guard (try? SocketTransport.writeLine(encoded, to: fd)) != nil else {
    failOpen("write failed")
}

guard isBlocking else {
    // Fire and forget. close() flushes the stream socket.
    exit(0)
}

// Hold the hook open until a human answers on the board.
guard let responseData = try? SocketTransport.readLine(from: fd),
      !responseData.isEmpty else {
    // The app went away mid-decision. Falling through with no output hands the
    // prompt back to Claude Code's own terminal UI, which is the right
    // degradation: the user still gets asked, just not in the notch.
    failOpen("no decision returned")
}

FileHandle.standardOutput.write(responseData)
exit(0)
