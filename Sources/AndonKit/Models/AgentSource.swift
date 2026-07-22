import Foundation

/// Which coding agent a session belongs to.
///
/// AndonCord started Claude-only, but Claude Code and Codex turned out to share
/// almost the same hook contract — same event names, same stdin-JSON payloads,
/// the same `hookSpecificOutput` decision format. So the shim, the socket, the
/// board, and the request cards are all agent-agnostic; the only things that
/// differ per agent are where hooks get installed (`~/.claude/settings.json`
/// vs `~/.codex/hooks.json`) and how a session is labelled on the board.
public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    /// A session whose source the shim did not tag. Decodes here rather than
    /// failing, so an older shim or an unknown agent still shows up.
    case unknown

    /// Parsed from the shim's `--source` argument.
    public init(argument: String?) {
        switch argument?.lowercased() {
        case "claude", "claude-code": self = .claude
        case "codex": self = .codex
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .unknown: return "Agent"
        }
    }

    /// Two-letter tag for the compact board badge.
    public var badge: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "CX"
        case .unknown: return "··"
        }
    }
}
