// Shell process wrapper: spawns a login shell connected to a PTY and provides
// minimal read/write/wait helpers for the main event loop.
const std = @import("std");
const assets = @import("assets");
const posix = std.posix;
const pty_mod = @import("pty.zig");
const tmux = @import("tmux.zig");
const libc = @cImport({
    @cInclude("stdlib.h");
});

const log = std.log.scoped(.shell);

// POSIX wait status macros (not available in std.c)
fn wifexited(status: c_int) bool {
    return (status & 0x7f) == 0;
}

fn wexitstatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

var warned_env_defaults: bool = false;
var terminfo_setup_done: bool = false;
var terminfo_available: bool = false;
var terminfo_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var terminfo_dir_z: ?[:0]const u8 = null;
var tic_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var cadre_command_base_buf: [std.fs.max_path_bytes]u8 = undefined;
var cadre_command_base_z: ?[:0]const u8 = null;
var cadre_command_setup_done: bool = false;
var cadre_command_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var cadre_command_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var cadre_command_dir_z: ?[:0]const u8 = null;
var cadre_command_path_z: ?[:0]const u8 = null;
var cadre_zsh_profile_setup_done: bool = false;
var cadre_zsh_profile_ready: bool = false;

const fallback_term = "xterm-256color";
const cadre_term = "xterm-ghostty";
const default_colorterm = "truecolor";
const default_lang = "en_US.UTF-8";
const default_term_program = "Cadre";
const default_force_hyperlink = "1";

