//! tmux-backed session persistence (Phase 1).
//!
//! When enabled, Cadre spawns each shell *inside* a detached tmux session so
//! agents (claude/codex/gemini) survive an Cadre restart and reattach live,
//! instead of being killed at quit and resumed from a possibly-stale local
//! transcript (the bridged `--resume` rewind bug). The tmux server double-forks
//! away from Cadre's process tree, so quitting Cadre — yours or the
//! reload script's — only drops the client; the server + shell + agent live on.
//!
//! On by default: whenever tmux is on PATH, `buildPersist` wraps the shell. When
//! tmux is not installed it returns null and the caller spawns a direct shell
//! exactly as before — so this degrades gracefully with no configuration.
const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.tmux);

/// Everything `Shell.spawn` needs to wrap a shell in a persistent tmux session.
/// All fields are owned heap strings; free with `freePersist`.
pub const Persist = struct {
    /// Absolute path to the tmux binary (execve needs a full path).
    tmux_path: [:0]const u8,
    /// Private server socket, stable across restarts so reattach finds the session.
    socket_path: [:0]const u8,
    /// Session name (`cadre-<epoch>-<persist_index>`); `new-session -A` keys
    /// off this. The index MUST be a session's stable persist_index, not its
    /// mutable grid slot_index — otherwise the name drifts as the grid reorders
    /// and a fresh spawn can attach to (clone) a live session. The <epoch> makes
    /// names disjoint per install so a new run never reattaches to another run's
    /// leftover session on the shared socket. See SessionState.persist_index and
    /// config.Persistence.persist_epoch.
    session_name: [:0]const u8,
    /// Config that makes tmux a transparent layer (no status bar, no keybindings).
    conf_path: [:0]const u8,
};

/// tmux config that turns tmux into an invisible persistence layer: no status
/// bar, no prefix, every key unbound (so Ctrl-B etc. pass straight through to
/// the agent), instant Escape, generous scrollback, truecolor passthrough,
/// OSC 8 hyperlink passthrough (so Cmd+Click doc links survive the tmux round
/// trip), and sessions that outlive a detached client.
///
/// `hyperlinks` in terminal-features tells tmux the OUTER terminal (Cadre)
/// understands OSC 8, so tmux re-emits hyperlinks it parsed from the pane
/// instead of stripping them; `allow-passthrough on` lets agents forward raw
/// escape sequences (OSC 52 clipboard, etc.) through tmux unmodified. Verified:
/// without `hyperlinks`, a pane's OSC 8 link is dropped before reaching
/// Cadre; with it, the link is re-emitted intact.
const conf_contents =
    \\set -g status off
    \\set -g prefix None
    \\set -g prefix2 None
    \\unbind-key -a
    \\set -g escape-time 0
    \\set -g history-limit 50000
    \\set -g destroy-unattached off
    \\set -g mouse off
    \\set -g focus-events off
    \\set -g default-terminal "screen-256color"
    \\set -as terminal-features ",*:RGB:hyperlinks"
    \\set -g allow-passthrough on
    \\set -g set-titles on
    \\set -g set-titles-string "#{pane_title}"
    \\
;

/// Allocate a null-terminated formatted string. Caller owns the result.
/// Uses a manual len+1 buffer (not allocSentinel) so freeing the returned
/// `[:0]u8` matches the allocation size exactly.
fn allocZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    const buf = try allocator.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

