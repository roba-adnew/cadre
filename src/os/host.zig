//! Cadre-signed process host (`cadre host <program> [args...]`). See ADR-016.
//!
//! macOS charges a process's protected-folder access (TCC: ~/Documents etc.)
//! to its "responsible process", fixed at spawn and inherited by every
//! descendant. Pane shells live in a tmux server that outlives Cadre, so they
//! were charged to whichever Cadre started that server; once it quit, the
//! kernel denied ~/Documents to every pane with no prompt.
//!
//! The host re-execs itself with responsibility disclaimed, becoming its own
//! responsible process under Cadre's code identity (so Cadre's existing grant
//! applies), then runs `program` as its child and lives exactly as long. Pane
//! shells and each `claude` launch get their own host: a process whose binary is
//! deleted while running (Claude Code's auto-update does this) poisons TCC for
//! its responsible process until that process exits, so one host per agent
//! confines the damage to that agent instead of the whole tree.
//!
//! Hosts run from a versioned copy of the bundle (`prepareHostExe`), never from
//! /Applications/Cadre.app: a reload replaces that bundle, and a host whose
//! binary is deleted is poisoned the same way.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.host);

pub const subcommand = "host";
/// Set across the self re-exec so the re-exec'd image knows it is disclaimed;
/// removed before the child starts so a nested host disclaims for itself.
const disclaimed_env = "CADRE_HOST_DISCLAIMED";
/// Pane environment variable naming the host executable (read by the `claude`
/// wrapper in the Cadre command dir).
pub const env_var = "CADRE_HOST";

const is_macos = builtin.os.tag == .macos;

