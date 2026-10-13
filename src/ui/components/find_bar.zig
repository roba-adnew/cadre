//! Cmd+F "find in terminal" overlay.
//!
//! Opens a small search bar (top-right) bound to the focused pane. Typing
//! recomputes case-insensitive substring matches across that pane's scrollback
//! + active area; Enter/Shift+Enter (or Up/Down) jump between them. The "current"
//! match is highlighted by reusing the terminal's own text selection (so it also
//! renders + copies like a normal selection) and the viewport scrolls to it.
//! Esc clears everything and returns to the live prompt.
//!
//! ponytail: matches are highlighted one-at-a-time via the terminal selection
//! (less-style jump-to-match), not an all-matches highlight overlay. Substring
//! only — no regex/cross-row-wrap matching. Upgrade if asked.

const std = @import("std");
const c = @import("../../c.zig");
const ghostty_vt = @import("ghostty-vt");
const dpi = @import("../../dpi.zig");
const geom = @import("../../geom.zig");
const types = @import("../types.zig");
const session_state = @import("../../session/state.zig");
const view_state = @import("../session_view_state.zig");
const search_utils = @import("search_utils.zig");
const UiComponent = @import("../component.zig").UiComponent;
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const log = std.log.scoped(.find_bar);

const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;

/// Bound the per-keystroke scan and result set so a 1-char query over deep
/// scrollback can't stall the UI or balloon memory. ponytail: raise if a real
/// find needs to reach further.
const max_scan_rows: usize = 10_000;
const max_matches: usize = 2_000;

/// A single match as the start/end terminal pins of its (single-row) span.
/// Pins are recomputed on every query edit and before every navigation, so they
/// are always fresh at select/scroll time (never dereferenced while stale).
const Match = struct { start: ghostty_vt.Pin, end: ghostty_vt.Pin };

/// One scanned cell: its lower-cased codepoint and the column it sits in. Built
/// per row so a match's column span maps straight back to terminal pins.
const ScanCell = struct { cp: u21, col: u16 };

