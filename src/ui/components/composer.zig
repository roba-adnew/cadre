// Composer: a real text box for the focused Claude pane.
//
// Claude Code's own prompt is drawn out of terminal cells: a drag selection
// there can only be copied, and a long paste or dictation collapses into
// "[Pasted text #1 +40 lines]" before it can be edited. The composer is a native
// AppKit text view (composer_view.zig) where the user writes and edits freely;
// Enter hands the whole text to the terminal as one bracketed paste followed by
// Return (UiAction.ComposerSubmit). Keys Claude itself needs (Esc, Ctrl chords,
// Tab/Shift+Tab, PgUp/PgDn, and arrows/Enter while the box is empty) still go
// to the terminal.
//
// The box sits on Claude's own input box (`SessionUiInfo.prompt_box`), in full
// view and on the focused grid tile, in the terminal's font and colours, so the
// pane looks as Claude drew it: its rules, its prompt mark and its status lines
// are still the terminal's. A longer draft grows up over the conversation's
// last rows. When a dialog takes the input box's place the composer hides and
// keys reach the dialog. A small toggle on the rule under the box turns the
// composer off, for typing into Claude's own input (its "/" and "@" menus),
// and on again; the box slides away and back, since on and off look alike once
// settled. Off never carries over: a new input box always starts with the
// composer on. A click on the terminal leaves the keyboard in the box.
//
// The box would hide anything in Claude's own input, so while that input holds
// text (a message recalled with the up arrow, something typed or pasted there)
// the composer steps aside the same way, and comes back once it is empty.
//
// Only when no input box has ever been found (a Claude Code release may have
// redrawn it) is the box docked instead: under the terminal in full view, in a
// strip of its own on every Claude tile in the grid. There, clicking the
// terminal hands the keyboard to it and clicking the box takes it back.

