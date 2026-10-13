#!/usr/bin/env bash
# Rebuild Architect from the CURRENT worktree (committed + uncommitted changes)
# and relaunch it, so you never again restart a stale binary.
#
# Flow: build (debug) -> package an .app bundle -> quit the running Architect ->
# swap the fresh bundle into /Applications -> relaunch via `open`.
#
# The quit+relaunch runs in a detached subprocess (nohup/disown) so it survives
# even if this script is itself running inside the Architect being replaced.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" || ! -f "$ROOT/scripts/bundle-macos.sh" ]]; then
    echo "error: run this from inside the Architect repo (no scripts/bundle-macos.sh found)" >&2
    exit 1
fi
cd "$ROOT"

# Find the running daily app's PID. Use ps, NOT `pgrep -x architect`: a
# Finder/`open`-launched .app is not reliably matched by pgrep's exact-name
# match (its comm is the full bundle exe path), so pgrep silently returns
# nothing and the live-agent guard below would no-op while the reload still
# quits the app and kills its agents. ps lists it reliably.
APP_EXE="/Applications/Cadre.app/Contents/MacOS/architect"
# Pre-rename bundle path: still matched so the first reload after the rename
# waits for (and guards) the old app instead of racing it for tmux sessions.
LEGACY_APP_EXE="/Applications/Architect.app/Contents/MacOS/architect"
# `|| true`: awk's early `exit` can SIGPIPE ps mid-write (load-dependent), and
# under set -e -o pipefail that 141 silently kills the whole script.
daily_pid() { ps -Axo pid=,comm= | awk -v exe="$APP_EXE" -v legacy="$LEGACY_APP_EXE" '$2 == exe || $2 == legacy { print $1; exit }' || true; }

# Returns 0 if any descendant of pid $1 looks like a running agent CLI
# (claude/codex/gemini) — i.e. restarting the app would kill a live agent.
#
# Reads pgrep output with `while IFS= read -r` (one pid per line) instead of
# `for k in $kids`: the latter relies on word-splitting `$kids` on the ambient
# IFS, and if IFS lacks a newline (seen in this shell), a multi-child pid list
# collapses into a single bogus "p1\np2" token, `ps -p` on it fails, and the
# walk silently misses every agent. The read loop is IFS-independent.
reload_has_live_agents() {
    local pid="$1" k args
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        args="$(ps -p "$k" -o args= 2>/dev/null || true)"
        # Skip tmux clients: their argv embeds the pane's ARCHITECT_RESUME_CMD
        # ("claude --resume ...") and false-positives this guard. They are never
        # agents themselves, and tmux-backed agents live under the tmux SERVER
        # (not our tree) and survive a reload by design — reattach re-adopts
        # them. This guard only needs to protect direct (non-tmux) shells.
        case "$args" in
            *tmux*) continue ;;
            *claude*|*codex*|*gemini*) return 0 ;;
        esac
        reload_has_live_agents "$k" && return 0
    done < <(pgrep -P "$pid" 2>/dev/null)
    return 1
}

# --- Ensure a working build toolchain + SDK ---
# Preferred path: a Nix dev shell provides zig, a linkable SDK, and SDL3. If
# zig is not on PATH but nix is, re-enter the flake dev shell and re-run there.
if ! command -v zig >/dev/null 2>&1; then
    if command -v nix >/dev/null 2>&1; then
        exec nix develop "$ROOT" -c "$0" "$@"
    fi
    echo "error: 'zig' is not on PATH and 'nix' is unavailable." >&2
    echo "       Install zig (or symlink it onto PATH), or run from your Nix dev shell." >&2
    exit 1
fi

# Native (Homebrew SDL3 + 15.4 SDK) build setup, shared with dev-instance.sh.
# shellcheck source=scripts/dev-build-env.sh
. "$ROOT/scripts/dev-build-env.sh"

