const std = @import("std");
const app_state = @import("app_state.zig");
const c = @import("../c.zig");
const font_mod = @import("../font.zig");
const ghostty_vt = @import("ghostty-vt");
const pty_mod = @import("../pty.zig");
const renderer_mod = @import("../render/renderer.zig");
const dpi = @import("../dpi.zig");
const session_state = @import("../session/state.zig");
const shell_mod = @import("../shell.zig");
const vt_stream = @import("../vt_stream.zig");

const log = std.log.scoped(.layout);
const AnimationState = app_state.AnimationState;
const SessionState = session_state.SessionState;

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
    /// Pixel area the cells actually occupy (cols * cell_width, rows * cell_height).
    /// Mirrored into `ws_xpixel`/`ws_ypixel` and DEC 2048 reports so sessions get the
    /// pixel dimensions of their own rendered area (matters for grid-tile sessions,
    /// which draw into a small tile rather than the whole window).
    width_px: u16,
    height_px: u16,
};

pub fn updateRenderSizes(
    window: *c.SDL_Window,
    window_w: *c_int,
    window_h: *c_int,
    render_w: *c_int,
    render_h: *c_int,
    scale_x: *f32,
    scale_y: *f32,
) void {
    _ = c.SDL_GetWindowSize(window, window_w, window_h);
    _ = c.SDL_GetWindowSizeInPixels(window, render_w, render_h);
    scale_x.* = if (window_w.* != 0) @as(f32, @floatFromInt(render_w.*)) / @as(f32, @floatFromInt(window_w.*)) else 1.0;
    scale_y.* = if (window_h.* != 0) @as(f32, @floatFromInt(render_h.*)) / @as(f32, @floatFromInt(window_h.*)) else 1.0;
}

pub fn scaleEventToRender(event: *const c.SDL_Event, scale_x: f32, scale_y: f32) c.SDL_Event {
    var e = event.*;
    switch (e.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            e.button.x *= scale_x;
            e.button.y *= scale_y;
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => {
            e.button.x *= scale_x;
            e.button.y *= scale_y;
        },
        c.SDL_EVENT_MOUSE_MOTION => {
            e.motion.x *= scale_x;
            e.motion.y *= scale_y;
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            e.wheel.mouse_x *= scale_x;
            e.wheel.mouse_y *= scale_y;
        },
        c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_POSITION => {
            e.drop.x *= scale_x;
            e.drop.y *= scale_y;
        },
        else => {},
    }
    return e;
}

pub fn calculateHoveredSession(
    mouse_x: c_int,
    mouse_y: c_int,
    anim_state: *const AnimationState,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    render_width: c_int,
    render_height: c_int,
    grid_cols: usize,
    grid_rows: usize,
) ?usize {
    return switch (anim_state.mode) {
        .Grid, .GridResizing => {
            if (mouse_x < 0 or mouse_x >= render_width or
                mouse_y < 0 or mouse_y >= render_height) return null;

            const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_width_pixels))), grid_cols - 1);
            const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_height_pixels))), grid_rows - 1);
            return grid_row_idx * grid_cols + grid_col_idx;
        },
        .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => anim_state.focused_session,
        .Expanding, .Collapsing => {
            const rect = anim_state.getCurrentRect(std.time.milliTimestamp());
            if (mouse_x >= rect.x and mouse_x < rect.x + rect.w and
                mouse_y >= rect.y and mouse_y < rect.y + rect.h)
            {
                return anim_state.focused_session;
            }
            return null;
        },
    };
}

pub fn calculateTerminalSize(font: *const font_mod.Font, window_width: c_int, window_height: c_int, grid_font_scale: f32, ui_scale: f32) TerminalSize {
    const padding = dpi.scale(renderer_mod.terminal_padding, ui_scale) * 2;
    const usable_w = @max(0, window_width - padding);
    const usable_h = @max(0, window_height - padding);
    const scaled_cell_w = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(font.cell_width)) * grid_font_scale)));
    const scaled_cell_h = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(font.cell_height)) * grid_font_scale)));
    const cols = @max(1, @divFloor(usable_w, scaled_cell_w));
    const rows = @max(1, @divFloor(usable_h, scaled_cell_h));
    return .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .width_px = @intCast(cols * scaled_cell_w),
        .height_px = @intCast(rows * scaled_cell_h),
    };
}

