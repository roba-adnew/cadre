"""E2E UI scenarios for Cadre.

Run:  python3 scripts/e2e/test_ui.py
Needs a built binary (`zig build`) and a logged-in macOS GUI session — each test
launches a real window and drives it with OS input, so it briefly takes focus.
"""

import sys
import time

from harness import Cadre, CMD


def _spawned(state):
    return sum(1 for s in state["sessions"] if s["spawned"])


def test_startup_writes_state():
    """The probe reports a sane initial state: session 0 spawned and focused."""
    with Cadre() as app:
        s = app.wait_for(lambda s: _spawned(s) >= 1, what="session 0 to spawn")
        assert s["focused_session"] == 0, s
        assert s["sessions"][0]["spawned"] and not s["sessions"][0]["dead"], s
        return f"mode={s['mode']} focused_session=0 spawned={_spawned(s)}"


def test_cmd_esc_enters_grid():
    """Cmd+N adds a pane; Cmd+Esc collapses to grid view."""
    with Cadre() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="initial pane")
        app.act_until(lambda: app.key("n", CMD), lambda s: _spawned(s) >= 2, what="second pane")
        s = app.act_until(lambda: app.key("esc", CMD), lambda s: s["mode"] == "Grid", what="grid mode")
        return f"panes={_spawned(s)} mode={s['mode']}"


def test_grid_click_moves_focus():
    """Single-clicking a grid pane moves keyboard focus to it (the bug we hit)."""
    with Cadre() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="initial pane")
        app.act_until(lambda: app.key("n", CMD), lambda s: _spawned(s) >= 2, what="2 panes")
        app.act_until(lambda: app.key("esc", CMD), lambda s: s["mode"] == "Grid", what="grid mode")

        # Grid opens focused on the new pane (1); click pane 0 then pane 1 so each
        # click is a real focus move, not a no-op.
        c0x, c0y = app.grid_cell_center(0)
        app.act_until(lambda: app.click(c0x, c0y), lambda s: s["focused_session"] == 0, what="click -> focus pane 0")
        c1x, c1y = app.grid_cell_center(1)
        app.act_until(lambda: app.click(c1x, c1y), lambda s: s["focused_session"] == 1, what="click -> focus pane 1")
        return "click moves grid focus (1 -> 0 -> 1)"


def test_cmd_w_removes_terminal():
    """Cmd+W closes a terminal; the spawned count drops and the grid compacts."""
    with Cadre() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="first pane")
        app.act_until(lambda: app.key("n", CMD), lambda s: _spawned(s) >= 2, what="second pane")
        s = app.act_until(lambda: app.key("w", CMD), lambda s: _spawned(s) == 1, what="one pane after Cmd+W")
        return f"panes={_spawned(s)} grid={s['grid_cols']}x{s['grid_rows']}"


def test_cmd_click_opens_link():
    """Cmd+Click on a URL in terminal output opens that URL (recorded in test mode)."""
    url = "https://example.com"
    with Cadre() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="terminal")
        # Fill the screen with the URL at column 0 so a click near the left edge
        # lands on it regardless of terminal width.
        app.type_text(f"yes {url} | head -120")
        app.enter()
        time.sleep(1.0)  # let the output render
        x, y, w, h = app.window_rect()
        app.act_until(
            lambda: app.cmd_click(x + w * 0.02, y + h * 0.5),
            lambda s: url in app.opened_urls(),
            timeout=8,
            what=f"{url} to be opened",
        )
        return f"opened {app.opened_urls()[-1]}"


def test_cmd_return_expands_to_full():
    """From grid, Cmd+Return expands the focused pane back to full view."""
    with Cadre() as app:
        app.wait_for(lambda s: _spawned(s) >= 1, what="initial pane")
        app.act_until(lambda: app.key("n", CMD), lambda s: _spawned(s) >= 2, what="2 panes")
        app.act_until(lambda: app.key("esc", CMD), lambda s: s["mode"] == "Grid", what="grid mode")
        s = app.act_until(lambda: app.key("return", CMD), lambda s: s["mode"] == "Full", what="full mode")
        return f"mode={s['mode']}"


TESTS = [
    test_startup_writes_state,
    test_cmd_esc_enters_grid,
    test_grid_click_moves_focus,
    test_cmd_return_expands_to_full,
    test_cmd_w_removes_terminal,
    test_cmd_click_opens_link,
]


def main():
    only = sys.argv[1:] if len(sys.argv) > 1 else None
    tests = [t for t in TESTS if not only or t.__name__ in only]
    passed, failed = 0, 0
    for t in tests:
        try:
            msg = t()
            print(f"PASS  {t.__name__}: {msg}")
            passed += 1
        except Exception as e:
            print(f"FAIL  {t.__name__}: {e}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
