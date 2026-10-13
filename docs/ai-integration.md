# AI Assistant Integration

Cadre exposes a Unix domain socket to let external tools (Claude Code, Codex, Gemini CLI, etc.) signal UI states.

Cadre also ships `cadre-mcp`, a separate stdio MCP helper that lets local MCP clients ask the running app to create new terminal sessions and close existing ones.

## Socket Protocol

- Socket: `${XDG_RUNTIME_DIR:-/tmp}/cadre_notify_<configkey>.sock` — `<configkey>` is a hash of the config dir, so the path is stable across app restarts (tmux-reattached shells keep a valid `CADRE_NOTIFY_SOCK`) and disjoint per `CADRE_CONFIG_DIR` instance
- Per-shell env vars: `CADRE_SESSION_ID` (the terminal's stable persist index — unchanged across app restarts) and `CADRE_NOTIFY_SOCK` (socket path)
- Payload: send a single-line JSON object

Examples:
```json
{"session": 0, "state": "start"}
{"session": 0, "state": "awaiting_approval"}
{"session": 0, "state": "done"}
```

## MCP tools

`cadre-mcp` is launched by an MCP client as a stdio server. It exposes two tools, `spawn_session` and `close_session`, and forwards each call to the running Cadre app through a local Unix-domain control socket. The helper is not a daemon and does not launch the GUI app if Cadre is not already running.

## MCP `spawn_session`


The running app writes a per-instance discovery file named `cadre_control_<uid>_<pid>.json` under `XDG_RUNTIME_DIR` when that is set. Otherwise it uses a stable per-user runtime directory: `~/Library/Caches/Cadre/runtime` on macOS, or `~/.cache/cadre/runtime` on other platforms. The app logs the full discovery file path together with the socket path. When several Cadre instances are running, `cadre-mcp` tries the newest reachable discovery entry.

Helper paths:

- Source builds: `zig-out/bin/cadre-mcp`
- Release app bundle: `Cadre.app/Contents/MacOS/cadre-mcp`
- Homebrew: `cadre-mcp` on `PATH`, with the app-bundle path under `$(brew --prefix)/Cellar/cadre/<version>/Cadre.app/Contents/MacOS/cadre-mcp` as a fallback

Input schema:

```json
{
  "type": "object",
  "required": ["cwd"],
  "additionalProperties": false,
  "properties": {
    "cwd": {
      "type": "string",
      "description": "Absolute working directory for the new terminal session."
    },
    "command": {
      "type": "string",
      "description": "Optional command text queued into the new shell. Cadre appends a newline when needed."
    },
    "display_name": {
      "type": "string",
      "description": "Optional display label reserved for clients and future Cadre UI."
    }
  }
}
```

Example tool arguments:

```json
{
  "cwd": "/Users/me/dev/project",
  "command": "codex",
  "display_name": "Project task"
}
```

Successful calls return MCP structured content like:

```json
{
  "status": "spawned",
  "session_id": 12,
  "slot_index": 3
}
```

Tool errors use stable codes:

- `invalid_request`: the MCP arguments do not match the schema
- `app_not_running`: no running Cadre app accepted the local control request
- `full_grid`: every Cadre terminal slot is already in use
- `invalid_cwd`: `cwd` is not an absolute existing directory
- `spawn_failed`: Cadre accepted the request but could not create or initialize the terminal session

## MCP `close_session`

The inverse of `spawn_session`: it asks the running app to close a terminal session and reclaim its grid slot, driving the same close/relayout path as the close-pane keybinding (the shell is terminated and the pane is removed — not left as a dead, unresponsive pane). Provide exactly one identifier.

Input schema:

```json
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "session_id": {
      "type": "integer",
      "description": "The session id returned by spawn_session. Provide this or slot_index."
    },
    "slot_index": {
      "type": "integer",
      "description": "The grid slot index to close. Provide this or session_id."
    }
  }
}
```

Example tool arguments:

```json
{ "session_id": 12 }
```

Successful calls return MCP structured content like:

```json
{
  "status": "closed",
  "session_id": 12
}
```

Tool errors use the same stable codes, plus:

- `invalid_request`: the MCP arguments do not match the schema (e.g. no identifier was provided)
- `not_found`: no session matches the requested `session_id` / `slot_index`
- `app_not_running`: no running Cadre app accepted the local control request

## Built-in Command (inside Cadre terminals)

Cadre injects a small `cadre` command into each shell's `PATH`. It reads the
session id and socket path from the environment, so hooks can simply call:

```bash
cadre notify start
cadre notify awaiting_approval
cadre notify done
```

On macOS zsh login shells, `/etc/zprofile` resets `PATH` via `path_helper`. Cadre
adds wrapper files at `~/.cache/cadre/zsh/.zshenv`, `.zprofile`, `.zshrc`, and `.zlogin`
that source your original dotfiles, prepend the Cadre command directory, and install
a small guard so `PATH` keeps the Cadre entry after directory changes.

If your hook runs outside an Cadre terminal, use the Python helper scripts below.
Replace `cadre notify ...` in the examples with `python3 ~/.<tool>/cadre_notify.py ...` when using those scripts.

## Hook Installer

From inside an Cadre terminal, you can install hooks automatically:

```bash
cadre hook claude
cadre hook codex
cadre hook gemini
```

If you upgrade Cadre, restart existing terminals so the bundled `cadre` script refreshes.
The installer writes timestamped backups before updating configs (for example:
`settings.json.cadre.bak.20260127T153045Z`).

## Claude Code Hooks

1. (Optional) Copy the helper script if the hook runs outside Cadre:
   ```bash
   cp scripts/cadre_notify.py ~/.claude/cadre_notify.py
   chmod +x ~/.claude/cadre_notify.py
   ```

2. Add hooks to `~/.claude/settings.json`:
   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "cadre notify done || true"
             }
           ]
         }
       ],
       "Notification": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "cadre notify || true"
             }
           ]
         }
       ]
     }
   }
   ```

   The Notification hook deliberately has no state argument: Claude Code pipes the
   hook JSON to stdin, and `cadre notify` maps `notification_type` itself —
   only `permission_prompt`, `agent_needs_input`, and `elicitation_dialog` become
   "needs you"; `idle_prompt`, `auth_success`, and the rest are ignored. (The old
   hardcoded `cadre notify awaiting_approval` flagged every notification —
   including a session merely idling at the prompt — as "needs you";
   `cadre hook claude` migrates that form automatically.)

## Codex Hooks

1. (Optional) Copy the helper script if the hook runs outside Cadre:
   ```bash
   cp scripts/cadre_notify.py ~/.codex/cadre_notify.py
   chmod +x ~/.codex/cadre_notify.py
   ```

2. Add the `notify` setting to `~/.codex/config.toml`:
   ```toml
   notify = ["cadre", "notify"]
   ```

If you already have `notify` configured, `cadre hook codex` overwrites it,
prints a warning, and prints the backup file name.

## Gemini CLI Hooks

Gemini hooks must emit JSON to stdout, so keep using the wrapper script even inside
Cadre terminals (it can call `cadre notify` under the hood).

1. Copy the notification scripts (the `cadre hook gemini` installer assumes they exist):
   ```bash
   cp scripts/cadre_notify.py ~/.gemini/cadre_notify.py
   cp scripts/cadre_hook_gemini.py ~/.gemini/cadre_hook.py
   chmod +x ~/.gemini/cadre_notify.py ~/.gemini/cadre_hook.py
   ```

2. Add hooks to `~/.gemini/settings.json`:
   ```json
   {
     "hooks": {
       "AfterAgent": [
         {
           "matcher": "*",
           "hooks": [
             {
               "name": "cadre-completion",
               "type": "command",
               "command": "python3 ~/.gemini/cadre_hook.py done",
               "description": "Notify Cadre when task completes"
             }
           ]
         }
       ],
       "Notification": [
         {
           "matcher": "*",
           "hooks": [
             {
               "name": "cadre-approval",
               "type": "command",
               "command": "python3 ~/.gemini/cadre_hook.py awaiting_approval",
               "description": "Notify Cadre when waiting for approval"
             }
           ]
         }
       ]
     },
     "tools": {
       "enableHooks": true
     }
   }
   ```