// Cadre terminfo: xterm-256color base + 24-bit truecolor + kitty keyboard protocol
const cadre_terminfo_src = assets.xterm_ghostty;
const cadre_command_script =
    \\#!/usr/bin/env python3
    \\"""
    \\Cadre shell helper for sending UI notifications and installing hooks.
    \\
    \\Usage:
    \\    cadre notify <state|json>
    \\    cadre notify   (reads stdin)
    \\    cadre hook claude|codex|gemini
    \\"""
    \\import datetime
    \\import json
    \\import os
    \\import shutil
    \\import socket
    \\import sys
    \\
    \\try:
    \\    import tomllib
    \\except ImportError:
    \\    tomllib = None
    \\
    \\VALID_STATES = {"start", "awaiting_approval", "done"}
    \\
    \\CLAUDE_DONE = "cadre notify done || true"
    \\# Stdin mode: Claude pipes the Notification hook JSON and state_from_notification
    \\# decides whether it means "needs you". The old hardcoded form flagged every
    \\# notification type (idle_prompt, auth_success, ...) as awaiting_approval.
    \\CLAUDE_APPROVAL = "cadre notify || true"
    \\CLAUDE_APPROVAL_LEGACY = "cadre notify awaiting_approval || true"
    \\CLAUDE_SESSION = "cadre agent-session || true"
    \\# Pre-rename commands (binary was `architect`); rewritten in place so panes
    \\# spawned before the rename keep notifying. ponytail: drop once no settings
    \\# file on any machine still carries them.
    \\LEGACY_RENAMES = (
    \\    ("architect notify done || true", CLAUDE_DONE),
    \\    ("architect notify || true", CLAUDE_APPROVAL),
    \\    ("architect notify awaiting_approval || true", CLAUDE_APPROVAL),
    \\    ("architect agent-session || true", CLAUDE_SESSION),
    \\)
    \\CLAUDE_NEEDLES = ("cadre notify", "cadre_notify.py")
    \\CLAUDE_SESSION_NEEDLES = ("cadre agent-session",)
    \\
    \\GEMINI_DONE = "python3 ~/.gemini/cadre_hook.py done"
    \\GEMINI_APPROVAL = "python3 ~/.gemini/cadre_hook.py awaiting_approval"
    \\GEMINI_NEEDLES = ("cadre_hook.py", "cadre notify")
    \\
    \\CODEX_NOTIFY = ["cadre", "notify"]
    \\
    \\def notify_cadre(state: str) -> None:
    \\    # ARCHITECT_* fallback: panes spawned before the rename carry the old env.
    \\    session_id = os.environ.get("CADRE_SESSION_ID") or os.environ.get("ARCHITECT_SESSION_ID")
    \\    sock_path = os.environ.get("CADRE_NOTIFY_SOCK") or os.environ.get("ARCHITECT_NOTIFY_SOCK")
    \\
    \\    if not session_id or not sock_path:
    \\        return
    \\
    \\    try:
    \\        message = json.dumps({
    \\            "session": int(session_id),
    \\            "state": state
    \\        }) + "\n"
    \\
    \\        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\        sock.connect(sock_path)
    \\        sock.sendall(message.encode())
    \\        sock.close()
    \\    except Exception:
    \\        pass
    \\
    \\def send_agent_session(session_id: str) -> None:
    \\    slot = os.environ.get("CADRE_SESSION_ID")
    \\    sock_path = os.environ.get("CADRE_NOTIFY_SOCK")
    \\    if not slot or not sock_path or not session_id:
    \\        return
    \\    try:
    \\        message = json.dumps({
    \\            "session": int(slot),
    \\            "type": "agent_session",
    \\            "agent": "claude",
    \\            "session_id": session_id,
    \\        }) + "\n"
    \\        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\        sock.connect(sock_path)
    \\        sock.sendall(message.encode())
    \\        sock.close()
    \\    except Exception:
    \\        pass
    \\
    \\def cmd_agent_session() -> int:
    \\    # Invoked as a Claude Code SessionStart hook. Claude pipes the hook event
    \\    # JSON (which carries "session_id") to stdin; forward that id to Cadre.
    \\    try:
    \\        raw = sys.stdin.read()
    \\    except Exception:
    \\        return 0
    \\    if not raw.strip():
    \\        return 0
    \\    try:
    \\        payload = json.loads(raw)
    \\    except Exception:
    \\        return 0
    \\    if isinstance(payload, dict):
    \\        session_id = payload.get("session_id")
    \\        if isinstance(session_id, str) and session_id:
    \\            send_agent_session(session_id)
    \\    return 0
    \\
    \\# Claude Code Notification hook types that actually need the user. Everything
    \\# else (idle_prompt, auth_success, elicitation_complete, ...) is noise for the
    \\# "needs you" badge and must be ignored, not mapped by substring heuristics.
    \\CLAUDE_NEEDS_YOU_TYPES = {
    \\    "permission_prompt",
    \\    "agent_needs_input",
    \\    "elicitation_dialog",
    \\}
    \\
    \\def state_from_notification(raw: str) -> str | None:
    \\    raw = raw.strip()
    \\    if not raw:
    \\        return None
    \\
    \\    if raw in VALID_STATES:
    \\        return raw
    \\
    \\    try:
    \\        payload = json.loads(raw)
    \\    except json.JSONDecodeError:
    \\        return None
    \\
    \\    if not isinstance(payload, dict):
    \\        return None
    \\
    \\    state_field = payload.get("state")
    \\    if isinstance(state_field, str) and state_field in VALID_STATES:
    \\        return state_field
    \\
    \\    # Claude Code Notification payloads carry notification_type; it is
    \\    # authoritative when present. Older Claude versions only carry message.
    \\    claude_type = payload.get("notification_type")
    \\    if isinstance(claude_type, str) and claude_type:
    \\        if claude_type.lower() in CLAUDE_NEEDS_YOU_TYPES:
    \\            return "awaiting_approval"
    \\        return None
    \\    if str(payload.get("hook_event_name") or "") == "Notification":
    \\        message = str(payload.get("message") or "").lower()
    \\        if "permission" in message or "approval" in message:
    \\            return "awaiting_approval"
    \\        return None
    \\
    \\    status = payload.get("status")
    \\    if isinstance(status, str):
    \\        lowered = status.lower()
    \\        if lowered in VALID_STATES:
    \\            return lowered
    \\        if lowered in ("complete", "completed", "finished", "success"):
    \\            return "done"
    \\        if "approval" in lowered or "permission" in lowered:
    \\            return "awaiting_approval"
    \\
    \\    ntype = str(payload.get("type") or "").lower()
    \\    if ntype:
    \\        if ntype in VALID_STATES:
    \\            return ntype
    \\        if "approval" in ntype or "permission" in ntype or (
    \\            "input" in ntype and "await" in ntype
    \\        ):
    \\            return "awaiting_approval"
    \\        if "complete" in ntype or ntype.endswith("-done"):
    \\            return "done"
    \\        if "start" in ntype or "begin" in ntype:
    \\            return "start"
    \\
    \\    return None
    \\
    \\def warn_unmapped(raw: str) -> None:
    \\    if sys.stderr.isatty():
    \\        print(f"Ignoring unmapped notification: {raw}", file=sys.stderr)
    \\
    \\def print_usage() -> None:
    \\    if sys.stderr.isatty():
    \\        print("Usage: cadre notify <state|json>", file=sys.stderr)
    \\        print("       cadre notify  (reads stdin)", file=sys.stderr)
    \\        print("       cadre hook claude|codex|gemini", file=sys.stderr)
    \\        print("       cadre story <filename>", file=sys.stderr)
    \\
    \\def timestamp_suffix() -> str:
    \\    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    \\
    \\def backup_path(path: str) -> str:
    \\    return f"{path}.cadre.bak.{timestamp_suffix()}"
    \\
    \\def backup_file(path: str) -> str | None:
    \\    try:
    \\        if os.path.exists(path):
    \\            backup = backup_path(path)
    \\            shutil.copy2(path, backup)
    \\            return backup
    \\    except OSError:
    \\        return None
    \\    return None
    \\
    \\def read_text(path: str) -> str | None:
    \\    try:
    \\        with open(path, "r", encoding="utf-8") as handle:
    \\            return handle.read()
    \\    except FileNotFoundError:
    \\        return None
    \\
    \\def write_text(path: str, text: str) -> None:
    \\    parent = os.path.dirname(path)
    \\    if parent:
    \\        os.makedirs(parent, exist_ok=True)
    \\    with open(path, "w", encoding="utf-8") as handle:
    \\        handle.write(text)
    \\
    \\def load_json(path: str) -> dict | None:
    \\    text = read_text(path)
    \\    if text is None:
    \\        return None
    \\    try:
    \\        return json.loads(text)
    \\    except json.JSONDecodeError:
    \\        return None
    \\
    \\def write_json(path: str, data: dict) -> None:
    \\    write_text(path, json.dumps(data, indent=2, sort_keys=False) + "\n")
    \\
    \\def command_has_needle(command: str, needles: tuple[str, ...]) -> bool:
    \\    return any(needle in command for needle in needles)
    \\
    \\def hooks_have_needles(groups, needles: tuple[str, ...]) -> bool:
    \\    if not isinstance(groups, list):
    \\        return False
    \\    for group in groups:
    \\        hooks = group.get("hooks") if isinstance(group, dict) else None
    \\        if not isinstance(hooks, list):
    \\            continue
    \\        for hook in hooks:
    \\            if not isinstance(hook, dict):
    \\                continue
    \\            cmd = hook.get("command")
    \\            if isinstance(cmd, str) and command_has_needle(cmd, needles):
    \\                return True
    \\    return False
    \\
    \\def normalize_notify(value) -> list[str] | None:
    \\    if not isinstance(value, list):
    \\        return None
    \\    if not all(isinstance(item, str) for item in value):
    \\        return None
    \\    return value
    \\
    \\def is_cadre_notify(command: list[str]) -> bool:
    \\    if command == CODEX_NOTIFY:
    \\        return True
    \\    for item in command:
    \\        if "cadre_notify.py" in item:
    \\            return True
    \\    return False
    \\
    \\def parse_notify_from_text(text: str) -> list[str] | None:
    \\    for line in text.splitlines():
    \\        stripped = line.strip()
    \\        if not stripped or stripped.startswith("#"):
    \\            continue
    \\        if stripped.startswith("notify"):
    \\            parts = stripped.split("=", 1)
    \\            if len(parts) != 2:
    \\                return None
    \\            value = parts[1].split("#", 1)[0].strip()
    \\            if not value.startswith("[") or not value.endswith("]"):
    \\                return None
    \\            try:
    \\                parsed = json.loads(value)
    \\            except json.JSONDecodeError:
    \\                return None
    \\            return normalize_notify(parsed)
    \\    return None
    \\
    \\def has_notify_line(text: str) -> bool:
    \\    for line in text.splitlines():
    \\        stripped = line.strip()
    \\        if not stripped or stripped.startswith("#"):
    \\            continue
    \\        if stripped.startswith("notify"):
    \\            return True
    \\    return False
    \\
    \\def read_codex_notify(text: str) -> list[str] | None:
    \\    if tomllib is not None:
    \\        try:
    \\            data = tomllib.loads(text)
    \\            value = data.get("notify")
    \\            parsed = normalize_notify(value)
    \\            if parsed is not None:
    \\                return parsed
    \\        except tomllib.TOMLDecodeError:
    \\            return None
    \\    return parse_notify_from_text(text)
    \\
    \\def ensure_group(groups):
    \\    if not groups:
    \\        group = {"hooks": []}
    \\        groups.append(group)
    \\        return group
    \\    group = groups[0]
    \\    if not isinstance(group, dict):
    \\        group = {"hooks": []}
    \\        groups[0] = group
    \\    if not isinstance(group.get("hooks"), list):
    \\        group["hooks"] = []
    \\    return group
    \\
    \\def ensure_matcher_group(groups):
    \\    if not groups:
    \\        group = {"matcher": "*", "hooks": []}
    \\        groups.append(group)
    \\        return group
    \\    for group in groups:
    \\        if isinstance(group, dict) and group.get("matcher") == "*":
    \\            if not isinstance(group.get("hooks"), list):
    \\                group["hooks"] = []
    \\            return group
    \\    group = {"matcher": "*", "hooks": []}
    \\    groups.append(group)
    \\    return group
    \\
    \\def replace_hook_command(groups, legacy: str, new: str) -> bool:
    \\    if not isinstance(groups, list):
    \\        return False
    \\    changed = False
    \\    for group in groups:
    \\        hooks = group.get("hooks") if isinstance(group, dict) else None
    \\        if not isinstance(hooks, list):
    \\            continue
    \\        for hook in hooks:
    \\            if isinstance(hook, dict) and hook.get("command") == legacy:
    \\                hook["command"] = new
    \\                changed = True
    \\    return changed
    \\
    \\def ensure_claude_hooks(data: dict) -> bool:
    \\    hooks = data.setdefault("hooks", {})
    \\    if not isinstance(hooks, dict):
    \\        hooks = {}
    \\        data["hooks"] = hooks
    \\    stop_groups = hooks.setdefault("Stop", [])
    \\    notification_groups = hooks.setdefault("Notification", [])
    \\    changed = False
    \\
    \\    for legacy, new in LEGACY_RENAMES:
    \\        for groups in (stop_groups, notification_groups, hooks.setdefault("SessionStart", [])):
    \\            if replace_hook_command(groups, legacy, new):
    \\                changed = True
    \\
    \\    if not hooks_have_needles(stop_groups, CLAUDE_NEEDLES):
    \\        group = ensure_group(stop_groups)
    \\        group["hooks"].append({"type": "command", "command": CLAUDE_DONE})
    \\        changed = True
    \\
    \\    # The needle check treats the legacy hardcoded command as installed, so
    \\    # migrate it in place before deciding whether to append a fresh hook.
    \\    if replace_hook_command(notification_groups, CLAUDE_APPROVAL_LEGACY, CLAUDE_APPROVAL):
    \\        changed = True
    \\
    \\    if not hooks_have_needles(notification_groups, CLAUDE_NEEDLES):
    \\        group = ensure_group(notification_groups)
    \\        group["hooks"].append({"type": "command", "command": CLAUDE_APPROVAL})
    \\        changed = True
    \\
    \\    session_groups = hooks.setdefault("SessionStart", [])
    \\    if not hooks_have_needles(session_groups, CLAUDE_SESSION_NEEDLES):
    \\        # Append a fresh matcher-less group so it runs on every session start
    \\        # (startup/resume/clear/compact), independent of any existing groups.
    \\        session_groups.append({"hooks": [{"type": "command", "command": CLAUDE_SESSION}]})
    \\        changed = True
    \\
    \\    return changed
    \\
    \\def ensure_gemini_hooks(data: dict) -> bool:
    \\    hooks = data.setdefault("hooks", {})
    \\    if not isinstance(hooks, dict):
    \\        hooks = {}
    \\        data["hooks"] = hooks
    \\    after_groups = hooks.setdefault("AfterAgent", [])
    \\    notification_groups = hooks.setdefault("Notification", [])
    \\    changed = False
    \\
    \\    if not hooks_have_needles(after_groups, GEMINI_NEEDLES):
    \\        group = ensure_matcher_group(after_groups)
    \\        group["hooks"].append({
    \\            "name": "cadre-completion",
    \\            "type": "command",
    \\            "command": GEMINI_DONE,
    \\            "description": "Notify Cadre when task completes",
    \\        })
    \\        changed = True
    \\
    \\    if not hooks_have_needles(notification_groups, GEMINI_NEEDLES):
    \\        group = ensure_matcher_group(notification_groups)
    \\        group["hooks"].append({
    \\            "name": "cadre-approval",
    \\            "type": "command",
    \\            "command": GEMINI_APPROVAL,
    \\            "description": "Notify Cadre when waiting for approval",
    \\        })
    \\        changed = True
    \\
    \\    tools = data.setdefault("tools", {})
    \\    if not isinstance(tools, dict):
    \\        tools = {}
    \\        data["tools"] = tools
    \\    if tools.get("enableHooks") is not True:
    \\        tools["enableHooks"] = True
    \\        changed = True
    \\
    \\    return changed
    \\
    \\
    \\def upsert_notify_line(text: str, line: str) -> str:
    \\    lines = text.splitlines()
    \\    filtered = []
    \\    for existing in lines:
    \\        stripped = existing.strip()
    \\        if stripped.startswith("notify") and not stripped.startswith("#"):
    \\            continue
    \\        filtered.append(existing)
    \\    lines = filtered
    \\    insert_idx = None
    \\    for i, existing in enumerate(lines):
    \\        stripped = existing.strip()
    \\        if not stripped or stripped.startswith("#"):
    \\            continue
    \\        if stripped.startswith("["):
    \\            insert_idx = i
    \\            break
    \\    if insert_idx is None:
    \\        if lines and lines[-1].strip() != "":
    \\            lines.append("")
    \\        lines.append(line)
    \\    else:
    \\        lines.insert(insert_idx, line)
    \\    return "\n".join(lines) + "\n"
    \\
    \\def install_claude() -> int:
    \\    path = os.path.expanduser("~/.claude/settings.json")
    \\    data = load_json(path)
    \\    if data is None:
    \\        # load_json returns None for a MISSING file and a MALFORMED one alike.
    \\        # A missing file is fine (fresh machine) — start from an empty config so
    \\        # the hook can still be installed. A malformed file must not be
    \\        # clobbered, so bail only when the file actually exists.
    \\        if os.path.exists(path):
    \\            print(f"Failed to read {path}", file=sys.stderr)
    \\            return 1
    \\        data = {}
    \\    if ensure_claude_hooks(data):
    \\        backup = backup_file(path)
    \\        if backup:
    \\            print(f"Wrote backup to {backup}")
    \\        write_json(path, data)
    \\        print("Installed Claude hooks.")
    \\    else:
    \\        print("Claude hooks already installed.")
    \\    return 0
    \\
    \\def install_gemini() -> int:
    \\    path = os.path.expanduser("~/.gemini/settings.json")
    \\    data = load_json(path)
    \\    if data is None:
    \\        print(f"Failed to read {path}", file=sys.stderr)
    \\        return 1
    \\    if ensure_gemini_hooks(data):
    \\        backup = backup_file(path)
    \\        if backup:
    \\            print(f"Wrote backup to {backup}")
    \\        write_json(path, data)
    \\        print("Installed Gemini hooks.")
    \\    else:
    \\        print("Gemini hooks already installed.")
    \\    return 0
    \\
    \\def install_codex() -> int:
    \\    path = os.path.expanduser("~/.codex/config.toml")
    \\    text = read_text(path)
    \\    if text is None:
    \\        print(f"Failed to read {path}", file=sys.stderr)
    \\        return 1
    \\    existing = read_codex_notify(text)
    \\    if existing is not None and is_cadre_notify(existing):
    \\        print("Codex hooks already installed.")
    \\        return 0
    \\    if existing is not None or has_notify_line(text):
    \\        print("Warning: replacing existing Codex notify configuration.", file=sys.stderr)
    \\    notify_line = f"notify = {json.dumps(CODEX_NOTIFY)}"
    \\    new_text = upsert_notify_line(text, notify_line)
    \\    backup = backup_file(path)
    \\    if backup:
    \\        print(f"Wrote backup to {backup}")
    \\    write_text(path, new_text)
    \\    print("Installed Codex hooks.")
    \\    return 0
    \\
    \\def main() -> int:
    \\    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
    \\        print_usage()
    \\        return 1
    \\
    \\    cmd = sys.argv[1]
    \\    if cmd == "notify":
    \\        raw_arg = sys.argv[2] if len(sys.argv) >= 3 else sys.stdin.read()
    \\        if not raw_arg.strip():
    \\            print_usage()
    \\            return 1
    \\        state = state_from_notification(raw_arg)
    \\        if state is None:
    \\            warn_unmapped(raw_arg)
    \\            return 0
    \\        notify_cadre(state)
    \\        return 0
    \\    if cmd == "agent-session":
    \\        return cmd_agent_session()
    \\    if cmd == "hook":
    \\        if len(sys.argv) < 3:
    \\            print_usage()
    \\            return 1
    \\        sub = sys.argv[2]
    \\        if sub == "claude":
    \\            return install_claude()
    \\        if sub == "codex":
    \\            return install_codex()
    \\        if sub == "gemini":
    \\            return install_gemini()
    \\        print_usage()
    \\        return 1
    \\    if cmd == "story":
    \\        if len(sys.argv) < 3:
    \\            print("Usage: cadre story <filename>", file=sys.stderr)
    \\            return 1
    \\        path = os.path.abspath(sys.argv[2])
    \\        if not os.path.isfile(path):
    \\            print(f"File not found: {path}", file=sys.stderr)
    \\            return 1
    \\        session_id = os.environ.get("CADRE_SESSION_ID") or os.environ.get("ARCHITECT_SESSION_ID")
    \\        sock_path = os.environ.get("CADRE_NOTIFY_SOCK") or os.environ.get("ARCHITECT_NOTIFY_SOCK")
    \\        if not session_id or not sock_path:
    \\            print("Not running inside Cadre", file=sys.stderr)
    \\            return 1
    \\        message = json.dumps({
    \\            "session": int(session_id),
    \\            "type": "story",
    \\            "path": path
    \\        }) + "\n"
    \\        try:
    \\            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\            sock.connect(sock_path)
    \\            sock.sendall(message.encode())
    \\            sock.close()
    \\        except Exception as e:
    \\            print(f"Failed to notify Cadre: {e}", file=sys.stderr)
    \\            return 1
    \\        return 0
    \\
    \\    print_usage()
    \\    return 1
    \\
    \\if __name__ == "__main__":
    \\    raise SystemExit(main())
    \\
