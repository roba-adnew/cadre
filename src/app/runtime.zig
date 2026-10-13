// Main application entry: wires SDL3 rendering, ghostty-vt terminals, PTY-backed
// shells, and the grid/animation system that drives the 3×3 terminal wall UI.
const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const posix = std.posix;
const app_state = @import("app_state.zig");
const grid_layout = @import("grid_layout.zig");
const grid_nav = @import("grid_nav.zig");
const input_keys = @import("input_keys.zig");
const input_text = @import("input_text.zig");
const layout = @import("layout.zig");
const terminal_actions = @import("terminal_actions.zig");
const ui_host = @import("ui_host.zig");
const test_probe = @import("test_probe.zig");
const worktree = @import("worktree.zig");
const control = @import("control.zig");
const hosting_mod = @import("../session/hosting.zig");
const notify = @import("../session/notify.zig");
const notify_sound = @import("../notify_sound.zig");
const session_state = @import("../session/state.zig");
const view_state = @import("../ui/session_view_state.zig");
const platform = @import("../platform/sdl.zig");
const macos_input = @import("../platform/macos_input_source.zig");
const macos_titlebar = @import("../platform/macos_titlebar.zig");

/// User-facing app name (window title bar, bundle display name). Internal
/// identifiers (config dir, sockets, tmux prefix, env vars) keep "cadre".
pub const app_name: [*:0]const u8 = "CADRE";
const input = @import("../input/mapper.zig");
const renderer_mod = @import("../render/renderer.zig");
const pty_mod = @import("../pty.zig");
const font_mod = @import("../font.zig");
const font_paths_mod = @import("../font_paths.zig");
const config_mod = @import("../config.zig");
const logging_mod = @import("../logging.zig");
const colors_mod = @import("../colors.zig");
const ui_mod = @import("../ui/mod.zig");
const font_cache_mod = @import("../font_cache.zig");
const c = @import("../c.zig");
const dpi = @import("../dpi.zig");
const metrics_mod = @import("../metrics.zig");
const open_url = @import("../os/open.zig");
const terminal_history = @import("terminal_history.zig");
const tmux = @import("../tmux.zig");
const shell = @import("../shell.zig");

const log = std.log.scoped(.runtime);
extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;

const initial_window_width = 1200;
const initial_window_height = 900;
const default_font_size: c_int = 14;
const min_font_size: c_int = 8;
const max_font_size: c_int = 96;
/// Grid panes may need a smaller native font than the base floor so dense grids
/// stay crisp (rendered near scale 1.0). It is fine for grid text to be tiny.
const min_grid_font_size: c_int = 4;
const font_step: c_int = 1;
const ui_font_size: c_int = 18;
const active_frame_ns: i128 = 16_666_667;
const idle_frame_ns: i128 = 50_000_000;
const max_idle_render_gap_ns: i128 = 250_000_000;
const foreground_process_cache_ms: i64 = 150;
// tmux-backed sessions need a tmux subprocess to see the foreground command, so
// refresh the focused-session cache more coarsely to bound the spawn rate (~1/s).
const foreground_process_cache_tmux_ms: i64 = 1000;
const Rect = app_state.Rect;
const AnimationState = app_state.AnimationState;
const NotificationQueue = notify.NotificationQueue;
const ControlQueue = control.SpawnQueue;
const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;
const GridLayout = grid_layout.GridLayout;
const SessionMove = grid_layout.SessionMove;

const FrameWaitDecision = union(enum) {
    none,
    idle_wait_ms: c_int,
    active_sleep_ns: u64,
};

const ForegroundProcessCache = struct {
    session_idx: ?usize = null,
    last_check_ms: i64 = 0,
    value: bool = false,

    fn get(self: *ForegroundProcessCache, now_ms: i64, focused_session: usize, sessions: []const *SessionState) bool {
        if (focused_session >= sessions.len) return false;
        if (self.session_idx != focused_session) {
            self.session_idx = focused_session;
            self.last_check_ms = 0;
        }
        const session = sessions[focused_session];
        // tmux-backed: the cheap pgrp check can't see the agent (the PTY
        // foreground is the tmux client), so use the tmux-aware check, throttled
        // more coarsely since it spawns a subprocess.
        const interval = if (session.tmux_backed) foreground_process_cache_tmux_ms else foreground_process_cache_ms;
        if (self.last_check_ms == 0 or now_ms < self.last_check_ms or
            now_ms - self.last_check_ms >= interval)
        {
            self.value = if (session.tmux_backed)
                session.hasForegroundProcessThorough()
            else
                session.hasForegroundProcess();
            self.last_check_ms = now_ms;
        }
        return self.value;
    }
};

fn countForegroundProcesses(sessions: []const *SessionState) usize {
    var total: usize = 0;
    for (sessions) |session| {
        // Confirmation-path check: tmux-aware, so a running agent inside a tmux
        // pane is seen even though the PTY foreground is the tmux client. The
        // per-frame status path still uses the cheap pgrp hasForegroundProcess().
        if (session.hasForegroundProcessThorough()) {
            total += 1;
        }
    }
    return total;
}

fn countSpawnedSessions(sessions: []const *SessionState) usize {
    var count: usize = 0;
    for (sessions) |session| {
        if (session.spawned) count += 1;
    }
    return count;
}

/// Sessions shown in the grid: spawned and not hidden. Drives grid sizing/layout
/// so hidden sessions don't reserve a tile.
fn countVisibleSessions(sessions: []const *SessionState) usize {
    var count: usize = 0;
    for (sessions) |session| {
        if (session.isVisible()) count += 1;
    }
    return count;
}

fn remainingFrameBudgetNs(target_frame_ns: i128, frame_ns: i128) u64 {
    if (frame_ns >= target_frame_ns) return 0;
    return @intCast(target_frame_ns - frame_ns);
}

fn waitTimeoutMsFromNs(remaining_ns: u64) c_int {
    if (remaining_ns == 0) return 0;

    const timeout_ms = 1 + @divFloor(remaining_ns - 1, std.time.ns_per_ms);

    const max_timeout_ms: u64 = @intCast(std.math.maxInt(c_int));
    return @intCast(@min(timeout_ms, max_timeout_ms));
}

fn computeFrameWaitDecision(is_idle: bool, vsync_enabled: bool, frame_ns: i128) FrameWaitDecision {
    if (is_idle) {
        const timeout_ms = waitTimeoutMsFromNs(remainingFrameBudgetNs(idle_frame_ns, frame_ns));
        return if (timeout_ms > 0) .{ .idle_wait_ms = timeout_ms } else .none;
    }
    if (vsync_enabled) return .none;

    const sleep_ns = remainingFrameBudgetNs(active_frame_ns, frame_ns);
    return if (sleep_ns > 0) .{ .active_sleep_ns = sleep_ns } else .none;
}

fn waitForNextFrame(wait_decision: FrameWaitDecision) ?c.SDL_Event {
    return switch (wait_decision) {
        .none => null,
        .idle_wait_ms => |timeout_ms| platform.waitEventTimeout(timeout_ms),
        .active_sleep_ns => |sleep_ns| blk: {
            std.Thread.sleep(sleep_ns);
            break :blk null;
        },
    };
}

fn writeRuntimeEvent(message: []const u8, event_name: []const u8, extra_data: []const u8) void {
    logging_mod.writeEvent("runtime", message, event_name, extra_data) catch |err| {
        log.warn("failed to write runtime event {s}: {}", .{ event_name, err });
    };
}

fn agentLabel(session: *const SessionState) []const u8 {
    if (session.agent_icon) |kind| return kind.name();
    return "none";
}

/// Log a structured `session_failed` event plus a human-readable error line
/// when a session is terminated due to an unrecoverable runtime error. The
/// `source` argument names the failing call site (e.g. `process_output`) and
/// becomes the `source=` field on the event so a future investigation can
/// grep `event=session_failed source=process_output` and find every instance.
fn reportSessionFailure(session: *const SessionState, err: anyerror, source: []const u8) void {
    const agent = agentLabel(session);
    const cwd = session.cwd_path orelse "<unknown>";
    log.err(
        "session {d}: {s} failed, marking session dead: {} (agent={s} cwd={s})",
        .{ session.id, source, err, agent, cwd },
    );
    var extra_buf: [192]u8 = undefined;
    const extra = std.fmt.bufPrint(&extra_buf, "session={d} agent={s} error={s} source={s}", .{
        session.id, agent, @errorName(err), source,
    }) catch |fmt_err| {
        log.warn("failed to format session_failed event payload: {}", .{fmt_err});
        return;
    };
    writeRuntimeEvent("session terminated after unrecoverable error", "session_failed", extra);
}

fn emitViewModeTransitionEvents(
    previous_mode: app_state.ViewMode,
    next_mode: app_state.ViewMode,
    focused_session: usize,
    spawned_count: usize,
) void {
    if (previous_mode == next_mode) return;

    var extra_buf: [160]u8 = undefined;
    const extra_data = std.fmt.bufPrint(&extra_buf, "from={s} to={s} focused_session={d} spawned_count={d}", .{
        @tagName(previous_mode),
        @tagName(next_mode),
        focused_session,
        spawned_count,
    }) catch |err| {
        log.warn("failed to format runtime view event payload: {}", .{err});
        return;
    };

    if (previous_mode == .Grid and next_mode != .Grid) {
        writeRuntimeEvent("exiting grid view", "view_exit_grid", extra_data);
    }
    if (next_mode == .Grid and previous_mode != .Grid) {
        writeRuntimeEvent("entered grid view", "view_enter_grid", extra_data);
    }
    if (previous_mode == .Full and next_mode != .Full) {
        writeRuntimeEvent("exiting full view", "view_exit_full", extra_data);
    }
    if (next_mode == .Full and previous_mode != .Full) {
        writeRuntimeEvent("entered full view", "view_enter_full", extra_data);
    }
}

fn optionalStringEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn persistedAgentType(session: *const SessionState) ?[]const u8 {
    if (!session.agent_metadata_captured) return null;
    if (session.agent_kind == null or session.agent_session_id == null) return null;
    return session.agent_kind.?.name();
}

fn persistedAgentSessionId(session: *const SessionState, agent_type: ?[]const u8) ?[]const u8 {
    if (agent_type == null) return null;
    return session.agent_session_id;
}

/// Build "claude --resume <id>" (etc.) from a restored entry and stash it on the session as
/// `resume_cmd`, to be injected as CADRE_RESUME_CMD at spawn time. Must be called BEFORE
/// the session is spawned. No-op for entries without a captured agent session.
fn setResumeCommandFromEntry(
    session: *SessionState,
    entry: config_mod.Persistence.TerminalEntry,
    allocator: std.mem.Allocator,
) void {
    const agent_type_str = entry.agent_type orelse return;
    const session_id = entry.agent_session_id orelse return;
    if (session_id.len == 0) return;
    const agent_kind = session_state.AgentKind.fromComm(agent_type_str) orelse return;
    const cmd = terminal_history.buildResumeCommand(allocator, agent_kind, session_id) catch |err| {
        log.warn("failed to build resume command for slot {d}: {}", .{ session.slot_index, err });
        return;
    };
    if (session.resume_cmd) |old| allocator.free(old);
    session.resume_cmd = cmd;
}

fn seedSessionAgentMetadataFromEntry(
    session: *SessionState,
    entry: config_mod.Persistence.TerminalEntry,
    allocator: std.mem.Allocator,
) void {
    const agent_type_str = entry.agent_type orelse return;
    const session_id = entry.agent_session_id orelse return;
    if (session_id.len == 0) return;
    const agent_kind = session_state.AgentKind.fromComm(agent_type_str) orelse return;

    session.agent_kind = agent_kind;
    if (session.agent_session_id) |sid| {
        allocator.free(sid);
        session.agent_session_id = null;
    }
    session.agent_session_id = allocator.dupe(u8, session_id) catch |err| {
        log.warn("failed to seed agent session id for restored session {d}: {}", .{ session.slot_index, err });
        return;
    };
    // Treat a seeded id as captured so it keeps being persisted forward. It is a
    // real resume target (it came from a prior live capture or quit scrape), so
    // re-writing it every save is strictly better than dropping it. The live
    // SessionStart hook (or the quit scrape) overwrites it with the fresher id
    // once the agent restarts. Marking it false here meant a mid-run agent that
    // never re-fired SessionStart lost its id on the first periodic save, so the
    // next reload could no longer auto-resume it.
    session.agent_metadata_captured = true;
}

/// Give sessions[slot] the persist index `want`, swapping with whichever
/// not-yet-spawned slot currently holds it. Indices start as the identity
/// permutation at init and swaps preserve uniqueness, so two terminals can
/// never build the same tmux session name.
fn claimPersistIndex(sessions: []const *SessionState, slot: usize, want: usize) void {
    if (sessions[slot].persist_index == want) return;
    for (sessions) |other| {
        if (other.persist_index != want) continue;
        if (other.spawned) {
            // Another live terminal already owns this identity (duplicate or
            // corrupt entry); keep the slot's own index rather than collide.
            log.warn("persist index {d} already in use by a live session; slot {d} keeps {d}", .{ want, slot, sessions[slot].persist_index });
            return;
        }
        other.persist_index = sessions[slot].persist_index;
        sessions[slot].persist_index = want;
        return;
    }
    // Nobody holds it (index beyond the slot range or corrupt file) — safe to take.
    sessions[slot].persist_index = want;
}

fn terminalEntriesMatchSessions(
    persistence: *const config_mod.Persistence,
    sessions: []const *SessionState,
) bool {
    var entry_idx: usize = 0;
    for (sessions) |session| {
        if (!session.spawned or session.dead) continue;
        const path = session.cwd_path orelse continue;
        if (path.len == 0) continue;

        if (entry_idx >= persistence.terminal_entries.items.len) return false;
        const entry = persistence.terminal_entries.items[entry_idx];
        const agent_type = persistedAgentType(session);
        const agent_session_id = persistedAgentSessionId(session, agent_type);

        if (!std.mem.eql(u8, entry.path, path)) return false;
        if (entry.hidden != session.hidden) return false;
        if (entry.persist_index != session.persist_index) return false;
        if (!optionalStringEql(entry.agent_type, agent_type)) return false;
        if (!optionalStringEql(entry.agent_session_id, agent_session_id)) return false;

        entry_idx += 1;
    }
    return entry_idx == persistence.terminal_entries.items.len;
}

