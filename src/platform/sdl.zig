const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig");

const is_macos = builtin.os.tag == .macos;
const log = std.log.scoped(.sdl);

pub const WindowPosition = struct { x: c_int, y: c_int };

pub const InitError = error{
    SDLInitFailed,
    TTFInitFailed,
    WindowCreationFailed,
    RendererCreationFailed,
    EventRegistrationFailed,
};

/// Process-wide SDL state: one per app. Threads keep a pointer to this for
/// wake events, so it must live at a stable address for the whole run.
pub const PlatformCore = struct {
    wake_event_type: u32,
};

/// One SDL window plus the renderer bound to it. Textures and fonts created
/// against `renderer` belong to this window only.
pub const PlatformWindow = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    vsync_enabled: bool,
    /// window logical size in points
    window_w: c_int,
    window_h: c_int,
    /// render output size in pixels
    render_w: c_int,
    render_h: c_int,
    /// scale factor render_pixels / window_points (per axis)
    scale_x: f32,
    scale_y: f32,
};

pub fn initCore() InitError!PlatformCore {
    // Let macOS provide native scroll momentum instead of synthesizing it.
    _ = c.SDL_SetHint("SDL_MAC_SCROLL_MOMENTUM", "1");
    if (is_macos) {
        // Keep press-and-hold behavior in repeat mode instead of showing the accent picker.
        std.debug.print("Disabling SDL_HINT_MAC_PRESS_AND_HOLD\n", .{});
        _ = c.SDL_SetHint(c.SDL_HINT_MAC_PRESS_AND_HOLD, "0");
        // Prevent Cmd+W from generating SDL_QUIT, allowing us to handle it ourselves
        _ = c.SDL_SetHint(c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }

    _ = c.SDL_EnableScreenSaver();

    if (!c.TTF_Init()) {
        std.debug.print("TTF_Init Error: {s}\n", .{c.SDL_GetError()});
        return error.TTFInitFailed;
    }

    // Force Metal renderer; fail if unavailable (no fallback to other drivers).
    const metal_hint_ok = c.SDL_SetHint("SDL_RENDER_DRIVER", "metal");
    if (!metal_hint_ok) {
        std.debug.print(
            "SDL_SetHint Error: failed to set SDL_RENDER_DRIVER to 'metal'; Metal renderer may be unavailable.\n",
            .{},
        );
        return error.RendererCreationFailed;
    }

    const wake_event_type = c.SDL_RegisterEvents(1);
    if (wake_event_type == std.math.maxInt(u32)) {
        std.debug.print("SDL_RegisterEvents Error: {s}\n", .{c.SDL_GetError()});
        return error.EventRegistrationFailed;
    }

    return PlatformCore{ .wake_event_type = wake_event_type };
}

pub fn initWindow(
    title: [*:0]const u8,
    width: c_int,
    height: c_int,
    position: ?WindowPosition,
    vsync_requested: bool,
) InitError!PlatformWindow {
    const window_flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = c.SDL_CreateWindow(title, width, height, window_flags) orelse {
        std.debug.print("SDL_CreateWindow Error: {s}\n", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    if (position) |pos| {
        _ = c.SDL_SetWindowPosition(window, pos.x, pos.y);
    }

    const renderer = c.SDL_CreateRenderer(window, "metal") orelse {
        std.debug.print("SDL_CreateRenderer Error: {s}\n", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    };
    errdefer c.SDL_DestroyRenderer(renderer);

    if (c.SDL_GetRendererName(renderer)) |name| {
        if (!std.mem.eql(u8, std.mem.sliceTo(name, 0), "metal")) {
            std.debug.print("Renderer mismatch: expected metal, got {s}\n", .{name});
            return error.RendererCreationFailed;
        }
    }

    const vsync_enabled = blk: {
        const success = c.SDL_SetRenderVSync(renderer, if (vsync_requested) 1 else 0);
        if (!success and vsync_requested) {
            std.debug.print("Warning: failed to enable vsync: {s}\n", .{c.SDL_GetError()});
            break :blk false;
        }
        break :blk vsync_requested and success;
    };

    var window_w: c_int = 0;
    var window_h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &window_w, &window_h);
    var render_w: c_int = 0;
    var render_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &render_w, &render_h);
    const scale_x: f32 = if (window_w != 0) @as(f32, @floatFromInt(render_w)) / @as(f32, @floatFromInt(window_w)) else 1.0;
    const scale_y: f32 = if (window_h != 0) @as(f32, @floatFromInt(render_h)) / @as(f32, @floatFromInt(window_h)) else 1.0;

    return PlatformWindow{
        .window = window,
        .renderer = renderer,
        .vsync_enabled = vsync_enabled,
        .window_w = window_w,
        .window_h = window_h,
        .render_w = render_w,
        .render_h = render_h,
        .scale_x = scale_x,
        .scale_y = scale_y,
    };
}

pub fn waitEventTimeout(timeout_ms: c_int) ?c.SDL_Event {
    if (timeout_ms <= 0) return null;

    var event = std.mem.zeroes(c.SDL_Event);
    if (!c.SDL_WaitEventTimeout(&event, timeout_ms)) return null;
    return event;
}

pub fn pushWakeEvent(core: *const PlatformCore) void {
    var event = std.mem.zeroes(c.SDL_Event);
    event.user.type = core.wake_event_type;
    if (!c.SDL_PushEvent(&event)) {
        log.err("failed to push runtime wake event: {s}", .{c.SDL_GetError()});
    }
}

pub fn isWakeEvent(core: *const PlatformCore, event: *const c.SDL_Event) bool {
    return event.type == core.wake_event_type;
}

pub fn pushWakeEventFromOpaque(context: ?*anyopaque) void {
    const core = @as(*const PlatformCore, @ptrCast(@alignCast(context orelse return)));
    pushWakeEvent(core);
}

pub fn startTextInput(window: *c.SDL_Window) void {
    _ = c.SDL_StartTextInput(window);
}

pub fn stopTextInput(window: *c.SDL_Window) void {
    _ = c.SDL_StopTextInput(window);
}

/// Toggle vsync on this window's renderer. With several windows, only the
/// focused one keeps vsync so N presents per frame do not stack refresh waits.
pub fn setVSync(w: *PlatformWindow, on: bool) void {
    if (w.vsync_enabled == on) return;
    if (!c.SDL_SetRenderVSync(w.renderer, if (on) 1 else 0)) {
        log.warn("failed to set vsync={}: {s}", .{ on, c.SDL_GetError() });
        return;
    }
    w.vsync_enabled = on;
}

pub fn windowId(w: *const PlatformWindow) c.SDL_WindowID {
    return c.SDL_GetWindowID(w.window);
}

pub fn deinitWindow(w: *PlatformWindow) void {
    c.SDL_DestroyRenderer(w.renderer);
    c.SDL_DestroyWindow(w.window);
}

pub fn deinitCore(_: *PlatformCore) void {
    c.TTF_Quit();
    c.SDL_Quit();
}
