// Composer: a real text box docked under the focused Claude pane.
//
// Claude Code's own prompt is drawn out of terminal cells: a drag selection
// there can only be copied, and a long paste or dictation collapses into
// "[Pasted text #1 +40 lines]" before it can be edited. The composer is a native
// AppKit text view (composer_view.zig) where the user writes and edits freely;
// Enter hands the whole text to the terminal as one bracketed paste followed by
// Return (UiAction.ComposerSubmit). Keys Claude itself needs (Esc, Ctrl chords,
// Tab/Shift+Tab, PgUp/PgDn, and arrows/Enter while the box is empty) still go
// to the terminal. Clicking the terminal hands the keyboard back to it; clicking
// the box takes it again.

const std = @import("std");
const c = @import("../../c.zig");
const dpi = @import("../../dpi.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const UiRoot = @import("../root.zig").UiRoot;
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const view_mod = @import("composer_view.zig");
const renderer_mod = @import("../../render/renderer.zig");
const cwd_bar_metrics = @import("cwd_bar_metrics.zig");

const log = std.log.scoped(.composer);

const ComposerView = view_mod.ComposerView;
const Rect = geom.Rect;

/// Above the terminal interaction layer, below every menu and overlay so those
/// get keys first while open.
pub const z_index: i32 = 700;
const font_pt: f64 = 14;
const min_height_pt: c_int = 36;

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
/// or on the focused grid tile (not while a tile is being dragged).
pub fn shouldShow(host: *const types.UiHost) bool {
    if (host.view_mode != .Full and host.view_mode != .Grid) return false;
    if (host.view_mode == .Grid and host.tile_drag_active) return false;
    if (host.focused_session >= host.sessions.len) return false;
    const info = host.sessions[host.focused_session];
    return info.spawned and !info.dead and info.claude_live;
}

/// Where the box docks: the whole window in full view, or the focused grid
/// tile above its cwd bar (same tile geometry as cwd_bar.zig). Null when the
/// tile is too small to hold the box with room to spare.
pub fn dockArea(host: *const types.UiHost) ?Rect {
    if (host.view_mode != .Grid) return .{ .x = 0, .y = 0, .w = host.window_w, .h = host.window_h };
    if (host.grid_cols == 0) return null;
    const row: c_int = @intCast(host.focused_session / host.grid_cols);
    const col: c_int = @intCast(host.focused_session % host.grid_cols);
    const border = dpi.scale(renderer_mod.grid_border_thickness, host.ui_scale);
    const bar = dpi.scale(cwd_bar_metrics.height, host.ui_scale);
    const area = Rect{
        .x = col * host.cell_w + border,
        .y = row * host.cell_h + border,
        .w = host.cell_w - border * 2,
        .h = host.cell_h - bar - border * 2,
    };
    if (area.w <= 0 or area.h < dpi.scale(min_height_pt, host.ui_scale) * 3) return null;
    return area;
}

/// Box docked to the bottom of `area`, tall enough for `content_h` (render
/// px), between one line and 40% of the area; past that the text scrolls.
pub fn composerRect(area: Rect, content_h: c_int, ui_scale: f32) Rect {
    const min_h = dpi.scale(min_height_pt, ui_scale);
    const max_h = @max(min_h, @divFloor(area.h * 2, 5));
    const h = std.math.clamp(content_h, min_h, max_h);
    return .{ .x = area.x, .y = area.y + area.h - h, .w = area.w, .h = h };
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
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    theme_key: ?[2]c.SDL_Color = null,
    /// Unsent text of panes not currently shown, by persist_index.
    drafts: std.AutoHashMapUnmanaged(usize, []u8) = .empty,
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
                                c.SDLK_C => view.perform(.copy),
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
        return true;
    }

    fn updateFn(ptr: *anyopaque, host: *const types.UiHost, out: *types.UiActionQueue) void {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        const view = &(self.view orelse return);

        self.pruneDrafts(host);
        const area = dockArea(host);
        var rect = if (area) |a| composerRect(a, self.content_h, host.ui_scale) else self.rect;
        // In the grid the box overlays the tile's bottom rows (Claude's own
        // prompt and status) instead of shrinking its PTY, which would redraw
        // two agents on every tile switch. So it steps aside while Claude is
        // asking something and the box is empty, leaving the question visible.
        const in_grid = host.view_mode == .Grid;
        const asking = in_grid and host.focused_session < host.sessions.len and
            host.sessions[host.focused_session].approval_pending and view.textLength() == 0;
        const show = area != null and shouldShow(host) and !asking and !self.covered(host, rect);

        if (show and self.visible and host.focused_session != self.session) {
            // Pane switched while the box stays up (grid tile or full view): swap drafts.
            self.saveDraft(view);
            self.bindSession(view, host);
            self.focusComposer(view);
        }
        if (show != self.visible) {
            self.visible = show;
            self.first_frame.markTransition();
            log.info("composer {s} (session {d})", .{ if (show) "shown" else "hidden", host.focused_session });
            if (show) {
                self.applyTheme(view, host);
                self.bindSession(view, host);
                view.setHidden(false);
                self.focusComposer(view);
            } else {
                self.saveDraft(view);
                self.draft_key = null;
                if (self.want_focus) self.focusTerminal(view);
                self.yielded = false;
                view.setHidden(true);
            }
        }

        if (self.visible) {
            self.applyTheme(view, host);
            self.syncFocus(view, host);
            view.setFrame(rect, host.window_w, host.window_h);
            self.content_h = view.contentHeightPx(host.window_h);
            if (area) |a| rect = composerRect(a, self.content_h, host.ui_scale);
            view.setFrame(rect, host.window_w, host.window_h);
        }
        self.rect = rect;

        // Only full view shrinks the PTY; the grid box overlays its tile.
        const reserve: c_int = if (self.visible and !in_grid) rect.h else 0;
        if (reserve != self.reported_h) {
            out.append(.{ .SetComposerHeight = reserve }) catch |err| {
                log.warn("failed to queue composer height: {}", .{err});
                return;
            };
            self.reported_h = reserve;
        }
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

    fn applyTheme(self: *ComposerComponent, view: *ComposerView, host: *const types.UiHost) void {
        const theme = host.theme;
        const key = [2]c.SDL_Color{ theme.background, theme.foreground };
        if (self.theme_key) |prev| {
            if (std.meta.eql(prev, key)) return;
        }
        self.theme_key = key;
        const bg = theme.surface(1);
        view.setColors(
            .{ .r = bg.r, .g = bg.g, .b = bg.b },
            .{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b },
            .{ .r = theme.accent.r, .g = theme.accent.g, .b = theme.accent.b },
        );
    }

    fn renderFn(ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        if (!self.visible) return;
        // Hairline over the box; the box itself is the native view.
        const line = host.theme.chromeBorder();
        _ = c.SDL_SetRenderDrawColor(renderer, line.r, line.g, line.b, 255);
        const y: f32 = @floatFromInt(self.rect.y - 1);
        _ = c.SDL_RenderLine(renderer, @floatFromInt(self.rect.x), y, @floatFromInt(self.rect.x + self.rect.w), y);
        self.first_frame.markDrawn();
    }

    fn hitTestFn(ptr: *anyopaque, _: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        return self.visible and geom.containsPoint(self.rect, x, y);
    }

    fn wantsFrameFn(ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        return self.first_frame.wantsFrame();
    }

    fn deinitFn(ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *ComposerComponent = @ptrCast(@alignCast(ptr));
        if (self.view) |*view| view.destroy();
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
    try testing.expectEqual(@as(c_int, 600 - cwd_bar_metrics.height - border * 2), tile.h);

    host.cell_h = 90; // too short for the box plus a usable terminal
    try testing.expect(dockArea(&host) == null);
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
    host.tile_drag_active = true; // a tile is being dragged: the box would be left behind
    try testing.expect(!shouldShow(&host));
    host.tile_drag_active = false;
    host.view_mode = .Expanding;
    try testing.expect(!shouldShow(&host));
    host.view_mode = .Full;
    sessions[0].claude_live = false;
    try testing.expect(!shouldShow(&host));
}