/// Resolve an executable on PATH. Caller owns the returned string.
fn findOnPath(allocator: std.mem.Allocator, name: []const u8) ?[:0]u8 {
    const path_env = posix.getenv("PATH") orelse "";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = allocZ(allocator, "{s}/{s}", .{ dir, name }) catch return null;
        if (posix.accessZ(candidate.ptr, posix.X_OK)) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    // Fallback to common install dirs. A Finder/login-item launch inherits
    // launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which omits
    // Homebrew, so tmux at /opt/homebrew/bin would be missed and persistence
    // would silently degrade to non-persistent shells. Check those dirs too.
    const fallback_dirs = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" };
    for (fallback_dirs) |dir| {
        const candidate = allocZ(allocator, "{s}/{s}", .{ dir, name }) catch return null;
        if (posix.accessZ(candidate.ptr, posix.X_OK)) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return null;
}

/// Stable per-user runtime directory for the tmux socket + config. Must be
/// stable across restarts (so reattach finds the same socket) and short enough
/// to keep the socket path under the ~104-char sun_path limit.
fn runtimeDir() []const u8 {
    if (posix.getenv("XDG_RUNTIME_DIR")) |d| if (d.len > 0) return trimTrailingSlash(d);
    if (posix.getenv("TMPDIR")) |d| if (d.len > 0) return trimTrailingSlash(d);
    return "/tmp";
}

fn trimTrailingSlash(d: []const u8) []const u8 {
    if (d.len > 1 and d[d.len - 1] == '/') return d[0 .. d.len - 1];
    return d;
}

// ponytail: process-wide singleton for the persist epoch. It is one constant for
// the whole run (the loaded persistence.persist_epoch), so threading it through
// every tmux call's signature would be noise. Set once at startup via setEpoch,
// read by sessionName. Fixed buffer -> no alloc, no lifetime coupling to the
// Persistence object. Empty until set (then names fall back to the legacy form).
var epoch_buf: [64]u8 = undefined;
var epoch_len: usize = 0;

/// Record the per-install epoch mixed into every tmux session name. Call once,
/// before any session spawns. See config.Persistence.persist_epoch.
pub fn setEpoch(epoch: []const u8) void {
    const n = @min(epoch.len, epoch_buf.len);
    @memcpy(epoch_buf[0..n], epoch[0..n]);
    epoch_len = n;
}

/// Build a session name `cadre-<epoch>-<index>` (or the legacy
/// `cadre-<index>` when no epoch is set). Caller owns the result.
fn sessionName(allocator: std.mem.Allocator, persist_index: usize) ?[:0]u8 {
    const built = if (epoch_len == 0)
        allocZ(allocator, "cadre-{d}", .{persist_index})
    else
        allocZ(allocator, "cadre-{s}-{d}", .{ epoch_buf[0..epoch_len], persist_index });
    return built catch |err| {
        log.warn("sessionName: alloc failed for index {d}: {}", .{ persist_index, err });
        return null;
    };
}

fn writeConf(path: [:0]const u8) !void {
    const file = try std.fs.cwd().createFileZ(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(conf_contents);
}

/// Re-apply the passthrough options to a server that is ALREADY running. tmux
/// reads `-f` only when it first starts the server, so a server left over from a
/// previous Cadre launch keeps its old options (e.g. missing the hyperlinks
/// feature) even after we rewrite the file. The next client attach negotiates
/// these, so OSC 8 links survive without restarting the server (which would kill
/// the agents). Best effort — on the first launch no server exists yet (no-op).
///
/// We set the relevant options (hyperlinks, passthrough, set-titles) directly
/// rather than `source-file`-ing the whole conf, because the conf's
/// `unbind-key -a` errors ("table prefix doesn't exist") on a server whose
/// prefix table was already emptied at start, aborting the rest of the file
/// before it reaches these lines. Keep in sync with `conf_contents`.
///
/// `allow-passthrough`/`set-titles*` use `set -g` (replace), so re-running them
/// every spawn is harmless. `terminal-features` uses `set -a` (append), so it is
/// guarded: appending unconditionally on every spawn piled up duplicate
/// ",*:hyperlinks" entries. Only append when the server doesn't already advertise
/// the feature (a fresh conf-built server already has "*:RGB:hyperlinks").
fn refreshRunningServer(allocator: std.mem.Allocator, tmux_path: [:0]const u8, socket_path: [:0]const u8) void {
    // Idempotent globals first. If no server is running yet this errors and we
    // return (nothing to refresh — the conf applies at server creation).
    var child = std.process.Child.init(&[_][]const u8{
        tmux_path,           "-S",            socket_path,
        "set",               "-g",            "allow-passthrough",
        "on",                ";",             "set",
        "-g",                "set-titles",    "on",
        ";",                 "set",           "-g",
        "set-titles-string", "#{pane_title}",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;

    // Append the hyperlinks feature only if the server lacks it, so repeated
    // spawns don't accumulate duplicates. On any query failure, assume present
    // and skip — the conf already guarantees it on fresh servers, so the worst
    // case is a stale pre-hyperlinks server waits until restart, never a dupe.
    const has_hyperlinks = blk: {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ tmux_path, "-S", socket_path, "show", "-g", "terminal-features" },
        }) catch |err| {
            log.debug("refreshRunningServer: terminal-features query failed: {}", .{err});
            break :blk true;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        break :blk std.mem.indexOf(u8, result.stdout, "hyperlinks") != null;
    };
    if (has_hyperlinks) return;

    var feat = std.process.Child.init(&[_][]const u8{
        tmux_path, "-S", socket_path, "set", "-ag", "terminal-features", ",*:hyperlinks",
    }, allocator);
    feat.stdin_behavior = .Ignore;
    feat.stdout_behavior = .Ignore;
    feat.stderr_behavior = .Ignore;
    _ = feat.spawnAndWait() catch return;
}

/// Build persist options keyed off a session's STABLE persist_index (not the
/// mutable grid slot_index), or null if persistence is disabled
/// or unavailable (tmux not found). On any partial failure, frees what it
/// allocated and returns null so the caller falls back to a direct shell spawn.
pub fn buildPersist(allocator: std.mem.Allocator, persist_index: usize) ?Persist {
    const tmux_path = findOnPath(allocator, "tmux") orelse {
        log.info("tmux not found on PATH; session persistence off, using direct shell", .{});
        return null;
    };
    errdefer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return null;
    errdefer allocator.free(socket_path);
    const conf_path = allocZ(allocator, "{s}/cadre-tmux.conf", .{dir}) catch return null;
    errdefer allocator.free(conf_path);
    const session_name = sessionName(allocator, persist_index) orelse return null;
    errdefer allocator.free(session_name);

    writeConf(conf_path) catch |err| {
        log.warn("failed to write tmux config {s}: {}; using direct shell", .{ conf_path, err });
        return null;
    };

    // Push current options into a server that survived a previous launch, so the
    // upcoming attach negotiates with the new conf (e.g. hyperlinks) instead of
    // the stale one. No-op when no server is running yet.
    refreshRunningServer(allocator, tmux_path, socket_path);

    return .{
        .tmux_path = tmux_path,
        .socket_path = socket_path,
        .session_name = session_name,
        .conf_path = conf_path,
    };
}

pub fn freePersist(allocator: std.mem.Allocator, p: Persist) void {
    allocator.free(p.tmux_path);
    allocator.free(p.socket_path);
    allocator.free(p.session_name);
    allocator.free(p.conf_path);
}

/// Scroll a persistent session's history via the tmux control socket.
///
/// Under persistence the shell runs full-screen *inside* tmux, so scrolled-off
/// lines live in tmux's 50k history buffer, not Cadre's ghostty-vt
/// scrollback — the wheel handler has nothing of its own to scroll. So drive
/// tmux copy-mode out-of-band: `copy-mode -e` enters it (idempotent; the `-e`
/// flag auto-exits when scrolled back to the bottom) and `send-keys -X -N <n>
/// scroll-{up,down}` moves the view. One combined tmux invocation per call.
/// Best-effort: a missing tmux or a failed call is a silent no-op, never an
/// error surfaced to the UI.
///
/// ponytail: spawnAndWait blocks the caller ~5-10ms per wheel tick — fine at
/// mouse-wheel cadence; if trackpad momentum feels laggy, coalesce ticks or
/// detach the spawn (double-fork). Also: while scrolled up the pane sits in tmux
/// copy-mode, so keystrokes are captured until you scroll back to the bottom.
pub fn scrollHistory(allocator: std.mem.Allocator, persist_index: usize, lines: u16, up: bool) void {
    if (lines == 0) return;

    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);
    const target = sessionName(allocator, persist_index) orelse return;
    defer allocator.free(target);

    var count_buf: [8]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}", .{lines}) catch return;
    const scroll_cmd: []const u8 = if (up) "scroll-up" else "scroll-down";

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path,   "-S",   socket_path,
        "copy-mode", "-e",   "-t",
        target,      ";",    "send-keys",
        "-t",        target, "-X",
        "-N",        count,  scroll_cmd,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}

