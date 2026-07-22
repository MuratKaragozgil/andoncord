import Foundation

/// Installs, verifies, and removes AndonCord's wiring for Codex CLI.
///
/// Codex's hook contract is close enough to Claude Code's that the shim, the
/// socket, and the board are shared unchanged — the only real differences are
/// where the hooks are registered and how the command is tagged:
///
///   * Hooks go in `~/.codex/hooks.json`, **not** `config.toml`. That file
///     holds a single `notify` key which is already claimed on many machines
///     (the Codex desktop app's Computer-Use integration), and TOML has no
///     append semantics — writing `notify` would clobber it. `hooks.json` is a
///     separate, additive source that Codex merges across config layers.
///   * Every command carries `--source codex`, so the board can tell a Codex
///     session apart from a Claude one on the shared socket.
///
/// The file itself is JSON with the same `{ "hooks": { Event: [groups] } }`
/// shape as Claude's `settings.json`, so the merge logic mirrors
/// `ClaudeSettingsInstaller`: additive, backed up, idempotent, reversible.
public struct CodexHooksInstaller {
    /// Same launcher marker as the Claude installer — it identifies an entry as
    /// ours in either file. Within `hooks.json` every marked entry is Codex's.
    public static var marker: String { ClaudeSettingsInstaller.marker }

    public static let blockingTimeoutSeconds = ClaudeSettingsInstaller.blockingTimeoutSeconds

    public enum Status: Equatable {
        case notInstalled
        case installed
        case drifted(reason: String)
        case fileUnreadable(reason: String)
    }

    public struct Report {
        public var status: Status
        public var backupURL: URL?
        /// True when `config.toml` appears to disable the hooks feature, so the
        /// hooks are installed but Codex will ignore them until it is enabled.
        public var hooksFeatureDisabled: Bool
    }

    public init() {}

    // MARK: - Command construction

    static func command(blocking: Bool) -> String {
        let launcher = "\"$HOME/\(marker)\""
        let args = blocking ? "--source codex --blocking" : "--source codex"
        return "/bin/sh -c '[ -x \(launcher) ] && \(launcher) \(args); exit 0'"
    }

    private func handler(blocking: Bool) -> [String: Any] {
        var entry: [String: Any] = ["type": "command", "command": Self.command(blocking: blocking)]
        if blocking { entry["timeout"] = Self.blockingTimeoutSeconds }
        return entry
    }

    /// The events Codex actually emits that drive the board.
    ///
    /// Deliberately a subset of the Claude set: Codex has no `SessionEnd`,
    /// `Notification`, or the `AskUserQuestion`/`ExitPlanMode` tools, so those
    /// are omitted. Dead Codex sessions are cleaned up by the pid reaper, the
    /// same as any other.
    func desiredGroups() -> [String: [[String: Any]]] {
        let passive = handler(blocking: false)
        let blocking = handler(blocking: true)
        return [
            HookEventName.sessionStart.rawValue: [["hooks": [passive]]],
            HookEventName.userPromptSubmit.rawValue: [["hooks": [passive]]],
            HookEventName.preToolUse.rawValue: [["matcher": "*", "hooks": [passive]]],
            HookEventName.postToolUse.rawValue: [["matcher": "*", "hooks": [passive]]],
            HookEventName.permissionRequest.rawValue: [["matcher": "*", "hooks": [blocking]]],
            HookEventName.stop.rawValue: [["hooks": [passive]]],
            HookEventName.subagentStart.rawValue: [["hooks": [passive]]],
            HookEventName.subagentStop.rawValue: [["hooks": [passive]]],
        ]
    }

    // MARK: - Reading

    func readHooksFile() throws -> [String: Any] {
        let url = Paths.codexHooks
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try JSONC.parseObject(text)
    }

    public func currentStatus() -> Status {
        let root: [String: Any]
        do {
            root = try readHooksFile()
        } catch {
            return .fileUnreadable(reason: error.localizedDescription)
        }

        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var found = false
        var missing: [String] = []
        for (event, groups) in desiredGroups() {
            let ours = (hooks[event] as? [[String: Any]] ?? []).filter { groupCarriesMarker($0) }
            if ours.isEmpty { missing.append(event) }
            else { found = true; if ours.count != groups.count { missing.append(event) } }
        }
        guard found else { return .notInstalled }
        if !missing.isEmpty {
            return .drifted(reason: "hooks out of date: \(missing.sorted().joined(separator: ", "))")
        }
        return .installed
    }

    /// Best-effort, read-only check of whether the Codex hooks feature is
    /// switched off in `config.toml`.
    ///
    /// The flag name and default have changed across Codex versions
    /// (`codex_hooks` → `hooks`, off → on), and this deliberately does not
    /// parse TOML or edit the file — it only scans for an explicit disable so
    /// the UI can warn "installed, but Codex is ignoring it". When nothing is
    /// found it assumes enabled, which matches recent Codex defaults.
    public func hooksFeatureDisabled() -> Bool {
        guard let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8) else {
            return false
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let normalised = line.replacingOccurrences(of: " ", with: "")
            if normalised == "hooks=false" || normalised == "codex_hooks=false" {
                return true
            }
        }
        return false
    }

    private func groupCarriesMarker(_ group: [String: Any]) -> Bool {
        guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
        return handlers.contains { ($0["command"] as? String)?.contains(Self.marker) ?? false }
    }

    private func groupWithoutMarker(_ group: [String: Any]) -> [String: Any]? {
        guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
        handlers.removeAll { ($0["command"] as? String)?.contains(Self.marker) ?? false }
        if handlers.isEmpty { return nil }
        var updated = group
        updated["hooks"] = handlers
        return updated
    }

    // MARK: - Install

    @discardableResult
    public func install() throws -> Report {
        try Paths.ensureDirectories()
        try LauncherWriter.writeLaunchers()
        try FileManager.default.createDirectory(
            at: Paths.codexDir, withIntermediateDirectories: true)

        let existing = try readHooksFile()
        let backup = try makeBackup()

        var root = existing
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, desired) in desiredGroups() {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { groupWithoutMarker($0) }
            groups.append(contentsOf: desired)
            hooks[event] = groups
        }
        root["hooks"] = hooks

        try writeAtomically(root)
        return Report(status: .installed, backupURL: backup,
                      hooksFeatureDisabled: hooksFeatureDisabled())
    }

    @discardableResult
    public func uninstall() throws -> URL? {
        let url = Paths.codexHooks
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var root = try readHooksFile()
        let backup = try makeBackup()

        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let remaining = groups.compactMap { groupWithoutMarker($0) }
                if remaining.isEmpty { hooks.removeValue(forKey: event) }
                else { hooks[event] = remaining }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") }
            else { root["hooks"] = hooks }
        }

        // Leaving an empty `{}` behind is harmless, but removing a file we
        // fully emptied is tidier and matches "restore what was there".
        if root.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try writeAtomically(root)
        }
        return backup
    }

    // MARK: - Safe writes

    private func makeBackup() throws -> URL? {
        let source = Paths.codexHooks
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        try Paths.ensureDirectories()

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "codex-hooks-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
        let destination = Paths.backups.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func writeAtomically(_ root: [String: Any]) throws {
        let data = try JSONC.serialize(root)
        try data.write(to: Paths.codexHooks, options: .atomic)
        Log.install.info("Wrote \(Paths.codexHooks.path, privacy: .public)")
    }
}
