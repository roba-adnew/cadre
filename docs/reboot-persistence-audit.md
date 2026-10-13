# Reboot Persistence Parity Audit

**Date:** 2026-07-27
**Question:** Are terminals preserved across a **full device restart** (OS reboot),
to the same observable state as an Cadre **app-restart**?
**Scope:** design review of the reboot *restore* path (ADR-015 tmux persistence),
plus the targeted fixes it surfaced.

## The physical constraint (stated first)

A reboot kills **every** process, including the detached tmux server. So the
**live in-memory agent context** — the thing an app-restart preserves by
reattaching to a surviving tmux session — **cannot** survive a reboot. The
achievable parity is:

> same set of terminals, same grid slots, same cwd, each agent **resumed from its
> transcript** via `claude --resume <id>`.

The audit's real job is to verify even *that* holds, and fix where it doesn't.

## Verdict

**The restore *machinery* is sound. The gap was resume-*id availability*.**

Nothing in the reboot restore/reattach/reaper path drops or misattributes a
terminal, and the historical agent-killer (the graveyard reaper) is provably
**inert** on reboot: every own session is freshly created and *attached* before
the reaper runs, and no pre-reboot detached fossils survive a power cycle. Grid
layout, slots, cwd, `persist_index` reclaim, fresh session creation, per-session
`--resume` delivery, and duplicate-id dedup all behave correctly.

What actually breaks parity is whether the agent's resume `id` is **already on
disk** when the power cuts — a reboot gives no chance to scrape it at shutdown.

## What each restart path preserves / loses

| Observable | App-restart (tmux alive) | Full reboot (tmux dead) |
|---|---|---|
| Live in-memory agent context | Preserved (reattach) | **Impossible** (process killed) |
| Terminal set + grid slots | Restored | Restored (identical code path) |
| cwd (macOS) | Restored | Restored |
| Agent conversation | Live | `--resume <id>` **iff id on disk** |
| Attention border | Not restored (phase-1 gap) | Not restored (same) |
| Scrollback above screen | Not repainted (phase-1 gap) | Not repainted (same) |

## Findings (ranked)

1. **[Critical — fixed] Resume id was only reliably captured if a hook was
   manually installed.** The id reaches `persistence.toml` live via Claude's
   `SessionStart` hook (`cadre agent-session` → notify socket →
   `.agent_session` handler → per-frame save). That hook was installed **only**
   by the user running `cadre hook claude` by hand; nothing auto-installed
   it. Without it, the id was captured only at graceful quit — which a reboot
   skips — so every terminal returned as a bare shell in the right cwd with **no
   conversation**. This is the difference between "looks preserved" and "is
   preserved."
2. **[Critical for those users — not fixed here] Codex/Gemini have no live
   id-capture hook.** The socket `agent` field is hard-coded `"claude"` and no
   `SessionStart`-equivalent is installed for them, so their id exists only via
   the quit-scrape → a reboot always loses it. Deferred (larger surface; matters
   only if you use Codex/Gemini).
3. **[Low — fixed] Intra-frame save lag.** A freshly-captured id set the dirty
   flag *after* that frame's save, so it landed one active frame later (~ms). A
   reboot in that sliver lost only the newest id.
4. **[Low / expected — not fixed] Non-macOS restores nothing; a corrupt
   `persist_index` collision keeps the slot's own index.** Documented / requires
   a hand-edited file. Not reboot-specific.

## What was fixed (this change)

- **Auto-install Claude's hooks at startup** (`shell.ensureClaudeHookInstalled`,
  called before the restore spawns so this run's agents get the hook too). It
  runs the idempotent `cadre hook claude`; best-effort — on any failure it
  warns and the launch continues. The installer was also hardened to **create a
  fresh `~/.claude/settings.json` when none exists** (previously it failed) while
  still **refusing to clobber a malformed** one. Verified: fresh-machine create,
  valid-file merge + backup, malformed-file preserved, idempotent no-dup.
- **Same-frame flush of a newly-captured id** — when a `SessionStart` hook
  delivers an id mid-frame, the loop re-syncs terminal entries and flushes
  immediately instead of a frame later, closing the reboot-loss window.

## What remains (follow-ups)

- Codex/Gemini live id capture (un-hardcode `agent`, add a session-id hook).
- Cross-platform cwd tracking (unlocks non-macOS restore).
- Attention border + scrollback restoration on reattach/reboot (phase-1 gaps).
- Defensive `persist_index` de-collision at load (corrupt/hand-edited files).

## Reboot-resume checklist (Claude, macOS)

1. `persistence.toml` holds the terminal's cwd, `persist_index`, and
   `agent_session_id` (captured live by the auto-installed SessionStart hook).
2. On next boot, restore replays entries → `claimPersistIndex` → fresh tmux
   session `cadre-<epoch>-<persist_index>` in the saved cwd.
3. `-e CADRE_RESUME_CMD` fires `claude --resume <id>` once (dedup: first
   entry wins), restoring the conversation from its transcript.
