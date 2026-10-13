const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const xev = @import("xev");
const ghostty_vt = @import("ghostty-vt");
const shell_mod = @import("../shell.zig");
const pty_mod = @import("../pty.zig");
const tmux = @import("../tmux.zig");
const colors_mod = @import("../colors.zig");
const fs = std.fs;
const cwd_mod = if (builtin.os.tag == .macos) @import("../cwd.zig") else struct {};
const vt_stream = @import("../vt_stream.zig");
const osc_title = @import("osc_title.zig");
const mac = if (builtin.os.tag == .macos)
    @cImport({
        @cInclude("sys/types.h");
        @cInclude("sys/sysctl.h");
        @cInclude("sys/proc.h");
    })
else
    struct {};

pub const AgentKind = enum {
    claude,
    codex,
    gemini,

    pub fn fromComm(comm: []const u8) ?AgentKind {
        if (std.mem.eql(u8, comm, "claude")) return .claude;
        if (std.mem.eql(u8, comm, "codex")) return .codex;
        if (std.mem.eql(u8, comm, "gemini")) return .gemini;
        return null;
    }

    /// Returns the agent kind if any known agent name appears as a complete
    /// path component in path.
    pub fn fromPath(path: []const u8) ?AgentKind {
        var start: usize = 0;
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (i == path.len or path[i] == '/') {
                const component = path[start..i];
                if (fromComm(component)) |kind| return kind;
                start = i + 1;
            }
        }
        return null;
    }

    pub fn name(self: AgentKind) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .gemini => "gemini",
        };
    }

    /// Control-byte sequence that triggers graceful exit.
    pub fn exitControlSequence(self: AgentKind) []const u8 {
        return switch (self) {
            .claude, .codex, .gemini => "\x03\x03",
        };
    }
};

const log = std.log.scoped(.session_state);

extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;
extern "c" fn ptsname(fd: posix.fd_t) ?[*:0]const u8;
/// Returns the full executable path for the given pid; available on macOS via libproc.
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

const pending_write_shrink_threshold: usize = 64 * 1024;
const session_id_buf_len: usize = 32;

/// Monotonic counter backing SessionState.order_seq. Never recycled — unlike
/// persist_index/id, which reuse a closed terminal's struct index and
/// therefore cannot order terminals. Advanced on first spawn and by
/// mintOrderSeqBlock when a drag-reorder renumbers the visible block.
var next_order_seq: u64 = 1;

/// Reserve `n` consecutive order_seq values above everything handed out so
/// far, returning the first. A reorder renumbers the whole visible block from
/// a fresh range so it can't collide with hidden sessions or a mid-spawn
/// terminal, and the next spawn still sorts last.
pub fn mintOrderSeqBlock(n: usize) u64 {
    const base = next_order_seq;
    next_order_seq += @intCast(n);
    return base;
}
const synchronized_output_timeout_ms: i64 = 1000;
const synchronized_output_quiet_ms: i64 = 100;
const synchronized_output_max_timeout_ms: i64 = 5000;

