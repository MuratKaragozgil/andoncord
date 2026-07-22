import Foundation

/// Which terminal a session is running in, and how precisely we can get back
/// to it.
public enum TerminalKind: String, Codable, Sendable, CaseIterable {
    case iTerm2
    case appleTerminal
    case ghostty
    case warp
    case wezTerm
    case kitty
    case alacritty
    case hyper
    case zed
    case vscode
    case cursor
    case windsurf
    /// Claude Code running inside the Claude desktop app rather than a
    /// terminal emulator. There is no tty and no terminal environment at all,
    /// so the best a jump can do is raise the app.
    case claudeDesktop
    case unknown

    public var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .appleTerminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .wezTerm: return "WezTerm"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        case .hyper: return "Hyper"
        case .zed: return "Zed"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .claudeDesktop: return "Claude"
        // Honest rather than reassuring: calling an unidentified host
        // "Terminal" invites a click that cannot possibly land anywhere.
        case .unknown: return "Unknown host"
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .iTerm2: return "com.googlecode.iterm2"
        case .appleTerminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .wezTerm: return "com.github.wez.wezterm"
        case .kitty: return "net.kovidgoyal.kitty"
        case .alacritty: return "org.alacritty"
        case .hyper: return "co.zeit.hyper"
        case .zed: return "dev.zed.Zed"
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .windsurf: return "com.exafunction.windsurf"
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .unknown: return nil
        }
    }

    /// Whether we can land on the exact tab/pane, or only raise the app.
    public var supportsPreciseJump: Bool {
        switch self {
        case .iTerm2, .appleTerminal, .ghostty, .wezTerm, .kitty, .warp:
            return true
        case .alacritty, .hyper, .zed, .vscode, .cursor, .windsurf,
             .claudeDesktop, .unknown:
            return false
        }
    }
}

/// Terminal identity captured by the hook shim.
///
/// This is the whole reason the shim is a real process rather than an HTTP
/// callback: Claude Code spawns it as a child of the user's shell, so it
/// inherits the controlling TTY and the terminal's environment variables.
/// Those are the only reliable handles on "which tab is this session in" —
/// the hook payload itself carries no terminal information at all.
public struct TerminalContext: Codable, Sendable, Hashable {
    public var kind: TerminalKind
    /// e.g. `/dev/ttys004`. The primary correlation key for most terminals.
    public var ttyPath: String?
    public var termProgram: String?
    public var termProgramVersion: String?

    /// Per-terminal pane/tab handles, whichever the terminal publishes.
    public var itermSessionId: String?
    public var termSessionId: String?
    public var wezTermPane: String?
    public var kittyWindowId: String?
    public var kittyListenOn: String?
    public var zellijSession: String?
    public var windowId: String?

    /// tmux multiplexes many panes onto one TTY, so when it is present the
    /// pane handle matters more than the TTY.
    public var tmuxSocket: String?
    public var tmuxPane: String?

    public var isVSCodeTerminal: Bool
    public var shimParentPid: Int32?
    /// `__CFBundleIdentifier` of whatever launched the shell.
    ///
    /// The fallback that makes a jump possible at all when no terminal is
    /// recognised — Claude Code increasingly runs somewhere that is not a
    /// terminal emulator, and this is the only handle on the host app.
    public var hostBundleIdentifier: String?

    public init(
        kind: TerminalKind = .unknown,
        ttyPath: String? = nil,
        termProgram: String? = nil,
        termProgramVersion: String? = nil,
        itermSessionId: String? = nil,
        termSessionId: String? = nil,
        wezTermPane: String? = nil,
        kittyWindowId: String? = nil,
        kittyListenOn: String? = nil,
        zellijSession: String? = nil,
        windowId: String? = nil,
        tmuxSocket: String? = nil,
        tmuxPane: String? = nil,
        isVSCodeTerminal: Bool = false,
        shimParentPid: Int32? = nil,
        hostBundleIdentifier: String? = nil
    ) {
        self.kind = kind
        self.ttyPath = ttyPath
        self.termProgram = termProgram
        self.termProgramVersion = termProgramVersion
        self.itermSessionId = itermSessionId
        self.termSessionId = termSessionId
        self.wezTermPane = wezTermPane
        self.kittyWindowId = kittyWindowId
        self.kittyListenOn = kittyListenOn
        self.zellijSession = zellijSession
        self.windowId = windowId
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.isVSCodeTerminal = isVSCodeTerminal
        self.shimParentPid = shimParentPid
        self.hostBundleIdentifier = hostBundleIdentifier
    }

