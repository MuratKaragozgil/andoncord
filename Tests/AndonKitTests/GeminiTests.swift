import XCTest
@testable import AndonKit

/// Gemini installs into `~/.gemini/settings.json` with Gemini's own event
/// vocabulary. Same guarantees as the other installers, plus the event-name
/// normalisation that lets the shared store understand Gemini payloads.
final class GeminiInstallerTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ text: String) throws {
        try text.write(to: Paths.geminiSettings, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: Any] {
        try JSONC.parseObject(try String(contentsOf: Paths.geminiSettings, encoding: .utf8))
    }

    func testInstallUsesGeminiEventNamesAndSourceTag() throws {
        let installer = GeminiHooksInstaller()
        try installer.install()
        XCTAssertEqual(installer.currentStatus(), .installed)

        let hooks = try read()["hooks"] as! [String: Any]
        // Gemini vocabulary, not Claude's.
        XCTAssertNotNil(hooks["BeforeTool"])
        XCTAssertNotNil(hooks["AfterAgent"])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["Stop"])

        let group = (hooks["BeforeTool"] as! [[String: Any]])[0]
        let handler = (group["hooks"] as! [[String: Any]])[0]
        let command = handler["command"] as! String
        XCTAssertTrue(command.contains("--source gemini"))
        XCTAssertTrue(command.hasSuffix("exit 0'"), "must fail open")
        XCTAssertEqual(handler["name"] as? String, "andoncord",
                       "Gemini's /hooks panel lists hooks by name")
        XCTAssertNil(handler["timeout"],
                     "Gemini timeouts are in ms; never blocking, so never set one")
    }

    func testNotificationHookNarrowsToToolPermission() throws {
        try GeminiHooksInstaller().install()
        let hooks = try read()["hooks"] as! [String: Any]
        let group = (hooks["Notification"] as! [[String: Any]])[0]
        XCTAssertEqual(group["matcher"] as? String, "ToolPermission")
    }

    func testForeignSettingsAndHooksSurviveRoundTrip() throws {
        try write("""
        {
          "theme": "dark",
          "hooks": {
            "BeforeTool": [
              { "matcher": "run_shell_command",
                "hooks": [ { "type": "command", "command": "my-guard.sh" } ] }
            ]
          }
        }
        """)
        let installer = GeminiHooksInstaller()
        try installer.install()
        try installer.uninstall()

        let after = try read()
        XCTAssertEqual(after["theme"] as? String, "dark",
                       "this is Gemini's MAIN settings file — foreign keys must survive")
        let groups = (after["hooks"] as! [String: Any])["BeforeTool"] as! [[String: Any]]
        let commands = groups
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, ["my-guard.sh"])
    }

    func testUninstallNeverDeletesTheSettingsFile() throws {
        let installer = GeminiHooksInstaller()
        try installer.install()
        try installer.uninstall()
        // Unlike Codex's dedicated hooks.json, settings.json belongs to Gemini.
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.geminiSettings.path))
    }

    func testRepeatedInstallsDoNotStack() throws {
        let installer = GeminiHooksInstaller()
        try installer.install()
        try installer.install()
        let hooks = try read()["hooks"] as! [String: Any]
        let ours = (hooks["AfterAgent"] as! [[String: Any]])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ($0["command"] as? String)?.contains("--source gemini") == true }
        XCTAssertEqual(ours.count, 1)
    }
}

/// The normalisation layer that lets one store speak every agent's dialect.
final class EventNormalizationTests: XCTestCase {
    func testGeminiEventNamesMapOntoCanonicalOnes() {
        XCTAssertEqual(HookEventName.normalized(from: "BeforeTool"), .preToolUse)
        XCTAssertEqual(HookEventName.normalized(from: "AfterTool"), .postToolUse)
        XCTAssertEqual(HookEventName.normalized(from: "BeforeAgent"), .userPromptSubmit)
        XCTAssertEqual(HookEventName.normalized(from: "AfterAgent"), .stop)
        XCTAssertEqual(HookEventName.normalized(from: "PreCompress"), .preCompact)
    }

    func testClaudeNamesPassThroughUnchanged() {
        XCTAssertEqual(HookEventName.normalized(from: "PreToolUse"), .preToolUse)
        XCTAssertEqual(HookEventName.normalized(from: "PermissionRequest"), .permissionRequest)
    }

    func testUnknownNamesResolveToNilNotACrash() {
        XCTAssertNil(HookEventName.normalized(from: "SomeFutureEvent"))
        XCTAssertNil(HookEventName.normalized(from: nil))
    }
}

/// Gemini payloads flowing through the shared store.
@MainActor
final class GeminiStoreTests: XCTestCase {
    private func send(_ store: BoardStore, _ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let payload = try JSONDecoder().decode(HookPayload.self, from: data)
        store.apply(HookEnvelope(blocking: false, agentSource: .gemini, payload: payload,
                                 raw: .object([:]), terminal: nil, shimPid: 1),
                    decision: nil)
    }

    func testGeminiLifecycleDrivesTheSameStates() throws {
        let store = BoardStore()
        try send(store, ["session_id": "g1", "hook_event_name": "SessionStart",
                         "source": "startup", "cwd": "/tmp/proj"])
        try send(store, ["session_id": "g1", "hook_event_name": "BeforeAgent",
                         "prompt": "refactor the parser"])
        XCTAssertEqual(store.session(id: "g1")?.state, .running)
        XCTAssertEqual(store.session(id: "g1")?.title, "refactor the parser")
        XCTAssertEqual(store.session(id: "g1")?.agent, .gemini)

        try send(store, ["session_id": "g1", "hook_event_name": "BeforeTool",
                         "tool_name": "run_shell_command",
                         "tool_input": ["command": "npm test"]])
        XCTAssertEqual(store.session(id: "g1")?.state, .working(tool: "run_shell_command"))

        // Approval dialog appeared. One-way: attention, not a parked request.
        try send(store, ["session_id": "g1", "hook_event_name": "Notification",
                         "notification_type": "ToolPermission",
                         "message": "Tool Shell requires execution"])
        XCTAssertEqual(store.session(id: "g1")?.state, .cordPulled(.attention))
        XCTAssertNil(store.session(id: "g1")?.pending,
                     "Gemini approvals cannot be answered, so nothing must park")

        // AfterAgent ends the turn with the reply text.
        try send(store, ["session_id": "g1", "hook_event_name": "AfterAgent",
                         "prompt_response": "Refactored and green."])
        XCTAssertEqual(store.session(id: "g1")?.state, .done)
        XCTAssertEqual(store.session(id: "g1")?.lastAssistantMessage, "Refactored and green.")
    }

    func testGeminiToolNamesRenderLikeNativeOnes() {
        let shell = ToolPresentation.make(
            toolName: "run_shell_command",
            input: .object(["command": .string("npm run build")]))
        XCTAssertEqual(shell.title, "Shell")
        XCTAssertEqual(shell.subtitle, "npm run build")

        let edit = ToolPresentation.make(
            toolName: "replace",
            input: .object(["file_path": .string("/a/b/parser.ts"),
                            "old_string": .string("x"), "new_string": .string("y")]))
        XCTAssertEqual(edit.title, "Edit")
        XCTAssertEqual(edit.subtitle, "b/parser.ts")
    }
}