pub const SessionState = struct {
    slot_index: usize,
    /// Stable per-object identity for the tmux persistence layer. Assigned once at
    /// creation (= the physical array position) and NEVER reassigned — unlike
    /// slot_index, which compactSessions rewrites to the current grid position as
    /// terminals are hidden/closed/reordered. tmux session names
    /// (`cadre-<epoch>-<n>`) key off this so a live pane's name never drifts
    /// out from under it. Keying
    /// them off the mutable slot_index instead let a new terminal reuse a name a
    /// live session still held, and `tmux new-session -A` would ATTACH to (clone)
    /// that live session. Must be stable for the object's lifetime.
    persist_index: usize,
    /// True when this shell was wrapped in a tmux session (persistence is on by
    /// default; it engages whenever tmux is present on PATH). tmux then owns the
    /// scrollback, so wheel-scroll is routed to tmux copy-mode instead of the
    /// (empty) ghostty-vt scrollback. See tmux.scrollHistory.
    tmux_backed: bool = false,
    /// True after a wheel-scroll left this tmux pane in copy-mode; the next keystroke
    /// cancels copy-mode so the cursor returns to the live prompt. See sendInput.
    scrolled_in_copy_mode: bool = false,
    id: usize,
    /// Display-order key for the grid (compactSessions sorts visible sessions
    /// by this). Initialized from a monotonic counter on first spawn (so the
    /// default order is creation order), renumbered via mintOrderSeqBlock when
    /// the user drag-reorders tiles, kept across in-place restarts (so a
    /// restarted terminal holds its grid position), and cleared on close so a
    /// reused struct gets a fresh seq. id/persist_index can't serve this role:
    /// they recycle a closed terminal's index, so sorting by them scrambled
    /// the visible order.
    order_seq: u64 = 0,
    shell: ?shell_mod.Shell,
    terminal: ?ghostty_vt.Terminal,
    stream: ?vt_stream.StreamType,
    output_buf: [4096]u8,
    render_epoch: u64 = 1,
    spawned: bool = false,
    dead: bool = false,
    /// Hidden from the grid (Cmd+H) but the session/shell stays alive; revealed
    /// later via the switcher. `isVisible()` = spawned and not hidden.
    hidden: bool = false,
    shell_path: []const u8,
    pty_size: pty_mod.winsize,
    session_id_z: [session_id_buf_len:0]u8,
    notify_sock_z: [:0]const u8,
    allocator: std.mem.Allocator,
    theme: colors_mod.Theme,
    cwd_path: ?[]const u8 = null,
    /// Subslice of cwd_path pointing to the basename. Always points within cwd_path's memory.
    /// When cwd_path is freed, this becomes invalid and must not be used.
    cwd_basename: ?[]const u8 = null,
    cwd_last_check: i64 = 0,
    /// Set to true once updateCwd observes a non-root directory. Prevents the transient `/`
    /// that the shell briefly reports during startup from polluting recent_folders.
    cwd_settled: bool = false,
    pending_write: std.ArrayListUnmanaged(u8) = .empty,
    /// Process watcher for event-driven exit detection.
    process_watcher: ?xev.Process = null,
    /// Context for disambiguating process exit callbacks. Includes its own completion struct
    /// so each process watcher has an independent completion that won't be corrupted on relaunch.
    process_wait_ctx: ?*WaitContext = null,
    /// Incremented whenever a new watcher is armed to ignore stale completions.
    process_generation: usize = 0,
    /// Last AI agent that set the terminal icon (OSC 1) during this session.
    /// Updated continuously by processOutput; used as a reliable fallback for agent detection
    /// when KERN_PROCARGS2 is restricted by the OS (macOS Sequoia and later).
    agent_icon: ?AgentKind = null,
    /// Claude Code session name parsed from the terminal title (the status glyph
    /// stripped) — e.g. the name from `/rename`, or the auto-generated summary.
    /// Null until a Claude title is seen. Owned; freed in teardown.
    title: ?[]const u8 = null,
    /// Agent type detected at quit time (macOS only). Set transiently before persistence save.
    agent_kind: ?AgentKind = null,
    /// Agent session UUID extracted from terminal output at quit time. Owned; freed in deinit.
    agent_session_id: ?[]const u8 = null,
    /// True only when agent_kind/agent_session_id were captured during the current run's quit flow.
    /// Restored metadata is used for startup resume injection, but must not be re-persisted as fresh data.
    agent_metadata_captured: bool = false,
    /// Resume command (e.g. "claude --resume <id>") injected as CADRE_RESUME_CMD into the
    /// next spawn's environment. The wrapper rc runs it ONCE after the user's shell rc finishes
    /// loading — so it never races stdin and can't be eaten by a startup prompt. Owned; freed in
    /// teardown. Null for normal (non-restored) panes.
    resume_cmd: ?[]u8 = null,
    /// Raw PTY output captured after quit teardown starts. Used to avoid extracting
    /// stale UUIDs from earlier scrollback.
    quit_capture: std.ArrayListUnmanaged(u8) = .empty,
    quit_capture_active: bool = false,
    synchronized_output_started_ms: i64 = 0,
    synchronized_output_last_output_ms: i64 = 0,

    const WaitContext = struct {
        session: *SessionState,
        generation: usize,
        pid: posix.pid_t,
        /// Each WaitContext has its own completion to avoid corruption when relaunching.
        completion: xev.Completion = .{},
    };

    pub const InitError = shell_mod.Shell.SpawnError || MakeNonBlockingError || error{
        DivisionByZero,
        GraphemeAllocOutOfMemory,
        GraphemeMapOutOfMemory,
        HyperlinkMapOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkSetOutOfMemory,
        NeedsRehash,
        OutOfMemory,
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
        SystemResources,
        SystemFdQuotaExceeded,
        InvalidArgument,
    };

    const WaitContextCleanup = enum {
        destroy_immediately,
        defer_if_active,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        slot_index: usize,
        shell_path: []const u8,
        size: pty_mod.winsize,
        notify_sock: [:0]const u8,
        theme: colors_mod.Theme,
    ) InitError!SessionState {
        const session_id_buf = [_:0]u8{0} ** session_id_buf_len;

        return SessionState{
            .slot_index = slot_index,
            .persist_index = slot_index,
            .id = 0,
            .shell = null,
            .terminal = null,
            .stream = null,
            .output_buf = undefined,
            .spawned = false,
            .shell_path = shell_path,
            .pty_size = size,
            .session_id_z = session_id_buf,
            .notify_sock_z = notify_sock,
            .allocator = allocator,
            .theme = theme,
        };
    }

    // Every spawn wrapper below is FRESH (discards any stale tmux session at
    // this slot's name first) — otherwise `new-session -A` would attach to a
    // leftover (e.g. a closed terminal's) and resurrect it as an exact clone.
    // Only the restore path attaches, via ensureSpawnedWithDir directly.

    pub fn ensureSpawned(self: *SessionState) InitError!void {
        return self.ensureSpawnedFresh(null, null);
    }

    pub fn ensureSpawnedWithLoop(self: *SessionState, loop: *xev.Loop) InitError!void {
        return self.ensureSpawnedFresh(null, loop);
    }

    pub fn ensureSpawnedFresh(self: *SessionState, working_dir: ?[:0]const u8, loop_opt: ?*xev.Loop) InitError!void {
        if (self.spawned) return;
        tmux.discardOrphanSession(self.allocator, self.persist_index);
        return self.ensureSpawnedWithDir(working_dir, loop_opt);
    }

    pub fn ensureSpawnedWithDir(self: *SessionState, working_dir: ?[:0]const u8, loop_opt: ?*xev.Loop) InitError!void {
        if (self.spawned) return;

        // Bump generation to invalidate any stale callbacks from a previous shell; wrapping is intentional.
        self.process_generation +%= 1;
        self.assignSessionId();
        if (self.order_seq == 0) {
            self.order_seq = next_order_seq;
            next_order_seq += 1;
        }

        // tmux-backed persistence (on by default): when tmux is available the
        // shell is wrapped in a detached tmux session so it survives an Cadre
        // restart. Null (tmux not installed) spawns a direct shell exactly as
        // before. Freed after spawn — the forked child reads its own copy-on-write
        // copy of these strings, so freeing here is safe.
        const persist = tmux.buildPersist(self.allocator, self.persist_index);
        defer if (persist) |p| tmux.freePersist(self.allocator, p);
        self.tmux_backed = persist != null;

        const shell = try shell_mod.Shell.spawn(
            self.shell_path,
            self.pty_size,
            &self.session_id_z,
            self.notify_sock_z,
            working_dir,
            self.resume_cmd,
            persist,
        );
        errdefer {
            var s = shell;
            s.deinit();
        }

        // Consumed: the resume command is baked into this shell's env and runs
        // once. Keeping it would re-inject it into any later respawn on this
        // struct (e.g. the close-last-terminal relaunch), resuming a
        // conversation the user never asked for.
        if (self.resume_cmd) |cmd| {
            self.allocator.free(cmd);
            self.resume_cmd = null;
        }

        var terminal = try ghostty_vt.Terminal.init(self.allocator, .{
            .cols = self.pty_size.ws_col,
            .rows = self.pty_size.ws_row,
            .max_scrollback = 10_000_000,
            .default_modes = .{ .grapheme_cluster = true },
            .colors = terminalColorsFromTheme(self.theme),
        });
        errdefer terminal.deinit(self.allocator);

        try makeNonBlocking(shell.pty.master);

        self.shell = shell;
        self.terminal = terminal;
        self.spawned = true;
        const stream = vt_stream.initStream(
            self.allocator,
            &self.terminal.?,
            &self.shell.?,
        );
        self.stream = stream;
        self.markDirty();

        if (loop_opt) |loop| {
            var process = try xev.Process.init(shell.child_pid);
            errdefer process.deinit();

            const wait_ctx = try self.allocator.create(WaitContext);
            errdefer self.allocator.destroy(wait_ctx);
            wait_ctx.* = .{
                .session = self,
                .generation = self.process_generation,
                .pid = shell.child_pid,
            };
            self.process_wait_ctx = wait_ctx;

            process.wait(
                loop,
                &wait_ctx.completion,
                WaitContext,
                wait_ctx,
                processExitCallback,
            );

            self.process_watcher = process;
        }

        log.debug("spawned session {d}", .{self.id});

        self.processOutput() catch |err| {
            log.warn("session {d}: initial output processing failed: {}", .{ self.id, err });
        };

        self.seedCwd(working_dir) catch |err| {
            log.warn("failed to record cwd for session {d}: {}", .{ self.id, err });
        };
    }

    /// Wire identity: exported as CADRE_SESSION_ID and echoed back in
    /// every notify-socket message. Equals persist_index (unique within a run,
    /// stable across restarts) so hooks from a tmux-reattached agent, whose
    /// env was baked by a previous run, still resolve to the right terminal —
    /// a per-run spawn counter collided across runs with different layouts.
    fn assignSessionId(self: *SessionState) void {
        self.id = self.persist_index;
        const written = std.fmt.bufPrint(&self.session_id_z, "{d}", .{self.id}) catch |err| {
            log.warn("failed to format session id {d}: {}", .{ self.id, err });
            self.session_id_z[0] = 0;
            return;
        };
        self.session_id_z[written.len] = 0;
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        self.teardown(allocator, .destroy_immediately);
    }

    /// Runtime close path used while the event loop is still active.
    /// Keeps active process wait callbacks valid by deferring context destruction.
    /// The user discarded this terminal, so its tmux session dies with it.
    /// Quit teardown does NOT come through here — quit only detaches, leaving
    /// sessions alive for the next launch to reattach.
    pub fn despawn(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.tmux_backed and self.spawned) {
            tmux.killSession(allocator, self.persist_index);
        }
        self.teardown(allocator, .defer_if_active);
    }

    fn teardown(self: *SessionState, allocator: std.mem.Allocator, wait_ctx_cleanup: WaitContextCleanup) void {
        self.pending_write.deinit(allocator);
        self.pending_write = .empty;
        self.quit_capture.deinit(allocator);
        self.quit_capture = .empty;
        self.quit_capture_active = false;
        self.resetSynchronizedOutputTracking();

        if (self.agent_session_id) |sid| {
            allocator.free(sid);
            self.agent_session_id = null;
        }
        if (self.title) |t| {
            allocator.free(t);
            self.title = null;
        }
        self.agent_kind = null;
        self.agent_metadata_captured = false;

        if (self.resume_cmd) |cmd| {
            allocator.free(cmd);
            self.resume_cmd = null;
        }

        if (self.cwd_path) |path| {
            allocator.free(path);
            self.cwd_path = null;
            self.cwd_basename = null;
        }

        if (self.process_watcher) |*watcher| {
            watcher.deinit();
            self.process_watcher = null;
        }
        if (self.process_wait_ctx) |ctx| {
            switch (wait_ctx_cleanup) {
                .destroy_immediately => {
                    allocator.destroy(ctx);
                },
                .defer_if_active => {
                    if (ctx.completion.state() == .dead) {
                        allocator.destroy(ctx);
                    }
                },
            }
        }
        self.process_wait_ctx = null;
        // Wrap intentionally: process_generation is a bounded counter and may overflow.
        self.process_generation +%= 1;

        if (self.shell) |*shell| {
            if (self.spawned and !self.dead) {
                _ = std.c.kill(shell.child_pid, std.c.SIG.TERM);
            }
            shell.deinit();
            self.shell = null;
        }
        if (self.stream) |*stream| {
            stream.deinit();
            self.stream = null;
        }
        if (self.terminal) |*terminal| {
            terminal.deinit(allocator);
            self.terminal = null;
        }

        self.spawned = false;
        self.dead = false;
        self.cwd_settled = false;
        // Closed for good (restart uses resetForRespawn, not teardown): a later
        // spawn reusing this struct is a NEW terminal and must sort at the end.
        self.order_seq = 0;
    }

    pub const ProcessOutputError = posix.ReadError || posix.WriteError || error{
        DivisionByZero,
        GraphemeAllocOutOfMemory,
        GraphemeMapOutOfMemory,
        HyperlinkMapOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkSetOutOfMemory,
        NeedsRehash,
        OutOfMemory,
        OutOfSpace,
        StringAllocOutOfMemory,
        StyleSetNeedsRehash,
        StyleSetOutOfMemory,
    };

    fn processExitCallback(
        ctx_opt: ?*WaitContext,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Process.WaitError!u32,
    ) xev.CallbackAction {
        const ctx = ctx_opt orelse return .disarm;
        const self = ctx.session;

        // Ignore completions from stale watchers (after despawn/restart) or mismatched PID.
        const shell = self.shell orelse {
            const is_current = self.process_wait_ctx == ctx;
            self.allocator.destroy(ctx);
            if (is_current) self.process_wait_ctx = null;
            return .disarm;
        };
        if (ctx.generation != self.process_generation or ctx.pid != shell.child_pid) {
            const is_current = self.process_wait_ctx == ctx;
            self.allocator.destroy(ctx);
            if (is_current) self.process_wait_ctx = null;
            return .disarm;
        }

        const exit_code = r catch |err| {
            log.err("process wait error for session {d}: {}", .{ self.id, err });
            const is_current = self.process_wait_ctx == ctx;
            self.allocator.destroy(ctx);
            if (is_current) self.process_wait_ctx = null;
            return .disarm;
        };

        self.dead = true;
        self.markDirty();
        log.info("session {d} process exited with code {d}", .{ self.id, exit_code });

        const is_current = self.process_wait_ctx == ctx;
        self.allocator.destroy(ctx);
        if (is_current) self.process_wait_ctx = null;

        return .disarm;
    }

    pub fn checkAlive(self: *SessionState) void {
        if (!self.spawned or self.dead) return;

        if (self.shell) |shell| {
            var status: c_int = 0;
            const result = std.c.waitpid(shell.child_pid, &status, std.c.W.NOHANG);
            if (result > 0) {
                self.dead = true;
                self.markDirty();
                log.info("session {d} process exited", .{self.id});
            }
        }
    }

    pub fn restart(self: *SessionState) InitError!void {
        if (self.spawned and !self.dead) return;

        self.resetForRespawn();
        try self.ensureSpawned();
    }

    /// Close-then-respawn of the sole remaining terminal: the user discarded
    /// it, so kill its tmux session before respawning fresh — `new-session -A`
    /// would otherwise reattach and resurrect the just-closed shell/agent.
    pub fn relaunch(self: *SessionState, working_dir: ?[:0]const u8, loop_opt: ?*xev.Loop) InitError!void {
        if (self.tmux_backed and self.spawned) {
            tmux.killSession(self.allocator, self.persist_index);
        }
        self.resetForRespawn();
        try self.ensureSpawnedFresh(working_dir, loop_opt);
    }

    fn resetForRespawn(self: *SessionState) void {
        self.clearTerminalSelection();
        self.pending_write.clearAndFree(self.allocator);
        self.quit_capture.clearAndFree(self.allocator);
        self.quit_capture_active = false;
        self.resetSynchronizedOutputTracking();
        if (self.process_watcher) |*watcher| {
            watcher.deinit();
            self.process_watcher = null;
        }
        if (self.process_wait_ctx) |ctx| {
            if (ctx.completion.state() == .dead) {
                self.allocator.destroy(ctx);
            }
        }
        self.process_wait_ctx = null;
        // Wrap intentionally: generation just invalidates prior watchers.
        self.process_generation +%= 1;
        if (self.stream) |*stream| {
            stream.deinit();
            self.stream = null;
        }
        if (self.terminal) |*terminal| {
            terminal.deinit(self.allocator);
            self.terminal = null;
        }
        if (self.shell) |*shell| {
            shell.deinit();
            self.shell = null;
        }

        if (self.agent_session_id) |sid| {
            self.allocator.free(sid);
            self.agent_session_id = null;
        }
        if (self.title) |t| {
            self.allocator.free(t);
            self.title = null;
        }
        self.agent_kind = null;
        self.agent_metadata_captured = false;

        self.spawned = false;
        self.dead = false;
        self.cwd_settled = false;
    }

    pub fn markDirty(self: *SessionState) void {
        self.render_epoch +%= 1;
    }

    pub fn synchronizedOutputActive(self: *const SessionState) bool {
        if (!self.spawned or self.dead) return false;
        if (self.terminal) |*terminal| {
            return terminal.modes.get(.synchronized_output);
        }
        return false;
    }

    pub fn resetSynchronizedOutputTracking(self: *SessionState) void {
        self.synchronized_output_started_ms = 0;
        self.synchronized_output_last_output_ms = 0;
    }

    pub fn expireSynchronizedOutput(self: *SessionState, current_time_ms: i64) bool {
        if (!self.spawned or self.dead) {
            self.resetSynchronizedOutputTracking();
            return false;
        }

        const terminal = if (self.terminal) |*terminal| terminal else {
            self.resetSynchronizedOutputTracking();
            return false;
        };

        if (!terminal.modes.get(.synchronized_output)) {
            self.resetSynchronizedOutputTracking();
            return false;
        }

        if (self.synchronized_output_started_ms == 0 or current_time_ms < self.synchronized_output_started_ms) {
            self.synchronized_output_started_ms = current_time_ms;
            self.synchronized_output_last_output_ms = current_time_ms;
            return false;
        }

        const active_ms = current_time_ms - self.synchronized_output_started_ms;
        const quiet_ms = quietDurationMs(
            current_time_ms,
            self.synchronized_output_started_ms,
            self.synchronized_output_last_output_ms,
        );
        if (active_ms < synchronized_output_timeout_ms) return false;
        if (active_ms < synchronized_output_max_timeout_ms and quiet_ms < synchronized_output_quiet_ms) return false;

        terminal.modes.set(.synchronized_output, false);
        self.resetSynchronizedOutputTracking();
        self.markDirty();
        return true;
    }

    fn updateSynchronizedOutputState(self: *SessionState, was_active: bool, current_time_ms: i64) void {
        const terminal = if (self.terminal) |*terminal| terminal else {
            self.resetSynchronizedOutputTracking();
            return;
        };

        const is_active = terminal.modes.get(.synchronized_output);
        if (is_active) {
            if (!was_active or self.synchronized_output_started_ms == 0) {
                self.synchronized_output_started_ms = current_time_ms;
            }
            self.synchronized_output_last_output_ms = current_time_ms;
        } else {
            self.resetSynchronizedOutputTracking();
        }
    }

    fn quietDurationMs(current_time_ms: i64, started_ms: i64, last_output_ms: i64) i64 {
        const quiet_started_ms = if (last_output_ms == 0) started_ms else last_output_ms;
        if (current_time_ms <= quiet_started_ms) return 0;
        return current_time_ms - quiet_started_ms;
    }

    fn clearTerminalSelection(self: *SessionState) void {
        if (!self.spawned) return;
        if (self.terminal) |*terminal| {
            terminal.screens.active.clearSelection();
            self.markDirty();
        }
    }

    pub fn processOutput(self: *SessionState) ProcessOutputError!void {
        if (!shouldProcessOutput(self.spawned, self.dead, self.quit_capture_active)) return;

        const shell = &(self.shell orelse return);
        const stream = &(self.stream orelse return);

        while (true) {
            const n = shell.read(&self.output_buf) catch |err| switch (err) {
                error.WouldBlock => return,
                // Linux PTYs can report EIO after the slave side closes.
                // Treat it as terminal EOF so normal dead sessions don't fail the runtime loop.
                error.InputOutput => return,
                else => return err,
            };

            if (n == 0) return;

            if (scanOsc1Agent(self.output_buf[0..n])) |kind| {
                self.agent_icon = kind;
            }
            if (osc_title.scanOscTitle(self.output_buf[0..n])) |t| {
                self.setTitle(t) catch |err| {
                    log.warn("session {d}: failed to store terminal title: {}", .{ self.id, err });
                };
            }
            if (self.quit_capture_active) {
                self.quit_capture.appendSlice(self.allocator, self.output_buf[0..n]) catch |err| {
                    log.warn("session {d}: quit capture append failed: {}", .{ self.id, err });
                };
            }
            const was_synchronized_output = self.synchronizedOutputActive();
            // Process byte-by-byte so a hyperlink capacity error on byte N doesn't
            // silently discard bytes N+1..end of the PTY read. Hyperlink errors drop
            // only that byte's side effect; normal output/control sequences continue.
            for (self.output_buf[0..n]) |byte| {
                stream.next(byte) catch |err| switch (err) {
                    error.HyperlinkSetOutOfMemory,
                    error.HyperlinkSetNeedsRehash,
                    error.HyperlinkMapOutOfMemory,
                    => log.warn("session {d}: OSC 8 hyperlink capacity exhausted, hyperlink dropped: {}", .{ self.id, err }),
                    else => return err,
                };
            }
            const processed_at_ms = std.time.milliTimestamp();
            self.updateSynchronizedOutputState(was_synchronized_output, processed_at_ms);
            self.markDirty();

            // Keep draining until the PTY would block to avoid frame-bounded
            // throttling of bursty output (e.g. startup logos).
        }
    }

    fn shouldProcessOutput(spawned: bool, dead: bool, quit_capture_active: bool) bool {
        if (!spawned) return false;
        if (!dead) return true;
        return quit_capture_active;
    }

    /// Mark the session as failed after an unrecoverable output-processing error
    /// (e.g. ghostty-vt resource exhaustion like `HyperlinkSetOutOfMemory`). Sends
    /// SIGTERM to the still-running child so it stops consuming resources behind a
    /// "[Process completed]" UI, drops queued stdin so `flushPendingWrites` does
    /// not retry every frame, then flips `dead` and bumps the render epoch. The
    /// shell/terminal/stream wrappers stay alive so scrollback remains visible and
    /// the session can be restarted through the existing dead-state UI path.
    pub fn failAndTerminate(self: *SessionState) void {
        if (self.shell) |shell| {
            if (self.spawned and !self.dead) {
                _ = std.c.kill(shell.child_pid, std.c.SIG.TERM);
            }
        }
        self.pending_write.clearAndFree(self.allocator);
        self.dead = true;
        self.markDirty();
    }

    /// Try to flush any queued stdin data; preserves ordering relative to new input.
    pub fn flushPendingWrites(self: *SessionState) !void {
        if (self.pending_write.items.len == 0) return;
        const shell = &(self.shell orelse return);
        const buf = self.pending_write.items[0..self.pending_write.items.len];
        const wrote = shell.write(buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (wrote == buf.len) {
            self.pending_write.clearRetainingCapacity();
            maybeShrinkPendingWrite(&self.pending_write, self.allocator);
            return;
        }
        if (wrote > 0) {
            const remaining = buf[wrote..];
            std.mem.copyForwards(u8, self.pending_write.items[0..remaining.len], remaining);
            self.pending_write.items.len = remaining.len;
        }
        // If wrote == 0 and WouldBlock, keep buffer as-is for next frame.
    }

    pub fn sendInput(self: *SessionState, data: []const u8) !void {
        if (!self.spawned or self.dead) return;
        // If the user scrolled this tmux pane up (leaving it in modal copy-mode),
        // typing should snap back to the live prompt instead of driving the scroll.
        // Cancel copy-mode first; spawnAndWait so it's gone before `data` hits the PTY.
        if (self.scrolled_in_copy_mode) {
            self.scrolled_in_copy_mode = false;
            tmux.cancelCopyMode(self.allocator, self.persist_index);
        }
        try self.flushPendingWrites();
        const shell = &(self.shell orelse return);
        const wrote = shell.write(data) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        if (wrote < data.len) {
            try self.pending_write.appendSlice(self.allocator, data[wrote..]);
        }
    }

    pub fn updateCwd(self: *SessionState, current_time: i64) void {
        if (builtin.os.tag != .macos) return;

        if (!self.spawned or self.dead) return;

        const shell = self.shell orelse return;

        // tmux-backed: the PTY child is the tmux client, whose process cwd is
        // frozen wherever it was spawned, so getCwd reports the wrong directory.
        // Ask tmux for the pane's real path instead. The longer, per-slot
        // staggered interval keeps these per-session tmux subprocesses off the
        // same frame.
        const check_interval_ms: i64 = if (self.tmux_backed)
            2000 + @as(i64, @intCast(self.slot_index % 8)) * 120
        else
            1000;
        if (current_time - self.cwd_last_check < check_interval_ms) return;
        self.cwd_last_check = current_time;

        const new_path = if (self.tmux_backed)
            (tmux.panePath(self.allocator, self.persist_index) orelse return)
        else
            (cwd_mod.getCwd(self.allocator, shell.child_pid) catch return);

        if (self.cwd_path) |old_path| {
            if (std.mem.eql(u8, old_path, new_path)) {
                self.allocator.free(new_path);
                return;
            }
            self.allocator.free(old_path);
        }

        if (!self.cwd_settled and !std.mem.eql(u8, new_path, "/")) {
            self.cwd_settled = true;
        }
        self.cwd_path = new_path;
        self.cwd_basename = basenameForDisplay(new_path);
        self.markDirty();
    }

    pub fn recordCwd(self: *SessionState, path: []const u8) !void {
        try self.replaceCwdPath(path);
    }

    fn seedCwd(self: *SessionState, working_dir: ?[:0]const u8) !void {
        if (working_dir) |dir| {
            try self.replaceCwdPath(std.mem.sliceTo(dir, 0));
            return;
        }

        if (std.posix.getenv("HOME")) |home_z| {
            try self.replaceCwdPath(std.mem.sliceTo(home_z, 0));
        }
    }

    fn replaceCwdPath(self: *SessionState, path: []const u8) !void {
        if (self.cwd_path) |old| {
            self.allocator.free(old);
        }

        self.cwd_path = try self.allocator.dupe(u8, path);
        self.cwd_basename = basenameForDisplay(self.cwd_path.?);
        self.markDirty();
    }

    /// Alive and shown in the grid: spawned and not hidden. Hidden sessions keep
    /// running but are excluded from the grid layout and rendering.
    pub fn isVisible(self: *const SessionState) bool {
        return self.spawned and !self.hidden;
    }

    /// Returns true when the PTY's foreground process group differs from the
    /// shell's PID, indicating that a child process is currently running in
    /// the terminal.
    pub fn hasForegroundProcess(self: *const SessionState) bool {
        if (!self.spawned or self.dead) return false;
        const shell = self.shell orelse return false;
        const fg_pgrp = self.foregroundPgrp() orelse return false;
        return fg_pgrp != shell.child_pid;
    }

    /// Like `hasForegroundProcess`, but correct for tmux-backed sessions. For
    /// those the PTY foreground is always the tmux client, so the pgrp check
    /// never sees the agent; ask tmux what's actually running in the pane
    /// instead. Spawns a tmux subprocess, so this is for event-driven
    /// confirmation/guard paths (quit, close-terminal, cd/switch/remove), NOT
    /// the per-frame status path.
    pub fn hasForegroundProcessThorough(self: *const SessionState) bool {
        if (!self.spawned or self.dead) return false;
        if (self.tmux_backed) {
            return tmux.paneHasForegroundCommand(self.allocator, self.persist_index);
        }
        return self.hasForegroundProcess();
    }

    pub fn shellPid(self: *const SessionState) ?posix.pid_t {
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;
        return shell.child_pid;
    }

    pub fn ptyMasterFd(self: *const SessionState) ?posix.fd_t {
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;
        return shell.pty.master;
    }

    fn foregroundPgrp(self: *const SessionState) ?posix.pid_t {
        const shell = self.shell orelse return null;
        if (getForegroundPgrp(shell.child_pid)) |fg| return fg;

        const slave_path_z = ptsname(shell.pty.master) orelse return null;
        const slave_path = std.mem.sliceTo(slave_path_z, 0);
        const fd = posix.openZ(slave_path, .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch {
            return null;
        };
        defer posix.close(fd);
        const fg_pgrp = tcgetpgrp(fd);
        if (fg_pgrp <= 0) return null;
        return @intCast(fg_pgrp);
    }

    pub fn startQuitCapture(self: *SessionState) void {
        self.quit_capture_active = true;
        self.quit_capture.clearRetainingCapacity();
    }

    pub fn stopQuitCapture(self: *SessionState) void {
        self.quit_capture_active = false;
    }

    pub fn quitCaptureBytes(self: *const SessionState) []const u8 {
        return self.quit_capture.items;
    }

    /// Copies the PTY slave path into `dest` and returns a sentinel-terminated slice.
    /// Returns null when no shell is available or when `dest` is too small.
    pub fn copyPtySlavePath(self: *const SessionState, dest: []u8) ?[:0]const u8 {
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;
        const slave_path_z = ptsname(shell.pty.master) orelse return null;
        const slave_path = std.mem.sliceTo(slave_path_z, 0);
        if (slave_path.len + 1 > dest.len) return null;
        @memcpy(dest[0..slave_path.len], slave_path);
        dest[slave_path.len] = 0;
        return dest[0..slave_path.len :0];
    }

    /// Returns the AgentKind of the foreground process if it is a known AI agent.
    /// macOS only; always returns null on other platforms.
    pub fn detectForegroundAgent(self: *const SessionState) ?AgentKind {
        if (builtin.os.tag != .macos) return null;
        if (!self.spawned or self.dead) return null;
        const shell = self.shell orelse return null;

        const fg_pgrp = self.foregroundPgrp() orelse return null;
        log.debug("detectForegroundAgent: shell_pid={d} fg_pgrp={d}", .{ shell.child_pid, fg_pgrp });
        if (fg_pgrp == shell.child_pid) {
            log.debug("detectForegroundAgent: shell is foreground, no agent", .{});
            return null;
        }

        if (detectAgentByPid(fg_pgrp)) |kind| {
            log.debug("detectForegroundAgent: fg_pgrp={d} result={s} (process inspection)", .{ fg_pgrp, kind.name() });
            return kind;
        }

        // KERN_PROCARGS2 may be restricted on macOS Sequoia (returns zeroed data without
        // a special entitlement). Fall back to the icon set by the agent via OSC 1, but
        // only for foreground processes that still look like Node.js wrappers. This avoids
        // stale icon state classifying unrelated tools as AI agents.
        if (self.agent_icon) |kind| {
            if (oscFallbackEligible(fg_pgrp)) {
                log.debug("detectForegroundAgent: fg_pgrp={d} result={s} (OSC 1 icon fallback)", .{ fg_pgrp, kind.name() });
                return kind;
            }
            log.debug("detectForegroundAgent: fg_pgrp={d} ignored OSC 1 fallback for non-wrapper process", .{fg_pgrp});
        }

        log.debug("detectForegroundAgent: fg_pgrp={d} result=null", .{fg_pgrp});
        return null;
    }

    /// Store the Claude Code session name parsed from terminal title `t`. Non-Claude
    /// titles (shell/git prompt strings) are ignored, so the last captured name
    /// sticks even while the shell repaints its own title between agent turns.
    fn setTitle(self: *SessionState, t: []const u8) !void {
        const name = osc_title.claudeSessionName(t) orelse return;
        if (self.title) |old| {
            if (std.mem.eql(u8, old, name)) return; // unchanged; avoid churn
        }
        const dup = try self.allocator.dupe(u8, name);
        if (self.title) |old| self.allocator.free(old);
        self.title = dup;
    }
};

fn terminalColorsFromTheme(theme: colors_mod.Theme) ghostty_vt.Terminal.Colors {
    var palette = ghostty_vt.color.default;
    for (theme.palette, 0..) |entry, idx| {
        palette[idx] = .{
            .r = entry.r,
            .g = entry.g,
            .b = entry.b,
        };
    }

    return .{
        .background = .init(.{
            .r = theme.background.r,
            .g = theme.background.g,
            .b = theme.background.b,
        }),
        .foreground = .init(.{
            .r = theme.foreground.r,
            .g = theme.foreground.g,
            .b = theme.foreground.b,
        }),
        .cursor = .unset,
        .palette = .init(palette),
    };
}

/// Returns the AgentKind for a given PID by inspecting its process name via sysctl.
/// Falls back to KERN_PROCARGS2 for Node.js wrappers.
fn detectAgentByPid(pid: posix.pid_t) ?AgentKind {
    if (builtin.os.tag != .macos) return null;
    var comm_buf: [32]u8 = undefined;
    const comm = readProcessComm(pid, &comm_buf) orelse {
        log.debug("detectAgentByPid: failed to read p_comm for pid={d}", .{pid});
        return null;
    };
    log.debug("detectAgentByPid: pid={d} p_comm={s}", .{ pid, comm });

    if (AgentKind.fromComm(comm)) |kind| return kind;

    // Try proc_pidpath for the full executable path. More reliable than KERN_PROCARGS2 on
    // macOS Sequoia, where KERN_PROCARGS2 may return zeroed data without a special entitlement.
    // This covers bundled runtimes like claude, whose p_comm is a version string ("2.1.50")
    // but whose exec path contains "claude".
    var path_buf: [posix.PATH_MAX]u8 = undefined;
    const path_len = proc_pidpath(@intCast(pid), &path_buf, path_buf.len);
    if (path_len > 0) {
        const exec_path = path_buf[0..@intCast(path_len)];
        log.debug("detectAgentByPid: proc_pidpath={s}", .{exec_path});
        if (AgentKind.fromPath(exec_path)) |kind| return kind;
    }

    // Fall back to KERN_PROCARGS2 for argv[1] (Node.js wrappers where the exec path is
    // just "node" but argv[1] names the agent script). This may return zeroed data on
    // Sequoia; if so, the OSC 1 icon set by the agent is used as a fallback at the call site.
    const result = detectAgentFromArgv(pid);
    log.debug("detectAgentByPid: argv scan for p_comm={s} result={?}", .{ comm, result });
    return result;
}

fn oscFallbackEligible(pid: posix.pid_t) bool {
    if (builtin.os.tag != .macos) return false;
    var comm_buf: [32]u8 = undefined;
    const comm = readProcessComm(pid, &comm_buf) orelse return false;
    return std.mem.eql(u8, comm, "node");
}

fn readProcessComm(pid: posix.pid_t, dest: []u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const mib = [_]c_int{ mac.CTL_KERN, mac.KERN_PROC, mac.KERN_PROC_PID, pid };
    var info: mac.kinfo_proc = undefined;
    var size: usize = @sizeOf(mac.kinfo_proc);
    if (mac.sysctl(@constCast(&mib), mib.len, &info, &size, null, 0) != 0) return null;
    if (size < @sizeOf(mac.kinfo_proc)) return null;

    const comm = std.mem.sliceTo(&info.kp_proc.p_comm, 0);
    if (comm.len > dest.len) return null;
    @memcpy(dest[0..comm.len], comm);
    return dest[0..comm.len];
}

/// Reads KERN_PROCARGS2 for a process and delegates to parseArgv.
fn detectAgentFromArgv(pid: posix.pid_t) ?AgentKind {
    if (builtin.os.tag != .macos) return null;
    const mib = [_]c_int{ mac.CTL_KERN, mac.KERN_PROCARGS2, pid };
    var buf: [4096]u8 = undefined;
    var size: usize = buf.len;
    if (mac.sysctl(@constCast(&mib), mib.len, &buf, &size, null, 0) != 0) return null;
    return parseArgv(buf[0..size], size);
}

/// Scans raw PTY output bytes for an OSC 1 sequence naming a known AI agent.
/// Pattern: ESC ] 1 ; <name> BEL  or  ESC ] 1 ; <name> ST (ESC \)
/// Returns the first matching AgentKind found, or null if none.
fn scanOsc1Agent(data: []const u8) ?AgentKind {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] != 0x1b or data[i + 1] != ']' or data[i + 2] != '1' or data[i + 3] != ';') continue;
        i += 4;
        const name_start = i;
        while (i < data.len and data[i] != 0x07) : (i += 1) {
            // Also stop at ST (ESC \)
            if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') break;
        }
        const icon = data[name_start..i];
        if (AgentKind.fromComm(icon)) |kind| return kind;
    }
    return null;
}