;

const cadre_zsh_env_script =
    \\# Generated by Cadre to preserve ZDOTDIR startup files.
    \\orig="${CADRE_ZDOTDIR_ORIG:-}"
    \\wrapper="${CADRE_ZDOTDIR_WRAPPER:-}"
    \\source_dir="$orig"
    \\if [ -z "$source_dir" ]; then
    \\  source_dir="$HOME"
    \\fi
    \\if [ -n "$source_dir" ] && [ -f "$source_dir/.zshenv" ]; then
    \\  ZDOTDIR="$source_dir"
    \\  export ZDOTDIR
    \\  . "$source_dir/.zshenv"
    \\fi
    \\if [ -n "$wrapper" ]; then
    \\  ZDOTDIR="$wrapper"
    \\  export ZDOTDIR
    \\else
    \\  unset ZDOTDIR
    \\fi
    \\unset orig
    \\unset wrapper
    \\unset source_dir
    \\
;

const cadre_zsh_profile_script =
    \\# Generated by Cadre to preserve PATH injection in login shells.
    \\orig="${CADRE_ZDOTDIR_ORIG:-}"
    \\wrapper="${CADRE_ZDOTDIR_WRAPPER:-}"
    \\source_dir="$orig"
    \\if [ -z "$source_dir" ]; then
    \\  source_dir="$HOME"
    \\fi
    \\if [ -n "$source_dir" ] && [ -f "$source_dir/.zprofile" ]; then
    \\  ZDOTDIR="$source_dir"
    \\  export ZDOTDIR
    \\  . "$source_dir/.zprofile"
    \\fi
    \\if [ -n "$wrapper" ]; then
    \\  ZDOTDIR="$wrapper"
    \\  export ZDOTDIR
    \\else
    \\  unset ZDOTDIR
    \\fi
    \\if [ -n "${CADRE_COMMAND_DIR:-}" ]; then
    \\  case ":$PATH:" in
    \\    *":$CADRE_COMMAND_DIR:"*) ;;
    \\    *) PATH="$CADRE_COMMAND_DIR:$PATH" ;;
    \\  esac
    \\  export PATH
    \\fi
    \\unset orig
    \\unset wrapper
    \\unset source_dir
    \\
