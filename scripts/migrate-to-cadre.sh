#!/usr/bin/env bash
# One-time migration of on-disk state from the old app name (architect) to cadre.
# Run with the app QUIT. Idempotent: every step skips when already migrated.
#
# What moves:
#   ~/.config/architect        -> ~/.config/cadre         (config + persistence)
#   ~/Library/Logs/Architect   -> ~/Library/Logs/Cadre
#   tmux sessions architect-*  -> cadre-*  (renamed on the old server, which is
#                                 then reachable at the new socket path via a
#                                 symlink; tmux unlinks the path before binding,
#                                 so a fresh server later replaces the symlink)
#   ~/.claude/settings.json hook commands are rewritten by `cadre hook claude`
#   on the next app launch, so nothing to do here.
set -euo pipefail

cfg_old="$HOME/.config/architect"; cfg_new="$HOME/.config/cadre"
if [ -d "$cfg_old" ] && [ ! -e "$cfg_new" ]; then
    mv "$cfg_old" "$cfg_new" && echo "moved $cfg_old -> $cfg_new"
fi

log_old="$HOME/Library/Logs/Architect"; log_new="$HOME/Library/Logs/Cadre"
if [ -d "$log_old" ] && [ ! -e "$log_new" ]; then
    mv "$log_old" "$log_new" && echo "moved $log_old -> $log_new"
fi

dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"; dir="${dir%/}"
sock_old="$dir/architect-tmux.sock"; sock_new="$dir/cadre-tmux.sock"
if command -v tmux >/dev/null && [ -S "$sock_old" ] && tmux -S "$sock_old" ls >/dev/null 2>&1; then
    tmux -S "$sock_old" ls -F '#S' | while IFS= read -r name; do
        case "$name" in
            architect-*) tmux -S "$sock_old" rename-session -t "$name" "cadre-${name#architect-}" && echo "renamed tmux session $name -> cadre-${name#architect-}" ;;
        esac
    done
    if [ ! -e "$sock_new" ]; then
        ln -s "$sock_old" "$sock_new" && echo "linked $sock_new -> $sock_old"
    fi
fi
echo "migration complete"