fn basenameForDisplay(path: []const u8) []const u8 {
    if (builtin.os.tag == .macos) {
        return cwd_mod.getBasename(path);
    }
    return fs.path.basename(path);
}

fn getForegroundPgrp(child_pid: posix.pid_t) ?posix.pid_t {
    if (builtin.os.tag != .macos) return null;
    const mib = [_]c_int{ mac.CTL_KERN, mac.KERN_PROC, mac.KERN_PROC_PID, child_pid };
    var info: mac.kinfo_proc = undefined;
    var size: usize = @sizeOf(mac.kinfo_proc);
    if (mac.sysctl(@constCast(&mib), mib.len, &info, &size, null, 0) != 0) return null;
    if (size < @sizeOf(mac.kinfo_proc)) return null;
    return info.kp_eproc.e_tpgid;
}

pub const MakeNonBlockingError = posix.FcntlError;

test "synchronized output timeout clears stuck terminal mode" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.spawned = true;
    session.dead = false;
    session.render_epoch = 1;
    session.synchronized_output_started_ms = 100;
    session.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer session.terminal.?.deinit(allocator);

    session.terminal.?.modes.set(.synchronized_output, true);
    try std.testing.expect(session.synchronizedOutputActive());
    try std.testing.expect(!session.expireSynchronizedOutput(1099));
    try std.testing.expect(session.synchronizedOutputActive());
    try std.testing.expect(session.expireSynchronizedOutput(1100));
    try std.testing.expect(!session.synchronizedOutputActive());
    try std.testing.expectEqual(@as(u64, 2), session.render_epoch);
}