const c = if (is_macos) @cImport({
    @cInclude("spawn.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
}) else struct {};

// libquarantine (part of libSystem). Not in public headers, but used by
// Chromium, LLDB and Qt Creator for exactly this.
extern "c" fn responsibility_spawnattrs_setdisclaim(attrs: *c.posix_spawnattr_t, disclaim: c_int) c_int;

const posix_spawn_setexec: c_short = 0x0040; // POSIX_SPAWN_SETEXEC (Apple)

pub fn isHostInvocation(argv: []const [*:0]const u8) bool {
    return argv.len >= 3 and std.mem.eql(u8, std.mem.span(argv[1]), subcommand);
}

/// Entry point for `cadre host <program> [args...]`. Never returns. Silent on
/// failure (stderr is the pane): falls back to running the program unhosted.
pub fn run(argv: [][*:0]u8) noreturn {
    if (!is_macos) execOrDie(argv[2..]);
    if (c.getenv(disclaimed_env) == null) {
        reexecDisclaimed(argv); // returns only on failure
    } else {
        _ = c.unsetenv(disclaimed_env);
    }
    installForwarders();
    const pid = spawnChild(argv[2..]) orelse execOrDie(argv[2..]);
    @atomicStore(posix.pid_t, &child_pid, pid, .seq_cst);
    const result = posix.waitpid(pid, 0);
    exitLike(result.status);
}

fn reexecDisclaimed(argv: [][*:0]u8) void {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch return;
    if (self_path.len >= self_buf.len) return;
    self_buf[self_path.len] = 0;
    const self_z: [*:0]const u8 = @ptrCast(self_path.ptr);

    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return;
    defer _ = c.posix_spawnattr_destroy(&attr);
    if (c.posix_spawnattr_setflags(&attr, posix_spawn_setexec) != 0) return;
    if (responsibility_spawnattrs_setdisclaim(&attr, 1) != 0) return;
    if (c.setenv(disclaimed_env, "1", 1) != 0) return;

    var pid: c.pid_t = 0;
    // On success SETEXEC replaces this image in place (same pid), so the
    // caller (tmux, a shell job) keeps waiting on the same process.
    _ = c.posix_spawn(&pid, self_z, null, &attr, @ptrCast(argv.ptr), @ptrCast(std.c.environ));
    _ = c.unsetenv(disclaimed_env);
}

fn spawnChild(args: [][*:0]u8) ?posix.pid_t {
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return null;
    defer _ = c.posix_spawnattr_destroy(&attr);
    // Start the program with default dispositions and an empty mask, whatever
    // the host itself has installed.
    var all: c.sigset_t = undefined;
    var none: c.sigset_t = undefined;
    _ = c.sigfillset(&all);
    _ = c.sigemptyset(&none);
    _ = c.posix_spawnattr_setsigdefault(&attr, &all);
    _ = c.posix_spawnattr_setsigmask(&attr, &none);
    _ = c.posix_spawnattr_setflags(&attr, @intCast(c.POSIX_SPAWN_SETSIGDEF | c.POSIX_SPAWN_SETSIGMASK));

    var pid: c.pid_t = 0;
    if (c.posix_spawnp(&pid, args[0], null, &attr, @ptrCast(args.ptr), @ptrCast(std.c.environ)) != 0) return null;
    return pid;
}

var child_pid: posix.pid_t = 0;

/// The host shares the child's process group, so keyboard signals (Ctrl+C)
/// reach the child directly; forwarding those too would double them (Claude
/// quits on a second Ctrl+C). macOS marks both kinds alike (si_code 0), but a
/// keyboard signal's si_pid is the process that wrote the key into the
/// terminal (tmux server, or Cadre), which lives in another session, while a
/// `kill -INT <host>` from inside the pane (claude-hup-shim.sh) comes from this
/// session. HUP and TERM are always forwarded: a pane's host is the session
/// leader, the only process the kernel hangs up when the pane closes.
pub fn shouldForward(sig: c_int, sender_pid: posix.pid_t, child: posix.pid_t, sender_in_session: bool) bool {
    if (sig == posix.SIG.HUP or sig == posix.SIG.TERM) return true;
    return sender_pid > 0 and sender_pid != child and sender_in_session;
}

extern "c" fn getsid(pid: posix.pid_t) posix.pid_t;

fn forwardSignal(sig: c_int, info: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const pid = @atomicLoad(posix.pid_t, &child_pid, .seq_cst);
    if (pid <= 0) return;
    const sender_sid = if (info.pid > 0) getsid(info.pid) else -1;
    const in_session = sender_sid >= 0 and sender_sid == getsid(0);
    if (shouldForward(sig, info.pid, pid, in_session)) _ = std.c.kill(pid, sig);
}

fn installForwarders() void {
    const action = posix.Sigaction{
        .handler = .{ .sigaction = forwardSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART,
    };
    for ([_]u8{ posix.SIG.HUP, posix.SIG.TERM, posix.SIG.INT, posix.SIG.QUIT, posix.SIG.USR1, posix.SIG.USR2 }) |sig| {
        posix.sigaction(sig, &action, null);
    }
}

/// Exit with the child's status; a child killed by a signal is mirrored by
/// dying of the same signal, so shells report it the same way.
fn exitLike(status: u32) noreturn {
    if (posix.W.IFEXITED(status)) std.c.exit(posix.W.EXITSTATUS(status));
    if (posix.W.IFSIGNALED(status)) {
        const sig: u8 = @intCast(posix.W.TERMSIG(status));
        const default = posix.Sigaction{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(sig, &default, null);
        _ = std.c.kill(std.c.getpid(), sig);
        std.c.exit(128 + @as(c_int, sig));
    }
    std.c.exit(1);
}

fn execOrDie(args: [][*:0]u8) noreturn {
    // argv comes from std.os.argv, so the slice is followed by its NULL entry.
    // No log on failure: stderr is the pane. 127 is the shell's "not found".
    posix.execvpeZ(args[0], @ptrCast(args.ptr), @ptrCast(std.c.environ)) catch std.c._exit(127);
}

// --- Versioned host copy (runs inside the Cadre app process) ---

/// Absolute path of the host executable for this build, copying the running
/// bundle to `~/Library/Application Support/Cadre/host/<build>/` first if
/// needed, and deleting older copies no process still runs from. Unbundled dev
/// builds borrow the newest existing copy. Null when unavailable (not macOS, no
/// copy yet, copy failed): panes then run unhosted, exactly as before.
pub fn prepareHostExe(allocator: std.mem.Allocator) ?[:0]u8 {
    if (!is_macos) return null;
    const home = posix.getenv("HOME") orelse return null;
    const base = std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Cadre", "host" }) catch return null;
    defer allocator.free(base);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&exe_buf) catch |err| {
        log.warn("host: can't resolve own executable: {}", .{err});
        return null;
    };
    const bundle = bundleRoot(exe) orelse return newestCopy(allocator, base);

    const stat = std.fs.cwd().statFile(exe) catch |err| {
        log.warn("host: can't stat {s}: {}", .{ exe, err });
        return null;
    };
    var id_buf: [64]u8 = undefined;
    const id = buildId(&id_buf, stat.size, stat.mtime) catch return null;
    const bundle_parent = std.fs.path.dirname(bundle) orelse return null;
    const rel_exe = exe[bundle_parent.len + 1 ..]; // "Cadre.app/Contents/MacOS/cadre"
    const host_exe = allocZ(allocator, "{s}/{s}/{s}", .{ base, id, rel_exe }) catch return null;

    if (!fileExists(host_exe)) {
        copyBundle(allocator, base, id, bundle) catch |err| {
            log.warn("host: copying {s} failed: {}; panes run unhosted", .{ bundle, err });
            allocator.free(host_exe);
            return null;
        };
    }
    removeUnusedCopies(allocator, base, id);
    return host_exe;
}

/// `/x/Cadre.app` for `/x/Cadre.app/Contents/MacOS/cadre`; null when the
/// executable isn't the main binary of an .app bundle (dev builds).
pub fn bundleRoot(exe: []const u8) ?[]const u8 {
    const macos_dir = std.fs.path.dirname(exe) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(macos_dir), "MacOS")) return null;
    const contents = std.fs.path.dirname(macos_dir) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(contents), "Contents")) return null;
    const bundle = std.fs.path.dirname(contents) orelse return null;
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return bundle;
}