fn syncPersistenceTerminalEntriesFromSessions(
    persistence: *config_mod.Persistence,
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !bool {
    if (terminalEntriesMatchSessions(persistence, sessions)) return false;

    persistence.clearTerminalEntries(allocator);
    for (sessions) |session| {
        if (!session.spawned or session.dead) continue;
        const path = session.cwd_path orelse continue;
        if (path.len == 0) continue;

        const agent_type = persistedAgentType(session);
        const agent_session_id = persistedAgentSessionId(session, agent_type);
        try persistence.appendTerminalEntry(allocator, path, agent_type, agent_session_id, session.hidden, session.persist_index);
    }
    return true;
}

fn savePersistenceIfDirty(
    persistence: *config_mod.Persistence,
    allocator: std.mem.Allocator,
    dirty: *bool,
) void {
    if (!dirty.*) return;
    persistence.save(allocator) catch |err| {
        std.debug.print("Failed to save persistence: {}\n", .{err});
        return;
    };
    dirty.* = false;
}

fn highestVisibleIndex(sessions: []const *SessionState) ?usize {
    var idx: usize = sessions.len;
    while (idx > 0) {
        idx -= 1;
        if (sessions[idx].isVisible()) return idx;
    }
    return null;
}

fn adjustedRenderHeightForMode(mode: app_state.ViewMode, render_height: c_int, ui_scale: f32, grid_rows: usize) c_int {
    return switch (mode) {
        .Grid => blk: {
            const cell_height = @divFloor(render_height, @as(c_int, @intCast(grid_rows)));
            const reserved_per_cell: c_int = if (cell_height >= ui_mod.cwd_bar.minCellHeight(ui_scale))
                ui_mod.cwd_bar.reservedHeight(ui_scale)
            else
                0;
            const reserved_total = reserved_per_cell * @as(c_int, @intCast(grid_rows));
            break :blk @max(0, render_height - reserved_total);
        },
        .Collapsing, .GridResizing, .Expanding, .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => render_height,
    };
}

/// Which sessions need full-window cell dimensions for the given view mode.
/// During Panning the previous session is still visible at full size on its way
/// off-screen, so it stays at full size until the pan completes.
fn fullSetForMode(mode: app_state.ViewMode, focused: usize, previous: usize) layout.FullSet {
    return switch (mode) {
        .Grid, .GridResizing => .{},
        .Full, .Expanding, .Collapsing => .{ .primary = focused },
        .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .{ .primary = focused, .secondary = previous },
    };
}

fn applyTerminalLayout(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    anim_state: *const AnimationState,
    grid_cols: usize,
    grid_rows: usize,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    full_cols: *u16,
    full_rows: *u16,
) void {
    const sizes = computeTerminalSizes(font, render_width, render_height, ui_scale, grid_cols, grid_rows, grid_cell_w, grid_cell_h);
    full_cols.* = sizes.full.cols;
    full_rows.* = sizes.full.rows;
    const full_set = fullSetForMode(anim_state.mode, anim_state.focused_session, anim_state.previous_session);
    _ = layout.applyTerminalResize(sessions, allocator, sizes, full_set);
}

fn applyTerminalLayoutIfSizeChanged(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    anim_state: *const AnimationState,
    grid_cols: usize,
    grid_rows: usize,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    full_cols: *u16,
    full_rows: *u16,
) bool {
    const sizes = computeTerminalSizes(font, render_width, render_height, ui_scale, grid_cols, grid_rows, grid_cell_w, grid_cell_h);
    full_cols.* = sizes.full.cols;
    full_rows.* = sizes.full.rows;
    const full_set = fullSetForMode(anim_state.mode, anim_state.focused_session, anim_state.previous_session);
    return layout.applyTerminalResize(sessions, allocator, sizes, full_set);
}

/// Computes both terminal sizes from the raw render dimensions. grid_size
/// always uses the Grid-mode CWD-bar reservation so unfocused sessions stay at
/// stable dims across view-mode toggles; full_size uses the raw render height.
fn computeTerminalSizes(
    font: *font_mod.Font,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    grid_cols: usize,
    grid_rows: usize,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
) layout.Sizes {
    const grid_render_height = adjustedRenderHeightForMode(.Grid, render_height, ui_scale, grid_rows);
    return layout.calculateTerminalSizes(font, render_width, grid_render_height, render_height, grid_cell_w, grid_cell_h, grid_cols, grid_rows, ui_scale);
}

const SessionIndexSnapshot = struct {
    session_id: usize,
    index: usize,
};

/// Collect indices for spawned sessions to preserve their pre-compaction positions.
fn collectSessionIndexSnapshots(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !std.ArrayList(SessionIndexSnapshot) {
    var snapshots = std.ArrayList(SessionIndexSnapshot).empty;
    for (sessions, 0..) |session, idx| {
        if (session.spawned) {
            try snapshots.append(allocator, .{ .session_id = session.id, .index = idx });
        }
    }
    return snapshots;
}

fn findSnapshotIndex(snapshots: []const SessionIndexSnapshot, session_id: usize) ?usize {
    for (snapshots) |snapshot| {
        if (snapshot.session_id == session_id) return snapshot.index;
    }
    return null;
}

const SessionMoves = struct {
    list: std.ArrayList(SessionMove),
    moved: bool,
};

/// Collect session moves using the current indices as both old and new positions.
fn collectSessionMovesCurrent(
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !std.ArrayList(SessionMove) {
    var moves = std.ArrayList(SessionMove).empty;
    for (sessions, 0..) |session, idx| {
        if (session.spawned) {
            try moves.append(allocator, .{ .session_idx = idx, .old_index = idx });
        }
    }
    return moves;
}

/// Collect session moves using snapshot indices as old positions, returning whether any moved.
fn collectSessionMovesFromSnapshots(
    sessions: []const *SessionState,
    snapshots: []const SessionIndexSnapshot,
    allocator: std.mem.Allocator,
) !SessionMoves {
    var moves = std.ArrayList(SessionMove).empty;
    var moved = false;
    for (sessions, 0..) |session, idx| {
        if (!session.spawned) continue;
        const old_index = findSnapshotIndex(snapshots, session.id);
        if (old_index) |old_idx| {
            if (old_idx != idx) moved = true;
        } else {
            moved = true;
        }
        try moves.append(allocator, .{ .session_idx = idx, .old_index = old_index });
    }
    return .{ .list = moves, .moved = moved };
}

fn findNextFreeSlotAfter(
    sessions: []const *SessionState,
    grid_capacity: usize,
    start_idx: usize,
) ?usize {
    if (grid_capacity == 0) return null;

    var offset: usize = 1;
    while (offset <= grid_capacity) : (offset += 1) {
        const idx = (start_idx + offset) % grid_capacity;
        if (idx >= sessions.len) continue;
        if (!sessions[idx].spawned) {
            return idx;
        }
    }
    return null;
}

fn findSessionIndexById(sessions: []const *SessionState, session_id: usize) ?usize {
    for (sessions, 0..) |session, idx| {
        if (session.spawned and session.id == session_id) return idx;
    }
    return null;
}

fn compactSessions(
    sessions: []*SessionState,
    views: []SessionViewState,
    render_cache: *renderer_mod.RenderCache,
    anim_state: *AnimationState,
) void {
    const focused_id: ?usize = if (anim_state.focused_session < sessions.len and sessions[anim_state.focused_session].isVisible())
        sessions[anim_state.focused_session].id
    else
        null;
    const previous_id: ?usize = if (anim_state.previous_session < sessions.len and sessions[anim_state.previous_session].isVisible())
        sessions[anim_state.previous_session].id
    else
        null;

    var write_idx: usize = 0;
    var idx: usize = 0;
    while (idx < sessions.len) : (idx += 1) {
        if (!sessions[idx].isVisible()) continue;
        if (write_idx != idx) {
            std.mem.swap(*SessionState, &sessions[write_idx], &sessions[idx]);
            std.mem.swap(SessionViewState, &views[write_idx], &views[idx]);
            std.mem.swap(renderer_mod.RenderCache.Entry, &render_cache.entries[write_idx], &render_cache.entries[idx]);
        }
        write_idx += 1;
    }

    // Park hidden sessions at the tail of the array. Since slot_index maps directly
    // to a grid cell, a hidden session left just after the visible block would sit
    // in a cell the renderer skips (blank) yet still block that slot from a new
    // terminal — making ⌘N open beyond the blanks. Pushing them to the end keeps
    // the cells between the visible block and the tail genuinely free.
    // ponytail: two-pointer partition over the non-visible tail; hidden order
    // doesn't matter since reveal mints a fresh order_seq (lands at the end).
    {
        var lo: usize = write_idx;
        var hi: usize = sessions.len;
        while (lo < hi) {
            if (!sessions[lo].hidden) {
                lo += 1;
                continue;
            }
            hi -= 1;
            if (lo == hi) break;
            if (sessions[hi].hidden) continue;
            std.mem.swap(*SessionState, &sessions[lo], &sessions[hi]);
            std.mem.swap(SessionViewState, &views[lo], &views[hi]);
            std.mem.swap(renderer_mod.RenderCache.Entry, &render_cache.entries[lo], &render_cache.entries[hi]);
            lo += 1;
        }
    }

    // Keep visible sessions in order_seq order (creation order until the user
    // drag-reorders; applyReorder renumbers order_seq and re-runs this).
    // Sorting by id looked equivalent but id = persist_index, which RECYCLES a
    // closed terminal's struct index — a later ⌘N could inherit a low id and
    // this sort would shuffle it into the middle of the grid on the next
    // close/hide.
    // ponytail: O(n^2) insertion sort, fine for the handful of grid slots.
    var a: usize = 1;
    while (a < write_idx) : (a += 1) {
        var b: usize = a;
        while (b > 0 and sessions[b - 1].order_seq > sessions[b].order_seq) : (b -= 1) {
            std.mem.swap(*SessionState, &sessions[b - 1], &sessions[b]);
            std.mem.swap(SessionViewState, &views[b - 1], &views[b]);
            std.mem.swap(renderer_mod.RenderCache.Entry, &render_cache.entries[b - 1], &render_cache.entries[b]);
        }
    }

    for (sessions, 0..) |session, slot_idx| {
        session.slot_index = slot_idx;
    }

    if (focused_id) |id| {
        if (findSessionIndexById(sessions, id)) |new_idx| {
            anim_state.focused_session = new_idx;
        }
    }
    if (previous_id) |id| {
        if (findSessionIndexById(sessions, id)) |new_idx| {
            anim_state.previous_session = new_idx;
        }
    }
}

/// Commit a drag-reorder: renumber the visible block's order_seq so the grid
/// shows `order`, then delegate the physical permutation to compactSessions
/// (which keeps sessions/views/render_cache in lockstep and remaps focus by
/// id). `order[i]` = current index of the session that should occupy slot i.
/// Renumbering from a fresh mintOrderSeqBlock range means hidden sessions and
/// the next spawn keep sorting correctly with no values reused. Returns false
/// on a stale/invalid permutation (e.g. a terminal died mid-drag) and changes
/// nothing.
/// Build the springboard permutation for moving visible slot `from` to `to`:
/// the dragged tile lands at `to`, tiles between the two shift one slot
/// toward `from`, everything outside that range stays put. Returns
/// order[i] = current index of the session that should occupy slot i.
fn springboardOrder(buf: []usize, visible: usize, from: usize, to: usize) []usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < visible) : (i += 1) {
        if (i == from) continue;
        if (w == to) w += 1; // hole for the dragged tile
        buf[w] = i;
        w += 1;
    }
    buf[to] = from;
    return buf[0..visible];
}

fn applyReorder(
    sessions: []*SessionState,
    views: []SessionViewState,
    render_cache: *renderer_mod.RenderCache,
    anim_state: *AnimationState,
    order: []const usize,
) bool {
    const visible = countVisibleSessions(sessions);
    // ponytail: u64 bitmask permutation check; grids are far below 64 tiles.
    if (order.len != visible or visible == 0 or visible > 64) {
        log.warn("reorder rejected: got {d} slots, {d} visible", .{ order.len, visible });
        return false;
    }
    var seen: u64 = 0;
    for (order) |idx| {
        if (idx >= visible or !sessions[idx].isVisible()) {
            log.warn("reorder rejected: index {d} not in visible block", .{idx});
            return false;
        }
        const bit = @as(u64, 1) << @intCast(idx);
        if (seen & bit != 0) {
            log.warn("reorder rejected: duplicate index {d}", .{idx});
            return false;
        }
        seen |= bit;
    }
    const base = session_state.mintOrderSeqBlock(order.len);
    for (order, 0..) |session_idx, slot| {
        sessions[session_idx].order_seq = base + slot;
    }
    compactSessions(sessions, views, render_cache, anim_state);
    return true;
}

const WorkingDir = struct {
    cwd_z: ?[:0]const u8,
    buf: ?[]u8,

    fn init(allocator: std.mem.Allocator, cwd_path: ?[]const u8) WorkingDir {
        var buf: ?[]u8 = null;
        const cwd_z: ?[:0]const u8 = if (cwd_path) |path| blk: {
            const owned = allocator.alloc(u8, path.len + 1) catch break :blk null;
            @memcpy(owned[0..path.len], path);
            owned[path.len] = 0;
            buf = owned;
            break :blk owned[0..path.len :0];
        } else null;

        return .{
            .cwd_z = cwd_z,
            .buf = buf,
        };
    }

    fn deinit(self: *WorkingDir, allocator: std.mem.Allocator) void {
        if (self.buf) |buf| allocator.free(buf);
    }
};

const ExternalSpawnPlan = struct {
    slot_index: usize,
    cols: usize,
    rows: usize,
    expands_grid: bool,
};

fn planExternalSpawnSlot(
    sessions: []const *SessionState,
    grid_cols: usize,
    grid_rows: usize,
    focused_session: usize,
) ?ExternalSpawnPlan {
    // Physical array occupancy (incl. hidden) caps how many shells can exist;
    // grid sizing below is driven by the VISIBLE count, since hidden sessions are
    // parked off-grid by compactSessions and don't reserve a cell.
    if (countSpawnedSessions(sessions) >= grid_layout.max_terminals) return null;
    const visible_count = countVisibleSessions(sessions);

    const capacity = grid_cols * grid_rows;
    if (visible_count >= capacity) {
        const new_dims = GridLayout.calculateDimensions(visible_count + 1);
        const new_capacity = new_dims.cols * new_dims.rows;
        if (new_capacity > grid_layout.max_terminals) return null;
        const slot_index = findNextFreeSlotAfter(sessions, new_capacity, focused_session) orelse return null;
        return .{
            .slot_index = slot_index,
            .cols = new_dims.cols,
            .rows = new_dims.rows,
            .expands_grid = true,
        };
    }

    const slot_index = if (focused_session < sessions.len and !sessions[focused_session].spawned)
        focused_session
    else
        findNextFreeSlotAfter(sessions, capacity, focused_session) orelse return null;

    return .{
        .slot_index = slot_index,
        .cols = grid_cols,
        .rows = grid_rows,
        .expands_grid = false,
    };
}

fn validateExternalSpawnCwd(cwd: []const u8) ?control.SpawnFailure {
    if (!std.fs.path.isAbsolute(cwd)) {
        return .{
            .code = .invalid_cwd,
            .message = "cwd must be an absolute directory",
        };
    }

    var dir = std.fs.openDirAbsolute(cwd, .{}) catch {
        return .{
            .code = .invalid_cwd,
            .message = "cwd must be an existing directory",
        };
    };
    dir.close();
    return null;
}

fn buildQueuedCommand(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    if (command.len == 0) return error.EmptyCommand;
    const needs_newline = command[command.len - 1] != '\n';
    const out_len = command.len + @as(usize, if (needs_newline) 1 else 0);
    const out = try allocator.alloc(u8, out_len);
    @memcpy(out[0..command.len], command);
    if (needs_newline) out[out.len - 1] = '\n';
    return out;
}

fn completeExternalSpawnFailure(
    pending: *control.PendingSpawn,
    code: control.SpawnErrorCode,
    message: []const u8,
) void {
    pending.completion.complete(.{ .failure = .{
        .code = code,
        .message = message,
    } });
}

fn handleExternalSpawnRequest(
    allocator: std.mem.Allocator,
    pending: *control.PendingSpawn,
    sessions: []const *SessionState,
    grid: *GridLayout,
    anim_state: *AnimationState,
    session_interaction_component: *ui_mod.SessionInteractionComponent,
    loop: *xev.Loop,
    animations_enabled: bool,
    now: i64,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    font: *font_mod.Font,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    full_cols: *u16,
    full_rows: *u16,
    cell_width_pixels: *c_int,
    cell_height_pixels: *c_int,
) void {
    if (validateExternalSpawnCwd(pending.request.cwd)) |failure| {
        pending.completion.complete(.{ .failure = failure });
        return;
    }

    const plan = planExternalSpawnSlot(sessions, grid.cols, grid.rows, anim_state.focused_session) orelse {
        completeExternalSpawnFailure(pending, .full_grid, "all Cadre terminal slots are in use");
        return;
    };

    const command_input = if (pending.request.command) |command| blk: {
        break :blk buildQueuedCommand(allocator, command) catch |err| {
            log.warn("failed to prepare external spawn command: {}", .{err});
            completeExternalSpawnFailure(pending, .spawn_failed, "failed to prepare command for the new session");
            return;
        };
    } else null;
    defer if (command_input) |input_bytes| allocator.free(input_bytes);

    const cwd_buf = allocZ(allocator, pending.request.cwd) catch |err| {
        log.warn("failed to allocate external spawn cwd: {}", .{err});
        completeExternalSpawnFailure(pending, .spawn_failed, "failed to prepare working directory");
        return;
    };
    defer allocator.free(cwd_buf);
    const cwd_z: [:0]const u8 = cwd_buf[0..pending.request.cwd.len :0];

    if (plan.expands_grid) {
        var moves = collectSessionMovesCurrent(sessions, allocator) catch |err| {
            log.warn("failed to collect external spawn grid moves: {}", .{err});
            completeExternalSpawnFailure(pending, .spawn_failed, "failed to prepare grid expansion");
            return;
        };
        defer moves.deinit(allocator);

        if (animations_enabled) {
            grid.startResize(plan.cols, plan.rows, now, render_width, render_height, moves.items) catch |err| {
                log.warn("failed to start external spawn grid resize: {}", .{err});
                grid.cols = plan.cols;
                grid.rows = plan.rows;
            };
            if (grid.is_resizing) {
                anim_state.mode = .GridResizing;
            }
        } else {
            grid.cols = plan.cols;
            grid.rows = plan.rows;
        }
    }

    const session = sessions[plan.slot_index];
    session.ensureSpawnedFresh(cwd_z, loop) catch |err| {
        log.warn("external spawn failed for cwd {s}: {}", .{ pending.request.cwd, err });
        completeExternalSpawnFailure(pending, .spawn_failed, "failed to spawn terminal session");
        return;
    };

    if (command_input) |input_bytes| {
        session.pending_write.appendSlice(allocator, input_bytes) catch |err| {
            log.warn("failed to queue external spawn command for session {d}: {}", .{ session.id, err });
            completeExternalSpawnFailure(pending, .spawn_failed, "failed to queue command for the new session");
            return;
        };
    }

    session_interaction_component.setAttention(plan.slot_index, false, now);
    session_interaction_component.clearSelection(anim_state.focused_session);
    session_interaction_component.clearSelection(plan.slot_index);

    anim_state.previous_session = anim_state.focused_session;
    anim_state.focused_session = plan.slot_index;

    cell_width_pixels.* = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
    cell_height_pixels.* = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
    applyTerminalLayout(
        sessions,
        allocator,
        font,
        render_width,
        render_height,
        ui_scale,
        anim_state,
        grid.cols,
        grid.rows,
        grid_cell_w,
        grid_cell_h,
        full_cols,
        full_rows,
    );

    pending.completion.complete(.{ .success = .{
        .session_id = session.id,
        .slot_index = plan.slot_index,
    } });
}

/// Close the terminal in `idx`, reclaim its grid slot, and relayout/animate the
/// remaining sessions exactly as the close-pane keybinding does. Shared by the
/// `.DespawnSession` UI action and the external `close_session` control request
/// so a programmatic close goes through the same battle-tested path (rather than
/// signal-killing the child, which would leave a dead, unresponsive pane).
fn despawnSessionAtIndex(
    idx: usize,
    /// When true, keep the session alive and just hide it from the grid (Cmd+H)
    /// instead of tearing it down. The grid reflow is identical either way.
    hide: bool,
    allocator: std.mem.Allocator,
    sessions: []*SessionState,
    grid: *GridLayout,
    anim_state: *AnimationState,
    session_interaction_component: *ui_mod.SessionInteractionComponent,
    render_cache: *renderer_mod.RenderCache,
    loop: *xev.Loop,
    animations_enabled: bool,
    now: i64,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    font: *font_mod.Font,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    full_cols: *u16,
    full_rows: *u16,
    cell_width_pixels: *c_int,
    cell_height_pixels: *c_int,
) void {
    if (idx >= sessions.len) return;

    if (anim_state.mode == .Full and anim_state.focused_session == idx) {
        if (animations_enabled) {
            grid_nav.startCollapseToGrid(anim_state, now, cell_width_pixels.*, cell_height_pixels.*, render_width, render_height, grid.cols);
        } else {
            anim_state.mode = .Grid;
        }
    }
    log.info("despawn idx={d} mode={s} spawned_count={d}", .{
        idx,
        @tagName(anim_state.mode),
        countSpawnedSessions(sessions),
    });
    var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
    defer if (old_positions) |*snapshots| {
        snapshots.deinit(allocator);
    };
    if (animations_enabled and anim_state.mode == .Grid) {
        old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
            std.debug.print("Failed to snapshot session positions: {}\n", .{err});
            break :blk null;
        };
    }
    if (hide) {
        // Keep the session (shell/PTY/agent) alive; just drop it from the grid,
        // preserving its view state so it returns exactly as it was.
        sessions[idx].hidden = true;
    } else {
        sessions[idx].despawn(allocator);
        session_interaction_component.resetView(idx);
    }
    sessions[idx].markDirty();
    compactSessions(sessions, session_interaction_component.viewSlice(), render_cache, anim_state);

    // Handle grid contraction (hidden sessions don't count toward grid size).
    const remaining_count = countVisibleSessions(sessions);
    const max_spawned_idx = highestVisibleIndex(sessions);
    const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

    if (remaining_count == 0) {
        // Re-spawn a fresh terminal in slot 0
        sessions[0].ensureSpawnedWithLoop(loop) catch |err| {
            std.debug.print("Failed to respawn terminal: {}\n", .{err});
        };
        anim_state.focused_session = 0;
        grid.cols = 1;
        grid.rows = 1;
        cell_width_pixels.* = render_width;
        cell_height_pixels.* = render_height;
        anim_state.mode = .Full;
        applyTerminalLayout(sessions, allocator, font, render_width, render_height, ui_scale, anim_state, grid.cols, grid.rows, grid_cell_w, grid_cell_h, full_cols, full_rows);
    } else if (remaining_count == 1) {
        // Only 1 terminal remains - go directly to Full mode, no resize animation
        grid.cols = 1;
        grid.rows = 1;
        cell_width_pixels.* = render_width;
        cell_height_pixels.* = render_height;
        if (!sessions[anim_state.focused_session].isVisible()) {
            for (sessions, 0..) |s, i| {
                if (s.isVisible()) {
                    anim_state.focused_session = i;
                    break;
                }
            }
        }
        anim_state.mode = .Full;
        applyTerminalLayout(sessions, allocator, font, render_width, render_height, ui_scale, anim_state, grid.cols, grid.rows, grid_cell_w, grid_cell_h, full_cols, full_rows);
    } else {
        const new_dims = GridLayout.calculateDimensions(required_slots);
        const should_shrink = new_dims.cols < grid.cols or new_dims.rows < grid.rows;
        if (should_shrink) {
            const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
            const grid_will_resize = new_dims.cols != grid.cols or new_dims.rows != grid.rows;
            if (can_animate_reflow) {
                if (old_positions) |snapshots| {
                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                        std.debug.print("Failed to collect session moves: {}\n", .{err});
                        break :blk null;
                    };
                    if (move_result) |*moves| {
                        defer moves.list.deinit(allocator);
                        if (grid_will_resize or moves.moved) {
                            grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                            };
                            anim_state.mode = .GridResizing;
                        } else {
                            grid.cols = new_dims.cols;
                            grid.rows = new_dims.rows;
                        }
                    } else {
                        grid.cols = new_dims.cols;
                        grid.rows = new_dims.rows;
                    }
                } else {
                    grid.cols = new_dims.cols;
                    grid.rows = new_dims.rows;
                }
            } else {
                grid.cols = new_dims.cols;
                grid.rows = new_dims.rows;
            }

            cell_width_pixels.* = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
            cell_height_pixels.* = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
            applyTerminalLayout(sessions, allocator, font, render_width, render_height, ui_scale, anim_state, grid.cols, grid.rows, grid_cell_w, grid_cell_h, full_cols, full_rows);

            if (!sessions[anim_state.focused_session].isVisible()) {
                var new_focus: usize = 0;
                for (sessions, 0..) |s, i| {
                    if (s.isVisible()) {
                        new_focus = i;
                        break;
                    }
                }
                anim_state.focused_session = new_focus;
            }
            std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ grid.cols, grid.rows, remaining_count });
        } else {
            const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
            if (can_animate_reflow) {
                if (old_positions) |snapshots| {
                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                        std.debug.print("Failed to collect session moves: {}\n", .{err});
                        break :blk null;
                    };
                    if (move_result) |*moves| {
                        defer moves.list.deinit(allocator);
                        if (moves.moved) {
                            grid.startResize(grid.cols, grid.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                            };
                            anim_state.mode = .GridResizing;
                        }
                    }
                }
            }
            if (!sessions[anim_state.focused_session].isVisible()) {
                var new_focus: usize = 0;
                for (sessions, 0..) |s, i| {
                    if (s.isVisible()) {
                        new_focus = i;
                        break;
                    }
                }
                anim_state.focused_session = new_focus;
            }
        }
    }
}

/// Resolve which spawned slot an external close request targets: by session id
/// if given, else by explicit slot_index. Returns null when nothing matches.
fn resolveCloseTargetIndex(sessions: []const *SessionState, request: control.CloseRequest) ?usize {
    if (request.session_id) |session_id| {
        return findSessionIndexById(sessions, session_id);
    }
    if (request.slot_index) |slot_index| {
        if (slot_index < sessions.len and sessions[slot_index].spawned) return slot_index;
    }
    return null;
}

fn handleExternalCloseRequest(
    allocator: std.mem.Allocator,
    pending: *control.PendingClose,
    sessions: []*SessionState,
    grid: *GridLayout,
    anim_state: *AnimationState,
    session_interaction_component: *ui_mod.SessionInteractionComponent,
    render_cache: *renderer_mod.RenderCache,
    loop: *xev.Loop,
    animations_enabled: bool,
    now: i64,
    render_width: c_int,
    render_height: c_int,
    ui_scale: f32,
    font: *font_mod.Font,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    full_cols: *u16,
    full_rows: *u16,
    cell_width_pixels: *c_int,
    cell_height_pixels: *c_int,
) void {
    const idx = resolveCloseTargetIndex(sessions, pending.request) orelse {
        pending.completion.complete(.{ .failure = .{
            .code = .not_found,
            .message = "no Cadre session matches the requested identifier",
        } });
        return;
    };

    const session_id = sessions[idx].id;
    despawnSessionAtIndex(
        idx,
        false,
        allocator,
        sessions,
        grid,
        anim_state,
        session_interaction_component,
        render_cache,
        loop,
        animations_enabled,
        now,
        render_width,
        render_height,
        ui_scale,
        font,
        grid_cell_w,
        grid_cell_h,
        full_cols,
        full_rows,
        cell_width_pixels,
        cell_height_pixels,
    );

    pending.completion.complete(.{ .success = .{ .session_id = session_id } });
}

fn initSharedFont(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    cache: *font_cache_mod.FontCache,
    size: c_int,
) font_mod.Font.InitError!font_mod.Font {
    const faces = cache.get(size) catch |err| switch (err) {
        error.FontUnavailable => return error.FontLoadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return font_mod.Font.initFromFaces(allocator, renderer, .{
        .regular = faces.regular,
        .bold = faces.bold,
        .italic = faces.italic,
        .bold_italic = faces.bold_italic,
        .symbol_embedded = faces.symbol_embedded,
        .symbol = faces.symbol,
        .symbol_secondary = faces.symbol_secondary,
        .emoji = faces.emoji,
    });
}

fn markTeardownComplete(flag: *bool) bool {
    if (flag.*) return false;
    flag.* = true;
    return true;
}

fn swapTwoResources(
    comptime Resource: type,
    comptime Context: type,
    comptime InitError: type,
    first: *Resource,
    second: *Resource,
    ctx: *Context,
    init_first: *const fn (ctx: *Context) InitError!Resource,
    init_second: *const fn (ctx: *Context) InitError!Resource,
    deinit_resource: *const fn (resource: *Resource) void,
) InitError!void {
    var next_first = try init_first(ctx);
    errdefer deinit_resource(&next_first);

    var next_second = try init_second(ctx);
    errdefer deinit_resource(&next_second);

    deinit_resource(first);
    deinit_resource(second);
    first.* = next_first;
    second.* = next_second;
}

const FontReloadContext = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    shared_cache: *font_cache_mod.FontCache,
    ui_cache: *font_cache_mod.FontCache,
    font_size: c_int,
    ui_scale: f32,
};

fn initTerminalFontForReload(ctx: *FontReloadContext) font_mod.Font.InitError!font_mod.Font {
    return initSharedFont(
        ctx.allocator,
        ctx.renderer,
        ctx.shared_cache,
        layout.scaledFontSize(ctx.font_size, ctx.ui_scale),
    );
}

fn initUiFontForReload(ctx: *FontReloadContext) font_mod.Font.InitError!font_mod.Font {
    return initSharedFont(
        ctx.allocator,
        ctx.renderer,
        ctx.ui_cache,
        layout.scaledFontSize(ui_font_size, ctx.ui_scale),
    );
}

fn deinitFontResource(font: *font_mod.Font) void {
    font.deinit();
}

