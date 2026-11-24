// The quick entry shortcut: a double tap of Option, from any app.
//
// Two NSEvent monitors for modifier changes feed one detector: the global one
// while another app has the keyboard, the local one while Cadre does (or its
// quick entry panel, macos_quick_panel.zig). The monitors' handlers are
// blocks, built here by hand as static "global" blocks (they capture
// nothing), since the build has no Objective-C sources. arm64 only, like
// ui/components/composer_view.zig.
//
// Also bringing Cadre in front of whatever app the user is in, for when a
// quick entry is sent.

const std = @import("std");
const builtin = @import("builtin");
const c_sdl = @import("../c.zig");

const log = std.log.scoped(.hotkey);

pub const supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

/// Called on the main thread when the shortcut fires, to break the frame
/// loop's idle wait (platform.pushWakeEventFromOpaque).
pub const Wake = struct {
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) void,
};

/// Two quick presses of Option on its own. Fed every modifier change; fires
/// on the second press.
pub const DoubleTap = struct {
    state: State = .idle,

    /// Longest a press may be held to count as a tap, and the longest pause
    /// between the two taps. By-feel knobs.
    pub const max_hold_s: f64 = 0.25;
    pub const max_gap_s: f64 = 0.30;

    /// The modifiers held after a change: none, Option alone, or anything else.
    pub const Mods = enum { none, option, other };

    const State = union(enum) {
        idle,
        /// First press, at this time.
        down: f64,
        /// First tap done.
        up: struct { down: f64, up: f64 },
    };

    /// A modifier change at `t` (seconds). `last_key_t` is when a key other
    /// than a modifier last went down: Option+Left pressed twice is two word
    /// jumps, not a double tap.
    pub fn feed(self: *DoubleTap, mods: Mods, t: f64, last_key_t: f64) bool {
        switch (mods) {
            .other => self.state = .idle,
            .option => switch (self.state) {
                .idle => self.state = .{ .down = t },
                .down => {}, // the other Option key, pressed on top
                .up => |tap| {
                    if (t - tap.up <= max_gap_s and last_key_t < tap.down) {
                        self.state = .idle;
                        return true;
                    }
                    self.state = .{ .down = t };
                },
            },
            .none => self.state = switch (self.state) {
                .down => |down| if (t - down <= max_hold_s) .{ .up = .{ .down = down, .up = t } } else .idle,
                .idle, .up => .idle,
            },
        }
        return false;
    }
};

const Impl = if (supported) AppKit else None;

/// Start listening for the shortcut. Once per process; the monitors stay for
/// its lifetime.
pub fn install(wake: Wake) void {
    Impl.install(wake);
}

/// True once after each time the shortcut fired.
pub fn take() bool {
    return Impl.take();
}

/// Bring Cadre, and `window`, in front of whatever app has the screen: out of
/// hiding (Cmd+H) and out of the Dock (minimized) too.
pub fn bringForward(window: *c_sdl.SDL_Window) void {
    Impl.bringForward(window);
}

const None = struct {
    fn install(_: Wake) void {}
    fn take() bool {
        return false;
    }
    fn bringForward(_: *c_sdl.SDL_Window) void {}
};

