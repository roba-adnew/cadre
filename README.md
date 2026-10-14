# Cadre

[![Build status](https://github.com/forketyfork/architect/actions/workflows/build.yml/badge.svg)](https://github.com/forketyfork/architect/actions/workflows/build.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/language-Zig-orange.svg)](https://ziglang.org/)

https://github.com/user-attachments/assets/a4e28a63-557a-44f3-9bae-47b2fd0a5dc6

A terminal built for multi-agent AI coding workflows. Run Claude Code, Codex, or Gemini in parallel and see at a glance which agents need your attention. See more in [my article](https://forketyfork.github.io/blog/2026/01/21/running-4-ai-coding-agents-at-once-the-terminal-i-built-to-keep-up/).

Built on [ghostty-vt](https://github.com/ghostty-org/ghostty) for terminal emulation and SDL3 for rendering.

## Why Cadre?

Running multiple AI coding agents is the new normal. But existing terminals weren't built for this:

- **Agents sit idle** waiting for approval while you're focused elsewhere
- **Context switching** between tmux panes or tabs kills your flow
- **No visibility** into which agent needs attention right now

Cadre solves this with a grid view that keeps all your agents visible, with **status-aware highlighting** that shows you instantly when an agent is awaiting approval or has completed its task.

> [!WARNING]
> **This project is in the early stages of development. Use at your own risk.**
>
> The application is experimental and may have bugs, stability issues, or unexpected behavior.

## Features

### Agent-Focused
- **Status highlights** — agents glow when awaiting approval or done, so you never miss a prompt
- **Agent session persistence** — when you quit Cadre, any running Claude, Codex, or Gemini agents are gracefully terminated and their session IDs saved; on next launch the agents resume automatically where they left off
- **Live session persistence (experimental)** — when `tmux` is installed, each shell runs inside a detached tmux session by default, so agents *survive* an Cadre restart and reattach with full in-memory context instead of being resumed from a transcript. See [Configuration](docs/configuration.md#persistent-agent-sessions) and ADR-015 for details and current limitations.
- **Dynamic grid** — starts with a single terminal in full view; press ⌘N to add a terminal after the current one, and closing terminals compacts the grid forward
- **Grid view** — keep all agents visible simultaneously; single-click a pane to move focus to it (no shell is spawned), double-click to expand it to full screen; double-click a focused pane to return to the grid (works even over mouse-tracking programs like Claude/vim)
- **Drag to reorder** — press and hold a grid tile (~¼s without moving), then drag: as the cursor reaches the center of another tile, tiles slide springboard-style to make room (only the tiles between the old and new slot shift). Release to drop, Esc to snap the tile back to where it started. The arrangement survives closing terminals and app restarts; a revealed hidden terminal joins at the end of the grid rather than disturbing your arrangement. Moving the pointer right away instead selects text as usual, and Cmd+Click still opens links Keep dragging past the window edge: release on empty screen to open that terminal in a new window at the drop point, or release over another Cadre window to move it there, landing on the slot under the pointer (the target outlines the slot while you hover). A window emptied by a drag closes itself. A window's only terminal (shown full-size) can be dragged out the same way: hold still briefly, then drag.
- **Find in terminal** (⌘F) — search the focused pane's scrollback and visible screen (case-insensitive substring); the current match is highlighted and the view scrolls to it. Enter/Shift+Enter (or ↑/↓) jump between matches, the counter shows position (e.g. `3/12`), and Esc clears the search and returns to the live prompt
- **Worktree picker** (⌘T) — quickly `cd` into git worktrees for parallel agent work on separate branches; new worktrees are created outside the repo tree (configurable via `[worktree]` in `config.toml`) with automatic post-create initialization
- **Recent folders** (⌘O) — quickly `cd` into recently visited directories with instant search filtering (start typing to narrow the list), substring highlighting, arrow key navigation, and ⌘1–⌘9 quick selection
- **Hide terminals** (⌘J / ⌘⇧J) — pull a terminal out of the grid with ⌘J to declutter (it keeps running in the background); press ⌘⇧J to open a searchable switcher listing every hidden terminal as `agent.folder` (just the folder when no agent is running) with live agent status (needs you / working / done / idle — driven by Claude's hooks: "needs you" only appears for real permission/input requests (not a session idling at the prompt), "working" only shows while Claude is actually processing, and "needs you" / "done" are sticky cues that clear back to idle once you view the terminal; "hosting" when the terminal is serving a local TCP port, and a plain dash when Claude never ran there), then filter by typing the folder or agent name, navigate with arrows or the mouse, and Enter/click to bring one back into the grid. A count pill in the top-right corner shows how many are hidden, and hidden terminals stay hidden across restarts
- **Diff review comments** — click diff lines in the ⌘D overlay to leave inline comments with multiline wrapping, then send them all to a running agent (or start one) with the "Send to agent" button
- **Story viewer** — run `cadre story <filename>` to open a scrollable overlay that renders PR story files with prose text and diff-colored code blocks
- **MCP session control** — run `cadre-mcp` from an MCP client to ask the running Cadre app to create a terminal session in a requested working directory (`spawn_session`) or close one and reclaim its slot (`close_session`)
- **Reader mode** (⌘R) — open a centered markdown reader for the selected terminal's history (works in full view and grid) with live updates, bottom pinning, incremental search (⌘F, Enter/Shift+Enter), markdown tables with inline cell styling (bold/italic/code/links/strikethrough), task checkboxes (emoji), clickable links, shared draggable scrollbar, and left-to-right gradient separators before command prompts (OSC 133 + fallback heuristics)

### Terminal Essentials
- Smooth animated transitions for grid expansion, contraction, and reflow (cells and borders move/resize together)
- Wakeable idle input handling keeps typing responsive after short idle periods instead of waiting on a fixed sleep window
- Keyboard navigation: ⌘+Return to expand, ⌘1–⌘0 to switch grid slots, ⇧Arrow to move focus in grid view (plays a brief wave animation on the destination terminal; ⌘←/→ instead jump to line start/end in the focused terminal), ⌘N to add, ⌘W to close a terminal (closes the window when it's the last terminal there and other windows are open, Chrome-style; restarts it when it's the only terminal in the only window), ⌘⇧N to open a new window (its first terminal starts in the focused terminal's directory; each window has its own grid), ⌘⇧P to move the focused terminal out into its own new window (the agent, shell and tmux session carry over untouched; a window's last visible terminal stays put), ⌘⇧W or the close button to close a window (confirms if something is still running there, discards its terminals; the last window quits instead), ⌘J to hide a terminal from the grid (⌘⇧J opens the searchable hidden-terminals picker), ⌘T for worktrees, ⌘O for recent folders, ⌘D for repo-wide git diff (staged + unstaged + untracked), ⌘R for reader mode, ⌘F to find in the focused terminal, ⌘⇧↓ to jump the focused terminal to the bottom of its scroll (sends Ctrl+End — useful in Claude Code, where it's normally Ctrl+End but macOS window managers grab the physical Ctrl+Fn+→), ⌘/ for shortcuts (the top-right help/worktree/recent-folders/hidden-count pills stay tucked away behind a tiny app-icon tray in the corner and slide out on hover or whenever one of them opens, so they don't cover the terminal); in kitty-protocol apps (e.g. Claude Code) modified Tab/Enter/Backspace are sent as real key events, so ⌥Enter inserts a newline and ⌥Delete deletes a word per the app's own bindings; quit with ⌘Q or the window close button (if terminals are still running, a 4-second **Undo Close** window lets you cancel before it quits)
- Git diff overlay title shows the repo root folder being diffed
- Per-cell cwd bar in grid view shows the working directory's folder name (plus the agent's name and hotkey) at the terminal's own font size; it reserves space, and terminal dimensions track grid/full mode so content wraps inside the visible area
- Scrollback with trackpad/wheel support and an auto-hiding draggable scrollbar in terminal views
- OSC 8 hyperlink support (Cmd+hover to underline, Cmd+Click to open); works in both full view and grid view, including detected URLs and existing file paths. Relative OSC 8 targets (e.g. `docs/FOO.md`, as emitted by Claude Code for local files) are resolved against the pane's working directory. Shells get `FORCE_HYPERLINK=1` so CLIs that feature-detect hyperlink support (Claude Code and friends) emit real OSC 8 links instead of plain colored text (export `FORCE_HYPERLINK=0` to opt out)
- Text selection & clipboard: drag to select (double-click a word, triple-click a line), ⌘C to copy, ⌘V to paste, and right-click for a context menu (Paste plus every window and terminal shortcut; in grid view it acts on the pane you clicked). Inside programs that capture the mouse (Claude, vim, pagers), hold ⇧ while dragging to select locally instead of forwarding the mouse to the program
- Replies to OSC 4/10/11 color queries using the live terminal palette/default colors so Codex and similar CLIs do not stall on startup probes
- Kitty keyboard protocol for enhanced key handling
- Persistent window state and font size across sessions; every open window and which terminals it held is restored on relaunch
- The native macOS title bar is tinted to the theme background, with the app name at its far right (title text and traffic lights follow the theme's light/dark luminance)
- UI chrome (menus, overlays, pills, dialogs, scrollbar) is derived from the theme background in both modes: lighter surfaces on dark themes, darker on light ones, so custom themes stay cohesive

## Installation

### Download Pre-built Binary (macOS)

Download the latest release from the [releases page](https://github.com/forketyfork/architect/releases).

**For Apple Silicon (M1/M2/M3/M4):**
```bash
curl -LO https://github.com/forketyfork/architect/releases/latest/download/cadre-macos-arm64.tar.gz
tar -xzf cadre-macos-arm64.tar.gz
xattr -dr com.apple.quarantine Cadre.app
open Cadre.app
```

**For Intel Macs:**
```bash
curl -LO https://github.com/forketyfork/architect/releases/latest/download/cadre-macos-x86_64.tar.gz
tar -xzf cadre-macos-x86_64.tar.gz
xattr -dr com.apple.quarantine Cadre.app
open Cadre.app
```

**Note**:

* These GitHub release archives are ad-hoc signed so macOS can launch them locally, but they are not Developer ID signed or notarized.
* Clear the quarantine attribute before first launch, or macOS may block the app.
* The archive contains `Cadre.app`. You can launch it with `open Cadre.app` or run `./Cadre.app/Contents/MacOS/cadre` from the terminal. The MCP helper is bundled at `./Cadre.app/Contents/MacOS/cadre-mcp`. Keep the bundle contents intact.
* Not sure which architecture? Run `uname -m` - if it shows `arm64`, use the ARM64 version; if it shows `x86_64`, use the Intel version.

### Homebrew (macOS)

**Prerequisites**: Xcode Command Line Tools must be installed:
```bash
xcode-select --install
```

Install via Homebrew (builds from source):
```bash
# Tap the repository (note: requires full repo URL since the formula is in the main repo)
brew tap forketyfork/architect https://github.com/forketyfork/architect

# Install cadre
brew install cadre

# Copy the app to your Applications folder
cp -r $(brew --prefix)/Cellar/cadre/*/Cadre.app /Applications/

# MCP clients can use the helper on PATH
cadre-mcp
```

Or install directly without tapping:
```bash
brew install https://raw.githubusercontent.com/forketyfork/architect/main/Formula/cadre.rb
cp -r $(brew --prefix)/Cellar/cadre/*/Cadre.app /Applications/
```

### Build from Source

See [`docs/development.md`](docs/development.md) for the full development setup. Quick start:
```bash
nix develop
just build
```

Source builds install both executables under `zig-out/bin/`: `cadre` and `cadre-mcp`.

## Hooks

Cadre **auto-installs Claude Code's hooks on startup** (idempotent) — including the `SessionStart` hook that captures each agent's resume id live, so a conversation can be restored after a full machine reboot rather than coming back as a bare shell. You don't need to run anything for Claude.

To (re-)install hooks manually, or to add Codex/Gemini hooks, use the `cadre` command available in the terminal:
```bash
cadre hook claude
cadre hook codex
cadre hook gemini
```

## MCP

`cadre-mcp` is a stdio MCP server for local clients. It exposes two tools, `spawn_session` and `close_session`, which forward the request to the running Cadre app. It does not launch Cadre by itself.

`spawn_session` arguments:
```json
{
  "cwd": "/absolute/path/to/worktree",
  "command": "codex",
  "display_name": "Issue 291"
}
```

`cwd` is required. `command` and `display_name` are optional. On success, the tool returns structured content with `status`, `session_id`, and `slot_index`. If Cadre is not running, the grid is full, `cwd` is invalid, or spawning fails, the tool returns an MCP tool error with a stable `code` and `message`.

`close_session` is the inverse: it closes a terminal session and reclaims its grid slot (the same path as the close-pane keybinding, so the pane is removed rather than left dead). Pass exactly one identifier — the `session_id` returned by `spawn_session`, or a `slot_index`:
```json
{ "session_id": 12 }
```
On success it returns structured content with `status: "closed"` and the `session_id`. An unknown identifier returns an MCP tool error with code `not_found`.

For release downloads, use:
```bash
./Cadre.app/Contents/MacOS/cadre-mcp
```

For Homebrew installs, `cadre-mcp` is also symlinked onto `PATH`; the app-bundle fallback is:
```bash
$(brew --prefix)/Cellar/cadre/$(brew list --versions cadre | awk '{print $2}')/Cadre.app/Contents/MacOS/cadre-mcp
```

## Configuration

Cadre stores configuration in `~/.config/cadre/`:

* `config.toml`: read-only user preferences (edit via `⌘,`).
* `persistence.toml`: runtime state (window position/size, font size, terminal cwds), managed automatically.

Common settings include font family, theme colors, grid font scale, and logging minimum severity (`[logging].min_level`). Set `[theme].mode = "light"` for a light theme matched to the Cacha companion app (background `#D6D6D5` + a readability-tuned light palette); see [`docs/configuration.md`](docs/configuration.md#light-mode). On macOS, structured app logs are written to `~/Library/Logs/Cadre/` with size-based rotation at 10 MiB, including startup/shutdown markers and grid/full view transition events at `INFO`. The grid size is dynamic and adapts to the number of terminals. Remove the files to reset to the default values.

## Troubleshooting

* **Upgrading from an install named Architect**: the app, binary, config dir (`~/.config/cadre`), log dir, tmux session prefix, sockets and `CADRE_*` env vars were all renamed from `architect`. Quit the app and run `scripts/migrate-to-cadre.sh` once: it moves config/logs and renames live tmux sessions so your terminals reattach. Hook commands in `~/.claude/settings.json` are rewritten on the next launch, and panes started before the rename keep notifying via `ARCHITECT_*` fallbacks until they restart.
* **App won't open (Gatekeeper)**: run `xattr -dr com.apple.quarantine Cadre.app` after extracting the release.
* **Font not found**: ensure the font is installed and set `font.family` in `config.toml`. The app falls back to `SFNSMono` on macOS.
* **Missing symbol glyphs**: fallbacks try the bundled Symbols Nerd Font, then `Arial Unicode MS`, then `STIXTwoMath` (if available) before emoji.
* **Emoji alignment**: single-codepoint emoji are centered using glyph metrics; if they appear off, try a different primary font or font size.
* **Reset configuration**: delete `~/.config/cadre/config.toml` and `~/.config/cadre/persistence.toml`.
* **Crash after closing a terminal**: update to the latest build; older builds could crash after terminal close events on macOS.
* **Known limitations**: emoji fallback is macOS-only; keybindings are currently fixed.

## Documentation

* [`docs/ai-integration.md`](docs/ai-integration.md): set up Claude Code, Codex, and Gemini CLI hooks for status notifications, plus the `cadre-mcp` `spawn_session` interface.
* [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): architecture overview and system boundaries.
* [`docs/configuration.md`](docs/configuration.md): detailed configuration reference for `config.toml` and `persistence.toml`.
* [`docs/development.md`](docs/development.md): build, test, and release process.
* [`CLAUDE.md`](CLAUDE.md): agent guidelines for code assistants.

## Related Tools

Cadre is part of a suite of tools I'm building for AI-assisted development:

- [**Stepcat**](https://github.com/forketyfork/stepcat) — Multi-step agent orchestration with Claude Code and Codex
- [**Marx**](https://github.com/forketyfork/marx) — Run Claude, Codex, and Gemini in parallel for PR code review
- [**Claude Nein**](https://github.com/forketyfork/claude-nein) — macOS menu bar app to monitor Claude Code spending

## License

MIT