const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const dpi = @import("../../dpi.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const UiRoot = @import("../root.zig").UiRoot;
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const view_mod = @import("composer_view.zig");
const renderer_mod = @import("../../render/renderer.zig");
const cwd_bar_metrics = @import("cwd_bar_metrics.zig");
const CwdBarComponent = @import("cwd_bar.zig").CwdBarComponent;
const search_utils = @import("search_utils.zig");
const easing = @import("../../anim/easing.zig");

const log = std.log.scoped(.composer);

const ComposerView = view_mod.ComposerView;
const Rect = geom.Rect;
const PromptBox = types.PromptBox;

/// Above the terminal interaction layer, below every menu and overlay so those
/// get keys first while open.
pub const z_index: i32 = 700;
const font_pt: f64 = 14;
/// Pause after the last edit before the draft is persisted (it is also
/// persisted right away when the box hides or switches panes).
const draft_save_delay_ms: i64 = 1000;
/// The box's typeface (NSFont systemFontOfSize:), so a tile's draft preview
/// doesn't change font when the tile gains focus.
const preview_font_path = "/System/Library/Fonts/SFNS.ttf";
/// The box's text insets (composer_view.zig textContainerInset), in points.
const preview_inset_x: c_int = 12;
const preview_inset_y: c_int = 9;
const min_height_pt: c_int = 36;
/// Space between Claude's status line (the terminal's last row) and the box.
const status_gap_pt: c_int = 10;
/// Light red wash on the box while the keyboard is in Claude's own prompt
/// (the user clicked the terminal), so typing into the wrong input shows.
/// Strength is a by-eye knob.
const away_tint = c.SDL_Color{ .r = 255, .g = 40, .b = 40, .a = 255 };
const away_tint_fraction: f32 = 0.18;
/// Claude redraws its screen in steps, and a step can leave its input box in
/// pieces for a frame: the place it was last seen holds this long before the
/// box counts as gone.
const spot_grace_ms: i64 = 150;
/// A live Claude whose input box has never been found gets the docked box
/// after this long (see `fallbackDock`).
const fallback_delay_ms: i64 = 3000;
/// The toggle on the rule under Claude's input box: what a click does.
const toggle_hide = " hide ";
const toggle_show = " show ";
const toggle_cells: c_int = toggle_hide.len;
/// The toggle slides the box away below the window, and back: on and off look
/// the same once settled (Claude's input is drawn just like the box), so the
/// move is what shows which way it went.
const slide_ms: i64 = 220;
/// While it is slid the box is a lighter card, so the move shows even with no
/// text in it: full strength by this fraction of the way out. By-eye knobs.
const slide_tint_by: f32 = 0.25;
const slide_tint_level: u2 = 3;

/// How far the box is slid away (0 = in place, 1 = wholly below the window)
/// `elapsed_ms` into a slide from `from` to `to`. A slide turned round
/// part-way takes that part of the time.
pub fn slideFraction(from: f32, to: f32, elapsed_ms: i64) f32 {
    const total = @as(f32, @floatFromInt(slide_ms)) * @abs(to - from);
    const t = if (total < 1) 1.0 else @as(f32, @floatFromInt(@max(0, elapsed_ms))) / total;
    if (t >= 1) return to;
    return from + (to - from) * easing.easeInOutCubic(t);
}

/// `rect` slid down by `slid` of the way to `bottom` (the window's bottom
/// edge, or its grid tile's) and cut off there, so it never shows on the tile
/// below.
pub fn slidRect(rect: Rect, slid: f32, bottom: c_int) Rect {
    var r = rect;
    r.y += @intFromFloat(slid * @as(f32, @floatFromInt(@max(0, bottom - rect.y))));
    r.h = std.math.clamp(bottom - r.y, 0, rect.h);
    return r;
}

/// The box's background on Claude's input box: the terminal's, lightening
/// into a card as the box slides away.
pub fn slideBackground(theme: *const colors.Theme, slid: f32) c.SDL_Color {
    return colors.shadeToward(theme.background, theme.surface(slide_tint_level), @min(1.0, slid / slide_tint_by));
}

/// The box's background: tinted red when `keyboard_away`.
pub fn boxBackground(theme: *const colors.Theme, keyboard_away: bool) c.SDL_Color {
    const bg = theme.surface(1);
    return if (keyboard_away) colors.shadeToward(bg, away_tint, away_tint_fraction) else bg;
}

pub const Route = enum { composer, terminal, submit };

/// Where a key press goes while the composer has focus. `has_text`: the box is
/// non-empty; `composing`: an input method or dictation holds marked text.
/// Must agree with `composer_view.commandAction`, which stops the text view
/// acting on keys routed to the terminal.
pub fn routeKeyDown(key: c.SDL_Keycode, mod: c.SDL_Keymod, has_text: bool, composing: bool) Route {
    const gui = (mod & c.SDL_KMOD_GUI) != 0;
    const ctrl = (mod & c.SDL_KMOD_CTRL) != 0;
    const alt = (mod & c.SDL_KMOD_ALT) != 0;
    const shift = (mod & c.SDL_KMOD_SHIFT) != 0;
    const enter = key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER;

    if (gui) {
        if (ctrl or alt) return .terminal;
        if (enter) return if (has_text and !composing) .submit else .terminal;
        return switch (key) {
            c.SDLK_A, c.SDLK_C, c.SDLK_V, c.SDLK_X, c.SDLK_Z => .composer,
            c.SDLK_LEFT, c.SDLK_RIGHT, c.SDLK_UP, c.SDLK_DOWN, c.SDLK_BACKSPACE, c.SDLK_DELETE => if (has_text) .composer else .terminal,
            else => .terminal, // Cadre's own shortcuts: Cmd+W, Cmd+1..9, Cmd+Esc, ...
        };
    }
    if (ctrl) return .terminal;
    if (enter) {
        if (composing or shift or alt) return .composer;
        return if (has_text) .submit else .terminal;
    }
    return switch (key) {
        c.SDLK_ESCAPE, c.SDLK_TAB, c.SDLK_PAGEUP, c.SDLK_PAGEDOWN => .terminal,
        // Empty box: arrows drive Claude's menus/history and Shift+Arrow pane nav.
        c.SDLK_UP, c.SDLK_DOWN, c.SDLK_LEFT, c.SDLK_RIGHT, c.SDLK_HOME, c.SDLK_END => if (has_text) .composer else .terminal,
        else => .composer,
    };
}

/// Shown for the focused pane while Claude runs in it: in steady full view,
/// or on the focused grid tile.
pub fn shouldShow(host: *const types.UiHost) bool {
    if (host.view_mode != .Full and host.view_mode != .Grid) return false;
    if (host.focused_session >= host.sessions.len) return false;
    const info = host.sessions[host.focused_session];
    return info.spawned and !info.dead and info.claude_live;
}

/// Where the box docks: the whole window in full view, or the focused grid
/// tile. Null when the tile is too small to hold the box with room to spare.
pub fn dockArea(host: *const types.UiHost) ?Rect {
    if (host.view_mode != .Grid) return .{ .x = 0, .y = 0, .w = host.window_w, .h = host.window_h };
    if (host.grid_cols == 0 or !tileFitsBox(host)) return null;
    const row: c_int = @intCast(host.focused_session / host.grid_cols);
    const col: c_int = @intCast(host.focused_session % host.grid_cols);
    const border = dpi.scale(renderer_mod.grid_border_thickness, host.ui_scale);
    return .{
        .x = col * host.cell_w + border,
        .y = row * host.cell_h + border,
        .w = host.cell_w - border * 2,
        .h = host.cell_h - border * 2,
    };
}

/// Grid tiles all share one size; a box (plus a few terminal rows) only makes
/// sense when a tile has room for it.
fn tileFitsBox(host: *const types.UiHost) bool {
    const border = dpi.scale(renderer_mod.grid_border_thickness, host.ui_scale);
    const bar = dpi.scale(cwd_bar_metrics.height, host.ui_scale);
    return host.cell_w - border * 2 > 0 and
        host.cell_h - border * 2 >= dpi.scale(min_height_pt, host.ui_scale) * 3 + bar;
}

pub const LiveBox = struct { session: usize, h: c_int };

/// Height of grid tile `i`'s box: the live box's on its own tile, one line on
/// every other Claude tile (so moving focus never resizes a terminal), 0 on
/// shell tiles and tiles too small for a box. `live` is the box currently up
/// on a grid tile, if any.
pub fn tileBoxPx(host: *const types.UiHost, i: usize, live: ?LiveBox) c_int {
    if (i >= host.sessions.len) return 0;
    const info = host.sessions[i];
    if (!info.spawned or info.dead or !info.claude_live or !tileFitsBox(host)) return 0;
    if (live) |box| {
        if (box.session == i) return box.h;
    }
    return dpi.scale(min_height_pt, host.ui_scale);
}

/// Pixels grid tile `i`'s PTY gives up for its box: the box and the gap above
/// it, less the id line's row that every tile already reserves (on a Claude
/// tile the id sits at the right end of the box's row instead).
pub fn tileReservePx(host: *const types.UiHost, i: usize, live: ?LiveBox) c_int {
    const box = tileBoxPx(host, i, live);
    if (box <= 0) return 0;
    const id_row = cwd_bar_metrics.reservedHeight(host.ui_scale, renderer_mod.grid_border_thickness);
    return @max(0, box + dpi.scale(status_gap_pt, host.ui_scale) - id_row);
}

/// Top of a box `status_gap_pt` under a terminal whose rows end at
/// `term_bottom`, or `docked_y` (the box flush with the area's bottom edge)
/// when the PTY height is unknown. Never below docked, and at most two lines
/// above it while a PTY catches up with a resize.
pub fn boxTop(term_bottom: c_int, term_h: c_int, docked_y: c_int, ui_scale: f32) c_int {
    if (term_h <= 0) return docked_y;
    const want = term_bottom + dpi.scale(status_gap_pt, ui_scale);
    return std.math.clamp(want, docked_y - dpi.scale(min_height_pt * 2, ui_scale), docked_y);
}

/// Grid tile `i`'s box (`h` tall) under its terminal's last row. The tile's
/// id line takes the right end of that row (`id_w`, at most half), so the box
/// stops there and its text wraps before the id.
pub fn tileBoxRect(host: *const types.UiHost, i: usize, h: c_int, id_w: c_int) Rect {
    var r = tileStrip(host, i, h);
    const top: c_int = @as(c_int, @intCast(i / host.grid_cols)) * host.cell_h;
    const pad = dpi.scale(renderer_mod.terminal_padding, host.ui_scale);
    const term_h = host.sessions[i].term_h_px;
    r.y = boxTop(top + pad + term_h, term_h, r.y, host.ui_scale);
    r.w -= @min(@max(0, id_w), @divFloor(r.w, 2));
    return r;
}

/// The docked `box` moved up under the focused terminal's last row (in the
/// grid, also short of the tile's id line).
pub fn placeBox(host: *const types.UiHost, box: Rect, id_w: c_int) Rect {
    if (host.view_mode == .Grid) return tileBoxRect(host, host.focused_session, box.h, id_w);
    const pad = dpi.scale(renderer_mod.terminal_padding, host.ui_scale);
    const term_h = host.sessions[host.focused_session].term_h_px;
    var r = box;
    r.y = boxTop(pad + term_h, term_h, box.y, host.ui_scale);
    return r;
}

/// Bottom strip of grid tile `i` with height `h` (inside the tile border).
fn tileStrip(host: *const types.UiHost, i: usize, h: c_int) Rect {
    const border = dpi.scale(renderer_mod.grid_border_thickness, host.ui_scale);
    const row: c_int = @intCast(i / host.grid_cols);
    const col: c_int = @intCast(i % host.grid_cols);
    return .{
        .x = col * host.cell_w + border,
        .y = row * host.cell_h + host.cell_h - border - h,
        .w = host.cell_w - border * 2,
        .h = h,
    };
}

/// A pane's rows as they lie on the window: where row 0 starts, the font they
/// are drawn in, how many rows and columns show, and the edge a box sliding
/// away stops at (the window's bottom, or the grid tile's).
pub const Surface = struct {
    x: c_int,
    y: c_int,
    bottom: c_int,
    font: types.TermFont,
    cols: c_int,
    rows: c_int,
};

/// Pane `i`'s rows: the whole window in full view, its tile in the grid (laid
/// out as renderer.renderSessionContent draws it). Null when the font isn't
/// known.
pub fn surfaceOf(host: *const types.UiHost, i: usize) ?Surface {
    const pad = dpi.scale(renderer_mod.terminal_padding, host.ui_scale);
    if (host.view_mode != .Grid) {
        const font = host.full_font;
        if (font.cell_w <= 0 or font.cell_h <= 0) return null;
        return .{ .x = pad, .y = pad, .bottom = host.window_h, .font = font, .cols = host.term_cols, .rows = host.term_rows };
    }
    const font = host.grid_font;
    if (font.cell_w <= 0 or font.cell_h <= 0 or host.grid_cols == 0) return null;
    const tile_x = @as(c_int, @intCast(i % host.grid_cols)) * host.cell_w;
    const tile_y = @as(c_int, @intCast(i / host.grid_cols)) * host.cell_h;
    const border = renderer_mod.grid_border_thickness;
    // The tile's id line keeps a row's worth free under the terminal's rows.
    const id_row = if (host.cell_h >= cwd_bar_metrics.minCellHeight(host.ui_scale, border)) cwd_bar_metrics.reservedHeight(host.ui_scale, border) else 0;
    return .{
        .x = tile_x + pad,
        .y = tile_y + pad,
        .bottom = tile_y + host.cell_h - dpi.scale(border, host.ui_scale),
        .font = font,
        .cols = @divFloor(host.cell_w - pad * 2, font.cell_w),
        .rows = @divFloor(host.cell_h - pad * 2 - id_row, font.cell_h),
    };
}

/// Rows of the box sitting on Claude's input box `spot`, for `content_h` px of
/// text: at least the rows Claude's own input has (to cover them), at most 40%
/// of the pane's rows or what leaves a row above for the box's rule. Past that
/// the text scrolls.
pub fn inlineRows(surface: Surface, spot: PromptBox, content_h: c_int) c_int {
    const cell_h = @max(1, surface.font.cell_h);
    const own: c_int = spot.textRows();
    const wanted = @divFloor(content_h + @divFloor(cell_h, 2), cell_h); // to the nearest row
    const room: c_int = @min(@divFloor(surface.rows * 2, 5), @as(c_int, spot.last));
    return @max(own, @min(wanted, room), 1);
}

/// The box sitting on Claude's input box: `rows` rows ending on that box's
/// last row, right of the prompt mark, as wide as the pane's columns.
pub fn inlineRect(surface: Surface, spot: PromptBox, rows: c_int) Rect {
    const font = surface.font;
    const gutter = types.prompt_gutter_cols * font.cell_w;
    return .{
        .x = surface.x + gutter,
        .y = surface.y + (@as(c_int, spot.last) + 1 - rows) * font.cell_h,
        .w = @max(0, surface.cols * font.cell_w - gutter),
        .h = rows * font.cell_h,
    };
}

/// How far the box `rect` (wherever a slide has it) reaches above the first
/// row of Claude's input box in pane `session`, for the renderer to move that
/// box's rule and prompt mark up with it (null when it doesn't).
pub fn promptLift(surface: Surface, spot: PromptBox, rect: Rect, session: usize) ?types.PromptLift {
    const px = surface.y + @as(c_int, spot.first) * surface.font.cell_h - rect.y;
    if (px <= 0) return null;
    return .{ .session = session, .top_rule = spot.top_rule, .first = spot.first, .px = px };
}

/// The toggle's place: on the rule under Claude's input box, one cell in from
/// its right end (where the rule above carries the session's name). Null on a
/// pane too narrow for it.
pub fn toggleRect(surface: Surface, spot: PromptBox) ?Rect {
    const font = surface.font;
    const col = surface.cols - 1 - toggle_cells;
    if (col < types.prompt_gutter_cols) return null;
    return .{
        .x = surface.x + col * font.cell_w,
        .y = surface.y + (@as(c_int, spot.last) + 1) * font.cell_h,
        .w = toggle_cells * font.cell_w,
        .h = font.cell_h,
    };
}

/// Box docked to the bottom of `area`, tall enough for `content_h` (render
/// px), between one line and 40% of the area; past that the text scrolls.
pub fn composerRect(area: Rect, content_h: c_int, ui_scale: f32) Rect {
    const min_h = dpi.scale(min_height_pt, ui_scale);
    const max_h = @max(min_h, @divFloor(area.h * 2, 5));
    const h = std.math.clamp(content_h, min_h, max_h);
    return .{ .x = area.x, .y = area.y + area.h - h, .w = area.w, .h = h };
}

/// First non-blank line of a draft, for a one-line preview.
pub fn firstLine(text: []const u8) []const u8 {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

/// Text to send, or null when there is nothing but whitespace. Unicode line and
/// paragraph separators (pasted from rich text) become "\n"; trailing
/// whitespace is dropped so the send doesn't end in blank lines.
pub fn normalizeSubmitText(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    const trimmed = std.mem.trimRight(u8, raw, " \t\r\n");
    if (std.mem.trim(u8, trimmed, " \t\r\n").len == 0) return null;
    const line_sep = "\u{2028}";
    const para_sep = "\u{2029}";
    const once = try std.mem.replaceOwned(u8, allocator, trimmed, line_sep, "\n");
    defer allocator.free(once);
    return try std.mem.replaceOwned(u8, allocator, once, para_sep, "\n");
}

pub const ComposerComponent = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    root: *UiRoot,
    view: ?ComposerView,
    visible: bool = false,
    /// Showing on a grid tile (vs full view); see `gridOverlay`.
    in_grid: bool = false,
    /// Showing on Claude's own input box, not docked.
    inline_mode: bool = false,
    /// Claude's input box in the focused pane, where it was last seen.
    spot: ?PromptBox = null,
    spot_ms: i64 = 0,
    /// persist_index of the pane `spot` was seen in.
    spot_key: usize = 0,
    /// `spot` is being held through `spot_grace_ms`; frames must keep coming
    /// until it is found again or given up.
    spot_held: bool = false,
    /// Claude's input box has been found at least once this run.
    spot_seen: bool = false,
    /// When a live Claude was first seen without its input box, while none
    /// has ever been found (`fallbackDock`).
    no_spot_since_ms: ?i64 = null,
    fallback_pending: bool = false,
    /// The fallback is on: boxes are docked, and Claude tiles keep a strip.
    fallback_docked: bool = false,
    /// Turned off with the toggle, to type into Claude's own input.
    user_hidden: bool = false,
    /// Turned on with the toggle over text in Claude's own input.
    forced_on: bool = false,
    /// Out of the way of the input box that is up: turned off with the
    /// toggle, or stepped aside because Claude's own input holds text that the
    /// box would hide (`PromptBox.typed`).
    off: bool = false,
    /// The input box has only just been taken up, so `off` applies at once
    /// instead of with a slide.
    spot_fresh: bool = false,
    /// How far the box is slid away (`slideFraction`): 1 once turned off.
    slid: f32 = 0,
    slide: ?Slide = null,
    /// `[ui] enable_animations`; off, the toggle takes effect at once.
    animate: bool = true,
    /// Where the toggle is drawn; null when Claude's input box isn't up.
    toggle_rect: ?Rect = null,
    /// Size of the font the toggle's label is set in (the pane's).
    toggle_px: c_int = 0,
    toggle_tex: ?search_utils.TextTex = null,
    toggle_key: ?ToggleKey = null,
    /// How far the box reaches above Claude's input box (`promptLift`).
    lift: ?types.PromptLift = null,
    style_key: ?StyleKey = null,
    /// The composer should hold the keyboard (vs the terminal).
    want_focus: bool = false,
    /// Keyboard handed to the terminal for a permission prompt or a text-entry
    /// overlay; taken back once that ends.
    yielded: bool = false,
    /// Already yielded during the current prompt/overlay, so a click back into
    /// the box sticks instead of being yielded away again.
    yield_spent: bool = false,
    session: usize = 0,
    /// persist_index of the pane whose draft is in the box.
    draft_key: ?usize = null,
    content_h: c_int = 0,
    reported_h: c_int = 0,
    /// Where the box is drawn (`placeBox`).
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    box_h: c_int = 0,
    /// Draws each grid tile's id line; the box stops short of it.
    id_line: ?*const CwdBarComponent = null,
    theme_key: ?[2]c.SDL_Color = null,
    /// Unsent text of panes not currently shown, by persist_index.
    drafts: std.AutoHashMapUnmanaged(usize, []u8) = .empty,
    /// Edited since the draft was last handed to the runtime to persist.
    persist_pending: bool = false,
    last_edit_ms: i64 = 0,
    /// System font for draft previews on unfocused tiles, matching the box.
    preview_font: ?*c.TTF_Font = null,
    preview_font_px: c_int = 0,
    first_frame: FirstFrameGuard = .{},

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window, root: *UiRoot) !*ComposerComponent {
        const self = try allocator.create(ComposerComponent);
        self.* = .{
            .allocator = allocator,
            .window = window,
            .root = root,
            .view = ComposerView.create(window, font_pt),
        };
        if (self.view == null and view_mod.supported) log.warn("composer text view unavailable", .{});
        return self;
    }

    pub fn asComponent(self: *ComposerComponent) UiComponent {
        return .{ .ptr = self, .vtable = &vtable, .z_index = z_index };
    }

    const Placement = union(enum) {
        none,
        /// Docked at the bottom of this area (a grid tile, or the window).
        docked: Rect,
        /// On Claude's own input box in the focused pane.
        on_prompt: struct { spot: PromptBox, surface: Surface },
    };

    const Slide = struct { from: f32, to: f32, start_ms: i64 };
    const StyleKey = struct { on_prompt: bool, font: types.TermFont, window_h: c_int, font_generation: u64 };
    const ToggleKey = struct { hidden: bool, hover: bool, px: c_int, color: c.SDL_Color };

    const vtable = UiComponent.VTable{
        .handleEvent = handleEventFn,
        .update = updateFn,
        .render = renderFn,
        .hitTest = hitTestFn,
        .deinit = deinitFn,
        .wantsFrame = wantsFrameFn,
    };

    fn handleEventFn(ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, out: *types.UiActionQueue) bool {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        // The toggle is up whether or not the box is.
        if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN or event.type == c.SDL_EVENT_MOUSE_BUTTON_UP) {
            if (self.overToggle(@intFromFloat(event.button.x), @intFromFloat(event.button.y))) {
                if (event.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and event.button.button == c.SDL_BUTTON_LEFT) {
                    self.flipToggle();
                    self.first_frame.markTransition();
                    log.info("composer turned {s} with its toggle", .{if (self.user_hidden) "off" else "on"});
                }
                return true;
            }
        }
        if (!self.visible) return false;
        const view = &(self.view orelse return false);
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                if (!view.isFocused()) return false;
                const key = event.key.key;
                const mod = event.key.mod;
                switch (routeKeyDown(key, mod, view.textLength() > 0, view.hasMarkedText())) {
                    .terminal => return false,
                    .submit => return self.submit(host, out),
                    .composer => {
                        if ((mod & c.SDL_KMOD_GUI) != 0) {
                            const shift = (mod & c.SDL_KMOD_SHIFT) != 0;
                            switch (key) {
                                c.SDLK_A => view.perform(.select_all),
                                // Nothing selected in the box: the copy is for a
                                // selection dragged in the terminal.
                                c.SDLK_C => if (view.hasSelection()) view.perform(.copy) else return false,
                                c.SDLK_X => view.perform(.cut),
                                c.SDLK_Z => view.perform(if (shift) .redo else .undo),
                                // A screenshot on the clipboard goes to the terminal's
                                // image passthrough (Claude attaches it), not the box.
                                c.SDLK_V => if (ComposerView.clipboardIsImageOnly()) return false else view.perform(.paste),
                                else => {}, // arrows/backspace: the text view handles them
                            }
                        }
                        return true;
                    },
                }
            },
            // The runtime sends Esc on key-up; let that one through.
            c.SDL_EVENT_KEY_UP => return view.isFocused() and event.key.key != c.SDLK_ESCAPE,
            c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING => return view.isFocused(),
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                // Clicks on the box itself never reach SDL (AppKit routes them to
                // the text view), so this is a click on the terminal: give it the
                // keyboard and let the click through.
                const x: c_int = @intFromFloat(event.button.x);
                const y: c_int = @intFromFloat(event.button.y);
                if (geom.containsPoint(self.rect, x, y)) return true;
                // On Claude's input box the toggle is the one way to Claude's own
                // input, so a click on the terminal (to select, say) leaves the
                // keyboard here; typing there would land under the box, unseen.
                if (self.inline_mode) return false;
                if (self.want_focus) self.focusTerminal(view);
                self.yielded = false; // an explicit choice; don't take it back later
                return false;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const x: c_int = @intFromFloat(event.motion.x);
                const y: c_int = @intFromFloat(event.motion.y);
                return geom.containsPoint(self.rect, x, y);
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const x: c_int = @intFromFloat(event.wheel.mouse_x);
                const y: c_int = @intFromFloat(event.wheel.mouse_y);
                return geom.containsPoint(self.rect, x, y);
            },
            else => return false,
        }
    }

    /// Put text the runtime refused to send (no agent in the pane) back as that
    /// pane's draft, so nothing typed or dictated is lost.
    pub fn returnText(self: *ComposerComponent, persist_index: usize, text: []const u8) void {
        if (self.visible and self.draft_key == persist_index) {
            if (self.view) |*view| view.setText(self.allocator, text);
            return;
        }
        const copy = self.allocator.dupe(u8, text) catch |err| {
            log.warn("failed to keep refused composer text: {}", .{err});
            return;
        };
        const entry = self.drafts.getOrPut(self.allocator, persist_index) catch |err| {
            log.warn("failed to keep refused composer text: {}", .{err});
            self.allocator.free(copy);
            return;
        };
        if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = copy;
    }

    fn submit(self: *ComposerComponent, host: *const types.UiHost, out: *types.UiActionQueue) bool {
        const view = &(self.view orelse return false);
        const raw = view.copyText(self.allocator) catch |err| {
            log.warn("failed to read composer text: {}", .{err});
            return true;
        };
        defer self.allocator.free(raw);
        const text = (normalizeSubmitText(self.allocator, raw) catch |err| {
            log.warn("failed to prepare composer text: {}", .{err});
            return true;
        }) orelse return false; // whitespace only: plain Enter for the terminal
        log.info("composer submit: {d} bytes to session {d}", .{ text.len, host.focused_session });
        out.append(.{ .ComposerSubmit = .{ .session = host.focused_session, .text = text } }) catch |err| {
            log.warn("failed to queue composer submit: {}", .{err});
            self.allocator.free(text);
            return true;
        };
        view.setText(self.allocator, "");
        // Sent: clear the persisted copy so it doesn't come back after a restart.
        self.persist_pending = true;
        self.persistDraft(view, out);
        return true;
    }

    /// Hand the bound pane's current text to the runtime to persist (see
    /// tmux.setComposerDraft) if it changed since the last time.
    fn persistDraft(self: *ComposerComponent, view: *ComposerView, out: *types.UiActionQueue) void {
        if (!self.persist_pending) return;
        const key = self.draft_key orelse return;
        const text = view.copyText(self.allocator) catch |err| {
            log.warn("failed to read composer draft: {}", .{err});
            return;
        };
        out.append(.{ .SaveComposerDraft = .{ .persist_index = key, .text = text } }) catch |err| {
            log.warn("failed to queue composer draft save: {}", .{err});
            self.allocator.free(text);
            return;
        };
        self.persist_pending = false;
    }

    /// A draft persisted by an earlier Cadre run (restored at startup). Kept
    /// only if this run has no draft of its own for that terminal yet.
    pub fn seedDraft(self: *ComposerComponent, persist_index: usize, text: []const u8) void {
        if (text.len == 0 or self.draft_key == persist_index or self.drafts.contains(persist_index)) return;
        const copy = self.allocator.dupe(u8, text) catch |err| {
            log.warn("failed to restore composer draft: {}", .{err});
            return;
        };
        self.drafts.put(self.allocator, persist_index, copy) catch |err| {
            log.warn("failed to restore composer draft: {}", .{err});
            self.allocator.free(copy);
        };
    }

    fn updateFn(ptr: *anyopaque, host: *const types.UiHost, out: *types.UiActionQueue) void {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        const view = &(self.view orelse return);

        self.pruneDrafts(host);
        if (self.slide) |slide| {
            self.slid = slideFraction(slide.from, slide.to, host.now_ms - slide.start_ms);
            if (self.slid == slide.to) self.slide = null;
        }
        const id_w = self.idWidthPx(host.focused_session);
        const in_grid = host.view_mode == .Grid;
        const placement = self.place(host);
        var rect = self.boxRect(host, placement, id_w) orelse self.rect;
        const on_prompt = placement == .on_prompt;
        const show = placement != .none and !self.covered(host, rect);

        // Edits belong to the pane they were made in: note them before a swap
        // below binds the box to another pane.
        if (self.visible and view.takeEdited()) {
            self.persist_pending = true;
            self.last_edit_ms = host.now_ms;
        }

        if (show and self.visible and host.focused_session != self.session) {
            // Pane switched while the box stays up (grid tile or full view): swap drafts.
            self.persistDraft(view, out);
            self.saveDraft(view);
            self.bindSession(view, host);
            self.focusComposer(view);
        }
        if (show != self.visible) {
            self.visible = show;
            self.first_frame.markTransition();
            log.info("composer {s} (session {d})", .{ if (show) "shown" else "hidden", host.focused_session });
            if (show) {
                self.applyStyle(view, host, placement);
                self.applyTheme(view, host, on_prompt);
                self.bindSession(view, host);
                view.setHidden(false);
                self.focusComposer(view);
            } else {
                self.persistDraft(view, out);
                self.saveDraft(view);
                self.draft_key = null;
                if (self.want_focus) self.focusTerminal(view);
                self.yielded = false;
                view.setHidden(true);
            }
        }

        if (self.visible) {
            if (self.persist_pending and host.now_ms - self.last_edit_ms >= draft_save_delay_ms) self.persistDraft(view, out);
            if (self.off and on_prompt) {
                // Out of the way: the keyboard is Claude's at once, while the
                // box is still sliding away.
                if (self.want_focus) self.focusTerminal(view);
                self.yielded = false;
            } else {
                self.syncFocus(view, host);
            }
            // After the focus sync, so the tint follows a focus change the same frame.
            self.applyStyle(view, host, placement);
            self.applyTheme(view, host, on_prompt);
            view.setFrame(rect, host.window_w, host.window_h);
            self.content_h = view.contentHeightPx(host.window_h);
            rect = self.boxRect(host, placement, id_w) orelse rect;
            self.box_h = rect.h;
            view.setFrame(rect, host.window_w, host.window_h);
        }
        self.rect = rect;

        self.in_grid = in_grid;
        self.inline_mode = self.visible and on_prompt;
        // The renderer redraws the terminal's rows around a taller box, so a
        // change needs a frame even when the terminal itself hasn't changed.
        const lift = if (self.inline_mode) promptLift(placement.on_prompt.surface, placement.on_prompt.spot, rect, host.focused_session) else null;
        if (!std.meta.eql(lift, self.lift)) self.first_frame.markTransition();
        self.lift = lift;
        // Docked in full view: the runtime shrinks the focused PTY by this. On
        // Claude's input box nothing is given up, and docked grid tiles are
        // sized from `gridReservePx` instead.
        const reserve: c_int = if (self.visible and !in_grid and !on_prompt) self.box_h + dpi.scale(status_gap_pt, host.ui_scale) else 0;
        if (reserve != self.reported_h) {
            out.append(.{ .SetComposerHeight = reserve }) catch |err| {
                log.warn("failed to queue composer height: {}", .{err});
                return;
            };
            self.reported_h = reserve;
        }
    }

    /// Where the box goes this frame, if anywhere.
    fn place(self: *ComposerComponent, host: *const types.UiHost) Placement {
        const live = shouldShow(host);
        // The focused pane's rows with Claude's input box on them, if it is up.
        const on: ?@FieldType(Placement, "on_prompt") = blk: {
            if (live) {
                if (surfaceOf(host, host.focused_session)) |surface| {
                    self.toggle_px = surface.font.px;
                    const spot = self.trackSpot(host, surface) orelse break :blk null;
                    break :blk .{ .spot = spot, .surface = surface };
                }
            }
            self.spot = null;
            self.spot_held = false;
            break :blk null;
        };
        self.toggle_rect = if (on) |found| toggleRect(found.surface, found.spot) else null;
        const dock_anyway = live and on == null and self.fallbackDock(host);
        if (!live or on != null) {
            self.no_spot_since_ms = null;
            self.fallback_pending = false;
        }
        if (!live) return .none;
        if (on) |found| {
            self.setOff(self.user_hidden or (found.spot.typed and !self.forced_on), host.now_ms);
            // Out of the way, the box stays up until it has slid away.
            return if (self.off and self.slid >= 1) .none else .{ .on_prompt = found };
        }
        if (!dock_anyway) return .none; // a dialog has the input box's place
        return if (dockArea(host)) |area| .{ .docked = area } else .none;
    }

    fn boxRect(self: *const ComposerComponent, host: *const types.UiHost, placement: Placement, id_w: c_int) ?Rect {
        return switch (placement) {
            .none => null,
            .docked => |area| placeBox(host, composerRect(area, self.content_h, host.ui_scale), id_w),
            .on_prompt => |on| slidRect(inlineRect(on.surface, on.spot, inlineRows(on.surface, on.spot, self.content_h)), self.slid, on.surface.bottom),
        };
    }

    /// Claude's input box in the focused pane: where it is now, or where it
    /// was until `spot_grace_ms` ago.
    fn trackSpot(self: *ComposerComponent, host: *const types.UiHost, surface: Surface) ?PromptBox {
        self.spot_held = false;
        const info = host.sessions[host.focused_session];
        const key = info.persist_index;
        // A box that runs past the rows on show isn't where its rows say: the
        // pane is between two sizes.
        const found = if (info.prompt_box) |box| (if (@as(c_int, box.last) + 1 < surface.rows) box else null) else null;
        if (found) |box| {
            // Off lasts only for the input box it was turned off on: another
            // pane's, or this one's again after a dialog or a change of view,
            // starts with the composer showing.
            if (self.spot == null or self.spot_key != key) {
                self.user_hidden = false;
                self.forced_on = false;
                self.spot_fresh = true;
            }
            // Its input emptied (sent, or cleared): the next text there is new.
            if (!box.typed) self.forced_on = false;
            self.spot = box;
            self.spot_ms = host.now_ms;
            self.spot_key = key;
            self.spot_seen = true;
            self.fallback_docked = false;
            return box;
        }
        const held = self.spot orelse return null;
        if (self.spot_key == key and host.now_ms - self.spot_ms < spot_grace_ms) {
            self.spot_held = true;
            return held;
        }
        self.spot = null;
        return null;
    }

    /// Claude live in the focused pane, its input box not on screen. Normally
    /// a dialog has taken the box's place and it will be back, so there is
    /// nothing to show. But while no input box has ever been found this run (a
    /// Claude Code release may have redrawn it), dock the box as the composer
    /// used to, after a pause for a starting Claude to draw.
    /// ponytail: one flag for the whole run; a pane running a Claude that draws
    /// its box differently gets no composer once another pane's was found.
    fn fallbackDock(self: *ComposerComponent, host: *const types.UiHost) bool {
        if (self.spot_seen) return false;
        if (self.fallback_docked) return true;
        const since = self.no_spot_since_ms orelse host.now_ms;
        self.no_spot_since_ms = since;
        self.fallback_pending = host.now_ms - since < fallback_delay_ms;
        self.fallback_docked = !self.fallback_pending;
        return self.fallback_docked;
    }

    /// Put the composer out of the way of the input box, or back. A change on
    /// an input box already up slides; on one just taken up it applies at once.
    fn setOff(self: *ComposerComponent, off: bool, now_ms: i64) void {
        const fresh = self.spot_fresh;
        self.spot_fresh = false;
        if (off == self.off and !fresh) return;
        self.off = off;
        const to: f32 = if (off) 1 else 0;
        self.slide = if (self.animate and !fresh) .{ .from = self.slid, .to = to, .start_ms = now_ms } else null;
        if (self.slide == null) self.slid = to;
    }

    /// A click on the toggle: on if the composer is out of the way (over
    /// whatever Claude's own input holds), off if it is up.
    fn flipToggle(self: *ComposerComponent) void {
        self.user_hidden = !self.off;
        self.forced_on = self.off;
    }

    fn overToggle(self: *const ComposerComponent, x: c_int, y: c_int) bool {
        const rect = self.toggle_rect orelse return false;
        return geom.containsPoint(rect, x, y);
    }

    /// What the renderer should move up for a box taller than Claude's own.
    pub fn promptLiftNow(self: *const ComposerComponent) ?types.PromptLift {
        return self.lift;
    }

    /// The box's font and spacing: the pane's on Claude's input box, the
    /// system's in a docked box.
    fn applyStyle(self: *ComposerComponent, view: *ComposerView, host: *const types.UiHost, placement: Placement) void {
        const cache = self.root.assets.font_cache;
        const font: ?types.TermFont = if (placement == .on_prompt) placement.on_prompt.surface.font else null;
        const key = StyleKey{
            .on_prompt = font != null,
            .font = font orelse .{},
            .window_h = if (font != null) host.window_h else 0,
            .font_generation = if (cache) |fonts| fonts.generation else 0,
        };
        if (self.style_key) |prev| {
            if (std.meta.eql(prev, key)) return;
        }
        self.style_key = key;
        const font_path: []const u8 = if (cache) |fonts| fonts.regular_path orelse "" else "";
        view.setStyle(if (font) |f| .{ .terminal = .{
            .font_name = std.fs.path.stem(font_path),
            .font_px = f.px,
            .cell_h = f.cell_h,
            .ascent = f.ascent,
            .render_h = host.window_h,
        } } else .{ .docked = .{ .font_pt = font_pt } });
    }

    /// Keep AppKit's first responder, SDL text input and `want_focus` in step.
    fn syncFocus(self: *ComposerComponent, view: *ComposerView, host: *const types.UiHost) void {
        const focused = view.isFocused();
        // Clicked into the box (AppKit made it first responder behind our back).
        if (focused and !self.want_focus) {
            self.want_focus = true;
            self.yielded = false;
        }

        // Claude asks for approval (keys like 1/2/3 must reach it), or an overlay
        // needs SDL text input for its own field.
        const approval = host.sessions[host.focused_session].approval_pending;
        if (!approval and !host.text_entry_open) {
            self.yield_spent = false;
            if (self.yielded) {
                self.yielded = false;
                self.focusComposer(view);
                return;
            }
        } else if (!self.yield_spent and self.want_focus and (host.text_entry_open or view.textLength() == 0)) {
            self.focusTerminal(view);
            self.yielded = true;
            self.yield_spent = true;
            return;
        }
        // Focus regained after app switch: the runtime restarted SDL text input,
        // which made SDL's own field first responder.
        if (self.want_focus and (!focused or c.SDL_TextInputActive(self.window))) self.focusComposer(view);
    }

    fn focusComposer(self: *ComposerComponent, view: *ComposerView) void {
        _ = c.SDL_StopTextInput(self.window);
        view.focus();
        self.want_focus = true;
    }

    fn focusTerminal(self: *ComposerComponent, view: *ComposerView) void {
        view.unfocus();
        // Stop first so Start re-creates SDL's field and makes it first responder.
        _ = c.SDL_StopTextInput(self.window);
        _ = c.SDL_StartTextInput(self.window);
        self.want_focus = false;
    }

    /// A native view draws over every SDL overlay, so hide whenever one is open
    /// on top of the box's area.
    /// ponytail: samples 9 points; an overlay smaller than the gaps slips under.
    fn covered(self: *ComposerComponent, host: *const types.UiHost, rect: Rect) bool {
        const xs = [_]c_int{ rect.x + 1, rect.x + @divFloor(rect.w, 2), rect.x + rect.w - 2 };
        const ys = [_]c_int{ rect.y + 1, rect.y + @divFloor(rect.h, 2), rect.y + rect.h - 2 };
        for (ys) |y| for (xs) |x| {
            if (self.root.hitTestAbove(z_index, host, x, y)) return true;
        };
        return false;
    }

    fn bindSession(self: *ComposerComponent, view: *ComposerView, host: *const types.UiHost) void {
        self.session = host.focused_session;
        const key = host.sessions[host.focused_session].persist_index;
        self.draft_key = key;
        const draft = if (self.drafts.fetchRemove(key)) |kv| kv.value else null;
        defer if (draft) |d| self.allocator.free(d);
        view.setText(self.allocator, draft orelse "");
    }

    fn saveDraft(self: *ComposerComponent, view: *ComposerView) void {
        const key = self.draft_key orelse return;
        const text = view.copyText(self.allocator) catch |err| {
            log.warn("failed to save composer draft: {}", .{err});
            return;
        };
        if (text.len == 0) {
            self.allocator.free(text);
            return;
        }
        const entry = self.drafts.getOrPut(self.allocator, key) catch |err| {
            log.warn("failed to save composer draft: {}", .{err});
            self.allocator.free(text);
            return;
        };
        if (entry.found_existing) self.allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = text;
    }

    /// Closed panes' persist indices get reused, so drop drafts whose pane is gone.
    fn pruneDrafts(self: *ComposerComponent, host: *const types.UiHost) void {
        var it = self.drafts.iterator();
        while (it.next()) |entry| {
            const alive = for (host.sessions) |info| {
                if (info.spawned and info.persist_index == entry.key_ptr.*) break true;
            } else false;
            if (alive) continue;
            self.allocator.free(entry.value_ptr.*);
            self.drafts.removeByPtr(entry.key_ptr);
            return; // iterator is invalid now; the rest go on later frames
        }
    }

    fn applyTheme(self: *ComposerComponent, view: *ComposerView, host: *const types.UiHost, on_prompt: bool) void {
        const theme = host.theme;
        // Away = the user handed the keyboard to the terminal. A yield to a
        // permission prompt or an overlay is expected, so it stays untinted.
        // On Claude's input box the box is a stretch of the terminal's screen.
        const bg = if (on_prompt) slideBackground(theme, self.slid) else boxBackground(theme, !self.want_focus and !self.yielded);
        const key = [2]c.SDL_Color{ bg, theme.foreground };
        if (self.theme_key) |prev| {
            if (std.meta.eql(prev, key)) return;
        }
        self.theme_key = key;
        view.setColors(
            .{ .r = bg.r, .g = bg.g, .b = bg.b },
            .{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b },
            .{ .r = theme.accent.r, .g = theme.accent.g, .b = theme.accent.b },
        );
    }

    /// Pixels grid tile `i`'s PTY gives up for its box (`tileReservePx`,
    /// applied by layout.reservedGridSize).
    pub fn gridReservePx(self: *const ComposerComponent, host: *const types.UiHost, i: usize) c_int {
        // On Claude's input box a tile gives up nothing.
        if (!self.fallback_docked) return 0;
        return tileReservePx(host, i, self.liveBox());
    }

    fn liveBox(self: *const ComposerComponent) ?LiveBox {
        return if (self.view != null and self.visible and self.in_grid and !self.inline_mode) .{ .session = self.session, .h = self.box_h } else null;
    }

    fn tileBoxH(self: *const ComposerComponent, host: *const types.UiHost, i: usize) c_int {
        if (self.view == null or !self.fallback_docked) return 0;
        return tileBoxPx(host, i, self.liveBox());
    }

    fn idWidthPx(self: *const ComposerComponent, i: usize) c_int {
        const bar = self.id_line orelse return 0;
        return bar.idWidthPx(i);
    }

    /// Where cwd_bar.zig draws grid tile `i`'s id line: the right end of the
    /// first line of its box row, or null on tiles without a box.
    pub fn idRow(self: *const ComposerComponent, host: *const types.UiHost, i: usize) ?Rect {
        const h = self.tileBoxH(host, i);
        if (h <= 0) return null;
        const row = tileBoxRect(host, i, h, 0);
        return .{ .x = row.x, .y = row.y, .w = row.w, .h = dpi.scale(min_height_pt, host.ui_scale) };
    }

    fn renderFn(ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        defer self.first_frame.markDrawn();
        self.drawToggle(renderer, host, assets);
        const line = host.theme.chromeBorder();
        // Unfocused Claude tiles show an empty strip where their box goes; a
        // click there focuses the tile and the live box moves in.
        if (host.view_mode == .Grid and !self.fallback_docked) self.drawInlinePreviews(renderer, host, assets);
        if (host.view_mode == .Grid and self.fallback_docked) {
            const fill = host.theme.surface(1);
            for (host.sessions, 0..) |_, i| {
                if (self.visible and i == self.session) continue;
                const h = self.tileBoxH(host, i);
                if (h <= 0) continue;
                const strip = tileBoxRect(host, i, h, self.idWidthPx(i));
                _ = c.SDL_SetRenderDrawColor(renderer, fill.r, fill.g, fill.b, 255);
                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = @floatFromInt(strip.x), .y = @floatFromInt(strip.y), .w = @floatFromInt(strip.w), .h = @floatFromInt(strip.h) });
                drawRowBorders(renderer, line, tileBoxRect(host, i, h, 0));
                const draft = self.drafts.get(host.sessions[i].persist_index) orelse continue;
                self.drawPreview(renderer, host, assets, strip, firstLine(draft));
            }
        }
        // On Claude's input box the rules around it are the terminal's own.
        if (!self.visible or self.inline_mode) return;
        // The box itself is the native view; its row's borders span the id too.
        drawRowBorders(renderer, line, if (self.in_grid) tileBoxRect(host, self.session, self.rect.h, 0) else self.rect);
    }

    /// The toggle, written into the rule under Claude's input box the way
    /// Claude writes a session's name into the rule above it.
    fn drawToggle(self: *ComposerComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) void {
        const rect = self.toggle_rect orelse return;
        const theme = host.theme;
        const hover = host.mouse_has_position and geom.containsPoint(rect, host.mouse_x, host.mouse_y);
        // Off stands out: the keyboard is in Claude's input, not the composer.
        const color = if (hover) theme.foreground else if (self.off) theme.accent else theme.chromeTextDim();
        const key = ToggleKey{ .hidden = self.off, .hover = hover, .px = self.toggle_px, .color = color };
        const fresh = if (self.toggle_key) |prev| !std.meta.eql(prev, key) else true;
        if (fresh) {
            if (self.toggle_tex) |old| c.SDL_DestroyTexture(old.tex);
            self.toggle_tex = null;
            self.toggle_key = key;
            const cache = assets.font_cache orelse return;
            const fonts = cache.get(self.toggle_px) catch |err| {
                log.warn("no font for the composer toggle: {}", .{err});
                return;
            };
            self.toggle_tex = search_utils.makeTextTexture(self.allocator, renderer, fonts.regular, if (self.off) toggle_show else toggle_hide, color) catch |err| blk: {
                log.warn("failed to draw the composer toggle: {}", .{err});
                break :blk null;
            };
        }
        const tex = self.toggle_tex orelse return;
        // Blank the stretch of rule under the label.
        const bg = theme.background;
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 255);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .w = @floatFromInt(rect.w), .h = @floatFromInt(rect.h) });
        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + @divFloor(rect.w - tex.w, 2)),
            .y = @floatFromInt(rect.y + @divFloor(rect.h - tex.h, 2)),
            .w = @floatFromInt(tex.w),
            .h = @floatFromInt(tex.h),
        });
    }

    /// Grid: a tile's unsent draft while the box is on another tile, written
    /// on that tile's own prompt row where the box would put it, so selecting
    /// another tile doesn't make it vanish.
    fn drawInlinePreviews(self: *ComposerComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) void {
        const cache = assets.font_cache orelse return;
        const bg = host.theme.background;
        const fg = host.theme.foreground;
        for (host.sessions, 0..) |info, i| {
            // The focused tile shows the box itself, or Claude's input when it is off.
            if (i == host.focused_session and (self.visible or self.off)) continue;
            if (!info.spawned or info.dead or info.hidden or !info.claude_live) continue;
            const spot = info.prompt_box orelse continue;
            // Text in Claude's own input stays on show; a preview would cover it.
            if (spot.typed) continue;
            const text = firstLine(self.drafts.get(info.persist_index) orelse continue);
            if (text.len == 0) continue;
            const surface = surfaceOf(host, i) orelse continue;
            if (@as(c_int, spot.last) + 1 >= surface.rows) continue;
            const row = inlineRect(surface, .{ .top_rule = spot.top_rule, .first = spot.first, .last = spot.first }, 1);
            const fonts = cache.get(surface.font.px) catch |err| {
                log.warn("no font for a tile's draft preview: {}", .{err});
                continue;
            };
            const text_surface = c.TTF_RenderText_Blended(fonts.regular, text.ptr, text.len, .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 }) orelse continue;
            defer c.SDL_DestroySurface(text_surface);
            const texture = c.SDL_CreateTextureFromSurface(renderer, text_surface) orelse continue;
            defer c.SDL_DestroyTexture(texture);
            var w: f32 = 0;
            var h: f32 = 0;
            _ = c.SDL_GetTextureSize(texture, &w, &h);
            _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 255);
            _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = @floatFromInt(row.x), .y = @floatFromInt(row.y), .w = @floatFromInt(row.w), .h = @floatFromInt(row.h) });
            // A long first line is cut at the tile's last column.
            const clip = c.SDL_Rect{ .x = row.x, .y = row.y, .w = row.w, .h = row.h };
            _ = c.SDL_SetRenderClipRect(renderer, &clip);
            _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
                .x = @floatFromInt(row.x),
                .y = @as(f32, @floatFromInt(row.y)) + (@as(f32, @floatFromInt(row.h)) - h) / 2,
                .w = w,
                .h = h,
            });
            _ = c.SDL_SetRenderClipRect(renderer, null);
        }
    }

    /// An unfocused tile's unsent draft, shown read-only in its strip where the
    /// box would put it, so selecting another tile doesn't make it vanish.
    fn drawPreview(self: *ComposerComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets, strip: Rect, text: []const u8) void {
        if (text.len == 0) return;
        const font = self.previewFont(host, assets) orelse return;
        const fg = host.theme.foreground;
        const surface = c.TTF_RenderText_Blended(font, text.ptr, text.len, .{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 }) orelse return;
        defer c.SDL_DestroySurface(surface);
        const texture = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return;
        defer c.SDL_DestroyTexture(texture);
        var w: f32 = 0;
        var h: f32 = 0;
        _ = c.SDL_GetTextureSize(texture, &w, &h);
        // Clip to the strip: long drafts are cut at the tile edge, like a
        // one-line box would scroll them.
        const clip = c.SDL_Rect{ .x = strip.x, .y = strip.y, .w = strip.w, .h = strip.h };
        _ = c.SDL_SetRenderClipRect(renderer, &clip);
        defer _ = c.SDL_SetRenderClipRect(renderer, null);
        _ = c.SDL_RenderTexture(renderer, texture, null, &c.SDL_FRect{
            .x = @floatFromInt(strip.x + dpi.scale(preview_inset_x, host.ui_scale)),
            .y = @floatFromInt(strip.y + dpi.scale(preview_inset_y, host.ui_scale)),
            .w = w,
            .h = h,
        });
    }

    fn previewFont(self: *ComposerComponent, host: *const types.UiHost, assets: *types.UiAssets) ?*c.TTF_Font {
        const px = dpi.scale(@intFromFloat(font_pt), host.ui_scale);
        if (self.preview_font == null or self.preview_font_px != px) {
            if (self.preview_font) |old| c.TTF_CloseFont(old);
            self.preview_font = c.TTF_OpenFont(preview_font_path, @floatFromInt(px));
            self.preview_font_px = px;
        }
        if (self.preview_font) |font| return font;
        // No system font file: Cadre's own font at the same size.
        const cache = assets.font_cache orelse return null;
        const fonts = cache.get(px) catch return null;
        return fonts.regular;
    }

    /// Lines along the top and bottom of a box row, just outside it (the
    /// native box covers its own rect).
    fn drawRowBorders(renderer: *c.SDL_Renderer, color: c.SDL_Color, row: Rect) void {
        _ = c.SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, 255);
        const x0: f32 = @floatFromInt(row.x);
        const x1: f32 = @floatFromInt(row.x + row.w);
        for ([_]c_int{ row.y - 1, row.y + row.h }) |y_px| {
            const y: f32 = @floatFromInt(y_px);
            _ = c.SDL_RenderLine(renderer, x0, y, x1, y);
        }
    }

    fn hitTestFn(ptr: *anyopaque, _: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        return (self.visible and geom.containsPoint(self.rect, x, y)) or self.overToggle(x, y);
    }

    fn wantsFrameFn(ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        // The slide and the two waits in `place` run on the clock, not on events.
        return self.first_frame.wantsFrame() or self.slide != null or self.spot_held or self.fallback_pending;
    }

    fn deinitFn(ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        if (self.view) |*view| view.destroy();
        if (self.preview_font) |font| c.TTF_CloseFont(font);
        if (self.toggle_tex) |tex| c.SDL_DestroyTexture(tex.tex);
        var it = self.drafts.valueIterator();
        while (it.next()) |text| self.allocator.free(text.*);
        self.drafts.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const testing = std.testing;

test "routeKeyDown: typing and editing stay in the box" {
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_A, 0, false, false));
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_BACKSPACE, 0, true, false));
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_V, c.SDL_KMOD_GUI, false, false)); // paste into an empty box
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_LEFT, c.SDL_KMOD_SHIFT, true, false)); // extend selection
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_RETURN, c.SDL_KMOD_SHIFT, true, false)); // newline
}

