import Foundation

/// Installs, verifies, and removes AndonCord's wiring for Cursor.
///
/// Cursor's `~/.cursor/hooks.json` looks superficially like Claude's config
/// but is **flat**: each event maps to an array of hook objects directly —
/// `{"hooks": {"stop": [{"command": "..."}]}}` — with no inner `hooks` array.
/// Event arrays are additive across scopes and the file is hot-reloaded, so
/// the merge rules mirror the other installers: append ours by marker, never
/// touch anyone else's entries.
///
/// Two modes, chosen by the user:
///   * **Watch** (default): lifecycle + activity events only. Cursor has no
///     "approval needed" event, so watch mode has no approval visibility —
///     the UI says so instead of pretending.
///   * **Gate** (opt-in): additionally registers `beforeShellExecution` as a
///     blocking hook. Cursor fires it for *every* shell command before its own
///     approval UI, and a hook's allow/deny takes precedence — so enabling the
///     gate moves shell approval into the notch wholesale, allowlisted
///     commands included. Powerful, noisy, and therefore off by default.
public struct CursorHooksInstaller {
    public static var marker: String { ClaudeSettingsInstaller.marker }

    /// Seconds, per Cursor's docs (unlike Gemini's milliseconds).
    public static let gateTimeoutSeconds = 86_400

    public enum Status: Equatable {
        case notInstalled
        case installed
        case drifted(reason: String)
        case fileUnreadable(reason: String)
    }

    public struct Report {
        public var status: Status
        public var backupURL: URL?
        public var gateEnabled: Bool
    }

    public init() {}

    // MARK: - Command construction

    static func command(blocking: Bool) -> String {
        let launcher = "\"$HOME/\(marker)\""
        let args = blocking ? "--source cursor --blocking" : "--source cursor"
        return "/bin/sh -c '[ -x \(launcher) ] && \(launcher) \(args); exit 0'"
    }

    /// Flat entries — Cursor's schema has no inner `hooks` array.
    func desiredHooks(gateEnabled: Bool) -> [String: [[String: Any]]] {
        let passive: [String: Any] = ["command": Self.command(blocking: false)]
        var hooks: [String: [[String: Any]]] = [
            "sessionStart": [passive].map { $0 },
            "sessionEnd": [passive],
            "beforeSubmitPrompt": [passive],
            "preToolUse": [passive],
            "postToolUse": [passive],
            "postToolUseFailure": [passive],
            "stop": [passive],
            "subagentStart": [passive],
            "subagentStop": [passive],
        ]
        if gateEnabled {
            hooks["beforeShellExecution"] = [[
                "command": Self.command(blocking: true),
                "timeout": Self.gateTimeoutSeconds,
            ]]
        }
        return hooks
    }

    // MARK: - Reading

    func readHooksFile() throws -> [String: Any] {
        let url = Paths.cursorHooks
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try JSONC.parseObject(text)
    }

    public func currentStatus(gateEnabled: Bool) -> Status {
        let root: [String: Any]
        do {
            root = try readHooksFile()
        } catch {
            return .fileUnreadable(reason: error.localizedDescription)
        }

        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var found = false
        var wrong: [String] = []
        for (event, expected) in desiredHooks(gateEnabled: gateEnabled) {
            let ours = (hooks[event] as? [[String: Any]] ?? []).filter { entryIsOurs($0) }
            if ours.isEmpty { wrong.append(event) }
            else { found = true; if ours.count != expected.count { wrong.append(event) } }
        }
        // A stale gate hook when the gate is off is drift too — it would keep
        // parking commands the user asked us to stop gating.
        if !gateEnabled {
            let gate = (hooks["beforeShellExecution"] as? [[String: Any]] ?? [])
                .filter { entryIsOurs($0) }
            if !gate.isEmpty { wrong.append("beforeShellExecution (should be removed)") }
        }
        guard found else { return .notInstalled }
        if !wrong.isEmpty {
            return .drifted(reason: "hooks out of date: \(wrong.sorted().joined(separator: ", "))")
        }
        return .installed
    }

    private func entryIsOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(Self.marker) ?? false
    }

    // MARK: - Install / uninstall

    @discardableResult
    public func install(gateEnabled: Bool) throws -> Report {
        try Paths.ensureDirectories()
        try LauncherWriter.writeLaunchers()
        try FileManager.default.createDirectory(
            at: Paths.cursorDir, withIntermediateDirectories: true)

        let existing = try readHooksFile()
        let backup = try makeBackup()

        var root = existing
        // Cursor requires the version field; preserve a newer one if present.
        if root["version"] == nil { root["version"] = 1 }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Strip ours everywhere first so a mode change (gate on→off) removes
        // the gate hook rather than orphaning it.
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let remaining = entries.filter { !entryIsOurs($0) }
            if remaining.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = remaining }
        }
        for (event, desired) in desiredHooks(gateEnabled: gateEnabled) {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(contentsOf: desired)
            hooks[event] = entries
        }
        root["hooks"] = hooks

        try writeAtomically(root)
        return Report(status: .installed, backupURL: backup, gateEnabled: gateEnabled)
    }

    @discardableResult
    public func uninstall() throws -> URL? {
        let url = Paths.cursorHooks
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var root = try readHooksFile()
        let backup = try makeBackup()

        if var hooks = root["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let entries = value as? [[String: Any]] else { continue }
                let remaining = entries.filter { !entryIsOurs($0) }
                if remaining.isEmpty { hooks.removeValue(forKey: event) }
                else { hooks[event] = remaining }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") }
            else { root["hooks"] = hooks }
        }

        // If only our scaffolding remains ({"version": 1}), remove the file;
        // otherwise put back what the user had.
        let leftoverKeys = Set(root.keys).subtracting(["version"])
        if leftoverKeys.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try writeAtomically(root)
        }
        return backup
    }

    // MARK: - Safe writes

    private func makeBackup() throws -> URL? {
        let source = Paths.cursorHooks
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        try Paths.ensureDirectories()

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "cursor-hooks-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
        let destination = Paths.backups.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func writeAtomically(_ root: [String: Any]) throws {
        let data = try JSONC.serialize(root)
        try data.write(to: Paths.cursorHooks, options: .atomic)
        Log.install.info("Wrote \(Paths.cursorHooks.path, privacy: .public)")
    }
}
