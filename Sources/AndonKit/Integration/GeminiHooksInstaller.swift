import Foundation

/// Installs, verifies, and removes AndonCord's wiring for Gemini CLI.
///
/// Gemini adopted Claude's hook *structure* wholesale — a `hooks` key in
/// `~/.gemini/settings.json` whose event arrays merge additively across
/// scopes — but renamed the events (`BeforeTool`, `AfterAgent`, …) and the
/// built-in tools (`run_shell_command`, `replace`, …). The shim and board
/// handle both via `HookEventName.normalized(from:)`; this installer's job is
/// only to register the right event names with `--source gemini` commands.
///
/// One deliberate scope limit: **Gemini is one-way.** Its `Notification`
/// hook fires when an approval dialog appears but cannot answer it, and
/// `BeforeTool` runs only after the user has already approved. So nothing
/// here registers as blocking — the board shows "needs you" and precise jump
/// takes the user to the terminal, which is the honest ceiling of what
/// Gemini's hook contract allows.
public struct GeminiHooksInstaller {
    public static var marker: String { ClaudeSettingsInstaller.marker }

    /// A stable name on every entry, because Gemini's `/hooks` panel lists and
    /// toggles hooks by name — an unnamed hook shows up as an opaque command.
    static let hookName = "andoncord"

    public enum Status: Equatable {
        case notInstalled
        case installed
        case drifted(reason: String)
        case fileUnreadable(reason: String)
    }

    public struct Report {
        public var status: Status
        public var backupURL: URL?
        public var commentsWillBeLost: Bool
    }

    public init() {}

    // MARK: - Command construction

    static func command() -> String {
        let launcher = "\"$HOME/\(marker)\""
        return "/bin/sh -c '[ -x \(launcher) ] && \(launcher) --source gemini; exit 0'"
    }

    private func handler() -> [String: Any] {
        // No `timeout`: Gemini's is in *milliseconds* (unlike Claude's
        // seconds), and the shim fires-and-forgets in ~10 ms anyway — the
        // 60 s default is already three orders of magnitude of headroom.
        [
            "type": "command",
            "name": Self.hookName,
            "command": Self.command(),
        ]
    }

    /// Gemini's event vocabulary for the same board signals.
    func desiredGroups() -> [String: [[String: Any]]] {
        let passive = handler()
        return [
            "SessionStart": [["hooks": [passive]]],
            "SessionEnd": [["hooks": [passive]]],
            // Prompt submitted — Gemini's UserPromptSubmit.
            "BeforeAgent": [["hooks": [passive]]],
            // Tool activity.
            "BeforeTool": [["matcher": "*", "hooks": [passive]]],
            "AfterTool": [["matcher": "*", "hooks": [passive]]],
            // Approval dialog on screen. Fire-and-forget by design (see type
            // doc); the matcher narrows to the only notification type Gemini
            // currently emits.
            "Notification": [["matcher": "ToolPermission", "hooks": [passive]]],
            // Turn finished — Gemini's Stop.
            "AfterAgent": [["hooks": [passive]]],
        ]
    }

    // MARK: - Reading

    public func readSettings() throws -> (object: [String: Any], hadComments: Bool) {
        let url = Paths.geminiSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], false) }
        let text = try String(contentsOf: url, encoding: .utf8)
        return (try JSONC.parseObject(text), JSONC.containsComments(text))
    }

    public func currentStatus() -> Status {
        let settings: [String: Any]
        do {
            settings = try readSettings().object
        } catch {
            return .fileUnreadable(reason: error.localizedDescription)
        }

        let hooks = settings["hooks"] as? [String: Any] ?? [:]
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

    // MARK: - Install / uninstall

    @discardableResult
    public func install() throws -> Report {
        try Paths.ensureDirectories()
        try LauncherWriter.writeLaunchers()
        try FileManager.default.createDirectory(
            at: Paths.geminiDir, withIntermediateDirectories: true)

        let (existing, hadComments) = try readSettings()
        let backup = try makeBackup()

        var settings = existing
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, desired) in desiredGroups() {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { groupWithoutMarker($0) }
            groups.append(contentsOf: desired)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        try writeAtomically(settings)
        return Report(status: .installed, backupURL: backup, commentsWillBeLost: hadComments)
    }

    @discardableResult
    public func uninstall() throws -> URL? {
        let url = Paths.geminiSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var settings = try readSettings().object
        let backup = try makeBackup()

        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let remaining = groups.compactMap { groupWithoutMarker($0) }
                if remaining.isEmpty { hooks.removeValue(forKey: event) }
                else { hooks[event] = remaining }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
            else { settings["hooks"] = hooks }
        }

        // Unlike Codex's hooks.json, this file is Gemini's *main* settings —
        // even when our hooks were its only content, other keys may exist, and
        // deleting the file would be wrong. Always write back.
        try writeAtomically(settings)
        return backup
    }

    // MARK: - Safe writes

    private func makeBackup() throws -> URL? {
        let source = Paths.geminiSettings
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        try Paths.ensureDirectories()

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let name = "gemini-settings-\(stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"
        let destination = Paths.backups.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func writeAtomically(_ settings: [String: Any]) throws {
        let data = try JSONC.serialize(settings)
        try data.write(to: Paths.geminiSettings, options: .atomic)
        Log.install.info("Wrote \(Paths.geminiSettings.path, privacy: .public)")
    }
}
