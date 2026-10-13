"""End-to-end UI test harness for Cadre.

Launches an isolated instance in test mode (CADRE_TEST_MODE), drives it with
real OS input events (CoreGraphics, via ctypes — no third-party deps), and reads
the per-frame JSON state the app writes to CADRE_STATE_FILE. Tests assert on
that state: "press Cmd+Esc -> assert mode == Grid", etc.

v1 drives real OS events, so the app window must be frontmost while a test runs
(the harness focuses it). That makes it a local/dev tool, not headless-CI yet;
socket-based input injection is the follow-up that removes the OS coupling.
"""

import ctypes
import ctypes.util
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time

# --- CoreGraphics event injection (ctypes, no pyobjc) ---
_cg = ctypes.CDLL(
    ctypes.util.find_library("CoreGraphics")
    or "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
)


class _CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, _CGPoint, ctypes.c_uint32]
_cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
_cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_cg.CGEventCreateScrollWheelEvent.restype = ctypes.c_void_p
_cg.CGEventCreateScrollWheelEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32]
_cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
_cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
_cg.CFRelease.argtypes = [ctypes.c_void_p]

CMD = 0x100000  # kCGEventFlagMaskCommand
SHIFT = 0x20000  # kCGEventFlagMaskShift

# macOS virtual keycodes (US layout)
KEYCODES = {
    "esc": 53, "return": 36, "n": 45, "t": 17, "w": 13, "space": 49,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
}


def _post(ev):
    _cg.CGEventPost(0, ev)  # 0 = kCGHIDEventTap
    _cg.CFRelease(ev)


