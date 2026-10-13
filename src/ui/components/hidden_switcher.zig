const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const component = @import("../component.zig");
const colors = @import("../../colors.zig");
const geom = @import("../../geom.zig");
const dpi = @import("../../dpi.zig");
const primitives = @import("../../gfx/primitives.zig");
const search_utils = @import("search_utils.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const log = std.log.scoped(.hidden_switcher);

/// Plenty for any realistic number of hidden terminals (grid caps well below this).
const max_entries = 64;
/// Filter query cap. Folder-name searches never need more; bytes past this are dropped.
const query_cap = 128;

/// Modal picker listing hidden terminals (Cmd+J hides; this reveals). Opens on
/// Cmd+Shift+J, lists each as "agent.folder — ● status" (just "folder" when no
/// agent is running), filters as you type (folder or agent name), and reveals the
/// selected one via a RevealHiddenTerminal action.
pub const HiddenSwitcherComponent = struct {
    allocator: std.mem.Allocator,
    open: bool = false,
    selected: usize = 0,
    query_buf: [query_cap]u8 = undefined,
    query_len: usize = 0,
    first_frame: FirstFrameGuard = .{},

    pub const vtable = component.UiComponent.VTable{
        .handleEvent = handleEvent,
        .render = render,
        .wantsFrame = wantsFrame,
    };

    fn query(self: *const HiddenSwitcherComponent) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    fn openMenu(self: *HiddenSwitcherComponent) void {
        self.open = true;
        self.selected = 0;
        self.query_len = 0;
        self.first_frame.markTransition();
    }

    /// Open/close the menu from the top-right count pill. The pill only exists when
    /// something is hidden, so there's always at least one entry to show.
    pub fn toggle(self: *HiddenSwitcherComponent) void {
        if (self.open) self.close() else self.openMenu();
    }

    fn close(self: *HiddenSwitcherComponent) void {
        if (!self.open) return;
        self.open = false;
        self.selected = 0;
        self.query_len = 0;
        // Force one frame so the scene under the modal redraws cleanly.
        self.first_frame.markTransition();
    }

    fn appendQuery(self: *HiddenSwitcherComponent, text: []const u8) void {
        const room = query_cap - self.query_len;
        const take = @min(room, text.len);
        @memcpy(self.query_buf[self.query_len .. self.query_len + take], text[0..take]);
        self.query_len += take;
        self.selected = 0;
    }

    fn backspaceQuery(self: *HiddenSwitcherComponent) void {
        if (self.query_len == 0) return;
        // Drop one whole UTF-8 codepoint: back over continuation bytes (0b10xxxxxx).
        var i = self.query_len - 1;
        while (i > 0 and (self.query_buf[i] & 0xC0) == 0x80) i -= 1;
        self.query_len = i;
        self.selected = 0;
    }

    fn basenameOf(info: types.SessionUiInfo) []const u8 {
        const b = info.cwd_basename orelse "~";
        return if (b.len == 0) "/" else b;
    }

    /// Max displayed bytes for an auto-generated title before the ellipsis (the
    /// auto-names are ASCII, so bytes == characters here).
    const title_display_cap = 10;
    const ellipsis = "\u{2026}"; // …

    /// Display form of a title. A name you set via /rename has no spaces and is
    /// shown in full; Claude Code's auto-generated names are sentence-like (they
    /// contain spaces), so those are capped at `title_display_cap` + ellipsis.
    fn displayTitle(title: []const u8, buf: []u8) []const u8 {
        if (std.mem.indexOfScalar(u8, title, ' ') == null) return title; // user-set: keep full
        if (title.len <= title_display_cap) return title; // short phrase: keep
        var end: usize = title_display_cap;
        while (end > 0 and title[end] & 0xC0 == 0x80) end -= 1; // back up off a UTF-8 split
        if (end + ellipsis.len > buf.len) return title[0..end];
        @memcpy(buf[0..end], title[0..end]);
        @memcpy(buf[end .. end + ellipsis.len], ellipsis);
        return buf[0 .. end + ellipsis.len];
    }

    /// Row label: "<title>.<folder>" when a title is set, else just "<folder>".
    /// Auto-generated titles are shortened for display; filtering uses the full title.
    fn rowLabel(info: types.SessionUiInfo, buf: []u8) []const u8 {
        const base = basenameOf(info);
        const title = info.agent_name orelse return base;
        var title_buf: [64]u8 = undefined;
        const shown = displayTitle(title, &title_buf);
        return std.fmt.bufPrint(buf, "{s}.{s}", .{ shown, base }) catch |err| blk: {
            log.warn("row label format failed: {}", .{err});
            break :blk base;
        };
    }

    /// Empty `q` matches all; otherwise matches the folder or the agent name
    /// (case-insensitive substring), so typing "claude" or "cadre" both work.
    fn matchesQuery(info: types.SessionUiInfo, q: []const u8) bool {
        if (q.len == 0) return true;
        if (search_utils.findCaseInsensitive(basenameOf(info), q, 0) != null) return true;
        if (info.agent_name) |a| {
            if (search_utils.findCaseInsensitive(a, q, 0) != null) return true;
        }
        return false;
    }

    /// Collect indices of spawned-but-hidden sessions matching `q`, in grid order.
    fn collectHidden(sessions: []const types.SessionUiInfo, q: []const u8, out: *[max_entries]usize) usize {
        var n: usize = 0;
        for (sessions, 0..) |info, i| {
            if (n >= max_entries) break;
            if (!info.isHidden()) continue;
            if (!matchesQuery(info, q)) continue;
            out[n] = i;
            n += 1;
        }
        return n;
    }

    /// Modal geometry, shared by render() and mouse hit-testing so clicks land on
    /// exactly what's drawn. `n` is the filtered row count.
    const Layout = struct { modal: geom.Rect, pad: c_int, gap: c_int, title_h: c_int, search_h: c_int, row_h: c_int, radius: c_int, rows_y0: c_int };

    fn computeLayout(host: *const types.UiHost, n: usize) Layout {
        const s = host.ui_scale;
        const pad = dpi.scale(16, s);
        const row_h = dpi.scale(34, s);
        const title_h = dpi.scale(26, s);
        const search_h = dpi.scale(30, s);
        const gap = dpi.scale(8, s);
        const display_rows: c_int = @max(1, @as(c_int, @intCast(n))); // 1 row reserved for "no matches"
        const modal_w = @min(dpi.scale(460, s), host.window_w - dpi.scale(80, s));
        const modal_h = pad + title_h + gap + search_h + gap + display_rows * row_h + pad;
        const modal_x = @divFloor(host.window_w - modal_w, 2);
        const modal_y = @divFloor(host.window_h - modal_h, 3); // upper third reads better than dead-center
        return .{
            .modal = .{ .x = modal_x, .y = modal_y, .w = modal_w, .h = modal_h },
            .pad = pad,
            .gap = gap,
            .title_h = title_h,
            .search_h = search_h,
            .row_h = row_h,
            .radius = dpi.scale(10, s),
            .rows_y0 = modal_y + pad + title_h + gap + search_h + gap,
        };
    }

    /// Which filtered row (0..n) is under (x, y), or null if not over a row.
    fn rowAt(host: *const types.UiHost, n: usize, x: c_int, y: c_int) ?usize {
        if (n == 0) return null;
        const l = computeLayout(host, n);
        if (x < l.modal.x or x > l.modal.x + l.modal.w or y < l.rows_y0) return null;
        const row: usize = @intCast(@divFloor(y - l.rows_y0, l.row_h));
        return if (row < n) row else null;
    }

    fn handleEvent(ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, out: *types.UiActionQueue) bool {
        const self: *HiddenSwitcherComponent = @ptrCast(@alignCast(ptr));

        // While open, typed characters drive the filter (KEY_DOWN for those keys is
        // swallowed below, so nothing leaks to the focused terminal).
        if (event.type == c.SDL_EVENT_TEXT_INPUT) {
            if (!self.open) return false;
            self.appendQuery(std.mem.span(event.text.text));
            return true;
        }

        // While open, the modal owns the mouse: hovering a row selects it, clicking
        // reveals it, clicking outside dismisses, and everything is swallowed so no
        // click/scroll leaks to the grid behind the dim.
        switch (event.type) {
            c.SDL_EVENT_MOUSE_MOTION => {
                if (!self.open) return false;
                var buf: [max_entries]usize = undefined;
                const n = collectHidden(host.sessions, self.query(), &buf);
                if (rowAt(host, n, @intFromFloat(event.motion.x), @intFromFloat(event.motion.y))) |row| {
                    self.selected = row;
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (!self.open) return false;
                const mx: c_int = @intFromFloat(event.button.x);
                const my: c_int = @intFromFloat(event.button.y);
                var buf: [max_entries]usize = undefined;
                const n = collectHidden(host.sessions, self.query(), &buf);
                if (rowAt(host, n, mx, my)) |row| {
                    out.append(.{ .RevealHiddenTerminal = buf[row] }) catch |err| {
                        log.warn("failed to queue reveal action: {}", .{err});
                    };
                    self.close();
                } else if (!geom.containsPoint(computeLayout(host, n).modal, mx, my)) {
                    self.close(); // click on the dim backdrop dismisses
                }
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_WHEEL => return self.open,
            else => {},
        }

        if (event.type != c.SDL_EVENT_KEY_DOWN) return false;

        const key = event.key.key;
        const mod = event.key.mod;
        const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
        const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
        const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;

        // Cmd+Shift+J toggles the switcher. When nothing is hidden we DON'T consume
        // it, so runtime's handler shows the "No hidden terminals" toast.
        if (has_gui and !has_blocking and has_shift and key == c.SDLK_J) {
            if (self.open) {
                self.close();
                return true;
            }
            var buf: [max_entries]usize = undefined;
            if (collectHidden(host.sessions, "", &buf) == 0) return false;
            self.openMenu();
            return true;
        }

        if (!self.open) return false;

        var buf: [max_entries]usize = undefined;
        const n = collectHidden(host.sessions, self.query(), &buf);
        const sel = if (n == 0) 0 else @min(self.selected, n - 1);

        switch (key) {
            c.SDLK_ESCAPE => self.close(),
            c.SDLK_BACKSPACE => self.backspaceQuery(),
            c.SDLK_UP => if (n > 0) {
                self.selected = if (sel == 0) n - 1 else sel - 1;
            },
            c.SDLK_DOWN => if (n > 0) {
                self.selected = if (sel + 1 >= n) 0 else sel + 1;
            },
            c.SDLK_RETURN, c.SDLK_KP_ENTER => if (n > 0) {
                out.append(.{ .RevealHiddenTerminal = buf[sel] }) catch |err| {
                    log.warn("failed to queue reveal action: {}", .{err});
                };
                self.close();
            },
            else => {}, // swallow other keys to stay modal
        }
        return true;
    }

    /// The word shown for each status (kept marker-free for testability).
    /// Claude hook states win; an idle session shows "hosting" when its
    /// process tree serves a local port, "idle" when Claude ran here before,
    /// and a plain dash when nothing has ever happened.
    fn statusLabel(info: types.SessionUiInfo) []const u8 {
        return switch (info.session_status) {
            .awaiting_approval => "needs you",
            .running => "working",
            .done => "done",
            .idle => if (info.hosting) "hosting" else if (info.claude_seen) "idle" else "\u{2013}", // –
        };
    }

    /// Leading dot: filled = attention/terminal, hollow = in progress/hosting,
    /// mid-dot = idle, none = never-touched dash rows.
    fn statusMarker(info: types.SessionUiInfo) []const u8 {
        return switch (info.session_status) {
            .awaiting_approval => "\u{25CF}", // ●
            .running => "\u{25CB}", // ○
            .done => "\u{25CF}", // ●
            .idle => if (info.hosting) "\u{25CB}" else if (info.claude_seen) "\u{00B7}" else "", // ○ / · / none
        };
    }

    fn statusColor(theme: *const colors.Theme, info: types.SessionUiInfo) c.SDL_Color {
        return switch (info.session_status) {
            .awaiting_approval => theme.palette[3], // yellow
            .running => theme.accent,
            .done => theme.palette[2], // green
            .idle => if (info.hosting) theme.palette[4] else theme.foreground, // blue when hosting
        };
    }

    fn render(ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *HiddenSwitcherComponent = @ptrCast(@alignCast(ptr));
        defer self.first_frame.markDrawn();
        if (!self.open) return;

        var buf: [max_entries]usize = undefined;
        const n = collectHidden(host.sessions, self.query(), &buf);
        // Unfiltered count for the title. Equals n with no filter, else a cheap
        // count rather than a second index-collecting scan.
        const total = if (self.query_len == 0) n else types.hiddenCount(host.sessions);
        if (total == 0) {
            // Nothing is hidden anymore (e.g. revealed elsewhere); dismiss.
            self.open = false;
            return;
        }
        const sel = if (n == 0) 0 else @min(self.selected, n - 1);
        const font_cache = assets.font_cache orelse return;
        const theme = host.theme;
        const ui_scale = host.ui_scale;

        const l = computeLayout(host, n);
        const modal = l.modal;
        const modal_x = modal.x;
        const modal_y = modal.y;
        const modal_w = modal.w;
        const pad = l.pad;
        const gap = l.gap;
        const title_h = l.title_h;
        const search_h = l.search_h;
        const row_h = l.row_h;
        const radius = l.radius;
        const rows_y0 = l.rows_y0;

        // Dim the scene behind the modal.
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const scrim_tint = theme.scrim(120);
        _ = c.SDL_SetRenderDrawColor(renderer, scrim_tint.r, scrim_tint.g, scrim_tint.b, scrim_tint.a);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(host.window_w),
            .h = @floatFromInt(host.window_h),
        });

        const panel_fill = theme.surface(2);
        _ = c.SDL_SetRenderDrawColor(renderer, panel_fill.r, panel_fill.g, panel_fill.b, 245);
        primitives.fillRoundedRect(renderer, modal, radius);
        _ = c.SDL_SetRenderDrawColor(renderer, theme.accent.r, theme.accent.g, theme.accent.b, 230);
        primitives.drawRoundedBorder(renderer, modal, radius);

        const title_fonts = font_cache.get(dpi.scale(18, ui_scale)) catch return;
        var title_buf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Hidden terminals ({d})", .{total}) catch |err| blk: {
            log.warn("title format failed: {}", .{err});
            break :blk "Hidden terminals";
        };
        drawText(self.allocator, renderer, title_fonts.regular, title, theme.foreground, modal_x + pad, modal_y + pad + @divFloor(title_h, 2));

        // Search bar (matches the recent-folders overlay style).
        const search_rect = geom.Rect{
            .x = modal_x + pad,
            .y = modal_y + pad + title_h + gap,
            .w = modal_w - 2 * pad,
            .h = search_h,
        };
        search_utils.renderSearchBar(
            self.allocator,
            renderer,
            host,
            search_rect,
            font_cache,
            self.query(),
            n,
            if (n > 0) sel else null,
        ) catch |err| log.warn("failed to render search bar: {}", .{err});

        const row_fonts = font_cache.get(dpi.scale(16, ui_scale)) catch return;

        if (n == 0) {
            drawText(self.allocator, renderer, row_fonts.regular, "No matches", theme.foreground, modal_x + pad + gap, rows_y0 + @divFloor(row_h, 2));
            return;
        }

        for (0..n) |i| {
            const info = host.sessions[buf[i]];
            const row_y = rows_y0 + @as(c_int, @intCast(i)) * row_h;
            const row_center = row_y + @divFloor(row_h, 2);

            if (i == sel) {
                const hl = geom.Rect{ .x = modal_x + gap, .y = row_y, .w = modal_w - 2 * gap, .h = row_h };
                _ = c.SDL_SetRenderDrawColor(renderer, theme.accent.r, theme.accent.g, theme.accent.b, 60);
                primitives.fillRoundedRect(renderer, hl, dpi.scale(6, ui_scale));
            }

            var label_left_buf: [288]u8 = undefined;
            drawText(self.allocator, renderer, row_fonts.regular, rowLabel(info, &label_left_buf), theme.foreground, modal_x + pad + gap, row_center);

            var label_buf: [48]u8 = undefined;
            const marker = statusMarker(info);
            const label = if (marker.len == 0) statusLabel(info) else std.fmt.bufPrint(&label_buf, "{s} {s}", .{ marker, statusLabel(info) }) catch |err| blk: {
                log.warn("label format failed: {}", .{err});
                break :blk statusLabel(info);
            };
            drawTextRight(self.allocator, renderer, row_fonts.regular, label, statusColor(theme, info), modal_x + modal_w - pad - gap, row_center);
        }
    }

    fn wantsFrame(ptr: *anyopaque, host: *const types.UiHost) bool {
        _ = host;
        const self: *HiddenSwitcherComponent = @ptrCast(@alignCast(ptr));
        return self.open or self.first_frame.wantsFrame();
    }
};

