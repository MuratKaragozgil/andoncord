import XCTest
@testable import AndonKit

/// Host detection.
///
/// Claude Code is not always run in a terminal emulator, and the first version
/// of this assumed it was — a session hosted by the Claude desktop app came
/// through as `.unknown`, displayed as "Terminal", offered a clickable row,
/// and then failed with "no bundle identifier". These cases pin that down.
final class TerminalContextTests: XCTestCase {

    private func capture(_ environment: [String: String]) -> TerminalContext {
        TerminalContext.capture(environment: environment, ttyPath: nil, parentPid: nil)
    }

    func testClaudeDesktopIsRecognisedWithNoTerminalVariables() {
        // Exactly what the shim sees there: no TERM_PROGRAM, no tty, nothing.
        let context = capture(["__CFBundleIdentifier": "com.anthropic.claudefordesktop"])

        XCTAssertEqual(context.kind, .claudeDesktop)
        XCTAssertEqual(context.displayName, "Claude")
        XCTAssertEqual(context.activationBundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertFalse(context.kind.supportsPreciseJump,
                       "there is no tab to address, and the UI must not claim otherwise")
    }

    func testUnrecognisedHostStillOffersActivationViaItsBundle() {
        let context = capture(["__CFBundleIdentifier": "com.example.SomeNewTerminal"])

        XCTAssertEqual(context.kind, .unknown)
        XCTAssertEqual(context.activationBundleIdentifier, "com.example.SomeNewTerminal",
                       "raising the host beats refusing to do anything")
    }

    func testSessionWithNoIdentifiableHostOffersNoJump() {
        // A cron job or detached process: nothing to raise.
        let context = capture([:])

        XCTAssertEqual(context.kind, .unknown)
        XCTAssertNil(context.activationBundleIdentifier,
                     "the row must not present itself as clickable")
        XCTAssertEqual(context.displayName, "Unknown host")
    }

    func testKnownTerminalWinsOverHostBundle() {
        // iTerm2 sets both; the terminal identity is the more specific signal.
        let context = capture([
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t1p0:ABC",
            "__CFBundleIdentifier": "com.googlecode.iterm2",
        ])

        XCTAssertEqual(context.kind, .iTerm2)
        XCTAssertEqual(context.activationBundleIdentifier, "com.googlecode.iterm2")
        XCTAssertTrue(context.kind.supportsPreciseJump)
    }

    func testTmuxPaneIsCapturedAlongsideTheHostTerminal() {
        let context = capture([
            "TERM_PROGRAM": "ghostty",
            "TMUX": "/private/tmp/tmux-501/default,4242,0",
            "TMUX_PANE": "%3",
        ])

        XCTAssertEqual(context.kind, .ghostty)
        XCTAssertTrue(context.isInsideTmux)
        XCTAssertEqual(context.tmuxPane, "%3")
        XCTAssertEqual(context.displayName, "Ghostty · tmux")
    }

    func testEditorForksAreDistinguishedFromPlainVSCode() {
        let cursor = capture([
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92cursor",
        ])
        XCTAssertEqual(cursor.kind, .cursor)

        let vscode = capture([
            "TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.microsoft.VSCode",
        ])
        XCTAssertEqual(vscode.kind, .vscode)
    }

    func testEveryKindThatClaimsPreciseJumpHasABundleIdentifier() {
        // A kind that supports precise jump but cannot be activated would be
        // able to select a tab and then fail to raise the window.
        for kind in TerminalKind.allCases where kind.supportsPreciseJump {
            XCTAssertNotNil(kind.bundleIdentifier, "\(kind) claims precise jump")
        }
    }
}