class Cadre:
    """A launched, test-mode Cadre instance you can drive and observe."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="arch-e2e-")
        self.state_file = os.path.join(self.dir, "state.json")
        cfg = os.path.join(self.dir, "cfg")
        os.makedirs(cfg)
        repo = subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
        binary = os.path.join(repo, "zig-out", "bin", "cadre")
        if not os.path.exists(binary):
            raise RuntimeError(f"cadre binary not found at {binary}; run `zig build` first")
        env = dict(os.environ)
        env["CADRE_TEST_MODE"] = "1"
        env["CADRE_STATE_FILE"] = self.state_file
        env["CADRE_CONFIG_DIR"] = cfg
        self.opened_file = os.path.join(self.dir, "opened.txt")
        env["CADRE_OPENED_URLS_FILE"] = self.opened_file
        self._log = open(os.path.join(self.dir, "stdout.log"), "w")
        self.proc = subprocess.Popen([binary], env=env, stdout=self._log, stderr=subprocess.STDOUT)
        self.wait_for(lambda s: s is not None, timeout=15, what="app to start and write state")
        self.focus()

    # --- observation ---
    def state(self):
        try:
            with open(self.state_file) as f:
                return json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def wait_for(self, pred, timeout=5.0, what=""):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise AssertionError(f"app exited (code {self.proc.returncode}) while waiting for {what}")
            last = self.state()
            try:
                if last is not None and pred(last):
                    return last
            except Exception:
                pass
            time.sleep(0.04)
        raise AssertionError(f"timed out after {timeout}s waiting for {what}; last state = {last}")

    def act_until(self, action, pred, timeout=8.0, what="", refocus=True):
        """Do `action`, then poll for `pred(state)`; if it doesn't take within a
        short window, re-focus and do it again. Rides out input/focus races so a
        dropped keystroke or click doesn't fail the test. Returns the state."""
        deadline = time.time() + timeout
        first = True
        while time.time() < deadline:
            if not first and refocus:
                self.focus()
            first = False
            action()
            sub = time.time() + 1.5
            while time.time() < sub:
                if self.proc.poll() is not None:
                    raise AssertionError(f"app exited while waiting for {what}")
                s = self.state()
                if s is not None:
                    try:
                        if pred(s):
                            return s
                    except Exception:
                        pass
                time.sleep(0.04)
        raise AssertionError(f"timed out after {timeout}s for {what}; last state = {self.state()}")

    # --- input ---
    def focus(self):
        subprocess.run(
            ["osascript", "-e",
             f'tell application "System Events" to set frontmost of '
             f'(first process whose unix id is {self.proc.pid}) to true'],
            stderr=subprocess.DEVNULL,
        )
        time.sleep(0.3)

    def key(self, name, flags=0):
        # Use osascript/System Events for keys: it applies modifiers reliably,
        # whereas raw CGEvent modifier flags don't always stick. Letters go via
        # `keystroke`; named/special keys (esc, return) via `key code`.
        mods = []
        if flags & CMD:
            mods.append("command down")
        if flags & SHIFT:
            mods.append("shift down")
        using = (" using {" + ", ".join(mods) + "}") if mods else ""
        if isinstance(name, str) and len(name) == 1:
            action = f'keystroke "{name}"{using}'
        else:
            code = KEYCODES[name] if isinstance(name, str) else int(name)
            action = f"key code {code}{using}"
        subprocess.run(
            ["osascript", "-e", f"tell application \"System Events\" to {action}"],
            stderr=subprocess.DEVNULL,
        )
        time.sleep(0.06)

    def type_text(self, text):
        esc = text.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(
            ["osascript", "-e", f'tell application "System Events" to keystroke "{esc}"'],
            stderr=subprocess.DEVNULL,
        )
        time.sleep(0.1)

    def enter(self):
        self.key("return")

    def _mouse_at(self, x, y, flags=0):
        pt = _CGPoint(float(x), float(y))
        for kind, pause in ((5, 0.05), (1, 0.06), (2, 0.05)):  # moved, left-down, left-up
            ev = _cg.CGEventCreateMouseEvent(None, kind, pt, 0)
            if flags:
                _cg.CGEventSetFlags(ev, flags)
            _post(ev)
            time.sleep(pause)

    def click(self, x, y):
        self._mouse_at(x, y)

    def cmd_click(self, x, y):
        # Physically hold Cmd (keycode 55) AND set the Cmd flag on the mouse events,
        # so the app reliably sees a Cmd+Click regardless of how it reads modifiers.
        kd = _cg.CGEventCreateKeyboardEvent(None, 55, True)
        _cg.CGEventSetFlags(kd, CMD)
        _post(kd)
        time.sleep(0.08)
        self._mouse_at(x, y, CMD)
        ku = _cg.CGEventCreateKeyboardEvent(None, 55, False)
        _post(ku)
        time.sleep(0.06)

    def opened_urls(self):
        """List of targets the app 'opened' (recorded in test mode), in order."""
        try:
            with open(self.opened_file) as f:
                return [ln.strip() for ln in f if ln.strip()]
        except FileNotFoundError:
            return []

    def scroll(self, dy):
        _post(_cg.CGEventCreateScrollWheelEvent(None, 1, 1, int(dy)))  # 1=line unit, 1 axis
        time.sleep(0.05)

    def window_rect(self):
        """(x, y, w, h) of the front window, in global screen coords."""
        out = subprocess.check_output(
            ["osascript", "-e",
             f'tell application "System Events" to tell '
             f'(first process whose unix id is {self.proc.pid}) '
             f"to get {{position, size}} of front window"]
        ).decode().strip()
        nums = [int(n.strip()) for n in out.replace(",", " ").split()]
        return tuple(nums[:4])

    def grid_cell_center(self, slot):
        """Global screen point at the center of grid cell `slot`."""
        s = self.state()
        cols, rows = s["grid_cols"], s["grid_rows"]
        x, y, w, h = self.window_rect()
        col, row = slot % cols, slot // cols
        cw, ch = w / cols, h / rows
        return (x + cw * (col + 0.5), y + ch * (row + 0.5))

    # --- lifecycle ---
    def quit(self):
        try:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=3)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        try:
            self._log.close()
        except Exception:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.quit()
