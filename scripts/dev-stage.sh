#!/usr/bin/env bash
# Build Cadre from the CURRENT worktree and swap the fresh bundle into
# /Applications so it takes effect on your NEXT quit + reopen of the daily app —
# no forced restart, no killing live agents mid-turn.
#
# How the swap is safe while the app is running: we do NOT overwrite the bundle
# in place (that would change the running mach-o's on-disk pages and the kernel
# would SIGKILL it on a signature page fault — "Killed: 9" / cs_invalid_page).
# Instead we ATOMIC-RENAME: build into a staging dir on the same volume, rename
# the old bundle aside, rename the new one into place. The running process keeps
# its original (renamed-then-unlinked) inode, so its pages never change and it
# is never killed; the NEXT launch picks up the new bundle.
#
# (An earlier version deferred the swap to a quit-watcher, but that raced the
# relaunch and often failed to apply — the immediate atomic swap is reliable.)
#
# Usage:
#   scripts/dev-stage.sh            build + swap (applies on next reopen)
#   scripts/dev-stage.sh --dry-run  build + stage into a temp dir, no swap
#   scripts/dev-stage.sh --debug    build a Debug build instead of ReleaseFast
set -euo pipefail

dry_run=false
build_debug=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --debug) build_debug=true ;;
        *) echo "unknown flag: $arg" >&2; exit 1 ;;
    esac
done
[ -n "${DEV_STAGE_DEBUG:-}" ] && build_debug=true

# Locate the repo from THIS script's own path, not $PWD: pushstage invokes us by
# absolute path without cd-ing, so $PWD can be $HOME (or any other repo) and a
# git/CWD-based lookup would resolve to the wrong tree or nothing — the guard
# below would then misfire with a confusing "not in the repo" error.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$ROOT/scripts/bundle-macos.sh" ]; then
    echo "error: dev-stage.sh must live in <repo>/scripts (bundle-macos.sh not found beside it)" >&2
    exit 1
fi
cd "$ROOT"

# Toolchain: a Nix dev shell provides zig; otherwise the native (Homebrew) env.
if ! command -v zig >/dev/null 2>&1; then
    if command -v nix >/dev/null 2>&1; then
        exec nix develop "$ROOT" -c "$0" "$@"
    fi
    echo "error: 'zig' is not on PATH and 'nix' is unavailable." >&2
    exit 1
fi
# shellcheck source=scripts/dev-build-env.sh
. "$ROOT/scripts/dev-build-env.sh"

APP="/Applications/Cadre.app"
# Stage on the SAME volume as /Applications so the final swap is an atomic
# rename, not a slow cross-device copy that widens the window where the app path
# is missing. A dot-prefixed dir keeps it out of Finder/Launchpad.
STAGE_PARENT="/Applications/.cadre-staged"
if [ "$dry_run" = true ]; then
    STAGE_PARENT="$(mktemp -d)"
fi

if [ "$build_debug" = true ]; then
    echo "==> Building Cadre (Debug)..."
    zig build
else
    echo "==> Building Cadre (ReleaseFast)..."
    zig build -Doptimize=ReleaseFast
fi

echo "==> Packaging staged bundle..."
rm -rf "$STAGE_PARENT"
mkdir -p "$STAGE_PARENT"
./scripts/bundle-macos.sh zig-out/bin/cadre "$STAGE_PARENT" zig-out/bin/cadre-mcp >/dev/null
staged="$STAGE_PARENT/Cadre.app"
if [ ! -d "$staged" ]; then
    echo "error: bundling did not produce $staged" >&2
    exit 1
fi

if [ "$dry_run" = true ]; then
    echo "==> [dry-run] staged a valid bundle at: $staged"
    echo "    Would swap it into $APP on the next quit of the running app."
    echo "    Leaving it in place for inspection; remove with: rm -rf '$STAGE_PARENT'"
    exit 0
fi

# Apply immediately via an atomic rename. This is safe even while Cadre is
# running: the live process keeps its old (renamed-aside, then unlinked) inode,
# so the kernel never SIGKILLs it on a code-signature page fault, and the NEXT
# launch picks up the new bundle. Replaces an earlier swap-on-quit watcher that
# raced the relaunch and frequently failed to apply the build at all.
echo "==> Applying new build to $APP (atomic swap; the running app keeps its old copy)..."
rm -rf "$APP.prev"
mv "$APP" "$APP.prev"
mv "$staged" "$APP"
rm -rf "$APP.prev" "$STAGE_PARENT"
echo "==> Done. Your next Cmd+Q + reopen of Cadre comes up on the new build."
