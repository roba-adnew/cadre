//! Right-click context menu listing the window/terminal shortcuts.
//!
//! Every item except Paste is executed by pushing the equivalent Cmd key
//! event back into SDL's queue (tagged with this window's id), so the
//! existing shortcut handlers run unchanged and nothing is duplicated here.
const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const geom = @import("../../geom.zig");
const dpi = @import("../../dpi.zig");
const colors = @import("../../colors.zig");
const primitives = @import("../../gfx/primitives.zig");
const font_cache = @import("../../font_cache.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const UiComponent = @import("../component.zig").UiComponent;

const log = std.log.scoped(.context_menu);

pub const Item = struct {
    label: []const u8,
    shortcut: []const u8,
    /// SDLK code pushed as Cmd(+Shift)+key; null for the Paste action.
    key: ?u32,
    shift: bool = false,
    separator_before: bool = false,
};

pub const items = [_]Item{
    .{ .label = "Paste", .shortcut = "⌘V", .key = null },
    .{ .label = "New Terminal", .shortcut = "⌘N", .key = c.SDLK_N, .separator_before = true },
    .{ .label = "New Window", .shortcut = "⌘⇧N", .key = c.SDLK_N, .shift = true },
    .{ .label = "Move to Separate Window", .shortcut = "⌘⇧P", .key = c.SDLK_P, .shift = true },
    .{ .label = "Hide Terminal", .shortcut = "⌘J", .key = c.SDLK_J },
    .{ .label = "Close Terminal", .shortcut = "⌘W", .key = c.SDLK_W },
    .{ .label = "Close Window", .shortcut = "⌘⇧W", .key = c.SDLK_W, .shift = true },
    .{ .label = "Worktrees", .shortcut = "⌘T", .key = c.SDLK_T, .separator_before = true },
    .{ .label = "Recent Folders", .shortcut = "⌘O", .key = c.SDLK_O },
    .{ .label = "Git Diff", .shortcut = "⌘D", .key = c.SDLK_D },
    .{ .label = "Reader Mode", .shortcut = "⌘R", .key = c.SDLK_R },
    .{ .label = "Find", .shortcut = "⌘F", .key = c.SDLK_F },
    .{ .label = "Shortcuts", .shortcut = "⌘/", .key = c.SDLK_SLASH },
};

const font_size_points: c_int = 14;
const row_height_points: c_int = 26;
const separator_height_points: c_int = 9;
const pad_x_points: c_int = 14;
const pad_y_points: c_int = 6;
const gap_points: c_int = 28;
const radius_points: c_int = 8;
const min_width_points: c_int = 220;

/// Pure geometry of an open menu, in render pixels.
pub const Layout = struct {
    rect: geom.Rect,
    row_h: c_int,
    sep_h: c_int,
    pad_y: c_int,

    pub fn compute(anchor_x: c_int, anchor_y: c_int, window_w: c_int, window_h: c_int, ui_scale: f32, content_w: c_int) Layout {
        const row_h = dpi.scale(row_height_points, ui_scale);
        const sep_h = dpi.scale(separator_height_points, ui_scale);
        const pad_y = dpi.scale(pad_y_points, ui_scale);
        const w = @max(dpi.scale(min_width_points, ui_scale), content_w + dpi.scale(pad_x_points, ui_scale) * 2);
        var h = pad_y * 2;
        for (items) |item| {
            if (item.separator_before) h += sep_h;
            h += row_h;
        }
        const origin = clampOrigin(anchor_x, anchor_y, w, h, window_w, window_h);
        return .{ .rect = .{ .x = origin.x, .y = origin.y, .w = w, .h = h }, .row_h = row_h, .sep_h = sep_h, .pad_y = pad_y };
    }

    /// Row rectangle for item `idx` (separators are skipped, not rows).
    pub fn rowRect(self: Layout, idx: usize) geom.Rect {
        var y = self.rect.y + self.pad_y;
        for (items, 0..) |item, i| {
            if (item.separator_before) y += self.sep_h;
            if (i == idx) break;
            y += self.row_h;
        }
        return .{ .x = self.rect.x, .y = y, .w = self.rect.w, .h = self.row_h };
    }

    /// Item under a render-pixel point, if any (separators and padding hit nothing).
    pub fn rowAt(self: Layout, x: c_int, y: c_int) ?usize {
        if (!geom.containsPoint(self.rect, x, y)) return null;
        for (items, 0..) |_, i| {
            if (geom.containsPoint(self.rowRect(i), x, y)) return i;
        }
        return null;
    }
};

/// Keep the panel inside the window; flip above/left of the anchor when it
/// would overflow, else pin to the edge.
pub fn clampOrigin(anchor_x: c_int, anchor_y: c_int, w: c_int, h: c_int, window_w: c_int, window_h: c_int) struct { x: c_int, y: c_int } {
    var x = anchor_x;
    var y = anchor_y;
    if (x + w > window_w) x = if (anchor_x - w >= 0) anchor_x - w else @max(0, window_w - w);
    if (y + h > window_h) y = if (anchor_y - h >= 0) anchor_y - h else @max(0, window_h - h);
    return .{ .x = @max(0, x), .y = @max(0, y) };
}

/// The Cmd(+Shift)+key press equivalent to `item`, addressed to `window_id`.
pub fn keyEventFor(item: Item, window_id: c.SDL_WindowID) ?c.SDL_Event {
    const key = item.key orelse return null;
    var event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_KEY_DOWN;
    event.key.windowID = window_id;
    event.key.key = key;
    event.key.mod = @intCast(c.SDL_KMOD_GUI | (if (item.shift) c.SDL_KMOD_SHIFT else 0));
    event.key.down = true;
    return event;
}

const TextTex = struct { tex: ?*c.SDL_Texture = null, w: c_int = 0, h: c_int = 0 };

pub const ContextMenuComponent = struct {
    allocator: std.mem.Allocator,
    /// Set by the owning window once SDL has assigned its id; synthetic key
    /// events are routed by it.
    window_id: c.SDL_WindowID = 0,
    open: bool = false,
    anchor_x: c_int = 0,
    anchor_y: c_int = 0,
    hover: ?usize = null,
    first_frame: FirstFrameGuard = .{},

    labels: [items.len]TextTex = [_]TextTex{.{}} ** items.len,
    shortcuts: [items.len]TextTex = [_]TextTex{.{}} ** items.len,
    cache_scale: f32 = 0,
    cache_generation: u64 = 0,
    cache_light: bool = false,
    content_w: c_int = 0,

    pub fn init(allocator: std.mem.Allocator) !*ContextMenuComponent {
        const comp = try allocator.create(ContextMenuComponent);
        comp.* = .{ .allocator = allocator };
        return comp;
    }

    pub fn asComponent(self: *ContextMenuComponent) UiComponent {
        // Above the terminal interaction layer, below modal dialogs/toasts.
        return .{ .ptr = self, .vtable = &vtable, .z_index = 850 };
    }

    fn layout(self: *const ContextMenuComponent, host: *const types.UiHost) Layout {
        return Layout.compute(self.anchor_x, self.anchor_y, host.window_w, host.window_h, host.ui_scale, self.content_w);
    }

    fn openAt(self: *ContextMenuComponent, x: c_int, y: c_int) void {
        self.open = true;
        self.anchor_x = x;
        self.anchor_y = y;
        self.hover = null;
        self.first_frame.markTransition();
    }

    fn close(self: *ContextMenuComponent) void {
        self.open = false;
        self.hover = null;
        self.first_frame.markTransition();
    }

    /// In grid view, make the right-clicked pane the focused one so the
    /// terminal actions apply to it rather than to the previously focused pane.
    fn selectPaneUnder(host: *const types.UiHost, x: c_int, y: c_int, actions: *types.UiActionQueue) void {
        if (host.view_mode != .Grid or host.cell_w <= 0 or host.cell_h <= 0) return;
        const col: usize = @intCast(@divFloor(x, host.cell_w));
        const row: usize = @intCast(@divFloor(y, host.cell_h));
        if (col >= host.grid_cols or row >= host.grid_rows) return;
        const idx = row * host.grid_cols + col;
        if (idx == host.focused_session or idx >= host.sessions.len) return;
        const info = host.sessions[idx];
        if (!info.spawned or info.hidden) return;
        actions.append(.{ .SelectGridSession = idx }) catch |err| {
            log.warn("failed to queue pane selection: {}", .{err});
        };
    }

    fn execute(self: *ContextMenuComponent, idx: usize, actions: *types.UiActionQueue) void {
        const item = items[idx];
        if (keyEventFor(item, self.window_id)) |event| {
            var ev = event;
            if (!c.SDL_PushEvent(&ev)) {
                log.warn("failed to push shortcut event for '{s}': {s}", .{ item.label, c.SDL_GetError() });
            }
            return;
        }
        actions.append(.PasteIntoFocused) catch |err| {
            log.warn("failed to queue paste action: {}", .{err});
        };
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *ContextMenuComponent = @ptrCast(@alignCast(self_ptr));
        switch (event.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const x: c_int = @intFromFloat(event.button.x);
                const y: c_int = @intFromFloat(event.button.y);
                if (self.open) {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        if (self.layout(host).rowAt(x, y)) |idx| self.execute(idx, actions);
                    }
                    self.close();
                    return true;
                }
                if (event.button.button == c.SDL_BUTTON_RIGHT) {
                    selectPaneUnder(host, x, y, actions);
                    self.openAt(x, y);
                    return true;
                }
                return false;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_WHEEL, c.SDL_EVENT_TEXT_INPUT => return self.open,
            c.SDL_EVENT_MOUSE_MOTION => {
                if (!self.open) return false;
                const x: c_int = @intFromFloat(event.motion.x);
                const y: c_int = @intFromFloat(event.motion.y);
                const next = self.layout(host).rowAt(x, y);
                if (next != self.hover) {
                    self.hover = next;
                    self.first_frame.markTransition();
                }
                return true;
            },
            c.SDL_EVENT_KEY_DOWN => {
                if (!self.open) return false;
                self.close();
                return true;
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                if (self.open) self.close();
                return false;
            },
            else => return false,
        }
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *ContextMenuComponent = @ptrCast(@alignCast(self_ptr));
        return self.open and geom.containsPoint(self.layout(host).rect, x, y);
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *ContextMenuComponent = @ptrCast(@alignCast(self_ptr));
        return self.first_frame.wantsFrame();
    }

    const Palette = struct { panel: c.SDL_Color, border: c.SDL_Color, hover: c.SDL_Color, text: c.SDL_Color, dim: c.SDL_Color };

    fn palette(theme: *const colors.Theme) Palette {
        // Same surface system as every other chrome panel (see Theme.surface).
        var panel_fill = theme.surface(2);
        panel_fill.a = 245;
        return .{
            .panel = panel_fill,
            .border = theme.chromeBorder(),
            .hover = theme.surface(3),
            .text = theme.chromeText(),
            .dim = theme.chromeTextDim(),
        };
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *ContextMenuComponent = @ptrCast(@alignCast(self_ptr));
        defer self.first_frame.markDrawn();
        if (!self.open) return;
        const cache = assets.font_cache orelse return;
        const pal = palette(host.theme);
        self.ensureTextures(renderer, cache, host.ui_scale, pal) catch |err| {
            log.warn("context menu text textures unavailable: {}", .{err});
            return;
        };
        const lay = self.layout(host);
        const radius = dpi.scale(radius_points, host.ui_scale);
        const pad_x = dpi.scale(pad_x_points, host.ui_scale);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, pal.panel.r, pal.panel.g, pal.panel.b, pal.panel.a);
        primitives.fillRoundedRect(renderer, lay.rect, radius);
        primitives.drawThickBorder(renderer, lay.rect, 1, radius, pal.border);

        for (items, 0..) |item, i| {
            const row = lay.rowRect(i);
            if (item.separator_before) {
                const sep_y = row.y - @divFloor(lay.sep_h, 2);
                const sep = c.SDL_FRect{ .x = @floatFromInt(row.x + pad_x), .y = @floatFromInt(sep_y), .w = @floatFromInt(row.w - pad_x * 2), .h = 1 };
                _ = c.SDL_SetRenderDrawColor(renderer, pal.border.r, pal.border.g, pal.border.b, pal.border.a);
                _ = c.SDL_RenderFillRect(renderer, &sep);
            }
            if (self.hover == i) {
                _ = c.SDL_SetRenderDrawColor(renderer, pal.hover.r, pal.hover.g, pal.hover.b, pal.hover.a);
                primitives.fillRoundedRect(renderer, .{ .x = row.x + @divFloor(pad_x, 2), .y = row.y, .w = row.w - pad_x, .h = row.h }, @divFloor(radius, 2));
            }
            blit(renderer, self.labels[i], row.x + pad_x, row.y + @divFloor(row.h - self.labels[i].h, 2));
            const sc = self.shortcuts[i];
            blit(renderer, sc, row.x + row.w - pad_x - sc.w, row.y + @divFloor(row.h - sc.h, 2));
        }
    }

    fn blit(renderer: *c.SDL_Renderer, t: TextTex, x: c_int, y: c_int) void {
        const tex = t.tex orelse return;
        const dst = c.SDL_FRect{ .x = @floatFromInt(x), .y = @floatFromInt(y), .w = @floatFromInt(t.w), .h = @floatFromInt(t.h) };
        _ = c.SDL_RenderTexture(renderer, tex, null, &dst);
    }

    fn ensureTextures(self: *ContextMenuComponent, renderer: *c.SDL_Renderer, cache: *font_cache.FontCache, ui_scale: f32, pal: Palette) !void {
        const light = pal.text.r < 128;
        if (self.cache_scale == ui_scale and self.cache_generation == cache.generation and self.cache_light == light and self.labels[0].tex != null) return;
        self.freeTextures();
        const fonts = try cache.get(dpi.scale(font_size_points, ui_scale));
        var label_w: c_int = 0;
        var shortcut_w: c_int = 0;
        for (items, 0..) |item, i| {
            self.labels[i] = try renderText(renderer, fonts.regular, item.label, pal.text);
            self.shortcuts[i] = try renderText(renderer, fonts.regular, item.shortcut, pal.dim);
            label_w = @max(label_w, self.labels[i].w);
            shortcut_w = @max(shortcut_w, self.shortcuts[i].w);
        }
        self.content_w = label_w + dpi.scale(gap_points, ui_scale) + shortcut_w;
        self.cache_scale = ui_scale;
        self.cache_generation = cache.generation;
        self.cache_light = light;
    }

    fn renderText(renderer: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color) !TextTex {
        var buf: [64]u8 = undefined;
        if (text.len >= buf.len) return error.TextTooLong;
        @memcpy(buf[0..text.len], text);
        buf[text.len] = 0;
        const surface = c.TTF_RenderText_Blended(font, @ptrCast(&buf), text.len, color) orelse return error.SurfaceFailed;
        defer c.SDL_DestroySurface(surface);
        const tex = c.SDL_CreateTextureFromSurface(renderer, surface) orelse return error.TextureFailed;
        _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        return .{ .tex = tex, .w = surface.*.w, .h = surface.*.h };
    }

    fn freeTextures(self: *ContextMenuComponent) void {
        for (&self.labels, &self.shortcuts) |*l, *s| {
            if (l.tex) |t| c.SDL_DestroyTexture(t);
            if (s.tex) |t| c.SDL_DestroyTexture(t);
            l.* = .{};
            s.* = .{};
        }
    }

    fn deinitComp(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *ContextMenuComponent = @ptrCast(@alignCast(self_ptr));
        self.freeTextures();
        self.allocator.destroy(self);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .render = render,
        .hitTest = hitTest,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

test "clampOrigin keeps the panel inside the window" {
    const near_corner = clampOrigin(900, 700, 200, 300, 1000, 800);
    try std.testing.expectEqual(@as(c_int, 700), near_corner.x); // flipped left of the anchor
    try std.testing.expectEqual(@as(c_int, 400), near_corner.y); // flipped above the anchor
    const tiny_window = clampOrigin(50, 50, 200, 300, 150, 250);
    try std.testing.expectEqual(@as(c_int, 0), tiny_window.x); // cannot flip: pinned to the edge
    try std.testing.expectEqual(@as(c_int, 0), tiny_window.y);
    const fits = clampOrigin(10, 20, 200, 300, 1000, 800);
    try std.testing.expectEqual(@as(c_int, 10), fits.x);
    try std.testing.expectEqual(@as(c_int, 20), fits.y);
}

test "Layout.rowAt maps points to items and skips separators" {
    const lay = Layout.compute(10, 10, 2000, 2000, 1.0, 100);
    const first = lay.rowRect(0);
    try std.testing.expectEqual(@as(?usize, 0), lay.rowAt(first.x + 5, first.y + 5));
    // The pixel row just above item 1 lies in its separator: no item.
    const second = lay.rowRect(1);
    try std.testing.expectEqual(@as(?usize, null), lay.rowAt(second.x + 5, second.y - 2));
    try std.testing.expectEqual(@as(?usize, 1), lay.rowAt(second.x + 5, second.y + 1));
    const last = lay.rowRect(items.len - 1);
    try std.testing.expectEqual(@as(?usize, items.len - 1), lay.rowAt(last.x + 5, last.y + last.h - 1));
    try std.testing.expectEqual(@as(?usize, null), lay.rowAt(lay.rect.x + lay.rect.w + 1, first.y));
    try std.testing.expectEqual(lay.rect.y + lay.rect.h, last.y + last.h + lay.pad_y);
}

test "keyEventFor builds the Cmd(+Shift) key press for the window" {
    const new_window = keyEventFor(items[2], 7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, c.SDL_EVENT_KEY_DOWN), new_window.type);
    try std.testing.expectEqual(@as(c.SDL_WindowID, 7), new_window.key.windowID);
    try std.testing.expectEqual(@as(u32, c.SDLK_N), new_window.key.key);
    try std.testing.expect((new_window.key.mod & c.SDL_KMOD_GUI) != 0);
    try std.testing.expect((new_window.key.mod & c.SDL_KMOD_SHIFT) != 0);
    const close_terminal = keyEventFor(items[5], 7) orelse return error.TestUnexpectedResult;
    try std.testing.expect((close_terminal.key.mod & c.SDL_KMOD_SHIFT) == 0);
    try std.testing.expect(keyEventFor(items[0], 7) == null); // Paste is a UiAction, not a key
}