pub const FindBarComponent = struct {
    allocator: std.mem.Allocator,
    sessions: []*SessionState,
    views: []SessionViewState,
    first_frame: FirstFrameGuard = .{},

    open: bool = false,
    /// Pane the search is bound to (captured when opened). Stays put even if
    /// focus changes underneath.
    session_idx: usize = 0,

    query: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(Match) = .empty,
    /// Index into `matches` of the highlighted match (top->bottom ordering).
    current: usize = 0,

    // Reused per-scan scratch so searching doesn't allocate per row.
    query_cps: std.ArrayList(u21) = .empty,
    row_cps: std.ArrayList(ScanCell) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        sessions: []*SessionState,
        views: []SessionViewState,
    ) !*FindBarComponent {
        const self = try allocator.create(FindBarComponent);
        self.* = .{
            .allocator = allocator,
            .sessions = sessions,
            .views = views,
        };
        return self;
    }

    pub fn asComponent(self: *FindBarComponent) UiComponent {
        return .{ .ptr = self, .vtable = &vtable, .z_index = 1000 };
    }

    pub fn destroy(self: *FindBarComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        self.query.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.query_cps.deinit(self.allocator);
        self.row_cps.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn focusedTerminal(self: *FindBarComponent) ?*ghostty_vt.Terminal {
        if (self.session_idx >= self.sessions.len) return null;
        const session = self.sessions[self.session_idx];
        if (!session.spawned) return null;
        return if (session.terminal) |*t| t else null;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *FindBarComponent = @ptrCast(@alignCast(self_ptr));

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const key = event.key.key;
                const mod = event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;

                // Cmd+F opens (binding to the currently focused pane).
                if (!self.open) {
                    if (key == c.SDLK_F and has_gui and !has_blocking) {
                        self.openFor(host.focused_session, host.now_ms);
                        return true;
                    }
                    return false;
                }

                // While open, the bar is modal over the terminal, but still
                // lets app-level Cmd shortcuts (quit, etc.) through.
                switch (key) {
                    c.SDLK_ESCAPE => self.close(),
                    c.SDLK_BACKSPACE => {
                        if (self.query.items.len > 0) {
                            // Drop one whole UTF-8 codepoint, not one byte.
                            var n: usize = 1;
                            while (n < self.query.items.len and
                                (self.query.items[self.query.items.len - n] & 0xC0) == 0x80) : (n += 1)
                            {}
                            self.query.items.len -= n;
                            self.recompute(host.now_ms);
                            self.selectCurrent();
                        }
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_UP, c.SDLK_DOWN => {
                        const forward = (key == c.SDLK_DOWN) or
                            ((key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) and has_shift);
                        self.navigate(forward, host.now_ms);
                    },
                    // Pass Cmd-combos (Cmd+Q/Cmd+W/...) to lower handlers; the
                    // letters of the query arrive via TEXT_INPUT, so plain keys
                    // are swallowed here to keep them out of the terminal.
                    else => return !has_gui,
                }
                self.first_frame.markTransition();
                return true;
            },
            c.SDL_EVENT_TEXT_INPUT => {
                if (!self.open) return false;
                const text = std.mem.span(event.text.text);
                self.query.appendSlice(self.allocator, text) catch |err| {
                    log.warn("failed to append find query: {}", .{err});
                };
                self.recompute(host.now_ms);
                self.selectCurrent();
                self.first_frame.markTransition();
                return true;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (!self.open) return false;
                // Click outside the bar dismisses it. Consume the click either way
                // so it doesn't also act on the terminal (closing scrolls back to
                // the live prompt, which would move what's under the cursor).
                const mx: c_int = @intFromFloat(event.button.x);
                const my: c_int = @intFromFloat(event.button.y);
                const r = self.barRect(host);
                const inside = mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h;
                if (!inside) self.close();
                return true;
            },
            else => {},
        }
        return false;
    }

    fn openFor(self: *FindBarComponent, session_idx: usize, now_ms: i64) void {
        self.open = true;
        self.session_idx = session_idx;
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.current = 0;
        self.first_frame.markTransition();
        _ = now_ms;
    }

    /// Close the bar when it is bound to `idx` (the pane is leaving this window).
    pub fn closeIfBoundTo(self: *FindBarComponent, idx: usize) void {
        if (self.open and self.session_idx == idx) self.close();
    }

    fn close(self: *FindBarComponent) void {
        self.open = false;
        // Drop the highlight and return to the live prompt on the bound pane.
        if (self.focusedTerminal()) |terminal| {
            terminal.screens.active.clearSelection();
            terminal.screens.active.pages.scroll(.{ .active = {} });
            if (self.session_idx < self.views.len) {
                self.views[self.session_idx].is_viewing_scrollback = false;
            }
            if (self.session_idx < self.sessions.len) self.sessions[self.session_idx].markDirty();
        }
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
    }

    /// Step to the next/prev match (wrapping) and reveal it.
    fn navigate(self: *FindBarComponent, forward: bool, now_ms: i64) void {
        self.recompute(now_ms); // keep pins fresh + count current
        if (self.matches.items.len == 0) return;
        const len = self.matches.items.len;
        self.current = if (forward)
            (self.current + 1) % len
        else
            (self.current + len - 1) % len;
        self.selectCurrent();
    }

    /// Rebuild the match list from the bound pane. Ordered top->bottom. On a
    /// query change this resets `current` to the bottom-most (newest) match;
    /// during navigation `current` is clamped so the cursor doesn't jump around.
    fn recompute(self: *FindBarComponent, now_ms: i64) void {
        _ = now_ms;
        const prev_len = self.matches.items.len;
        self.matches.clearRetainingCapacity();

        const terminal = self.focusedTerminal() orelse return;
        const pages = &terminal.screens.active.pages;
        const cols: usize = pages.cols;
        const total: usize = pages.total_rows;
        if (cols == 0 or total == 0) return;

        // Decode the query to lower-cased codepoints once.
        self.query_cps.clearRetainingCapacity();
        decodeLower(self.allocator, &self.query_cps, self.query.items);
        const needle = self.query_cps.items;
        if (needle.len == 0) {
            self.current = 0;
            return;
        }

        const start_y: usize = if (total > max_scan_rows) total - max_scan_rows else 0;
        var p = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(start_y) } }) orelse return;

        var truncated = false;
        var y: usize = start_y;
        scan: while (y < total) : (y += 1) {
            // Build this row's lower-cased cells (skipping wide-char tail halves).
            self.row_cps.clearRetainingCapacity();
            var x: u16 = 0;
            while (x < cols) : (x += 1) {
                const rac = p.node.data.getRowAndCell(x, p.y);
                const cell = rac.cell;
                if (cell.wide == .spacer_tail) continue;
                const cp = cellCodepoint(cell);
                self.row_cps.append(self.allocator, .{
                    .cp = lowerCp(if (cp == 0) ' ' else cp),
                    .col = x,
                }) catch |err| {
                    log.warn("find: row buffer alloc failed: {}", .{err});
                    break :scan;
                };
            }

            const row = self.row_cps.items;
            if (row.len >= needle.len) {
                var i: usize = 0;
                while (i + needle.len <= row.len) : (i += 1) {
                    var k: usize = 0;
                    while (k < needle.len) : (k += 1) {
                        if (row[i + k].cp != needle[k]) break;
                    }
                    if (k == needle.len) {
                        var sp = p;
                        sp.x = row[i].col;
                        var ep = p;
                        ep.x = row[i + needle.len - 1].col;
                        self.matches.append(self.allocator, .{ .start = sp, .end = ep }) catch |err| {
                            log.warn("find: match list alloc failed: {}", .{err});
                            break :scan;
                        };
                        if (self.matches.items.len >= max_matches) {
                            truncated = true;
                            break :scan;
                        }
                        i += needle.len - 1; // non-overlapping
                    }
                }
            }

            p = p.down(1) orelse break;
        }

        if (truncated) log.warn("find: capped at {d} matches", .{max_matches});

        // Fresh query (count changed meaningfully) -> jump to the newest match.
        if (self.matches.items.len == 0) {
            self.current = 0;
        } else if (prev_len != self.matches.items.len or self.current >= self.matches.items.len) {
            self.current = self.matches.items.len - 1;
        }
    }

    /// Highlight `matches[current]` as the terminal selection and scroll to it.
    fn selectCurrent(self: *FindBarComponent) void {
        const terminal = self.focusedTerminal() orelse return;
        if (self.current >= self.matches.items.len) {
            terminal.screens.active.clearSelection();
            return;
        }
        const m = self.matches.items[self.current];
        terminal.screens.active.clearSelection();
        terminal.screens.active.select(ghostty_vt.Selection.init(m.start, m.end, false)) catch |err| {
            log.warn("find: failed to select match: {}", .{err});
            return;
        };
        var pages = &terminal.screens.active.pages;
        pages.scroll(.{ .pin = m.start });
        if (self.session_idx < self.views.len) {
            self.views[self.session_idx].is_viewing_scrollback = (pages.viewport != .active);
        }
        if (self.session_idx < self.sessions.len) self.sessions[self.session_idx].markDirty();
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *FindBarComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.open) return false;
        const r = self.barRect(host);
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }

    fn wantsFrame(self_ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *FindBarComponent = @ptrCast(@alignCast(self_ptr));
        return self.open or self.first_frame.wantsFrame();
    }

    /// Search bar rect: top-right, but dropped BELOW the top-right indicator
    /// pills (which live at y=20, height=40) so the bar never overlaps or
    /// z-fights with them.
    fn barRect(_: *FindBarComponent, host: *const types.UiHost) geom.Rect {
        const margin = dpi.scale(12, host.ui_scale);
        const h = dpi.scale(30, host.ui_scale);
        // Clear the pill row: pills start at y=20 and are 40 tall, plus a gap.
        const top = dpi.scale(20 + 40 + 8, host.ui_scale);
        const want_w = dpi.scale(320, host.ui_scale);
        const max_w = host.window_w - margin * 2;
        const w = @min(want_w, @max(max_w, dpi.scale(120, host.ui_scale)));
        return .{ .x = host.window_w - w - margin, .y = top, .w = w, .h = h };
    }

    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *FindBarComponent = @ptrCast(@alignCast(self_ptr));
        if (!self.open) return;
        const font_cache = assets.font_cache orelse return;

        // Reuse the shared search-bar renderer (same look as reader/story search).
        // `selected_match` is null when there are no matches so it shows "0/0".
        const selected: ?usize = if (self.matches.items.len == 0) null else self.current;
        search_utils.renderSearchBar(
            self.allocator,
            renderer,
            host,
            self.barRect(host),
            font_cache,
            self.query.items,
            self.matches.items.len,
            selected,
        ) catch |err| {
            log.warn("find: search bar render failed: {}", .{err});
        };
        self.first_frame.markDrawn();
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *FindBarComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = null,
        .render = render,
        .hitTest = hitTest,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

