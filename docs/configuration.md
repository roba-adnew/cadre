# Configuration

Cadre stores its configuration in `~/.config/cadre/` using two TOML files with distinct purposes:

| File | Purpose | Managed by |
|------|---------|------------|
| `config.toml` | User preferences (theme, font, grid size) | User (via `Cmd+,`) |
| `persistence.toml` | Runtime state (window position, font size, terminal cwds) | Application |

Set `CADRE_CONFIG_DIR` to relocate **both** files to a different directory
(it overrides `~/.config/cadre/`). This is how an isolated dev instance keeps
its own state without resuming or clobbering the daily app's sessions — see
`scripts/dev-instance.sh` in `docs/development.md`.

## Environment variables

| Variable | Effect |
|----------|--------|
| `CADRE_CONFIG_DIR` | Relocates `config.toml` + `persistence.toml` to the given directory (overrides `~/.config/cadre/`). |

### Persistent agent sessions

On by default (experimental): whenever `tmux` is on `PATH`, Cadre spawns each
shell inside a detached **tmux** session instead of as a direct child process. The
tmux server outlives Cadre, so quitting and relaunching Cadre — or a crash,
or the reload script — reattaches to the *same live shell* with the agent's full
in-memory context intact, instead of killing the agent and resuming it from a
local transcript that can be stale (the bridged-resume "rewind"). See ADR-015 in
`docs/ARCHITECTURE.md` for the full design.

- **State location:** a private tmux socket and config live in
  `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cadre-tmux.sock` and `…/cadre-tmux.conf`.
  Sessions are named `cadre-<epoch>-<n>`, where `<epoch>` is a random
  per-install token (`persist_epoch` in `persistence.toml`) that keeps this
  install's session names disjoint from other installs' and from older fossils on
  the shared socket. List them with `tmux -S <socket> ls`; kill a stuck one with
  `tmux -S <socket> kill-session -t cadre-<epoch>-<n>`. At startup Cadre
  reattaches to its own sessions and then reaps every remaining *detached* session
  on the socket, so leftovers from crashes or closed terminals don't accumulate.
- **Automatic fallback:** if `tmux` isn't installed, Cadre spawns a direct
  shell exactly as before — no configuration needed.
- **Known limitations (phase 1):** the attention/approval border may not light up
  on a *reattached* agent; deep scrollback above the visible screen is not
  reconstructed on reattach (the conversation state is intact); a full machine
  reboot loses the live session and falls back to a fresh shell; and only one
  persistence-enabled Cadre instance should run at a time (the socket and
  session names are shared per user).

## config.toml

User-editable preferences file. Changes take effect on next launch. Open it quickly with `Cmd+,`.

If the file doesn't exist, Cadre creates a commented template on first run (written atomically).

### Font Configuration

```toml
[font]
family = "Menlo"     # Font family name (default: JetBrainsMono if installed, else Menlo)
size = 14            # Base font size in points (default: 14)
```

The font family must be installed on your system. Common choices:
- `JetBrainsMono` (preferred default — tall x-height, sturdy strokes on dark backgrounds; `brew install --cask font-jetbrains-mono`)
- `Menlo` (macOS terminal font, fallback default — more body, smoother at low DPI)
- `SFNSMono` (SF Mono — Apple system mono, thinner)
- `MesloLGS NF` (Nerd Font with icons)
- `Fira Code`

### Grid Configuration

```toml
[grid]
font_scale = 1.0  # Font scale in grid view (0.5-3.0, default: 1.0)
```

The grid size is dynamic and adjusts automatically based on the number of terminals:
- Press `Cmd+N` to add a new terminal after the currently focused one — the grid expands to accommodate it
- Press `Cmd+W` to close a terminal — remaining terminals compact forward to fill gaps and the grid shrinks when possible; if it's the only terminal, it restarts in place (use `Cmd+Q` or the window close button to quit)
- When only one terminal is spawned, the view stays in full-screen mode
- Grid layout maintains `columns >= rows` (e.g., 1x1 → 2x1 → 3x1 → 2x2 → 3x2 → 3x3 → ...); 3 terminals lay out as a single horizontal row
- Maximum grid size is 12×12 (144 terminals)

