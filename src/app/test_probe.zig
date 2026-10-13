//! End-to-end test observability (opt-in via CADRE_TEST_MODE=1).
//!
//! When enabled, the runtime calls `writeState` once per rendered frame with the
//! per-frame UiHost snapshot. We serialize the parts a UI test cares about (view
//! mode, focused pane, grid size, per-pane state) as JSON to CADRE_STATE_FILE
//! via a temp-file + rename so a reader never sees a torn write. This is a
//! read-only observer of UI state — it never mutates anything — and is a complete
//! no-op in production (the env vars are unset), so it adds zero cost there.
//!
//! It is the "look at what the app is doing" half of the E2E harness; the test
//! script drives input (clicks/keys) and then asserts against this file.
const std = @import("std");
const posix = std.posix;
const ui_mod = @import("../ui/types.zig");

const log = std.log.scoped(.test_probe);

/// True only when the harness asked for test mode. Keep this cheap — it runs per
/// frame — but reading one env var is fine and keeps the gate in one place.
pub fn enabled() bool {
    const v = posix.getenv("CADRE_TEST_MODE") orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

/// Serialize the current UI state to CADRE_STATE_FILE. Best-effort: any
/// failure is logged and swallowed so a flaky test filesystem can never take
/// down the app. No-op unless both the test-mode flag and the target path are set.
pub fn writeState(allocator: std.mem.Allocator, host: *const ui_mod.UiHost) void {
    if (!enabled()) return;
    const path = posix.getenv("CADRE_STATE_FILE") orelse return;
    writeStateInner(allocator, path, host) catch |err| {
        log.warn("failed to write test state to {s}: {}", .{ path, err });
    };
}

fn writeStateInner(allocator: std.mem.Allocator, path: []const u8, host: *const ui_mod.UiHost) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };

    try json.beginObject();
    try json.objectField("mode");
    try json.write(@tagName(host.view_mode));
    try json.objectField("focused_session");
    try json.write(host.focused_session);
    try json.objectField("grid_cols");
    try json.write(host.grid_cols);
    try json.objectField("grid_rows");
    try json.write(host.grid_rows);
    try json.objectField("window_w");
    try json.write(host.window_w);
    try json.objectField("window_h");
    try json.write(host.window_h);
    try json.objectField("sessions");
    try json.beginArray();
    // Only the visible grid cells (slot == array index); the full slot array is
    // 144 entries and almost all unspawned — no point serializing it every frame.
    const visible = @min(host.sessions.len, host.grid_cols * host.grid_rows);
    for (host.sessions[0..visible], 0..) |s, i| {
        try json.beginObject();
        try json.objectField("slot");
        try json.write(i);
        try json.objectField("spawned");
        try json.write(s.spawned);
        try json.objectField("dead");
        try json.write(s.dead);
        try json.objectField("status");
        try json.write(@tagName(s.session_status));
        try json.objectField("cwd");
        if (s.cwd_path) |cwd| {
            try json.write(cwd);
        } else {
            try json.write(null);
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try out.writer.writeByte('\n');

    try writeFileAtomic(allocator, path, out.written());
}

/// Write `bytes` to `path` atomically (temp file + rename) so a concurrent reader
/// always sees either the previous or the new content, never a partial file.
fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);

    {
        var file = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }
    try std.fs.cwd().rename(tmp, path);
}