fn reloadFontsForScale(
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    shared_cache: *font_cache_mod.FontCache,
    ui_cache: *font_cache_mod.FontCache,
    font_size: c_int,
    ui_scale: f32,
    metrics_ptr: ?*metrics_mod.Metrics,
    font: *font_mod.Font,
    ui_font: *font_mod.Font,
) font_mod.Font.InitError!void {
    var ctx = FontReloadContext{
        .allocator = allocator,
        .renderer = renderer,
        .shared_cache = shared_cache,
        .ui_cache = ui_cache,
        .font_size = font_size,
        .ui_scale = ui_scale,
    };
    try swapTwoResources(
        font_mod.Font,
        FontReloadContext,
        font_mod.Font.InitError,
        font,
        ui_font,
        &ctx,
        initTerminalFontForReload,
        initUiFontForReload,
        deinitFontResource,
    );
    font.metrics = metrics_ptr;
}

fn applyScaleChangeAndResize(
    comptime Context: type,
    comptime ReloadError: type,
    ctx: *Context,
    prev_scale: f32,
    next_scale: f32,
    reload_fn: *const fn (ctx: *Context) ReloadError!void,
    resize_fn: *const fn (ctx: *Context) void,
) ReloadError!void {
    if (next_scale != prev_scale) {
        try reload_fn(ctx);
    }
    resize_fn(ctx);
}

const RuntimeScaleChangeContext = struct {
    allocator: std.mem.Allocator,
    renderer: *c.SDL_Renderer,
    shared_font_cache: *font_cache_mod.FontCache,
    ui_font_cache: *font_cache_mod.FontCache,
    font_size: c_int,
    ui_scale: f32,
    metrics_ptr: ?*metrics_mod.Metrics,
    font: *font_mod.Font,
    ui_font: *font_mod.Font,
    ui: *ui_mod.UiRoot,
    sessions: []const *SessionState,
    render_width: c_int,
    render_height: c_int,
    anim_state: *const AnimationState,
    grid_cols: usize,
    grid_rows: usize,
    grid_cell_w: c_int,
    grid_cell_h: c_int,
    full_cols: *u16,
    full_rows: *u16,
};

fn reloadRuntimeFontsForScaleChange(ctx: *RuntimeScaleChangeContext) font_mod.Font.InitError!void {
    try reloadFontsForScale(
        ctx.allocator,
        ctx.renderer,
        ctx.shared_font_cache,
        ctx.ui_font_cache,
        ctx.font_size,
        ctx.ui_scale,
        ctx.metrics_ptr,
        ctx.font,
        ctx.ui_font,
    );
    ctx.ui.assets.ui_font = ctx.ui_font;
}

fn applyRuntimeResizeForScaleChange(ctx: *RuntimeScaleChangeContext) void {
    const sizes = computeTerminalSizes(ctx.font, ctx.render_width, ctx.render_height, ctx.ui_scale, ctx.grid_cols, ctx.grid_rows, ctx.grid_cell_w, ctx.grid_cell_h);
    ctx.full_cols.* = sizes.full.cols;
    ctx.full_rows.* = sizes.full.rows;
    const full_set = fullSetForMode(ctx.anim_state.mode, ctx.anim_state.focused_session, ctx.anim_state.previous_session);
    _ = layout.applyTerminalResize(
        ctx.sessions,
        ctx.allocator,
        sizes,
        full_set,
    );
}

fn handleQuitRequest(
    sessions: []const *SessionState,
    confirm: *ui_mod.quit_confirm.QuitConfirmComponent,
) bool {
    const running_processes = countForegroundProcesses(sessions);
    if (running_processes > 0) {
        confirm.show(running_processes);
        return false;
    }
    return true;
}

const quit_primary_wait_ms: u64 = 2500;
const quit_retry_wait_ms: u64 = 2500;
const quit_term_wait_ms: u64 = 500;
const quit_capture_drain_poll_ns: u64 = 20 * std.time.ns_per_ms;
const quit_capture_drain_quiet_ns: i128 = 250 * @as(i128, std.time.ns_per_ms);
const quit_capture_drain_max_ns: i128 = 2500 * @as(i128, std.time.ns_per_ms);

const QuitTeardownTask = struct {
    session_idx: usize,
    shell_pid: posix.pid_t,
    pty_master: posix.fd_t,
    agent_kind: session_state.AgentKind,
    slave_path_len: usize = 0,
    slave_path: [posix.PATH_MAX + 1]u8 = [_]u8{0} ** (posix.PATH_MAX + 1),

    fn slavePathZ(self: *const QuitTeardownTask) [:0]const u8 {
        return self.slave_path[0..self.slave_path_len :0];
    }
};

const QuitTeardownWorker = struct {
    tasks: []QuitTeardownTask,
    done: *std.atomic.Value(bool),

    fn run(self: *QuitTeardownWorker) void {
        defer self.done.store(true, .seq_cst);
        var threads: [grid_layout.max_terminals]?std.Thread = [_]?std.Thread{null} ** grid_layout.max_terminals;
        for (self.tasks, 0..) |*task, idx| {
            threads[idx] = std.Thread.spawn(.{}, runTask, .{task}) catch |err| blk: {
                log.warn("quit teardown: failed to spawn parallel task for session {d}: {}", .{ task.session_idx, err });
                runTask(task);
                break :blk null;
            };
        }
        for (threads[0..self.tasks.len]) |thread_opt| {
            if (thread_opt) |thread| {
                thread.join();
            }
        }
    }

    fn runTask(task: *QuitTeardownTask) void {
        log.info("quit teardown: session {d} has foreground agent {s}", .{ task.session_idx, task.agent_kind.name() });
        sendExitSequence(task.pty_master, task.agent_kind);
        std.Thread.sleep(quit_primary_wait_ms * std.time.ns_per_ms);

        var fg_pgrp = foregroundPgrp(task.slavePathZ(), task.shell_pid);
        if (fg_pgrp != null) {
            log.debug("quit teardown: session {d} agent {s} still foreground after primary quit, retrying with interrupt", .{ task.session_idx, task.agent_kind.name() });
            sendExitSequence(task.pty_master, task.agent_kind);
            std.Thread.sleep(quit_retry_wait_ms * std.time.ns_per_ms);
            fg_pgrp = foregroundPgrp(task.slavePathZ(), task.shell_pid);
        }

        if (fg_pgrp) |pgrp| {
            log.debug("quit teardown: session {d} agent {s} did not exit gracefully, sending SIGTERM", .{ task.session_idx, task.agent_kind.name() });
            _ = std.c.kill(-pgrp, std.c.SIG.TERM);
            std.Thread.sleep(quit_term_wait_ms * std.time.ns_per_ms);
        } else {
            log.debug("quit teardown: session {d} agent {s} exited gracefully", .{ task.session_idx, task.agent_kind.name() });
        }
    }
};

const QuitTeardownState = struct {
    active: bool = false,
    task_count: usize = 0,
    tasks: [grid_layout.max_terminals]QuitTeardownTask = undefined,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: QuitTeardownWorker = undefined,
    thread: ?std.Thread = null,

    fn start(self: *QuitTeardownState, sessions: []*SessionState) !bool {
        if (self.active) return true;

        self.task_count = 0;
        for (sessions, 0..) |session, idx| {
            const agent_kind = session.detectForegroundAgent() orelse continue;
            const shell_pid = session.shellPid() orelse continue;
            const pty_master = session.ptyMasterFd() orelse continue;

            var task = QuitTeardownTask{
                .session_idx = idx,
                .shell_pid = shell_pid,
                .pty_master = pty_master,
                .agent_kind = agent_kind,
            };
            const copied_path = session.copyPtySlavePath(task.slave_path[0..]) orelse continue;
            task.slave_path_len = copied_path.len;

            session.startQuitCapture();
            self.tasks[self.task_count] = task;
            self.task_count += 1;
        }

        if (self.task_count == 0) return false;

        self.done.store(false, .seq_cst);
        self.worker = .{
            .tasks = self.tasks[0..self.task_count],
            .done = &self.done,
        };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{&self.worker});
        self.active = true;
        return true;
    }

    fn isFinished(self: *const QuitTeardownState) bool {
        return self.active and self.done.load(.seq_cst);
    }

    fn join(self: *QuitTeardownState) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn workerMain(worker: *QuitTeardownWorker) void {
        worker.run();
    }
};

fn sendExitSequence(master_fd: posix.fd_t, agent_kind: session_state.AgentKind) void {
    const sequence = agent_kind.exitControlSequence();
    for (sequence, 0..) |byte, idx| {
        const buf = [1]u8{byte};
        _ = posix.write(master_fd, &buf) catch |err| {
            log.warn("quit teardown: failed to send exit key sequence (step {d}) for {s}: {}", .{ idx + 1, agent_kind.name(), err });
            return;
        };
        if (idx + 1 < sequence.len) {
            std.Thread.sleep(220 * std.time.ns_per_ms);
        }
    }
    log.debug("quit teardown: wrote exit command for agent {s}", .{agent_kind.name()});
}

fn foregroundPgrp(slave_path_z: [:0]const u8, shell_pid: posix.pid_t) ?posix.pid_t {
    const fd = posix.openZ(slave_path_z, .{ .ACCMODE = .RDONLY, .NOCTTY = true }, 0) catch return null;
    defer posix.close(fd);
    const fg = tcgetpgrp(fd);
    if (fg <= 0) return null;
    const fg_pgrp: posix.pid_t = @intCast(fg);
    if (fg_pgrp == shell_pid) return null;
    return fg_pgrp;
}

fn drainQuitCaptureOutput(tasks: []const QuitTeardownTask, sessions: []const *SessionState) void {
    if (tasks.len == 0) return;

    var last_capture_lengths: [grid_layout.max_terminals]usize = [_]usize{0} ** grid_layout.max_terminals;
    for (tasks, 0..) |task, idx| {
        last_capture_lengths[idx] = sessions[task.session_idx].quitCaptureBytes().len;
    }

    const start_ns = std.time.nanoTimestamp();
    var last_growth_ns = start_ns;

    while (true) {
        var saw_growth = false;
        for (tasks, 0..) |task, idx| {
            const session = sessions[task.session_idx];
            session.processOutput() catch |err| {
                log.warn("quit teardown: session {d} post-worker output drain failed: {}", .{ task.session_idx, err });
            };
            const new_len = session.quitCaptureBytes().len;
            if (new_len > last_capture_lengths[idx]) {
                saw_growth = true;
            }
            last_capture_lengths[idx] = new_len;
        }

        const now_ns = std.time.nanoTimestamp();
        if (saw_growth) {
            last_growth_ns = now_ns;
        }

        if (!shouldContinueQuitCaptureDrain(start_ns, last_growth_ns, now_ns)) break;
        std.Thread.sleep(quit_capture_drain_poll_ns);
    }
}

fn shouldContinueQuitCaptureDrain(start_ns: i128, last_growth_ns: i128, now_ns: i128) bool {
    const quiet_elapsed = now_ns - last_growth_ns;
    const total_elapsed = now_ns - start_ns;
    return quiet_elapsed < quit_capture_drain_quiet_ns and total_elapsed < quit_capture_drain_max_ns;
}

