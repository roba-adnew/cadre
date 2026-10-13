const std = @import("std");
const c = @import("../../c.zig");
const types = @import("../types.zig");
const component = @import("../component.zig");
const geom = @import("../../geom.zig");
const dpi = @import("../../dpi.zig");
const primitives = @import("../../gfx/primitives.zig");
const search_utils = @import("search_utils.zig");
const ExpandingOverlay = @import("expanding_overlay.zig").ExpandingOverlay;
const HiddenSwitcherComponent = @import("hidden_switcher.zig").HiddenSwitcherComponent;

/// Top-right count pill for hidden terminals — a fourth indicator next to the
/// help/recent-folders/worktree buttons. Shows the number of hidden terminals and
/// opens the switcher on click; renders nothing when nothing is hidden.
pub const HiddenIndicatorComponent = struct {
    allocator: std.mem.Allocator,
    switcher: *HiddenSwitcherComponent,
    // Slot 3: right after worktree(2)/recent-folders(1)/help(0). Same 40px size and
    // 20px margin as those pills (kept Closed; we only use it for slot positioning).
    overlay: ExpandingOverlay = ExpandingOverlay.init(3, 20, 40, 40, 1),
    hovered: bool = false,

    pub const vtable = component.UiComponent.VTable{
        .handleEvent = handleEvent,
        .hitTest = hitTest,
        .render = render,
    };

    fn pillRect(self: *HiddenIndicatorComponent, host: *const types.UiHost) geom.Rect {
        return self.overlay.rect(host.now_ms, host.window_w, host.window_h, host.ui_scale);
    }

    fn handleEvent(ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, _: *types.UiActionQueue) bool {
        const self: *HiddenIndicatorComponent = @ptrCast(@alignCast(ptr));
        if (types.hiddenCount(host.sessions) == 0) {
            self.hovered = false;
            return false;
        }
        switch (event.type) {
            c.SDL_EVENT_MOUSE_MOTION => {
                const mx: c_int = @intFromFloat(event.motion.x);
                const my: c_int = @intFromFloat(event.motion.y);
                self.hovered = geom.containsPoint(pillRect(self, host), mx, my);
                return false; // hover only; don't swallow motion
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mx: c_int = @intFromFloat(event.button.x);
                const my: c_int = @intFromFloat(event.button.y);
                if (geom.containsPoint(pillRect(self, host), mx, my)) {
                    self.switcher.toggle();
                    return true;
                }
            },
            else => {},
        }
        return false;
    }

    fn hitTest(ptr: *anyopaque, host: *const types.UiHost, x: c_int, y: c_int) bool {
        const self: *HiddenIndicatorComponent = @ptrCast(@alignCast(ptr));
        if (types.hiddenCount(host.sessions) == 0) return false;
        return geom.containsPoint(pillRect(self, host), x, y);
    }

    fn render(ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *HiddenIndicatorComponent = @ptrCast(@alignCast(ptr));
        const n = types.hiddenCount(host.sessions);
        if (n == 0) return; // no hidden terminals -> no pill
        const font_cache = assets.font_cache orelse return;
        const theme = host.theme;
        const rect = pillRect(self, host);
        const radius: c_int = 8;

        // Pill background + border, matching the help/recent-folders/worktree pills.
        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const panel_fill = theme.surface(2);
        _ = c.SDL_SetRenderDrawColor(renderer, panel_fill.r, panel_fill.g, panel_fill.b, 245);
        primitives.fillRoundedRect(renderer, rect, radius);
        if (self.hovered) {
            const hover_tint = theme.hoverOverlay();
            _ = c.SDL_SetRenderDrawColor(renderer, hover_tint.r, hover_tint.g, hover_tint.b, hover_tint.a);
            primitives.fillRoundedRect(renderer, rect, radius);
        }
        // Border adopts the "needs you" attention color (same palette slot as the
        // grid terminal's attention border) when any hidden terminal awaits approval.
        const border = if (types.hiddenNeedsAttention(host.sessions)) theme.palette[3] else theme.accent;
        _ = c.SDL_SetRenderDrawColor(renderer, border.r, border.g, border.b, 255);
        primitives.drawRoundedBorder(renderer, rect, radius);

        const font_size = dpi.scale(@max(12, @min(20, @divFloor(rect.h, 2))), host.ui_scale);
        const fonts = font_cache.get(font_size) catch return;
        var buf: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
        const tex = search_utils.makeTextTexture(self.allocator, renderer, fonts.regular, label, theme.foreground) catch return;
        defer c.SDL_DestroyTexture(tex.tex);
        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(rect.x + @divFloor(rect.w - tex.w, 2)),
            .y = @floatFromInt(rect.y + @divFloor(rect.h - tex.h, 2)),
            .w = @floatFromInt(tex.w),
            .h = @floatFromInt(tex.h),
        });
    }
};