/// Build a one-shot texture for `text` and blit it left-aligned at x, vertically
/// centered on center_y.
/// ponytail: rebuilt every frame the modal is open; it's a short list shown
/// briefly, so a glyph-texture cache isn't worth it yet.
fn drawText(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color, x: c_int, center_y: c_int) void {
    if (text.len == 0) return;
    const tex = search_utils.makeTextTexture(allocator, renderer, font, text, color) catch return;
    defer c.SDL_DestroyTexture(tex.tex);
    _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(x),
        .y = @floatFromInt(center_y - @divFloor(tex.h, 2)),
        .w = @floatFromInt(tex.w),
        .h = @floatFromInt(tex.h),
    });
}

/// Same as drawText but right-aligned to `right_x`.
fn drawTextRight(allocator: std.mem.Allocator, renderer: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color, right_x: c_int, center_y: c_int) void {
    if (text.len == 0) return;
    const tex = search_utils.makeTextTexture(allocator, renderer, font, text, color) catch return;
    defer c.SDL_DestroyTexture(tex.tex);
    _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
        .x = @floatFromInt(right_x - tex.w),
        .y = @floatFromInt(center_y - @divFloor(tex.h, 2)),
        .w = @floatFromInt(tex.w),
        .h = @floatFromInt(tex.h),
    });
}