/// Terminal cell-grid that fits `window_width × window_height` for an EXPLICIT
/// cell size in px. Mirrors the renderer's fit math (drawable = area − padding,
/// then floor-divide by the cell) so the PTY is sized to the exact cols/rows the
/// renderer draws — no clipped status line, no empty gap. Used for grid tiles,
/// where the cell is the grid font's native cell (rendered at scale 1.0).
fn terminalSizeForCell(window_width: c_int, window_height: c_int, cell_w: c_int, cell_h: c_int, ui_scale: f32) TerminalSize {
    const padding = dpi.scale(renderer_mod.terminal_padding, ui_scale) * 2;
    const usable_w = @max(0, window_width - padding);
    const usable_h = @max(0, window_height - padding);
    const cw = @max(1, cell_w);
    const ch = @max(1, cell_h);
    const cols = @max(1, @divFloor(usable_w, cw));
    const rows = @max(1, @divFloor(usable_h, ch));
    return .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .width_px = @intCast(cols * cw),
        .height_px = @intCast(rows * ch),
    };
}

pub const Sizes = struct {
    grid: TerminalSize,
    full: TerminalSize,
};

/// `grid_window_height` should be the render height with the Grid-mode CWD-bar
/// reservation applied (and should NOT vary across view modes — unfocused
/// sessions stay at grid size permanently, so the grid dims must be stable).
/// `full_window_height` is the raw render height (the focused session uses the
/// whole window when at full size).
///
/// `grid_cell_w`/`grid_cell_h` are the grid font's native cell size in px — the
/// SAME cell the renderer draws grid tiles with (at scale 1.0). Sizing the PTY
/// from the actual grid cell (instead of base-font × a scale factor) keeps the
/// PTY cols/rows in lockstep with what the renderer fits, so grid tiles never
/// clip the status line / right edge.
pub fn calculateTerminalSizes(
    font: *const font_mod.Font,
    window_width: c_int,
    grid_window_height: c_int,
    full_window_height: c_int,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    grid_cols: usize,
    grid_rows: usize,
    ui_scale: f32,
) Sizes {
    const tile_w = @divFloor(window_width, @as(c_int, @intCast(grid_cols)));
    const tile_h = @divFloor(grid_window_height, @as(c_int, @intCast(grid_rows)));
    return .{
        .grid = terminalSizeForCell(tile_w, tile_h, grid_cell_w, grid_cell_h, ui_scale),
        .full = calculateTerminalSize(font, window_width, full_window_height, 1.0, ui_scale),
    };
}

/// Describes which sessions need full-window cell dimensions. All other
/// sessions remain at grid-cell size. Only the focused session in stable Full
/// mode (and the previous focused session during a panning transition) is at
/// full size; the rest are invisible in Full mode and rendered at grid-cell
/// scale in Grid mode, so paying for full-size PTYs would just force them to
/// redraw their content on every view toggle.
pub const FullSet = struct {
    primary: ?usize = null,
    secondary: ?usize = null,

    pub fn contains(self: FullSet, idx: usize) bool {
        if (self.primary) |p| if (p == idx) return true;
        if (self.secondary) |s| if (s == idx) return true;
        return false;
    }
};

pub fn scaledFontSize(points: c_int, scale: f32) c_int {
    const scaled = std.math.round(@as(f32, @floatFromInt(points)) * scale);
    return @max(1, @as(c_int, @intFromFloat(scaled)));
}

/// Grid-tile winsize after giving up `reserve_px` at the bottom (the composer's
/// strip on Claude tiles), in whole cell rows, keeping at least one row.
pub fn reservedGridSize(grid: TerminalSize, reserve_px: c_int) pty_mod.winsize {
    var size = pty_mod.winsize{
        .ws_row = grid.rows,
        .ws_col = grid.cols,
        .ws_xpixel = grid.width_px,
        .ws_ypixel = grid.height_px,
    };
    if (reserve_px <= 0 or grid.rows == 0) return size;
    const cell_h: c_int = @divFloor(@as(c_int, grid.height_px), @as(c_int, grid.rows));
    if (cell_h <= 0) return size;
    const lost: c_int = @divFloor(reserve_px + cell_h - 1, cell_h);
    const kept: c_int = @max(1, @as(c_int, grid.rows) - lost);
    size.ws_row = @intCast(kept);
    size.ws_ypixel = @intCast(kept * cell_h);
    return size;
}

