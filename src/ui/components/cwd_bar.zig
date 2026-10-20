const std = @import("std");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const font_cache = @import("../../font_cache.zig");
const renderer_mod = @import("../../render/renderer.zig");
const dpi = @import("../../dpi.zig");
const input = @import("../../input/mapper.zig");
const metrics = @import("cwd_bar_metrics.zig");
const ComposerComponent = @import("composer.zig").ComposerComponent;

const log = std.log.scoped(.cwd_bar);

const Rect = geom.Rect;

const cwd_bar_height = metrics.height;
const cwd_font_size = metrics.font_size;
const cwd_padding = metrics.padding;

pub fn reservedHeight(ui_scale: f32) c_int {
    return metrics.reservedHeight(ui_scale, renderer_mod.grid_border_thickness);
}

pub fn minCellHeight(ui_scale: f32) c_int {
    return metrics.minCellHeight(ui_scale, renderer_mod.grid_border_thickness);
}

pub const CwdBarComponent = struct {
    allocator: std.mem.Allocator,
    font_generation: u64 = 0,
    session_caches: []SessionCache = &.{},
    max_sessions: usize = 0,
    /// On Claude tiles the id goes at the right end of the composer's row
    /// (`ComposerComponent.idRow`) instead of in a bar at the tile's bottom.
    composer: ?*const ComposerComponent = null,

    const SessionCache = struct {
        basename_tex: ?*c.SDL_Texture = null,
        basename_w: c_int = 0,
        basename_h: c_int = 0,
        cached_path: ?[]const u8 = null,
        font_size: c_int = 0,
        /// Width the id took from its row's right end on the last frame.
        id_w: c_int = 0,

        fn deinit(self: *SessionCache, allocator: std.mem.Allocator) void {
            self.invalidate(allocator);
            self.font_size = 0;
        }

        fn invalidate(self: *SessionCache, allocator: std.mem.Allocator) void {
            if (self.basename_tex) |tex| {
                c.SDL_DestroyTexture(tex);
                self.basename_tex = null;
            }
            if (self.cached_path) |path| {
                allocator.free(path);
                self.cached_path = null;
            }
            self.basename_w = 0;
            self.basename_h = 0;
        }
    };

    pub fn init(allocator: std.mem.Allocator) !*CwdBarComponent {
        const self = try allocator.create(CwdBarComponent);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn asComponent(self: *CwdBarComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = 50,
        };
    }

    pub fn destroy(self: *CwdBarComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        for (self.session_caches) |*cache| {
            cache.deinit(self.allocator);
        }
        if (self.session_caches.len > 0) {
            self.allocator.free(self.session_caches);
        }
        self.allocator.destroy(self);
    }

    fn ensureCacheCapacity(self: *CwdBarComponent, count: usize) !void {
        if (count <= self.max_sessions) return;

        const new_caches = try self.allocator.alloc(SessionCache, count);
        @memset(new_caches, SessionCache{});

        if (self.session_caches.len > 0) {
            @memcpy(new_caches[0..self.session_caches.len], self.session_caches);
            self.allocator.free(self.session_caches);
        }

        self.session_caches = new_caches;
        self.max_sessions = count;
    }

    /// Width of session `i`'s id line on the last frame drawn (0 if unknown);
    /// the composer's box in that tile's row stops short of it.
    pub fn idWidthPx(self: *const CwdBarComponent, i: usize) c_int {
        return if (i < self.session_caches.len) self.session_caches[i].id_w else 0;
    }

    fn handleEvent(_: *anyopaque, _: *const types.UiHost, _: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        return false;
    }

    fn update(_: *anyopaque, _: *const types.UiHost, _: *types.UiActionQueue) void {}

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *CwdBarComponent = @ptrCast(@alignCast(self_ptr));

        const cache = assets.font_cache orelse return;
        if (self.font_generation != cache.generation) {
            self.font_generation = cache.generation;
            for (self.session_caches) |*sc| {
                sc.invalidate(self.allocator);
            }
        }

        self.ensureCacheCapacity(host.sessions.len) catch return;

        // CWD bar is only shown in Grid view (not full view or during animations)
        if (host.view_mode != .Grid) return;

        for (host.sessions, 0..) |info, i| {
            if (!info.spawned) continue;
            const grid_row: c_int = @intCast(i / host.grid_cols);
            const grid_col: c_int = @intCast(i % host.grid_cols);
            const cell_rect = Rect{
                .x = grid_col * host.cell_w,
                .y = grid_row * host.cell_h,
                .w = host.cell_w,
                .h = host.cell_h,
            };
            self.renderCwdBar(renderer, i, info, cell_rect, host, cache, i);
        }
    }

    fn renderCwdBar(
        self: *CwdBarComponent,
        renderer: *c.SDL_Renderer,
        session_idx: usize,
        info: types.SessionUiInfo,
        rect: Rect,
        host: *const types.UiHost,
        cache: *font_cache.FontCache,
        grid_index: ?usize,
    ) void {
        const cwd_path = info.cwd_path orelse return;
        const cwd_basename = info.cwd_basename orelse return;

        const bar_height = dpi.scale(cwd_bar_height, host.ui_scale);
        const border_thickness = dpi.scale(renderer_mod.grid_border_thickness, host.ui_scale);
        const padding = dpi.scale(cwd_padding, host.ui_scale);

        if (rect.w <= border_thickness * 2 or rect.h <= bar_height + border_thickness) return;

        const box_row: ?Rect = if (self.composer) |comp| (if (grid_index) |i| comp.idRow(host, i) else null) else null;
        const bar_rect = box_row orelse Rect{
            .x = rect.x + border_thickness,
            .y = rect.y + rect.h - bar_height - border_thickness,
            .w = rect.w - border_thickness * 2,
            .h = bar_height,
        };

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        if (box_row == null) {
            const panel_fill = host.theme.surface(2);
            _ = c.SDL_SetRenderDrawColor(renderer, panel_fill.r, panel_fill.g, panel_fill.b, 230);
            const bg_rect = c.SDL_FRect{
                .x = @floatFromInt(bar_rect.x),
                .y = @floatFromInt(bar_rect.y),
                .w = @floatFromInt(bar_rect.w),
                .h = @floatFromInt(bar_rect.h),
            };
            _ = c.SDL_RenderFillRect(renderer, &bg_rect);
        }

        // Match the terminal text: same typeface (shared font paths) at the grid
        // font's pixel size, clamped so tall fonts still fit inside the bar.
        const font_px = if (host.grid_font_px > 0)
            @max(1, @min(host.grid_font_px, bar_height - dpi.scale(4, host.ui_scale)))
        else
            dpi.scale(cwd_font_size, host.ui_scale);
        const fonts = cache.get(font_px) catch return;
        const cwd_font = fonts.regular;

        const fg = host.theme.foreground;
        const dimmed_fg = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 180 };

        var hotkey_width: c_int = 0;
        if (grid_index) |gi| {
            if (input.terminalHotkeyLabel(gi)) |hotkey_str| {
                const hotkey_surface = c.TTF_RenderText_Blended(cwd_font, hotkey_str.ptr, hotkey_str.len, dimmed_fg) orelse return;
                defer c.SDL_DestroySurface(hotkey_surface);

                const hotkey_texture = c.SDL_CreateTextureFromSurface(renderer, hotkey_surface) orelse return;
                defer c.SDL_DestroyTexture(hotkey_texture);

                var hotkey_w_f: f32 = 0;
                var hotkey_h_f: f32 = 0;
                _ = c.SDL_GetTextureSize(hotkey_texture, &hotkey_w_f, &hotkey_h_f);
                hotkey_width = @intFromFloat(hotkey_w_f);
                const hotkey_height: c_int = @intFromFloat(hotkey_h_f);

                const hotkey_x = bar_rect.x + bar_rect.w - hotkey_width - padding;
                const hotkey_y = bar_rect.y + @divFloor(bar_rect.h - hotkey_height, 2);

                _ = c.SDL_RenderTexture(renderer, hotkey_texture, null, &c.SDL_FRect{
                    .x = @floatFromInt(hotkey_x),
                    .y = @floatFromInt(hotkey_y),
                    .w = hotkey_w_f,
                    .h = hotkey_h_f,
                });
            }
        }

        const text_color = c.SDL_Color{ .r = fg.r, .g = fg.g, .b = fg.b, .a = 255 };
        const hotkey_extra_padding: c_int = if (hotkey_width > 0) padding else 0;

        // The terminal's name (the title the program set, e.g. Claude Code's
        // /rename), drawn in the accent color just left of the command number.
        // Rendered per-frame like the hotkey; only when a name is set.
        var name_width: c_int = 0;
        if (info.agent_name) |name_raw| {
            var name_buf: [32]u8 = undefined;
            const name = clampUtf8(name_raw, &name_buf);
            if (name.len > 0) {
                const accent = host.theme.accent;
                const name_color = c.SDL_Color{ .r = accent.r, .g = accent.g, .b = accent.b, .a = 255 };
                if (c.TTF_RenderText_Blended(cwd_font, name.ptr, name.len, name_color)) |surf| {
                    defer c.SDL_DestroySurface(surf);
                    if (c.SDL_CreateTextureFromSurface(renderer, surf)) |tex| {
                        defer c.SDL_DestroyTexture(tex);
                        var nw: f32 = 0;
                        var nh: f32 = 0;
                        _ = c.SDL_GetTextureSize(tex, &nw, &nh);
                        name_width = @intFromFloat(nw);
                        const name_h: c_int = @intFromFloat(nh);
                        const name_x = bar_rect.x + bar_rect.w - hotkey_width - hotkey_extra_padding - name_width - padding;
                        const name_y = bar_rect.y + @divFloor(bar_rect.h - name_h, 2);
                        _ = c.SDL_RenderTexture(renderer, tex, null, &c.SDL_FRect{
                            .x = @floatFromInt(name_x),
                            .y = @floatFromInt(name_y),
                            .w = nw,
                            .h = nh,
                        });
                    }
                }
            }
        }
        const name_extra_padding: c_int = if (name_width > 0) padding else 0;

        const content_right_edge = bar_rect.x + bar_rect.w - hotkey_width - padding - hotkey_extra_padding - name_width - name_extra_padding;

        var sc = &self.session_caches[session_idx];

        const path_changed = if (sc.cached_path) |cp| !std.mem.eql(u8, cp, cwd_path) else true;
        const font_changed = sc.font_size != font_px;

        if (path_changed or font_changed or sc.basename_tex == null) {
            sc.invalidate(self.allocator);
            sc.font_size = font_px;
            sc.cached_path = self.allocator.dupe(u8, cwd_path) catch |err| blk: {
                log.warn("failed to allocate cached path: {}", .{err});
                break :blk null;
            };

            const basename_surface = c.TTF_RenderText_Blended(cwd_font, cwd_basename.ptr, cwd_basename.len, text_color) orelse return;
            defer c.SDL_DestroySurface(basename_surface);

            const basename_texture = c.SDL_CreateTextureFromSurface(renderer, basename_surface) orelse return;

            var basename_width_f: f32 = 0;
            var basename_height_f: f32 = 0;
            _ = c.SDL_GetTextureSize(basename_texture, &basename_width_f, &basename_height_f);

            sc.basename_tex = basename_texture;
            sc.basename_w = @intFromFloat(basename_width_f);
            sc.basename_h = @intFromFloat(basename_height_f);
        }

        const basename_texture = sc.basename_tex orelse return;
        const basename_width: c_int = sc.basename_w;
        const text_height: c_int = sc.basename_h;
        const basename_width_f: f32 = @floatFromInt(basename_width);
        const basename_height_f: f32 = @floatFromInt(text_height);

        const basename_x = content_right_edge - basename_width;
        sc.id_w = bar_rect.x + bar_rect.w - basename_x + padding;
        const text_y = bar_rect.y + @divFloor(bar_rect.h - text_height, 2);

        // Clip in case a long folder name at a large font outruns the bar.
        const clip_rect = c.SDL_Rect{
            .x = bar_rect.x + padding,
            .y = bar_rect.y,
            .w = @max(0, bar_rect.w - padding * 2),
            .h = bar_rect.h,
        };
        _ = c.SDL_SetRenderClipRect(renderer, &clip_rect);
        _ = c.SDL_RenderTexture(renderer, basename_texture, null, &c.SDL_FRect{
            .x = @floatFromInt(basename_x),
            .y = @floatFromInt(text_y),
            .w = basename_width_f,
            .h = basename_height_f,
        });
        _ = c.SDL_SetRenderClipRect(renderer, null);
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *CwdBarComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .deinit = deinitComp,
    };
};

/// Copy at most `dest.len` bytes of `s` into `dest` without splitting a UTF-8
/// codepoint, returning the copied slice. Used to bound the name width in a tile.
fn clampUtf8(s: []const u8, dest: []u8) []const u8 {
    var n = @min(s.len, dest.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) : (n -= 1) {}
    @memcpy(dest[0..n], s[0..n]);
    return dest[0..n];
}

test "clampUtf8 truncates on a codepoint boundary" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hello", clampUtf8("hello", &buf)); // fits
    try std.testing.expectEqualStrings("abcdefgh", clampUtf8("abcdefghij", &buf)); // ASCII cut at cap
    // "é" is 2 bytes (0xC3 0xA9); a 3-byte cap must not split the 2nd "é".
    var small: [3]u8 = undefined;
    try std.testing.expectEqualStrings("é", clampUtf8("éé", &small)); // 4 bytes -> keep first é (2 bytes)
}