;

const cadre_zsh_rc_script =
    \\# Generated by Cadre to preserve PATH injection for interactive shells.
    \\orig="${CADRE_ZDOTDIR_ORIG:-}"
    \\wrapper="${CADRE_ZDOTDIR_WRAPPER:-}"
    \\source_dir="$orig"
    \\if [ -z "$source_dir" ]; then
    \\  source_dir="$HOME"
    \\fi
    \\if [ -n "$source_dir" ] && [ -f "$source_dir/.zshrc" ]; then
    \\  ZDOTDIR="$source_dir"
    \\  export ZDOTDIR
    \\  . "$source_dir/.zshrc"
    \\fi
    \\if [ -n "$wrapper" ]; then
    \\  ZDOTDIR="$wrapper"
    \\  export ZDOTDIR
    \\else
    \\  unset ZDOTDIR
    \\fi
    \\cadre_path_guard() {
    \\  if [ -n "${CADRE_COMMAND_DIR:-}" ]; then
    \\    case ":$PATH:" in
    \\      *":$CADRE_COMMAND_DIR:"*) ;;
    \\      *) PATH="$CADRE_COMMAND_DIR:$PATH" ;;
    \\    esac
    \\    export PATH
    \\  fi
    \\}
    \\if typeset -p precmd_functions >/dev/null 2>&1; then
    \\  case " ${precmd_functions[@]} " in
    \\    *" cadre_path_guard "*) ;;
    \\    *) precmd_functions+=(cadre_path_guard) ;;
    \\  esac
    \\else
    \\  precmd_functions=(cadre_path_guard)
    \\fi
    \\if typeset -p chpwd_functions >/dev/null 2>&1; then
    \\  case " ${chpwd_functions[@]} " in
    \\    *" cadre_path_guard "*) ;;
    \\    *) chpwd_functions+=(cadre_path_guard) ;;
    \\  esac
    \\else
    \\  chpwd_functions=(cadre_path_guard)
    \\fi
    \\cadre_path_guard
    \\if [ -n "$orig" ]; then
    \\  ZDOTDIR="$orig"
    \\  export ZDOTDIR
    \\else
    \\  unset ZDOTDIR
    \\fi
    \\unset orig
    \\unset wrapper
    \\unset source_dir
    \\# Cadre: run the restore/resume command ONCE, after the user's rc has
    \\# finished loading (so `claude`/PATH are ready) and stdin is the live tty.
    \\# It is executed, never typed into the PTY, so a startup prompt (e.g. an
    \\# oh-my-zsh update [Y/n]) cannot swallow it. Unset first so the launched
    \\# program and any nested shells do not re-run it.
    \\if [ -n "${CADRE_RESUME_CMD:-}" ]; then
    \\  cadre__resume_cmd="$CADRE_RESUME_CMD"
    \\  unset CADRE_RESUME_CMD
    \\  eval "$cadre__resume_cmd"
    \\  unset cadre__resume_cmd
    \\fi
    \\