test "synchronized output timeout resets when mode is already clear" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.spawned = true;
    session.dead = false;
    session.render_epoch = 1;
    session.synchronized_output_started_ms = 100;
    session.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer session.terminal.?.deinit(allocator);

    try std.testing.expect(!session.expireSynchronizedOutput(2000));
    try std.testing.expectEqual(@as(i64, 0), session.synchronized_output_started_ms);
    try std.testing.expectEqual(@as(u64, 1), session.render_epoch);
}

test "synchronized output timeout waits for output to go quiet" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.spawned = true;
    session.dead = false;
    session.render_epoch = 1;
    session.synchronized_output_started_ms = 100;
    session.synchronized_output_last_output_ms = 1050;
    session.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer session.terminal.?.deinit(allocator);

    session.terminal.?.modes.set(.synchronized_output, true);
    try std.testing.expect(!session.expireSynchronizedOutput(1100));
    try std.testing.expect(session.synchronizedOutputActive());
    try std.testing.expect(session.expireSynchronizedOutput(1150));
    try std.testing.expect(!session.synchronizedOutputActive());
}

test "synchronized output keeps future last-output sample" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.spawned = true;
    session.dead = false;
    session.render_epoch = 1;
    session.synchronized_output_started_ms = 100;
    session.synchronized_output_last_output_ms = 1101;
    session.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer session.terminal.?.deinit(allocator);

    session.terminal.?.modes.set(.synchronized_output, true);
    try std.testing.expect(!session.expireSynchronizedOutput(1100));
    try std.testing.expect(session.synchronizedOutputActive());
    try std.testing.expectEqual(@as(i64, 1101), session.synchronized_output_last_output_ms);
}