    /// The app a jump should raise, if any. `nil` means the row should not
    /// offer a jump at all.
    public var activationBundleIdentifier: String? {
        kind.bundleIdentifier ?? hostBundleIdentifier
    }

    public var isInsideTmux: Bool { tmuxSocket?.isEmpty == false }

    public var displayName: String {
        if isInsideTmux { return "\(kind.displayName) · tmux" }
        return kind.displayName
    }

    /// Capture from an environment dictionary. Kept pure and injectable so it
    /// is testable without spawning a terminal.
    public static func capture(
        environment: [String: String],
        ttyPath: String?,
        parentPid: Int32?
    ) -> TerminalContext {
        let termProgram = environment["TERM_PROGRAM"]
        let kind = detectKind(environment: environment, termProgram: termProgram)

        return TerminalContext(
            kind: kind,
            ttyPath: ttyPath,
            termProgram: termProgram,
            termProgramVersion: environment["TERM_PROGRAM_VERSION"],
            itermSessionId: environment["ITERM_SESSION_ID"],
            termSessionId: environment["TERM_SESSION_ID"],
            wezTermPane: environment["WEZTERM_PANE"],
            kittyWindowId: environment["KITTY_WINDOW_ID"],
            kittyListenOn: environment["KITTY_LISTEN_ON"],
            zellijSession: environment["ZELLIJ_SESSION_NAME"],
            windowId: environment["WINDOWID"],
            tmuxSocket: environment["TMUX"],
            tmuxPane: environment["TMUX_PANE"],
            isVSCodeTerminal: environment["VSCODE_INJECTION"] != nil
                || termProgram == "vscode",
            shimParentPid: parentPid,
            hostBundleIdentifier: environment["__CFBundleIdentifier"]
        )
    }

    private static func detectKind(
        environment: [String: String], termProgram: String?
    ) -> TerminalKind {
        // Editor-hosted terminals set TERM_PROGRAM=vscode regardless of which
        // fork is running, so disambiguate on the app path before falling
        // through to the generic mapping.
        if termProgram == "vscode" || environment["VSCODE_INJECTION"] != nil {
            let appName = environment["__CFBundleIdentifier"]
                ?? environment["VSCODE_GIT_ASKPASS_MAIN"] ?? ""
            let lowered = appName.lowercased()
            if lowered.contains("cursor") { return .cursor }
            if lowered.contains("windsurf") { return .windsurf }
            return .vscode
        }

        switch termProgram {
        case "iTerm.app": return .iTerm2
        case "Apple_Terminal": return .appleTerminal
        case "ghostty": return .ghostty
        case "WarpTerminal", "WarpPreview": return .warp
        case "WezTerm": return .wezTerm
        case "Hyper": return .hyper
        case "zed": return .zed
        default: break
        }

        if environment["KITTY_WINDOW_ID"] != nil { return .kitty }
        if environment["GHOSTTY_RESOURCES_DIR"] != nil { return .ghostty }
        if environment["ALACRITTY_WINDOW_ID"] != nil
            || environment["ALACRITTY_SOCKET"] != nil { return .alacritty }
        if environment["WEZTERM_PANE"] != nil { return .wezTerm }

        // Claude Code hosted by the Claude desktop app sets no terminal
        // variables whatsoever, so the launching bundle is the only signal.
        if environment["__CFBundleIdentifier"] == "com.anthropic.claudefordesktop" {
            return .claudeDesktop
        }
        return .unknown
    }
}