// --- Tests ---

const test_sessions = [_]types.SessionUiInfo{
    .{ .dead = false, .spawned = true, .hidden = false, .cwd_basename = "visible" }, // 0
    .{ .dead = false, .spawned = true, .hidden = true, .cwd_basename = "cadre", .agent_name = "claude" }, // 1
    .{ .dead = false, .spawned = false, .hidden = true, .cwd_basename = "dead" }, // 2: not spawned
    .{ .dead = false, .spawned = true, .hidden = true, .cwd_basename = "cacha" }, // 3: no agent
};

test "collectHidden picks only spawned+hidden, preserving index order" {
    var buf: [max_entries]usize = undefined;
    const n = HiddenSwitcherComponent.collectHidden(&test_sessions, "", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), buf[0]);
    try std.testing.expectEqual(@as(usize, 3), buf[1]);
}

test "collectHidden filters by folder, case-insensitive" {
    var buf: [max_entries]usize = undefined;
    const n = HiddenSwitcherComponent.collectHidden(&test_sessions, "CAD", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 1), buf[0]);

    try std.testing.expectEqual(@as(usize, 0), HiddenSwitcherComponent.collectHidden(&test_sessions, "zzz", &buf));
}

test "collectHidden filters by agent name too" {
    var buf: [max_entries]usize = undefined;
    const n = HiddenSwitcherComponent.collectHidden(&test_sessions, "claude", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 1), buf[0]); // cadre runs claude
}

