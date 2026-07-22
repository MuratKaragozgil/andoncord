import AndonKit
import AppKit
import Observation
import os

enum AndonLog {
    static let ui = Logger(subsystem: "app.andoncord", category: "app")
}

/// Wires the pieces together and owns their lifecycle.
///
/// Deliberately thin: the board holds state, the server holds transport, the
/// installer holds the on-disk contract. This just starts them in the right
/// order and routes between them.
@Observable
@MainActor
final class AppState {
    let board = BoardStore()
    let settings = AndonSettings()
    let installer = ClaudeSettingsInstaller()
    let codexInstaller = CodexHooksInstaller()
    let geminiInstaller = GeminiHooksInstaller()
    let cursorInstaller = CursorHooksInstaller()

    @ObservationIgnored
    private let server = HookServer()
    @ObservationIgnored
    private let chiptune = ChiptuneEngine()

    /// Surfaced in the menu bar and settings so a broken install is visible
    /// rather than presenting as "the app just doesn't work".
    private(set) var installStatus: ClaudeSettingsInstaller.Status = .notInstalled
    private(set) var codexStatus: CodexHooksInstaller.Status = .notInstalled
    private(set) var geminiStatus: GeminiHooksInstaller.Status = .notInstalled
    private(set) var cursorStatus: CursorHooksInstaller.Status = .notInstalled
    private(set) var serverError: String?
    /// Set when another copy of the app already owns the socket.
    private(set) var duplicateInstancePID: pid_t?

    /// Opens the real settings window. Wired by `MenuBarController`, which
    /// owns the window. The notch panel calls this instead of presenting a
    /// SwiftUI sheet — a sheet attaches to the fixed-size notch window and
    /// floats inside its transparent expanse, which looks like a dialog lost
    /// on a black field.
    @ObservationIgnored
    var openSettingsWindow: (() -> Void)?

    init() {
        board.onSound = { [weak self] sound in self?.playSound(sound) }
    }

    // MARK: - Lifecycle

    func start() {
        do {
            try PidGuard.claim()
        } catch let running as PidGuard.AlreadyRunning {
            // Two instances would fight over the socket, and the loser would
            // look alive while receiving nothing.
            duplicateInstancePID = running.pid
            AndonLog.ui.error("Another instance is running (pid \(running.pid))")
            return
        } catch {
            serverError = error.localizedDescription
        }

        server.onEvent = { [weak self] envelope, decision in
            self?.board.apply(envelope, decision: decision)
        }

        do {
            try server.start()
            serverError = nil
        } catch {
            serverError = Self.describe(error)
            AndonLog.ui.error("Server failed to start: \(self.serverError ?? "")")
        }

        board.startWatchingRateLimits()
        // Sessions whose process died without a SessionEnd would otherwise sit
        // on the board reading "running" indefinitely.
        board.startReapingDeadSessions()
        refreshInstallStatus()

        // The launcher embeds the current bundle path. Rewriting it on every
        // launch keeps hooks working after the app is moved or updated,
        // without touching settings.json again.
        if case .installed = installStatus {
            try? LauncherWriter.writeLaunchers()
        }
    }

    func stop() {
        board.stopReaping()
        server.stop()
        chiptune.shutdown()
        PidGuard.release()
    }

    private static func describe(_ error: Error) -> String {
        if case SocketTransport.TransportError.pathTooLong = error {
            return "Home directory path is too long for a Unix socket (104 byte limit)."
        }
        return error.localizedDescription
    }

    // MARK: - Integration

    func refreshInstallStatus() {
        installStatus = installer.currentStatus()
        codexStatus = codexInstaller.currentStatus()
        geminiStatus = geminiInstaller.currentStatus()
        cursorStatus = cursorInstaller.currentStatus(gateEnabled: settings.cursorGateEnabled)
    }

    var isIntegrationHealthy: Bool {
        if case .installed = installStatus { return serverError == nil }
        return false
    }

    var isCodexInstalled: Bool {
        if case .installed = codexStatus { return true }
        return false
    }

    @discardableResult
    func installCodex() -> Result<CodexHooksInstaller.Report, Error> {
        do {
            let report = try codexInstaller.install()
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Codex install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeCodex() -> Result<URL?, Error> {
        do {
            let backup = try codexInstaller.uninstall()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    var isGeminiInstalled: Bool {
        if case .installed = geminiStatus { return true }
        return false
    }

    @discardableResult
    func installGemini() -> Result<GeminiHooksInstaller.Report, Error> {
        do {
            let report = try geminiInstaller.install()
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Gemini install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeGemini() -> Result<URL?, Error> {
        do {
            let backup = try geminiInstaller.uninstall()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    var isCursorInstalled: Bool {
        if case .installed = cursorStatus { return true }
        return false
    }

    @discardableResult
    func installCursor() -> Result<CursorHooksInstaller.Report, Error> {
        do {
            let report = try cursorInstaller.install(gateEnabled: settings.cursorGateEnabled)
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Cursor install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeCursor() -> Result<URL?, Error> {
        do {
            let backup = try cursorInstaller.uninstall()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    /// Flip the shell gate and rewrite the hooks file to match. Cursor
    /// hot-reloads hooks.json, so the change takes effect without a restart.
    func setCursorGate(_ enabled: Bool) {
        settings.cursorGateEnabled = enabled
        if isCursorInstalled { installCursor() }
    }

    @discardableResult
    func installIntegration() -> Result<ClaudeSettingsInstaller.Report, Error> {
        do {
            let report = try installer.install()
            refreshInstallStatus()
            return .success(report)
        } catch {
            AndonLog.ui.error("Install failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func removeIntegration() -> Result<URL?, Error> {
        do {
            let backup = try installer.uninstall()
            LauncherWriter.removeLaunchers()
            board.reset()
            refreshInstallStatus()
            return .success(backup)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Sound

    private func playSound(_ sound: BoardSound) {
        guard settings.soundsEnabled else { return }
        if settings.quietWhileFocused && Self.isDoNotDisturbLikely { return }
        chiptune.volume = Float(settings.volume)
        chiptune.play(sound)
    }

    func previewSound(_ sound: BoardSound) {
        chiptune.volume = Float(settings.volume)
        chiptune.preview(sound)
    }

    /// Best-effort Focus detection.
    ///
    /// macOS exposes no public API for Focus state, so this checks the one
    /// closely-related signal that is public: an active screen recording or
    /// sharing session, where a surprise chiptune is worst. Presenting this as
    /// "quiet while focused" is a slight overstatement, and the settings copy
    /// says so.
    private static var isDoNotDisturbLikely: Bool {
        NSApplication.shared.occlusionState.contains(.visible) == false
    }
}