fn lowerCp(cp: u21) u21 {
    return if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
}

/// Decode UTF-8 `bytes` into lower-cased codepoints appended to `out`.
fn decodeLower(allocator: std.mem.Allocator, out: *std.ArrayList(u21), bytes: []const u8) void {
    var idx: usize = 0;
    while (idx < bytes.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(bytes[idx]) catch |err| blk: {
            log.debug("find: bad utf8 sequence length: {}", .{err});
            break :blk 1;
        };
        const end = @min(idx + seq_len, bytes.len);
        const cp = std.unicode.utf8Decode(bytes[idx..end]) catch |err| blk: {
            log.debug("find: utf8 decode failed: {}", .{err});
            break :blk 0xFFFD;
        };
        out.append(allocator, lowerCp(cp)) catch |err| {
            log.warn("find: failed to buffer query codepoint: {}", .{err});
            return;
        };
        idx = end;
    }
}

/// Read a cell's codepoint honoring `content_tag` (mirrors the guard in
/// session_interaction.zig / renderer.zig): only text cells carry a real
/// codepoint; palette/RGB-background cells store unrelated bits.
fn cellCodepoint(cell: anytype) u21 {
    return if (cell.content_tag == .codepoint or cell.content_tag == .codepoint_grapheme)
        cell.content.codepoint
    else
        0;
}

const testing = std.testing;

test "decodeLower lowercases ASCII and preserves non-ASCII" {
    var out: std.ArrayList(u21) = .empty;
    defer out.deinit(testing.allocator);
    decodeLower(testing.allocator, &out, "AbC édé");
    try testing.expectEqualSlices(u21, &.{ 'a', 'b', 'c', ' ', 0xE9, 'd', 0xE9 }, out.items);
}

test "lowerCp only touches ASCII" {
    try testing.expectEqual(@as(u21, 'a'), lowerCp('A'));
    try testing.expectEqual(@as(u21, 'z'), lowerCp('z'));
    try testing.expectEqual(@as(u21, 0x00C9), lowerCp(0x00C9)); // É unchanged
}