test "synchronized output hard timeout clears chatty sessions" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.spawned = true;
    session.dead = false;
    session.render_epoch = 1;
    session.synchronized_output_started_ms = 100;
    session.synchronized_output_last_output_ms = 5099;
    session.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = 5,
    });
    defer session.terminal.?.deinit(allocator);

    session.terminal.?.modes.set(.synchronized_output, true);
    try std.testing.expect(session.expireSynchronizedOutput(5100));
    try std.testing.expect(!session.synchronizedOutputActive());
}

test "session id mirrors persist_index" {
    const allocator = std.testing.allocator;
    const theme = colors_mod.Theme.default();

    const size = pty_mod.winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const notify_sock: [:0]const u8 = "sock";

    var session = try SessionState.init(allocator, 0, "/bin/zsh", size, notify_sock, theme);
    defer session.deinit(allocator);

    // A restored terminal reclaims its persist_index before spawning; the
    // wire id must follow it, not the slot position or a spawn counter.
    session.persist_index = 141;
    session.assignSessionId();
    try std.testing.expectEqual(@as(usize, 141), session.id);
    try std.testing.expectEqualStrings("141", std.mem.sliceTo(session.session_id_z[0..], 0));
}

test "despawn keeps active wait context alive until callback reclaims it" {
    const allocator = std.testing.allocator;
    const theme = colors_mod.Theme.default();
    const size = pty_mod.winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const notify_sock: [:0]const u8 = "sock";

    var session = try SessionState.init(allocator, 0, "/bin/zsh", size, notify_sock, theme);
    defer session.deinit(allocator);

    const wait_ctx = try allocator.create(SessionState.WaitContext);
    wait_ctx.* = .{
        .session = &session,
        .generation = 0,
        .pid = 1,
        .completion = .{},
    };
    wait_ctx.completion.flags.state = @enumFromInt(1);

    session.process_wait_ctx = wait_ctx;
    session.despawn(allocator);
    try std.testing.expect(session.process_wait_ctx == null);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var completion: xev.Completion = .{};
    const action = SessionState.processExitCallback(wait_ctx, &loop, &completion, 0);
    try std.testing.expectEqual(xev.CallbackAction.disarm, action);
}

