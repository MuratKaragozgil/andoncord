import XCTest
@testable import AndonKit

/// Cursor installs into `~/.cursor/hooks.json` — the FLAT schema, no inner
/// `hooks` array — with a watch mode and an opt-in shell gate.
final class CursorInstallerTests: XCTestCase {
    var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        Paths.homeOverride = sandbox
    }

    override func tearDownWithError() throws {
        Paths.homeOverride = nil
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ text: String) throws {
        try text.write(to: Paths.cursorHooks, atomically: true, encoding: .utf8)
    }

    private func read() throws -> [String: Any] {
        try JSONC.parseObject(try String(contentsOf: Paths.cursorHooks, encoding: .utf8))
    }

    func testInstallUsesFlatSchemaWithVersionField() throws {
        let installer = CursorHooksInstaller()
        try installer.install(gateEnabled: false)
        XCTAssertEqual(installer.currentStatus(gateEnabled: false), .installed)

        let root = try read()
        XCTAssertEqual(root["version"] as? Int, 1, "Cursor requires the version field")

        let hooks = root["hooks"] as! [String: Any]
        let stop = (hooks["stop"] as! [[String: Any]])[0]
        // Flat: the entry IS the hook object; no nested "hooks" array.
        XCTAssertNotNil(stop["command"])
        XCTAssertNil(stop["hooks"], "Cursor's schema is flat — nesting would be ignored")
        XCTAssertTrue((stop["command"] as! String).contains("--source cursor"))
    }

    func testWatchModeRegistersNoGate() throws {
        try CursorHooksInstaller().install(gateEnabled: false)
        let hooks = try read()["hooks"] as! [String: Any]
        XCTAssertNil(hooks["beforeShellExecution"],
                     "watch mode must not intercept shell commands")
        XCTAssertNotNil(hooks["preToolUse"])
        XCTAssertNotNil(hooks["beforeSubmitPrompt"])
    }

    func testGateModeAddsBlockingShellHookWithSecondsTimeout() throws {
        try CursorHooksInstaller().install(gateEnabled: true)
        let hooks = try read()["hooks"] as! [String: Any]
        let gate = (hooks["beforeShellExecution"] as! [[String: Any]])[0]
        XCTAssertTrue((gate["command"] as! String).contains("--blocking"))
        XCTAssertEqual(gate["timeout"] as? Int, CursorHooksInstaller.gateTimeoutSeconds,
                       "Cursor timeouts are seconds (unlike Gemini's ms)")
    }

    func testTogglingGateOffRemovesTheGateHook() throws {
        let installer = CursorHooksInstaller()
        try installer.install(gateEnabled: true)
        try installer.install(gateEnabled: false)

        let hooks = try read()["hooks"] as! [String: Any]
        XCTAssertNil(hooks["beforeShellExecution"],
                     "a stale gate would keep parking commands the user un-gated")
        XCTAssertEqual(installer.currentStatus(gateEnabled: false), .installed)
    }

    func testStaleGateHookRegistersAsDrift() throws {
        let installer = CursorHooksInstaller()
        try installer.install(gateEnabled: true)
        guard case .drifted = installer.currentStatus(gateEnabled: false) else {
            return XCTFail("gate hook present while setting is off must be drift")
        }
    }

    func testForeignEntriesSurviveRoundTrip() throws {
        try write("""
        { "version": 1,
          "hooks": {
            "afterFileEdit": [ { "command": "./format.sh" } ],
            "stop": [ { "command": "./their-audit.sh" } ]
          } }
        """)
        let installer = CursorHooksInstaller()
        try installer.install(gateEnabled: false)
        try installer.uninstall()

        let hooks = try read()["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["afterFileEdit"] as! [[String: Any]]).count, 1)
        let stopCommands = (hooks["stop"] as! [[String: Any]])
            .compactMap { $0["command"] as? String }
        XCTAssertEqual(stopCommands, ["./their-audit.sh"])
    }

    func testUninstallRemovesFileWeWhollyOwned() throws {
        let installer = CursorHooksInstaller()
        try installer.install(gateEnabled: false)
        try installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.cursorHooks.path),
                       "only {version:1} scaffolding left → file should go")
    }
}

/// Cursor payloads through the shared store: camelCase events, conversation_id
/// keying, cursor_version re-tagging, and the flat permission decisions.
@MainActor
final class CursorStoreTests: XCTestCase {
    var outcomes: [UUID: HookResponse?] = [:]