;

const cadre_zsh_login_script =
    \\# Generated by Cadre to preserve ZDOTDIR startup files.
    \\orig="${CADRE_ZDOTDIR_ORIG:-}"
    \\wrapper="${CADRE_ZDOTDIR_WRAPPER:-}"
    \\source_dir="$orig"
    \\if [ -z "$source_dir" ]; then
    \\  source_dir="$HOME"
    \\fi
    \\if [ -n "$source_dir" ] && [ -f "$source_dir/.zlogin" ]; then
    \\  ZDOTDIR="$source_dir"
    \\  export ZDOTDIR
    \\  . "$source_dir/.zlogin"
    \\fi
    \\if [ -n "$orig" ]; then
    \\  ZDOTDIR="$orig"
    \\  export ZDOTDIR
    \\else
    \\  unset ZDOTDIR
    \\fi
    \\unset orig
    \\unset wrapper
    \\unset source_dir
    \\
;

fn setDefaultEnv(name: [:0]const u8, value: [:0]const u8) void {
    if (posix.getenv(name) != null) return;
    if (libc.setenv(name, value, 1) != 0) {
        std.c._exit(1);
    }
}

fn setEnv(name: [:0]const u8, value: [:0]const u8) void {
    if (libc.setenv(name, value, 1) != 0) {
        std.c._exit(1);
    }
}

/// Ensure xterm-ghostty terminfo is compiled and available.
/// Installs to ~/.cache/cadre/terminfo. Must be called from parent process before fork.
pub fn ensureTerminfoSetup() void {
    if (terminfo_setup_done) return;
    terminfo_setup_done = true;

    // Install to ~/.cache/cadre/terminfo
    const home = posix.getenv("HOME") orelse {
        log.warn("HOME not set, cannot install terminfo, falling back to {s}", .{fallback_term});
        return;
    };

    const cache_dir_z = std.fmt.bufPrintZ(&terminfo_dir_buf, "{s}/.cache/cadre/terminfo", .{home}) catch {
        log.warn("Failed to format terminfo cache path", .{});
        return;
    };
    const cache_dir = cache_dir_z[0..cache_dir_z.len];

    // Create cache directory structure (including parents)
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Create ~/.cache first if needed
    const dot_cache = std.fmt.bufPrint(&parent_buf, "{s}/.cache", .{home}) catch return;
    std.fs.makeDirAbsolute(dot_cache) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create .cache dir: {}", .{err});
            return;
        },
    };

    // Create ~/.cache/cadre (parent of terminfo dir)
    var cadre_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cadre_dir = std.fmt.bufPrint(&cadre_buf, "{s}/.cache/cadre", .{home}) catch return;
    std.fs.makeDirAbsolute(cadre_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create cadre cache dir: {}", .{err});
            return;
        },
    };

    // Create terminfo dir
    std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create terminfo cache dir: {}", .{err});
            return;
        },
    };

    // Create x subdir for terminfo entries
    var x_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const x_dir = std.fmt.bufPrint(&x_dir_buf, "{s}/x", .{cache_dir}) catch return;
    std.fs.makeDirAbsolute(x_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("Failed to create terminfo x dir: {}", .{err});
            return;
        },
    };

    // Write terminfo source to temp file (need null-terminated paths for execve)
    var src_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path_z = std.fmt.bufPrintZ(&src_path_buf, "{s}/xterm-ghostty.ti", .{cache_dir}) catch return;

    const src_file = std.fs.createFileAbsolute(src_path_z, .{}) catch |err| {
        log.warn("Failed to create terminfo source file: {}", .{err});
        return;
    };
    defer src_file.close();
    src_file.writeAll(cadre_terminfo_src) catch |err| {
        log.warn("Failed to write terminfo source: {}", .{err});
        return;
    };

    const tic_path = findExecutableInPath("tic") orelse {
        log.warn("tic not found in PATH, falling back to {s}", .{fallback_term});
        return;
    };

    // Compile with tic
    const tic_argv = [_:null]?[*:0]const u8{
        tic_path.ptr,
        "-x",
        "-o",
        cache_dir_z.ptr,
        src_path_z.ptr,
        null,
    };

    const fork_result = std.c.fork();
    if (fork_result == 0) {
        // Child: exec tic
        _ = std.c.execve(tic_path.ptr, &tic_argv, @ptrCast(std.c.environ));
        std.c._exit(1);
    } else if (fork_result > 0) {
        // Parent: wait for tic to complete
        var status: c_int = 0;
        _ = std.c.waitpid(fork_result, &status, 0);

        if (wifexited(status) and wexitstatus(status) == 0) {
            log.info("Successfully compiled {s} terminfo to {s}", .{ cadre_term, cache_dir_z });
            terminfo_dir_z = cache_dir_z;
            terminfo_available = true;
        } else {
            log.warn("tic failed to compile terminfo (status={}), falling back to {s}", .{ status, fallback_term });
        }
    } else {
        log.warn("Failed to fork for tic, falling back to {s}", .{fallback_term});
    }
}

fn ensureCadreCommandSetup() void {
    if (cadre_command_setup_done) return;
    cadre_command_setup_done = true;

    const runtime_dir = posix.getenv("XDG_RUNTIME_DIR");
    const home = posix.getenv("HOME");
    const base_dir_z: [:0]const u8 = if (runtime_dir) |dir|
        std.fmt.bufPrintZ(&cadre_command_base_buf, "{s}/cadre", .{dir}) catch |err| {
            log.warn("failed to format cadre runtime path: {}", .{err});
            return;
        }
    else if (home) |home_dir|
        std.fmt.bufPrintZ(&cadre_command_base_buf, "{s}/.cache/cadre", .{home_dir}) catch |err| {
            log.warn("failed to format cadre cache path: {}", .{err});
            return;
        }
    else
        "/tmp/cadre";

    cadre_command_base_z = base_dir_z;
    const base_dir = std.mem.sliceTo(base_dir_z, 0);

    std.fs.makeDirAbsolute(base_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("failed to create cadre command base dir: {}", .{err});
            return;
        },
    };

    const bin_dir_z = std.fmt.bufPrintZ(&cadre_command_dir_buf, "{s}/bin", .{base_dir}) catch |err| {
        log.warn("failed to format cadre bin path: {}", .{err});
        return;
    };
    const bin_dir = bin_dir_z[0..bin_dir_z.len];

    std.fs.makeDirAbsolute(bin_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("failed to create cadre bin dir: {}", .{err});
            return;
        },
    };

    const script_path_z = std.fmt.bufPrintZ(&cadre_command_path_buf, "{s}/cadre", .{bin_dir}) catch |err| {
        log.warn("failed to format cadre command path: {}", .{err});
        return;
    };

    const script_file = std.fs.createFileAbsolute(script_path_z, .{ .truncate = true }) catch |err| {
        log.warn("failed to create cadre command: {}", .{err});
        return;
    };
    defer script_file.close();

    script_file.writeAll(cadre_command_script) catch |err| {
        log.warn("failed to write cadre command: {}", .{err});
        return;
    };

    const script_path = std.mem.sliceTo(script_path_z, 0);
    posix.fchmodat(posix.AT.FDCWD, script_path, 0o755, 0) catch |err| {
        log.warn("failed to chmod cadre command: {}", .{err});
    };

    cadre_command_path_z = script_path_z;
    cadre_command_dir_z = bin_dir_z;
}