test "rowLabel is title.folder, or folder alone without a title" {
    var buf: [288]u8 = undefined;
    try std.testing.expectEqualStrings("claude.cadre", HiddenSwitcherComponent.rowLabel(test_sessions[1], &buf));
    try std.testing.expectEqualStrings("cacha", HiddenSwitcherComponent.rowLabel(test_sessions[3], &buf));
}

test "displayTitle: keep user names full, cap auto-generated (spaced) names" {
    var buf: [64]u8 = undefined;
    // No spaces = a name you set -> always full, even when long.
    try std.testing.expectEqualStrings("backend", HiddenSwitcherComponent.displayTitle("backend", &buf));
    try std.testing.expectEqualStrings("backend-refactor-v2", HiddenSwitcherComponent.displayTitle("backend-refactor-v2", &buf));
    // Spaces = auto-generated sentence -> capped at 10 + ellipsis.
    try std.testing.expectEqualStrings("Fix the lo\u{2026}", HiddenSwitcherComponent.displayTitle("Fix the login bug", &buf));
    // Short phrase (has a space but <= 10 chars) -> left as-is.
    try std.testing.expectEqualStrings("Fix bug", HiddenSwitcherComponent.displayTitle("Fix bug", &buf));
}

test "collectHidden returns 0 when nothing is hidden" {
    const sessions = [_]types.SessionUiInfo{
        .{ .dead = false, .spawned = true, .hidden = false },
        .{ .dead = false, .spawned = false, .hidden = false },
    };
    var buf: [max_entries]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), HiddenSwitcherComponent.collectHidden(&sessions, "", &buf));
}

