const std = @import("std");
const runtime = @import("app/runtime.zig");
const logging = @import("logging.zig");

pub const std_options: std.Options = .{
    // Keep compile-time logging permissive; runtime filtering is handled by
    // logging.zig with the user-configured minimum level.
    .log_level = .debug,
    .logFn = logging.logFn,
};

pub fn main() !void {
    try runtime.run();
}

test {
    _ = @import("app/runtime.zig");
    _ = @import("app/layout.zig");
    _ = @import("app/grid_layout.zig");
    _ = @import("ui/components/diff_comment_layout.zig");
    _ = @import("shell.zig");
    _ = @import("ui/components/hidden_switcher.zig");
    _ = @import("ui/components/expanding_overlay.zig");
    _ = @import("ui/components/pill_group.zig");
    _ = @import("anim/easing.zig");
    _ = @import("session/osc_title.zig");
    _ = @import("config.zig");
    _ = @import("colors.zig");
    _ = @import("ui/components/session_interaction.zig");
    _ = @import("input/mapper.zig");
    _ = @import("render/renderer.zig");
    _ = @import("ui/components/find_bar.zig");
    _ = @import("tmux.zig");
    _ = @import("ui/components/cwd_bar.zig");
    _ = @import("session/hosting.zig");
    _ = @import("session/notify.zig");
    _ = @import("ui/types.zig");
    _ = @import("ui/components/context_menu.zig");
    _ = @import("ui/components/composer.zig");
    _ = @import("ui/components/composer_view.zig");
}