/// Best-effort: install Claude's hooks (Stop/Notification for attention, and
/// SessionStart for LIVE resume-id capture) into ~/.claude/settings.json by
/// running the materialized `cadre hook claude` helper. This is what writes
/// a running agent's resume id into persistence.toml *while it runs* — the only
/// window a full device reboot leaves, since a reboot SIGKILLs the process with
/// no chance to scrape the id at shutdown. Without the hook, resume-on-reboot
/// silently does nothing and terminals return as bare shells.
///
/// Idempotent: the installer is a no-op when the hooks already exist. Call once
/// at startup, BEFORE agents spawn, so this run's agents also get the hook.
/// Never fails the launch — on any error it warns and returns; the user can
/// still install manually with `cadre hook claude`.
pub fn ensureClaudeHookInstalled(allocator: std.mem.Allocator) void {
    ensureCadreCommandSetup();
    const script_path = cadre_command_path_z orelse {
        log.warn("skipping Claude hook auto-install: cadre command helper unavailable", .{});
        return;
    };

    var child = std.process.Child.init(&[_][]const u8{ script_path, "hook", "claude" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch |err| {
        log.warn("Claude hook auto-install could not run ({}); resume-across-reboot may be unavailable until you run `cadre hook claude`", .{err});
        return;
    };
    switch (term) {
        .Exited => |code| if (code != 0) {
            log.warn("Claude hook auto-install exited {d}; resume-across-reboot may be unavailable until you run `cadre hook claude`", .{code});
        },
        else => log.warn("Claude hook auto-install terminated abnormally; resume-across-reboot may be unavailable", .{}),
    }
}

fn isShellNamed(shell_path: []const u8, name: []const u8) bool {
    const base = std.fs.path.basename(shell_path);
    return std.mem.eql(u8, base, name);
}

fn ensureCadreZshProfileSetup() void {
    if (cadre_zsh_profile_setup_done) return;
    cadre_zsh_profile_setup_done = true;

    const base_dir_z = cadre_command_base_z orelse return;
    const base_dir = std.mem.sliceTo(base_dir_z, 0);

    var zsh_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsh_dir_z = std.fmt.bufPrintZ(&zsh_dir_buf, "{s}/zsh", .{base_dir}) catch |err| {
        log.warn("failed to format cadre zsh dir: {}", .{err});
        return;
    };

    std.fs.makeDirAbsolute(zsh_dir_z) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            log.warn("failed to create cadre zsh dir: {}", .{err});
            return;
        },
    };

    var env_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const env_path_z = std.fmt.bufPrintZ(&env_path_buf, "{s}/.zshenv", .{zsh_dir_z}) catch |err| {
        log.warn("failed to format cadre zsh env path: {}", .{err});
        return;
    };

    const env_file = std.fs.createFileAbsolute(env_path_z, .{ .truncate = true }) catch |err| {
        log.warn("failed to create cadre zsh env: {}", .{err});
        return;
    };
    defer env_file.close();

    env_file.writeAll(cadre_zsh_env_script) catch |err| {
        log.warn("failed to write cadre zsh env: {}", .{err});
        return;
    };

    var profile_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const profile_path_z = std.fmt.bufPrintZ(&profile_path_buf, "{s}/.zprofile", .{zsh_dir_z}) catch |err| {
        log.warn("failed to format cadre zsh profile path: {}", .{err});
        return;
    };

    const profile_file = std.fs.createFileAbsolute(profile_path_z, .{ .truncate = true }) catch |err| {
        log.warn("failed to create cadre zsh profile: {}", .{err});
        return;
    };
    defer profile_file.close();

    profile_file.writeAll(cadre_zsh_profile_script) catch |err| {
        log.warn("failed to write cadre zsh profile: {}", .{err});
        return;
    };

    var rc_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc_path_z = std.fmt.bufPrintZ(&rc_path_buf, "{s}/.zshrc", .{zsh_dir_z}) catch |err| {
        log.warn("failed to format cadre zsh rc path: {}", .{err});
        return;
    };

    const rc_file = std.fs.createFileAbsolute(rc_path_z, .{ .truncate = true }) catch |err| {
        log.warn("failed to create cadre zsh rc: {}", .{err});
        return;
    };
    defer rc_file.close();

    rc_file.writeAll(cadre_zsh_rc_script) catch |err| {
        log.warn("failed to write cadre zsh rc: {}", .{err});
        return;
    };

    var login_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const login_path_z = std.fmt.bufPrintZ(&login_path_buf, "{s}/.zlogin", .{zsh_dir_z}) catch |err| {
        log.warn("failed to format cadre zsh login path: {}", .{err});
        return;
    };

    const login_file = std.fs.createFileAbsolute(login_path_z, .{ .truncate = true }) catch |err| {
        log.warn("failed to create cadre zsh login: {}", .{err});
        return;
    };
    defer login_file.close();

    login_file.writeAll(cadre_zsh_login_script) catch |err| {
        log.warn("failed to write cadre zsh login: {}", .{err});
        return;
    };

    cadre_zsh_profile_ready = true;
}

fn configureZshPathInjection(shell_path: []const u8) void {
    if (!isShellNamed(shell_path, "zsh")) return;
    if (!cadre_zsh_profile_ready) return;

    const command_dir_z = cadre_command_dir_z orelse return;
    setEnv("CADRE_COMMAND_DIR", command_dir_z);

    const empty_zdotdir: [:0]const u8 = "";
    const original_zdotdir = posix.getenv("ZDOTDIR") orelse empty_zdotdir;
    setEnv("CADRE_ZDOTDIR_ORIG", original_zdotdir);

    const base_dir_z = cadre_command_base_z orelse return;
    const base_dir = std.mem.sliceTo(base_dir_z, 0);

    var zsh_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zsh_dir_z = std.fmt.bufPrintZ(&zsh_dir_buf, "{s}/zsh", .{base_dir}) catch |err| {
        log.warn("failed to format cadre zsh dir for env: {}", .{err});
        return;
    };

    setEnv("CADRE_ZDOTDIR_WRAPPER", zsh_dir_z);
    setEnv("ZDOTDIR", zsh_dir_z);
}

fn pathContainsEntry(path: []const u8, entry: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, entry)) return true;
    }
    return false;
}