/// Exit copy-mode for a persistent session's pane (best-effort, no-op if not in
/// copy-mode). `scrollHistory` leaves the pane in tmux copy-mode, which is modal —
/// the cursor and keys belong to the scroll, not the app underneath — so the first
/// keystroke afterward should snap back to the live prompt. Called from
/// `SessionState.sendInput`; spawnAndWait so copy-mode is gone before the keystroke
/// is written to the PTY (otherwise the key would drive the scroll instead).
pub fn cancelCopyMode(allocator: std.mem.Allocator, persist_index: usize) void {
    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);
    const target = sessionName(allocator, persist_index) orelse return;
    defer allocator.free(target);

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path, "-S", socket_path, "send-keys", "-t", target, "-X", "cancel",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}

/// Whether the persistent session's tmux pane is running a real command (an
/// agent/program), not just an idle shell. The quit-confirmation check can't see
/// this through Cadre's PTY foreground pgrp — for a tmux-backed pane that's
/// always the tmux client, never the agent — so it asks tmux directly via
/// `#{pane_current_command}`. Best-effort: returns false if tmux can't be queried.
pub fn paneHasForegroundCommand(allocator: std.mem.Allocator, persist_index: usize) bool {
    const tmux_path = findOnPath(allocator, "tmux") orelse return false;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return false;
    defer allocator.free(socket_path);
    const target = sessionName(allocator, persist_index) orelse return false;
    defer allocator.free(target);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            tmux_path, "-S", socket_path, "display-message", "-p", "-t", target, "#{pane_current_command}",
        },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }

    const cmd = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (cmd.len == 0) return false; // tmux returned nothing — don't false-positive
    return !isShellCommand(cmd);
}