/// Copy directory name for one build of the executable (a rebuild changes size
/// or mtime, so each reload gets its own copy).
pub fn buildId(buf: []u8, size: u64, mtime_ns: i128) ![]u8 {
    return std.fmt.bufPrint(buf, "s{d}-t{d}", .{ size, @divTrunc(mtime_ns, std.time.ns_per_s) });
}

/// True when a line of `ps -Axo comm=` runs an executable under `dir/`.
pub fn copyInUse(ps_comms: []const u8, dir: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, ps_comms, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > dir.len and std.mem.startsWith(u8, line, dir) and line[dir.len] == '/') return true;
    }
    return false;
}

fn copyBundle(allocator: std.mem.Allocator, base: []const u8, id: []const u8, bundle: []const u8) !void {
    try std.fs.cwd().makePath(base);
    const tmp = try std.fmt.allocPrint(allocator, "{s}/{s}.tmp-{d}", .{ base, id, std.c.getpid() });
    defer allocator.free(tmp);
    const final = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, id });
    defer allocator.free(final);
    std.fs.cwd().deleteTree(tmp) catch |err| log.debug("host: no stale {s} to clear: {}", .{ tmp, err });
    try std.fs.cwd().makePath(tmp);
    errdefer std.fs.cwd().deleteTree(tmp) catch |err| log.warn("host: cleanup of {s} failed: {}", .{ tmp, err });

    // ditto keeps the code signature, xattrs and symlinks intact.
    const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, std.fs.path.basename(bundle) });
    defer allocator.free(dest);
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "/usr/bin/ditto", bundle, dest } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.DittoFailed,
        else => return error.DittoFailed,
    }
    std.fs.cwd().rename(tmp, final) catch |err| switch (err) {
        // Another instance finished the same copy first; use theirs.
        error.PathAlreadyExists => try std.fs.cwd().deleteTree(tmp),
        else => return err,
    };
    log.info("host: copied {s} -> {s}", .{ bundle, final });
}

/// A copy is deleted only when no process runs from it: deleting a live
/// host's binary would poison that host's whole pane.
fn removeUnusedCopies(allocator: std.mem.Allocator, base: []const u8, keep: []const u8) void {
    const ps = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "/bin/ps", "-Axo", "comm=" }, .max_output_bytes = 4 << 20 }) catch |err| {
        log.warn("host: ps failed ({}); keeping old copies", .{err});
        return;
    };
    defer allocator.free(ps.stdout);
    defer allocator.free(ps.stderr);
    switch (ps.term) {
        .Exited => |code| if (code != 0) return,
        else => return,
    }
    var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory or std.mem.eql(u8, entry.name, keep)) continue;
        if (std.mem.indexOf(u8, entry.name, ".tmp-") != null) continue; // another instance's copy in flight
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, entry.name }) catch return;
        defer allocator.free(path);
        if (copyInUse(ps.stdout, path)) continue;
        dir.deleteTree(entry.name) catch |err| {
            log.warn("host: removing old copy {s} failed: {}", .{ path, err });
            continue;
        };
        log.info("host: removed unused copy {s}", .{path});
    }
}