fn ensureCadreCommandPath() void {
    const dir_z = cadre_command_dir_z orelse return;
    const dir = std.mem.sliceTo(dir_z, 0);

    const path_env = posix.getenv("PATH") orelse "";
    const path_slice = std.mem.sliceTo(path_env, 0);
    if (pathContainsEntry(path_slice, dir)) return;

    const needs_sep = path_slice.len > 0;
    const sep_len: usize = if (needs_sep) 1 else 0;
    const total_len = dir.len + sep_len + path_slice.len;
    const buf = std.heap.c_allocator.alloc(u8, total_len + 1) catch |err| {
        log.warn("failed to allocate PATH for cadre command: {}", .{err});
        return;
    };
    defer std.heap.c_allocator.free(buf);

    var idx: usize = 0;
    std.mem.copyForwards(u8, buf[idx..][0..dir.len], dir);
    idx += dir.len;
    if (needs_sep) {
        buf[idx] = ':';
        idx += 1;
        std.mem.copyForwards(u8, buf[idx..][0..path_slice.len], path_slice);
        idx += path_slice.len;
    }
    buf[idx] = 0;

    const value_z: [:0]u8 = buf[0..idx :0];
    if (libc.setenv("PATH", value_z.ptr, 1) != 0) {
        log.warn("failed to set PATH for cadre command", .{});
    }
}

fn findExecutableInPath(name: []const u8) ?[:0]const u8 {
    const path_env = posix.getenv("PATH") orelse return null;
    const path_env_slice = std.mem.sliceTo(path_env, 0);
    var it = std.mem.splitScalar(u8, path_env_slice, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fmt.bufPrintZ(&tic_path_buf, "{s}/{s}", .{ dir, name }) catch |err| {
            log.warn("failed to format candidate path: {}", .{err});
            continue;
        };
        if (std.fs.cwd().statFile(candidate)) |_| {
            return candidate;
        } else |_| {}
    }
    return null;
}

pub const Shell = struct {
    pty: pty_mod.Pty,
    child_pid: std.c.pid_t,

    pub const SpawnError = error{
        ForkFailed,
        ExecFailed,
    } || pty_mod.Pty.Error;

    const name_session: [:0]const u8 = "CADRE_SESSION_ID\x00";
    const name_sock: [:0]const u8 = "CADRE_NOTIFY_SOCK\x00";
    const name_resume: [:0]const u8 = "CADRE_RESUME_CMD\x00";

    pub fn spawn(shell_path: []const u8, size: pty_mod.winsize, session_id: [:0]const u8, notify_sock: [:0]const u8, working_dir: ?[:0]const u8, resume_cmd: ?[]const u8, persist: ?tmux.Persist) SpawnError!Shell {
        // Ensure terminfo is set up (parent process, before fork)
        ensureTerminfoSetup();
        ensureCadreCommandSetup();
        if (isShellNamed(shell_path, "zsh")) {
            ensureCadreZshProfileSetup();
        }

        const pty_instance = try pty_mod.Pty.open(size);
        errdefer {
            var pty_copy = pty_instance;
            pty_copy.deinit();
        }

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // Match ghostty's order: dup2 first so stdin/stdout/stderr point at the
            // slave before childPreExec rebinds the controlling terminal and closes
            // the original master/slave fds.
            posix.dup2(pty_instance.slave, posix.STDIN_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDOUT_FILENO) catch std.c._exit(1);
            posix.dup2(pty_instance.slave, posix.STDERR_FILENO) catch std.c._exit(1);

            if (libc.setenv(name_session.ptr, session_id, 1) != 0) {
                std.c._exit(1);
            }
            if (libc.setenv(name_sock.ptr, notify_sock, 1) != 0) {
                std.c._exit(1);
            }
            if (resume_cmd) |rc| {
                // Null-terminate on the stack (no sentinel heap alloc) for setenv.
                var rbuf: [512]u8 = undefined;
                if (rc.len < rbuf.len) {
                    @memcpy(rbuf[0..rc.len], rc);
                    rbuf[rc.len] = 0;
                    const rc_z = rbuf[0..rc.len :0];
                    if (libc.setenv(name_resume.ptr, rc_z, 1) != 0) {
                        std.c._exit(1);
                    }
                }
            }

            // Finder launches provide a nearly empty environment; seed common
            // terminal vars so shells behave like real terminals (color, terminfo).
            // Use xterm-ghostty if terminfo is available for kitty keyboard protocol support.
            if (terminfo_available) {
                if (terminfo_dir_z) |dir| {
                    // We installed to cache, set TERMINFO to point there
                    setEnv("TERMINFO", dir);
                }
                setEnv("TERM", cadre_term);
            } else {
                setEnv("TERM", fallback_term);
            }
            setDefaultEnv("COLORTERM", default_colorterm);
            setDefaultEnv("LANG", default_lang);
            setDefaultEnv("TERM_PROGRAM", default_term_program);
            // CLIs that feature-detect OSC 8 hyperlink support (Claude Code,
            // anything using the supports-hyperlinks library) don't recognize
            // TERM_PROGRAM=Cadre and fall back to plain colored text, so
            // Cmd+Click has no URL to open. Cadre + ghostty-vt fully
            // support OSC 8, so force emission on. Default-only: a user
            // exporting FORCE_HYPERLINK=0 wins.
            setDefaultEnv("FORCE_HYPERLINK", default_force_hyperlink);
            configureZshPathInjection(shell_path);
            ensureCadreCommandPath();

            // Change to specified directory or home directory before spawning shell.
            // Try working_dir first, fall back to HOME.
            const target_dir = working_dir orelse posix.getenv("HOME");
            if (target_dir) |dir| {
                // zwanzig-disable: empty-catch-engine
                // Errors are intentionally ignored: we're in a forked child process where
                // logging is impractical, and chdir failure is non-fatal (shell starts in
                // the parent's cwd instead).
                posix.chdir(dir) catch {};
            }

            pty_instance.childPreExec() catch std.c._exit(1);

            const shell_path_z = @as([*:0]const u8, @ptrCast(shell_path.ptr));
            const login_flag = "-l\x00";

            if (persist) |p| {
                // Wrap the shell in a detached tmux session so it survives an
                // Cadre restart. `new-session -A` creates the session on
                // first launch and reattaches to the live one afterward, so the
                // running agent reappears with full in-memory context instead of
                // being resumed from a stale transcript. The `-e` vars only take
                // effect on fresh creation (ignored on reattach), which is
                // exactly when the resume-command fallback should run.
                //
                // Buffers are filled here in the (post-fork) child's own stack;
                // bufPrintZ does not allocate, so it is safe before execve.
                var cols_buf: [8]u8 = undefined;
                var rows_buf: [8]u8 = undefined;
                var sess_buf: [64]u8 = undefined;
                var sock_buf: [192]u8 = undefined;
                var resume_buf: [560]u8 = undefined;

                const cols_z = std.fmt.bufPrintZ(&cols_buf, "{d}", .{size.ws_col}) catch std.c._exit(1);
                const rows_z = std.fmt.bufPrintZ(&rows_buf, "{d}", .{size.ws_row}) catch std.c._exit(1);
                const sess_z = std.fmt.bufPrintZ(&sess_buf, "CADRE_SESSION_ID={s}", .{session_id}) catch std.c._exit(1);
                const sock_z = std.fmt.bufPrintZ(&sock_buf, "CADRE_NOTIFY_SOCK={s}", .{notify_sock}) catch std.c._exit(1);

                var argv: [26]?[*:0]const u8 = undefined;
                var n: usize = 0;
                argv[n] = p.tmux_path.ptr;
                n += 1;
                argv[n] = "-S";
                n += 1;
                argv[n] = p.socket_path.ptr;
                n += 1;
                argv[n] = "-f";
                n += 1;
                argv[n] = p.conf_path.ptr;
                n += 1;
                argv[n] = "new-session";
                n += 1;
                argv[n] = "-A";
                n += 1;
                argv[n] = "-s";
                n += 1;
                argv[n] = p.session_name.ptr;
                n += 1;
                argv[n] = "-x";
                n += 1;
                argv[n] = cols_z.ptr;
                n += 1;
                argv[n] = "-y";
                n += 1;
                argv[n] = rows_z.ptr;
                n += 1;
                argv[n] = "-e";
                n += 1;
                argv[n] = sess_z.ptr;
                n += 1;
                argv[n] = "-e";
                n += 1;
                argv[n] = sock_z.ptr;
                n += 1;
                // Servers started before FORCE_HYPERLINK existed lack it in
                // their global env; the per-session override covers new
                // sessions on those servers (fresh servers also inherit it
                // from the client env via setDefaultEnv above).
                argv[n] = "-e";
                n += 1;
                argv[n] = "FORCE_HYPERLINK=1";
                n += 1;
                // ALWAYS override CADRE_RESUME_CMD per session — empty when
                // no resume is intended. The tmux SERVER captures the env of
                // whichever client started it (which can include a resume
                // command via the setenv above), and sessions inherit server
                // globals they don't override — a new terminal would then run a
                // stale `claude --resume` for a conversation it never owned.
                argv[n] = "-e";
                n += 1;
                argv[n] = blk: {
                    if (resume_cmd) |rc| {
                        if (std.fmt.bufPrintZ(&resume_buf, "CADRE_RESUME_CMD={s}", .{rc})) |rz| {
                            break :blk rz.ptr;
                        } else |_| {}
                    }
                    break :blk "CADRE_RESUME_CMD=";
                };
                n += 1;
                argv[n] = "--";
                n += 1;
                argv[n] = shell_path_z;
                n += 1;
                argv[n] = login_flag;
                n += 1;
                argv[n] = null;

                _ = std.c.execve(p.tmux_path.ptr, @ptrCast(&argv), @ptrCast(std.c.environ));
                std.c._exit(1);
            }

            const argv = [_:null]?[*:0]const u8{ shell_path_z, login_flag, null };

            _ = std.c.execve(shell_path_z, &argv, @ptrCast(std.c.environ));
            std.c._exit(1);
        }

        if (!warned_env_defaults) {
            warned_env_defaults = true;
            if (posix.getenv("TERM") == null or posix.getenv("LANG") == null) {
                log.warn("TERM/LANG missing in parent env; child shells will receive defaults ({s}, {s})", .{ fallback_term, default_lang });
            }
        }

        posix.close(pty_instance.slave);

        return .{
            .pty = pty_instance,
            .child_pid = pid,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.pty.deinit();
        self.* = undefined;
    }

    pub fn read(self: *Shell, buffer: []u8) !usize {
        return posix.read(self.pty.master, buffer);
    }

    pub fn write(self: *Shell, data: []const u8) !usize {
        var written: usize = 0;
        var waited_ns: u64 = 0;
        const max_wait_ns: u64 = 50 * std.time.ns_per_ms;
        const backoff_ns: u64 = 1 * std.time.ns_per_ms;

        while (written < data.len) {
            const n = posix.write(self.pty.master, data[written..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // PTY is full; retry for a short bounded window so pastes
                    // complete, but avoid indefinitely stalling the UI thread.
                    if (waited_ns >= max_wait_ns) {
                        return if (written > 0) written else err;
                    }
                    std.Thread.sleep(backoff_ns);
                    waited_ns += backoff_ns;
                    continue;
                },
                else => return err,
            };
            if (n == 0) return error.WouldBlock;
            written += n;
        }

        return data.len;
    }

    pub fn wait(self: *Shell) !void {
        _ = std.c.waitpid(self.child_pid, null, 0);
    }
};

