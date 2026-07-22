# Andon Cord

A macOS notch app for Claude Code.

On a factory line, any worker can pull the andon cord to stop production and
ask for help, and a board above the floor shows the status of every station.
That is what this is: Claude Code pulls the cord when it needs you, the board
in your notch lights up, and you answer without leaving your editor.

Claude-Code-only, on purpose. One agent supported properly beats twenty
supported shallowly — it is what lets the permission card render a real diff,
the plan reviewer render real Markdown, and questions be answered from the
notch instead of just announced.

---

## What it does

| | |
|---|---|
| **Watch** | Every session's state — idle, running, which tool, done, failed. |
| **Answer** | Approve or deny tool calls, answer `AskUserQuestion`, review and revise plans. |
| **Jump** | Click a session to land in its exact terminal tab, split, or tmux pane. |
| **Budget** | 5-hour and 7-day quota, read from Claude Code itself rather than guessed. |
| **Hear** | Synthesized 8-bit cues, one per event, distinct enough to learn by ear. |

Everything is local. No account, no server, no telemetry, no network calls.

---

## How it works

```
Claude Code ──spawns──▶ andon-hook ──unix socket──▶ Andon Cord.app
   (hooks)              (the shim)                   (the board)
      ▲                                                   │
      └──────────── decision JSON on stdout ◀─────────────┘
```

**The shim is a real process, not an HTTP callback.** Claude Code spawns it as
a child of your shell, so it inherits the controlling TTY and the terminal's
environment variables. That is the only reliable way to learn which tab a
session lives in — the hook payload carries no terminal information at all.

**Blocking hooks are how approval works.** `PermissionRequest` is registered
with a 24-hour timeout. The shim writes the request to the socket and then
blocks on `read()`. Claude Code is genuinely paused during that time; when you
click Allow, the decision travels back down the same connection, the shim
prints it to stdout, and the turn resumes.

**Questions and plans ride the `deny` + reason channel.** A `PreToolUse` hook
cannot return a tool result, but Claude Code does feed
`permissionDecisionReason` back to the model. So answering a question is
expressed as a denial whose reason is *"The user answered: Staging"*. The answer
lands as ordinary tool feedback — no keystrokes injected into your terminal, no
dependence on the TUI's internal state.

**Quota comes from the statusline.** `rate_limits.five_hour.used_percentage`
is exposed on the statusline payload and nowhere else. Since only one
statusline can be configured, Andon Cord takes it over and *chains* to whatever
was there before, passing the identical stdin — an existing statusline keeps
rendering, and uninstall restores it exactly.

### Failing open

The shim sits on your critical path, so every failure path exits 0 with no
output, which Claude Code reads as "the hook had no opinion":

- app not running → exit 0
- socket refused, app mid-update, hook undecodable → exit 0
- you close the session while a request is parked → hook released, Claude Code
  falls back to asking in the terminal

The worst case is that Andon Cord becomes invisible. It never breaks Claude Code.

---

## Install

```bash
./build.sh release
open "build/Andon Cord.app"
```

First launch offers to set up the integration. It will:

- add hook entries to `~/.claude/settings.json`, **alongside** anything already
  there — other tools' hooks keep running
- point `statusLine` at a wrapper that chains to your existing one
- create `~/.andoncord/` for the socket, the launcher, and backups

A timestamped backup is taken before every write, and **Settings → Remove** puts
the file back the way it was. Note that JSON rewriting drops comments; the
backup keeps them, and the app warns you if your file had any.

Already-running Claude Code sessions need restarting before hooks apply.

---

## Layout

```
Sources/
  AndonKit/            # models, socket, installer, store — no AppKit
    Models/            # HookEvent, Session, ToolPresentation, StatusSnapshot
    Server/            # HookServer, SocketTransport, PendingDecision
    Integration/       # ClaudeSettingsInstaller, LauncherWriter, JSONC
    Store/             # BoardStore — the state machine
    Audio/             # ChiptuneEngine
  andon-hook/          # the shim. tiny, fails open
  AndonCordApp/        # SwiftUI + AppKit
    Notch/             # panel, geometry, pill, board, request cards
    Terminal/          # TerminalJumper
```

`AndonKit` deliberately avoids AppKit so the shim stays light — it is spawned
on every tool call. `TerminalJumper` lives in the app target for that reason.

---

## Tests

```bash
swift build --product andon-hook          # RoundTripTests need the binary
swift test
```

36 tests. The ones that matter:

- **`RoundTripTests`** — spawns the real shim as a subprocess, over a real
  socket, and asserts on what it prints to stdout. Covers approval round trip,
  release-on-session-end, fail-open, and hot-path latency.
- **`InstallerTests`** — coexistence with other tools' hooks, exact statusline
  restoration, idempotent reinstall, drift detection, comment handling.
- **`BoardStoreTests`** — every path releases its parked hook. A leak here
  would hang someone's session, so it is tested from several angles.

`RealSettingsTests` round-trips a copy of your actual `settings.json` when
`ANDON_REAL_SETTINGS` is set. It only ever reads the original.

---

## Debugging

`ANDON_DEBUG=1` writes hover and presentation transitions to
`~/.andoncord/debug.log`:

```bash
pkill -f "Andon Cord"
ANDON_DEBUG=1 "build/Andon Cord.app/Contents/MacOS/AndonCord" &
tail -f ~/.andoncord/debug.log
```

Useful because the panel's behaviour is driven by pointer geometry, which is
awkward to reason about from the outside — a flickering panel shows up here as
a burst of `presentation ->` lines.

## Known limits

- **Precise jump** works for iTerm2, Terminal.app, WezTerm, kitty (with remote
  control on), and tmux. Ghostty, Warp, Alacritty, Hyper, Zed, and editor
  terminals get app activation only — they expose no public tab-addressing API,
  and the UI says so rather than pretending.
- **Sessions hosted by the Claude desktop app** have no terminal and no tty at
  all; they are identified by the launching bundle and a click raises Claude.
  The row reads "Click to raise" rather than "Click to jump". Any host we do
  not recognise falls back to the same behaviour, and a session with no
  identifiable host is not clickable at all.
- **Quota needs an interactive session.** `claude -p` does not render a
  statusline, and `rate_limits` is exposed nowhere else, so the usage strip
  stays empty until you run `claude` interactively.
- **First jump prompts for Automation permission.** Denying it downgrades to
  app activation.
- **`quietWhileFocused`** keys off occlusion, not Focus — macOS exposes no
  public Focus API.
- **Ad-hoc signed.** A real release needs a Developer ID signature and
  notarisation.
- **No SSH remote sessions**, no multi-Mac licensing, no auto-update.