/// Newest existing copy's executable (dev builds have no bundle of their own).
fn newestCopy(allocator: std.mem.Allocator, base: []const u8) ?[:0]u8 {
    var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return null;
    defer dir.close();
    var best: ?[:0]u8 = null;
    var best_mtime: i128 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory or std.mem.indexOf(u8, entry.name, ".tmp-") != null) continue;
        const exe = allocZ(allocator, "{s}/{s}/Cadre.app/Contents/MacOS/cadre", .{ base, entry.name }) catch return best;
        const stat = std.fs.cwd().statFile(exe) catch {
            allocator.free(exe);
            continue;
        };
        if (best == null or stat.mtime > best_mtime) {
            if (best) |b| allocator.free(b);
            best = exe;
            best_mtime = stat.mtime;
        } else allocator.free(exe);
    }
    return best;
}

/// Null-terminated formatted string (manual len+1, like tmux.allocZ, so the
/// caller's free of the `[:0]u8` matches the allocation).
fn allocZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    const buf = try allocator.alloc(u8, text.len + 1);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return buf[0..text.len :0];
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "isHostInvocation needs the subcommand and a program" {
    const yes = [_][*:0]const u8{ "cadre", "host", "/bin/zsh" };
    const no_prog = [_][*:0]const u8{ "cadre", "host" };
    const gui = [_][*:0]const u8{"cadre"};
    try std.testing.expect(isHostInvocation(&yes));
    try std.testing.expect(!isHostInvocation(&no_prog));
    try std.testing.expect(!isHostInvocation(&gui));
}

test "shouldForward passes in-pane kills, not the keyboard's Ctrl+C" {
    const child: posix.pid_t = 500;
    try std.testing.expect(!shouldForward(posix.SIG.INT, 14101, child, false)); // Ctrl+C via tmux server
    try std.testing.expect(shouldForward(posix.SIG.INT, 321, child, true)); // kill -INT <host> from a shim
    try std.testing.expect(!shouldForward(posix.SIG.INT, child, child, true)); // never bounce back
    try std.testing.expect(!shouldForward(posix.SIG.INT, 0, child, false));
    try std.testing.expect(shouldForward(posix.SIG.HUP, 0, child, false)); // pane closed: leader only
    try std.testing.expect(shouldForward(posix.SIG.TERM, 14101, child, false));
}

test "bundleRoot finds the .app only for a bundle's main binary" {
    try std.testing.expectEqualStrings("/Applications/Cadre.app", bundleRoot("/Applications/Cadre.app/Contents/MacOS/cadre").?);
    try std.testing.expect(bundleRoot("/repo/zig-out/bin/cadre") == null);
    try std.testing.expect(bundleRoot("/x/Contents/MacOS/cadre") == null);
}

test "copyInUse matches executables inside the copy only" {
    const ps =
        \\/sbin/launchd
        \\/Users/r/Library/Application Support/Cadre/host/s1-t2/Cadre.app/Contents/MacOS/cadre
        \\/Users/r/Library/Application Support/Cadre/host/s1-t22/Cadre.app/Contents/MacOS/cadre
    ;
    const base = "/Users/r/Library/Application Support/Cadre/host";
    try std.testing.expect(copyInUse(ps, base ++ "/s1-t2"));
    try std.testing.expect(!copyInUse(ps, base ++ "/s1-t3"));
    try std.testing.expect(!copyInUse(ps, base ++ "/s1-t")); // prefix of another id
}

test "buildId changes with size or mtime" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const x = try buildId(&a, 100, 5 * std.time.ns_per_s);
    const y = try buildId(&b, 100, 6 * std.time.ns_per_s);
    try std.testing.expect(!std.mem.eql(u8, x, y));
}
