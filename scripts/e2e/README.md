# End-to-end UI harness

Automated tests for the things `zig build test` can't see: real UI behavior —
focus, view-mode transitions, clicks, keys. This is where the bugs kept hiding
(Esc-in-grid, click-to-focus), so this is where we guard against regressions.

## Run

```bash
zig build                          # build the binary the harness launches
python3 scripts/e2e/test_ui.py     # run all scenarios
python3 scripts/e2e/test_ui.py test_grid_click_moves_focus   # run one
```

No dependencies beyond Python 3 and macOS. Each test launches a real, isolated
window and drives it with OS input, so it **briefly takes over the screen** —
run it when you're not mid-task. Exit code is non-zero if any test fails.

## How it works

Two halves:

- **Observe.** With `CADRE_TEST_MODE=1`, the app writes a JSON snapshot of its
  UI state (view mode, focused pane, grid size, per-pane spawned/dead/cwd/status)
  to `CADRE_STATE_FILE` every frame, atomically (`src/app/test_probe.zig`).
  Tests read that file — precise truth, no screen-scraping. It's a no-op in
  production (the env vars are unset), so it costs nothing there.
- **Drive.** The harness (`harness.py`) launches an isolated instance, brings its
  window frontmost, and injects input: keys via System Events (`osascript`),
  mouse clicks/scrolls via CoreGraphics (`ctypes`, no third-party deps).

A test is just: do something, then assert on the state.

```python
from harness import Cadre, CMD

def test_cmd_esc_enters_grid():
    with Cadre() as app:
        app.wait_for(lambda s: any(x["spawned"] for x in s["sessions"]), what="first pane")
        app.act_until(lambda: app.key("n", CMD),                       # Cmd+N: add a pane
                      lambda s: sum(x["spawned"] for x in s["sessions"]) >= 2, what="2 panes")
        app.act_until(lambda: app.key("esc", CMD),                     # Cmd+Esc: collapse to grid
                      lambda s: s["mode"] == "Grid", what="grid mode")
```

`Cadre` gives you: `state()`, `opened_urls()`, `wait_for(pred, ...)`,
`act_until(action, pred, ...)`, `key(name, flags)`, `type_text(s)`, `enter()`,
`click(x, y)`, `cmd_click(x, y)`, `scroll(dy)`, `grid_cell_center(slot)`,
`window_rect()`. Add a test by writing a function and listing it in `TESTS` in
`test_ui.py`.

Prefer **`act_until`** for anything that changes state: it does the action, polls
for the expected result, and re-sends it (re-focusing) if a keystroke or click was
dropped — so real-OS-input races don't make the suite flaky. `wait_for` is for
waiting on something with no action to repeat.

Covered today: startup, add/remove terminals (Cmd+N / Cmd+W), grid↔full
(Cmd+Esc / Cmd+Return), click-to-focus in grid, and Cmd+Click opening a link.
Link opens are recorded to `CADRE_OPENED_URLS_FILE` instead of launching a
browser (`recordOpenForTest` in `src/os/open.zig`), readable via `opened_urls()`.

## Limitations / roadmap

- **v1 drives real OS events**, so it needs a logged-in GUI session and steals
  focus — fine locally, not yet headless/CI. The follow-up is socket-based input
  injection (feed synthetic events through the existing control channel), which
  removes the OS coupling and the focus-stealing.
- The state snapshot currently covers focus/mode/session basics. Add fields to
  `test_probe.zig` (e.g. scroll offset, visible text) as new tests need them.