test "pathContainsEntry" {
    try std.testing.expect(pathContainsEntry("/usr/bin:/opt/bin", "/usr/bin"));
    try std.testing.expect(pathContainsEntry("/usr/bin:/opt/bin", "/opt/bin"));
    try std.testing.expect(!pathContainsEntry("/usr/bin:/opt/bin", "/bin"));
    try std.testing.expect(pathContainsEntry("/usr/bin", "/usr/bin"));
    try std.testing.expect(!pathContainsEntry("", "/usr/bin"));
}

// Regression test for issue #318: the bundled terminfo source must compile to
// the legacy short-int format (magic 0x011a) so that macOS system tools linked
// against the old libncurses 5.4 in dyld_shared_cache (less, man, etc.) can read
// it. If `use=xterm-256color` inherits `pairs#0x10000` from a modern ncurses
// terminfo DB without an override, tic emits the extended-numbers format (magic
// 0x021e), which those tools cannot parse and they print "WARNING: terminal is
// not fully functional".
test "bundled terminfo compiles to legacy short-int format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const src_path = try std.fs.path.join(allocator, &.{ tmp_path, "xterm-ghostty.terminfo" });
    defer allocator.free(src_path);

    {
        const src_file = try std.fs.createFileAbsolute(src_path, .{});
        defer src_file.close();
        try src_file.writeAll(cadre_terminfo_src);
    }

    const tic_path = findExecutableInPath("tic") orelse return error.SkipZigTest;

    var child = std.process.Child.init(&.{ tic_path, "-x", "-o", tmp_path, src_path }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);

    // tic stores the compiled entry in either `78/xterm-ghostty` (hashed,
    // modern ncurses default) or `x/xterm-ghostty` (legacy single-char), so try
    // both locations.
    const candidates = [_][]const u8{ "78/xterm-ghostty", "x/xterm-ghostty" };
    var magic: [2]u8 = undefined;
    var read_ok = false;
    for (candidates) |rel| {
        const full = try std.fs.path.join(allocator, &.{ tmp_path, rel });
        defer allocator.free(full);
        const file = std.fs.openFileAbsolute(full, .{}) catch continue;
        defer file.close();
        const n = try file.readAll(&magic);
        if (n == magic.len) {
            read_ok = true;
            break;
        }
    }
    try testing.expect(read_ok);

    // Legacy short-int magic is 0x011a (little-endian on disk: 0x1a, 0x01).
    // Extended-numbers magic 0x021e (0x1e, 0x02) means the entry inherited a
    // numeric capability that overflows signed 16-bit and is unreadable by
    // macOS's bundled libncurses 5.4.
    try testing.expectEqual(@as(u8, 0x1a), magic[0]);
    try testing.expectEqual(@as(u8, 0x01), magic[1]);
}