/// Ask tmux to expand `format` for the persistent session's pane
/// (display-message -p). Returns the trimmed output (caller owns); null if
/// tmux can't be queried or the output is empty.
fn paneDisplay(allocator: std.mem.Allocator, persist_index: usize, format: []const u8) ?[]u8 {
    const tmux_path = findOnPath(allocator, "tmux") orelse return null;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return null;
    defer allocator.free(socket_path);
    const target = sessionName(allocator, persist_index) orelse return null;
    defer allocator.free(target);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            tmux_path, "-S", socket_path, "display-message", "-p", "-t", target, format,
        },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const text = std.mem.trimRight(u8, result.stdout, " \t\r\n");
    if (text.len == 0) return null;
    return allocator.dupe(u8, text) catch |err| {
        log.warn("paneDisplay: dupe failed: {}", .{err});
        return null;
    };
}

/// The working directory of the persistent session's tmux pane — the dir the
/// shell/agent is actually in. For a tmux-backed session the PTY child is the
/// tmux client, whose own process cwd is frozen wherever it was spawned, so
/// reading it (getCwd) reports the wrong directory; ask tmux for the pane path
/// instead. Caller owns the returned slice; null if tmux can't be queried.
pub fn panePath(allocator: std.mem.Allocator, persist_index: usize) ?[]u8 {
    return paneDisplay(allocator, persist_index, "#{pane_current_path}");
}