fn startQuitFlow(
    quit_state: *QuitTeardownState,
    sessions: []*SessionState,
    overlay: *ui_mod.quit_blocking_overlay.QuitBlockingOverlayComponent,
) bool {
    if (builtin.os.tag != .macos) return true;
    if (quit_state.active) return false;
    const started = quit_state.start(sessions) catch |err| {
        log.warn("quit teardown: failed to start worker thread: {}", .{err});
        return true;
    };
    if (!started) return true;
    overlay.setActive(true);
    return false;
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Socket listener relays external "awaiting approval / done" signals from
    // shells (or other tools) into the UI thread without blocking rendering.
    var notify_queue = NotificationQueue{};
    defer notify_queue.deinit(allocator);

    var control_queue = ControlQueue{};
    defer control_queue.deinit(allocator);

    var close_queue = control.CloseQueue{};
    defer close_queue.deinit(allocator);

    const notify_sock = try notify.getNotifySocketPath(allocator);
    defer allocator.free(notify_sock);

    const control_sock = try control.getControlSocketPath(allocator);
    defer allocator.free(control_sock);

    const control_discovery_path = try control.getControlDiscoveryPath(allocator);
    defer allocator.free(control_discovery_path);

    var notify_stop = std.atomic.Value(bool).init(false);
    var control_stop = std.atomic.Value(bool).init(false);

    var config = config_mod.Config.load(allocator) catch |err| blk: {
        if (err == error.ConfigNotFound) {
            std.debug.print("Config not found, creating default config file\n", .{});
            config_mod.Config.createDefaultConfigFile(allocator) catch |create_err| {
                std.debug.print("Failed to create default config: {}\n", .{create_err});
            };
        } else {
            std.debug.print("Failed to load config: {}, using defaults\n", .{err});
        }
        break :blk config_mod.Config{
            .font = .{ .size = default_font_size },
            .window = .{
                .width = initial_window_width,
                .height = initial_window_height,
            },
        };
    };
    defer config.deinit(allocator);

    var file_logging_enabled = false;
    logging_mod.init(allocator, .{
        .min_level = config.logging.getMinLevel(),
    }) catch |err| {
        std.debug.print("Failed to initialize file logging: {}\n", .{err});
    };
    if (logging_mod.isInitialized()) {
        file_logging_enabled = true;
        logging_mod.writeStartupMarker() catch |err| {
            std.debug.print("Failed to write startup marker: {}\n", .{err});
        };
    }
    defer {
        if (file_logging_enabled) {
            logging_mod.writeShutdownMarker() catch |err| {
                std.debug.print("Failed to write shutdown marker: {}\n", .{err});
            };
        }
        logging_mod.deinit();
    }

    var persistence = config_mod.Persistence.load(allocator) catch |err| blk: {
        std.debug.print("Failed to load persistence: {}, using defaults\n", .{err});
        var fallback = config_mod.Persistence.init(allocator);
        fallback.font_size = config.font.size;
        fallback.window = config.window;
        break :blk fallback;
    };
    errdefer persistence.deinit(allocator);
    persistence.font_size = std.math.clamp(persistence.font_size, min_font_size, max_font_size);

    // Mint the per-install tmux-name epoch (first launch after upgrade) and hand
    // it to the tmux layer BEFORE any session spawns, so `cadre-<epoch>-<n>`
    // names are used from the very first buildPersist. Save immediately so the
    // epoch is stable across relaunch (reattach depends on the name being equal).
    if (persistence.ensurePersistEpoch(allocator) catch |err| blk: {
        log.warn("failed to generate persist epoch: {}", .{err});
        break :blk false;
    }) {
        persistence.save(allocator) catch |err| {
            log.warn("failed to save freshly generated persist epoch: {}", .{err});
        };
    }
    tmux.setEpoch(persistence.persist_epoch);
    // Heal a server left poisoned by an older build (stale global resume cmd)
    // before any session spawns or reattaches this run.
    tmux.scrubStaleGlobalEnv(allocator);
    // Ensure Claude's hooks (incl. the SessionStart id-capture hook) are installed
    // so a running agent's resume id is written to persistence.toml WHILE it runs.
    // That live capture is the only way a conversation survives a full device
    // reboot, which SIGKILLs the process with no chance to scrape the id at quit.
    // Runs before the restore spawns below, so this run's agents get the hook too.
    shell.ensureClaudeHookInstalled(allocator);

    // Seed the live grid font scale: a persisted value (from a previous
    // Cmd+Opt +/- adjustment) wins over the static [font]/[grid] config; then
    // mirror it back so future persistence saves keep it in sync.
    if (persistence.grid_font_scale != 0) {
        config.grid.font_scale = std.math.clamp(persistence.grid_font_scale, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
    }
    persistence.grid_font_scale = config.grid.font_scale;

    // Initialize recent folders with home directory if empty
    if (persistence.recent_folders.items.len == 0) {
        if (std.posix.getenv("HOME")) |home| {
            persistence.appendRecentFolder(allocator, home) catch |err| {
                log.warn("failed to initialize recent folders with home: {}", .{err});
            };
        }
    }

    const theme = colors_mod.Theme.fromConfig(config.theme);

    // Dynamic grid layout - starts with 1x1 and grows as terminals are added
    var grid = try GridLayout.init(allocator);
    defer grid.deinit();

    // Load persisted terminals to determine initial grid size
    const restored_entries = if (builtin.os.tag == .macos) persistence.terminal_entries.items else &[_]config_mod.Persistence.TerminalEntry{};
    const restored_limit = @min(restored_entries.len, grid_layout.max_terminals);
    const restored_slice = restored_entries[0..restored_limit];

    // Calculate initial grid size from the VISIBLE restored terminals only —
    // hidden ones are spawned (below) but don't reserve a grid tile. Entries are
    // saved already compacted (visible first, hidden last), so the visible ones
    // land at the front slots and the grid sizes to them.
    const initial_visible_count: usize = blk: {
        var v: usize = 0;
        for (restored_slice) |entry| {
            if (!entry.hidden) v += 1;
        }
        break :blk v;
    };
    const initial_terminal_count: usize = if (initial_visible_count > 0) initial_visible_count else 1;
    const initial_dims = GridLayout.calculateDimensions(initial_terminal_count);
    grid.cols = initial_dims.cols;
    grid.rows = initial_dims.rows;

    const animations_enabled = config.ui.enable_animations;

    const window_pos = if (persistence.window.x >= 0 and persistence.window.y >= 0)
        platform.WindowPosition{ .x = persistence.window.x, .y = persistence.window.y }
    else
        null;

    var sdl = try platform.init(
        app_name,
        persistence.window.width,
        persistence.window.height,
        window_pos,
        config.rendering.vsync,
    );
    defer platform.deinit(&sdl);
    macos_titlebar.style(sdl.window, app_name, theme.background.r, theme.background.g, theme.background.b);
    platform.startTextInput(sdl.window);
    defer platform.stopTextInput(sdl.window);
    const notify_thread = try notify.startNotifyThread(
        allocator,
        notify_sock,
        &notify_queue,
        &notify_stop,
        .{
            .context = &sdl,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        notify_stop.store(true, .seq_cst);
        notify_thread.join();
    }
    notify.linkLegacySocketPath(allocator, notify_sock);
    const control_thread = try control.startControlThread(
        allocator,
        control_sock,
        control_discovery_path,
        &control_queue,
        &close_queue,
        &control_stop,
        .{
            .context = &sdl,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        control_stop.store(true, .seq_cst);
        control.failPending(&control_queue, allocator, .app_not_running, "Cadre is shutting down");
        control.failPendingClose(&close_queue, allocator, .app_not_running, "Cadre is shutting down");
        control_thread.join();
        control.cleanupControlFiles(control_sock, control_discovery_path);
    }
    var text_input_active = true;
    var input_source_tracker = macos_input.InputSourceTracker.init();
    defer input_source_tracker.deinit();
    if (builtin.os.tag == .macos) {
        input_source_tracker.capture() catch |err| {
            log.warn("Failed to capture input source: {}", .{err});
        };
    }

    const renderer = sdl.renderer;

    var font_size: c_int = persistence.font_size;
    // Whether the Cadre window is the frontmost app (drives the accent
    // overlay). Assume focused at launch; updated by SDL focus events.
    var window_focused: bool = true;
    var window_width_points: c_int = sdl.window_w;
    var window_height_points: c_int = sdl.window_h;
    var render_width: c_int = sdl.render_w;
    var render_height: c_int = sdl.render_h;
    var scale_x = sdl.scale_x;
    var scale_y = sdl.scale_y;
    var ui_scale: f32 = @max(scale_x, scale_y);

    var font_paths = try font_paths_mod.FontPaths.init(allocator, config.font.family);
    defer font_paths.deinit();

    var shared_font_cache = font_cache_mod.FontCache.initWithFallbacks(allocator, false);
    defer shared_font_cache.deinit();
    shared_font_cache.setPaths(
        font_paths.regular,
        font_paths.bold,
        font_paths.italic,
        font_paths.bold_italic,
        font_paths.symbol_fallback,
        font_paths.symbol_fallback_secondary,
        font_paths.emoji_fallback,
    );

    var ui_font_cache = font_cache_mod.FontCache.initWithFallbacks(allocator, true);
    defer ui_font_cache.deinit();
    ui_font_cache.setPaths(
        font_paths.regular,
        font_paths.bold,
        font_paths.italic,
        font_paths.bold_italic,
        font_paths.symbol_fallback,
        font_paths.symbol_fallback_secondary,
        font_paths.emoji_fallback,
    );

    var metrics_storage: metrics_mod.Metrics = metrics_mod.Metrics.init();
    const metrics_ptr: ?*metrics_mod.Metrics = if (config.metrics.enabled) &metrics_storage else null;
    metrics_mod.global = metrics_ptr;

    var font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(font_size, ui_scale));
    defer font.deinit();
    font.metrics = metrics_ptr;

    // Grid view renders this second, non-owning Font (faces shared with
    // shared_font_cache) opened at the grid's native cell size, so small text
    // stays crisp instead of being GPU-downscaled. Rebuilt before render() when
    // the target size or the font cache generation changes.
    var grid_font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(font_size, ui_scale));
    defer grid_font.deinit();
    grid_font.metrics = metrics_ptr;
    var grid_font_size: c_int = layout.scaledFontSize(font_size, ui_scale);
    var grid_font_generation: u64 = shared_font_cache.generation;
    var grid_render_scale: f32 = 1.0;
    // Per-grid-shape font scale: when the grid shape changes, load its saved
    // preset (Cmd+Opt zoom is remembered per "<cols>x<rows>"). 0 = not yet resolved.
    var resolved_grid_cols: usize = 0;
    var resolved_grid_rows: usize = 0;

    var ui_font = try initSharedFont(allocator, renderer, &ui_font_cache, layout.scaledFontSize(ui_font_size, ui_scale));
    defer ui_font.deinit();

    var ui = ui_mod.UiRoot.init(allocator);
    var ui_deinitialized = false;
    errdefer if (markTeardownComplete(&ui_deinitialized)) ui.deinit(renderer);
    ui.assets.ui_font = &ui_font;
    ui.assets.font_cache = &ui_font_cache;

    var window_x: c_int = persistence.window.x;
    var window_y: c_int = persistence.window.y;

    const initial_view_mode: app_state.ViewMode = if (initial_terminal_count == 1) .Full else .Grid;
    const initial_term_render_height = adjustedRenderHeightForMode(initial_view_mode, render_height, ui_scale, grid.rows);
    const initial_sizes = computeTerminalSizes(&font, render_width, render_height, ui_scale, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height);
    var full_cols: u16 = initial_sizes.full.cols;
    var full_rows: u16 = initial_sizes.full.rows;

    std.debug.print("Grid cell terminal size: {d}x{d}; full size: {d}x{d}\n", .{ initial_sizes.grid.cols, initial_sizes.grid.rows, full_cols, full_rows });

    const shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";
    std.debug.print("Starting with {d}x{d} grid: {s}\n", .{ grid.cols, grid.rows, shell_path });

    var cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
    var cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));

    const terminal_padding = dpi.scale(renderer_mod.terminal_padding, ui_scale);
    const usable_width = @max(0, render_width - terminal_padding * 2);
    const usable_height = @max(0, initial_term_render_height - terminal_padding * 2);

    // All sessions seed at grid-cell size. The first applyTerminalLayoutIfSizeChanged
    // promotes the focused session to full size if the initial view is Full.
    const size = pty_mod.winsize{
        .ws_row = initial_sizes.grid.rows,
        .ws_col = initial_sizes.grid.cols,
        .ws_xpixel = @intCast(usable_width),
        .ws_ypixel = @intCast(usable_height),
    };

    // Allocate max possible sessions to avoid reallocation
    const sessions_storage = try allocator.alloc(SessionState, grid_layout.max_terminals);
    const sessions = blk: {
        errdefer allocator.free(sessions_storage);
        break :blk try allocator.alloc(*SessionState, grid_layout.max_terminals);
    };
    var init_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < init_count) : (i += 1) {
            sessions_storage[i].deinit(allocator);
        }
        allocator.free(sessions_storage);
        allocator.free(sessions);
    }
    defer if (markTeardownComplete(&ui_deinitialized)) ui.deinit(renderer);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Initialize all session slots
    for (0..grid_layout.max_terminals) |i| {
        sessions_storage[i] = try SessionState.init(allocator, i, shell_path, size, notify_sock, theme);
        sessions[i] = &sessions_storage[i];
        init_count += 1;
    }

    // Restore persisted terminals
    for (restored_slice, 0..) |entry, new_idx| {
        if (new_idx >= sessions.len or entry.path.len == 0) continue;
        const dir_buf = allocZ(allocator, entry.path) catch |err| blk: {
            std.debug.print("Failed to restore terminal {d}: {}\n", .{ new_idx, err });
            break :blk null;
        };
        defer if (dir_buf) |buf| allocator.free(buf);
        if (dir_buf) |buf| {
            const dir: [:0]const u8 = buf[0..entry.path.len :0];

            // Reclaim the terminal's own tmux identity BEFORE spawning, so
            // `new-session -A` targets the exact session it used last run.
            // Restoring by grid position instead orphaned any terminal whose
            // persist index had drifted from its position, and the reaper
            // below then killed the orphan (agent and all).
            if (entry.persist_index) |want| claimPersistIndex(sessions, new_idx, want);

            // An id can appear on multiple entries (from a stale-hook smear);
            // resuming it twice would fork one conversation into two
            // terminals. First entry wins; later ones start plain shells.
            const duplicate_resume_id: ?[]const u8 = if (entry.agent_session_id) |id| blk: {
                for (restored_slice[0..new_idx]) |prev| {
                    const prev_id = prev.agent_session_id orelse continue;
                    if (std.mem.eql(u8, prev_id, id)) break :blk id;
                }
                break :blk null;
            } else null;

            // Build the resume command BEFORE spawning: it is injected as
            // CADRE_RESUME_CMD into the shell env and run once by the wrapper rc
            // after the user's rc loads — no stdin race, can't be eaten by a startup prompt.
            if (duplicate_resume_id) |id| {
                log.warn("restored terminal {d}: agent session id {s} already claimed by an earlier terminal; not resuming it twice", .{ new_idx, id });
            } else {
                setResumeCommandFromEntry(sessions[new_idx], entry, allocator);
            }

            const expected_session = tmux.hasSession(allocator, sessions[new_idx].persist_index);
            sessions[new_idx].ensureSpawnedWithDir(dir, &loop) catch |err| {
                std.debug.print("Failed to spawn restored terminal {d}: {}\n", .{ new_idx, err });
            };
            if (sessions[new_idx].spawned) {
                if (sessions[new_idx].tmux_backed) {
                    if (expected_session) {
                        log.info("restored terminal {d}: reattached to tmux persist index {d}", .{ new_idx, sessions[new_idx].persist_index });
                    } else {
                        log.warn("restored terminal {d}: no tmux session for persist index {d}; started fresh (resume fallback)", .{ new_idx, sessions[new_idx].persist_index });
                    }
                }
                if (duplicate_resume_id == null) {
                    seedSessionAgentMetadataFromEntry(sessions[new_idx], entry, allocator);
                }
                // Restore as hidden: alive but out of the grid until revealed.
                sessions[new_idx].hidden = entry.hidden;
            }
        }
    }

    // Always spawn at least the first terminal
    try sessions[0].ensureSpawnedWithLoop(&loop);

    init_count = sessions.len;

    // Now that every restored/first session has reattached and holds a client,
    // drain the socket's detached-session graveyard (crashed instances, closed
    // terminals, pre-epoch fossils). Ours read as attached, so they're spared,
    // and so are the persisted indices we still want (a spawn failure above
    // must not cost the agent its session). Same-epoch sessions are only fair
    // game once every restored entry carried an index — a legacy file without
    // them can't tell a graveyard fossil from a live terminal's session.
    if (sessions[0].tmux_backed) {
        var keep_buf: [grid_layout.max_terminals]usize = undefined;
        var keep_len: usize = 0;
        var all_indexed = true;
        for (restored_slice) |entry| {
            if (entry.persist_index) |pi| {
                if (keep_len < keep_buf.len) {
                    keep_buf[keep_len] = pi;
                    keep_len += 1;
                }
            } else all_indexed = false;
        }
        tmux.reapDetachedSessions(allocator, keep_buf[0..keep_len], all_indexed);
    }

    const session_ui_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_layout.max_terminals);
    defer allocator.free(session_ui_info);

    var render_cache = try renderer_mod.RenderCache.init(allocator, grid_layout.max_terminals);
    defer render_cache.deinit();

    var foreground_cache = ForegroundProcessCache{};

    var running = true;
    var persistence_dirty = false;
    var quit_teardown = QuitTeardownState{};
    defer quit_teardown.join();

    // Restore focus + zoom from persistence (2c): clamp the focused pane to the restored
    // count, and only honor zoom when there is a pane to zoom into. The renderer computes
    // the Full rect from the window each frame, so setting .Full directly is sufficient.
    const restored_focus: usize = if (persistence.focused_session < initial_terminal_count)
        persistence.focused_session
    else
        0;
    const initial_mode: app_state.ViewMode = if (persistence.zoomed and initial_terminal_count >= 1)
        .Full
    else
        initial_view_mode;
    var anim_state = AnimationState{
        .mode = initial_mode,
        .focused_session = restored_focus,
        .previous_session = restored_focus,
        .start_time = 0,
        .start_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .target_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
    };
    var ime_composition = input_text.ImeComposition{};
    var last_focused_session: usize = anim_state.focused_session;
    var last_logged_mode = anim_state.mode;
    var relaunch_trace_frames: u8 = 0;
    var window_close_suppress_countdown: u8 = 0;

    const PendingCommentSend = struct {
        session: usize,
        text: []const u8,
        send_after_ms: i64,
    };
    var pending_comment_send: ?PendingCommentSend = null;

    // "hosting" badge state for the hidden switcher. Detection spawns
    // subprocesses, so it only polls while the switcher modal is open.
    const hosting_poll_interval_ms: i64 = 5000;
    var hosting_last_poll_ms: ?i64 = null;
    const hosting_flags = try allocator.alloc(bool, sessions.len);
    defer allocator.free(hosting_flags);

    const session_interaction_component = try ui_mod.SessionInteractionComponent.init(allocator, sessions, &font);
    try ui.register(session_interaction_component.asComponent());

    // Cmd+F find-in-terminal. Shares the interaction component's per-session
    // view states so its highlight/scroll reuses the same selection + scrollback
    // machinery as mouse selection.
    const find_bar_component = try ui_mod.find_bar.FindBarComponent.init(
        allocator,
        sessions,
        session_interaction_component.viewSlice(),
    );
    try ui.register(find_bar_component.asComponent());

    // Restored terminals land sequentially (visible first, hidden right after).
    // Compact once so hidden sessions get parked off-grid, otherwise the first ⌘N
    // after a reload would open beyond the restored hidden sessions' slots.
    compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);

    const worktree_comp_ptr = try allocator.create(ui_mod.worktree_overlay.WorktreeOverlayComponent);
    worktree_comp_ptr.* = .{ .allocator = allocator };
    const worktree_component = ui_mod.UiComponent{
        .ptr = worktree_comp_ptr,
        .vtable = &ui_mod.worktree_overlay.WorktreeOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(worktree_component);

    const recent_folders_comp_ptr = try allocator.create(ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent);
    recent_folders_comp_ptr.* = .{ .allocator = allocator };
    const recent_folders_component = ui_mod.UiComponent{
        .ptr = recent_folders_comp_ptr,
        .vtable = &ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(recent_folders_component);
    recent_folders_comp_ptr.setFolders(persistence.getRecentFolders());

    const hidden_switcher_comp_ptr = try allocator.create(ui_mod.hidden_switcher.HiddenSwitcherComponent);
    hidden_switcher_comp_ptr.* = .{ .allocator = allocator };
    try ui.register(.{
        .ptr = hidden_switcher_comp_ptr,
        .vtable = &ui_mod.hidden_switcher.HiddenSwitcherComponent.vtable,
        .z_index = 1000,
    });

    // Top-right count pill; z below the switcher modal so the modal dims over it.
    const hidden_indicator_comp_ptr = try allocator.create(ui_mod.hidden_indicator.HiddenIndicatorComponent);
    hidden_indicator_comp_ptr.* = .{ .allocator = allocator, .switcher = hidden_switcher_comp_ptr };
    try ui.register(.{
        .ptr = hidden_indicator_comp_ptr,
        .vtable = &ui_mod.hidden_indicator.HiddenIndicatorComponent.vtable,
        .z_index = 999,
    });

    const help_comp_ptr = try allocator.create(ui_mod.help_overlay.HelpOverlayComponent);
    help_comp_ptr.* = .{ .allocator = allocator };
    const help_component = ui_mod.UiComponent{
        .ptr = help_comp_ptr,
        .vtable = &ui_mod.help_overlay.HelpOverlayComponent.vtable,
        .z_index = 1000,
    };
    try ui.register(help_component);

    const pill_group_component = try ui_mod.pill_group.PillGroupComponent.create(allocator, help_comp_ptr, recent_folders_comp_ptr, worktree_comp_ptr, hidden_indicator_comp_ptr);
    try ui.register(pill_group_component);
    const toast_component = try ui_mod.toast.ToastComponent.init(allocator);
    try ui.register(toast_component.asComponent());
    ui.toast_component = toast_component;
    // Escape-hold-to-collapse is intentionally disabled: return-to-grid is now
    // Cmd+Esc, and single/double Esc must pass straight through to the focused
    // program (e.g. Claude Code's Esc-Esc rewind, vim's Esc). Leaving the
    // EscapeHoldComponent unregistered keeps Escape a plain passthrough key.
    const hotkey_component = try ui_mod.hotkey_indicator.HotkeyIndicatorComponent.init(allocator, &ui_font);
    try ui.register(hotkey_component.asComponent());
    ui.hotkey_component = hotkey_component;
    const restart_component = try ui_mod.restart_buttons.RestartButtonsComponent.init(allocator);
    try ui.register(restart_component.asComponent());
    const quit_confirm_component = try ui_mod.quit_confirm.QuitConfirmComponent.init(allocator);
    try ui.register(quit_confirm_component.asComponent());
    const quit_blocking_overlay_component = try ui_mod.quit_blocking_overlay.QuitBlockingOverlayComponent.init(allocator);
    try ui.register(quit_blocking_overlay_component.asComponent());
    const confirm_dialog_component = try ui_mod.confirm_dialog.ConfirmDialogComponent.init(allocator);
    try ui.register(confirm_dialog_component.asComponent());
    const global_shortcuts_component = try ui_mod.global_shortcuts.GlobalShortcutsComponent.create(allocator);
    try ui.register(global_shortcuts_component);
    const cwd_bar_component = try ui_mod.cwd_bar.CwdBarComponent.init(allocator);
    try ui.register(cwd_bar_component.asComponent());
    const metrics_overlay_component = try ui_mod.metrics_overlay.MetricsOverlayComponent.init(allocator);
    try ui.register(metrics_overlay_component.asComponent());
    const diff_overlay_component = try ui_mod.diff_overlay.DiffOverlayComponent.init(allocator);
    try ui.register(diff_overlay_component.asComponent());
    const reader_overlay_component = try ui_mod.reader_overlay.ReaderOverlayComponent.init(allocator, sessions);
    try ui.register(reader_overlay_component.asComponent());
    const story_overlay_component = try ui_mod.story_overlay.StoryOverlayComponent.init(allocator);
    try ui.register(story_overlay_component.asComponent());

    // Main loop: optionally wait for the next wake-worthy event, then handle SDL
    // input, feed PTY output into terminals, apply async notifications, drive
    // animations, and render at the current cadence.
    var last_render_ns: i128 = 0;
    var next_frame_wait: FrameWaitDecision = .none;
    while (running) {
        var next_event = waitForNextFrame(next_frame_wait);
        const frame_start_ns: i128 = std.time.nanoTimestamp();
        const now = std.time.milliTimestamp();
        if (relaunch_trace_frames > 0) {
            log.info("frame trace start mode={s} grid_resizing={} grid={d}x{d}", .{
                @tagName(anim_state.mode),
                grid.is_resizing,
                grid.cols,
                grid.rows,
            });
        }

        var event: c.SDL_Event = undefined;
        var processed_event = false;
        while (true) {
            if (next_event) |ready_event| {
                event = ready_event;
                next_event = null;
            } else if (!c.SDL_PollEvent(&event)) {
                break;
            }
            if (platform.isWakeEvent(&sdl, &event)) continue;
            if (anim_state.focused_session != last_focused_session) {
                const previous_session = last_focused_session;
                input_text.clearImeComposition(sessions[previous_session], &ime_composition) catch |err| {
                    std.debug.print("Failed to clear IME composition: {}\n", .{err});
                };
                ime_composition.reset();
                last_focused_session = anim_state.focused_session;
            }
            processed_event = true;
            var scaled_event = layout.scaleEventToRender(&event, scale_x, scale_y);
            if (builtin.os.tag == .macos and scaled_event.type == c.SDL_EVENT_KEY_DOWN) {
                const key = scaled_event.key.key;
                const mod = scaled_event.key.mod;
                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                if (has_gui and !has_blocking_mod and key == c.SDLK_W) {
                    // Use 2 frames to cover the delay between Cmd+W and SDL delivering a close request.
                    // A single frame is not always enough to suppress the close in the next loop.
                    window_close_suppress_countdown = 2;
                }
            }
            const focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
            const host_snapshot = ui_host.makeUiHost(
                now,
                render_width,
                render_height,
                ui_scale,
                cell_width_pixels,
                cell_height_pixels,
                grid_font.cell_width,
                grid_font.cell_height,
                grid_font_size,
                grid.cols,
                grid.rows,
                full_cols,
                full_rows,
                &anim_state,
                sessions,
                session_ui_info,
                session_interaction_component.viewSlice(),
                focused_has_foreground_process,
                &theme,
            );
            var event_ui_host = host_snapshot;
            ui_host.applyMouseContext(&ui, &event_ui_host, &scaled_event);

            const ui_consumed = ui.handleEvent(&event_ui_host, &scaled_event);
            if (ui_consumed) continue;

            switch (scaled_event.type) {
                c.SDL_EVENT_QUIT => {
                    if (quit_teardown.active) continue;
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                            running = false;
                        }
                    }
                },
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (quit_teardown.active) continue;
                    if (builtin.os.tag == .macos and window_close_suppress_countdown > 0) {
                        // Reset immediately so we only suppress this close request.
                        window_close_suppress_countdown = 0;
                        continue;
                    }
                    if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                        if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                            running = false;
                        }
                    }
                },
                c.SDL_EVENT_WINDOW_DESTROYED => {
                    running = false;
                },
                c.SDL_EVENT_WINDOW_MOVED => {
                    window_x = scaled_event.window.data1;
                    window_y = scaled_event.window.data2;

                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence_dirty = true;
                    savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    layout.updateRenderSizes(sdl.window, &window_width_points, &window_height_points, &render_width, &render_height, &scale_x, &scale_y);
                    const prev_scale = ui_scale;
                    ui_scale = @max(scale_x, scale_y);
                    var scale_change_ctx = RuntimeScaleChangeContext{
                        .allocator = allocator,
                        .renderer = renderer,
                        .shared_font_cache = &shared_font_cache,
                        .ui_font_cache = &ui_font_cache,
                        .font_size = font_size,
                        .ui_scale = ui_scale,
                        .metrics_ptr = metrics_ptr,
                        .font = &font,
                        .ui_font = &ui_font,
                        .ui = &ui,
                        .sessions = sessions,
                        .render_width = render_width,
                        .render_height = render_height,
                        .anim_state = &anim_state,
                        .grid_cols = grid.cols,
                        .grid_rows = grid.rows,
                        .grid_cell_w = grid_font.cell_width,
                        .grid_cell_h = grid_font.cell_height,
                        .full_cols = &full_cols,
                        .full_rows = &full_rows,
                    };
                    try applyScaleChangeAndResize(
                        RuntimeScaleChangeContext,
                        font_mod.Font.InitError,
                        &scale_change_ctx,
                        prev_scale,
                        ui_scale,
                        reloadRuntimeFontsForScaleChange,
                        applyRuntimeResizeForScaleChange,
                    );
                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));

                    std.debug.print("Window resized to: {d}x{d} (render {d}x{d}), terminal size: {d}x{d}\n", .{ window_width_points, window_height_points, render_width, render_height, full_cols, full_rows });

                    persistence.window.width = window_width_points;
                    persistence.window.height = window_height_points;
                    persistence.window.x = window_x;
                    persistence.window.y = window_y;
                    persistence_dirty = true;
                    savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                },
                c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                    window_focused = false;
                    // Clear stuck modifier keys. If focus left while a modifier was
                    // held (e.g. Cmd during Cmd+Tab), macOS delivers the key-up to
                    // the other app, so SDL keeps reporting the modifier as held and
                    // plain keystrokes then act like Cmd-shortcuts. Resetting the
                    // keyboard here makes the next keystrokes start from a clean state.
                    c.SDL_ResetKeyboard();
                    if (builtin.os.tag == .macos) {
                        if (text_input_active) {
                            platform.stopTextInput(sdl.window);
                            text_input_active = false;
                        }
                    }
                    ime_composition.reset();
                },
                c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                    window_focused = true;
                    if (builtin.os.tag == .macos) {
                        input_source_tracker.restore() catch |err| {
                            log.warn("Failed to restore input source: {}", .{err});
                        };
                        // Reset text input so macOS restores the per-document input source.
                        if (text_input_active) {
                            platform.stopTextInput(sdl.window);
                        }
                        platform.startTextInput(sdl.window);
                        text_input_active = true;
                    }
                },
                c.SDL_EVENT_KEYMAP_CHANGED => {
                    if (builtin.os.tag == .macos) {
                        input_source_tracker.capture() catch |err| {
                            log.warn("Failed to capture input source: {}", .{err});
                        };
                    }
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const focused = sessions[anim_state.focused_session];
                    input_text.handleTextInput(focused, &ime_composition, scaled_event.text.text, session_interaction_component) catch |err| {
                        std.debug.print("Text input failed: {}\n", .{err});
                    };
                    if (anim_state.mode == .Grid) {
                        session_interaction_component.setAttention(anim_state.focused_session, false, now);
                    }
                },
                c.SDL_EVENT_TEXT_EDITING => {
                    const focused = sessions[anim_state.focused_session];
                    input_text.handleTextEditing(
                        focused,
                        &ime_composition,
                        scaled_event.edit.text,
                        scaled_event.edit.start,
                        scaled_event.edit.length,
                        session_interaction_component,
                    ) catch |err| {
                        std.debug.print("Edit input failed: {}\n", .{err});
                    };
                },
                c.SDL_EVENT_DROP_FILE => {
                    const drop_path_ptr = scaled_event.drop.data;
                    if (drop_path_ptr == null) continue;
                    const drop_path = std.mem.span(drop_path_ptr.?);
                    if (drop_path.len == 0) continue;

                    const mouse_x: c_int = @intFromFloat(scaled_event.drop.x);
                    const mouse_y: c_int = @intFromFloat(scaled_event.drop.y);

                    const hovered_session = layout.calculateHoveredSession(
                        mouse_x,
                        mouse_y,
                        &anim_state,
                        cell_width_pixels,
                        cell_height_pixels,
                        render_width,
                        render_height,
                        grid.cols,
                        grid.rows,
                    ) orelse continue;

                    var session = sessions[hovered_session];
                    try session.ensureSpawnedWithLoop(&loop);

                    const escaped = worktree.shellQuotePath(allocator, drop_path) catch |err| {
                        std.debug.print("Failed to escape dropped path: {}\n", .{err});
                        continue;
                    };
                    defer allocator.free(escaped);

                    terminal_actions.pasteText(session, allocator, escaped, session_interaction_component) catch |err| switch (err) {
                        error.NoTerminal => ui.showToast("No terminal to paste into", now),
                        error.NoShell => ui.showToast("Shell not available", now),
                        else => std.debug.print("Failed to paste dropped path: {}\n", .{err}),
                    };
                },
                c.SDL_EVENT_KEY_DOWN => {
                    const key = scaled_event.key.key;
                    const mod = scaled_event.key.mod;
                    const focused = sessions[anim_state.focused_session];

                    const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                    const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                    const terminal_shortcut: ?usize = if (worktree_comp_ptr.overlay.state == .Closed)
                        input.terminalSwitchShortcut(key, mod, grid.cols * grid.rows)
                    else
                        null;

                    if (has_gui and !has_blocking_mod and key == c.SDLK_Q) {
                        if (quit_teardown.active) continue;
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘Q", now);
                        if (handleQuitRequest(sessions[0..], quit_confirm_component)) {
                            if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                                running = false;
                            }
                        }
                        continue;
                    }

                    if (has_gui and !has_blocking_mod and key == c.SDLK_ESCAPE) {
                        // Cmd+Esc: collapse the focused pane back to the grid.
                        // (Plain Esc still passes through to the program.)
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⎋", now);
                        if (anim_state.mode == .Full and countSpawnedSessions(sessions) > 1) {
                            if (animations_enabled) {
                                grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                            } else {
                                const grid_row: c_int = @intCast(anim_state.focused_session / grid.cols);
                                const grid_col: c_int = @intCast(anim_state.focused_session % grid.cols);
                                anim_state.mode = .Grid;
                                anim_state.start_time = now;
                                anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };
                                anim_state.target_rect = Rect{
                                    .x = grid_col * cell_width_pixels,
                                    .y = grid_row * cell_height_pixels,
                                    .w = cell_width_pixels,
                                    .h = cell_height_pixels,
                                };
                            }
                        }
                        continue;
                    }

                    if (has_gui and !has_blocking_mod and key == c.SDLK_W) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘W", now);
                        const session_idx = anim_state.focused_session;
                        const session = sessions[session_idx];

                        if (!session.spawned) {
                            log.info("close requested on unspawned session idx={d} mode={s}", .{ session_idx, @tagName(anim_state.mode) });
                            continue;
                        }

                        if (session.hasForegroundProcessThorough()) {
                            confirm_dialog_component.show(
                                "Delete Terminal?",
                                "A process is running. Delete anyway?",
                                "Delete",
                                "Cancel",
                                .{ .DespawnSession = session_idx },
                            );
                        } else {
                            const spawned_count = countSpawnedSessions(sessions);
                            log.info("close requested idx={d} spawned_count={d} mode={s}", .{
                                session_idx,
                                spawned_count,
                                @tagName(anim_state.mode),
                            });
                            if (spawned_count == 1) {
                                var working_dir = WorkingDir.init(allocator, session.cwd_path);
                                defer working_dir.deinit(allocator);

                                log.info("relaunching last session idx={d} grid_resizing={}", .{
                                    session_idx,
                                    grid.is_resizing,
                                });
                                relaunch_trace_frames = 120;
                                try session.relaunch(working_dir.cwd_z, &loop);
                                session_interaction_component.resetView(session_idx);
                                session_interaction_component.setAttention(session_idx, false, now);
                                session.markDirty();
                                grid.cancelResize();
                                log.info("relaunch complete idx={d} spawned={} dead={}", .{
                                    session_idx,
                                    session.spawned,
                                    session.dead,
                                });
                                anim_state.mode = .Full;
                                continue;
                            }

                            // If in full view, collapse to grid first
                            if (anim_state.mode == .Full) {
                                if (animations_enabled) {
                                    grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                                } else {
                                    anim_state.mode = .Grid;
                                }
                            }

                            var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
                            defer if (old_positions) |*snapshots| {
                                snapshots.deinit(allocator);
                            };
                            if (animations_enabled and anim_state.mode == .Grid) {
                                old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                                    std.debug.print("Failed to snapshot session positions: {}\n", .{err});
                                    break :blk null;
                                };
                            }

                            // Close the terminal
                            session.despawn(allocator);
                            session_interaction_component.resetView(session_idx);
                            session.markDirty();

                            compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);

                            // Count remaining spawned sessions after closing
                            const remaining_count = countVisibleSessions(sessions);
                            const max_spawned_idx = highestVisibleIndex(sessions);
                            const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

                            // Don't shrink below 1 terminal
                            if (remaining_count == 0) {
                                // Re-spawn a fresh terminal in slot 0
                                try sessions[0].ensureSpawnedWithLoop(&loop);
                                anim_state.focused_session = 0;
                                grid.cols = 1;
                                grid.rows = 1;
                                cell_width_pixels = render_width;
                                cell_height_pixels = render_height;
                                anim_state.mode = .Full;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);
                            } else if (remaining_count == 1) {
                                // Only 1 terminal remains - go directly to Full mode, no resize animation
                                grid.cols = 1;
                                grid.rows = 1;
                                cell_width_pixels = render_width;
                                cell_height_pixels = render_height;
                                if (!sessions[anim_state.focused_session].isVisible()) {
                                    for (sessions, 0..) |s, idx| {
                                        if (s.isVisible()) {
                                            anim_state.focused_session = idx;
                                            break;
                                        }
                                    }
                                }
                                anim_state.mode = .Full;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);
                            } else {
                                const new_dims = GridLayout.calculateDimensions(required_slots);
                                const should_shrink = new_dims.cols < grid.cols or new_dims.rows < grid.rows;

                                if (should_shrink) {
                                    const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                                    const grid_will_resize = new_dims.cols != grid.cols or new_dims.rows != grid.rows;
                                    if (can_animate_reflow) {
                                        if (old_positions) |snapshots| {
                                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                                break :blk null;
                                            };
                                            if (move_result) |*moves| {
                                                defer moves.list.deinit(allocator);
                                                if (grid_will_resize or moves.moved) {
                                                    grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                        std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                                    };
                                                    anim_state.mode = .GridResizing;
                                                } else {
                                                    grid.cols = new_dims.cols;
                                                    grid.rows = new_dims.rows;
                                                }
                                            } else {
                                                grid.cols = new_dims.cols;
                                                grid.rows = new_dims.rows;
                                            }
                                        } else {
                                            grid.cols = new_dims.cols;
                                            grid.rows = new_dims.rows;
                                        }
                                    } else {
                                        grid.cols = new_dims.cols;
                                        grid.rows = new_dims.rows;
                                    }

                                    cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                                    cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                                    applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);

                                    // Update focus to a valid session
                                    if (!sessions[anim_state.focused_session].isVisible()) {
                                        var new_focus: usize = 0;
                                        for (sessions, 0..) |s, idx| {
                                            if (s.isVisible()) {
                                                new_focus = idx;
                                                break;
                                            }
                                        }
                                        anim_state.focused_session = new_focus;
                                    }

                                    std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ grid.cols, grid.rows, remaining_count });
                                } else {
                                    const can_animate_reflow = animations_enabled and anim_state.mode == .Grid;
                                    if (can_animate_reflow) {
                                        if (old_positions) |snapshots| {
                                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                                break :blk null;
                                            };
                                            if (move_result) |*moves| {
                                                defer moves.list.deinit(allocator);
                                                if (moves.moved) {
                                                    grid.startResize(grid.cols, grid.rows, now, render_width, render_height, moves.list.items) catch |err| {
                                                        std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                                    };
                                                    anim_state.mode = .GridResizing;
                                                }
                                            }
                                        }
                                    }
                                    // Grid doesn't need to shrink, just update focus if needed
                                    if (!sessions[anim_state.focused_session].isVisible()) {
                                        // Find the next spawned session
                                        var new_focus: usize = 0;
                                        for (sessions, 0..) |s, idx| {
                                            if (s.isVisible()) {
                                                new_focus = idx;
                                                break;
                                            }
                                        }
                                        anim_state.focused_session = new_focus;
                                    }
                                }
                            }
                        }
                        continue;
                    }

                    // Cmd+J hides the focused terminal (keeps it alive, drops it from
                    // the grid); Cmd+Shift+J opens the reveal picker — but the switcher
                    // consumes ⌘⇧J before this whenever anything is hidden, so here it
                    // only means "nothing to reveal". (Cmd+H is reserved by macOS.)
                    if (has_gui and !has_blocking_mod and key == c.SDLK_J) {
                        if ((mod & c.SDL_KMOD_SHIFT) == 0) {
                            if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘J", now);
                            const idx = anim_state.focused_session;
                            if (idx < sessions.len and sessions[idx].isVisible()) {
                                if (countVisibleSessions(sessions) <= 1) {
                                    ui.showToast("Can't hide the last terminal", now);
                                } else {
                                    despawnSessionAtIndex(
                                        idx,
                                        true,
                                        allocator,
                                        sessions,
                                        &grid,
                                        &anim_state,
                                        session_interaction_component,
                                        &render_cache,
                                        &loop,
                                        animations_enabled,
                                        now,
                                        render_width,
                                        render_height,
                                        ui_scale,
                                        &font,
                                        grid_font.cell_width,
                                        grid_font.cell_height,
                                        &full_cols,
                                        &full_rows,
                                        &cell_width_pixels,
                                        &cell_height_pixels,
                                    );
                                    ui.showToast("Hidden — ⌘⇧J to reveal", now);
                                }
                            }
                        } else {
                            if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⇧J", now);
                            ui.showToast("No hidden terminals", now);
                        }
                        continue;
                    }

                    if (key == c.SDLK_K and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘K", now);
                        terminal_actions.clearTerminal(focused);
                        ui.showToast("Cleared terminal", now);
                    } else if (key == c.SDLK_C and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘C", now);
                        terminal_actions.copySelectionToClipboard(focused, allocator, &ui, now) catch |err| {
                            std.debug.print("Copy failed: {}\n", .{err});
                        };
                    } else if (key == c.SDLK_V and has_gui and !has_blocking_mod) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘V", now);
                        // Opt-in: if the clipboard holds an image, forward Ctrl+V so a
                        // CLI in the terminal inlines it; otherwise paste text as usual.
                        var handled_paste = false;
                        if (config.paste.image_passthrough) {
                            handled_paste = terminal_actions.tryPasteImagePassthrough(focused, allocator, &ui, now, session_interaction_component) catch |err| blk: {
                                std.debug.print("Image paste passthrough failed: {}\n", .{err});
                                break :blk false;
                            };
                        }
                        if (!handled_paste) {
                            terminal_actions.pasteClipboardIntoSession(focused, allocator, &ui, now, session_interaction_component) catch |err| {
                                std.debug.print("Paste failed: {}\n", .{err});
                            };
                        }
                    } else if (input.fontSizeShortcut(key, mod)) |direction| {
                        // Zoom is context-aware: in grid view it changes the GRID
                        // font size; in focus view it changes the FOCUS font size.
                        // The two are persisted independently and don't bleed into
                        // each other.
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(if (direction == .increase) "⌘+" else "⌘-", now);
                        if (anim_state.mode == .Grid or anim_state.mode == .GridResizing) {
                            const grid_scale_step: f32 = 0.1;
                            const delta: f32 = if (direction == .increase) grid_scale_step else -grid_scale_step;
                            const target_scale = std.math.clamp(config.grid.font_scale + delta, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
                            if (target_scale != config.grid.font_scale) {
                                config.grid.font_scale = target_scale;
                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);
                                persistence.grid_font_scale = config.grid.font_scale;
                                persistence.setGridFontPreset(allocator, grid.cols, grid.rows, config.grid.font_scale) catch |err| {
                                    log.warn("failed to save grid font preset: {}", .{err});
                                };
                                persistence_dirty = true;
                                savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                            }
                            var grid_scale_buf: [64]u8 = undefined;
                            const grid_scale_msg = std.fmt.bufPrint(&grid_scale_buf, "Grid font: {d:.0}%", .{config.grid.font_scale * 100.0}) catch |err| blk: {
                                log.warn("failed to format grid scale toast: {}", .{err});
                                break :blk "Grid font changed";
                            };
                            ui.showToast(grid_scale_msg, now);
                        } else {
                            const delta: c_int = if (direction == .increase) font_step else -font_step;
                            const target_size = std.math.clamp(font_size + delta, min_font_size, max_font_size);
                            if (target_size != font_size) {
                                const new_font = try initSharedFont(allocator, renderer, &shared_font_cache, layout.scaledFontSize(target_size, ui_scale));
                                font.deinit();
                                font = new_font;
                                font.metrics = metrics_ptr;
                                // Grid text size scales with the focus font size, so
                                // compensate the grid scale to hold the grid steady.
                                const comp = @as(f32, @floatFromInt(font_size)) / @as(f32, @floatFromInt(target_size));
                                config.grid.font_scale = std.math.clamp(config.grid.font_scale * comp, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
                                font_size = target_size;

                                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);
                                std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ font_size, full_cols, full_rows });

                                persistence.font_size = font_size;
                                persistence.grid_font_scale = config.grid.font_scale;
                                persistence_dirty = true;
                                savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
                            }
                            var notification_buf: [64]u8 = undefined;
                            const notification_msg = std.fmt.bufPrint(&notification_buf, "Font size: {d}pt", .{font_size}) catch |err| blk: {
                                log.warn("failed to format font size toast: {}", .{err});
                                break :blk "Font size changed";
                            };
                            ui.showToast(notification_msg, now);
                        }
                    } else if (key == c.SDLK_N and has_gui and !has_blocking_mod and (anim_state.mode == .Full or anim_state.mode == .Grid)) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘N", now);

                        // Grid sizing is driven by VISIBLE sessions; hidden ones are
                        // parked off-grid by compactSessions and must not reserve a cell.
                        const visible_count = countVisibleSessions(sessions);

                        // Check if we need to expand the grid
                        if (grid.needsExpansion(visible_count)) {
                            // Calculate new grid dimensions
                            const new_dims = GridLayout.calculateDimensions(visible_count + 1);
                            if (new_dims.cols * new_dims.rows > grid_layout.max_terminals) {
                                ui.showToast("Maximum terminals reached", now);
                                continue;
                            }

                            // Get working directory from focused session
                            var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                            defer working_dir.deinit(allocator);

                            const new_capacity = new_dims.cols * new_dims.rows;
                            const new_idx = findNextFreeSlotAfter(sessions, new_capacity, anim_state.focused_session) orelse {
                                ui.showToast("All terminals in use", now);
                                continue;
                            };

                            // Collect active sessions for animation
                            var moves = collectSessionMovesCurrent(sessions, allocator) catch |err| {
                                std.debug.print("Failed to collect session moves: {}\n", .{err});
                                continue;
                            };
                            defer moves.deinit(allocator);

                            // Update grid dimensions and start animation
                            if (animations_enabled) {
                                grid.startResize(new_dims.cols, new_dims.rows, now, render_width, render_height, moves.items) catch |err| {
                                    std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                };
                                anim_state.mode = .GridResizing;
                            } else {
                                grid.cols = new_dims.cols;
                                grid.rows = new_dims.rows;
                            }

                            // Spawn new terminal
                            try sessions[new_idx].ensureSpawnedFresh(working_dir.cwd_z, &loop);
                            session_interaction_component.setAttention(new_idx, false, now);

                            // Update cell dimensions for new grid
                            cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                            cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                            applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);

                            session_interaction_component.clearSelection(anim_state.focused_session);
                            session_interaction_component.clearSelection(new_idx);

                            anim_state.previous_session = anim_state.focused_session;
                            anim_state.focused_session = new_idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, new_idx, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);
                            std.debug.print("Grid expanded to {d}x{d}, new terminal at index {d}\n", .{ grid.cols, grid.rows, new_idx });
                        } else {
                            // Grid has space, find next free slot
                            const target_idx: ?usize = if (!focused.spawned)
                                anim_state.focused_session
                            else
                                findNextFreeSlotAfter(sessions, grid.capacity(), anim_state.focused_session);

                            if (target_idx) |next_free_idx| {
                                var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                                defer working_dir.deinit(allocator);

                                try sessions[next_free_idx].ensureSpawnedFresh(working_dir.cwd_z, &loop);
                                session_interaction_component.setAttention(next_free_idx, false, now);

                                session_interaction_component.clearSelection(anim_state.focused_session);
                                session_interaction_component.clearSelection(next_free_idx);

                                anim_state.previous_session = anim_state.focused_session;
                                anim_state.focused_session = next_free_idx;

                                const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                                const notification_buf = try allocator.alloc(u8, buf_size);
                                defer allocator.free(notification_buf);
                                const notification_msg = try grid_nav.formatGridNotification(notification_buf, next_free_idx, grid.cols, grid.rows);
                                ui.showToast(notification_msg, now);
                            } else {
                                ui.showToast("All terminals in use", now);
                            }
                        }
                    } else if (terminal_shortcut) |idx| {
                        const hotkey_label = input.terminalHotkeyLabel(idx) orelse "⌘?";
                        if (config.ui.show_hotkey_feedback) ui.showHotkey(hotkey_label, now);

                        if (anim_state.mode == .Grid) {
                            try sessions[idx].ensureSpawnedWithLoop(&loop);
                            session_interaction_component.acknowledgeAttention(idx);
                            session_interaction_component.setAttention(idx, false, now);

                            const grid_row: c_int = @intCast(idx / grid.cols);
                            const grid_col: c_int = @intCast(idx % grid.cols);
                            const start_rect = Rect{
                                .x = grid_col * cell_width_pixels,
                                .y = grid_row * cell_height_pixels,
                                .w = cell_width_pixels,
                                .h = cell_height_pixels,
                            };
                            const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                            anim_state.focused_session = idx;
                            if (animations_enabled) {
                                anim_state.mode = .Expanding;
                                anim_state.start_time = now;
                                anim_state.start_rect = start_rect;
                                anim_state.target_rect = target_rect;
                            } else {
                                anim_state.mode = .Full;
                                anim_state.start_time = now;
                                anim_state.start_rect = target_rect;
                                anim_state.target_rect = target_rect;
                                anim_state.previous_session = idx;
                            }
                            std.debug.print("Expanding session via hotkey: {d}\n", .{idx});
                        } else if (anim_state.mode == .Full and idx != anim_state.focused_session) {
                            try sessions[idx].ensureSpawnedWithLoop(&loop);
                            session_interaction_component.clearSelection(anim_state.focused_session);
                            session_interaction_component.clearSelection(idx);
                            session_interaction_component.acknowledgeAttention(idx);
                            session_interaction_component.setAttention(idx, false, now);
                            anim_state.focused_session = idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, idx, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);
                            std.debug.print("Switched to session via hotkey: {d}\n", .{idx});
                        }
                    } else if (input.gridNavShortcut(key, mod)) |direction| {
                        if (anim_state.mode == .Grid) {
                            if (config.ui.show_hotkey_feedback) {
                                const arrow = switch (direction) {
                                    .up => "⇧↑",
                                    .down => "⇧↓",
                                    .left => "⇧←",
                                    .right => "⇧→",
                                };
                                ui.showHotkey(arrow, now);
                            }
                            try grid_nav.navigateGrid(&anim_state, sessions, session_interaction_component, direction, now, true, false, grid.cols, grid.rows, &loop);
                            const new_session = anim_state.focused_session;
                            session_interaction_component.acknowledgeAttention(new_session);
                            session_interaction_component.triggerNavWave(new_session, now);
                            std.debug.print("Grid nav to session {d} (with wrapping)\n", .{new_session});
                        } else if (anim_state.mode == .Full) {
                            if (config.ui.show_hotkey_feedback) {
                                const arrow = switch (direction) {
                                    .up => "⇧↑",
                                    .down => "⇧↓",
                                    .left => "⇧←",
                                    .right => "⇧→",
                                };
                                ui.showHotkey(arrow, now);
                            }
                            try grid_nav.navigateGrid(&anim_state, sessions, session_interaction_component, direction, now, true, animations_enabled, grid.cols, grid.rows, &loop);
                            session_interaction_component.acknowledgeAttention(anim_state.focused_session);

                            const buf_size = grid_nav.gridNotificationBufferSize(grid.cols, grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, anim_state.focused_session, grid.cols, grid.rows);
                            ui.showToast(notification_msg, now);

                            std.debug.print("Full mode grid nav to session {d}\n", .{anim_state.focused_session});
                        } else {
                            if (focused.spawned and !focused.dead) {
                                session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                                try input_keys.handleKeyInput(focused, key, mod);
                            }
                        }
                    } else if (input.jumpToBottomShortcut(key, mod)) {
                        // Cmd+Shift+Down → send Ctrl+End so the focused TUI (e.g.
                        // Claude Code) jumps to the bottom of its scroll. Stands in
                        // for the physical Ctrl+End, which macOS window managers
                        // grab as Ctrl+Fn+→. Focused live pane only.
                        if (focused.spawned and !focused.dead) {
                            if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⇧↓", now);
                            session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                            focused.sendInput(input.ctrl_end_sequence) catch |err| {
                                log.warn("jump-to-bottom send failed: {}", .{err});
                            };
                        }
                    } else if (key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and anim_state.mode == .Grid) {
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘↵", now);
                        if (countSpawnedSessions(sessions) == 1) {
                            continue;
                        }
                        const clicked_session = anim_state.focused_session;
                        try sessions[clicked_session].ensureSpawnedWithLoop(&loop);

                        session_interaction_component.acknowledgeAttention(clicked_session);
                        session_interaction_component.setAttention(clicked_session, false, now);

                        const grid_row: c_int = @intCast(clicked_session / grid.cols);
                        const grid_col: c_int = @intCast(clicked_session % grid.cols);
                        const start_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                        const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                        anim_state.focused_session = clicked_session;
                        if (animations_enabled) {
                            anim_state.mode = .Expanding;
                            anim_state.start_time = now;
                            anim_state.start_rect = start_rect;
                            anim_state.target_rect = target_rect;
                        } else {
                            anim_state.mode = .Full;
                            anim_state.start_time = now;
                            anim_state.start_rect = target_rect;
                            anim_state.target_rect = target_rect;
                            anim_state.previous_session = clicked_session;
                        }
                        std.debug.print("Expanding session: {d}\n", .{clicked_session});
                    } else if (focused.spawned and !focused.dead and !input_keys.isModifierKey(key)) {
                        session_interaction_component.resetScrollIfNeeded(anim_state.focused_session);
                        if (anim_state.mode == .Grid) {
                            session_interaction_component.setAttention(anim_state.focused_session, false, now);
                        }
                        try input_keys.handleKeyInput(focused, key, mod);
                    }
                },
                c.SDL_EVENT_KEY_UP => {
                    const key = scaled_event.key.key;
                    if (key == c.SDLK_ESCAPE and input.canHandleEscapePress(anim_state.mode)) {
                        const focused = sessions[anim_state.focused_session];
                        if (focused.spawned and !focused.dead and focused.shell != null) {
                            const esc_byte: [1]u8 = .{27};
                            _ = focused.shell.?.write(&esc_byte) catch |err| {
                                log.warn("session {d}: failed to send escape key: {}", .{ anim_state.focused_session, err });
                            };
                        }
                    }
                },
                else => {},
            }
        }

        if (!running) break;

        loop.run(.no_wait) catch |err| {
            log.err("xev loop run failed: {}", .{err});
            return err;
        };
        if (relaunch_trace_frames > 0) {
            log.info("frame trace after xev run", .{});
        }

        for (sessions) |session| {
            if (relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace before process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
            session.checkAlive();
            session.processOutput() catch |err| {
                reportSessionFailure(session, err, "process_output");
                session.failAndTerminate();
                continue;
            };
            session.flushPendingWrites() catch |err| {
                reportSessionFailure(session, err, "flush_pending_writes");
                session.failAndTerminate();
                continue;
            };
            const prev_cwd_ptr = if (session.cwd_path) |p| p.ptr else null;
            session.updateCwd(now);
            _ = session.expireSynchronizedOutput(now);
            if (session.cwd_path) |new_cwd| {
                // Compare pointers: if they differ, cwd changed (and old memory was freed by updateCwd)
                const changed = prev_cwd_ptr == null or prev_cwd_ptr != new_cwd.ptr;
                if (changed and session.cwd_settled) {
                    persistence.appendRecentFolder(allocator, new_cwd) catch |err| {
                        log.warn("failed to update recent folders: {}", .{err});
                    };
                    recent_folders_comp_ptr.setFolders(persistence.getRecentFolders());
                    persistence_dirty = true;
                }
            }
            if (relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace after process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
        }

        const terminal_entries_changed = syncPersistenceTerminalEntriesFromSessions(&persistence, sessions, allocator) catch |err| blk: {
            log.warn("failed to sync terminal persistence state: {}", .{err});
            break :blk false;
        };
        if (terminal_entries_changed) {
            persistence_dirty = true;
        }
        // Persist focus + zoom so the active/zoomed pane is restored on relaunch (2c).
        const cur_zoomed = anim_state.mode == .Full;
        if (persistence.focused_session != anim_state.focused_session or persistence.zoomed != cur_zoomed) {
            persistence.focused_session = anim_state.focused_session;
            persistence.zoomed = cur_zoomed;
            persistence_dirty = true;
        }
        savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);

        if (quit_teardown.isFinished()) {
            running = false;
        }
        var any_session_dirty = render_cache.anyDirty(sessions);

        var control_requests = control_queue.drainAll();
        defer control_requests.deinit(allocator);
        var had_control_requests = control_requests.items.len > 0;
        for (control_requests.items) |*request| {
            handleExternalSpawnRequest(
                allocator,
                request,
                sessions,
                &grid,
                &anim_state,
                session_interaction_component,
                &loop,
                animations_enabled,
                now,
                render_width,
                render_height,
                ui_scale,
                &font,
                grid_font.cell_width,
                grid_font.cell_height,
                &full_cols,
                &full_rows,
                &cell_width_pixels,
                &cell_height_pixels,
            );
            request.request.deinit(allocator);
        }

        var close_requests = close_queue.drainAll();
        defer close_requests.deinit(allocator);
        if (close_requests.items.len > 0) had_control_requests = true;
        for (close_requests.items) |*request| {
            handleExternalCloseRequest(
                allocator,
                request,
                sessions,
                &grid,
                &anim_state,
                session_interaction_component,
                &render_cache,
                &loop,
                animations_enabled,
                now,
                render_width,
                render_height,
                ui_scale,
                &font,
                grid_font.cell_width,
                grid_font.cell_height,
                &full_cols,
                &full_rows,
                &cell_width_pixels,
                &cell_height_pixels,
            );
        }

        var notifications = notify_queue.drainAll();
        defer notifications.deinit(allocator);
        const had_notifications = notifications.items.len > 0;
        var captured_agent_session_id = false;
        for (notifications.items) |note| {
            switch (note) {
                .status => |s| {
                    const session_idx = findSessionIndexById(sessions, s.session) orelse continue;
                    session_interaction_component.setStatus(session_idx, s.state);
                    const wants_attention = switch (s.state) {
                        .awaiting_approval, .done => true,
                        else => false,
                    };
                    // Chime when an agent needs you or finishes, but only while
                    // Cadre is backgrounded (foreground already shows the border).
                    if (wants_attention and config.notifications.sound and !window_focused) {
                        notify_sound.play(allocator, s.state);
                    }
                    const is_focused_full = anim_state.mode == .Full and anim_state.focused_session == session_idx;
                    session_interaction_component.setAttention(session_idx, if (is_focused_full) false else wants_attention, now);
                    std.debug.print("Session {d} (slot {d}) status -> {s}\n", .{ s.session, session_idx, @tagName(s.state) });
                },
                .story => |s| {
                    if (!story_overlay_component.show(s.path, now)) {
                        ui.showToast("Failed to open story file", now);
                    }
                    allocator.free(s.path);
                },
                .agent_session => |s| {
                    // Live session-id capture from the agent's SessionStart hook.
                    // Free the heap strings on every exit path.
                    defer {
                        allocator.free(s.agent);
                        allocator.free(s.session_id);
                    }
                    const session_idx = findSessionIndexById(sessions, s.session) orelse continue;
                    const agent_kind = session_state.AgentKind.fromComm(s.agent) orelse continue;
                    const session = sessions[session_idx];
                    // Skip if nothing changed, to avoid needless persistence churn.
                    const unchanged = session.agent_metadata_captured and
                        session.agent_kind == agent_kind and
                        session.agent_session_id != null and
                        std.mem.eql(u8, session.agent_session_id.?, s.session_id);
                    if (unchanged) continue;
                    const id_dupe = allocator.dupe(u8, s.session_id) catch |err| {
                        log.warn("failed to store agent session id for slot {d}: {}", .{ session_idx, err });
                        continue;
                    };
                    if (session.agent_session_id) |old| allocator.free(old);
                    session.agent_kind = agent_kind;
                    session.agent_session_id = id_dupe;
                    session.agent_metadata_captured = true;
                    persistence_dirty = true;
                    captured_agent_session_id = true;
                    log.info("captured agent session: slot {d} {s} {s}", .{ session_idx, s.agent, s.session_id });
                },
            }
        }

        // A SessionStart hook just delivered a fresh resume id this frame — but
        // AFTER the earlier entry-sync/save (which read the sessions before the id
        // landed). Re-sync so the entry carries the new id, then flush now instead
        // of a frame later, closing the window where a reboot could lose an id we
        // already hold in memory.
        if (captured_agent_session_id) {
            if (syncPersistenceTerminalEntriesFromSessions(&persistence, sessions, allocator) catch |err| blk: {
                log.warn("failed to re-sync terminal persistence after agent-session capture: {}", .{err});
                break :blk false;
            }) {
                persistence_dirty = true;
            }
            savePersistenceIfDirty(&persistence, allocator, &persistence_dirty);
        }

        if (pending_comment_send) |pcs| {
            const prompt_ready = pcs.session < sessions.len and
                sessions[pcs.session].hasForegroundProcess();
            if (now >= pcs.send_after_ms or prompt_ready) {
                if (pcs.session < sessions.len) {
                    sessions[pcs.session].sendInput(pcs.text) catch |err| {
                        log.warn("failed to send pending diff comments: {}", .{err});
                    };
                }
                allocator.free(pcs.text);
                pending_comment_send = null;
            }
        }

        if (hidden_switcher_comp_ptr.open) {
            if (hosting_last_poll_ms == null or now - hosting_last_poll_ms.? >= hosting_poll_interval_ms) {
                hosting_last_poll_ms = now;
                // ponytail: synchronous subprocess poll (~tens of ms) while a
                // static modal is up; move to a worker thread if it hitches.
                hosting_mod.detectHosting(allocator, sessions, hosting_flags);
                for (hosting_flags, 0..) |flag, i| {
                    session_interaction_component.setHosting(i, flag);
                }
            }
        } else {
            hosting_last_poll_ms = null; // re-poll immediately on next open
        }

        var focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
        const ui_update_host = ui_host.makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid_font.cell_width,
            grid_font.cell_height,
            grid_font_size,
            grid.cols,
            grid.rows,
            full_cols,
            full_rows,
            &anim_state,
            sessions,
            session_ui_info,
            session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &theme,
        );
        ui.update(&ui_update_host);

        ui_action_loop: while (ui.popAction()) |action| switch (action) {
            .RestartSession => |idx| {
                if (idx < sessions.len) {
                    try sessions[idx].restart();
                    session_interaction_component.resetView(idx);
                    std.debug.print("UI requested restart: {d}\n", .{idx});
                }
            },
            .FocusSession => |idx| {
                if (anim_state.mode != .Grid) continue;
                if (idx >= sessions.len) continue;

                session_interaction_component.clearSelection(anim_state.focused_session);
                try sessions[idx].ensureSpawnedWithLoop(&loop);
                session_interaction_component.acknowledgeAttention(idx);
                session_interaction_component.setAttention(idx, false, now);

                const grid_row: c_int = @intCast(idx / grid.cols);
                const grid_col: c_int = @intCast(idx % grid.cols);
                const cell_rect = Rect{
                    .x = grid_col * cell_width_pixels,
                    .y = grid_row * cell_height_pixels,
                    .w = cell_width_pixels,
                    .h = cell_height_pixels,
                };
                const target_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };

                anim_state.focused_session = idx;
                if (animations_enabled) {
                    anim_state.mode = .Expanding;
                    anim_state.start_time = now;
                    anim_state.start_rect = cell_rect;
                    anim_state.target_rect = target_rect;
                } else {
                    anim_state.mode = .Full;
                    anim_state.start_time = now;
                    anim_state.start_rect = target_rect;
                    anim_state.target_rect = target_rect;
                    anim_state.previous_session = idx;
                }
                std.debug.print("Expanding session: {d}\n", .{idx});
            },
            .SelectGridSession => |idx| {
                // Single click in grid view: instantly move the focus/selection
                // highlight to the clicked pane. No shell spawn, no zoom, and
                // deliberately NO nav-wave animation. A mouse click is direct
                // manipulation, so focus must change instantly (the moved accent
                // border is the feedback); the wave stays on keyboard nav, where
                // it answers "where did focus jump to?" (mirrors :focus-visible).
                if (anim_state.mode != .Grid) continue;
                if (idx >= sessions.len) continue;
                if (idx == anim_state.focused_session) continue;

                // Clear the pane we're leaving, but NOT the one we're moving to:
                // the same mouse-down that queued this action already ran
                // `beginSelection` on `idx`, which cleared that pane's screen
                // selection and armed a drag (selection_pending/anchor). Clearing
                // `idx` here would reset those flags before the following motion
                // events could build the selection, so a drag-select on a
                // non-focused grid pane produced nothing to copy.
                session_interaction_component.clearSelection(anim_state.focused_session);
                // Selecting is a focus: acknowledge a sticky "done"/"needs you"
                // back to idle AND drop the attention border, same as every
                // keyboard/zoom focus path (status alone leaves an orange
                // fallback border while `attention` is still set).
                session_interaction_component.acknowledgeAttention(idx);
                session_interaction_component.setAttention(idx, false, now);
                anim_state.focused_session = idx;
            },
            .ReorderGridSessions => |move| {
                const visible = countVisibleSessions(sessions);
                if (move.from >= visible or move.to >= visible or move.from == move.to) continue;
                var order_buf: [grid_layout.max_terminals]usize = undefined;
                const order = springboardOrder(&order_buf, visible, move.from, move.to);
                // Snapshot pre-reorder indices so the slide can animate each
                // tile from where it was; taken before applyReorder permutes.
                var snapshots: ?std.ArrayList(SessionIndexSnapshot) = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                    log.warn("failed to snapshot reorder positions (slide skipped): {}", .{err});
                    break :blk null;
                };
                defer if (snapshots) |*snaps| snaps.deinit(allocator);
                if (applyReorder(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state, order)) {
                    // Tiles changed cells; repaint every visible pane. PTY
                    // sizes are untouched — a pure permutation keeps the
                    // uniform grid winsize, so no resize fires.
                    for (sessions) |session| {
                        if (session.isVisible()) session.markDirty();
                    }
                    persistence_dirty = true;
                    // Slide tiles to their new cells. Unlike add/remove
                    // reflows this also starts while a previous slide is in
                    // flight (mode == .GridResizing): startResizeWithDuration
                    // retargets from the drawn mid-flight rects, which is what
                    // keeps rapid re-slots smooth instead of snapping.
                    if (animations_enabled and (anim_state.mode == .Grid or anim_state.mode == .GridResizing)) {
                        if (snapshots) |snaps| {
                            var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snaps.items, allocator) catch |err| blk: {
                                log.warn("failed to collect reorder moves (slide skipped): {}", .{err});
                                break :blk null;
                            };
                            if (move_result) |*moves| {
                                defer moves.list.deinit(allocator);
                                if (moves.moved) {
                                    grid.startResizeWithDuration(grid.cols, grid.rows, now, render_width, render_height, moves.list.items, GridLayout.reorder_duration_ms) catch |err| {
                                        log.warn("failed to start reorder slide: {}", .{err});
                                    };
                                    if (grid.is_resizing) {
                                        anim_state.mode = .GridResizing;
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .RevealHiddenTerminal => |idx| {
                if (idx >= sessions.len) continue;
                if (!(sessions[idx].spawned and sessions[idx].hidden)) continue;
                const reveal_id = sessions[idx].id;
                sessions[idx].hidden = false;
                // Reveal is a fresh appearance: mint a new order_seq so the
                // terminal lands at the END of the grid instead of re-sorting
                // by its old seq into the middle of a hand-arranged order.
                sessions[idx].order_seq = session_state.mintOrderSeqBlock(1);
                sessions[idx].markDirty();
                compactSessions(sessions, session_interaction_component.viewSlice(), &render_cache, &anim_state);
                const new_dims = GridLayout.calculateDimensions(countVisibleSessions(sessions));
                grid.cols = new_dims.cols;
                grid.rows = new_dims.rows;
                cell_width_pixels = @divFloor(render_width, @as(c_int, @intCast(grid.cols)));
                cell_height_pixels = @divFloor(render_height, @as(c_int, @intCast(grid.rows)));
                anim_state.mode = .Grid;
                if (findSessionIndexById(sessions, reveal_id)) |new_idx| {
                    anim_state.focused_session = new_idx;
                    // Revealing is a focus: acknowledge a sticky "done"/"needs you" back to idle.
                    session_interaction_component.acknowledgeAttention(new_idx);
                }
                applyTerminalLayout(sessions, allocator, &font, render_width, render_height, ui_scale, &anim_state, grid.cols, grid.rows, grid_font.cell_width, grid_font.cell_height, &full_cols, &full_rows);
                ui.showToast("Revealed terminal", now);
            },
            .DespawnSession => |idx| {
                despawnSessionAtIndex(
                    idx,
                    false,
                    allocator,
                    sessions,
                    &grid,
                    &anim_state,
                    session_interaction_component,
                    &render_cache,
                    &loop,
                    animations_enabled,
                    now,
                    render_width,
                    render_height,
                    ui_scale,
                    &font,
                    grid_font.cell_width,
                    grid_font.cell_height,
                    &full_cols,
                    &full_rows,
                    &cell_width_pixels,
                    &cell_height_pixels,
                );
            },
            .RequestCollapseFocused => {
                if (anim_state.mode == .Full) {
                    const spawned_count = countSpawnedSessions(sessions);
                    if (spawned_count == 1) {
                        std.debug.print("UI requested collapse ignored (single terminal)\n", .{});
                    } else if (animations_enabled) {
                        grid_nav.startCollapseToGrid(&anim_state, now, cell_width_pixels, cell_height_pixels, render_width, render_height, grid.cols);
                    } else {
                        const grid_row: c_int = @intCast(anim_state.focused_session / grid.cols);
                        const grid_col: c_int = @intCast(anim_state.focused_session % grid.cols);
                        anim_state.mode = .Grid;
                        anim_state.start_time = now;
                        anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = render_width, .h = render_height };
                        anim_state.target_rect = Rect{
                            .x = grid_col * cell_width_pixels,
                            .y = grid_row * cell_height_pixels,
                            .w = cell_width_pixels,
                            .h = cell_height_pixels,
                        };
                    }
                    std.debug.print("UI requested collapse of focused session: {d}\n", .{anim_state.focused_session});
                }
            },
            .PasteIntoFocused => {
                // Same paste path as Cmd+V: try image passthrough first (opt-in),
                // then fall back to text.
                if (anim_state.focused_session < sessions.len) {
                    const focused = sessions[anim_state.focused_session];
                    var handled_paste = false;
                    if (config.paste.image_passthrough) {
                        handled_paste = terminal_actions.tryPasteImagePassthrough(focused, allocator, &ui, now, session_interaction_component) catch |err| blk: {
                            std.debug.print("Image paste passthrough failed: {}\n", .{err});
                            break :blk false;
                        };
                    }
                    if (!handled_paste) {
                        terminal_actions.pasteClipboardIntoSession(focused, allocator, &ui, now, session_interaction_component) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    }
                }
            },
            .ConfirmQuit => {
                if (!quit_teardown.active) {
                    if (startQuitFlow(&quit_teardown, sessions[0..], quit_blocking_overlay_component)) {
                        running = false;
                    }
                }
            },
            .OpenConfig => {
                if (config_mod.Config.getConfigPath(allocator)) |config_path| {
                    defer allocator.free(config_path);
                    if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘,", now);

                    const result = switch (builtin.os.tag) {
                        .macos => blk: {
                            var child = std.process.Child.init(&.{ "open", "-t", config_path }, allocator);
                            break :blk child.spawn();
                        },
                        else => open_url.openUrl(allocator, config_path),
                    };
                    result catch |err| {
                        std.debug.print("Failed to open config file: {}\n", .{err});
                    };
                    ui.showToast("Opening config file", now);
                } else |err| {
                    std.debug.print("Failed to get config path: {}\n", .{err});
                }
            },
            .SwitchWorktree => |switch_action| {
                defer allocator.free(switch_action.path);
                if (switch_action.session >= sessions.len) continue;

                var session = sessions[switch_action.session];
                if (session.hasForegroundProcessThorough()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, switch_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ switch_action.session, err });
                    ui.showToast("Could not switch worktree", now);
                    continue;
                };

                session_interaction_component.setAttention(switch_action.session, false, now);
                ui.showToast("Switched worktree", now);
            },
            .CreateWorktree => |create_action| {
                defer allocator.free(create_action.base_path);
                defer allocator.free(create_action.name);
                if (create_action.session >= sessions.len) continue;
                var session = sessions[create_action.session];

                if (session.hasForegroundProcessThorough()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                const target_path = worktree.resolveWorktreeDir(
                    allocator,
                    create_action.base_path,
                    create_action.name,
                    config.worktree.directory,
                ) catch |err| {
                    std.debug.print("Failed to resolve worktree directory: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(target_path);

                const command = worktree.buildCreateWorktreeCommand(
                    allocator,
                    create_action.base_path,
                    target_path,
                    create_action.name,
                    config.worktree.init_command,
                ) catch |err| {
                    std.debug.print("Failed to build worktree command: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send worktree command: {}\n", .{err});
                    ui.showToast("Could not create worktree", now);
                    continue;
                };

                session.recordCwd(target_path) catch |err| {
                    log.warn("session {d}: failed to record cwd: {}", .{ create_action.session, err });
                };

                session_interaction_component.setAttention(create_action.session, false, now);
                ui.showToast("Creating worktree…", now);
            },
            .RemoveWorktree => |remove_action| {
                defer allocator.free(remove_action.path);
                if (remove_action.session >= sessions.len) continue;
                var session = sessions[remove_action.session];

                if (session.hasForegroundProcessThorough()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                for (sessions, 0..) |other_session, idx| {
                    if (idx == remove_action.session) continue;
                    if (!other_session.spawned or other_session.dead) continue;

                    const other_cwd = other_session.cwd_path orelse continue;
                    if (std.mem.eql(u8, other_cwd, remove_action.path)) {
                        ui.showToast("Worktree in use by another session", now);
                        continue :ui_action_loop;
                    }
                    if (std.mem.startsWith(u8, other_cwd, remove_action.path)) {
                        const suffix = other_cwd[remove_action.path.len..];
                        if (suffix.len > 0 and suffix[0] == '/') {
                            ui.showToast("Worktree in use by another session", now);
                            continue :ui_action_loop;
                        }
                    }
                }

                const command = worktree.buildRemoveWorktreeCommand(allocator, remove_action.path) catch |err| {
                    std.debug.print("Failed to build remove worktree command: {}\n", .{err});
                    ui.showToast("Could not remove worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send remove worktree command: {}\n", .{err});
                    ui.showToast("Could not remove worktree", now);
                    continue;
                };

                session_interaction_component.setAttention(remove_action.session, false, now);
                ui.showToast("Removing worktree…", now);
            },
            .ChangeDirectory => |cd_action| {
                defer allocator.free(cd_action.path);
                if (cd_action.session >= sessions.len) continue;

                var session = sessions[cd_action.session];
                if (session.hasForegroundProcessThorough()) {
                    ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, cd_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ cd_action.session, err });
                    ui.showToast("Could not change directory", now);
                    continue;
                };

                // Note: appendRecentFolder is handled by the per-frame updateCwd loop
                // to avoid double-counting when cwd changes are detected

                session_interaction_component.setAttention(cd_action.session, false, now);

                const basename = std.fs.path.basename(cd_action.path);
                const toast_msg_buf: ?[]u8 = std.fmt.allocPrint(allocator, "Changed to {s}", .{basename}) catch |err| blk: {
                    log.warn("failed to allocate cd toast: {}", .{err});
                    break :blk null;
                };
                const toast_msg = toast_msg_buf orelse "Changed directory";
                defer if (toast_msg_buf) |buf| allocator.free(buf);
                ui.showToast(toast_msg, now);
            },
            .ToggleMetrics => {
                if (config.metrics.enabled) {
                    metrics_overlay_component.toggle();
                    if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘⇧M", now);
                } else {
                    ui.showToast("Metrics disabled in config", now);
                }
            },
            .ToggleDiffOverlay => {
                const focused_cwd = if (anim_state.focused_session < sessions.len)
                    sessions[anim_state.focused_session].cwd_path
                else
                    null;
                switch (diff_overlay_component.toggle(focused_cwd, now)) {
                    .not_a_repo => ui.showToast("Not a git repository", now),
                    .clean => ui.showToast("Working tree clean", now),
                    .opened => if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘D", now),
                }
            },
            .ToggleReaderOverlay => {
                const focused_has_foreground = foreground_cache.get(now, anim_state.focused_session, sessions);
                const host_snapshot = ui_host.makeUiHost(
                    now,
                    render_width,
                    render_height,
                    ui_scale,
                    cell_width_pixels,
                    cell_height_pixels,
                    grid_font.cell_width,
                    grid_font.cell_height,
                    grid_font_size,
                    grid.cols,
                    grid.rows,
                    full_cols,
                    full_rows,
                    &anim_state,
                    sessions,
                    session_ui_info,
                    session_interaction_component.viewSlice(),
                    focused_has_foreground,
                    &theme,
                );
                switch (reader_overlay_component.toggle(&host_snapshot, now)) {
                    .opened => {
                        ui.showToast("Reader Mode", now);
                        if (config.ui.show_hotkey_feedback) ui.showHotkey("⌘R", now);
                    },
                    .closed => {},
                    .unavailable => ui.showToast("Reader mode requires a selected running terminal", now),
                }
            },
            .SendDiffComments => |dc_action| {
                if (dc_action.session >= sessions.len) {
                    allocator.free(dc_action.comments_text);
                    if (dc_action.agent_command) |cmd| allocator.free(cmd);
                    continue;
                }
                var dc_session = sessions[dc_action.session];
                if (dc_action.agent_command) |cmd| {
                    dc_session.sendInput(cmd) catch |err| {
                        log.warn("failed to send agent command: {}", .{err});
                        allocator.free(dc_action.comments_text);
                        allocator.free(cmd);
                        continue;
                    };
                    allocator.free(cmd);
                    if (pending_comment_send) |prev| allocator.free(prev.text);
                    pending_comment_send = .{
                        .session = dc_action.session,
                        .text = dc_action.comments_text,
                        .send_after_ms = now + 2000,
                    };
                } else {
                    dc_session.sendInput(dc_action.comments_text) catch |err| {
                        log.warn("failed to send diff comments: {}", .{err});
                    };
                    allocator.free(dc_action.comments_text);
                }
            },
            .OpenStory => |story_action| {
                if (!story_overlay_component.show(story_action.path, now)) {
                    ui.showToast("Failed to open story file", now);
                }
                allocator.free(story_action.path);
            },
        };

        if (anim_state.mode == .Expanding or anim_state.mode == .Collapsing or
            anim_state.mode == .PanningLeft or anim_state.mode == .PanningRight or
            anim_state.mode == .PanningUp or anim_state.mode == .PanningDown)
        {
            if (anim_state.isComplete(now)) {
                const previous_mode = anim_state.mode;
                const next_mode = switch (anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .Full,
                    .Collapsing => .Grid,
                    else => anim_state.mode,
                };
                anim_state.mode = next_mode;
                if (previous_mode == .Collapsing and next_mode == .Grid and anim_state.focused_session < sessions.len) {
                    sessions[anim_state.focused_session].markDirty();
                }
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(anim_state.mode)});
            }
        }

        // Handle grid resize animation completion
        if (anim_state.mode == .GridResizing) {
            if (grid.updateResize(now)) {
                anim_state.mode = .Grid;
                // Mark all sessions dirty to refresh render cache
                for (sessions) |session| {
                    session.markDirty();
                }
                std.debug.print("Grid resize complete: {d}x{d}\n", .{ grid.cols, grid.rows });
            }
        }

        // When the grid shape changes, resolve its saved per-shape font scale
        // (falling back to the global) before the per-frame layout so the PTY
        // dims and the grid font agree.
        if (grid.cols != resolved_grid_cols or grid.rows != resolved_grid_rows) {
            resolved_grid_cols = grid.cols;
            resolved_grid_rows = grid.rows;
            const preset = persistence.getGridFontPreset(grid.cols, grid.rows) orelse persistence.grid_font_scale;
            config.grid.font_scale = std.math.clamp(preset, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
        }

        const terminal_layout_changed = applyTerminalLayoutIfSizeChanged(
            sessions,
            allocator,
            &font,
            render_width,
            render_height,
            ui_scale,
            &anim_state,
            grid.cols,
            grid.rows,
            grid_font.cell_width,
            grid_font.cell_height,
            &full_cols,
            &full_rows,
        );
        if (terminal_layout_changed) {
            any_session_dirty = true;
            std.debug.print("Terminal layout adjusted for {s}: {d}x{d}\n", .{
                @tagName(anim_state.mode),
                full_cols,
                full_rows,
            });
        }

        if (anim_state.mode != last_logged_mode) {
            emitViewModeTransitionEvents(last_logged_mode, anim_state.mode, anim_state.focused_session, countSpawnedSessions(sessions));
            last_logged_mode = anim_state.mode;
        }

        focused_has_foreground_process = foreground_cache.get(now, anim_state.focused_session, sessions);
        const ui_render_host = ui_host.makeUiHost(
            now,
            render_width,
            render_height,
            ui_scale,
            cell_width_pixels,
            cell_height_pixels,
            grid_font.cell_width,
            grid_font.cell_height,
            grid_font_size,
            grid.cols,
            grid.rows,
            full_cols,
            full_rows,
            &anim_state,
            sessions,
            session_ui_info,
            session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &theme,
        );

        // E2E harness observability (no-op unless CADRE_TEST_MODE is set).
        test_probe.writeState(allocator, &ui_render_host);

        const animating = anim_state.mode != .Grid and anim_state.mode != .Full;
        const ui_needs_frame = ui.needsFrame(&ui_render_host);
        const last_render_stale = last_render_ns == 0 or (frame_start_ns - last_render_ns) >= max_idle_render_gap_ns;
        const should_render = animating or any_session_dirty or ui_needs_frame or processed_event or had_notifications or had_control_requests or last_render_stale;

        if (should_render) {
            // Open grid_font at the grid's target size and render it at its native
            // cell (grid_render_scale = 1.0). The rasterizer hints the glyph at the
            // small point size; that's already the crisp result. The old residual
            // scale (target/native) bilinear-blurred every glyph — invisible at large
            // [grid] font_scale (~1.0), but ugly at small values where ±0.5pt rounding
            // is a big fraction of a tiny font. Native render is sharp at every
            // percentage; the tile just fits a cell more/fewer, which visible_cols/rows
            // already clamp.
            // ponytail: native render, no glyph scaling; trades exact tile-fit for sharpness.
            {
                const grid_dim = @max(grid.cols, grid.rows);
                const eff_scale = (1.0 / @as(f32, @floatFromInt(grid_dim))) * config.grid.font_scale;
                // Estimate the grid font size directly: cell size scales ~linearly
                // with point size, so size ~= base_size * eff_scale. Opens one font
                // instead of probing every size (which caused a one-time hitch on
                // the first resize).
                const base_pt: f32 = @floatFromInt(layout.scaledFontSize(font_size, ui_scale));
                const desired = std.math.clamp(@as(c_int, @intFromFloat(@round(base_pt * eff_scale))), min_grid_font_size, max_font_size);
                if (desired != grid_font_size or shared_font_cache.generation != grid_font_generation) {
                    if (initSharedFont(allocator, renderer, &shared_font_cache, desired)) |new_grid_font| {
                        grid_font.deinit();
                        grid_font = new_grid_font;
                        grid_font.metrics = metrics_ptr;
                        grid_font_size = desired;
                        grid_font_generation = shared_font_cache.generation;
                    } else |err| {
                        log.warn("failed to rebuild grid font at size {d}: {}", .{ desired, err });
                    }
                }
                grid_render_scale = 1.0;
            }
            if (relaunch_trace_frames > 0) {
                log.info("frame trace before render", .{});
            }
            renderer_mod.render(
                renderer,
                &render_cache,
                sessions,
                session_interaction_component.viewSlice(),
                cell_width_pixels,
                cell_height_pixels,
                grid.cols,
                grid.rows,
                &anim_state,
                now,
                &font,
                &grid_font,
                grid_render_scale,
                full_cols,
                full_rows,
                render_width,
                render_height,
                &theme,
                ui_scale,
                config.grid.font_scale,
                &grid,
                window_focused,
                @intCast(config.ui.inactive_overlay_alpha),
            ) catch |err| {
                log.err("render failed: {}", .{err});
                return err;
            };
            ui.render(&ui_render_host, renderer);
            _ = c.SDL_RenderPresent(renderer);
            if (relaunch_trace_frames > 0) {
                log.info("frame trace after render", .{});
            }
            metrics_mod.increment(.frame_count);
            last_render_ns = std.time.nanoTimestamp();
        }

        if (relaunch_trace_frames > 0) {
            relaunch_trace_frames -= 1;
        }

        const is_idle = !animating and !any_session_dirty and !ui_needs_frame and !processed_event and !had_notifications and !had_control_requests;

        if (window_close_suppress_countdown > 0) {
            window_close_suppress_countdown -= 1;
        }

        const frame_end_ns: i128 = std.time.nanoTimestamp();
        const frame_ns = frame_end_ns - frame_start_ns;
        next_frame_wait = computeFrameWaitDecision(is_idle, sdl.vsync_enabled, frame_ns);
    }

    if (builtin.os.tag == .macos) {
        const now = std.time.milliTimestamp();
        for (sessions) |session| {
            session.updateCwd(now);
        }

        if (quit_teardown.active) {
            quit_blocking_overlay_component.setActive(false);
            quit_teardown.join();
            drainQuitCaptureOutput(quit_teardown.tasks[0..quit_teardown.task_count], sessions[0..]);
            for (quit_teardown.tasks[0..quit_teardown.task_count]) |task| {
                const session = sessions[task.session_idx];
                session.stopQuitCapture();
                const text = session.quitCaptureBytes();
                log.debug("quit teardown: session {d} extracted {d} bytes of terminal text", .{ task.session_idx, text.len });
                if (terminal_history.extractLastUuid(text)) |uuid| {
                    // Scrape succeeded: overwrite with the freshest id from the farewell banner.
                    // Dup first so a failed alloc keeps the existing (hook-captured) id intact.
                    if (allocator.dupe(u8, uuid)) |new_id| {
                        if (session.agent_session_id) |sid| allocator.free(sid);
                        session.agent_session_id = new_id;
                        session.agent_kind = task.agent_kind;
                        session.agent_metadata_captured = true;
                        log.info("quit teardown: session {d} captured session id: {s}", .{ task.session_idx, uuid });
                    } else |err| {
                        log.warn("quit teardown: session {d} failed to allocate session id: {}", .{ task.session_idx, err });
                    }
                } else {
                    // Scrape failed: KEEP whatever the SessionStart hook captured this run instead
                    // of wiping it. The live hook is the reliable source of the resume id; the quit
                    // scrape is only a best-effort fallback for agents without the hook.
                    log.warn("quit teardown: session {d} agent {s} exited; no id in farewell output, keeping live-captured id (captured={})", .{ task.session_idx, task.agent_kind.name(), session.agent_metadata_captured });
                }
            }
        }

        _ = syncPersistenceTerminalEntriesFromSessions(&persistence, sessions, allocator) catch |err| {
            std.debug.print("Failed to refresh terminal persistence: {}\n", .{err});
        };
    }

    persistence.save(allocator) catch |err| {
        std.debug.print("Failed to save persistence: {}\n", .{err});
    };
    persistence.deinit(allocator);
}

