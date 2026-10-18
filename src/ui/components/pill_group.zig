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
// The tray icon: half a pill, tucked in the very corner.
const tray_margin: c_int = 6;
const tray_size: c_int = 20;
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
                self.tray_hovered = geom.containsPoint(trayRect(host), mx, my);
                self.strip_hovered = geom.containsPoint(stripRect(host), mx, my);
                if (self.tray_hovered or (self.reveal_target > 0 and self.strip_hovered)) self.setRevealTarget(1, host.now_ms);
                return false;
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mx: c_int = @intFromFloat(event.button.x);
                const my: c_int = @intFromFloat(event.button.y);
                if (geom.containsPoint(trayRect(host), mx, my)) {
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
        return self.reveal_target == 0 and geom.containsPoint(trayRect(host), x, y);
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

    /// Two-tone, simplified take on the app icon in the theme's own colors: a
    /// rounded body in the dim text tone, 2x2 background-colored panes, and a
    /// prompt triangle (the icon's ">") cut back into the first pane in the
    /// body tone. Fades out as the pills slide in.
    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        defer self.first_frame.markDrawn();
        const alpha_f = 1.0 - self.reveal(host.now_ms);
        if (alpha_f <= 0.01) return;
        const alpha: u8 = @intFromFloat(alpha_f * 255.0);
        const r = trayRect(host);
        const theme = host.theme;
        const body = theme.chromeTextDim();
        const screen = theme.background;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetRenderDrawColor(renderer, body.r, body.g, body.b, alpha);
        primitives.fillRoundedRect(renderer, r, @divFloor(r.w, 4));
        if (self.tray_hovered) {
            const tint = theme.hoverOverlay();
            _ = c.SDL_SetRenderDrawColor(renderer, tint.r, tint.g, tint.b, @intFromFloat(alpha_f * @as(f32, @floatFromInt(tint.a))));
            primitives.fillRoundedRect(renderer, r, @divFloor(r.w, 4));
        }

        // Panes on the design's 40-unit grid: 12-unit panes at 6 and 21, radius 2.
        const pane = @divFloor(r.w * 12, 40);
        const pane_at = [_]c_int{ @divFloor(r.w * 6, 40), @divFloor(r.w * 21, 40) };
        _ = c.SDL_SetRenderDrawColor(renderer, screen.r, screen.g, screen.b, alpha);
        for (pane_at) |dy| {
            for (pane_at) |dx| {
                primitives.fillRoundedRect(renderer, .{ .x = r.x + dx, .y = r.y + dy, .w = pane, .h = pane }, @divFloor(r.w, 20));
            }
        }

        const px: f32 = @floatFromInt(r.x + pane_at[0]);
        const py: f32 = @floatFromInt(r.y + pane_at[0]);
        const ps: f32 = @floatFromInt(pane);
        const prompt = c.SDL_FColor{
            .r = @as(f32, @floatFromInt(body.r)) / 255.0,
            .g = @as(f32, @floatFromInt(body.g)) / 255.0,
            .b = @as(f32, @floatFromInt(body.b)) / 255.0,
            .a = alpha_f,
        };
        const verts = [3]c.SDL_Vertex{
            .{ .position = .{ .x = px + ps * 0.34, .y = py + ps * 0.26 }, .color = prompt },
            .{ .position = .{ .x = px + ps * 0.34, .y = py + ps * 0.74 }, .color = prompt },
            .{ .position = .{ .x = px + ps * 0.74, .y = py + ps * 0.5 }, .color = prompt },
        };
        const indices = [_]c_int{ 0, 1, 2 };
        _ = c.SDL_RenderGeometry(renderer, null, &verts, 3, &indices, 3);
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