test "routeKeyDown: Enter sends text, or reaches Claude when the box is empty" {
    try testing.expectEqual(Route.submit, routeKeyDown(c.SDLK_RETURN, 0, true, false));
    try testing.expectEqual(Route.submit, routeKeyDown(c.SDLK_RETURN, c.SDL_KMOD_GUI, true, false));
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_RETURN, 0, false, false));
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_RETURN, 0, true, true)); // IME/dictation commit
}

test "routeKeyDown: Claude's control keys pass through" {
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_ESCAPE, 0, true, false));
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_C, c.SDL_KMOD_CTRL, true, false));
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_TAB, c.SDL_KMOD_SHIFT, true, false));
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_PAGEUP, 0, true, false));
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_UP, 0, false, false)); // menus/history when empty
    try testing.expectEqual(Route.composer, routeKeyDown(c.SDLK_UP, 0, true, false));
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_W, c.SDL_KMOD_GUI, true, false)); // Cadre shortcut
    try testing.expectEqual(Route.terminal, routeKeyDown(c.SDLK_LEFT, c.SDL_KMOD_SHIFT, false, false)); // pane nav when empty
}

test "composerRect grows with content between one line and 40% of its area" {
    const window = Rect{ .x = 0, .y = 0, .w = 800, .h = 1000 };
    const small = composerRect(window, 0, 1.0);
    try testing.expectEqual(@as(c_int, min_height_pt), small.h);
    try testing.expectEqual(@as(c_int, 1000 - min_height_pt), small.y);
    try testing.expectEqual(@as(c_int, 120), composerRect(window, 120, 1.0).h);
    const tall = composerRect(window, 900, 1.0);
    try testing.expectEqual(@as(c_int, 400), tall.h);
    try testing.expectEqual(@as(c_int, 600), tall.y);
    // A grid tile: docked to the tile's own bottom edge, tile width.
    const tile = Rect{ .x = 400, .y = 300, .w = 390, .h = 260 };
    const in_tile = composerRect(tile, 0, 1.0);
    try testing.expectEqual(@as(c_int, 400), in_tile.x);
    try testing.expectEqual(@as(c_int, 390), in_tile.w);
    try testing.expectEqual(@as(c_int, 300 + 260 - min_height_pt), in_tile.y);
}