/// Remove CADRE_RESUME_CMD from the tmux server's GLOBAL environment.
/// The server captures the env of whichever client happened to start it —
/// including that pane's resume command — and sessions inherit any global
/// they don't override, so a brand-new terminal could run a stale
/// `claude --resume` at its first prompt. New spawns now always override the
/// variable per session; this heals a server poisoned by an older build
/// without restarting it. Best-effort: no server yet is a no-op.
pub fn scrubStaleGlobalEnv(allocator: std.mem.Allocator) void {
    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path, "-S", socket_path, "set-environment", "-g", "-u", "CADRE_RESUME_CMD",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch |err| {
        log.debug("scrubStaleGlobalEnv: {}", .{err});
    };
}

/// `ps` rows (`tpgid pgid comm`) for every process on the persistent session's
/// pane tty. tmux's own #{pane_current_command} names only the foreground
/// group's LEADER, which is a zsh wrapper when Claude was started through one,
/// so callers that need "what is in the foreground" scan these rows instead.
/// Spawns two subprocesses: event paths only. Caller owns; null on failure.
pub fn paneProcessTable(allocator: std.mem.Allocator, persist_index: usize) ?[]u8 {
    const tty = paneDisplay(allocator, persist_index, "#{pane_tty}") orelse return null;
    defer allocator.free(tty);
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "/bin/ps", "-t", std.fs.path.basename(tty), "-o", "tpgid=,pgid=,comm=" },
    }) catch |err| {
        log.warn("paneProcessTable: ps failed: {}", .{err});
        return null;
    };
    allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return null;
}

/// The pid of the persistent session's pane process (the shell running inside
/// tmux). For a tmux-backed session the PTY child is the tmux client, so
/// process-tree checks must start from the pane pid — the real tree lives
/// under the tmux server. Best-effort: null if tmux can't be queried.
pub fn panePid(allocator: std.mem.Allocator, persist_index: usize) ?std.posix.pid_t {
    const text = paneDisplay(allocator, persist_index, "#{pane_pid}") orelse return null;
    defer allocator.free(text);
    return std.fmt.parseInt(std.posix.pid_t, text, 10) catch |err| {
        log.warn("panePid: unparsable pane_pid {s}: {}", .{ text, err });
        return null;
    };
}

/// Discard a STALE ORPHAN tmux session for a slot before spawning a fresh
/// terminal there — otherwise `new-session -A` would ATTACH to the orphan and
/// the "new" terminal would mirror it. Only kills a session with ZERO attached
/// clients: a visible terminal's session is always attached by its client, so
/// this can never kill a live pane even if the slot bookkeeping is momentarily
/// off. No-op if the session doesn't exist or is attached. Best-effort.
pub fn discardOrphanSession(allocator: std.mem.Allocator, persist_index: usize) void {
    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);
    const target = sessionName(allocator, persist_index) orelse return;
    defer allocator.free(target);

    // Only proceed if the session exists AND is detached (#{session_attached} == 0).
    const probe = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            tmux_path, "-S", socket_path, "display-message", "-p", "-t", target, "#{session_attached}",
        },
    }) catch return;
    defer allocator.free(probe.stdout);
    defer allocator.free(probe.stderr);
    switch (probe.term) {
        .Exited => |code| if (code != 0) return, // session doesn't exist — nothing to discard
        else => return,
    }
    const attached = std.mem.trimRight(u8, probe.stdout, " \t\r\n");
    if (!std.mem.eql(u8, attached, "0")) return; // attached (a live pane) or unknown — never kill

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path, "-S", socket_path, "kill-session", "-t", target,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch return;
}