// ponytail: manual len+1 [] buffer, not allocator.dupeZ — dupeZ's [:0] return
// trips the zwanzig sentinel-alloc lint here; this keeps free sizes unambiguous.
fn allocZ(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, data.len + 1);
    @memcpy(buf[0..data.len], data);
    buf[data.len] = 0;
    return buf;
}

test "planExternalSpawnSlot expands a full current grid" {
    var first: SessionState = undefined;
    first.spawned = true;
    first.hidden = false;
    var second: SessionState = undefined;
    second.spawned = false;
    second.hidden = false;
    var sessions = [_]*SessionState{ &first, &second };

    const plan = planExternalSpawnSlot(&sessions, 1, 1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(plan.expands_grid);
    try std.testing.expectEqual(@as(usize, 2), plan.cols);
    try std.testing.expectEqual(@as(usize, 1), plan.rows);
    try std.testing.expectEqual(@as(usize, 1), plan.slot_index);
}

test "planExternalSpawnSlot reuses free capacity" {
    var first: SessionState = undefined;
    first.spawned = true;
    first.hidden = false;
    var second: SessionState = undefined;
    second.spawned = false;
    second.hidden = false;
    var sessions = [_]*SessionState{ &first, &second };

    const plan = planExternalSpawnSlot(&sessions, 2, 1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!plan.expands_grid);
    try std.testing.expectEqual(@as(usize, 2), plan.cols);
    try std.testing.expectEqual(@as(usize, 1), plan.rows);
    try std.testing.expectEqual(@as(usize, 1), plan.slot_index);
}

test "planExternalSpawnSlot reports full grid" {
    var storage: [grid_layout.max_terminals]SessionState = undefined;
    var sessions: [grid_layout.max_terminals]*SessionState = undefined;
    for (&storage, 0..) |*session, idx| {
        session.* = undefined;
        session.spawned = true;
        session.hidden = false;
        sessions[idx] = session;
    }

    try std.testing.expect(planExternalSpawnSlot(&sessions, grid_layout.max_grid_size, grid_layout.max_grid_size, 0) == null);
}

test "planExternalSpawnSlot ignores hidden sessions when sizing the grid" {
    // Post-compaction layout: 3 visible at the front, one free cell at slot 3, and
    // a hidden session parked at the tail. A new terminal must fill the free cell
    // WITHOUT expanding the grid — a hidden session must not reserve a tile.
    var s0: SessionState = undefined;
    s0.spawned = true;
    s0.hidden = false;
    var s1: SessionState = undefined;
    s1.spawned = true;
    s1.hidden = false;
    var s2: SessionState = undefined;
    s2.spawned = true;
    s2.hidden = false;
    var free: SessionState = undefined;
    free.spawned = false;
    free.hidden = false;
    var hid: SessionState = undefined;
    hid.spawned = true;
    hid.hidden = true;
    var sessions = [_]*SessionState{ &s0, &s1, &s2, &free, &hid };

    const plan = planExternalSpawnSlot(&sessions, 2, 2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!plan.expands_grid);
    try std.testing.expectEqual(@as(usize, 2), plan.cols);
    try std.testing.expectEqual(@as(usize, 2), plan.rows);
    try std.testing.expectEqual(@as(usize, 3), plan.slot_index);
}

test "planExternalSpawnSlot expands on the visible count, not the spawned count" {
    // 4 visible fill a 2x2 grid; 1 hidden parked at the tail with a free cell at
    // slot 4. ⌘N must expand to fit the 5th VISIBLE terminal (3x2) and place it in
    // the first free cell, not skip past the hidden session.
    var v0: SessionState = undefined;
    v0.spawned = true;
    v0.hidden = false;
    var v1: SessionState = undefined;
    v1.spawned = true;
    v1.hidden = false;
    var v2: SessionState = undefined;
    v2.spawned = true;
    v2.hidden = false;
    var v3: SessionState = undefined;
    v3.spawned = true;
    v3.hidden = false;
    var free: SessionState = undefined;
    free.spawned = false;
    free.hidden = false;
    var hid: SessionState = undefined;
    hid.spawned = true;
    hid.hidden = true;
    var sessions = [_]*SessionState{ &v0, &v1, &v2, &v3, &free, &hid };

    const plan = planExternalSpawnSlot(&sessions, 2, 2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(plan.expands_grid);
    try std.testing.expectEqual(@as(usize, 3), plan.cols);
    try std.testing.expectEqual(@as(usize, 2), plan.rows);
    try std.testing.expectEqual(@as(usize, 4), plan.slot_index);
}

test "claimPersistIndex swaps identities and never duplicates them" {
    var s0: SessionState = undefined;
    s0.spawned = false;
    s0.persist_index = 0;
    var s1: SessionState = undefined;
    s1.spawned = false;
    s1.persist_index = 1;
    var s2: SessionState = undefined;
    s2.spawned = false;
    s2.persist_index = 2;
    const sessions = [_]*SessionState{ &s0, &s1, &s2 };

    // Slot 0 reclaims identity 2 (its terminal was cadre-<epoch>-2 last run):
    // the previous holder inherits slot 0's default so indices stay unique.
    claimPersistIndex(&sessions, 0, 2);
    try std.testing.expectEqual(@as(usize, 2), s0.persist_index);
    try std.testing.expectEqual(@as(usize, 0), s2.persist_index);

    // Claiming an index nobody holds (drifted beyond the slot range) just takes it.
    claimPersistIndex(&sessions, 1, 141);
    try std.testing.expectEqual(@as(usize, 141), s1.persist_index);

    // A live session's identity is never stolen (corrupt/duplicate entry).
    s0.spawned = true;
    claimPersistIndex(&sessions, 2, 2);
    try std.testing.expectEqual(@as(usize, 2), s0.persist_index); // live holder keeps it
    try std.testing.expectEqual(@as(usize, 0), s2.persist_index); // claimant keeps its own

    // No-op when the slot already holds what it wants.
    claimPersistIndex(&sessions, 1, 141);
    try std.testing.expectEqual(@as(usize, 141), s1.persist_index);
}

test "compactSessions parks hidden sessions at the tail" {
    // 5 slots: visible(seq2), hidden(seq0), visible(seq1), free, free. After
    // compaction the visible sessions must pack to the front in order_seq
    // (creation) order and the hidden session must move to the tail, leaving the
    // cells between them free for new terminals.
    // persist_index seeds the physical creation order (0..4); it must survive
    // compaction unchanged even though slot_index gets rewritten to the new
    // position. That stability is what keeps each live pane's tmux name pinned.
    var s_v2: SessionState = undefined;
    s_v2.spawned = true;
    s_v2.hidden = false;
    s_v2.id = 2;
    s_v2.order_seq = 3;
    s_v2.persist_index = 0;
    var s_h0: SessionState = undefined;
    s_h0.spawned = true;
    s_h0.hidden = true;
    s_h0.id = 0;
    s_h0.order_seq = 1;
    s_h0.persist_index = 1;
    var s_v1: SessionState = undefined;
    s_v1.spawned = true;
    s_v1.hidden = false;
    s_v1.id = 1;
    s_v1.order_seq = 2;
    s_v1.persist_index = 2;
    var s_e3: SessionState = undefined;
    s_e3.spawned = false;
    s_e3.hidden = false;
    s_e3.id = 3;
    s_e3.order_seq = 0;
    s_e3.persist_index = 3;
    var s_e4: SessionState = undefined;
    s_e4.spawned = false;
    s_e4.hidden = false;
    s_e4.id = 4;
    s_e4.order_seq = 0;
    s_e4.persist_index = 4;
    var sessions = [_]*SessionState{ &s_v2, &s_h0, &s_v1, &s_e3, &s_e4 };

    var views: [5]SessionViewState = undefined;
    var render_cache = try renderer_mod.RenderCache.init(std.testing.allocator, 5);
    defer render_cache.deinit();
    var anim: AnimationState = undefined;
    anim.focused_session = 0;
    anim.previous_session = 0;

    compactSessions(&sessions, &views, &render_cache, &anim);

    // Visible sessions packed to the front in order_seq order.
    try std.testing.expect(sessions[0].isVisible());
    try std.testing.expectEqual(@as(usize, 1), sessions[0].id);
    try std.testing.expect(sessions[1].isVisible());
    try std.testing.expectEqual(@as(usize, 2), sessions[1].id);
    // The cell right after the visible block is genuinely free (not the hidden one).
    try std.testing.expect(!sessions[2].spawned);
    // The hidden session is parked at the tail, out of the grid's cell range.
    try std.testing.expect(sessions[4].hidden and sessions[4].spawned);
    try std.testing.expectEqual(@as(usize, 0), sessions[4].id);

    // persist_index is NEVER rewritten by compaction — it stays bound to the
    // object (its creation-order id), even as slot_index moves to the new
    // position. This is the invariant that stops a fresh tmux spawn from reusing
    // a live session's `cadre-<n>` name and cloning it.
    try std.testing.expectEqual(@as(usize, 2), sessions[0].persist_index); // s_v1
    try std.testing.expectEqual(@as(usize, 0), sessions[0].slot_index);
    try std.testing.expectEqual(@as(usize, 0), sessions[1].persist_index); // s_v2
    try std.testing.expectEqual(@as(usize, 1), sessions[1].slot_index);
    try std.testing.expectEqual(@as(usize, 1), sessions[4].persist_index); // s_h0
    try std.testing.expectEqual(@as(usize, 4), sessions[4].slot_index);
}

test "compactSessions keeps display order when a recycled id is out of creation order" {
    // Regression: close terminal #2 → its struct (persist_index 1) parks at the
    // tail → ⌘N reuses it, inheriting id=1 but a NEW (highest) order_seq. The
    // grid shows it last; the next close must keep it last. Sorting by id put
    // it in the middle, scrambling the surviving terminals.
    var s_a: SessionState = undefined;
    s_a.spawned = true;
    s_a.hidden = false;
    s_a.id = 0;
    s_a.order_seq = 1;
    s_a.persist_index = 0;
    var s_c: SessionState = undefined;
    s_c.spawned = true;
    s_c.hidden = false;
    s_c.id = 2;
    s_c.order_seq = 3;
    s_c.persist_index = 2;
    var s_new: SessionState = undefined; // reused struct: low id, newest spawn
    s_new.spawned = true;
    s_new.hidden = false;
    s_new.id = 1;
    s_new.order_seq = 4;
    s_new.persist_index = 1;
    var sessions = [_]*SessionState{ &s_a, &s_c, &s_new };

    var views: [3]SessionViewState = undefined;
    var render_cache = try renderer_mod.RenderCache.init(std.testing.allocator, 3);
    defer render_cache.deinit();
    var anim: AnimationState = undefined;
    anim.focused_session = 0;
    anim.previous_session = 0;

    compactSessions(&sessions, &views, &render_cache, &anim);

    try std.testing.expectEqual(@as(u64, 1), sessions[0].order_seq); // s_a stays first
    try std.testing.expectEqual(@as(u64, 3), sessions[1].order_seq); // s_c stays second
    try std.testing.expectEqual(@as(u64, 4), sessions[2].order_seq); // newest stays last
    try std.testing.expectEqual(@as(usize, 1), sessions[2].id); // despite its recycled low id
}

/// Test helper: a minimal visible/hidden/free session for reorder tests.
fn testSession(s: *SessionState, id: usize, order_seq: u64, spawned: bool, hidden: bool) void {
    s.* = undefined;
    s.spawned = spawned;
    s.hidden = hidden;
    s.dead = false;
    s.id = id;
    s.order_seq = order_seq;
    s.persist_index = id;
}

test "springboardOrder shifts only the tiles between from and to" {
    var buf: [8]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 0, 3 }, springboardOrder(&buf, 4, 0, 2));
    try std.testing.expectEqualSlices(usize, &.{ 2, 0, 1, 3 }, springboardOrder(&buf, 4, 2, 0));
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3, 1 }, springboardOrder(&buf, 4, 1, 3));
    // Adjacent swap: exactly two tiles trade places.
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2, 3 }, springboardOrder(&buf, 4, 0, 1));
}