fn testHost(sessions: []types.SessionUiInfo) types.UiHost {
    return .{
        .now_ms = 0,
        .window_w = 800,
        .window_h = 600,
        .ui_scale = 1.0,
        .grid_cols = 2,
        .grid_rows = 1,
        .cell_w = 400,
        .cell_h = 600,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Full,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = true,
        .sessions = sessions,
        .theme = undefined,
    };
}

test "boxBackground tints the box red only while the keyboard is away" {
    const theme = colors.Theme.default();
    const home = boxBackground(&theme, false);
    const away = boxBackground(&theme, true);
    try testing.expect(colors.colorsEqual(home, theme.surface(1)));
    try testing.expect(@as(i32, away.r) - away.g > @as(i32, home.r) - home.g);
}

test "dockArea is the whole window in full view, the focused tile above its cwd bar in the grid" {
    var sessions = [_]types.SessionUiInfo{ .{ .dead = false, .spawned = true }, .{ .dead = false, .spawned = true } };
    var host = testHost(&sessions);
    const full = dockArea(&host) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(c_int, 800), full.w);
    try testing.expectEqual(@as(c_int, 600), full.h);

    host.view_mode = .Grid;
    host.focused_session = 1;
    const tile = dockArea(&host) orelse return error.TestUnexpectedResult;
    const border = renderer_mod.grid_border_thickness;
    try testing.expectEqual(@as(c_int, 400 + border), tile.x);
    try testing.expectEqual(@as(c_int, 400 - border * 2), tile.w);
    try testing.expectEqual(@as(c_int, 600 - border * 2), tile.h); // box at the very bottom, id line above it
}