    private func payload(_ json: [String: Any]) throws -> HookPayload {
        try JSONDecoder().decode(HookPayload.self,
                                 from: JSONSerialization.data(withJSONObject: json))
    }

    @discardableResult
    private func send(_ store: BoardStore, _ json: [String: Any],
                      source: AgentSource = .cursor,
                      blocking: Bool = false) throws -> PendingDecision? {
        let env = HookEnvelope(blocking: blocking, agentSource: source,
                               payload: try payload(json), raw: .object([:]),
                               terminal: nil, shimPid: 1)
        guard blocking else { store.apply(env, decision: nil); return nil }
        let id = UUID()
        let decision = PendingDecision(id: id, envelope: env) { [weak self] r in
            self?.outcomes[id] = r
        }
        store.apply(env, decision: decision)
        return decision
    }

    func testConversationIdKeysTheSession() throws {
        let store = BoardStore()
        try send(store, ["conversation_id": "conv-1", "cursor_version": "2.4",
                         "hook_event_name": "beforeSubmitPrompt",
                         "prompt": "add pagination",
                         "workspace_roots": ["/Users/dev/webapp"]])
        let session = store.session(id: "conv-1")
        XCTAssertNotNil(session, "conversation_id must work as the session key")
        XCTAssertEqual(session?.title, "add pagination")
        XCTAssertEqual(session?.cwd, "/Users/dev/webapp",
                       "workspace_roots is the cwd fallback")
    }

    func testCursorVersionRetagsClaudeCompatDoubleFires() throws {
        // cursor-agent also runs hooks from Claude's settings.json, which
        // arrive tagged --source claude. The payload's cursor_version settles
        // the identity, and the shared conversation id collapses the double
        // fire into one session.
        let store = BoardStore()
        try send(store, ["conversation_id": "conv-2", "cursor_version": "2.4",
                         "hook_event_name": "sessionStart"],
                 source: .claude)
        XCTAssertEqual(store.session(id: "conv-2")?.agent, .cursor)
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testShellGateParksAndAllowsInCursorFormat() throws {
        let store = BoardStore()
        let decision = try send(store, [
            "conversation_id": "conv-3", "cursor_version": "2.4",
            "hook_event_name": "beforeShellExecution",
            "command": "npm run deploy", "cwd": "/Users/dev/webapp",
        ], blocking: true)!

        let session = store.session(id: "conv-3")!
        XCTAssertEqual(session.state, .cordPulled(.permission))
        // Top-level command becomes a shell presentation for the card.
        XCTAssertEqual(session.pending?.toolName, "run_shell_command")

        store.approve(session.pending!)

        let response = try XCTUnwrap(outcomes[decision.id] ?? nil)
        XCTAssertEqual(response.permission, "allow",
                       "Cursor expects the flat permission contract")
        XCTAssertNil(response.hookSpecificOutput,
                     "no Claude envelope on a Cursor decision")
    }

    func testDenyAndDeferUseCursorContract() throws {
        let store = BoardStore()
        let d1 = try send(store, ["conversation_id": "c4", "cursor_version": "2.4",
                                  "hook_event_name": "beforeShellExecution",
                                  "command": "rm -rf /"], blocking: true)!
        store.deny(store.session(id: "c4")!.pending!, reason: "no thanks")
        let r1 = try XCTUnwrap(outcomes[d1.id] ?? nil)
        XCTAssertEqual(r1.permission, "deny")
        XCTAssertEqual(r1.agentMessage, "no thanks")

        let d2 = try send(store, ["conversation_id": "c4", "cursor_version": "2.4",
                                  "hook_event_name": "beforeShellExecution",
                                  "command": "make test"], blocking: true)!
        store.deferToAgent(store.session(id: "c4")!.pending!)
        let r2 = try XCTUnwrap(outcomes[d2.id] ?? nil)
        XCTAssertEqual(r2.permission, "ask",
                       "defer hands the decision to Cursor's own UI")
    }

    func testStopStatusErrorBecomesFailedState() throws {
        let store = BoardStore()
        try send(store, ["conversation_id": "c5", "cursor_version": "2.4",
                         "hook_event_name": "beforeSubmitPrompt", "prompt": "go"])
        try send(store, ["conversation_id": "c5", "cursor_version": "2.4",
                         "hook_event_name": "stop", "status": "error"])
        guard case .failed = store.session(id: "c5")?.state else {
            return XCTFail("Cursor stop(status: error) should read as failed")
        }
    }
}