test "resetForRespawn clears agent metadata" {
    const allocator = std.testing.allocator;
    const theme = colors_mod.Theme.default();
    const size = pty_mod.winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    const notify_sock: [:0]const u8 = "sock";

    var session = try SessionState.init(allocator, 0, "/bin/zsh", size, notify_sock, theme);
    defer session.deinit(allocator);

    session.agent_kind = .codex;
    session.agent_session_id = try allocator.dupe(u8, "sid-42");
    session.agent_metadata_captured = true;

    session.resetForRespawn();

    try std.testing.expect(session.agent_kind == null);
    try std.testing.expect(session.agent_session_id == null);
    try std.testing.expect(!session.agent_metadata_captured);
}

fn makeNonBlocking(fd: posix.fd_t) MakeNonBlockingError!void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    var o_flags: posix.O = @bitCast(@as(u32, @intCast(flags)));
    o_flags.NONBLOCK = true;
    _ = try posix.fcntl(fd, posix.F.SETFL, @as(u32, @bitCast(o_flags)));
}

fn maybeShrinkPendingWrite(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
    if (buf.items.len == 0 and buf.capacity > pending_write_shrink_threshold) {
        buf.shrinkAndFree(allocator, 0);
    }
}

test "pending write shrinks when empty and over threshold" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.ensureTotalCapacity(allocator, pending_write_shrink_threshold + 10);
    buf.items.len = pending_write_shrink_threshold + 10;
    buf.clearRetainingCapacity();

    const before = buf.capacity;
    try std.testing.expect(before > pending_write_shrink_threshold);

    maybeShrinkPendingWrite(&buf, allocator);
    try std.testing.expect(buf.capacity <= pending_write_shrink_threshold);
}