test "applyReorder commits a springboard move and focus follows its session" {
    // 4 visible tiles [id0,id1,id2,id3]; drag slot 0 to slot 2 → springboard
    // permutation [1,2,0,3]: only the tiles between old and new slot shift.
    var s0: SessionState = undefined;
    var s1: SessionState = undefined;
    var s2: SessionState = undefined;
    var s3: SessionState = undefined;
    testSession(&s0, 0, 1, true, false);
    testSession(&s1, 1, 2, true, false);
    testSession(&s2, 2, 3, true, false);
    testSession(&s3, 3, 4, true, false);
    var sessions = [_]*SessionState{ &s0, &s1, &s2, &s3 };

    var views: [4]SessionViewState = undefined;
    var render_cache = try renderer_mod.RenderCache.init(std.testing.allocator, 4);
    defer render_cache.deinit();
    var anim: AnimationState = undefined;
    anim.focused_session = 0; // id 0, the dragged tile
    anim.previous_session = 3; // id 3, untouched by the move

    const order = [_]usize{ 1, 2, 0, 3 };
    try std.testing.expect(applyReorder(&sessions, &views, &render_cache, &anim, &order));

    try std.testing.expectEqual(@as(usize, 1), sessions[0].id);
    try std.testing.expectEqual(@as(usize, 2), sessions[1].id);
    try std.testing.expectEqual(@as(usize, 0), sessions[2].id);
    try std.testing.expectEqual(@as(usize, 3), sessions[3].id);
    // slot_index rewritten to the new grid positions.
    for (sessions, 0..) |s, i| try std.testing.expectEqual(i, s.slot_index);
    // Focus tracks the session identity, not the array index.
    try std.testing.expectEqual(@as(usize, 2), anim.focused_session); // id 0 now at slot 2
    try std.testing.expectEqual(@as(usize, 3), anim.previous_session); // id 3 still at slot 3
    // Renumbered order_seq is strictly increasing across the block.
    try std.testing.expect(sessions[0].order_seq < sessions[1].order_seq);
    try std.testing.expect(sessions[1].order_seq < sessions[2].order_seq);
    try std.testing.expect(sessions[2].order_seq < sessions[3].order_seq);
}

