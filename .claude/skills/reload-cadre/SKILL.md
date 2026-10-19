---
name: reload-cadre
description: Rebuild the Cadre app from the current worktree (committed + uncommitted local changes) and relaunch it, so the running app reflects in-progress code. Use when the user wants to see/test their Cadre changes in the actual app — e.g. "reload cadre", "rebuild and restart cadre", "run my changes", "relaunch with my edits", "I closed and reopened but don't see my changes". Also run it on your own, unasked, as soon as a code change the user will want to see in the app builds cleanly; the user should never have to say "reload for me".
---

# Reload Cadre

Goal: get the running Cadre to be the build of **this worktree's current code** (including uncommitted changes). Editing source and relaunching the *installed* app does nothing — the `.app` must be rebuilt. This skill does build → quit → relaunch in one step via `scripts/dev-reload.sh`.

## When to run it

Run it yourself after every change to Cadre's code that the user will check in the running app, once it builds, then tell them it reloaded. Don't wait to be asked: over two weeks the user typed "reload for me" 19 times. The exceptions are when the user said not to reload, or when the change can't be seen in the app (tests or docs only).

## Steps

1. Find the repo root and confirm we're in the Cadre repo:
   ```bash
   ROOT="$(git rev-parse --show-toplevel)" && test -f "$ROOT/scripts/dev-reload.sh" && echo "$ROOT"
   ```
   If that fails, tell the user to run the skill from inside the Cadre repo (or a worktree of it) and stop.

2. Run the reload from the repo root:
   ```bash
   bash "$ROOT/scripts/dev-reload.sh"
   ```
   This builds (debug), packages the `.app`, quits the running Cadre, swaps the fresh build into `/Applications`, and relaunches it. The relaunch is detached, so it completes on its own.

3. Report the outcome:
   - On success, tell the user Cadre will close and reopen on the fresh build, and remind them what changed (branch + the local edits being tested).
   - If the build fails (`zig build` error), surface the compiler error and offer to fix it. Do **not** leave them thinking it reloaded.

## If the toolchain isn't reachable from your shell

The build needs the Nix dev shell (`zig`). If `scripts/dev-reload.sh` exits with **"neither 'zig' nor 'nix' is on PATH"**, then this agent's shell can't reach the build toolchain (it lives in the user's login/direnv shell, not necessarily yours). In that case, do **not** keep retrying — tell the user to run it in their own session instead, where the toolchain is loaded:

```
!just reload
```

(or `!./scripts/dev-reload.sh`). The `!` prefix runs it in the user's interactive session, and the output comes back into the conversation.

## Notes

- Works in any Cadre worktree — it resolves the repo root from the current directory, so it reloads whichever branch/worktree you're in.
- Safe to run while Cadre is the frontmost app or in the background; the quit+relaunch is detached and survives even if it was launched from inside the Cadre being replaced.
- This replaces `/Applications/Cadre.app`, so Spotlight/Dock launches afterward also get the fresh build — no "which version am I running?" ambiguity.