test "tileBoxPx: live box on its tile, a strip on other Claude tiles, nothing on shells" {
    var sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .claude_live = true },
        .{ .dead = false, .spawned = true, .claude_live = true },
        .{ .dead = false, .spawned = true },
    };
    var host = testHost(&sessions);
    host.view_mode = .Grid;
    host.grid_cols = 3;
    host.cell_w = 260;
    const live = LiveBox{ .session = 0, .h = 80 }; // the live box is up on tile 0
    try testing.expectEqual(@as(c_int, 80), tileBoxPx(&host, 0, live));
    try testing.expectEqual(@as(c_int, min_height_pt), tileBoxPx(&host, 1, live));
    try testing.expectEqual(@as(c_int, min_height_pt), tileBoxPx(&host, 0, null)); // box hidden: keep the strip
    try testing.expectEqual(@as(c_int, 0), tileBoxPx(&host, 2, live)); // shell tile
    // The PTY gives up the box and the gap above it, less the id row it already lost.
    const id_row = cwd_bar_metrics.reservedHeight(1.0, renderer_mod.grid_border_thickness);
    try testing.expectEqual(@as(c_int, 80 + status_gap_pt - id_row), tileReservePx(&host, 0, live));
    try testing.expectEqual(@as(c_int, 0), tileReservePx(&host, 2, live));
    host.cell_h = 90; // too small for a box
    try testing.expectEqual(@as(c_int, 0), tileBoxPx(&host, 1, live));
    try testing.expect(dockArea(&host) == null);
}