/// Destroy the persistent session outright, attached or not — the CLOSE path:
/// a discarded terminal's session must not linger as a resurrection target.
/// Quit never calls this; its sessions stay alive for reattach. Best-effort.
pub fn killSession(allocator: std.mem.Allocator, persist_index: usize) void {
    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);
    const target = sessionName(allocator, persist_index) orelse return;
    defer allocator.free(target);
    // '=' prefix: exact-name match, so -t can't prefix-match a longer name.
    const exact = allocZ(allocator, "={s}", .{target}) catch return;
    defer allocator.free(exact);

    var child = std.process.Child.init(&[_][]const u8{
        tmux_path, "-S", socket_path, "kill-session", "-t", exact,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch |err| {
        log.warn("killSession: {s} failed: {}", .{ target, err });
        return;
    };
    log.info("killSession: {s} -> {}", .{ target, term });
}

/// Whether a persistent session for this index exists on the socket right now.
/// Lets the restore path tell "reattached" apart from "started fresh".
pub fn hasSession(allocator: std.mem.Allocator, persist_index: usize) bool {
    const name = paneDisplay(allocator, persist_index, "#{session_name}") orelse return false;
    defer allocator.free(name);
    const target = sessionName(allocator, persist_index) orelse return false;
    defer allocator.free(target);
    // Equality check defeats tmux's prefix matching (-t foo-1 can hit foo-14).
    return std.mem.eql(u8, name, target);
}

const ReapVerdict = enum {
    reap,
    /// A caller-protected index: a persisted terminal's session. If it shows
    /// up detached here, the reattach that should have claimed it went wrong —
    /// killing it would take the agent with it.
    spare_kept,
    /// Same-epoch but the caller lacks full index information (legacy file);
    /// can't tell a fossil from a live terminal's session, so keep it.
    spare_same_epoch,
    /// Not one of our names; never touch it.
    spare_foreign,
};

/// Decide the fate of a DETACHED session. `keep` holds persist indices that
/// must survive; `reap_same_epoch` is false when the caller can't vouch for
/// the full index set. Different-epoch (or pre-epoch) cadre names are
/// always fossils: their run can never reattach to them again.
fn classifyDetachedSession(name: []const u8, epoch: []const u8, keep: []const usize, reap_same_epoch: bool) ReapVerdict {
    if (!std.mem.startsWith(u8, name, "cadre-")) return .spare_foreign;
    if (epoch.len == 0) return .reap; // epoch unset: everything is legacy

    var prefix_buf: [96]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "cadre-{s}-", .{epoch}) catch return .spare_same_epoch;
    if (!std.mem.startsWith(u8, name, prefix)) return .reap; // other/pre-epoch fossil

    const index = std.fmt.parseInt(usize, name[prefix.len..], 10) catch return .spare_same_epoch;
    for (keep) |k| {
        if (k == index) return .spare_kept;
    }
    return if (reap_same_epoch) .reap else .spare_same_epoch;
}

/// Drain the session graveyard at startup. The shared socket accumulates a
/// detached session for every terminal that ever ran and was never reattached
/// (crashed instances, closed terminals, pre-epoch fossils), so it grows without
/// bound — dozens piled up in practice. Call ONCE, AFTER this run has reattached
/// to all of its own sessions (so they hold a client and read as attached): kill
/// DETACHED sessions on the socket, except `keep` indices (persisted terminals
/// whose reattach may have failed — killing those loses the agent) and, when
/// `reap_same_epoch` is false, anything from our own epoch. Attached sessions —
/// ours and any other live instance's — are never touched. Best-effort: any
/// failure is a silent no-op. See config.Persistence.persist_epoch.
pub fn reapDetachedSessions(allocator: std.mem.Allocator, keep: []const usize, reap_same_epoch: bool) void {
    const tmux_path = findOnPath(allocator, "tmux") orelse return;
    defer allocator.free(tmux_path);

    const dir = runtimeDir();
    const socket_path = allocZ(allocator, "{s}/cadre-tmux.sock", .{dir}) catch return;
    defer allocator.free(socket_path);

    // One line per session: "<attached> <name>". No server yet => non-zero exit.
    const list = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            tmux_path, "-S", socket_path, "list-sessions", "-F", "#{session_attached} #{session_name}",
        },
    }) catch return;
    defer allocator.free(list.stdout);
    defer allocator.free(list.stderr);
    switch (list.term) {
        .Exited => |code| if (code != 0) return,
        else => return,
    }

    var reaped: usize = 0;
    var it = std.mem.splitScalar(u8, list.stdout, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (line.len < 3) continue;
        if (!std.mem.startsWith(u8, line, "0 ")) continue; // attached (or malformed) — spare it
        const name = line[2..];
        if (name.len == 0) continue;
        switch (classifyDetachedSession(name, epoch_buf[0..epoch_len], keep, reap_same_epoch)) {
            .reap => {},
            .spare_kept => {
                log.warn("reap: sparing detached session {s} — it belongs to a persisted terminal (missed reattach?)", .{name});
                continue;
            },
            .spare_same_epoch => {
                log.info("reap: sparing same-epoch session {s} (incomplete index info this run)", .{name});
                continue;
            },
            .spare_foreign => continue,
        }
        var child = std.process.Child.init(&[_][]const u8{
            tmux_path, "-S", socket_path, "kill-session", "-t", name,
        }, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        _ = child.spawnAndWait() catch |err| {
            log.debug("reap: kill-session {s} failed: {}", .{ name, err });
            continue;
        };
        log.info("reaped detached tmux session {s}", .{name});
        reaped += 1;
    }
    if (reaped > 0) log.info("reaped {d} detached tmux session(s)", .{reaped});
}