/// `grid_reserve_px[i]` (when present) is taken off the bottom of session i's
/// grid size; sessions in `full_set` use the full size unchanged.
pub fn applyTerminalResize(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    sizes: Sizes,
    full_set: FullSet,
    grid_reserve_px: []const c_int,
) bool {
    const full_size = pty_mod.winsize{
        .ws_row = sizes.full.rows,
        .ws_col = sizes.full.cols,
        .ws_xpixel = sizes.full.width_px,
        .ws_ypixel = sizes.full.height_px,
    };

    var terminal_resized = false;
    for (sessions, 0..) |session, idx| {
        const reserve: c_int = if (idx < grid_reserve_px.len) grid_reserve_px[idx] else 0;
        const target = if (full_set.contains(idx)) full_size else reservedGridSize(sizes.grid, reserve);
        if (!session.spawned) {
            session.pty_size = target;
            continue;
        }

        const shell = &(session.shell orelse continue);
        const terminal = &(session.terminal orelse continue);

        const winsize_changed = !std.meta.eql(session.pty_size, target);
        const terminal_cells_changed = terminal.cols != target.ws_col or terminal.rows != target.ws_row;

        if (winsize_changed) {
            shell.pty.setSize(target) catch |err| {
                log.warn("failed to resize PTY session={d} target={d}x{d}: {}", .{ session.id, target.ws_col, target.ws_row, err });
                continue;
            };
        }

        if (terminal_cells_changed) {
            resizeTerminal(allocator, terminal, target.ws_col, target.ws_row, target) catch |err| {
                log.warn("failed to resize VT session={d} target={d}x{d}: {}", .{ session.id, target.ws_col, target.ws_row, err });
                continue;
            };

            if (session.stream == null) {
                session.stream = vt_stream.initStream(allocator, terminal, shell);
            }
            session.resetSynchronizedOutputTracking();
            session.markDirty();
            terminal_resized = true;
        }

        // DEC 2048 reports carry pixel fields, so apps tracking pixel
        // geometry need them even when the cell count is unchanged.
        if (winsize_changed and terminal.modes.get(.in_band_size_reports)) {
            sendInBandSizeReport(shell, target);
        }

        session.pty_size = target;
    }
    return terminal_resized;
}

fn resizeTerminal(
    allocator: std.mem.Allocator,
    terminal: *ghostty_vt.Terminal,
    cols: u16,
    rows: u16,
    size: pty_mod.winsize,
) !void {
    try terminal.resize(allocator, cols, rows);
    terminal.width_px = @intCast(size.ws_xpixel);
    terminal.height_px = @intCast(size.ws_ypixel);
    // Spec-allowed by DEC mode 2026: clear synchronized output on resize so the
    // change is shown immediately rather than buffered.
    terminal.modes.set(.synchronized_output, false);
}

/// Write a DEC mode 2048 in-band size report to the shell. Apps that opt into
/// mode 2048 (nvim does) detect resizes via this report rather than SIGWINCH;
/// without it, they keep drawing at the pre-resize dimensions. Matches
/// ghostty's `src/termio/Termio.zig:sizeReportLocked` mode_2048 branch.
fn sendInBandSizeReport(shell: *shell_mod.Shell, size: pty_mod.winsize) void {
    var buf: [64]u8 = undefined;
    const report = vt_stream.formatInBandSizeReport(&buf, size.ws_row, size.ws_col, size.ws_ypixel, size.ws_xpixel) catch return;
    _ = shell.write(report) catch |err| {
        log.warn("failed to write in-band size report: {}", .{err});
    };
}

test "calculateTerminalSizes returns smaller grid than full and shrinks grid further when the grid cell grows" {
    var font: font_mod.Font = undefined;
    font.cell_width = 10;
    font.cell_height = 20;

    // grid cell == base cell, then a larger grid cell (fewer cols fit per tile).
    const normal = calculateTerminalSizes(&font, 1200, 800, 800, 10, 20, 2, 1, 1.0);
    const bigger_cell = calculateTerminalSizes(&font, 1200, 800, 800, 20, 40, 2, 1, 1.0);

    try std.testing.expect(normal.grid.cols < normal.full.cols);
    try std.testing.expect(bigger_cell.grid.cols < normal.grid.cols);
    // Full size is driven by the base font, not the grid cell.
    try std.testing.expectEqual(normal.full, bigger_cell.full);
}