test "statusLabel covers every status" {
    const base = types.SessionUiInfo{ .dead = false, .spawned = true, .hidden = true };

    var info = base;
    info.session_status = .awaiting_approval;
    try std.testing.expectEqualStrings("needs you", HiddenSwitcherComponent.statusLabel(info));
    info.session_status = .running;
    try std.testing.expectEqualStrings("working", HiddenSwitcherComponent.statusLabel(info));
    info.session_status = .done;
    try std.testing.expectEqualStrings("done", HiddenSwitcherComponent.statusLabel(info));
    info.session_status = .idle;
    try std.testing.expectEqualStrings("\u{2013}", HiddenSwitcherComponent.statusLabel(info));
    info.claude_seen = true;
    try std.testing.expectEqualStrings("idle", HiddenSwitcherComponent.statusLabel(info));
}

test "hosting shows only when no Claude state is active" {
    var info = types.SessionUiInfo{ .dead = false, .spawned = true, .hidden = true, .hosting = true };

    info.session_status = .idle;
    try std.testing.expectEqualStrings("hosting", HiddenSwitcherComponent.statusLabel(info));
    // Claude states take precedence over hosting.
    info.session_status = .running;
    try std.testing.expectEqualStrings("working", HiddenSwitcherComponent.statusLabel(info));
    info.session_status = .done;
    try std.testing.expectEqualStrings("done", HiddenSwitcherComponent.statusLabel(info));
    info.session_status = .awaiting_approval;
    try std.testing.expectEqualStrings("needs you", HiddenSwitcherComponent.statusLabel(info));
}

test "never-touched idle rows have no marker" {
    var info = types.SessionUiInfo{ .dead = false, .spawned = true, .hidden = true };
    info.session_status = .idle;
    try std.testing.expectEqualStrings("", HiddenSwitcherComponent.statusMarker(info));
    info.hosting = true;
    try std.testing.expectEqualStrings("\u{25CB}", HiddenSwitcherComponent.statusMarker(info));
}

test "backspaceQuery removes a whole UTF-8 codepoint" {
    var sw = HiddenSwitcherComponent{ .allocator = std.testing.allocator };
    sw.appendQuery("a\u{00E9}"); // 'a' + 'é' (2 bytes)
    try std.testing.expectEqual(@as(usize, 3), sw.query_len);
    sw.backspaceQuery();
    try std.testing.expectEqualStrings("a", sw.query());
    sw.backspaceQuery();
    try std.testing.expectEqual(@as(usize, 0), sw.query_len);
    sw.backspaceQuery(); // no-op on empty
    try std.testing.expectEqual(@as(usize, 0), sw.query_len);
}
