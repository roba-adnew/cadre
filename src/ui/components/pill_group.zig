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
                const in_strip = self.reveal_target > 0 and geom.containsPoint(stripRect(host), mx, my);
                if (self.tray_hovered or in_strip) self.setRevealTarget(1, host.now_ms);
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
            c.SDL_EVENT_WINDOW_MOUSE_LEAVE => self.tray_hovered = false,
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
        const pointer_in_strip = geom.containsPoint(stripRect(host), host.mouse_x, host.mouse_y);
        if (!self.anyOverlayOpen() and !self.tray_hovered and !pointer_in_strip) {
            self.setRevealTarget(0, host.now_ms);
        } else if (self.anyOverlayOpen()) {
            self.setRevealTarget(1, host.now_ms);
        }
        expanding_overlay.reveal = self.reveal(host.now_ms);
    }

    /// A half-size take on the app icon: light rounded body, 2x2 dark tiles,
    /// accent mark on the first tile. Fades out as the pills slide in.
    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, _: *types.UiAssets) void {
        const self: *PillGroupComponent = @ptrCast(@alignCast(self_ptr));
        defer self.first_frame.markDrawn();
        const alpha_f = 1.0 - self.reveal(host.now_ms);
        if (alpha_f <= 0.01) return;
        const alpha: u8 = @intFromFloat(alpha_f * 255.0);
        const r = trayRect(host);
        const theme = host.theme;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const body = theme.surface(2);
        _ = c.SDL_SetRenderDrawColor(renderer, body.r, body.g, body.b, @intFromFloat(alpha_f * 235.0));
        primitives.fillRoundedRect(renderer, r, @divFloor(r.w, 4));
        if (self.tray_hovered) {
            const tint = theme.hoverOverlay();
            _ = c.SDL_SetRenderDrawColor(renderer, tint.r, tint.g, tint.b, @intFromFloat(alpha_f * @as(f32, @floatFromInt(tint.a))));
            primitives.fillRoundedRect(renderer, r, @divFloor(r.w, 4));
        }

        // Tiles: 2x2 grid with a gutter of 1/10 of the icon.
        const gutter = @max(1, @divFloor(r.w, 10));
        const tile = @divFloor(r.w - 3 * gutter, 2);
        const fg = theme.foreground;
        var row: c_int = 0;
        while (row < 2) : (row += 1) {
            var col: c_int = 0;
            while (col < 2) : (col += 1) {
                const tx = r.x + gutter + col * (tile + gutter);
                const ty = r.y + gutter + row * (tile + gutter);
                _ = c.SDL_SetRenderDrawColor(renderer, fg.r, fg.g, fg.b, @intFromFloat(alpha_f * 90.0));
                _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = @floatFromInt(tx), .y = @floatFromInt(ty), .w = @floatFromInt(tile), .h = @floatFromInt(tile) });
            }
        }
        // Accent mark in the first tile, like the ">" on the real icon.
        const accent = theme.accent;
        const mark = @max(2, @divFloor(tile, 2));
        _ = c.SDL_SetRenderDrawColor(renderer, accent.r, accent.g, accent.b, alpha);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{
            .x = @floatFromInt(r.x + gutter + @divFloor(tile - mark, 2)),
            .y = @floatFromInt(r.y + gutter + @divFloor(tile - mark, 2)),
            .w = @floatFromInt(mark),
            .h = @floatFromInt(mark),
        });
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
