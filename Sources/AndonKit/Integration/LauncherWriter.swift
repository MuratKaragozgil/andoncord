import Foundation

/// Writes the small shell launchers that `settings.json` actually points at.
///
/// The hook entries deliberately reference `~/.andoncord/bin/andon-hook`
/// rather than the binary inside the app bundle. That indirection matters:
/// people move apps to /Applications, Sparkle-style updaters replace the
/// bundle in place, and Homebrew installs somewhere else entirely. A hardcoded
/// bundle path in someone's settings file would break on any of those and
/// leave hooks silently pointing at nothing. The launcher re-resolves the
/// bundle on every invocation, and exits 0 when it cannot find it.
public enum LauncherWriter {
    public static let bundleIdentifier = "app.andoncord.mac"

    /// Where the real helper lives right now.
    ///
    /// In a packaged build this is inside the bundle. In a `swift run` build
    /// it sits next to the app binary in `.build`, which is what makes the
    /// whole thing debuggable without packaging first.
    public static func resolveHelperBinary() -> URL? {
        let bundleURL = Bundle.main.bundleURL

        let candidates = [
            // Packaged: AndonCord.app/Contents/MacOS/andon-hook
            bundleURL.appendingPathComponent("Contents/MacOS/andon-hook"),
            // Development: sibling of the app executable in .build/debug
            bundleURL.appendingPathComponent("andon-hook"),
            bundleURL.deletingLastPathComponent().appendingPathComponent("andon-hook"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func writeLaunchers() throws {
        try Paths.ensureDirectories()
        let primary = resolveHelperBinary()?.path

        try write(script: launcherScript(primary: primary, extraArguments: nil),
                  to: Paths.hookLauncher)
        try write(script: launcherScript(primary: primary, extraArguments: "--statusline"),
                  to: Paths.statuslineLauncher)
    }

    public static func removeLaunchers() {
        try? FileManager.default.removeItem(at: Paths.hookLauncher)
        try? FileManager.default.removeItem(at: Paths.statuslineLauncher)
        try? FileManager.default.removeItem(at: Paths.bundleCache)
    }

    private static func write(script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Single-quote a path for `sh`, escaping any embedded quote.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func launcherScript(primary: String?, extraArguments: String?) -> String {
        let forward = extraArguments.map { "\($0) \"$@\"" } ?? "\"$@\""
        var lines = [
            "#!/bin/sh",
            "# AndonCord launcher — generated, do not edit.",
            "# Resolves the helper inside the app bundle, then execs it.",
            "# Every failure path exits 0 so a hook never blocks Claude Code.",
            "",
        ]

        if let primary {
            lines.append("P=\(shellQuote(primary))")
            lines.append("[ -x \"$P\" ] && exec \"$P\" \(forward)")
            lines.append("")
        }

        lines.append(contentsOf: [
            "for C in \\",
            "  \"/Applications/AndonCord.app/Contents/MacOS/andon-hook\" \\",
            "  \"$HOME/Applications/AndonCord.app/Contents/MacOS/andon-hook\"; do",
            "  [ -x \"$C\" ] && exec \"$C\" \(forward)",
            "done",
            "",
            "# Cached Spotlight result, so the lookup below runs at most once.",
            "CACHE=\"$HOME/.andoncord/bin/.bundle-cache\"",
            "if [ -f \"$CACHE\" ]; then",
            "  read -r B < \"$CACHE\"",
            "  [ -n \"$B\" ] && [ -x \"$B\" ] && exec \"$B\" \(forward)",
            "fi",
            "",
            "B=\"$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == \"\(bundleIdentifier)\"' 2>/dev/null | /usr/bin/head -1)/Contents/MacOS/andon-hook\"",
            "if [ -x \"$B\" ]; then",
            "  printf '%s\\n' \"$B\" > \"$CACHE\" 2>/dev/null",
            "  exec \"$B\" \(forward)",
            "fi",
            "",
            "# App not installed or not found. Do nothing, successfully.",
            "exit 0",
            "",
        ])
        return lines.joined(separator: "\n")
    }
}
