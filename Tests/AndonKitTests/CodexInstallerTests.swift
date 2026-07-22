import XCTest
@testable import AndonKit

/// Codex installs into `~/.codex/hooks.json`. Same guarantees as the Claude
/// installer — additive, idempotent, reversible — verified against a throwaway
/// HOME so it never touches the real file.
final class CodexInstallerTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ text: String) throws {
        try text.write(to: Paths.codexHooks, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: Any] {
        try JSONC.parseObject(try String(contentsOf: Paths.codexHooks, encoding: .utf8))
    }

    func testInstallIntoEmptyDirCreatesCodexSourcedHooks() throws {
        let installer = CodexHooksInstaller()
        try installer.install()
        XCTAssertEqual(installer.currentStatus(), .installed)

        let hooks = try read()["hooks"] as! [String: Any]
        let group = (hooks["PermissionRequest"] as! [[String: Any]])[0]
        let command = ((group["hooks"] as! [[String: Any]])[0])["command"] as! String
        XCTAssertTrue(command.contains("--source codex"), "must tag the agent")
        XCTAssertTrue(command.contains("--blocking"))
        XCTAssertTrue(command.hasSuffix("exit 0'"), "must fail open")
    }

    func testForeignCodexHooksSurviveInstallAndUninstall() throws {
        // A user with their own Codex hook already registered.
        try write("""
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [
                  { "type": "command", "command": "python3 ~/.codex/my-guard.py" } ] }
            ]
          }
        }
        """)
        let installer = CodexHooksInstaller()
        try installer.install()

        let afterInstall = (try read()["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        let commands = afterInstall
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains { $0.contains("my-guard.py") }, "their hook stays")
        XCTAssertTrue(commands.contains { $0.contains("--source codex") }, "ours is added")

        try installer.uninstall()
        let afterUninstall = (try read()["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        let remaining = afterUninstall
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(remaining, ["python3 ~/.codex/my-guard.py"],
                       "uninstall removes only ours, leaving theirs intact")
    }

    func testRepeatedInstallsDoNotStack() throws {
        let installer = CodexHooksInstaller()
        try installer.install()
        try installer.install()
        try installer.install()

        let hooks = try read()["hooks"] as! [String: Any]
        let ours = (hooks["Stop"] as! [[String: Any]])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ($0["command"] as? String)?.contains("--source codex") == true }
        XCTAssertEqual(ours.count, 1, "reinstall replaces, never appends")
    }

    func testUninstallRemovesTheFileWhenWeOwnedAllOfIt() throws {
        let installer = CodexHooksInstaller()
        try installer.install()
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.codexHooks.path),
                       "a file that only ever held our hooks should be removed")
    }

    func testDoesNotRegisterCodexUnsupportedEvents() throws {
        try CodexHooksInstaller().install()
        let hooks = try read()["hooks"] as! [String: Any]
        // Codex has no SessionEnd / Notification; registering them would spawn
        // the shim for events that never fire.
        XCTAssertNil(hooks["SessionEnd"])
        XCTAssertNil(hooks["Notification"])
        XCTAssertNotNil(hooks["PermissionRequest"])
    }

    // MARK: - Feature-flag detection

    func testDetectsDisabledHooksFeatureInConfig() throws {
        try "[features]\nhooks = false\n".write(
            to: Paths.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexHooksInstaller().hooksFeatureDisabled())
    }

    func testDetectsLegacyDisabledFlag() throws {
        try "[features]\ncodex_hooks = false\n".write(
            to: Paths.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertTrue(CodexHooksInstaller().hooksFeatureDisabled())
    }

    func testAssumesEnabledWhenConfigSaysNothing() throws {
        try "model = \"gpt-5\"\n".write(
            to: Paths.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertFalse(CodexHooksInstaller().hooksFeatureDisabled())
    }

    func testIgnoresCommentedOutDisable() throws {
        try "[features]\n# hooks = false\n".write(
            to: Paths.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertFalse(CodexHooksInstaller().hooksFeatureDisabled(),
                       "a commented line is not an active setting")
    }
}