### Window Configuration

```toml
[window]
width = 1280    # Initial window width in pixels (default: 1280)
height = 720    # Initial window height in pixels (default: 720)
x = -1          # Initial X position (-1 = centered, default: -1)
y = -1          # Initial Y position (-1 = centered, default: -1)
```

Note: Runtime window position and size are saved to `persistence.toml` and take precedence over these values after the first launch.

### Theme Configuration

```toml
[theme]
mode = "light"          # "light" = Cacha light preset; omit/"dark" = default dark
background = "#262624"  # Terminal background color
foreground = "#B5BDC8"  # Default text color
selection = "#1B2230"   # Selection highlight color
accent = "#61AFEF"      # Accent color (focused borders, UI elements)
```

Colors are specified in hexadecimal format (`#RRGGBB` or `RRGGBB`).
The configured theme colors are reused across terminal chrome and overlay surfaces, including modal panels and their input fields.

#### Light mode

Set `mode = "light"` to switch the defaults to a light preset matched to the
Cacha companion app's light theme (background `#D6D6D5`, soft near-black text,
Cacha's blue accent, and a light ANSI palette tuned for readable contrast on the
gray background). `mode` only changes which
set of *defaults* is used — any explicit `background`/`foreground`/`accent`/
`selection` or `[theme.palette]` key still overrides the preset. Changing the
mode takes effect on the next launch.

#### Default Theme Colors

| Setting | Dark default (`mode` unset) | Light default (`mode = "light"`) | Description |
|---------|---------|---------|-------------|
| `background` | `#262624` | `#D6D6D5` | App + terminal background |
| `foreground` | `#B5BDC8` | `#1A1A1A` | Default text color |
| `selection` | `#1B2230` | `#BAC2CA` | Selection highlight |
| `accent` | `#61AFEF` | `#2563EB` | Focus indicators / UI accent |

### ANSI Palette

Customize the 16-color ANSI palette under `[theme.palette]`:

```toml
[theme.palette]
# Standard colors (0-7)
black = "#0E1116"
red = "#E06C75"
green = "#98C379"
yellow = "#D19A66"
blue = "#61AFEF"
magenta = "#C678DD"
cyan = "#56B6C2"
white = "#ABB2BF"

# Bright colors (8-15)
bright_black = "#5C6370"
bright_red = "#E06C75"
bright_green = "#98C379"
bright_yellow = "#E5C07B"
bright_blue = "#61AFEF"
bright_magenta = "#C678DD"
bright_cyan = "#56B6C2"
bright_white = "#CDD6E0"
```

Omitted colors fall back to the built-in One Dark-inspired palette (or, when `mode = "light"`, a light palette tuned for readable contrast on the gray background).

### UI Configuration

```toml
[ui]
show_hotkey_feedback = true  # Show hotkey hints overlay (default: true)
enable_animations = true     # Enable expand/collapse animations (default: true)
```

### Notification Configuration

```toml
[notifications]
sound = true  # Play a macOS system chime when an agent needs approval or
              # finishes, while Cadre is in the background (default: true)
```

The chime only plays when Cadre is **not** the frontmost app — when it's
focused, the pulsing pane border is the signal instead. Distinct sounds are used
for "needs approval" (Ping) and "done" (Glass). macOS only; set `sound = false`
to silence.

### Rendering Configuration

```toml
[rendering]
vsync = true  # Enable vertical sync (default: true)
```

Disabling vsync may reduce input latency but can cause screen tearing.

### Metrics Configuration

```toml
[metrics]
enabled = false  # Enable metrics collection overlay (default: false)
```