# Reload guard: this restarts your DAILY /Applications app, which kills its
# agents. A bridged Claude session can then resume from a stale local transcript
# (recent context appears lost). Refuse when agents are live. To test changes
# WITHOUT touching the daily app, use scripts/dev-instance.sh (isolated).
if [ -z "${DEV_RELOAD_FORCE:-}" ] && [ -z "${DEV_RELOAD_BUILD_ONLY:-}" ]; then
    arch_pid="$(daily_pid)"
    if [ -n "$arch_pid" ] && reload_has_live_agents "$arch_pid"; then
        echo "REFUSING: the running Architect has live agent sessions (claude/codex/gemini)." >&2
        echo "Restarting it kills them, and a bridged resume can come back stale (lost context)." >&2
        echo "  - Safe alternative: scripts/dev-instance.sh  (isolated dev instance, leaves this app alone)" >&2
        echo "  - Reload anyway, accepting the risk:  DEV_RELOAD_FORCE=1 $0 $*" >&2
        exit 1
    fi
fi

# Default to an optimized ReleaseFast build — this replaces your daily-driver
# /Applications app, so it must not be a slow Debug build. Pass --debug (or set
# DEV_RELOAD_DEBUG=1) only when you specifically need debug assertions/symbols.
build_debug=false
for arg in "$@"; do
    [ "$arg" = "--debug" ] && build_debug=true
done
[ -n "${DEV_RELOAD_DEBUG:-}" ] && build_debug=true

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [ "$build_debug" = true ]; then
    echo "==> Building Architect (Debug) from '$branch' + local changes..."
    zig build
else
    echo "==> Building Architect (ReleaseFast) from '$branch' + local changes..."
    zig build -Doptimize=ReleaseFast
fi

# Build-only mode: verify the build without touching the running app.
if [ -n "${DEV_RELOAD_BUILD_ONLY:-}" ]; then
    echo "==> DEV_RELOAD_BUILD_ONLY set: built successfully, leaving the running app untouched."
    exit 0
fi

echo "==> Packaging app bundle..."
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
if [ "$build_debug" = true ]; then
    ./scripts/bundle-macos.sh zig-out/bin/architect "$staging" zig-out/bin/architect-mcp --debug
else
    ./scripts/bundle-macos.sh zig-out/bin/architect "$staging" zig-out/bin/architect-mcp
fi

# Hand the swap+relaunch to a detached process. It outlives this shell, so the
# new Architect comes up even if quitting the old one tears down our terminal.
echo "==> Quitting Architect (waiting for agents to shut down + flush) and relaunching..."
old_pid="$(daily_pid)"
# Variables below are for the inner shell, not this one (intentional single quotes).
# shellcheck disable=SC2016
nohup bash -c '
    set -e
    staging="$1"
    old_pid="$2"
    # Quit gracefully, then block until the old process exits. This matters for
    # agent resume: on quit, Architect Ctrl+Cs each running agent so Claude
    # flushes its session to disk before exiting. Force-killing instead kills the
    # agents mid-turn, so the next `claude --resume` reloads a rewound transcript.
    # caffeinate -w waits on the process-exit event (no polling, no re-sending the
    # quit). A watchdog force-kills ONLY if the teardown truly hangs (~5 min),
    # which loses agent state.
    osascript -e "quit app \"Cadre\"" 2>/dev/null || true
    # Legacy bundle name (pre-rename); quit + remove it once so the swap is clean.
    osascript -e "quit app \"Architect\"" 2>/dev/null || true
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        ( sleep 300; kill -TERM "$old_pid" 2>/dev/null; sleep 2; kill -KILL "$old_pid" 2>/dev/null ) &
        watchdog=$!
        caffeinate -w "$old_pid" 2>/dev/null || true
        kill "$watchdog" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
    fi
    rm -rf "/Applications/Cadre.app" "/Applications/Architect.app"
    mv "$staging/Cadre.app" "/Applications/Cadre.app"
    rmdir "$staging" 2>/dev/null || true
    open "/Applications/Cadre.app"
' _ "$staging" "$old_pid" >/dev/null 2>&1 &
disown

# The detached job owns the staging dir now; do not let our EXIT trap delete it.
trap - EXIT

echo "==> Done. Architect will close and reopen on the fresh build."