test "calculateTerminalSizes grid dims stay stable when only full height changes" {
    var font: font_mod.Font = undefined;
    font.cell_width = 10;
    font.cell_height = 20;

    // grid_window_height held constant; full_window_height varies (the typical
    // case across view-mode toggles where the CWD-bar reservation only changes
    // when the actual grid layout changes).
    const a = calculateTerminalSizes(&font, 1200, 700, 800, 10, 20, 2, 1, 1.0);
    const b = calculateTerminalSizes(&font, 1200, 700, 750, 10, 20, 2, 1, 1.0);
    try std.testing.expectEqual(a.grid, b.grid);
}

test "FullSet.contains identifies primary and secondary indices" {
    try std.testing.expect(!(FullSet{}).contains(0));
    try std.testing.expect((FullSet{ .primary = 3 }).contains(3));
    try std.testing.expect(!(FullSet{ .primary = 3 }).contains(2));
    try std.testing.expect((FullSet{ .primary = 3, .secondary = 5 }).contains(5));
    try std.testing.expect(!(FullSet{ .primary = 3, .secondary = 5 }).contains(4));
}

test "terminal resize preserves prompt contents when shell does not redraw" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer terminal.deinit(allocator);

    const screen = terminal.screens.active;
    try screen.testWriteString("ABCDE\n");
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("> ");
    screen.cursorSetSemanticContent(.{ .input = .clear_eol });
    try screen.testWriteString("echo");
    terminal.flags.shell_redraws_prompt = .false;

    const before = try terminal.plainString(allocator);
    defer allocator.free(before);
    try std.testing.expectEqualStrings("ABCDE\n> echo", before);

    const size = pty_mod.winsize{ .ws_col = 20, .ws_row = 3, .ws_xpixel = 200, .ws_ypixel = 60 };
    try resizeTerminal(allocator, &terminal, 20, 3, size);

    const after = try terminal.plainString(allocator);
    defer allocator.free(after);
    try std.testing.expectEqualStrings("ABCDE\n> echo", after);
    try std.testing.expectEqual(@as(u32, 200), terminal.width_px);
    try std.testing.expectEqual(@as(u32, 60), terminal.height_px);
}

test "terminal resize clears semantic prompt when shell redraws prompt" {
    const allocator = std.testing.allocator;

    var terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer terminal.deinit(allocator);

    const screen = terminal.screens.active;
    try screen.testWriteString("ABCDE\n");
    screen.cursorSetSemanticContent(.{ .prompt = .initial });
    try screen.testWriteString("> ");
    screen.cursorSetSemanticContent(.{ .input = .clear_eol });
    try screen.testWriteString("echo");

    terminal.flags.shell_redraws_prompt = .true;
    const size = pty_mod.winsize{ .ws_col = 20, .ws_row = 3, .ws_xpixel = 200, .ws_ypixel = 60 };
    try resizeTerminal(allocator, &terminal, 20, 3, size);
    try std.testing.expectEqual(.true, terminal.flags.shell_redraws_prompt);

    const after = try terminal.plainString(allocator);
    defer allocator.free(after);
    try std.testing.expectEqualStrings("ABCDE", after);
}

test "reservedGridSize gives up whole rows for the reserve, keeping at least one" {
    const grid = TerminalSize{ .cols = 80, .rows = 30, .width_px = 640, .height_px = 480 }; // 16px rows
    const none = reservedGridSize(grid, 0);
    try std.testing.expectEqual(@as(u16, 30), none.ws_row);
    const strip = reservedGridSize(grid, 36); // 36px -> 3 rows
    try std.testing.expectEqual(@as(u16, 27), strip.ws_row);
    try std.testing.expectEqual(@as(u16, 27 * 16), strip.ws_ypixel);
    try std.testing.expectEqual(@as(u16, 80), strip.ws_col);
    try std.testing.expectEqual(@as(u16, 1), reservedGridSize(grid, 10_000).ws_row);
}
