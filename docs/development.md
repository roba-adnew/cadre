# Development

This document covers local setup, build/test commands, and release steps.

## Prerequisites

- Nix with flakes enabled
- macOS: Xcode Command Line Tools if you plan to use Homebrew dependencies

## Setup

1. (Optional) Pre-fetch the ghostty dependency to speed up the first build:
   ```bash
   just setup
   ```
   `just setup` caches the `ghostty` source tarball; the regular build will fetch it automatically if you skip this step.

2. Enter the development shell:
   ```bash
   nix develop
   ```

   Or, if using direnv:
   ```bash
   direnv allow
   ```

   On macOS hosts where the active `MacOSX.sdk` only exposes `arm64e` targets, Zig 0.15.2 can fail during native Darwin linking with errors such as `undefined symbol: __availability_version_check`. The upstream tracker for this regression is https://codeberg.org/ziglang/zig/issues/31756.

   The dev shell works around that by exposing `MacOSX15.4.sdk` through a fake `DEVELOPER_DIR` whose `usr/bin/xcrun` is a narrow shim for `xcrun --sdk macosx --show-sdk-path`. `build.zig` also resolves framework paths through `DEVELOPER_DIR` and `xcrun` before it falls back to hardcoded SDK locations, so the workaround does not need to force `SDKROOT`. Keeping the shim inside the fake developer tree means tools like `git` can still invoke `/usr/bin/xcrun` without tripping over the overridden `DEVELOPER_DIR`.

   Remove this workaround once Cadre no longer uses Zig 0.15.2, or once Zig handles the arm64e-only macOS SDK stubs correctly. If the active `MacOSX.sdk/usr/lib/libSystem.tbd` advertises `arm64-macos` again, the shell hook becomes a no-op.

3. Verify the environment:
   ```bash
   zig version  # Should show 0.15.2+ (compatible with ghostty-vt)
   just --list  # Show available commands
   ```

## Build and Run

Build the project:
```bash
just build
# or
zig build
```

Build optimized release:
```bash
zig build -Doptimize=ReleaseFast
```

Run the application:
```bash
just run
# or
zig build run
```

Reload the installed app with your in-progress changes:
```bash
just reload
# or
./scripts/dev-reload.sh
```
This rebuilds from the current worktree (committed + uncommitted changes), quits the
running Cadre, swaps the fresh build into `/Applications/Cadre.app`, and
relaunches it. Use it to avoid restarting a stale binary after editing source — relaunching
the installed app alone never picks up source changes. The Claude Code skill
`/reload-cadre` runs the same script.

The swap is done by a detached worker: the new bundle is staged as
`/Applications/Cadre.app.new` *before* the old app is quit, then renamed into place
and the old one removed. If the swap fails the old bundle is restored, so
`/Applications` is never left without a `Cadre.app` (an empty install also locks
every Cadre-spawned shell out of `~/Documents` via TCC attribution). The worker
logs every step to `~/Library/Logs/Cadre/reload.log`; read that first when a
reload does not come back.

**Reload guard.** `dev-reload.sh` refuses to run while the installed app has live
agent descendants (`claude`/`codex`/`gemini`), because restarting it kills those
agents mid-turn and a bridged `claude --resume` can come back from a stale (rewound)
transcript. Override with `DEV_RELOAD_FORCE=1 ./scripts/dev-reload.sh` only when you
accept losing that agent state.

**Stage on next quit (no forced restart).** When you want the new build but
*don't* want to restart now (and kill live agents mid-turn), stage it instead:
```bash
./scripts/dev-stage.sh        # build + stage; applies on your next Cmd+Q + reopen
./scripts/dev-stage.sh --dry-run   # build + stage to a temp dir, no swap/arm (test)
```
This builds the worktree and **atomic-swaps** the fresh bundle into
`/Applications` immediately: it renames the old bundle aside and renames the new
one into place. The swap is safe even while Cadre is running because the
live process keeps its original (renamed-then-unlinked) inode — its mach-o pages
never change, so the kernel never SIGKILLs it on a signature page fault
(`cs_invalid_page` / "Killed: 9") the way an in-place *overwrite* would. You keep
working on the running copy; your next quit + reopen comes up on the new build.
The `pushstage` shell alias backs the current branch up to your fork, then runs
this script. Contrast with `dev-reload.sh`, which quits + relaunches immediately.