test "placeBox puts the box a gap under the terminal's last row" {
    var sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .claude_live = true, .term_h_px = 500 },
        .{ .dead = false, .spawned = true, .claude_live = true },
    };
    var host = testHost(&sessions);
    const pad = renderer_mod.terminal_padding;

    // Full view: one line, `status_gap_pt` under the last row (padding + 500 px).
    const box = composerRect(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 0, 1.0);
    const full = placeBox(&host, box, 0);
    try testing.expectEqual(@as(c_int, pad + 500 + status_gap_pt), full.y);
    try testing.expectEqual(box.h, full.h);
    try testing.expectEqual(box.w, full.w);
    // Unknown PTY height: left docked. A PTY far behind a resize: at most two lines up.
    sessions[0].term_h_px = 0;
    try testing.expectEqual(box, placeBox(&host, box, 0));
    sessions[0].term_h_px = 100;
    try testing.expectEqual(box.y - min_height_pt * 2, placeBox(&host, box, 0).y);

    // Grid tile 1: same gap under its rows; the id line takes the row's right end.
    host.view_mode = .Grid;
    host.focused_session = 1;
    const border = renderer_mod.grid_border_thickness;
    const docked_y = 600 - border - min_height_pt;
    sessions[1].term_h_px = docked_y - pad - status_gap_pt - 5; // 5 px spare under the box
    const in_tile = placeBox(&host, box, 100);
    try testing.expectEqual(@as(c_int, docked_y - 5), in_tile.y);
    try testing.expectEqual(@as(c_int, 400 + border), in_tile.x);
    try testing.expectEqual(@as(c_int, 400 - border * 2 - 100), in_tile.w);
    // A very long id gets at most half the row.
    try testing.expectEqual(@divFloor(400 - border * 2, 2), tileBoxRect(&host, 1, min_height_pt, 1000).w);
}