test "reordered arrangement survives an unrelated close and a new spawn lands last" {
    var s0: SessionState = undefined;
    var s1: SessionState = undefined;
    var s2: SessionState = undefined;
    var s_hidden: SessionState = undefined;
    testSession(&s0, 0, 1, true, false);
    testSession(&s1, 1, 2, true, false);
    testSession(&s2, 2, 3, true, false);
    testSession(&s_hidden, 9, 100, true, true); // parked hidden, high old seq
    var sessions = [_]*SessionState{ &s0, &s1, &s2, &s_hidden };

    var views: [4]SessionViewState = undefined;
    var render_cache = try renderer_mod.RenderCache.init(std.testing.allocator, 4);
    defer render_cache.deinit();
    var anim: AnimationState = undefined;
    anim.focused_session = 0;
    anim.previous_session = 0;

    // Move slot 2 to slot 0 → [2,0,1]. Hidden session is not part of the order.
    const order = [_]usize{ 2, 0, 1 };
    try std.testing.expect(applyReorder(&sessions, &views, &render_cache, &anim, &order));
    try std.testing.expectEqual(@as(usize, 2), sessions[0].id);
    try std.testing.expectEqual(@as(usize, 0), sessions[1].id);
    try std.testing.expectEqual(@as(usize, 1), sessions[2].id);
    try std.testing.expect(sessions[3].hidden); // still parked at the tail

    // Close the middle terminal (id 0) the way teardown does; compaction must
    // keep the user's order for the survivors instead of snapping back.
    sessions[1].spawned = false;
    sessions[1].order_seq = 0;
    compactSessions(&sessions, &views, &render_cache, &anim);
    try std.testing.expectEqual(@as(usize, 2), sessions[0].id);
    try std.testing.expectEqual(@as(usize, 1), sessions[1].id);

    // ⌘N reuses the closed struct. Its fresh spawn mints from the counter the
    // reorder already advanced past, so it lands after every reordered tile.
    sessions[2].spawned = true;
    sessions[2].order_seq = session_state.mintOrderSeqBlock(1);
    compactSessions(&sessions, &views, &render_cache, &anim);
    try std.testing.expectEqual(@as(usize, 2), sessions[0].id);
    try std.testing.expectEqual(@as(usize, 1), sessions[1].id);
    try std.testing.expectEqual(@as(usize, 0), sessions[2].id); // the respawn, last
}

