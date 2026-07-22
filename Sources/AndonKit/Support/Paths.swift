import Foundation

/// Every on-disk location AndonCord touches, in one place.
///
/// Everything the app owns lives under `~/.andoncord`. The only file outside
/// that tree we ever write is `~/.claude/settings.json`, and that write is
/// always additive + backed up (see `ClaudeSettingsInstaller`).
public enum Paths {
    /// Redirects every path below a different root.
    ///
    /// Exists so the installer can be exercised against a throwaway copy of a
    /// real `settings.json` — the merge logic is the one part of this codebase
    /// that can damage something the user cares about, and it needs to be
    /// testable without pointing it at their actual config.
    nonisolated(unsafe) public static var homeOverride: URL?

    public static var home: URL {
        if let homeOverride { return homeOverride }
        // `NSHomeDirectory()` resolves through the password database and
        // ignores `$HOME`, so a subprocess cannot be redirected by setting it.
        // This gives the shim an explicit, inheritable override — needed to
        // point a spawned `andon-hook` at a test socket, and useful when
        // debugging against a scratch config.
        if let path = ProcessInfo.processInfo.environment["ANDON_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// `~/.andoncord`
    public static var root: URL { home.appendingPathComponent(".andoncord") }

    /// Launcher script + any cached bundle location.
    public static var bin: URL { root.appendingPathComponent("bin") }
    /// Socket and pidfile. Recreated on every launch.
    public static var run: URL { root.appendingPathComponent("run") }
    /// Backups of files we modified outside our own tree.
    public static var backups: URL { root.appendingPathComponent("backups") }
    /// User-supplied sound packs.
    public static var sounds: URL { root.appendingPathComponent("sounds") }

    /// The shim Claude Code invokes. A shell launcher, not the binary itself,
    /// so that moving or updating the .app never breaks an installed hook.
    public static var hookLauncher: URL { bin.appendingPathComponent("andon-hook") }
    public static var statuslineLauncher: URL { bin.appendingPathComponent("andon-statusline") }
    /// Written by the launcher when it locates the bundle via Spotlight.
    public static var bundleCache: URL { bin.appendingPathComponent(".bundle-cache") }

    public static var socket: URL { run.appendingPathComponent("andon.sock") }
    public static var pidFile: URL { run.appendingPathComponent("andon.pid") }

    /// Where the statusline shim parks the `rate_limits` blob it sees.
    public static var rateLimitsCache: URL { root.appendingPathComponent("rate-limits.json") }
    /// Records what `statusLine.command` was before we took it over, so
    /// uninstall can put it back exactly.
    public static var statuslineChain: URL { root.appendingPathComponent("statusline-chain.json") }

    public static var claudeDir: URL { home.appendingPathComponent(".claude") }
    public static var claudeSettings: URL { claudeDir.appendingPathComponent("settings.json") }

    public static var codexDir: URL { home.appendingPathComponent(".codex") }
    /// Codex hooks live in their own file, separate from `config.toml` — which
    /// matters, because `config.toml` holds a single `notify` key we must not
    /// touch, whereas hook sources are additive.
    public static var codexHooks: URL { codexDir.appendingPathComponent("hooks.json") }
    public static var codexConfig: URL { codexDir.appendingPathComponent("config.toml") }

    public static var geminiDir: URL { home.appendingPathComponent(".gemini") }
    /// Gemini hooks live in the main settings file, Claude-style: a `hooks`
    /// key whose event arrays merge additively across config scopes.
    public static var geminiSettings: URL { geminiDir.appendingPathComponent("settings.json") }

    public static var cursorDir: URL { home.appendingPathComponent(".cursor") }
    /// Cursor's user-level hooks file. Flat schema (no inner `hooks` array),
    /// watched and hot-reloaded by Cursor itself.
    public static var cursorHooks: URL { cursorDir.appendingPathComponent("hooks.json") }

    /// Socket paths are capped at 104 bytes on Darwin (`sun_path`). A long
    /// username can push `~/.andoncord/run/andon.sock` past that, so callers
    /// need a way to find out before they try to bind.
    public static var socketPathFitsInSunPath: Bool {
        socket.path.utf8.count < 104
    }

    public static func ensureDirectories() throws {
        for dir in [root, bin, run, backups, sounds] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                // Session titles and prompts pass through here; keep it private.
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