**Isolated dev instance (preferred while agents are running).** To test source
changes without touching the daily app at all:
```bash
./scripts/dev-instance.sh
```
This builds the current worktree and launches a separate instance with its own
config/persistence directory (`CADRE_CONFIG_DIR`, default `~/.config/cadre-dev`),
so it never resumes, reads, or clobbers the daily app's agent sessions. Point it at a
named scratch dir with `CADRE_DEV_CONFIG_DIR=/path ./scripts/dev-instance.sh`.
The shared native build environment (Homebrew SDL3 + macOS 15.4 SDK workaround) lives
in `scripts/dev-build-env.sh`, sourced by both scripts.

## Migrating a pre-rename install

The project was renamed from `architect` to `cadre` (binary, bundle, config and log dirs, tmux session prefix `cadre-<epoch>-<n>`, tmux/notify/control socket names, `CADRE_*` env vars). `scripts/migrate-to-cadre.sh` moves `~/.config/architect` and `~/Library/Logs/Architect`, renames `architect-*` tmux sessions in place and symlinks the new tmux socket path to the old server so live agents reattach. Run it with the app quit; it is idempotent. Compatibility shims kept for panes spawned before the rename: `cadre notify`/`agent-session` read `ARCHITECT_SESSION_ID`/`ARCHITECT_NOTIFY_SOCK` as fallbacks, the app symlinks the old notify socket path to the live one at startup, and `cadre hook claude` rewrites `architect ...` hook commands in `~/.claude/settings.json`.

## Persistent agent sessions

tmux-backed persistence is on by default (experimental) — it engages whenever
`tmux` is on `PATH`, letting agents survive an Cadre restart and reattach live
instead of being resumed from a stale transcript. If `tmux` isn't installed,
Cadre falls back to a direct shell. See `docs/configuration.md` and ADR-015 in
`docs/ARCHITECTURE.md`.

**Try it:** run an agent in a dev instance (`./scripts/dev-instance.sh`), quit,
relaunch with the same command — the agent reappears mid-conversation. Inspect the
tmux state with
`tmux -S "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cadre-tmux.sock" ls`.

## Dependencies and Tooling

- **ghostty-vt** is fetched as a pinned tarball via the Zig package manager (`build.zig.zon`).
- **SDL3** and **SDL3_ttf** are provided by Nix. SDL3 is pinned to 3.4.10 via `overlays/sdl3-3-4-10.nix` with binaries cached in the public `forketyfork` Cachix to avoid rebuilds.

## Tests and Formatting

Run tests:
```bash
just test
# or
zig build test
```

Check formatting and script linting:
```bash
just lint
# or
zig fmt --check src/
shellcheck scripts/*.sh scripts/verify-setup.sh
ruff check scripts/*.py
```

Format code:
```bash
zig fmt src/
```

## End-to-end UI tests

`zig build test` covers logic but not real UI behavior (focus, view-mode
transitions, clicks) — the area that has caused the most regressions. The E2E
harness in `scripts/e2e/` fills that gap: with `CADRE_TEST_MODE=1` the app
writes a per-frame JSON state snapshot (`src/app/test_probe.zig`, a no-op in
production), and a Python harness launches an isolated instance, injects real
keys/clicks, and asserts on that state.

```bash
zig build && python3 scripts/e2e/test_ui.py
```

Each test launches a real window and drives it with OS input, so it briefly takes
over the screen (macOS GUI session required; not yet headless). See
`scripts/e2e/README.md` for how to add scenarios and the roadmap to a
socket-driven headless version.

## Release Process

macOS release binaries are automatically built for both ARM64 (Apple Silicon) and x86_64 (Intel) architectures via GitHub Actions when a version tag is pushed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow packages ad-hoc-signed app bundles with local `codesign --sign -`. It does not import macOS signing certificates, does not produce Developer ID-signed artifacts, and does not notarize the app. Release downloads therefore still require clearing the quarantine attribute after extraction, as described in the README installation instructions. You can also run the Release workflow manually with `workflow_dispatch` to validate the packaging flow before pushing a real release tag.

Each release includes:
- `cadre-macos-arm64.tar.gz` - Apple Silicon
- `cadre-macos-x86_64.tar.gz` - Intel

Each archive contains `Cadre.app` with both `Contents/MacOS/cadre` and the stdio MCP helper `Contents/MacOS/cadre-mcp`.