test "on Claude's input box: the box covers its text rows and grows upward" {
    var sessions = [_]types.SessionUiInfo{.{ .dead = false, .spawned = true, .claude_live = true }};
    var host = testHost(&sessions);
    host.term_cols = 80;
    host.term_rows = 40;
    host.full_font = .{ .cell_w = 10, .cell_h = 20, .px = 16, .ascent = 15 };
    const pad = renderer_mod.terminal_padding;
    const pane = surfaceOf(&host, 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Surface{ .x = pad, .y = pad, .bottom = 600, .font = host.full_font, .cols = 80, .rows = 40 }, pane);
    // Rule on row 30, empty prompt on row 31, rule on row 32.
    const spot = PromptBox{ .top_rule = 30, .first = 31, .last = 31 };

    // One line of text (or none yet): exactly Claude's prompt row, right of its mark.
    try testing.expectEqual(@as(c_int, 1), inlineRows(pane, spot, 0));
    try testing.expectEqual(@as(c_int, 1), inlineRows(pane, spot, 21)); // a pixel of rounding
    const one = inlineRect(pane, spot, 1);
    try testing.expectEqual(Rect{ .x = pad + 2 * 10, .y = pad + 31 * 20, .w = 78 * 10, .h = 20 }, one);
    try testing.expect(promptLift(pane, spot, one, 0) == null);

    // Three lines: same bottom edge, two rows taller, and the rule moves up two.
    try testing.expectEqual(@as(c_int, 3), inlineRows(pane, spot, 60));
    const three = inlineRect(pane, spot, 3);
    try testing.expectEqual(one.y + one.h, three.y + three.h);
    try testing.expectEqual(@as(c_int, pad + 29 * 20), three.y);
    try testing.expectEqual(types.PromptLift{ .session = 7, .top_rule = 30, .first = 31, .px = 2 * 20 }, promptLift(pane, spot, three, 7).?);

    // A long draft stops at 40% of the pane's rows; the rest scrolls.
    try testing.expectEqual(@as(c_int, 16), inlineRows(pane, spot, 60 * 20));
    // Near the top of a short screen: a row is left above for the rule.
    try testing.expectEqual(@as(c_int, 2), inlineRows(pane, .{ .top_rule = 1, .first = 2, .last = 2 }, 60 * 20));

    // Claude's own input already has three rows of text: cover them all.
    const grown = PromptBox{ .top_rule = 28, .first = 29, .last = 31 };
    try testing.expectEqual(@as(c_int, 3), inlineRows(pane, grown, 0));
    try testing.expectEqual(@as(c_int, pad + 29 * 20), inlineRect(pane, grown, 3).y);
    try testing.expect(promptLift(pane, grown, inlineRect(pane, grown, 3), 0) == null);
    try testing.expectEqual(@as(c_int, 20), promptLift(pane, grown, inlineRect(pane, grown, 4), 0).?.px);
}

test "on a grid tile the box sits on that tile's rows, in the grid font" {
    var sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .claude_live = true },
        .{ .dead = false, .spawned = true, .claude_live = true },
        .{ .dead = false, .spawned = true, .claude_live = true },
    };
    var host = testHost(&sessions);
    host.view_mode = .Grid;
    host.grid_cols = 2;
    host.grid_rows = 2;
    host.cell_w = 400;
    host.cell_h = 300;
    host.grid_font = .{ .cell_w = 5, .cell_h = 10, .px = 8, .ascent = 8 };
    const pad = renderer_mod.terminal_padding;
    const border = renderer_mod.grid_border_thickness;
    const id_row = cwd_bar_metrics.reservedHeight(1.0, border);

    // Tile 2 is the second row's first: its rows start a padding in from its
    // corner and stop above the id line's row.
    const tile = surfaceOf(&host, 2) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(c_int, pad), tile.x);
    try testing.expectEqual(@as(c_int, 300 + pad), tile.y);
    try testing.expectEqual(@as(c_int, 600 - border), tile.bottom);
    try testing.expectEqual(@divFloor(400 - pad * 2, 5), tile.cols);
    try testing.expectEqual(@divFloor(300 - pad * 2 - id_row, 10), tile.rows);
    try testing.expectEqual(host.grid_font, tile.font);
    // Tile 1 is the first row's second.
    try testing.expectEqual(@as(c_int, 400 + pad), surfaceOf(&host, 1).?.x);

    const spot = PromptBox{ .top_rule = 20, .first = 21, .last = 21 };
    const box = inlineRect(tile, spot, 2);
    try testing.expectEqual(Rect{ .x = pad + 2 * 5, .y = 300 + pad + 20 * 10, .w = (tile.cols - 2) * 5, .h = 20 }, box);
    try testing.expectEqual(@as(c_int, 10), promptLift(tile, spot, box, 2).?.px);
    const toggle = toggleRect(tile, spot) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(c_int, 300 + pad + 22 * 10), toggle.y);
    try testing.expectEqual(pad + (tile.cols - 1) * 5, toggle.x + toggle.w);

    // Turned off, it slides to the tile's bottom edge and is cut off there,
    // never showing on the tile below.
    const half = slidRect(box, 0.5, tile.bottom);
    try testing.expect(half.y > box.y);
    try testing.expect(half.y + half.h <= tile.bottom);
    try testing.expectEqual(@as(c_int, 0), slidRect(box, 1, tile.bottom).h);

    // No grid font known (a caller that never draws on tiles): nothing to sit on.
    host.grid_font = .{};
    try testing.expect(surfaceOf(&host, 2) == null);
}

test "the toggle's slide: the box drops out of its pane and comes back" {
    try testing.expectEqual(@as(f32, 0), slideFraction(0, 1, 0));
    try testing.expectEqual(@as(f32, 1), slideFraction(0, 1, slide_ms));
    try testing.expectEqual(@as(f32, 1), slideFraction(0, 1, slide_ms * 10));
    try testing.expectApproxEqAbs(@as(f32, 0.5), slideFraction(0, 1, @divFloor(slide_ms, 2)), 0.01);
    try testing.expectEqual(@as(f32, 0), slideFraction(1, 0, slide_ms));
    // Turned round a quarter of the way out: back in a quarter of the time.
    try testing.expectEqual(@as(f32, 0), slideFraction(0.25, 0, @divFloor(slide_ms, 4)));
    try testing.expect(slideFraction(0.25, 0, @divFloor(slide_ms, 8)) > 0);
    try testing.expectEqual(@as(f32, 1), slideFraction(1, 1, 0)); // nowhere to go

    // In place at 0; at 1 its top is on the bottom edge, so none of it shows.
    const box = Rect{ .x = 28, .y = 500, .w = 700, .h = 60 };
    try testing.expectEqual(box, slidRect(box, 0, 600));
    try testing.expectEqual(Rect{ .x = 28, .y = 550, .w = 700, .h = 50 }, slidRect(box, 0.5, 600));
    try testing.expectEqual(Rect{ .x = 28, .y = 600, .w = 700, .h = 0 }, slidRect(box, 1, 600));

    // Sliding, a taller box's rule and mark follow it down pixel by pixel until
    // they are back where Claude drew them.
    var sessions = [_]types.SessionUiInfo{.{ .dead = false, .spawned = true, .claude_live = true }};
    var host = testHost(&sessions);
    host.term_cols = 80;
    host.term_rows = 40;
    host.window_h = 1000;
    host.full_font = .{ .cell_w = 10, .cell_h = 20, .px = 16, .ascent = 15 };
    const pane = surfaceOf(&host, 0) orelse return error.TestUnexpectedResult;
    const spot = PromptBox{ .top_rule = 20, .first = 21, .last = 21 };
    const rest = inlineRect(pane, spot, 3);
    try testing.expectEqual(@as(c_int, 40), promptLift(pane, spot, rest, 0).?.px);
    var moved = rest;
    moved.y += 25;
    try testing.expectEqual(@as(c_int, 15), promptLift(pane, spot, moved, 0).?.px);
    moved.y += 25;
    try testing.expect(promptLift(pane, spot, moved, 0) == null);

    // The card: the terminal's background in place, lighter once it is moving.
    const theme = colors.Theme.default();
    try testing.expect(colors.colorsEqual(theme.background, slideBackground(&theme, 0)));
    try testing.expect(colors.colorsEqual(theme.surface(slide_tint_level), slideBackground(&theme, slide_tint_by)));
    try testing.expect(colors.colorsEqual(theme.surface(slide_tint_level), slideBackground(&theme, 1)));
}