test "shouldProcessOutput drains dead sessions only during quit capture" {
    try std.testing.expect(!SessionState.shouldProcessOutput(false, false, false));
    try std.testing.expect(!SessionState.shouldProcessOutput(false, true, false));
    try std.testing.expect(SessionState.shouldProcessOutput(true, false, false));
    try std.testing.expect(!SessionState.shouldProcessOutput(true, true, false));
    try std.testing.expect(SessionState.shouldProcessOutput(true, true, true));
}

test "failAndTerminate marks dead, bumps render epoch, and drops pending writes" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.shell = null;
    session.spawned = false;
    session.dead = false;
    session.render_epoch = 4;
    session.allocator = allocator;
    session.pending_write = .empty;
    try session.pending_write.appendSlice(allocator, "queued");
    defer session.pending_write.deinit(allocator);

    session.failAndTerminate();

    try std.testing.expect(session.dead);
    try std.testing.expectEqual(@as(u64, 5), session.render_epoch);
    try std.testing.expectEqual(@as(usize, 0), session.pending_write.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.pending_write.capacity);
}

test "AgentKind.fromComm recognises known agent names" {
    try std.testing.expectEqual(AgentKind.claude, AgentKind.fromComm("claude").?);
    try std.testing.expectEqual(AgentKind.codex, AgentKind.fromComm("codex").?);
    try std.testing.expectEqual(AgentKind.gemini, AgentKind.fromComm("gemini").?);
    try std.testing.expect(AgentKind.fromComm("node") == null);
    try std.testing.expect(AgentKind.fromComm("") == null);
    try std.testing.expect(AgentKind.fromComm("python") == null);
}

test "AgentKind.fromComm round-trips through name()" {
    inline for (.{ AgentKind.claude, AgentKind.codex, AgentKind.gemini }) |kind| {
        const s = kind.name();
        try std.testing.expectEqual(kind, AgentKind.fromComm(s).?);
    }
}

test "AgentKind.fromPath matches complete components only" {
    try std.testing.expectEqual(AgentKind.claude, AgentKind.fromPath("/Users/me/.local/share/claude/versions/2.1.50").?);
    try std.testing.expectEqual(AgentKind.codex, AgentKind.fromPath("/opt/tools/codex/bin/cli").?);
    try std.testing.expectEqual(AgentKind.gemini, AgentKind.fromPath("/usr/local/gemini/run").?);
    try std.testing.expect(AgentKind.fromPath("/Users/claudette/bin/python") == null);
    try std.testing.expect(AgentKind.fromPath("/opt/codex-unrelated/node") == null);
    try std.testing.expect(AgentKind.fromPath("/usr/local/gemini-proxy/server") == null);
}

test "AgentKind.exitControlSequence uses double ctrl-c for all agents" {
    try std.testing.expectEqualStrings("\x03\x03", AgentKind.claude.exitControlSequence());
    try std.testing.expectEqualStrings("\x03\x03", AgentKind.codex.exitControlSequence());
    try std.testing.expectEqualStrings("\x03\x03", AgentKind.gemini.exitControlSequence());
}