When enabled, press `Cmd+Shift+M` to toggle the metrics overlay in the bottom-right corner. The overlay displays:
- **Frames**: Total rendered frame count
- **FPS**: Frames per second
- **Glyph cache**: Number of cached glyph textures
- **Glyph hit rate**: Cache hit percentage (hits / total accesses)
- **Glyph hits/s**: Glyph cache hits per second
- **Glyph misses/s**: Glyph cache misses per second
- **Glyph evictions/s**: Glyph cache evictions per second

Metrics collection has zero overhead when disabled (no allocations, null pointer checks compile away).

### Logging Configuration

```toml
[logging]
min_level = "info"  # One of: err, warn, info, debug (case-insensitive)
```

Cadre writes structured application logs to:
- macOS: `~/Library/Logs/Cadre/cadre.log`

Each log line uses local time with an explicit timezone offset (for example, `2026-03-08T14:23:00+01:00`).

Logs rotate by size. When `cadre.log` exceeds 10 MiB, it is archived to a timestamped file (for example, `cadre-20260306T143000Z.log`) and a new active log file is created.

| Setting | Default | Description |
|---------|---------|-------------|
| `min_level` | `"info"` | Minimum severity written to the log file. Accepts `err`, `warn`, `info`, or `debug` (case-insensitive). Unknown values fall back to `info`. |

Event markers (startup/shutdown and grid/full view transitions) are always recorded at `INFO` level.

### Worktree Configuration

```toml
[worktree]
directory = "~/.cadre-worktrees"  # Base directory for new worktrees
init_command = "script/setup"         # Command to run after creating a worktree
```

| Setting | Default | Description |
|---------|---------|-------------|
| `directory` | `~/.cadre-worktrees` | Base directory where new worktrees are created. Each repo gets a subdirectory mirroring its path relative to `$HOME`, and each worktree is a subdirectory within that. Supports `~` expansion. Relative paths are resolved against `$HOME`. |
| `init_command` | *(auto-detect)* | Shell command to run in the new worktree after creation. When not set, Cadre automatically runs `script/setup` or `.cadre-init.sh` if either exists and is executable. |

New worktrees are created at `<directory>/<repo-subpath>/<worktree-name>`, where `<repo-subpath>` is the repo's path relative to `$HOME`. For example, if the repo is at `~/dev/myproject`, creating a worktree called `feature-x` produces `~/.cadre-worktrees/dev/myproject/feature-x`.

Creating worktrees outside the repository tree prevents agents (Claude Code, Codex, etc.) from discovering the parent repository's configuration files when traversing up the directory tree.

Existing worktrees (including legacy ones under `.cadre/` inside the repo) remain visible in the worktree picker and can be switched to or removed normally.

### Complete Example

```toml
# ~/.config/cadre/config.toml

[font]
family = "JetBrains Mono"
size = 13

[grid]
font_scale = 0.9

[theme]
background = "#1E1E2E"
foreground = "#CDD6F4"
selection = "#45475A"
accent = "#89B4FA"

[theme.palette]
black = "#45475A"
red = "#F38BA8"
green = "#A6E3A1"
yellow = "#F9E2AF"
blue = "#89B4FA"
magenta = "#F5C2E7"
cyan = "#94E2D5"
white = "#BAC2DE"
bright_black = "#585B70"
bright_red = "#F38BA8"
bright_green = "#A6E3A1"
bright_yellow = "#F9E2AF"
bright_blue = "#89B4FA"
bright_magenta = "#F5C2E7"
bright_cyan = "#94E2D5"
bright_white = "#A6ADC8"

[ui]
show_hotkey_feedback = true
enable_animations = true

[rendering]
vsync = true

[metrics]
enabled = false

[logging]
min_level = "info"

[worktree]
# directory = "~/.cadre-worktrees"
# init_command = "script/setup"
```

## persistence.toml

Auto-managed runtime state. Do not edit manually unless troubleshooting.

### Structure