const AppKit = struct {
    const objc = @import("objc.zig");
    const Id = objc.Id;
    const send = objc.send;
    const cls = objc.cls;

    /// Seconds since the last event of a type, system-wide. Tells that a key
    /// went down without the permission it takes to see which.
    extern "c" fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) f64;
    const cg_combined_session_state: i32 = 0; // kCGEventSourceStateCombinedSessionState
    const cg_key_down: u32 = 10; // kCGEventKeyDown
    /// Whether the user has granted this app the Accessibility permission.
    extern "c" fn AXIsProcessTrusted() u8;

    const ns_flags_changed_mask: u64 = 1 << 12; // NSEventMaskFlagsChanged
    const flag_shift: usize = 1 << 17;
    const flag_ctrl: usize = 1 << 18;
    const flag_option: usize = 1 << 19;
    const flag_cmd: usize = 1 << 20;

    // The block ABI (Block_private.h): a block that captures nothing can live
    // in static storage with the "global" class and flag; copying it is a no-op.
    const Block = extern struct {
        isa: *anyopaque,
        flags: c_int = 1 << 28, // BLOCK_IS_GLOBAL
        reserved: c_int = 0,
        invoke: *const anyopaque,
        descriptor: *const Descriptor,
    };
    const Descriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };
    const block_descriptor = Descriptor{ .size = @sizeOf(Block) };

    var global_block: Block = undefined;
    var local_block: Block = undefined;
    var installed = false;
    var wake: ?Wake = null;
    var detector = DoubleTap{};
    var pending = false;

    fn install(on_fire: Wake) void {
        if (installed) return;
        installed = true;
        wake = on_fire;
        const isa: *anyopaque = @extern(*anyopaque, .{ .name = "_NSConcreteGlobalBlock" });
        global_block = .{ .isa = isa, .invoke = @ptrCast(&onGlobal), .descriptor = &block_descriptor };
        local_block = .{ .isa = isa, .invoke = @ptrCast(&onLocal), .descriptor = &block_descriptor };
        const ns_event = cls("NSEvent");
        const global = send(Id, ns_event, "addGlobalMonitorForEventsMatchingMask:handler:", .{ ns_flags_changed_mask, @as(*anyopaque, &global_block) });
        const local = send(Id, ns_event, "addLocalMonitorForEventsMatchingMask:handler:", .{ ns_flags_changed_mask, @as(*anyopaque, &local_block) });
        if (global == null or local == null) {
            log.warn("quick entry shortcut: monitor not installed (global={} local={})", .{ global != null, local != null });
            return;
        }
        // The monitors only ask for modifier changes, which should not need
        // the permission; logged so a shortcut that never fires can be told
        // from one that macOS is holding back.
        log.info("quick entry shortcut installed (double-tap Option); accessibility permission: {s}", .{if (AXIsProcessTrusted() != 0) "granted" else "not granted"});
    }

    fn take() bool {
        const fired = pending;
        pending = false;
        return fired;
    }

    fn onGlobal(_: *Block, event: Id) callconv(.c) void {
        handle(event);
    }

    fn onLocal(_: *Block, event: Id) callconv(.c) Id {
        handle(event);
        return event;
    }

    fn handle(event: Id) void {
        const held = send(usize, event, "modifierFlags", .{}) & (flag_shift | flag_ctrl | flag_option | flag_cmd);
        const mods: DoubleTap.Mods = if (held == 0) .none else if (held == flag_option) .option else .other;
        // Event times count from system start, as systemUptime does.
        const now = send(f64, send(Id, cls("NSProcessInfo"), "processInfo", .{}), "systemUptime", .{});
        const last_key_t = now - CGEventSourceSecondsSinceLastEventType(cg_combined_session_state, cg_key_down);
        if (!detector.feed(mods, send(f64, event, "timestamp", .{}), last_key_t)) return;
        log.info("quick entry shortcut fired", .{});
        pending = true;
        if (wake) |w| w.callback(w.context);
    }

    fn bringForward(window: *c_sdl.SDL_Window) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const props = c_sdl.SDL_GetWindowProperties(window);
        const ns_window: Id = c_sdl.SDL_GetPointerProperty(props, c_sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return;
        const app = sharedApp();
        send(void, app, "unhide:", .{@as(Id, null)});
        send(void, app, "activateIgnoringOtherApps:", .{true});
        // Brings a minimized window back out as well.
        send(void, ns_window, "makeKeyAndOrderFront:", .{@as(Id, null)});
    }

    fn sharedApp() Id {
        return send(Id, cls("NSApplication"), "sharedApplication", .{});
    }
};

const testing = std.testing;

test "two quick presses of Option alone fire on the second press" {
    var tap = DoubleTap{};
    try testing.expect(!tap.feed(.option, 10.00, 5));
    try testing.expect(!tap.feed(.none, 10.08, 5));
    try testing.expect(tap.feed(.option, 10.20, 5));
    // Letting go of the second press starts nothing.
    try testing.expect(!tap.feed(.none, 10.30, 5));
    try testing.expect(!tap.feed(.option, 11.00, 5));
}

test "a held Option, or a slow second press, is not a double tap" {
    var held = DoubleTap{};
    _ = held.feed(.option, 10.0, 5);
    _ = held.feed(.none, 10.0 + DoubleTap.max_hold_s + 0.01, 5);
    try testing.expect(!held.feed(.option, 10.4, 5));

    var slow = DoubleTap{};
    _ = slow.feed(.option, 10.0, 5);
    _ = slow.feed(.none, 10.1, 5);
    try testing.expect(!slow.feed(.option, 10.1 + DoubleTap.max_gap_s + 0.01, 5));
    // That late press is a first tap of its own.
    _ = slow.feed(.none, 10.5, 5);
    try testing.expect(slow.feed(.option, 10.6, 5));
}

test "Option with a key or another modifier is not a tap" {
    // Option+Left, twice: a key went down during the first press.
    var word_jump = DoubleTap{};
    _ = word_jump.feed(.option, 10.00, 5);
    _ = word_jump.feed(.none, 10.10, 10.05);
    try testing.expect(!word_jump.feed(.option, 10.20, 10.05));

    // Shift joins the first press: that press no longer counts.
    var chord = DoubleTap{};
    _ = chord.feed(.option, 10.00, 5);
    _ = chord.feed(.other, 10.05, 5);
    _ = chord.feed(.none, 10.10, 5);
    try testing.expect(!chord.feed(.option, 10.20, 5));

    // Both Option keys at once is one press.
    var both = DoubleTap{};
    _ = both.feed(.option, 10.00, 5);
    try testing.expect(!both.feed(.option, 10.05, 5));
}
