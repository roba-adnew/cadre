#!/usr/bin/env bash
# Launch an ISOLATED dev instance of Cadre from the current worktree, running
# ALONGSIDE the installed daily app WITHOUT touching it.
#
# It builds the current source and runs the bare binary with a separate config
# dir (CADRE_CONFIG_DIR), so it has its own persistence and will NOT resume,
# read, or clobber your daily app's agent sessions. This is the safe way to test
# changes: your real agents keep running, untouched.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" || ! -f "$ROOT/build.zig" ]]; then
    echo "error: run this from inside the Cadre repo (no build.zig found)" >&2
    exit 1
fi
cd "$ROOT"

# Toolchain: a Nix dev shell provides zig; otherwise build natively (Homebrew).
if ! command -v zig >/dev/null 2>&1; then
    if command -v nix >/dev/null 2>&1; then
        exec nix develop "$ROOT" -c "$0" "$@"
    fi
    echo "error: 'zig' is not on PATH and 'nix' is unavailable." >&2
    exit 1
fi
# shellcheck source=scripts/dev-build-env.sh
. "$ROOT/scripts/dev-build-env.sh"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo "==> Building dev Cadre (debug) from '$branch' + local changes..."
zig build

# Isolated config dir -> its own persistence -> never resumes the daily app's
# sessions. Override with CADRE_DEV_CONFIG_DIR if you want a named scratch.
dev_config="${CADRE_DEV_CONFIG_DIR:-$HOME/.config/cadre-dev}"
mkdir -p "$dev_config"

echo "==> Launching ISOLATED dev instance"
echo "    config dir: $dev_config  (separate from your daily ~/.config/cadre)"
echo "    It runs alongside your daily Cadre and will NOT touch its agents."
CADRE_CONFIG_DIR="$dev_config" nohup zig-out/bin/cadre >/tmp/cadre-dev.log 2>&1 &
disown
sleep 1
echo "==> Dev instance launched (logs: /tmp/cadre-dev.log)."
echo "    Quit it any time; your daily app and its agents are unaffected."