test "parseArgv matches agent name in argv[1] (Node.js wrapper)" {
    // Layout: [argc i32][exec_path\0][argv0\0][argv1\0]
    const build = struct {
        fn blob(argc: i32, exec: []const u8, argv0: []const u8, argv1: []const u8) [512]u8 {
            var buf = [_]u8{0} ** 512;
            std.mem.writeInt(i32, buf[0..4], argc, .little);
            var pos: usize = 4;
            @memcpy(buf[pos..][0..exec.len], exec);
            pos += exec.len;
            pos += 1; // null after exec_path
            @memcpy(buf[pos..][0..argv0.len], argv0);
            pos += argv0.len;
            pos += 1; // null after argv0
            @memcpy(buf[pos..][0..argv1.len], argv1);
            return buf;
        }
    };

    const claude_blob = build.blob(3, "/usr/local/bin/node", "node", "/usr/local/lib/node_modules/@anthropic/claude/bin/claude");
    try std.testing.expectEqual(AgentKind.claude, parseArgv(&claude_blob, claude_blob.len).?);

    const codex_blob = build.blob(2, "/usr/local/bin/node", "node", "/home/user/.npm/bin/codex");
    try std.testing.expectEqual(AgentKind.codex, parseArgv(&codex_blob, codex_blob.len).?);

    const gemini_blob = build.blob(2, "/usr/local/bin/node", "node", "/usr/local/bin/gemini-cli");
    try std.testing.expectEqual(AgentKind.gemini, parseArgv(&gemini_blob, gemini_blob.len).?);

    const unknown_blob = build.blob(2, "/usr/local/bin/node", "node", "/usr/local/bin/some-other-tool");
    try std.testing.expect(parseArgv(&unknown_blob, unknown_blob.len) == null);

    const no_argv1_blob = build.blob(1, "/usr/local/bin/node", "node", "");
    try std.testing.expect(parseArgv(&no_argv1_blob, no_argv1_blob.len) == null);
}

test "parseArgv matches agent name in exec_path (bundled runtime)" {
    // Covers bundled CLIs whose p_comm is a version string (e.g. "2.1.50") and the
    // agent name only appears in the full executable path, not in argv[1].
    const build = struct {
        fn blob(argc: i32, exec: []const u8, argv0: []const u8) [512]u8 {
            var buf = [_]u8{0} ** 512;
            std.mem.writeInt(i32, buf[0..4], argc, .little);
            var pos: usize = 4;
            @memcpy(buf[pos..][0..exec.len], exec);
            pos += exec.len;
            pos += 1;
            @memcpy(buf[pos..][0..argv0.len], argv0);
            return buf;
        }
    };

    const claude_bundled = build.blob(1, "/Users/me/.local/share/claude/2.1.50", "2.1.50");
    try std.testing.expectEqual(AgentKind.claude, parseArgv(&claude_bundled, claude_bundled.len).?);

    const codex_bundled = build.blob(1, "/Users/me/.npm-global/lib/node_modules/codex/dist/cli", "cli");
    try std.testing.expectEqual(AgentKind.codex, parseArgv(&codex_bundled, codex_bundled.len).?);

    const gemini_bundled = build.blob(1, "/Users/me/.local/bin/gemini", "gemini");
    try std.testing.expectEqual(AgentKind.gemini, parseArgv(&gemini_bundled, gemini_bundled.len).?);

    const unknown_bundled = build.blob(1, "/usr/local/bin/python3", "python3");
    try std.testing.expect(parseArgv(&unknown_bundled, unknown_bundled.len) == null);
}

/// Pure parsing logic for KERN_PROCARGS2 blobs, extracted for testability.
/// Checks exec_path first (covers bundled runtimes whose binary path names the agent),
/// then argv[1] (covers Node.js wrappers where the script path names the agent).
fn parseArgv(buf: []const u8, size: usize) ?AgentKind {
    if (size < 4) return null;
    const argc = std.mem.readInt(i32, buf[0..4], .little);
    log.debug("parseArgv: argc={d} size={d} buf[4..12]={any}", .{ argc, size, buf[4..@min(12, size)] });

    var pos: usize = 4;

    // exec_path: full path to the executable
    const exec_start = pos;
    while (pos < size and buf[pos] != 0) : (pos += 1) {}
    const exec_path = buf[exec_start..pos];
    if (pos >= size) return null;
    pos += 1;

    log.debug("parseArgv: exec_path={s}", .{exec_path});

    if (std.mem.indexOf(u8, exec_path, "claude") != null) return .claude;
    if (std.mem.indexOf(u8, exec_path, "codex") != null) return .codex;
    if (std.mem.indexOf(u8, exec_path, "gemini") != null) return .gemini;

    if (argc < 2) return null;

    // skip padding nulls after exec_path
    while (pos < size and buf[pos] == 0) : (pos += 1) {}
    // skip argv[0] (process name)
    while (pos < size and buf[pos] != 0) : (pos += 1) {}
    if (pos >= size) return null;
    pos += 1;
    if (pos >= size) return null;

    // argv[1]: script path for Node.js wrappers
    const argv1_start = pos;
    while (pos < size and buf[pos] != 0) : (pos += 1) {}
    const argv1 = buf[argv1_start..pos];

    log.debug("parseArgv: argv[1]={s}", .{argv1});

    if (std.mem.indexOf(u8, argv1, "claude") != null) return .claude;
    if (std.mem.indexOf(u8, argv1, "codex") != null) return .codex;
    if (std.mem.indexOf(u8, argv1, "gemini") != null) return .gemini;
    return null;
}

test "scanOsc1Agent finds known icon with BEL terminator" {
    const data = [_]u8{
        'x',  'x',
        0x1b, ']',
        '1',  ';',
        'c',  'o',
        'd',  'e',
        'x',  0x07,
        'y',
    };
    try std.testing.expectEqual(AgentKind.codex, scanOsc1Agent(&data).?);
}

test "scanOsc1Agent finds known icon with ST terminator" {
    const data = [_]u8{
        0x1b, ']', '1', ';', 'g', 'e', 'm', 'i', 'n', 'i', 0x1b, '\\',
    };
    try std.testing.expectEqual(AgentKind.gemini, scanOsc1Agent(&data).?);
}

test "scanOsc1Agent returns first matching known icon" {
    const data = [_]u8{
        0x1b, ']', '1', ';', 'u', 'n', 'k', 'n', 'o',  'w', 'n',  0x07,
        0x1b, ']', '1', ';', 'c', 'l', 'a', 'u', 'd',  'e', 0x07, 0x1b,
        ']',  '1', ';', 'c', 'o', 'd', 'e', 'x', 0x07,
    };
    try std.testing.expectEqual(AgentKind.claude, scanOsc1Agent(&data).?);
}

test "scanOsc1Agent returns null for unknown icon name" {
    const data = [_]u8{
        0x1b, ']', '1', ';', 'r', 'a', 'n', 'd', 'o', 'm', 0x07,
    };
    try std.testing.expect(scanOsc1Agent(&data) == null);
}

test "scanOsc1Agent handles malformed and incomplete sequences" {
    const data = [_]u8{
        0x1b, ']', '1', ';', 'n', 'o', 't', // incomplete
        0x1b, ']', '2', ';', 'c', 'o', 'd', 'e', 'x', 0x07, // wrong OSC selector
        0x1b, ']', '1', ';', 'x', 0x1b, '\\', // unknown icon with ST
    };
    try std.testing.expect(scanOsc1Agent(&data) == null);
}