test "classifyDetachedSession: keep set, epochs, malformed names" {
    const epoch = "abc123";
    const keep = [_]usize{ 0, 141 };

    // Same epoch, protected index -> spared even when same-epoch reaping is on.
    try std.testing.expectEqual(ReapVerdict.spare_kept, classifyDetachedSession("cadre-abc123-141", epoch, &keep, true));
    // Same epoch, unprotected index -> fair game only with full index info.
    try std.testing.expectEqual(ReapVerdict.reap, classifyDetachedSession("cadre-abc123-7", epoch, &keep, true));
    try std.testing.expectEqual(ReapVerdict.spare_same_epoch, classifyDetachedSession("cadre-abc123-7", epoch, &keep, false));
    // Different epoch or legacy pre-epoch name -> always a fossil.
    try std.testing.expectEqual(ReapVerdict.reap, classifyDetachedSession("cadre-deadbeef-3", epoch, &keep, false));
    try std.testing.expectEqual(ReapVerdict.reap, classifyDetachedSession("cadre-3", epoch, &keep, false));
    // Same-epoch prefix with a malformed index -> keep (can't reason about it).
    try std.testing.expectEqual(ReapVerdict.spare_same_epoch, classifyDetachedSession("cadre-abc123-x", epoch, &keep, true));
    // Not ours at all.
    try std.testing.expectEqual(ReapVerdict.spare_foreign, classifyDetachedSession("some-other-session", epoch, &keep, true));
    // Epoch unset (legacy install): old behavior, reap any cadre session.
    try std.testing.expectEqual(ReapVerdict.reap, classifyDetachedSession("cadre-3", "", &keep, false));
}

/// tmux's `pane_current_command` for an idle pane is the shell name (e.g. "zsh");
/// a login shell may report with a leading '-'. Anything that isn't a known shell
/// counts as "a command/agent is running".
fn isShellCommand(cmd: []const u8) bool {
    const name = if (cmd.len > 0 and cmd[0] == '-') cmd[1..] else cmd;
    const shells = [_][]const u8{ "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh" };
    for (shells) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

test "isShellCommand: shells vs running commands" {
    try std.testing.expect(isShellCommand("zsh"));
    try std.testing.expect(isShellCommand("-zsh")); // login shell
    try std.testing.expect(isShellCommand("bash"));
    try std.testing.expect(!isShellCommand("claude"));
    try std.testing.expect(!isShellCommand("node"));
    try std.testing.expect(!isShellCommand("vim"));
    try std.testing.expect(!isShellCommand("")); // empty -> treat as no shell match
}