```toml
font_size = 14
persist_epoch = "a3f1c09b7e5d2648"

terminals = [
  "/Users/me/projects/app",
  "/Users/me/projects/lib",
  "/Users/me",
]

terminal_agent_types = ["claude", "", ""]
terminal_session_ids = ["550e8400-e29b-41d4-a716-446655440000", "", ""]
terminal_persist_indices = [0, 141, 2]
terminal_hidden = [false, false, true]

[window]
width = 1440
height = 900
x = 100
y = 50

[recent_folders]
"/Users/me/projects/app" = 15
"/Users/me/projects/lib" = 8
"/Users/me" = 3

[grid_font_presets]
"3x2" = 1.200
"2x2" = 0.800
```

### Fields

| Field | Description |
|-------|-------------|
| `font_size` | Current font size (adjusted with `Cmd++`/`Cmd+-`) |
| `persist_epoch` | Random per-install token (16 hex chars) minted on first launch and mixed into tmux session names (`cadre-<epoch>-<n>`) so this install never reattaches to another install's — or an old fossil's — session on the shared socket. Do not edit; deleting it just mints a fresh one (and abandons the current run's live tmux sessions). |
| `terminals` | Working directories for each terminal. Array position is the grid display order — creation order until you drag-reorder tiles, after which the user's arrangement is what round-trips across restarts. |
| `terminal_agent_types` | Agent type for each terminal slot (`"claude"`, `"codex"`, `"gemini"`), or an empty string (`""`) when absent. Present only when at least one terminal had a running agent at quit time. |
| `terminal_session_ids` | Session UUID for each terminal slot, or an empty string (`""`) when absent. Written alongside `terminal_agent_types` when an agent session ID was captured at quit. On next launch, Cadre writes the corresponding resume command (e.g., `claude --resume <uuid>`) to the terminal as soon as the shell is ready. |
| `terminal_persist_indices` | Each terminal's tmux identity (`cadre-<epoch>-<index>`), so a restored terminal reattaches to its own live session instead of one derived from its grid position. `-1` = unknown. Absent in older files: terminals then reattach by position, and same-epoch graveyard sessions are spared for that one launch. |
| `terminal_hidden` | Per-terminal boolean: `true` for terminals hidden from the grid (⌘J) at quit time, restored as spawned-but-hidden (revealed via ⌘⇧J). Present only when at least one terminal is hidden; absent means all visible. |
| `[window]` | Last window position and dimensions |
| `[recent_folders]` | Directory visit counts (up to 10 entries, sorted by frequency for `Cmd+O` overlay) |
| `grid_font_scale` | Last grid-view font zoom multiplier (`Cmd+Opt +/-`); global fallback when a grid shape has no saved preset |
| `[grid_font_presets]` | Per-grid-shape font zoom, keyed by `"<cols>x<rows>"` — each grid shape remembers its own `Cmd+Opt` zoom across relaunches (grid text is rendered crisply at that scale's native size) |

On launch, Cadre restores terminals to their saved working directories. The grid automatically resizes to fit the number of restored terminals. If a terminal had an AI agent running when Cadre was last closed, the agent is automatically resumed.

`persistence.toml` is written atomically (temp file + replace), so updates never leave a partially written file. Cadre updates it during runtime when state changes (window move/resize, font size, terminal cwd changes, terminal spawn/despawn) and performs a final save during shutdown.

Note: Terminal cwd persistence and agent session resumption are currently macOS-only.

Older `persistence.toml` files that used the `[terminals]` table or `recent_folders` array are migrated automatically. Files without `terminal_agent_types` / `terminal_session_ids` / `terminal_hidden` are loaded normally (no agent resumption, all terminals visible). Files without `persist_epoch` get one minted and saved on first launch. Files without `terminal_persist_indices` restore by position for one launch (indices are saved from then on); during that launch same-epoch detached tmux sessions are not reaped, since they can't be told apart from live terminals' sessions.

## Resetting Configuration

Delete the configuration files to reset to defaults:

```bash
rm ~/.config/cadre/config.toml      # Reset preferences
rm ~/.config/cadre/persistence.toml # Reset runtime state
```

Or remove the entire directory:

```bash
rm -rf ~/.config/cadre
```
