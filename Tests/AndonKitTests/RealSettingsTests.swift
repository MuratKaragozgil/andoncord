import XCTest
@testable import AndonKit

/// Exercises the installer against a copy of a real, populated
/// `~/.claude/settings.json` rather than a hand-written fixture.
///
/// Synthetic fixtures are tidier than real config files. Real ones have twelve
/// hook events already registered by another tool, an `enabledPlugins` block,
/// and a statusline someone else owns — which is exactly the situation where a
/// careless merge does damage. Skipped unless `ANDON_REAL_SETTINGS` points at
/// a file; the original is only ever read.
final class RealSettingsTests: XCTestCase {
    var sandbox: URL!
    var fixture: String!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["ANDON_REAL_SETTINGS"],
              FileManager.default.fileExists(atPath: path)
        else { throw XCTSkip("set ANDON_REAL_SETTINGS to run") }

        // Once the app is actually installed on this machine, the live file
        // contains our own hooks — and a round-trip test that treats those as
        // "foreign" would report a false failure when uninstall correctly
        // removes them. Strip our marker so the fixture always represents a
        // config owned entirely by other tools, which is what this is testing.
        fixture = try Self.withoutAndonCordEntries(
            try String(contentsOfFile: path, encoding: .utf8))

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("andon-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
        try fixture.write(to: Paths.claudeSettings, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// Remove anything Andon Cord installed, yielding the config as it would
    /// look on a machine that has never run this app.
    private static func withoutAndonCordEntries(_ source: String) throws -> String {
        var settings = try JSONC.parseObject(source)
        let marker = ClaudeSettingsInstaller.marker

        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let cleaned = groups.compactMap { group -> [String: Any]? in
                    guard var handlers = group["hooks"] as? [[String: Any]] else { return group }
                    handlers.removeAll {
                        ($0["command"] as? String)?.contains(marker) ?? false
                    }
                    guard !handlers.isEmpty else { return nil }
                    var updated = group
                    updated["hooks"] = handlers
                    return updated
                }
                if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        }

        // Put back whatever statusline we displaced, so the fixture has the
        // original owner rather than our wrapper.
        if let statusline = settings["statusLine"] as? [String: Any],
           (statusline["command"] as? String)?.contains("andon-statusline") == true {
            if let data = try? Data(contentsOf: Paths.statuslineChain),
               let chain = try? JSONDecoder().decode(StatuslineChain.self, from: data),
               let command = chain.command, !chain.wasAbsent {
                settings["statusLine"] = ["type": chain.type ?? "command", "command": command]
            } else {
                settings.removeValue(forKey: "statusLine")
            }
        }

        return String(data: try JSONC.serialize(settings), encoding: .utf8) ?? "{}"
    }

    func testRoundTripPreservesEveryForeignKeyAndHook() throws {
        let before = try JSONC.parseObject(fixture)
        let beforeHooks = before["hooks"] as? [String: Any] ?? [:]

        // Every hook command in the original file, so we can prove none vanish.
        func commands(_ settings: [String: Any]) -> Set<String> {
            let hooks = settings["hooks"] as? [String: Any] ?? [:]
            var found = Set<String>()
            for (_, value) in hooks {
                for group in (value as? [[String: Any]] ?? []) {
                    for handler in (group["hooks"] as? [[String: Any]] ?? []) {
                        if let command = handler["command"] as? String { found.insert(command) }
                    }
                }
            }
            return found
        }

        let originalCommands = commands(before)
        XCTAssertFalse(originalCommands.isEmpty, "fixture should already have hooks")

        let installer = ClaudeSettingsInstaller()
        try installer.install()
        XCTAssertEqual(installer.currentStatus(), .installed)

        let installed = try JSONC.parseObject(
            try String(contentsOf: Paths.claudeSettings, encoding: .utf8))
        let installedCommands = commands(installed)
        XCTAssertTrue(originalCommands.isSubset(of: installedCommands),
                      "installing must not drop any pre-existing hook command")

        try installer.uninstall()

        let after = try JSONC.parseObject(
            try String(contentsOf: Paths.claudeSettings, encoding: .utf8))

        XCTAssertEqual(commands(after), originalCommands,
                       "after uninstall the hook set must match the original exactly")
        XCTAssertEqual(
            Set((after["hooks"] as? [String: Any] ?? [:]).keys),
            Set(beforeHooks.keys),
            "no hook event should be added or removed by a round trip")

        for key in before.keys where key != "hooks" && key != "statusLine" {
            XCTAssertNotNil(after[key], "top-level key '\(key)' must survive")
        }
        XCTAssertEqual(
            (after["statusLine"] as? [String: Any])?["command"] as? String,
            (before["statusLine"] as? [String: Any])?["command"] as? String,
            "the original statusline owner must get its entry back")
    }
}
