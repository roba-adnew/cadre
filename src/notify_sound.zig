//! Plays a short macOS system sound for agent notifications (needs-approval /
//! done), so you hear it when Cadre is in the background.
const std = @import("std");
const builtin = @import("builtin");
const SessionStatus = @import("app/app_state.zig").SessionStatus;

const log = std.log.scoped(.notify_sound);

/// System sound for an alerting agent state, or null for states that don't chime.
fn soundPath(state: SessionStatus) ?[]const u8 {
    return switch (state) {
        .awaiting_approval => "/System/Library/Sounds/Ping.aiff",
        .done => "/System/Library/Sounds/Glass.aiff",
        .idle, .running => null,
    };
}

/// Plays the chime for `state` without blocking the caller. No-op off macOS or
/// for non-alerting states. ponytail: afplay + stock system sounds; swap for
/// bundled audio if a branded chime is ever wanted.
pub fn play(allocator: std.mem.Allocator, state: SessionStatus) void {
    if (builtin.os.tag != .macos) return;
    const path = soundPath(state) orelse return;
    // sh backgrounds afplay and exits at once: no render-loop stall, and afplay
    // reparents to launchd so there's no zombie child to reap.
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "afplay '{s}' &", .{path}) catch return;
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        log.warn("failed to play notification sound: {}", .{err});
        return;
    };
    _ = child.wait() catch |err| {
        log.warn("failed to wait on notification sound process: {}", .{err});
    };
}

test "soundPath chimes only for alerting states" {
    try std.testing.expect(soundPath(.awaiting_approval) != null);
    try std.testing.expect(soundPath(.done) != null);
    try std.testing.expectEqual(@as(?[]const u8, null), soundPath(.idle));
    try std.testing.expectEqual(@as(?[]const u8, null), soundPath(.running));
}
