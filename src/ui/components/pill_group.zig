const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const HelpOverlayComponent = @import("help_overlay.zig").HelpOverlayComponent;
const WorktreeOverlayComponent = @import("worktree_overlay.zig").WorktreeOverlayComponent;
const RecentFoldersOverlayComponent = @import("recent_folders_overlay.zig").RecentFoldersOverlayComponent;
const HiddenIndicatorComponent = @import("hidden_indicator.zig").HiddenIndicatorComponent;

const expanding_overlay = @import("expanding_overlay.zig");
const ExpandingOverlay = expanding_overlay.ExpandingOverlay;
const geom = @import("../../geom.zig");
const dpi = @import("../../dpi.zig");
const easing = @import("../../anim/easing.zig");
const primitives = @import("../../gfx/primitives.zig");
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

// Pill geometry shared by every pill (see hidden_indicator / help overlays).
const pill_margin: c_int = 20;
const pill_size: c_int = 40;
const max_slots: c_int = 4;
// The tray icon: half a pill, set in from the corner.
const tray_margin: c_int = 12;
const tray_size: c_int = 20;
// The live pane's orange in the app icon (Cadre Dispatch's accent).
const live_pane = c.SDL_Color{ .r = 0xFF, .g = 0xA6, .b = 0x2B, .a = 255 };
const reveal_duration_ms: i64 = 180;