test "applyReorder rejects stale or invalid permutations" {
    var s0: SessionState = undefined;
    var s1: SessionState = undefined;
    testSession(&s0, 0, 1, true, false);
    testSession(&s1, 1, 2, true, false);
    var sessions = [_]*SessionState{ &s0, &s1 };

    var views: [2]SessionViewState = undefined;
    var render_cache = try renderer_mod.RenderCache.init(std.testing.allocator, 2);
    defer render_cache.deinit();
    var anim: AnimationState = undefined;
    anim.focused_session = 0;
    anim.previous_session = 0;

    // Wrong length (a terminal died mid-drag).
    const short = [_]usize{0};
    try std.testing.expect(!applyReorder(&sessions, &views, &render_cache, &anim, &short));
    // Duplicate index.
    const dup = [_]usize{ 0, 0 };
    try std.testing.expect(!applyReorder(&sessions, &views, &render_cache, &anim, &dup));
    // Out-of-range index.
    const oob = [_]usize{ 0, 5 };
    try std.testing.expect(!applyReorder(&sessions, &views, &render_cache, &anim, &oob));
    // Nothing changed.
    try std.testing.expectEqual(@as(usize, 0), sessions[0].id);
    try std.testing.expectEqual(@as(u64, 1), sessions[0].order_seq);
    try std.testing.expectEqual(@as(usize, 1), sessions[1].id);
    try std.testing.expectEqual(@as(u64, 2), sessions[1].order_seq);
}

test "agentLabel reports the detected agent name or 'none'" {
    var session: SessionState = undefined;
    session.agent_icon = null;
    try std.testing.expectEqualStrings("none", agentLabel(&session));

    session.agent_icon = .codex;
    try std.testing.expectEqualStrings("codex", agentLabel(&session));

    session.agent_icon = .claude;
    try std.testing.expectEqualStrings("claude", agentLabel(&session));
}

test "validateExternalSpawnCwd accepts directories and rejects relative paths" {
    try std.testing.expect(validateExternalSpawnCwd("/tmp") == null);

    const failure = validateExternalSpawnCwd("relative/path") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(control.SpawnErrorCode.invalid_cwd, failure.code);
}

test "buildQueuedCommand appends a newline only when needed" {
    const allocator = std.testing.allocator;

    const first = try buildQueuedCommand(allocator, "echo ok");
    defer allocator.free(first);
    try std.testing.expectEqualStrings("echo ok\n", first);

    const second = try buildQueuedCommand(allocator, "echo ok\n");
    defer allocator.free(second);
    try std.testing.expectEqualStrings("echo ok\n", second);
}

test "waitTimeoutMsFromNs rounds up to whole milliseconds" {
    try std.testing.expectEqual(@as(c_int, 0), waitTimeoutMsFromNs(0));
    try std.testing.expectEqual(@as(c_int, 1), waitTimeoutMsFromNs(std.time.ns_per_ms - 1));
    try std.testing.expectEqual(@as(c_int, 50), waitTimeoutMsFromNs((49 * std.time.ns_per_ms) + 999_999));
}

test "computeFrameWaitDecision returns idle wait while idle" {
    const decision = computeFrameWaitDecision(true, false, 10 * std.time.ns_per_ms);
    switch (decision) {
        .idle_wait_ms => |timeout_ms| try std.testing.expectEqual(@as(c_int, 40), timeout_ms),
        else => try std.testing.expect(false),
    }
}

test "computeFrameWaitDecision keeps active pacing without vsync" {
    const decision = computeFrameWaitDecision(false, false, 5 * std.time.ns_per_ms);
    switch (decision) {
        .active_sleep_ns => |sleep_ns| try std.testing.expectEqual(@as(u64, active_frame_ns - (5 * std.time.ns_per_ms)), sleep_ns),
        else => try std.testing.expect(false),
    }
}

test "computeFrameWaitDecision defers to vsync while active" {
    const decision = computeFrameWaitDecision(false, true, 5 * std.time.ns_per_ms);
    switch (decision) {
        .none => {},
        else => try std.testing.expect(false),
    }
}

test "fullSetForMode promotes focused (and previous during panning) to full size" {
    try std.testing.expectEqual(@as(?usize, null), fullSetForMode(.Grid, 2, 7).primary);
    try std.testing.expectEqual(@as(?usize, null), fullSetForMode(.GridResizing, 2, 7).primary);

    const full = fullSetForMode(.Full, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), full.primary);
    try std.testing.expectEqual(@as(?usize, null), full.secondary);

    const expanding = fullSetForMode(.Expanding, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), expanding.primary);
    try std.testing.expectEqual(@as(?usize, null), expanding.secondary);

    const collapsing = fullSetForMode(.Collapsing, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), collapsing.primary);
    try std.testing.expectEqual(@as(?usize, null), collapsing.secondary);

    const pan = fullSetForMode(.PanningLeft, 2, 7);
    try std.testing.expectEqual(@as(?usize, 2), pan.primary);
    try std.testing.expectEqual(@as(?usize, 7), pan.secondary);
}

test "markTeardownComplete returns true only once" {
    var done = false;
    try std.testing.expect(markTeardownComplete(&done));
    try std.testing.expect(!markTeardownComplete(&done));
}

test "shouldContinueQuitCaptureDrain stops after quiet window" {
    const start_ns: i128 = 0;
    const last_growth_ns: i128 = 0;
    const at_quiet_boundary = quit_capture_drain_quiet_ns;
    try std.testing.expect(!shouldContinueQuitCaptureDrain(start_ns, last_growth_ns, at_quiet_boundary));

    const just_before_quiet = quit_capture_drain_quiet_ns - 1;
    try std.testing.expect(shouldContinueQuitCaptureDrain(start_ns, last_growth_ns, just_before_quiet));
}

test "shouldContinueQuitCaptureDrain stops after max window" {
    const start_ns: i128 = 0;
    const recent_growth_ns = quit_capture_drain_max_ns - 1;
    const at_max_boundary = quit_capture_drain_max_ns;
    try std.testing.expect(!shouldContinueQuitCaptureDrain(start_ns, recent_growth_ns, at_max_boundary));
}

const TestSwapError = error{InitFailed};

const TestResource = struct {
    id: u8,
    deinit_count: *usize,

    fn deinit(self: *TestResource) void {
        self.deinit_count.* += 1;
    }
};

const TestSwapContext = struct {
    fail_on: enum {
        none,
        first,
        second,
    } = .none,
    next_id: u8 = 10,
    new_deinit_count: usize = 0,
};

fn initTestResourceFirst(ctx: *TestSwapContext) TestSwapError!TestResource {
    if (ctx.fail_on == .first) return error.InitFailed;

    const id = ctx.next_id;
    ctx.next_id += 1;
    return .{
        .id = id,
        .deinit_count = &ctx.new_deinit_count,
    };
}

fn initTestResourceSecond(ctx: *TestSwapContext) TestSwapError!TestResource {
    if (ctx.fail_on == .second) return error.InitFailed;

    const id = ctx.next_id;
    ctx.next_id += 1;
    return .{
        .id = id,
        .deinit_count = &ctx.new_deinit_count,
    };
}

fn deinitTestResource(resource: *TestResource) void {
    resource.deinit();
}

test "swapTwoResources replaces both resources after successful initialization" {
    var first_deinit_count: usize = 0;
    var second_deinit_count: usize = 0;
    var first = TestResource{ .id = 1, .deinit_count = &first_deinit_count };
    var second = TestResource{ .id = 2, .deinit_count = &second_deinit_count };
    var ctx = TestSwapContext{};

    try swapTwoResources(
        TestResource,
        TestSwapContext,
        TestSwapError,
        &first,
        &second,
        &ctx,
        initTestResourceFirst,
        initTestResourceSecond,
        deinitTestResource,
    );

    try std.testing.expectEqual(@as(usize, 1), first_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), second_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), ctx.new_deinit_count);
    try std.testing.expectEqual(@as(u8, 10), first.id);
    try std.testing.expectEqual(@as(u8, 11), second.id);
}

test "swapTwoResources keeps old resources when second initialization fails" {
    var first_deinit_count: usize = 0;
    var second_deinit_count: usize = 0;
    var first = TestResource{ .id = 1, .deinit_count = &first_deinit_count };
    var second = TestResource{ .id = 2, .deinit_count = &second_deinit_count };
    var ctx = TestSwapContext{ .fail_on = .second };

    try std.testing.expectError(
        error.InitFailed,
        swapTwoResources(
            TestResource,
            TestSwapContext,
            TestSwapError,
            &first,
            &second,
            &ctx,
            initTestResourceFirst,
            initTestResourceSecond,
            deinitTestResource,
        ),
    );

    try std.testing.expectEqual(@as(usize, 0), first_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), second_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), ctx.new_deinit_count);
    try std.testing.expectEqual(@as(u8, 1), first.id);
    try std.testing.expectEqual(@as(u8, 2), second.id);
}

const TestScaleChangeError = error{ReloadFailed};

const TestScaleChangeContext = struct {
    reload_calls: usize = 0,
    resize_calls: usize = 0,
    fail_reload: bool = false,
};

fn reloadTestScaleChange(ctx: *TestScaleChangeContext) TestScaleChangeError!void {
    ctx.reload_calls += 1;
    if (ctx.fail_reload) return error.ReloadFailed;
}

fn resizeTestScaleChange(ctx: *TestScaleChangeContext) void {
    ctx.resize_calls += 1;
}

test "adjustedRenderHeightForMode reserves cwd bar only in stable grid mode" {
    const render_height: c_int = 800;
    const grid_height = adjustedRenderHeightForMode(.Grid, render_height, 1.0, 2);

    try std.testing.expect(grid_height < render_height);
    try std.testing.expectEqual(render_height, adjustedRenderHeightForMode(.Collapsing, render_height, 1.0, 2));
    try std.testing.expectEqual(render_height, adjustedRenderHeightForMode(.GridResizing, render_height, 1.0, 2));
    try std.testing.expectEqual(render_height, adjustedRenderHeightForMode(.Full, render_height, 1.0, 2));
}

test "applyScaleChangeAndResize reloads then resizes when scale changes" {
    var ctx = TestScaleChangeContext{};

    try applyScaleChangeAndResize(
        TestScaleChangeContext,
        TestScaleChangeError,
        &ctx,
        1.0,
        2.0,
        reloadTestScaleChange,
        resizeTestScaleChange,
    );

    try std.testing.expectEqual(@as(usize, 1), ctx.reload_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.resize_calls);
}

test "applyScaleChangeAndResize only resizes when scale stays unchanged" {
    var ctx = TestScaleChangeContext{};

    try applyScaleChangeAndResize(
        TestScaleChangeContext,
        TestScaleChangeError,
        &ctx,
        1.0,
        1.0,
        reloadTestScaleChange,
        resizeTestScaleChange,
    );

    try std.testing.expectEqual(@as(usize, 0), ctx.reload_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.resize_calls);
}

test "applyScaleChangeAndResize skips resize when reload fails" {
    var ctx = TestScaleChangeContext{ .fail_reload = true };

    try std.testing.expectError(
        error.ReloadFailed,
        applyScaleChangeAndResize(
            TestScaleChangeContext,
            TestScaleChangeError,
            &ctx,
            1.0,
            2.0,
            reloadTestScaleChange,
            resizeTestScaleChange,
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), ctx.reload_calls);
    try std.testing.expectEqual(@as(usize, 0), ctx.resize_calls);
}

test "seedSessionAgentMetadataFromEntry seeds known restored metadata" {
    const allocator = std.testing.allocator;

    var session: SessionState = undefined;
    session.slot_index = 3;
    session.agent_kind = null;
    session.agent_session_id = null;
    session.agent_metadata_captured = true;

    const entry = config_mod.Persistence.TerminalEntry{
        .path = "/tmp/test",
        .agent_type = "codex",
        .agent_session_id = "abc-123",
    };
    seedSessionAgentMetadataFromEntry(&session, entry, allocator);

    try std.testing.expect(session.agent_kind != null);
    try std.testing.expectEqual(session_state.AgentKind.codex, session.agent_kind.?);
    try std.testing.expect(session.agent_session_id != null);
    try std.testing.expectEqualStrings("abc-123", session.agent_session_id.?);
    try std.testing.expect(session.agent_session_id.?.ptr != entry.agent_session_id.?.ptr);
    // A seeded id is marked captured so it survives periodic saves (Bug 2 fix).
    try std.testing.expect(session.agent_metadata_captured);

    if (session.agent_session_id) |sid| allocator.free(sid);
}

test "syncPersistenceTerminalEntriesFromSessions keeps restored agent metadata (Bug 2)" {
    const allocator = std.testing.allocator;

    var persistence = config_mod.Persistence.init(allocator);
    defer persistence.deinit(allocator);

    try persistence.appendTerminalEntry(allocator, "/one", "codex", "seed-id", false, 0);

    var session: SessionState = undefined;
    session.slot_index = 0;
    session.spawned = true;
    session.dead = false;
    session.cwd_path = "/one";
    session.agent_kind = null;
    session.agent_session_id = null;
    session.agent_metadata_captured = false;

    seedSessionAgentMetadataFromEntry(&session, persistence.terminal_entries.items[0], allocator);
    defer if (session.agent_session_id) |sid| allocator.free(sid);

    var sessions = [_]*SessionState{&session};

    // A seeded id must keep being persisted, even without a fresh live/quit
    // capture — otherwise a mid-run agent's resume id is wiped on the first save.
    _ = try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator);
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items.len);
    try std.testing.expectEqualStrings("codex", persistence.terminal_entries.items[0].agent_type.?);
    try std.testing.expectEqualStrings("seed-id", persistence.terminal_entries.items[0].agent_session_id.?);
}

test "syncPersistenceTerminalEntriesFromSessions reacts to cd, spawn, and despawn" {
    const allocator = std.testing.allocator;

    var persistence = config_mod.Persistence.init(allocator);
    defer persistence.deinit(allocator);

    var sessions_storage: [2]SessionState = undefined;
    for (&sessions_storage) |*session| {
        session.* = undefined;
        session.spawned = false;
        session.dead = false;
        session.cwd_path = null;
        session.agent_kind = null;
        session.agent_session_id = null;
        session.agent_metadata_captured = false;
    }
    var sessions = [_]*SessionState{ &sessions_storage[0], &sessions_storage[1] };

    sessions_storage[0].spawned = true;
    sessions_storage[0].cwd_path = "/one";

    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items.len);
    try std.testing.expectEqualStrings("/one", persistence.terminal_entries.items[0].path);

    sessions_storage[0].cwd_path = "/two";
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqualStrings("/two", persistence.terminal_entries.items[0].path);
    try std.testing.expect(!(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator)));

    sessions_storage[0].spawned = false;
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 0), persistence.terminal_entries.items.len);

    sessions_storage[1].spawned = true;
    sessions_storage[1].cwd_path = "/three";
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items.len);
    try std.testing.expectEqualStrings("/three", persistence.terminal_entries.items[0].path);

    sessions_storage[1].agent_kind = .codex;
    sessions_storage[1].agent_session_id = "sid-42";
    sessions_storage[1].agent_metadata_captured = true;
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator));
    try std.testing.expectEqualStrings("codex", persistence.terminal_entries.items[0].agent_type.?);
    try std.testing.expectEqualStrings("sid-42", persistence.terminal_entries.items[0].agent_session_id.?);
    try std.testing.expect(!(try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator)));
}

test "reordered arrangement round-trips through persistence entries" {
    const allocator = std.testing.allocator;

    // Live grid [/a, /b, /c]; user drags slot 2 to slot 0 → [/c, /a, /b].
    var s0: SessionState = undefined;
    var s1: SessionState = undefined;
    var s2: SessionState = undefined;
    testSession(&s0, 0, 1, true, false);
    testSession(&s1, 1, 2, true, false);
    testSession(&s2, 2, 3, true, false);
    const paths = [_][]const u8{ "/a", "/b", "/c" };
    var sessions = [_]*SessionState{ &s0, &s1, &s2 };
    for (sessions, 0..) |s, i| {
        s.cwd_path = paths[i];
        s.agent_kind = null;
        s.agent_session_id = null;
        s.agent_metadata_captured = false;
    }

    var views: [3]SessionViewState = undefined;
    var render_cache = try renderer_mod.RenderCache.init(allocator, 3);
    defer render_cache.deinit();
    var anim: AnimationState = undefined;
    anim.focused_session = 0;
    anim.previous_session = 0;

    const order = [_]usize{ 2, 0, 1 };
    try std.testing.expect(applyReorder(&sessions, &views, &render_cache, &anim, &order));

    // The writer walks physical array order, so the file records the user's
    // arrangement — no dedicated order field needed.
    var persistence = config_mod.Persistence.init(allocator);
    defer persistence.deinit(allocator);
    _ = try syncPersistenceTerminalEntriesFromSessions(&persistence, &sessions, allocator);
    try std.testing.expectEqual(@as(usize, 3), persistence.terminal_entries.items.len);
    try std.testing.expectEqualStrings("/c", persistence.terminal_entries.items[0].path);
    try std.testing.expectEqualStrings("/a", persistence.terminal_entries.items[1].path);
    try std.testing.expectEqualStrings("/b", persistence.terminal_entries.items[2].path);

    // Restore spawns entries in file position, minting order_seq per spawn the
    // way ensureSpawnedWithDir does (order_seq == 0 → next counter value), so
    // compaction reproduces the saved arrangement.
    var r0: SessionState = undefined;
    var r1: SessionState = undefined;
    var r2: SessionState = undefined;
    const restored_arr = [_]*SessionState{ &r0, &r1, &r2 };
    for (restored_arr, 0..) |r, i| {
        testSession(r, i, 0, true, false);
        r.order_seq = session_state.mintOrderSeqBlock(1);
        r.cwd_path = persistence.terminal_entries.items[i].path;
    }
    var restored = restored_arr;
    var restored_views: [3]SessionViewState = undefined;
    var restored_cache = try renderer_mod.RenderCache.init(allocator, 3);
    defer restored_cache.deinit();
    compactSessions(&restored, &restored_views, &restored_cache, &anim);
    try std.testing.expectEqualStrings("/c", restored[0].cwd_path.?);
    try std.testing.expectEqualStrings("/a", restored[1].cwd_path.?);
    try std.testing.expectEqualStrings("/b", restored[2].cwd_path.?);
}