test "turning the composer off lasts only for the input box that is up" {
    var sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .claude_live = true, .persist_index = 4 },
        .{ .dead = false, .spawned = true, .claude_live = true, .persist_index = 9 },
    };
    var host = testHost(&sessions);
    host.term_cols = 80;
    host.term_rows = 40;
    host.full_font = .{ .cell_w = 10, .cell_h = 20, .px = 16, .ascent = 15 };
    const box = PromptBox{ .top_rule = 30, .first = 31, .last = 31 };
    sessions[0].prompt_box = box;
    sessions[1].prompt_box = box;
    var composer = ComposerComponent{ .allocator = testing.allocator, .window = undefined, .root = undefined, .view = null };

    try testing.expect(composer.place(&host) == .on_prompt);
    composer.user_hidden = true;
    composer.slid = 1;
    try testing.expect(composer.place(&host) == .none);
    try testing.expect(composer.toggle_rect != null); // still there to turn it back on

    // A dialog takes the input box's place for longer than a redraw, then closes.
    sessions[0].prompt_box = null;
    host.now_ms = spot_grace_ms + 1;
    try testing.expect(composer.place(&host) == .none);
    try testing.expect(composer.toggle_rect == null);
    sessions[0].prompt_box = box;
    try testing.expect(composer.place(&host) == .on_prompt);
    try testing.expect(!composer.user_hidden);

    // Another pane's input box, and this pane's again after the view changed
    // (the box is away while the grid animates in or out).
    composer.user_hidden = true;
    composer.slid = 1;
    host.focused_session = 1;
    try testing.expect(composer.place(&host) == .on_prompt);
    composer.user_hidden = true;
    composer.slid = 1;
    host.view_mode = .Collapsing;
    try testing.expect(composer.place(&host) == .none);
    host.view_mode = .Full;
    try testing.expect(composer.place(&host) == .on_prompt);
    try testing.expectEqual(@as(f32, 0), composer.slid);
}

test "the composer steps aside while Claude's own input holds text" {
    var sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .claude_live = true, .persist_index = 4 },
        .{ .dead = false, .spawned = true, .claude_live = true, .persist_index = 9 },
    };
    var host = testHost(&sessions);
    host.term_cols = 80;
    host.term_rows = 40;
    host.full_font = .{ .cell_w = 10, .cell_h = 20, .px = 16, .ascent = 15 };
    const empty = PromptBox{ .top_rule = 30, .first = 31, .last = 31 };
    const holding = PromptBox{ .top_rule = 28, .first = 29, .last = 31, .typed = true };
    var composer = ComposerComponent{ .allocator = testing.allocator, .window = undefined, .root = undefined, .view = null, .animate = false };

    sessions[0].prompt_box = empty;
    try testing.expect(composer.place(&host) == .on_prompt);
    // The up arrow recalled a message into Claude's input, or a paste landed
    // there: the box would hide it, so it gets out of the way.
    sessions[0].prompt_box = holding;
    try testing.expect(composer.place(&host) == .none);
    try testing.expect(composer.off);
    try testing.expect(composer.toggle_rect != null);
    // The toggle (reading "show") puts the composer over it anyway, and off again.
    composer.flipToggle();
    try testing.expect(composer.place(&host) == .on_prompt);
    composer.flipToggle();
    try testing.expect(composer.place(&host) == .none);
    composer.flipToggle();
    try testing.expect(composer.place(&host) == .on_prompt);
    // Sent or cleared: still up, and the next text there moves it aside again.
    sessions[0].prompt_box = empty;
    try testing.expect(composer.place(&host) == .on_prompt);
    sessions[0].prompt_box = holding;
    try testing.expect(composer.place(&host) == .none);
    sessions[0].prompt_box = empty;
    try testing.expect(composer.place(&host) == .on_prompt);

    // A change on the input box that is up slides; a pane focused with text
    // already in its input starts out of the way, with no slide to sit through.
    composer.animate = true;
    sessions[0].prompt_box = holding;
    try testing.expect(composer.place(&host) == .on_prompt); // still sliding away
    try testing.expect(composer.slide != null);
    sessions[1].prompt_box = holding;
    host.focused_session = 1;
    try testing.expect(composer.place(&host) == .none);
    try testing.expect(composer.slide == null);
    try testing.expectEqual(@as(f32, 1), composer.slid);
}

test "the box is found by its place among the rows on show, and docks only if never found" {
    var sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .claude_live = true },
        .{ .dead = false, .spawned = true, .claude_live = true },
    };
    var host = testHost(&sessions);
    host.view_mode = .Grid;
    host.grid_cols = 2;
    host.cell_w = 400;
    host.cell_h = 600;
    host.grid_font = .{ .cell_w = 5, .cell_h = 10, .px = 8, .ascent = 8 };
    var composer = ComposerComponent{ .allocator = testing.allocator, .window = undefined, .root = undefined, .view = null };
    const rows = (surfaceOf(&host, 0) orelse return error.TestUnexpectedResult).rows;

    // No input box yet: nothing for three seconds, then the docked strips.
    try testing.expect(composer.place(&host) == .none);
    try testing.expectEqual(@as(c_int, 0), composer.gridReservePx(&host, 1));
    host.now_ms = fallback_delay_ms;
    try testing.expect(composer.place(&host) == .docked);
    try testing.expect(composer.fallback_docked);

    // An input box whose rule would fall below the tile's rows is a pane
    // between two sizes: not yet a place to sit.
    sessions[0].prompt_box = .{ .top_rule = @intCast(rows - 2), .first = @intCast(rows - 1), .last = @intCast(rows - 1) };
    try testing.expect(composer.place(&host) == .docked);

    // Found: on the tile's own input box, and no tile gives up rows any more.
    sessions[0].prompt_box = .{ .top_rule = @intCast(rows - 5), .first = @intCast(rows - 4), .last = @intCast(rows - 4) };
    try testing.expect(composer.place(&host) == .on_prompt);
    try testing.expect(!composer.fallback_docked);
    try testing.expectEqual(@as(c_int, 0), composer.gridReservePx(&host, 0));
    try testing.expectEqual(@as(c_int, 0), composer.gridReservePx(&host, 1));
    try testing.expect(composer.idRow(&host, 1) == null); // the id line goes back to its own bar

    // And once one has been found, a missing box is a dialog: the composer waits.
    sessions[0].prompt_box = null;
    host.now_ms += fallback_delay_ms * 2;
    try testing.expect(composer.place(&host) == .none);
}

test "the toggle sits on the rule under Claude's input box, a cell from its right end" {
    var sessions = [_]types.SessionUiInfo{.{ .dead = false, .spawned = true, .claude_live = true }};
    var host = testHost(&sessions);
    host.term_cols = 80;
    host.term_rows = 40;
    host.full_font = .{ .cell_w = 10, .cell_h = 20, .px = 16, .ascent = 15 };
    const pad = renderer_mod.terminal_padding;
    var pane = surfaceOf(&host, 0) orelse return error.TestUnexpectedResult;
    const rect = toggleRect(pane, .{ .top_rule = 30, .first = 31, .last = 31 }) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(c_int, pad + 32 * 20), rect.y);
    try testing.expectEqual(@as(c_int, 20), rect.h);
    try testing.expectEqual(@as(c_int, pad + 79 * 10), rect.x + rect.w); // the last column stays rule
    try testing.expectEqual(toggle_cells * 10, rect.w);
    pane.cols = 6;
    try testing.expect(toggleRect(pane, .{ .top_rule = 30, .first = 31, .last = 31 }) == null);
}

test "firstLine previews the first non-blank line" {
    try testing.expectEqualStrings("hello there", firstLine("\n  hello there  \nsecond line"));
    try testing.expectEqualStrings("", firstLine(" \n\t\n"));
    try testing.expectEqualStrings("one", firstLine("one"));
}

test "normalizeSubmitText trims trailing blanks and rejects whitespace" {
    const out = (try normalizeSubmitText(testing.allocator, "fix it\u{2028}  now\n\n  ")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("fix it\n  now", out);
    try testing.expect((try normalizeSubmitText(testing.allocator, " \n\t ")) == null);
}

test "shouldShow for a live Claude pane in full view or on its grid tile" {
    var sessions = [_]types.SessionUiInfo{.{ .dead = false, .spawned = true, .claude_live = true }};
    var host = types.UiHost{
        .now_ms = 0,
        .window_w = 800,
        .window_h = 600,
        .ui_scale = 1.0,
        .grid_cols = 1,
        .grid_rows = 1,
        .cell_w = 8,
        .cell_h = 16,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Full,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = true,
        .sessions = &sessions,
        .theme = undefined,
    };
    try testing.expect(shouldShow(&host));
    host.view_mode = .Grid;
    try testing.expect(shouldShow(&host));
    host.view_mode = .Expanding;
    try testing.expect(!shouldShow(&host));
    host.view_mode = .Full;
    sessions[0].claude_live = false;
    try testing.expect(!shouldShow(&host));
}