pub const PillGroupComponent = struct {
    allocator: std.mem.Allocator,
    help: *HelpOverlayComponent,
    recent_folders: *RecentFoldersOverlayComponent,
    worktree: *WorktreeOverlayComponent,
    hidden_indicator: *HiddenIndicatorComponent,
    last_help_state: ExpandingOverlay.State = .Closed,
    last_recent_folders_state: ExpandingOverlay.State = .Closed,
    last_worktree_state: ExpandingOverlay.State = .Closed,
    reveal_from: f32 = 0,
    reveal_target: f32 = 0,
    reveal_start_ms: i64 = 0,
    tray_hovered: bool = false,
    strip_hovered: bool = false,
    first_frame: FirstFrameGuard = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        help: *HelpOverlayComponent,
        recent_folders: *RecentFoldersOverlayComponent,
        worktree: *WorktreeOverlayComponent,
        hidden_indicator: *HiddenIndicatorComponent,
    ) !UiComponent {
        const comp = try allocator.create(PillGroupComponent);
        comp.* = .{
            .allocator = allocator,
            .help = help,
            .recent_folders = recent_folders,
            .worktree = worktree,
            .hidden_indicator = hidden_indicator,
        };

        return UiComponent{
            .ptr = comp,
            .vtable = &vtable,
            .z_index = 999,
        };
    }

    fn deinit(self_ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        self.allocator.destroy(self);
    }

    fn trayRect(host: *const types.UiHost) geom.Rect {
        const m = dpi.scale(tray_margin, host.ui_scale);
        const sz = dpi.scale(tray_size, host.ui_scale);
        return .{ .x = host.window_w - m - sz, .y = m, .w = sz, .h = sz };
    }

    /// The icon plus the gap between it and the window's corner, so a pointer
    /// thrown into the corner still lands on the tray.
    fn trayHitRect(host: *const types.UiHost) geom.Rect {
        const r = trayRect(host);
        return .{ .x = r.x, .y = 0, .w = host.window_w - r.x, .h = r.y + r.h };
    }

    const Panes = struct { at: c_int, side: c_int, gap: c_int };

    /// The icon's 2x2 panes on a `w`-wide tile: where the first starts, a
    /// pane's side and the gap between two. From Cadre Dispatch's drawing (a
    /// 20.6-unit tile, 5.5-unit panes 1 apart), with the gap widened a pixel
    /// where that is what centres the panes.
    fn trayPanes(w: c_int) Panes {
        const side = @divFloor(w * 55 + 103, 206);
        var gap: c_int = @max(1, @divFloor(w * 10 + 103, 206));
        if (@mod(w - gap, 2) != 0) gap += 1;
        return .{ .at = @divFloor(w - side * 2 - gap, 2), .side = side, .gap = gap };
    }

    /// The band the revealed pills live in; leaving it slides them away.
    fn stripRect(host: *const types.UiHost) geom.Rect {
        const w = dpi.scale(max_slots * (pill_size + pill_margin) + pill_margin, host.ui_scale);
        const h = dpi.scale(pill_size + 2 * pill_margin, host.ui_scale);
        return .{ .x = host.window_w - w, .y = 0, .w = w, .h = h };
    }

    fn reveal(self: *const PillGroupComponent, now: i64) f32 {
        const elapsed = @as(f32, @floatFromInt(now - self.reveal_start_ms));
        const t = @min(1.0, elapsed / @as(f32, @floatFromInt(reveal_duration_ms)));
        return self.reveal_from + (self.reveal_target - self.reveal_from) * easing.easeInOutCubic(t);
    }

    fn setRevealTarget(self: *PillGroupComponent, target: f32, now: i64) void {
        if (self.reveal_target == target) return;
        self.reveal_from = self.reveal(now);
        self.reveal_target = target;
        self.reveal_start_ms = now;
        self.first_frame.markTransition();
    }

    fn anyOverlayOpen(self: *const PillGroupComponent) bool {
        return self.help.overlay.state != .Closed or
            self.recent_folders.overlay.state != .Closed or
            self.worktree.overlay.state != .Closed;
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        switch (event.type) {
            c.SDL_EVENT_MOUSE_MOTION => {
                const mx: c_int = @intFromFloat(event.motion.x);
                const my: c_int = @intFromFloat(event.motion.y);
                self.tray_hovered = geom.containsPoint(trayHitRect(host), mx, my);
                self.strip_hovered = geom.containsPoint(stripRect(host), mx, my);
                if (self.tray_hovered or (self.reveal_target > 0 and self.strip_hovered)) self.setRevealTarget(1, host.now_ms);
                return false;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mx: c_int = @intFromFloat(event.button.x);
                const my: c_int = @intFromFloat(event.button.y);
                if (geom.containsPoint(trayHitRect(host), mx, my)) {
                    self.setRevealTarget(1, host.now_ms);
                    return true;
                }
            },
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                self.tray_hovered = false;
                self.strip_hovered = false;
            },
            else => {},
        }
        return false;
    }

    fn hitTest(self_ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        return self.reveal_target == 0 and geom.containsPoint(trayHitRect(host), x, y);
    }

    /// Pack the visible pills into consecutive slots (slot 0 = rightmost) so a
    /// hidden pill never leaves a gap. Each pill is conditionally shown — recent
    /// folders only with history, worktree only on-git, the hidden indicator only
    /// when something is hidden — and help is always present. Order right→left:
    /// help, recent folders, worktree, hidden indicator.
    fn assignSlots(self: *PillGroupComponent, host: *const types.UiHost) void {
        var slot: usize = 0;
        self.help.overlay.slot = slot; // always visible
        slot += 1;
        if (self.recent_folders.all_folders.items.len > 0) {
            self.recent_folders.overlay.slot = slot;
            slot += 1;
        }
        if (self.worktree.available or self.worktree.creating or self.worktree.confirming_removal) {
            self.worktree.overlay.slot = slot;
            slot += 1;
        }
        if (types.hiddenCount(host.sessions) > 0) {
            self.hidden_indicator.overlay.slot = slot;
            slot += 1;
        }
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        self.assignSlots(host);

        const help_state = self.help.overlay.state;
        const recent_folders_state = self.recent_folders.overlay.state;
        const worktree_state = self.worktree.overlay.state;

        const help_started_expanding = self.last_help_state != .Expanding and help_state == .Expanding;
        const recent_folders_started_expanding = self.last_recent_folders_state != .Expanding and recent_folders_state == .Expanding;
        const worktree_started_expanding = self.last_worktree_state != .Expanding and worktree_state == .Expanding;

        // When one overlay starts expanding, collapse the others
        if (help_started_expanding) {
            if (recent_folders_state == .Open or recent_folders_state == .Expanding) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state == .Open or worktree_state == .Expanding) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
        }

        if (recent_folders_started_expanding) {
            if (help_state == .Open or help_state == .Expanding) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (worktree_state == .Open or worktree_state == .Expanding) {
                self.worktree.overlay.startCollapsing(host.now_ms);
            }
        }

        if (worktree_started_expanding) {
            if (help_state == .Open or help_state == .Expanding) {
                self.help.overlay.startCollapsing(host.now_ms);
            }
            if (recent_folders_state == .Open or recent_folders_state == .Expanding) {
                self.recent_folders.overlay.startCollapsing(host.now_ms);
            }
        }

        self.last_help_state = help_state;
        self.last_recent_folders_state = recent_folders_state;
        self.last_worktree_state = worktree_state;

        // Slide the strip away once the pointer has left it and nothing is open.
        // Hover comes from motion events: the per-frame host carries no pointer.
        if (!self.anyOverlayOpen() and !self.tray_hovered and !self.strip_hovered) {
            self.setRevealTarget(0, host.now_ms);
        } else if (self.anyOverlayOpen()) {
            self.setRevealTarget(1, host.now_ms);
        }
        expanding_overlay.reveal = self.reveal(host.now_ms);
    }

    /// Cadre Dispatch's toolbar icon, the app icon cut down to a glyph: a
    /// rounded frame in the dim text tone around 2x2 panes, the live one in
    /// its orange and the rest in the frame's tone at 55%. Fades out as the
    /// pills slide in.
    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        defer self.first_frame.markDrawn();
        const alpha_f = 1.0 - self.reveal(host.now_ms);
        if (alpha_f <= 0.01) return;
        const alpha: u8 = @intFromFloat(alpha_f * 255.0);
        const r = trayRect(host);
        const theme = host.theme;
        const frame = theme.chromeTextDim();
        const radius = @divFloor(r.w, 4);

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        if (self.tray_hovered) {
            const tint = theme.hoverOverlay();
            _ = c.SDL_SetRenderDrawColor(renderer, tint.r, tint.g, tint.b, @intFromFloat(alpha_f * @as(f32, @floatFromInt(tint.a))));
            primitives.fillRoundedRect(renderer, r, radius);
        }
        // The drawing's 1.6-unit stroke on its 20.6-unit tile.
        const stroke: c_int = @max(1, @divFloor(r.w * 16 + 103, 206));
        primitives.drawThickBorder(renderer, r, stroke, radius, .{ .r = frame.r, .g = frame.g, .b = frame.b, .a = alpha });

        const panes = trayPanes(r.w);
        const pane_at = [_]c_int{ panes.at, panes.at + panes.side + panes.gap };
        for (pane_at, 0..) |dy, row| {
            for (pane_at, 0..) |dx, col| {
                if (row == 0 and col == 0) {
                    _ = c.SDL_SetRenderDrawColor(renderer, live_pane.r, live_pane.g, live_pane.b, alpha);
                } else {
                    _ = c.SDL_SetRenderDrawColor(renderer, frame.r, frame.g, frame.b, @intFromFloat(alpha_f * 0.55 * 255.0));
                }
                primitives.fillRoundedRect(renderer, .{ .x = r.x + dx, .y = r.y + dy, .w = panes.side, .h = panes.side }, @divFloor(r.w, 20));
            }
        }
    }

    fn wantsFrame(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        const animating = self.reveal(host.now_ms) != self.reveal_target;
        return animating or self.first_frame.wantsFrame();
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        deinit(self_ptr, renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .update = update,
        .render = render,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

test "the tray icon's panes are centred at every scale" {
    for ([_]c_int{ 20, 30, 40, 60 }) |w| {
        const p = PillGroupComponent.trayPanes(w);
        try std.testing.expect(p.side > 0 and p.gap > 0 and p.at > 0);
        try std.testing.expectEqual(w, p.at * 2 + p.side * 2 + p.gap);
    }
    // 1x and 2x: the drawing's proportions, to the pixel.
    try std.testing.expectEqual(PillGroupComponent.Panes{ .at = 4, .side = 5, .gap = 2 }, PillGroupComponent.trayPanes(20));
    try std.testing.expectEqual(PillGroupComponent.Panes{ .at = 8, .side = 11, .gap = 2 }, PillGroupComponent.trayPanes(40));
}

test "the gap between the tray icon and the window's corner counts as the tray" {
    const theme = @import("../../colors.zig").Theme.default();
    const host = types.UiHost{
        .now_ms = 0,
        .window_w = 1200,
        .window_h = 800,
        .ui_scale = 1.0,
        .grid_cols = 1,
        .grid_rows = 1,
        .cell_w = 0,
        .cell_h = 0,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Grid,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = false,
        .sessions = &.{},
        .theme = &theme,
    };
    const icon = PillGroupComponent.trayRect(&host);
    try std.testing.expectEqual(@as(c_int, tray_size), icon.w); // the size is unchanged
    try std.testing.expectEqual(@as(c_int, tray_margin), icon.y);
    try std.testing.expectEqual(@as(c_int, 1200 - tray_margin), icon.x + icon.w);
    const hit = PillGroupComponent.trayHitRect(&host);
    try std.testing.expect(geom.containsPoint(hit, 1199, 0)); // the very corner
    try std.testing.expect(geom.containsPoint(hit, icon.x, icon.y + icon.h - 1));
    try std.testing.expect(!geom.containsPoint(hit, icon.x - 1, icon.y));
    try std.testing.expect(!geom.containsPoint(hit, icon.x, icon.y + icon.h));
}

test "pill strip stays revealed after the pointer leaves the tray for a pill" {
    const colors = @import("../../colors.zig");
    const alloc = std.testing.allocator;
    var help = HelpOverlayComponent{ .allocator = alloc };
    var recent = RecentFoldersOverlayComponent{ .allocator = alloc };
    var worktree = WorktreeOverlayComponent{ .allocator = alloc };
    var hidden = HiddenIndicatorComponent{ .allocator = alloc, .switcher = undefined };
    var group = PillGroupComponent{ .allocator = alloc, .help = &help, .recent_folders = &recent, .worktree = &worktree, .hidden_indicator = &hidden };
    var queue = types.UiActionQueue.init(alloc);
    defer queue.deinit();
    const theme = colors.Theme.default();
    var host = types.UiHost{
        .now_ms = 0,
        .window_w = 1200,
        .window_h = 800,
        .ui_scale = 1.0,
        .grid_cols = 1,
        .grid_rows = 1,
        .cell_w = 0,
        .cell_h = 0,
        .term_cols = 80,
        .term_rows = 24,
        .view_mode = .Grid,
        .focused_session = 0,
        .focused_cwd = null,
        .focused_has_foreground_process = false,
        .sessions = &.{},
        .theme = &theme,
    };
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.motion.type = c.SDL_EVENT_MOUSE_MOTION;

    // Hover the tray, then move onto the first pill (left of and below it).
    const tray = PillGroupComponent.trayRect(&host);
    ev.motion.x = @floatFromInt(tray.x + 2);
    ev.motion.y = @floatFromInt(tray.y + 2);
    _ = PillGroupComponent.handleEvent(&group, &host, &ev, &queue);
    PillGroupComponent.update(&group, &host, &queue);
    ev.motion.x = @floatFromInt(host.window_w - 40);
    ev.motion.y = 50;
    _ = PillGroupComponent.handleEvent(&group, &host, &ev, &queue);
    host.now_ms = 1000;
    PillGroupComponent.update(&group, &host, &queue);
    try std.testing.expectEqual(@as(f32, 1), group.reveal_target);

    // Leaving the strip slides it away.
    ev.motion.x = 10;
    ev.motion.y = 400;
    _ = PillGroupComponent.handleEvent(&group, &host, &ev, &queue);
    PillGroupComponent.update(&group, &host, &queue);
    try std.testing.expectEqual(@as(f32, 0), group.reveal_target);
}
