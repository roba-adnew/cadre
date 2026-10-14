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
/// An isolated instance (CADRE_CONFIG_DIR set, e.g. scripts/dev-instance.sh)
/// is titled distinctly so its windows are never mistaken for the daily app's.
fn windowTitle() [*:0]const u8 {
    return if (std.posix.getenv("CADRE_CONFIG_DIR") != null) "CADRE (dev)" else app_name;
}
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

/// One terminal list for every window: `groups[k]` is window k's slots, so
/// entries are grouped by window and ordered by slot within each window.
fn terminalEntriesMatchSlices(
    persistence: *const config_mod.Persistence,
    groups: []const []const *SessionState,
) bool {
    var entry_idx: usize = 0;
    for (groups, 0..) |sessions, window_index| {
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
            if (entry.window_index != window_index) return false;
            if (!optionalStringEql(entry.agent_type, agent_type)) return false;
            if (!optionalStringEql(entry.agent_session_id, agent_session_id)) return false;

            entry_idx += 1;
        }
    }
    return entry_idx == persistence.terminal_entries.items.len;
}

fn syncPersistenceTerminalEntriesFromSessions(
    persistence: *config_mod.Persistence,
    sessions: []const *SessionState,
    allocator: std.mem.Allocator,
) !bool {
    return syncPersistenceTerminalEntriesFromSlices(persistence, &[_][]const *SessionState{sessions}, allocator);
}

fn syncPersistenceTerminalEntriesFromSlices(
    persistence: *config_mod.Persistence,
    groups: []const []const *SessionState,
    allocator: std.mem.Allocator,
) !bool {
    if (terminalEntriesMatchSlices(persistence, groups)) return false;

    persistence.clearTerminalEntries(allocator);
    for (groups, 0..) |sessions, window_index| {
        for (sessions) |session| {
            if (!session.spawned or session.dead) continue;
            const path = session.cwd_path orelse continue;
            if (path.len == 0) continue;

            const agent_type = persistedAgentType(session);
            const agent_session_id = persistedAgentSessionId(session, agent_type);
            try persistence.appendTerminalEntryInWindow(allocator, path, agent_type, agent_session_id, session.hidden, session.persist_index, window_index);
        }
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

const quit_primary_wait_ms: u64 = 2500;
const quit_retry_wait_ms: u64 = 2500;
const quit_term_wait_ms: u64 = 500;
const quit_capture_drain_poll_ns: u64 = 20 * std.time.ns_per_ms;
const quit_capture_drain_quiet_ns: i128 = 250 * @as(i128, std.time.ns_per_ms);
const quit_capture_drain_max_ns: i128 = 2500 * @as(i128, std.time.ns_per_ms);

const QuitTeardownTask = struct {
    session: *SessionState,
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
    threads: []?std.Thread,
    done: *std.atomic.Value(bool),

    fn run(self: *QuitTeardownWorker) void {
        defer self.done.store(true, .seq_cst);
        for (self.threads, self.tasks) |*slot, *task| {
            slot.* = std.Thread.spawn(.{}, runTask, .{task}) catch |err| blk: {
                log.warn("quit teardown: failed to spawn parallel task for session {d}: {}", .{ task.session.slot_index, err });
                runTask(task);
                break :blk null;
            };
        }
        for (self.threads) |thread_opt| {
            if (thread_opt) |thread| {
                thread.join();
            }
        }
    }

    fn runTask(task: *QuitTeardownTask) void {
        log.info("quit teardown: session {d} has foreground agent {s}", .{ task.session.slot_index, task.agent_kind.name() });
        sendExitSequence(task.pty_master, task.agent_kind);
        std.Thread.sleep(quit_primary_wait_ms * std.time.ns_per_ms);

        var fg_pgrp = foregroundPgrp(task.slavePathZ(), task.shell_pid);
        if (fg_pgrp != null) {
            log.debug("quit teardown: session {d} agent {s} still foreground after primary quit, retrying with interrupt", .{ task.session.slot_index, task.agent_kind.name() });
            sendExitSequence(task.pty_master, task.agent_kind);
            std.Thread.sleep(quit_retry_wait_ms * std.time.ns_per_ms);
            fg_pgrp = foregroundPgrp(task.slavePathZ(), task.shell_pid);
        }

        if (fg_pgrp) |pgrp| {
            log.debug("quit teardown: session {d} agent {s} did not exit gracefully, sending SIGTERM", .{ task.session.slot_index, task.agent_kind.name() });
            _ = std.c.kill(-pgrp, std.c.SIG.TERM);
            std.Thread.sleep(quit_term_wait_ms * std.time.ns_per_ms);
        } else {
            log.debug("quit teardown: session {d} agent {s} exited gracefully", .{ task.session.slot_index, task.agent_kind.name() });
        }
    }
};

const QuitTeardownState = struct {
    active: bool = false,
    /// Heap-allocated: one task per session with a foreground agent, across
    /// every window (each task carries a PATH_MAX buffer).
    tasks: std.ArrayListUnmanaged(QuitTeardownTask) = .{},
    threads: std.ArrayListUnmanaged(?std.Thread) = .{},
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    worker: QuitTeardownWorker = undefined,
    thread: ?std.Thread = null,

    fn start(self: *QuitTeardownState, allocator: std.mem.Allocator, sessions: []const *SessionState) !bool {
        if (self.active) return true;

        self.tasks.clearRetainingCapacity();
        for (sessions) |session| {
            const agent_kind = session.detectForegroundAgent() orelse continue;
            const shell_pid = session.shellPid() orelse continue;
            const pty_master = session.ptyMasterFd() orelse continue;

            var task = QuitTeardownTask{
                .session = session,
                .shell_pid = shell_pid,
                .pty_master = pty_master,
                .agent_kind = agent_kind,
            };
            const copied_path = session.copyPtySlavePath(task.slave_path[0..]) orelse continue;
            task.slave_path_len = copied_path.len;

            session.startQuitCapture();
            try self.tasks.append(allocator, task);
        }

        if (self.tasks.items.len == 0) return false;

        try self.threads.resize(allocator, self.tasks.items.len);
        @memset(self.threads.items, null);
        self.done.store(false, .seq_cst);
        self.worker = .{
            .tasks = self.tasks.items,
            .threads = self.threads.items,
            .done = &self.done,
        };
        self.thread = try std.Thread.spawn(.{}, workerMain, .{&self.worker});
        self.active = true;
        return true;
    }

    fn deinit(self: *QuitTeardownState, allocator: std.mem.Allocator) void {
        self.join();
        self.tasks.deinit(allocator);
        self.threads.deinit(allocator);
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

fn drainQuitCaptureOutput(allocator: std.mem.Allocator, tasks: []const QuitTeardownTask) void {
    if (tasks.len == 0) return;

    const last_capture_lengths = allocator.alloc(usize, tasks.len) catch |err| {
        log.warn("quit teardown: failed to allocate capture tracking: {}", .{err});
        return;
    };
    defer allocator.free(last_capture_lengths);
    for (tasks, 0..) |task, idx| {
        last_capture_lengths[idx] = task.session.quitCaptureBytes().len;
    }

    const start_ns = std.time.nanoTimestamp();
    var last_growth_ns = start_ns;

    while (true) {
        var saw_growth = false;
        for (tasks, 0..) |task, idx| {
            const session = task.session;
            session.processOutput() catch |err| {
                log.warn("quit teardown: session {d} post-worker output drain failed: {}", .{ session.slot_index, err });
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

const PendingCommentSend = struct {
    session: usize,
    text: []const u8,
    send_after_ms: i64,
};

// "hosting" badge state for the hidden switcher. Detection spawns
// subprocesses, so it only polls while the switcher modal is open.
const hosting_poll_interval_ms: i64 = 5000;

/// Process-wide state: everything that is shared by (or outlives) the windows.
/// Lives on run()'s stack; threads keep `&app.core` for wake events, so it is
/// never moved or copied.
const App = struct {
    allocator: std.mem.Allocator,
    notify_queue: NotificationQueue,
    control_queue: ControlQueue,
    close_queue: control.CloseQueue,
    notify_sock: [:0]u8,
    control_sock: [:0]u8,
    control_discovery_path: []u8,
    notify_stop: std.atomic.Value(bool),
    control_stop: std.atomic.Value(bool),
    config: config_mod.Config,
    persistence: config_mod.Persistence,
    theme: colors_mod.Theme,
    animations_enabled: bool,
    core: platform.PlatformCore,
    input_source_tracker: macos_input.InputSourceTracker,
    font_paths: font_paths_mod.FontPaths,
    shared_font_cache: font_cache_mod.FontCache,
    ui_font_cache: font_cache_mod.FontCache,
    metrics_storage: metrics_mod.Metrics,
    metrics_ptr: ?*metrics_mod.Metrics,
    shell_path: []const u8,
    loop: xev.Loop,
    running: bool,
    persistence_dirty: bool,
    quit_teardown: QuitTeardownState,
    next_frame_wait: FrameWaitDecision,
    /// Open windows in display order; parallel to `persistence.windows`.
    windows: std.ArrayListUnmanaged(*Window),
    /// Every SessionState ever allocated, in persist-index order. Owned here
    /// and freed only at exit: an armed xev exit watcher keeps a raw pointer
    /// to its session, so a closed window must not free its sessions.
    pool: std.ArrayListUnmanaged(*SessionState),
    /// Window that most recently gained focus: target for QUIT, control
    /// spawns, story overlays and windowless events.
    last_focused: ?*Window,
    /// Cmd+Shift+N request, fulfilled after the event drain.
    pending_new_window: ?NewWindowRequest,
    /// Window to tear down at the end of this frame.
    closing_window: ?*Window,
    /// Session move between two existing windows, applied after every
    /// window's action drain so both grids change in one place.
    pending_move: ?MoveRequest,
    /// Drag-out resolved after every window's action drain (see applyPendingDragOut).
    pending_drag_out: ?DragOutRequest,

    fn focusedWindow(self: *App) *Window {
        return self.last_focused orelse self.windows.items[0];
    }

    fn anyWindowFocused(self: *const App) bool {
        for (self.windows.items) |w| {
            if (w.window_focused) return true;
        }
        return false;
    }

    fn windowIndex(self: *const App, window: *const Window) usize {
        for (self.windows.items, 0..) |w, i| {
            if (w == window) return i;
        }
        return 0;
    }

    fn windowById(self: *const App, id: c.SDL_WindowID) ?*Window {
        for (self.windows.items) |w| {
            if (w.window_id == id) return w;
        }
        return null;
    }

    const SessionRef = struct { window: *Window, idx: usize };

    /// Locate a session by its persist index (the CADRE_SESSION_ID hooks send).
    fn findSession(self: *const App, persist_index: usize) ?SessionRef {
        for (self.windows.items) |w| {
            if (findSessionIndexById(w.sessions, persist_index)) |idx| {
                return .{ .window = w, .idx = idx };
            }
        }
        return null;
    }

    /// Allocate a pool-owned session for grid slot `slot` with a pool-unique
    /// persist index (window 0 therefore keeps today's 0..max_terminals-1).
    fn allocSession(self: *App, slot: usize, size: pty_mod.winsize) !*SessionState {
        const session = try self.allocator.create(SessionState);
        errdefer self.allocator.destroy(session);
        session.* = try SessionState.init(self.allocator, slot, self.shell_path, size, self.notify_sock, self.theme);
        session.persist_index = self.pool.items.len;
        try self.pool.append(self.allocator, session);
        return session;
    }

    /// Give `target` the persist index `want`, swapping with whichever
    /// not-yet-spawned pool session currently holds it (pool-wide version of
    /// claimPersistIndex, so two windows can never share a tmux name).
    fn claimPersistIndexInPool(self: *App, target: *SessionState, want: usize) void {
        if (target.persist_index == want) return;
        for (self.pool.items) |other| {
            if (other.persist_index != want) continue;
            if (other.spawned) {
                log.warn("persist index {d} already in use by a live session; slot {d} keeps {d}", .{ want, target.slot_index, target.persist_index });
                return;
            }
            other.persist_index = target.persist_index;
            target.persist_index = want;
            return;
        }
        target.persist_index = want;
    }

    fn countForegroundProcessesAll(self: *const App) usize {
        var total: usize = 0;
        for (self.windows.items) |w| total += countForegroundProcesses(w.sessions);
        return total;
    }

    /// Only the focused window keeps vsync: N vsynced presents per frame would
    /// each wait for a display refresh.
    fn applyVsyncFocus(self: *App, focused: *Window) void {
        if (!self.config.rendering.vsync) return;
        for (self.windows.items) |w| {
            platform.setVSync(&w.pw, w == focused);
        }
    }

    fn refreshRecentFolders(self: *App) void {
        for (self.windows.items) |w| {
            w.recent_folders_comp_ptr.setFolders(self.persistence.getRecentFolders());
        }
    }

    fn syncPersistenceFromWindows(self: *App) !bool {
        var groups: [max_windows][]const *SessionState = undefined;
        const n = @min(self.windows.items.len, max_windows);
        for (self.windows.items[0..n], 0..) |w, i| groups[i] = w.sessions;
        return syncPersistenceTerminalEntriesFromSlices(&self.persistence, groups[0..n], self.allocator);
    }

    /// Mirror each window's focus/zoom into its persistence entry (2c).
    fn syncWindowViewState(self: *App) void {
        for (self.windows.items, 0..) |w, i| {
            if (i >= self.persistence.windows.items.len) break;
            const entry = &self.persistence.windows.items[i];
            const cur_zoomed = w.anim_state.mode == .Full;
            if (entry.focused_session != w.anim_state.focused_session or entry.zoomed != cur_zoomed) {
                entry.focused_session = w.anim_state.focused_session;
                entry.zoomed = cur_zoomed;
                self.persistence_dirty = true;
            }
        }
    }

    /// Route one SDL event: app-level events are handled here, window events
    /// go to the window they name (dropped when it is gone), and windowless
    /// events go to the focused window.
    fn dispatchEvent(self: *App, event: *c.SDL_Event, now: i64) !void {
        switch (event.type) {
            c.SDL_EVENT_KEYMAP_CHANGED => {
                if (builtin.os.tag == .macos) {
                    self.input_source_tracker.capture() catch |err| {
                        log.warn("Failed to capture input source: {}", .{err});
                    };
                }
                return;
            },
            c.SDL_EVENT_WINDOW_DESTROYED => {
                // Our own closes are unregistered before SDL reports them; a
                // still-registered window here was destroyed under us.
                if (self.windowById(event.window.windowID)) |w| {
                    log.warn("window {d} destroyed outside the close path", .{w.window_id});
                }
                return;
            },
            c.SDL_EVENT_QUIT => return self.focusedWindow().handleEvent(event, now),
            else => {},
        }
        if (eventWindowId(event)) |id| {
            const w = self.windowById(id) orelse return;
            return w.handleEvent(event, now);
        }
        return self.focusedWindow().handleEvent(event, now);
    }

    fn handleControlSpawn(self: *App, pending: *control.PendingSpawn, now: i64) void {
        self.focusedWindow().handleExternalSpawnRequest(pending, now);
    }

    fn handleControlClose(self: *App, pending: *control.PendingClose, now: i64) void {
        if (pending.request.session_id) |session_id| {
            if (self.findSession(session_id)) |ref| {
                ref.window.handleExternalCloseRequest(pending, now);
                return;
            }
            pending.completion.complete(.{ .failure = .{
                .code = .not_found,
                .message = "no Cadre session matches the requested identifier",
            } });
            return;
        }
        self.focusedWindow().handleExternalCloseRequest(pending, now);
    }

    /// Route an external notification to the window owning the session.
    /// Returns true when a fresh agent session id was captured.
    fn applyNotification(self: *App, note: notify.Notification, now: i64) bool {
        const allocator = self.allocator;
        switch (note) {
            .status => |st| {
                const ref = self.findSession(st.session) orelse return false;
                return ref.window.applyNotification(note, now);
            },
            .story => |st| {
                const target = if (self.findSession(st.session)) |ref| ref.window else self.focusedWindow();
                return target.applyNotification(note, now);
            },
            .agent_session => |ag| {
                const ref = self.findSession(ag.session) orelse {
                    allocator.free(ag.agent);
                    allocator.free(ag.session_id);
                    return false;
                };
                return ref.window.applyNotification(note, now);
            },
        }
    }

    fn requestNewWindow(self: *App, from: *Window) void {
        const allocator = self.allocator;
        if (self.pending_new_window != null) return;
        if (self.windows.items.len >= max_windows) {
            from.ui.showToast("Window limit reached", std.time.milliTimestamp());
            return;
        }
        const focused = from.sessions[from.anim_state.focused_session];
        const cwd: ?[]u8 = if (focused.cwd_path) |path| allocator.dupe(u8, path) catch |err| blk: {
            log.warn("failed to copy cwd for new window: {}", .{err});
            break :blk null;
        } else null;
        self.pending_new_window = cascadedRequest(from, cwd, null);
    }

    /// Cmd+Shift+P: detach `idx` of `from` into a new window opened next frame
    /// step (after the event drain). A lone visible terminal stays put.
    fn requestMoveToNewWindow(self: *App, from: *Window, idx: usize) void {
        const now = std.time.milliTimestamp();
        log.info("move to separate window requested: window {d} idx {d} visible {d} pending {} closing {} mode {s}", .{
            from.window_id, idx, countVisibleSessions(from.sessions), self.pending_new_window != null, self.closing_window == from, @tagName(from.anim_state.mode),
        });
        if (self.pending_new_window != null or self.closing_window == from) {
            log.warn("move ignored: a window request or close is already pending", .{});
            return;
        }
        if (idx >= from.sessions.len or !from.sessions[idx].isVisible()) {
            log.warn("move ignored: focused slot {d} is not a visible terminal", .{idx});
            return;
        }
        if (countVisibleSessions(from.sessions) <= 1) {
            from.ui.showToast("Already its own window", now);
            return;
        }
        if (self.windows.items.len >= max_windows) {
            from.ui.showToast("Window limit reached", now);
            return;
        }
        self.pending_new_window = cascadedRequest(from, null, .{ .window = from, .idx = idx });
    }

    fn cascadedRequest(from: *Window, cwd: ?[]u8, move_from: ?MoveSource) NewWindowRequest {
        return .{
            .width = from.window_width_points,
            .height = from.window_height_points,
            .x = if (from.window_x >= 0) from.window_x + new_window_offset_points else -1,
            .y = if (from.window_y >= 0) from.window_y + new_window_offset_points else -1,
            .cwd = cwd,
            .move_from = move_from,
        };
    }

    /// Move the visible session at `src_idx` from `src` into `dst`. The
    /// `*SessionState` pointer changes hands (PTY, tmux name, persist_index and
    /// any armed exit watcher travel with it); the renderer-bound texture and
    /// scrollbar caches are dropped on the source side and rebuilt lazily by
    /// the target; both grids reflow. Fails before touching anything when the
    /// target has no free slot.
    fn moveSession(self: *App, src: *Window, src_idx: usize, dst: *Window, now: i64) !void {
        const allocator = self.allocator;
        if (src == dst) return error.SameWindow;
        if (src_idx >= src.sessions.len or !src.sessions[src_idx].isVisible()) return error.NotVisible;
        const plan = planExternalSpawnSlot(dst.sessions, dst.grid.cols, dst.grid.rows, dst.anim_state.focused_session) orelse return error.TargetFull;
        const moving = src.sessions[src_idx];

        // --- source: detach the pane from everything that indexes it ---
        if (src.anim_state.focused_session == src_idx) {
            input_text.clearImeComposition(moving, &src.ime_composition) catch |err| {
                log.warn("failed to clear IME composition before move: {}", .{err});
            };
            if (src.anim_state.mode == .Full) {
                if (self.animations_enabled) {
                    grid_nav.startCollapseToGrid(&src.anim_state, now, src.cell_width_pixels, src.cell_height_pixels, src.render_width, src.render_height, src.grid.cols);
                } else {
                    src.anim_state.mode = .Grid;
                }
            }
        }
        if (src.pending_comment_send) |pending| {
            if (pending.session == src_idx) {
                allocator.free(pending.text);
                src.pending_comment_send = null;
            }
        }
        src.find_bar_comp_ptr.closeIfBoundTo(src_idx);
        src.reader_overlay_component.hideIfBoundTo(src_idx, now);
        src.foreground_cache = .{};

        var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
        defer if (old_positions) |*snapshots| snapshots.deinit(allocator);
        if (self.animations_enabled and src.anim_state.mode == .Grid) {
            old_positions = collectSessionIndexSnapshots(src.sessions, allocator) catch |err| blk: {
                log.warn("failed to snapshot session positions for move: {}", .{err});
                break :blk null;
            };
        }

        // Renderer-bound state must die while the source renderer is alive.
        carryViewState(&src.session_interaction_component.viewSlice()[src_idx], &dst.session_interaction_component.viewSlice()[plan.slot_index]);
        dropCacheEntry(&src.render_cache, src_idx);
        dropCacheEntry(&dst.render_cache, plan.slot_index);

        transferSlot(src.sessions, src_idx, dst.sessions, plan.slot_index);
        src.reflowAfterRemoval(if (old_positions) |*snapshots| snapshots.items else null, now);

        // --- target: same path as revealing a hidden terminal ---
        const dst_sessions = dst.sessions;
        compactSessions(dst_sessions, dst.session_interaction_component.viewSlice(), &dst.render_cache, &dst.anim_state);
        const visible = countVisibleSessions(dst_sessions);
        const new_idx = findSessionIndexById(dst_sessions, moving.id) orelse 0;
        dst.anim_state.previous_session = dst.anim_state.focused_session;
        dst.anim_state.focused_session = new_idx;
        dst.session_interaction_component.clearSelection(new_idx);
        if (visible <= 1) {
            dst.grid.cols = 1;
            dst.grid.rows = 1;
            dst.anim_state.mode = .Full;
        } else {
            const dims = GridLayout.calculateDimensions(visible);
            dst.grid.cols = dims.cols;
            dst.grid.rows = dims.rows;
            dst.anim_state.mode = .Grid;
        }
        dst.cell_width_pixels = @divFloor(dst.render_width, @as(c_int, @intCast(dst.grid.cols)));
        dst.cell_height_pixels = @divFloor(dst.render_height, @as(c_int, @intCast(dst.grid.rows)));
        dst.applyTerminalLayout();
        self.persistence_dirty = true;
        log.info("moved session persist_index={d} from window {d} slot {d} to window {d} slot {d}", .{ moving.persist_index, src.window_id, src_idx, dst.window_id, new_idx });
    }

    /// Apply a queued window-to-window move once every window's action drain
    /// has run this frame.
    fn applyPendingMove(self: *App, now: i64) void {
        const req = self.pending_move orelse return;
        self.pending_move = null;
        if (self.closing_window == req.src or self.closing_window == req.dst) return;
        if (self.windowIndexOrNull(req.src) == null or self.windowIndexOrNull(req.dst) == null) return;
        self.moveSession(req.src, req.idx, req.dst, now) catch |err| {
            log.warn("move to window failed: {}", .{err});
            req.src.ui.showToast("Could not move terminal", now);
            return;
        };
        _ = c.SDL_RaiseWindow(req.dst.pw.window);
    }

    fn windowRect(window: *const Window) WindowRect {
        var x: c_int = 0;
        var y: c_int = 0;
        var w: c_int = 0;
        var h: c_int = 0;
        if (!c.SDL_GetWindowPosition(window.pw.window, &x, &y)) log.warn("could not read window position: {s}", .{c.SDL_GetError()});
        if (!c.SDL_GetWindowSize(window.pw.window, &w, &h)) log.warn("could not read window size: {s}", .{c.SDL_GetError()});
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    /// Window under a screen point (points), preferring the last focused one
    /// when windows overlap. A window being closed never counts.
    fn windowAtPoint(self: *App, x: c_int, y: c_int) ?*Window {
        var rects: [max_windows]WindowRect = undefined;
        const n = @min(self.windows.items.len, max_windows);
        var preferred: ?usize = null;
        for (self.windows.items[0..n], 0..) |w, i| {
            rects[i] = if (w == self.closing_window) .{ .x = 0, .y = 0, .w = 0, .h = 0 } else windowRect(w);
            if (w == self.last_focused) preferred = i;
        }
        const idx = pickWindowAtPoint(rects[0..n], preferred, x, y) orelse return null;
        return self.windows.items[idx];
    }

    /// Slot of `window` under a screen point, using its live grid geometry.
    fn dropSlotIn(window: *const Window, screen_x: c_int, screen_y: c_int) ?usize {
        return dropSlotForPoint(
            screen_x,
            screen_y,
            windowRect(window),
            window.scale_x,
            window.scale_y,
            window.cell_width_pixels,
            window.cell_height_pixels,
            window.grid.cols,
            window.grid.rows,
            countVisibleSessions(window.sessions),
        );
    }

    /// A tile released outside its window: onto another Cadre window it moves
    /// there and lands on the slot under the pointer; onto empty screen it
    /// opens a new window at the drop point. Runs after every window's action
    /// drain since two windows change.
    fn applyPendingDragOut(self: *App, now: i64) void {
        const req = self.pending_drag_out orelse return;
        self.pending_drag_out = null;
        const src = req.src;
        if (self.windowIndexOrNull(src) == null or self.closing_window == src) return;
        if (req.idx >= src.sessions.len or !src.sessions[req.idx].isVisible()) return;

        const target = self.windowAtPoint(req.screen_x, req.screen_y);
        if (target == null or target.? == src) {
            if (target != null) return; // released over the source after all: the live re-slots already stand
            if (countVisibleSessions(src.sessions) <= 1) {
                src.ui.showToast("Already its own window", now);
                self.springboardBack(src, req.idx, req.origin, now);
                return;
            }
            if (self.pending_new_window != null or self.windows.items.len >= max_windows) {
                src.ui.showToast(if (self.pending_new_window != null) "Try again" else "Window limit reached", now);
                self.springboardBack(src, req.idx, req.origin, now);
                return;
            }
            self.pending_new_window = .{
                .width = src.window_width_points,
                .height = src.window_height_points,
                .x = @max(req.screen_x - drop_window_inset_points, 0),
                .y = @max(req.screen_y - drop_window_inset_points, 0),
                .cwd = null,
                .move_from = .{ .window = src, .idx = req.idx },
            };
            log.info("drag-out: opening a window at ({d}, {d}) for slot {d} of window {d}", .{ req.screen_x, req.screen_y, req.idx, src.window_id });
            return;
        }

        const dst = target.?;
        dst.session_interaction_component.setDropHint(null);
        const moving_id = src.sessions[req.idx].id;
        self.moveSession(src, req.idx, dst, now) catch |err| {
            log.warn("drag-out move into window {d} failed: {}", .{ dst.window_id, err });
            if (err == error.TargetFull) dst.ui.showToast("Window is full", now) else src.ui.showToast("Could not move terminal", now);
            self.springboardBack(src, req.idx, req.origin, now);
            return;
        };
        // Land where it was dropped: the move appended the tile at the end of
        // the target grid, so springboard it to the slot under the pointer.
        if (findSessionIndexById(dst.sessions, moving_id)) |landed| {
            if (dropSlotIn(dst, req.screen_x, req.screen_y)) |slot| {
                if (slot != landed) dst.reorderVisible(landed, slot, now);
            }
        }
        if (countSpawnedSessions(src.sessions) == 0) {
            // Nothing left to confirm; the empty source goes away at frame end.
            log.info("drag-out emptied window {d}; closing it", .{src.window_id});
            self.closing_window = src;
        }
        _ = c.SDL_RaiseWindow(dst.pw.window);
    }

    /// Cancelled drag-out: the live re-slots stand, so put the tile back
    /// where the drag started (same as Escape).
    fn springboardBack(self: *App, window: *Window, from: usize, origin: usize, now: i64) void {
        _ = self;
        if (from != origin) window.reorderVisible(from, origin, now);
    }

    /// While a drag is in flight, outline the slot under the pointer in the
    /// window it hovers (never the source: it draws its own lift cue).
    fn updateDropHints(self: *App) void {
        var src: ?*Window = null;
        for (self.windows.items) |w| {
            if (w.session_interaction_component.isReordering()) {
                src = w;
                break;
            }
        }
        var target: ?*Window = null;
        var slot: ?usize = null;
        if (src != null) {
            var gx: f32 = 0;
            var gy: f32 = 0;
            _ = c.SDL_GetGlobalMouseState(&gx, &gy);
            const sx: c_int = @intFromFloat(gx);
            const sy: c_int = @intFromFloat(gy);
            target = self.windowAtPoint(sx, sy);
            if (target) |t| {
                if (t != src.?) slot = dropSlotIn(t, sx, sy);
            }
        }
        for (self.windows.items) |w| {
            w.session_interaction_component.setDropHint(if (target == w and w != src) slot else null);
        }
    }

    fn windowIndexOrNull(self: *const App, window: *const Window) ?usize {
        for (self.windows.items, 0..) |w, i| {
            if (w == window) return i;
        }
        return null;
    }

    fn createWindowFromRequest(self: *App) void {
        const allocator = self.allocator;
        const req = self.pending_new_window orelse return;
        self.pending_new_window = null;
        defer if (req.cwd) |cwd| allocator.free(cwd);
        const now = std.time.milliTimestamp();
        const geometry = config_mod.WindowConfig{ .width = req.width, .height = req.height, .x = req.x, .y = req.y };
        // A move brings its own terminal, so the window opens with an empty slot 0.
        const window = Window.create(self, &[_]config_mod.Persistence.TerminalEntry{}, geometry, 0, false, req.cwd, req.move_from == null) catch |err| {
            log.err("failed to open a new window: {}", .{err});
            self.focusedWindow().ui.showToast("Could not open window", now);
            return;
        };
        self.windows.append(allocator, window) catch |err| {
            log.err("failed to register new window: {}", .{err});
            window.destroy();
            return;
        };
        self.persistence.windows.append(allocator, .{ .window = geometry }) catch |err| {
            log.warn("failed to persist new window entry: {}", .{err});
        };
        self.persistence_dirty = true;
        if (req.move_from) |mv| {
            const src_alive = self.windowIndexOrNull(mv.window) != null and self.closing_window != mv.window;
            const moved = if (src_alive) self.moveSession(mv.window, mv.idx, window, now) else error.SourceGone;
            moved catch |err| {
                // Never leave a window without a terminal: fall back to a fresh shell.
                log.warn("move into new window failed: {}; opening a fresh terminal instead", .{err});
                window.sessions[0].ensureSpawnedWithLoop(&self.loop) catch |spawn_err| {
                    log.err("failed to spawn fallback terminal in new window: {}", .{spawn_err});
                };
                window.applyTerminalLayout();
            };
        }
        _ = c.SDL_RaiseWindow(window.pw.window);
        log.info("opened window {d} (total {d})", .{ window.window_id, self.windows.items.len });
    }

    /// Tear down the window marked for closing. Its terminals are discarded
    /// (tmux sessions killed) like Cmd+W; the last window quits instead.
    fn finishClosingWindow(self: *App) void {
        const allocator = self.allocator;
        const window = self.closing_window orelse return;
        self.closing_window = null;
        if (self.windows.items.len <= 1) {
            if (window.handleQuitRequest()) {
                if (window.startQuitFlow()) self.running = false;
            }
            return;
        }
        for (window.sessions) |session| {
            if (!session.spawned) continue;
            log.info("closing window {d}: discarding terminal persist_index {d} (tmux {})", .{ window.window_id, session.persist_index, session.tmux_backed });
            session.despawn(allocator);
        }
        const idx = self.windowIndex(window);
        _ = self.windows.orderedRemove(idx);
        if (idx < self.persistence.windows.items.len) _ = self.persistence.windows.orderedRemove(idx);
        self.persistence_dirty = true;
        if (self.last_focused == window) self.last_focused = self.windows.items[0];
        log.info("closed window {d} (remaining {d})", .{ window.window_id, self.windows.items.len });
        window.destroy();
        self.applyVsyncFocus(self.focusedWindow());
    }

    /// After the loop exits: refresh cwds, finish the quit teardown and scrape
    /// agent ids, then sync the terminal entries one last time.
    fn finalizeOnExit(self: *App) void {
        const allocator = self.allocator;
        if (builtin.os.tag != .macos) return;
        const now = std.time.milliTimestamp();
        for (self.windows.items) |w| {
            for (w.sessions) |session| session.updateCwd(now);
        }

        if (self.quit_teardown.active) {
            for (self.windows.items) |w| w.quit_blocking_overlay_component.setActive(false);
            self.quit_teardown.join();
            drainQuitCaptureOutput(allocator, self.quit_teardown.tasks.items);
            for (self.quit_teardown.tasks.items) |task| {
                const session = task.session;
                session.stopQuitCapture();
                const text = session.quitCaptureBytes();
                log.debug("quit teardown: session {d} extracted {d} bytes of terminal text", .{ session.slot_index, text.len });
                if (terminal_history.extractLastUuid(text)) |uuid| {
                    // Scrape succeeded: overwrite with the freshest id from the farewell banner.
                    // Dup first so a failed alloc keeps the existing (hook-captured) id intact.
                    if (allocator.dupe(u8, uuid)) |new_id| {
                        if (session.agent_session_id) |sid| allocator.free(sid);
                        session.agent_session_id = new_id;
                        session.agent_kind = task.agent_kind;
                        session.agent_metadata_captured = true;
                        log.info("quit teardown: session {d} captured session id: {s}", .{ session.slot_index, uuid });
                    } else |err| {
                        log.warn("quit teardown: session {d} failed to allocate session id: {}", .{ session.slot_index, err });
                    }
                } else {
                    // Scrape failed: KEEP whatever the SessionStart hook captured this run instead
                    // of wiping it. The live hook is the reliable source of the resume id; the quit
                    // scrape is only a best-effort fallback for agents without the hook.
                    log.warn("quit teardown: session {d} agent {s} exited; no id in farewell output, keeping live-captured id (captured={})", .{ session.slot_index, task.agent_kind.name(), session.agent_metadata_captured });
                }
            }
        }

        _ = self.syncPersistenceFromWindows() catch |err| {
            std.debug.print("Failed to refresh terminal persistence: {}\n", .{err});
        };
    }
};

/// Upper bound on simultaneously open windows (sizes the per-frame slice
/// scratch; the session pool itself grows on demand).
pub const max_windows: usize = 8;
/// Cascade offset for a window opened with Cmd+Shift+N, in points.
const new_window_offset_points: c_int = 40;

const NewWindowRequest = struct {
    width: c_int,
    height: c_int,
    x: c_int,
    y: c_int,
    cwd: ?[]u8,
    /// Set when the window is opened to receive a detached terminal.
    move_from: ?MoveSource = null,
};

const MoveSource = struct { window: *Window, idx: usize };
const MoveRequest = struct { src: *Window, idx: usize, dst: *Window };
/// A grid tile released outside its window at screen point (x, y).
const DragOutRequest = struct { src: *Window, idx: usize, origin: usize, screen_x: c_int, screen_y: c_int };
/// New-window top-left sits this far up/left of the drop point.
const drop_window_inset_points: c_int = 24;

pub const WindowRect = struct { x: c_int, y: c_int, w: c_int, h: c_int };

fn rectContains(r: WindowRect, x: c_int, y: c_int) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

/// Index of the window under screen point (x, y). When several overlap the
/// `preferred` one (last focused, i.e. most likely on top) wins, else the
/// first match.
pub fn pickWindowAtPoint(rects: []const WindowRect, preferred: ?usize, x: c_int, y: c_int) ?usize {
    if (preferred) |p| {
        if (p < rects.len and rectContains(rects[p], x, y)) return p;
    }
    for (rects, 0..) |r, i| {
        if (rectContains(r, x, y)) return i;
    }
    return null;
}

/// Grid slot of `rect`'s window under screen point (x, y), or null when the
/// point is outside the window or past the last visible tile. `visible <= 1`
/// means the window shows a single pane filling it: slot 0.
pub fn dropSlotForPoint(
    screen_x: c_int,
    screen_y: c_int,
    rect: WindowRect,
    scale_x: f32,
    scale_y: f32,
    cell_w: c_int,
    cell_h: c_int,
    cols: usize,
    rows: usize,
    visible: usize,
) ?usize {
    if (!rectContains(rect, screen_x, screen_y)) return null;
    if (visible <= 1) return 0;
    if (cell_w <= 0 or cell_h <= 0 or cols == 0 or rows == 0) return null;
    const px: c_int = @intFromFloat(@as(f32, @floatFromInt(screen_x - rect.x)) * scale_x);
    const py: c_int = @intFromFloat(@as(f32, @floatFromInt(screen_y - rect.y)) * scale_y);
    const col: usize = @min(@as(usize, @intCast(@divFloor(px, cell_w))), cols - 1);
    const row: usize = @min(@as(usize, @intCast(@divFloor(py, cell_h))), rows - 1);
    const slot: usize = row * cols + col;
    return if (slot < visible) slot else null;
}

/// Hand the visible session at `src_idx` to `dst_idx` of another window by
/// swapping the slot pointers: the target's (never-spawned) placeholder takes
/// the vacated source slot, so both arrays stay fully populated. The moved
/// session arrives un-hidden with a fresh order_seq (lands at the end of the
/// target grid, like a reveal) and both sessions are marked dirty.
fn transferSlot(src: []*SessionState, src_idx: usize, dst: []*SessionState, dst_idx: usize) void {
    std.mem.swap(*SessionState, &src[src_idx], &dst[dst_idx]);
    src[src_idx].slot_index = src_idx;
    src[src_idx].markDirty();
    const moved = dst[dst_idx];
    moved.slot_index = dst_idx;
    moved.hidden = false;
    moved.order_seq = session_state.mintOrderSeqBlock(1);
    moved.markDirty();
}

/// Carry a pane's status badges across windows and reset everything that is
/// bound to the old window: scroll, selection, hover pins, waves and the
/// scrollbar textures (freed here, while the source renderer is alive).
fn carryViewState(src: *SessionViewState, dst: *SessionViewState) void {
    const status = src.status;
    const claude_seen = src.claude_seen;
    const attention = src.attention;
    const hosting = src.hosting;
    src.reset();
    dst.reset();
    dst.status = status;
    dst.claude_seen = claude_seen;
    dst.attention = attention;
    dst.hosting = hosting;
}

/// Free a slot's cached texture (renderer-bound) and forget its epochs.
fn dropCacheEntry(cache: *renderer_mod.RenderCache, idx: usize) void {
    if (idx >= cache.entries.len) return;
    if (cache.entries[idx].texture) |tex| c.SDL_DestroyTexture(tex);
    cache.entries[idx] = .{};
}

/// The window an SDL event names, or null for windowless events (QUIT,
/// keymap/clipboard changes), which go to the focused window.
fn eventWindowId(event: *const c.SDL_Event) ?c.SDL_WindowID {
    const t = event.type;
    if (t >= c.SDL_EVENT_WINDOW_FIRST and t <= c.SDL_EVENT_WINDOW_LAST) return event.window.windowID;
    return switch (t) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => event.key.windowID,
        c.SDL_EVENT_TEXT_EDITING => event.edit.windowID,
        c.SDL_EVENT_TEXT_INPUT => event.text.windowID,
        c.SDL_EVENT_MOUSE_MOTION => event.motion.windowID,
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => event.button.windowID,
        c.SDL_EVENT_MOUSE_WHEEL => event.wheel.windowID,
        c.SDL_EVENT_DROP_BEGIN, c.SDL_EVENT_DROP_FILE, c.SDL_EVENT_DROP_TEXT, c.SDL_EVENT_DROP_COMPLETE, c.SDL_EVENT_DROP_POSITION => event.drop.windowID,
        else => null,
    };
}

/// One SDL window: its renderer, the fonts and textures bound to that renderer,
/// the grid of sessions it shows, and the UI overlay root. Heap-allocated and
/// never moved: UI components keep raw pointers into it (fonts, sessions).
const Window = struct {
    app: *App,
    pw: platform.PlatformWindow,
    grid: GridLayout,
    text_input_active: bool,
    font_size: c_int,
    /// Whether this window is the frontmost (drives the accent overlay).
    /// Assume focused at launch; updated by SDL focus events.
    window_focused: bool,
    window_width_points: c_int,
    window_height_points: c_int,
    render_width: c_int,
    render_height: c_int,
    scale_x: f32,
    scale_y: f32,
    ui_scale: f32,
    font: font_mod.Font,
    /// Grid view renders this second, non-owning Font (faces shared with
    /// shared_font_cache) opened at the grid's native cell size, so small text
    /// stays crisp instead of being GPU-downscaled. Rebuilt before render() when
    /// the target size or the font cache generation changes.
    grid_font: font_mod.Font,
    grid_font_size: c_int,
    grid_font_generation: u64,
    grid_render_scale: f32,
    /// Live grid font scale (was config.grid.font_scale): seeded from
    /// persistence, adjusted by Cmd+Opt +/-, mirrored back to persistence.
    grid_font_scale: f32,
    /// Per-grid-shape font scale: when the grid shape changes, load its saved
    /// preset (Cmd+Opt zoom is remembered per "<cols>x<rows>"). 0 = not yet resolved.
    resolved_grid_cols: usize,
    resolved_grid_rows: usize,
    ui_font: font_mod.Font,
    ui: ui_mod.UiRoot,
    window_x: c_int,
    window_y: c_int,
    full_cols: u16,
    full_rows: u16,
    cell_width_pixels: c_int,
    cell_height_pixels: c_int,
    /// Grid slots: pool-owned sessions (see App.pool), never freed here.
    sessions: []*SessionState,
    window_id: c.SDL_WindowID,
    session_ui_info: []ui_mod.SessionUiInfo,
    render_cache: renderer_mod.RenderCache,
    foreground_cache: ForegroundProcessCache,
    anim_state: AnimationState,
    ime_composition: input_text.ImeComposition,
    last_focused_session: usize,
    last_logged_mode: app_state.ViewMode,
    relaunch_trace_frames: u8,
    window_close_suppress_countdown: u8,
    pending_comment_send: ?PendingCommentSend,
    hosting_last_poll_ms: ?i64,
    hosting_flags: []bool,
    last_render_ns: i128,
    /// Per-frame: an SDL event reached this window this frame.
    processed_event: bool,
    /// Per-frame: a session texture or the layout changed this frame.
    any_session_dirty: bool,
    session_interaction_component: *ui_mod.SessionInteractionComponent,
    find_bar_comp_ptr: *ui_mod.find_bar.FindBarComponent,
    context_menu_component: *ui_mod.context_menu.ContextMenuComponent,
    worktree_comp_ptr: *ui_mod.worktree_overlay.WorktreeOverlayComponent,
    recent_folders_comp_ptr: *ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent,
    hidden_switcher_comp_ptr: *ui_mod.hidden_switcher.HiddenSwitcherComponent,
    quit_confirm_component: *ui_mod.quit_confirm.QuitConfirmComponent,
    quit_blocking_overlay_component: *ui_mod.quit_blocking_overlay.QuitBlockingOverlayComponent,
    confirm_dialog_component: *ui_mod.confirm_dialog.ConfirmDialogComponent,
    metrics_overlay_component: *ui_mod.metrics_overlay.MetricsOverlayComponent,
    diff_overlay_component: *ui_mod.diff_overlay.DiffOverlayComponent,
    reader_overlay_component: *ui_mod.reader_overlay.ReaderOverlayComponent,
    story_overlay_component: *ui_mod.story_overlay.StoryOverlayComponent,

    /// Order: SDL window -> renderer -> fonts -> sizes -> sessions -> restore ->
    /// caches -> UI. Mirrors the pre-extraction init sequence of run().
    fn create(
        app: *App,
        restored_slice: []const config_mod.Persistence.TerminalEntry,
        geometry: config_mod.WindowConfig,
        focused_session: usize,
        zoomed: bool,
        initial_cwd: ?[]const u8,
        spawn_initial: bool,
    ) !*Window {
        const allocator = app.allocator;
        const persistence = &app.persistence;
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);
        self.app = app;

        // Dynamic grid layout - starts with 1x1 and grows as terminals are added
        self.grid = try GridLayout.init(allocator);
        errdefer self.grid.deinit();

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
        self.grid.cols = initial_dims.cols;
        self.grid.rows = initial_dims.rows;

        const window_pos = if (geometry.x >= 0 and geometry.y >= 0)
            platform.WindowPosition{ .x = geometry.x, .y = geometry.y }
        else
            null;

        self.pw = try platform.initWindow(
            windowTitle(),
            geometry.width,
            geometry.height,
            window_pos,
            app.config.rendering.vsync,
        );
        errdefer platform.deinitWindow(&self.pw);
        self.window_id = platform.windowId(&self.pw);
        macos_titlebar.style(self.pw.window, windowTitle(), app.theme.background.r, app.theme.background.g, app.theme.background.b);
        platform.startTextInput(self.pw.window);
        errdefer platform.stopTextInput(self.pw.window);
        self.text_input_active = true;

        self.font_size = persistence.font_size;
        self.window_focused = true;
        self.window_width_points = self.pw.window_w;
        self.window_height_points = self.pw.window_h;
        self.render_width = self.pw.render_w;
        self.render_height = self.pw.render_h;
        self.scale_x = self.pw.scale_x;
        self.scale_y = self.pw.scale_y;
        self.ui_scale = @max(self.scale_x, self.scale_y);
        self.grid_font_scale = app.config.grid.font_scale;

        self.font = try initSharedFont(allocator, self.pw.renderer, &app.shared_font_cache, layout.scaledFontSize(self.font_size, self.ui_scale));
        errdefer self.font.deinit();
        self.font.metrics = app.metrics_ptr;

        self.grid_font = try initSharedFont(allocator, self.pw.renderer, &app.shared_font_cache, layout.scaledFontSize(self.font_size, self.ui_scale));
        errdefer self.grid_font.deinit();
        self.grid_font.metrics = app.metrics_ptr;
        self.grid_font_size = layout.scaledFontSize(self.font_size, self.ui_scale);
        self.grid_font_generation = app.shared_font_cache.generation;
        self.grid_render_scale = 1.0;
        self.resolved_grid_cols = 0;
        self.resolved_grid_rows = 0;

        self.ui_font = try initSharedFont(allocator, self.pw.renderer, &app.ui_font_cache, layout.scaledFontSize(ui_font_size, self.ui_scale));
        errdefer self.ui_font.deinit();

        self.window_x = geometry.x;
        self.window_y = geometry.y;
        var actual_x: c_int = 0;
        var actual_y: c_int = 0;
        if (c.SDL_GetWindowPosition(self.pw.window, &actual_x, &actual_y)) {
            self.window_x = actual_x;
            self.window_y = actual_y;
        } else {
            log.warn("could not read window position: {s}", .{c.SDL_GetError()});
        }

        const initial_view_mode: app_state.ViewMode = if (initial_terminal_count == 1) .Full else .Grid;
        const initial_term_render_height = adjustedRenderHeightForMode(initial_view_mode, self.render_height, self.ui_scale, self.grid.rows);
        const initial_sizes = self.computeTerminalSizes();
        self.full_cols = initial_sizes.full.cols;
        self.full_rows = initial_sizes.full.rows;

        std.debug.print("Grid cell terminal size: {d}x{d}; full size: {d}x{d}\n", .{ initial_sizes.grid.cols, initial_sizes.grid.rows, self.full_cols, self.full_rows });
        std.debug.print("Starting with {d}x{d} grid: {s}\n", .{ self.grid.cols, self.grid.rows, app.shell_path });

        self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
        self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));

        const terminal_padding = dpi.scale(renderer_mod.terminal_padding, self.ui_scale);
        const usable_width = @max(0, self.render_width - terminal_padding * 2);
        const usable_height = @max(0, initial_term_render_height - terminal_padding * 2);

        // All sessions seed at grid-cell size. The first applyTerminalLayoutIfSizeChanged
        // promotes the focused session to full size if the initial view is Full.
        const size = pty_mod.winsize{
            .ws_row = initial_sizes.grid.rows,
            .ws_col = initial_sizes.grid.cols,
            .ws_xpixel = @intCast(usable_width),
            .ws_ypixel = @intCast(usable_height),
        };

        // Grid slots point at pool-owned sessions (App.pool keeps them alive
        // until exit) with pool-unique persist indices.
        self.sessions = try allocator.alloc(*SessionState, grid_layout.max_terminals);
        errdefer allocator.free(self.sessions);

        // UI root is torn down before the sessions it references (errdefer
        // order), matching destroy().
        self.ui = ui_mod.UiRoot.init(allocator);
        errdefer self.ui.deinit(self.pw.renderer);
        self.ui.assets.ui_font = &self.ui_font;
        self.ui.assets.font_cache = &app.ui_font_cache;

        const sessions = self.sessions;
        for (0..grid_layout.max_terminals) |i| {
            sessions[i] = try app.allocSession(i, size);
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
                if (entry.persist_index) |want| app.claimPersistIndexInPool(sessions[new_idx], want);

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
                sessions[new_idx].ensureSpawnedWithDir(dir, &app.loop) catch |err| {
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

        // Always spawn at least the first terminal; a window opened from a
        // terminal starts in that terminal's directory. A window opened to
        // receive a moved terminal keeps slot 0 empty for it.
        if (!spawn_initial) {} else if (initial_cwd) |cwd| {
            const cwd_buf = try allocZ(allocator, cwd);
            defer allocator.free(cwd_buf);
            const cwd_z: [:0]const u8 = cwd_buf[0..cwd.len :0];
            sessions[0].ensureSpawnedFresh(cwd_z, &app.loop) catch |err| {
                log.warn("failed to spawn in {s}: {}; falling back to the default directory", .{ cwd, err });
                try sessions[0].ensureSpawnedWithLoop(&app.loop);
            };
        } else {
            try sessions[0].ensureSpawnedWithLoop(&app.loop);
        }

        self.session_ui_info = try allocator.alloc(ui_mod.SessionUiInfo, grid_layout.max_terminals);
        errdefer allocator.free(self.session_ui_info);

        self.render_cache = try renderer_mod.RenderCache.init(allocator, grid_layout.max_terminals);
        errdefer self.render_cache.deinit();

        self.foreground_cache = ForegroundProcessCache{};

        // Restore focus + zoom from persistence (2c): clamp the focused pane to the restored
        // count, and only honor zoom when there is a pane to zoom into. The renderer computes
        // the Full rect from the window each frame, so setting .Full directly is sufficient.
        const restored_focus: usize = if (focused_session < initial_terminal_count)
            focused_session
        else
            0;
        const initial_mode: app_state.ViewMode = if (zoomed and initial_terminal_count >= 1)
            .Full
        else
            initial_view_mode;
        self.anim_state = AnimationState{
            .mode = initial_mode,
            .focused_session = restored_focus,
            .previous_session = restored_focus,
            .start_time = 0,
            .start_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .target_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };
        self.ime_composition = input_text.ImeComposition{};
        self.last_focused_session = self.anim_state.focused_session;
        self.last_logged_mode = self.anim_state.mode;
        self.relaunch_trace_frames = 0;
        self.window_close_suppress_countdown = 0;
        self.pending_comment_send = null;
        self.hosting_last_poll_ms = null;
        self.hosting_flags = try allocator.alloc(bool, sessions.len);
        errdefer allocator.free(self.hosting_flags);
        self.last_render_ns = 0;
        self.processed_event = false;
        self.any_session_dirty = false;

        self.session_interaction_component = try ui_mod.SessionInteractionComponent.init(allocator, sessions, &self.font);
        try self.ui.register(self.session_interaction_component.asComponent());

        // Right-click menu of the window/terminal shortcuts; sits above the
        // interaction layer so an open menu swallows mouse/keys first.
        self.context_menu_component = try ui_mod.context_menu.ContextMenuComponent.init(allocator);
        self.context_menu_component.window_id = self.window_id;
        try self.ui.register(self.context_menu_component.asComponent());

        // Cmd+F find-in-terminal. Shares the interaction component's per-session
        // view states so its highlight/scroll reuses the same selection + scrollback
        // machinery as mouse selection.
        self.find_bar_comp_ptr = try ui_mod.find_bar.FindBarComponent.init(
            allocator,
            sessions,
            self.session_interaction_component.viewSlice(),
        );
        try self.ui.register(self.find_bar_comp_ptr.asComponent());

        // Restored terminals land sequentially (visible first, hidden right after).
        // Compact once so hidden sessions get parked off-grid, otherwise the first ⌘N
        // after a reload would open beyond the restored hidden sessions' slots.
        compactSessions(sessions, self.session_interaction_component.viewSlice(), &self.render_cache, &self.anim_state);

        self.worktree_comp_ptr = try allocator.create(ui_mod.worktree_overlay.WorktreeOverlayComponent);
        self.worktree_comp_ptr.* = .{ .allocator = allocator };
        const worktree_component = ui_mod.UiComponent{
            .ptr = self.worktree_comp_ptr,
            .vtable = &ui_mod.worktree_overlay.WorktreeOverlayComponent.vtable,
            .z_index = 1000,
        };
        try self.ui.register(worktree_component);

        self.recent_folders_comp_ptr = try allocator.create(ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent);
        self.recent_folders_comp_ptr.* = .{ .allocator = allocator };
        const recent_folders_component = ui_mod.UiComponent{
            .ptr = self.recent_folders_comp_ptr,
            .vtable = &ui_mod.recent_folders_overlay.RecentFoldersOverlayComponent.vtable,
            .z_index = 1000,
        };
        try self.ui.register(recent_folders_component);
        self.recent_folders_comp_ptr.setFolders(persistence.getRecentFolders());

        self.hidden_switcher_comp_ptr = try allocator.create(ui_mod.hidden_switcher.HiddenSwitcherComponent);
        self.hidden_switcher_comp_ptr.* = .{ .allocator = allocator };
        try self.ui.register(.{
            .ptr = self.hidden_switcher_comp_ptr,
            .vtable = &ui_mod.hidden_switcher.HiddenSwitcherComponent.vtable,
            .z_index = 1000,
        });

        // Top-right count pill; z below the switcher modal so the modal dims over it.
        const hidden_indicator_comp_ptr = try allocator.create(ui_mod.hidden_indicator.HiddenIndicatorComponent);
        hidden_indicator_comp_ptr.* = .{ .allocator = allocator, .switcher = self.hidden_switcher_comp_ptr };
        try self.ui.register(.{
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
        try self.ui.register(help_component);

        const pill_group_component = try ui_mod.pill_group.PillGroupComponent.create(allocator, help_comp_ptr, self.recent_folders_comp_ptr, self.worktree_comp_ptr, hidden_indicator_comp_ptr);
        try self.ui.register(pill_group_component);
        const toast_component = try ui_mod.toast.ToastComponent.init(allocator);
        try self.ui.register(toast_component.asComponent());
        self.ui.toast_component = toast_component;
        // Escape-hold-to-collapse is intentionally disabled: return-to-grid is now
        // Cmd+Esc, and single/double Esc must pass straight through to the focused
        // program (e.g. Claude Code's Esc-Esc rewind, vim's Esc). Leaving the
        // EscapeHoldComponent unregistered keeps Escape a plain passthrough key.
        const hotkey_component = try ui_mod.hotkey_indicator.HotkeyIndicatorComponent.init(allocator, &self.ui_font);
        try self.ui.register(hotkey_component.asComponent());
        self.ui.hotkey_component = hotkey_component;
        const restart_component = try ui_mod.restart_buttons.RestartButtonsComponent.init(allocator);
        try self.ui.register(restart_component.asComponent());
        self.quit_confirm_component = try ui_mod.quit_confirm.QuitConfirmComponent.init(allocator);
        try self.ui.register(self.quit_confirm_component.asComponent());
        self.quit_blocking_overlay_component = try ui_mod.quit_blocking_overlay.QuitBlockingOverlayComponent.init(allocator);
        try self.ui.register(self.quit_blocking_overlay_component.asComponent());
        self.confirm_dialog_component = try ui_mod.confirm_dialog.ConfirmDialogComponent.init(allocator);
        try self.ui.register(self.confirm_dialog_component.asComponent());
        const global_shortcuts_component = try ui_mod.global_shortcuts.GlobalShortcutsComponent.create(allocator);
        try self.ui.register(global_shortcuts_component);
        const cwd_bar_component = try ui_mod.cwd_bar.CwdBarComponent.init(allocator);
        try self.ui.register(cwd_bar_component.asComponent());
        self.metrics_overlay_component = try ui_mod.metrics_overlay.MetricsOverlayComponent.init(allocator);
        try self.ui.register(self.metrics_overlay_component.asComponent());
        self.diff_overlay_component = try ui_mod.diff_overlay.DiffOverlayComponent.init(allocator);
        try self.ui.register(self.diff_overlay_component.asComponent());
        self.reader_overlay_component = try ui_mod.reader_overlay.ReaderOverlayComponent.init(allocator, sessions);
        try self.ui.register(self.reader_overlay_component.asComponent());
        self.story_overlay_component = try ui_mod.story_overlay.StoryOverlayComponent.init(allocator);
        try self.ui.register(self.story_overlay_component.asComponent());

        return self;
    }

    /// Teardown: UI (textures) before sessions, fonts before the renderer,
    /// renderer before the window.
    fn destroy(self: *Window) void {
        const allocator = self.app.allocator;
        allocator.free(self.hosting_flags);
        self.render_cache.deinit();
        allocator.free(self.session_ui_info);
        self.ui.deinit(self.pw.renderer);
        // Sessions stay in App.pool (armed exit watchers may still point at them).
        allocator.free(self.sessions);
        self.ui_font.deinit();
        self.grid_font.deinit();
        self.font.deinit();
        platform.stopTextInput(self.pw.window);
        platform.deinitWindow(&self.pw);
        self.grid.deinit();
        allocator.destroy(self);
    }

    fn applyTerminalLayout(self: *Window) void {
        const sizes = self.computeTerminalSizes();
        self.full_cols = sizes.full.cols;
        self.full_rows = sizes.full.rows;
        const full_set = fullSetForMode(self.anim_state.mode, self.anim_state.focused_session, self.anim_state.previous_session);
        _ = layout.applyTerminalResize(self.sessions, self.app.allocator, sizes, full_set);
    }

    fn applyTerminalLayoutIfSizeChanged(self: *Window) bool {
        const sizes = self.computeTerminalSizes();
        self.full_cols = sizes.full.cols;
        self.full_rows = sizes.full.rows;
        const full_set = fullSetForMode(self.anim_state.mode, self.anim_state.focused_session, self.anim_state.previous_session);
        return layout.applyTerminalResize(self.sessions, self.app.allocator, sizes, full_set);
    }

    /// Computes both terminal sizes from the raw render dimensions. grid_size
    /// always uses the Grid-mode CWD-bar reservation so unfocused sessions stay at
    /// stable dims across view-mode toggles; full_size uses the raw render height.
    fn computeTerminalSizes(self: *Window) layout.Sizes {
        const grid_render_height = adjustedRenderHeightForMode(.Grid, self.render_height, self.ui_scale, self.grid.rows);
        return layout.calculateTerminalSizes(&self.font, self.render_width, grid_render_height, self.render_height, self.grid_font.cell_width, self.grid_font.cell_height, self.grid.cols, self.grid.rows, self.ui_scale);
    }

    fn handleExternalSpawnRequest(self: *Window, pending: *control.PendingSpawn, now: i64) void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        if (validateExternalSpawnCwd(pending.request.cwd)) |failure| {
            pending.completion.complete(.{ .failure = failure });
            return;
        }

        const plan = planExternalSpawnSlot(sessions, self.grid.cols, self.grid.rows, self.anim_state.focused_session) orelse {
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

            if (app.animations_enabled) {
                self.grid.startResize(plan.cols, plan.rows, now, self.render_width, self.render_height, moves.items) catch |err| {
                    log.warn("failed to start external spawn grid resize: {}", .{err});
                    self.grid.cols = plan.cols;
                    self.grid.rows = plan.rows;
                };
                if (self.grid.is_resizing) {
                    self.anim_state.mode = .GridResizing;
                }
            } else {
                self.grid.cols = plan.cols;
                self.grid.rows = plan.rows;
            }
        }

        const session = sessions[plan.slot_index];
        session.ensureSpawnedFresh(cwd_z, &app.loop) catch |err| {
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

        self.session_interaction_component.setAttention(plan.slot_index, false, now);
        self.session_interaction_component.clearSelection(self.anim_state.focused_session);
        self.session_interaction_component.clearSelection(plan.slot_index);

        self.anim_state.previous_session = self.anim_state.focused_session;
        self.anim_state.focused_session = plan.slot_index;

        self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
        self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));
        self.applyTerminalLayout();

        pending.completion.complete(.{ .success = .{
            .session_id = session.id,
            .slot_index = plan.slot_index,
            .window_index = app.windowIndex(self),
        } });
    }

    /// Close the terminal in `idx`, reclaim its grid slot, and relayout/animate the
    /// remaining sessions exactly as the close-pane keybinding does. Shared by the
    /// `.DespawnSession` UI action and the external `close_session` control request
    /// so a programmatic close goes through the same battle-tested path (rather than
    /// signal-killing the child, which would leave a dead, unresponsive pane).
    /// `hide`: keep the session alive and just hide it from the grid (Cmd+J)
    /// instead of tearing it down. The grid reflow is identical either way.
    fn despawnSessionAtIndex(self: *Window, idx: usize, hide: bool, now: i64) void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        if (idx >= sessions.len) return;

        if (self.anim_state.mode == .Full and self.anim_state.focused_session == idx) {
            if (app.animations_enabled) {
                grid_nav.startCollapseToGrid(&self.anim_state, now, self.cell_width_pixels, self.cell_height_pixels, self.render_width, self.render_height, self.grid.cols);
            } else {
                self.anim_state.mode = .Grid;
            }
        }
        log.info("despawn idx={d} mode={s} spawned_count={d}", .{
            idx,
            @tagName(self.anim_state.mode),
            countSpawnedSessions(sessions),
        });
        var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
        defer if (old_positions) |*snapshots| {
            snapshots.deinit(allocator);
        };
        if (app.animations_enabled and self.anim_state.mode == .Grid) {
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
            self.session_interaction_component.resetView(idx);
        }
        sessions[idx].markDirty();
        self.reflowAfterRemoval(if (old_positions) |*snapshots| snapshots.items else null, now);
    }

    /// Grid half of a removal (close, hide or move-out): compact the slots,
    /// shrink the grid, animate the reflow from `old_positions` when given,
    /// re-focus a visible pane, and respawn a fresh shell when nothing is left.
    /// Springboard the visible tile at slot `from` to slot `to` (live reorder
    /// step, Escape cancel, or a cross-window drop landing on its slot).
    fn reorderVisible(self: *Window, from: usize, to: usize, now: i64) void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        const visible = countVisibleSessions(sessions);
        if (from >= visible or to >= visible or from == to) return;
        var order_buf: [grid_layout.max_terminals]usize = undefined;
        const order = springboardOrder(&order_buf, visible, from, to);
        // Snapshot pre-reorder indices so the slide can animate each
        // tile from where it was; taken before applyReorder permutes.
        var snapshots: ?std.ArrayList(SessionIndexSnapshot) = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
            log.warn("failed to snapshot reorder positions (slide skipped): {}", .{err});
            break :blk null;
        };
        defer if (snapshots) |*snaps| snaps.deinit(allocator);
        if (applyReorder(sessions, self.session_interaction_component.viewSlice(), &self.render_cache, &self.anim_state, order)) {
            // Tiles changed cells; repaint every visible pane. PTY
            // sizes are untouched — a pure permutation keeps the
            // uniform grid winsize, so no resize fires.
            for (sessions) |session| {
                if (session.isVisible()) session.markDirty();
            }
            app.persistence_dirty = true;
            // Slide tiles to their new cells. Unlike add/remove
            // reflows this also starts while a previous slide is in
            // flight (mode == .GridResizing): startResizeWithDuration
            // retargets from the drawn mid-flight rects, which is what
            // keeps rapid re-slots smooth instead of snapping.
            if (app.animations_enabled and (self.anim_state.mode == .Grid or self.anim_state.mode == .GridResizing)) {
                if (snapshots) |snaps| {
                    var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snaps.items, allocator) catch |err| blk: {
                        log.warn("failed to collect reorder moves (slide skipped): {}", .{err});
                        break :blk null;
                    };
                    if (move_result) |*moves| {
                        defer moves.list.deinit(allocator);
                        if (moves.moved) {
                            self.grid.startResizeWithDuration(self.grid.cols, self.grid.rows, now, self.render_width, self.render_height, moves.list.items, GridLayout.reorder_duration_ms) catch |err| {
                                log.warn("failed to start reorder slide: {}", .{err});
                            };
                            if (self.grid.is_resizing) {
                                self.anim_state.mode = .GridResizing;
                            }
                        }
                    }
                }
            }
        }
    }

    fn reflowAfterRemoval(self: *Window, old_positions: ?[]const SessionIndexSnapshot, now: i64) void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        compactSessions(sessions, self.session_interaction_component.viewSlice(), &self.render_cache, &self.anim_state);

        // Handle grid contraction (hidden sessions don't count toward grid size).
        const remaining_count = countVisibleSessions(sessions);
        const max_spawned_idx = highestVisibleIndex(sessions);
        const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

        if (remaining_count == 0 and app.windows.items.len > 1 and countSpawnedSessions(sessions) == 0) {
            // Nothing left in this window (not even hidden) and other windows
            // exist: leave it empty so the caller closes it instead of
            // respawning a shell nobody asked for (drag-out / move-out path).
            self.anim_state.focused_session = 0;
            self.grid.cols = 1;
            self.grid.rows = 1;
            self.anim_state.mode = .Full;
        } else if (remaining_count == 0) {
            // Re-spawn a fresh terminal in slot 0
            sessions[0].ensureSpawnedWithLoop(&app.loop) catch |err| {
                std.debug.print("Failed to respawn terminal: {}\n", .{err});
            };
            self.anim_state.focused_session = 0;
            self.grid.cols = 1;
            self.grid.rows = 1;
            self.cell_width_pixels = self.render_width;
            self.cell_height_pixels = self.render_height;
            self.anim_state.mode = .Full;
            self.applyTerminalLayout();
        } else if (remaining_count == 1) {
            // Only 1 terminal remains - go directly to Full mode, no resize animation
            self.grid.cols = 1;
            self.grid.rows = 1;
            self.cell_width_pixels = self.render_width;
            self.cell_height_pixels = self.render_height;
            if (!sessions[self.anim_state.focused_session].isVisible()) {
                for (sessions, 0..) |s, i| {
                    if (s.isVisible()) {
                        self.anim_state.focused_session = i;
                        break;
                    }
                }
            }
            self.anim_state.mode = .Full;
            self.applyTerminalLayout();
        } else {
            const new_dims = GridLayout.calculateDimensions(required_slots);
            const should_shrink = new_dims.cols < self.grid.cols or new_dims.rows < self.grid.rows;
            if (should_shrink) {
                const can_animate_reflow = app.animations_enabled and self.anim_state.mode == .Grid;
                const grid_will_resize = new_dims.cols != self.grid.cols or new_dims.rows != self.grid.rows;
                if (can_animate_reflow) {
                    if (old_positions) |snapshots| {
                        var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots, allocator) catch |err| blk: {
                            std.debug.print("Failed to collect session moves: {}\n", .{err});
                            break :blk null;
                        };
                        if (move_result) |*moves| {
                            defer moves.list.deinit(allocator);
                            if (grid_will_resize or moves.moved) {
                                self.grid.startResize(new_dims.cols, new_dims.rows, now, self.render_width, self.render_height, moves.list.items) catch |err| {
                                    std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                };
                                self.anim_state.mode = .GridResizing;
                            } else {
                                self.grid.cols = new_dims.cols;
                                self.grid.rows = new_dims.rows;
                            }
                        } else {
                            self.grid.cols = new_dims.cols;
                            self.grid.rows = new_dims.rows;
                        }
                    } else {
                        self.grid.cols = new_dims.cols;
                        self.grid.rows = new_dims.rows;
                    }
                } else {
                    self.grid.cols = new_dims.cols;
                    self.grid.rows = new_dims.rows;
                }

                self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
                self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));
                self.applyTerminalLayout();

                if (!sessions[self.anim_state.focused_session].isVisible()) {
                    var new_focus: usize = 0;
                    for (sessions, 0..) |s, i| {
                        if (s.isVisible()) {
                            new_focus = i;
                            break;
                        }
                    }
                    self.anim_state.focused_session = new_focus;
                }
                std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ self.grid.cols, self.grid.rows, remaining_count });
            } else {
                const can_animate_reflow = app.animations_enabled and self.anim_state.mode == .Grid;
                if (can_animate_reflow) {
                    if (old_positions) |snapshots| {
                        var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots, allocator) catch |err| blk: {
                            std.debug.print("Failed to collect session moves: {}\n", .{err});
                            break :blk null;
                        };
                        if (move_result) |*moves| {
                            defer moves.list.deinit(allocator);
                            if (moves.moved) {
                                self.grid.startResize(self.grid.cols, self.grid.rows, now, self.render_width, self.render_height, moves.list.items) catch |err| {
                                    std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                };
                                self.anim_state.mode = .GridResizing;
                            }
                        }
                    }
                }
                if (!sessions[self.anim_state.focused_session].isVisible()) {
                    var new_focus: usize = 0;
                    for (sessions, 0..) |s, i| {
                        if (s.isVisible()) {
                            new_focus = i;
                            break;
                        }
                    }
                    self.anim_state.focused_session = new_focus;
                }
            }
        }
    }

    fn handleExternalCloseRequest(self: *Window, pending: *control.PendingClose, now: i64) void {
        const sessions = self.sessions;
        const idx = resolveCloseTargetIndex(sessions, pending.request) orelse {
            pending.completion.complete(.{ .failure = .{
                .code = .not_found,
                .message = "no Cadre session matches the requested identifier",
            } });
            return;
        };

        const session_id = sessions[idx].id;
        self.despawnSessionAtIndex(idx, false, now);

        pending.completion.complete(.{ .success = .{ .session_id = session_id } });
    }

    fn reloadFontsForScaleChange(self: *Window) font_mod.Font.InitError!void {
        try reloadFontsForScale(
            self.app.allocator,
            self.pw.renderer,
            &self.app.shared_font_cache,
            &self.app.ui_font_cache,
            self.font_size,
            self.ui_scale,
            self.app.metrics_ptr,
            &self.font,
            &self.ui_font,
        );
        self.ui.assets.ui_font = &self.ui_font;
    }

    fn applyResizeForScaleChange(self: *Window) void {
        const sizes = self.computeTerminalSizes();
        self.full_cols = sizes.full.cols;
        self.full_rows = sizes.full.rows;
        const full_set = fullSetForMode(self.anim_state.mode, self.anim_state.focused_session, self.anim_state.previous_session);
        _ = layout.applyTerminalResize(self.sessions, self.app.allocator, sizes, full_set);
    }

    fn handleQuitRequest(self: *Window) bool {
        const running_processes = self.app.countForegroundProcessesAll();
        if (running_processes > 0) {
            self.quit_confirm_component.show(running_processes);
            return false;
        }
        return true;
    }

    fn startQuitFlow(self: *Window) bool {
        const app = self.app;
        if (builtin.os.tag != .macos) return true;
        if (app.quit_teardown.active) return false;
        const started = app.quit_teardown.start(app.allocator, app.pool.items) catch |err| {
            log.warn("quit teardown: failed to start worker thread: {}", .{err});
            return true;
        };
        if (!started) return true;
        self.quit_blocking_overlay_component.setActive(true);
        return false;
    }

    /// Close this window (close button / Cmd+Shift+W). The last window takes
    /// the quit path; otherwise confirm when something is still running.
    fn requestClose(self: *Window) void {
        const app = self.app;
        if (app.quit_teardown.active) return;
        if (app.windows.items.len <= 1) {
            if (self.handleQuitRequest()) {
                if (self.startQuitFlow()) app.running = false;
            }
            return;
        }
        const running_processes = countForegroundProcesses(self.sessions);
        if (running_processes > 0) {
            self.confirm_dialog_component.show(
                "Close Window?",
                "A process is still running in this window. Close anyway?",
                "Close",
                "Cancel",
                .{ .CloseWindow = {} },
            );
            return;
        }
        app.closing_window = self;
    }

    /// One SDL event for this window: UI overlays get first refusal, then the
    /// app-level switch. Every early exit that used to `continue` the event
    /// drain now returns.
    fn handleEvent(self: *Window, event: *c.SDL_Event, now: i64) !void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        if (self.anim_state.focused_session != self.last_focused_session) {
            const previous_session = self.last_focused_session;
            input_text.clearImeComposition(sessions[previous_session], &self.ime_composition) catch |err| {
                std.debug.print("Failed to clear IME composition: {}\n", .{err});
            };
            self.ime_composition.reset();
            self.last_focused_session = self.anim_state.focused_session;
        }
        self.processed_event = true;
        var scaled_event = layout.scaleEventToRender(event, self.scale_x, self.scale_y);
        if (builtin.os.tag == .macos and scaled_event.type == c.SDL_EVENT_KEY_DOWN) {
            const key = scaled_event.key.key;
            const mod = scaled_event.key.mod;
            const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
            const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
            const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;
            if (has_gui and !has_blocking_mod and !has_shift and key == c.SDLK_W) {
                // Use 2 frames to cover the delay between Cmd+W and SDL delivering a close request.
                // A single frame is not always enough to suppress the close in the next loop.
                self.window_close_suppress_countdown = 2;
            }
        }
        const focused_has_foreground_process = self.foreground_cache.get(now, self.anim_state.focused_session, sessions);
        const host_snapshot = ui_host.makeUiHost(
            now,
            self.render_width,
            self.render_height,
            self.ui_scale,
            self.cell_width_pixels,
            self.cell_height_pixels,
            self.grid_font.cell_width,
            self.grid_font.cell_height,
            self.grid_font_size,
            self.grid.cols,
            self.grid.rows,
            self.full_cols,
            self.full_rows,
            &self.anim_state,
            sessions,
            self.session_ui_info,
            self.session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &app.theme,
        );
        var event_ui_host = host_snapshot;
        ui_host.applyMouseContext(&self.ui, &event_ui_host, &scaled_event);

        const ui_consumed = self.ui.handleEvent(&event_ui_host, &scaled_event);
        if (ui_consumed) return;

        switch (scaled_event.type) {
            c.SDL_EVENT_QUIT => {
                if (app.quit_teardown.active) return;
                if (self.handleQuitRequest()) {
                    if (self.startQuitFlow()) {
                        app.running = false;
                    }
                }
            },
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                if (app.quit_teardown.active) return;
                if (builtin.os.tag == .macos and self.window_close_suppress_countdown > 0) {
                    // Reset immediately so we only suppress this close request.
                    self.window_close_suppress_countdown = 0;
                    return;
                }
                self.requestClose();
            },
            c.SDL_EVENT_WINDOW_MOVED => {
                self.window_x = scaled_event.window.data1;
                self.window_y = scaled_event.window.data2;

                self.persistGeometry();
                savePersistenceIfDirty(&app.persistence, allocator, &app.persistence_dirty);
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                layout.updateRenderSizes(self.pw.window, &self.window_width_points, &self.window_height_points, &self.render_width, &self.render_height, &self.scale_x, &self.scale_y);
                const prev_scale = self.ui_scale;
                self.ui_scale = @max(self.scale_x, self.scale_y);
                try applyScaleChangeAndResize(
                    Window,
                    font_mod.Font.InitError,
                    self,
                    prev_scale,
                    self.ui_scale,
                    reloadFontsForScaleChange,
                    applyResizeForScaleChange,
                );
                self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
                self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));

                std.debug.print("Window resized to: {d}x{d} (render {d}x{d}), terminal size: {d}x{d}\n", .{ self.window_width_points, self.window_height_points, self.render_width, self.render_height, self.full_cols, self.full_rows });

                self.persistGeometry();
                savePersistenceIfDirty(&app.persistence, allocator, &app.persistence_dirty);
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                self.window_focused = false;
                // Clear stuck modifier keys. If focus left while a modifier was
                // held (e.g. Cmd during Cmd+Tab), macOS delivers the key-up to
                // the other app, so SDL keeps reporting the modifier as held and
                // plain keystrokes then act like Cmd-shortcuts. Resetting the
                // keyboard here makes the next keystrokes start from a clean state.
                c.SDL_ResetKeyboard();
                if (builtin.os.tag == .macos) {
                    if (self.text_input_active) {
                        platform.stopTextInput(self.pw.window);
                        self.text_input_active = false;
                    }
                }
                self.ime_composition.reset();
            },
            c.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                self.window_focused = true;
                app.last_focused = self;
                app.applyVsyncFocus(self);
                if (builtin.os.tag == .macos) {
                    app.input_source_tracker.restore() catch |err| {
                        log.warn("Failed to restore input source: {}", .{err});
                    };
                    // Reset text input so macOS restores the per-document input source.
                    if (self.text_input_active) {
                        platform.stopTextInput(self.pw.window);
                    }
                    platform.startTextInput(self.pw.window);
                    self.text_input_active = true;
                }
            },
            c.SDL_EVENT_TEXT_INPUT => {
                const focused = sessions[self.anim_state.focused_session];
                input_text.handleTextInput(focused, &self.ime_composition, scaled_event.text.text, self.session_interaction_component) catch |err| {
                    std.debug.print("Text input failed: {}\n", .{err});
                };
                if (self.anim_state.mode == .Grid) {
                    self.session_interaction_component.setAttention(self.anim_state.focused_session, false, now);
                }
            },
            c.SDL_EVENT_TEXT_EDITING => {
                const focused = sessions[self.anim_state.focused_session];
                input_text.handleTextEditing(
                    focused,
                    &self.ime_composition,
                    scaled_event.edit.text,
                    scaled_event.edit.start,
                    scaled_event.edit.length,
                    self.session_interaction_component,
                ) catch |err| {
                    std.debug.print("Edit input failed: {}\n", .{err});
                };
            },
            c.SDL_EVENT_DROP_FILE => {
                const drop_path_ptr = scaled_event.drop.data;
                if (drop_path_ptr == null) return;
                const drop_path = std.mem.span(drop_path_ptr.?);
                if (drop_path.len == 0) return;

                const mouse_x: c_int = @intFromFloat(scaled_event.drop.x);
                const mouse_y: c_int = @intFromFloat(scaled_event.drop.y);

                const hovered_session = layout.calculateHoveredSession(
                    mouse_x,
                    mouse_y,
                    &self.anim_state,
                    self.cell_width_pixels,
                    self.cell_height_pixels,
                    self.render_width,
                    self.render_height,
                    self.grid.cols,
                    self.grid.rows,
                ) orelse return;

                var session = sessions[hovered_session];
                try session.ensureSpawnedWithLoop(&app.loop);

                const escaped = worktree.shellQuotePath(allocator, drop_path) catch |err| {
                    std.debug.print("Failed to escape dropped path: {}\n", .{err});
                    return;
                };
                defer allocator.free(escaped);

                terminal_actions.pasteText(session, allocator, escaped, self.session_interaction_component) catch |err| switch (err) {
                    error.NoTerminal => self.ui.showToast("No terminal to paste into", now),
                    error.NoShell => self.ui.showToast("Shell not available", now),
                    else => std.debug.print("Failed to paste dropped path: {}\n", .{err}),
                };
            },
            c.SDL_EVENT_KEY_DOWN => {
                const key = scaled_event.key.key;
                const mod = scaled_event.key.mod;
                const focused = sessions[self.anim_state.focused_session];

                const has_gui = (mod & c.SDL_KMOD_GUI) != 0;
                const has_blocking_mod = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_ALT)) != 0;
                const has_shift = (mod & c.SDL_KMOD_SHIFT) != 0;
                const terminal_shortcut: ?usize = if (self.worktree_comp_ptr.overlay.state == .Closed)
                    input.terminalSwitchShortcut(key, mod, self.grid.cols * self.grid.rows)
                else
                    null;

                if (has_gui and !has_blocking_mod and key == c.SDLK_Q) {
                    if (app.quit_teardown.active) return;
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘Q", now);
                    if (self.handleQuitRequest()) {
                        if (self.startQuitFlow()) {
                            app.running = false;
                        }
                    }
                    return;
                }

                if (has_gui and !has_blocking_mod and key == c.SDLK_ESCAPE) {
                    // Cmd+Esc: collapse the focused pane back to the grid.
                    // (Plain Esc still passes through to the program.)
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⎋", now);
                    if (self.anim_state.mode == .Full and countSpawnedSessions(sessions) > 1) {
                        if (app.animations_enabled) {
                            grid_nav.startCollapseToGrid(&self.anim_state, now, self.cell_width_pixels, self.cell_height_pixels, self.render_width, self.render_height, self.grid.cols);
                        } else {
                            const grid_row: c_int = @intCast(self.anim_state.focused_session / self.grid.cols);
                            const grid_col: c_int = @intCast(self.anim_state.focused_session % self.grid.cols);
                            self.anim_state.mode = .Grid;
                            self.anim_state.start_time = now;
                            self.anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = self.render_width, .h = self.render_height };
                            self.anim_state.target_rect = Rect{
                                .x = grid_col * self.cell_width_pixels,
                                .y = grid_row * self.cell_height_pixels,
                                .w = self.cell_width_pixels,
                                .h = self.cell_height_pixels,
                            };
                        }
                    }
                    return;
                }

                if (has_gui and !has_blocking_mod and has_shift and key == c.SDLK_N) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⇧N", now);
                    app.requestNewWindow(self);
                    return;
                }

                if (has_gui and !has_blocking_mod and has_shift and key == c.SDLK_W) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⇧W", now);
                    self.requestClose();
                    return;
                }

                if (has_gui and !has_blocking_mod and has_shift and key == c.SDLK_P) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⇧P", now);
                    app.requestMoveToNewWindow(self, self.anim_state.focused_session);
                    return;
                }

                if (has_gui and !has_blocking_mod and !has_shift and key == c.SDLK_W) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘W", now);
                    const session_idx = self.anim_state.focused_session;
                    const session = sessions[session_idx];

                    if (!session.spawned) {
                        log.info("close requested on unspawned session idx={d} mode={s}", .{ session_idx, @tagName(self.anim_state.mode) });
                        return;
                    }

                    // Chrome-like: closing the last tab closes the window. The
                    // last window overall keeps the relaunch-in-place behavior.
                    if (app.windows.items.len > 1 and countSpawnedSessions(sessions) == 1) {
                        self.requestClose();
                        return;
                    }

                    if (session.hasForegroundProcessThorough()) {
                        self.confirm_dialog_component.show(
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
                            @tagName(self.anim_state.mode),
                        });
                        if (spawned_count == 1) {
                            var working_dir = WorkingDir.init(allocator, session.cwd_path);
                            defer working_dir.deinit(allocator);

                            log.info("relaunching last session idx={d} grid_resizing={}", .{
                                session_idx,
                                self.grid.is_resizing,
                            });
                            self.relaunch_trace_frames = 120;
                            try session.relaunch(working_dir.cwd_z, &app.loop);
                            self.session_interaction_component.resetView(session_idx);
                            self.session_interaction_component.setAttention(session_idx, false, now);
                            session.markDirty();
                            self.grid.cancelResize();
                            log.info("relaunch complete idx={d} spawned={} dead={}", .{
                                session_idx,
                                session.spawned,
                                session.dead,
                            });
                            self.anim_state.mode = .Full;
                            return;
                        }

                        // If in full view, collapse to grid first
                        if (self.anim_state.mode == .Full) {
                            if (app.animations_enabled) {
                                grid_nav.startCollapseToGrid(&self.anim_state, now, self.cell_width_pixels, self.cell_height_pixels, self.render_width, self.render_height, self.grid.cols);
                            } else {
                                self.anim_state.mode = .Grid;
                            }
                        }

                        var old_positions: ?std.ArrayList(SessionIndexSnapshot) = null;
                        defer if (old_positions) |*snapshots| {
                            snapshots.deinit(allocator);
                        };
                        if (app.animations_enabled and self.anim_state.mode == .Grid) {
                            old_positions = collectSessionIndexSnapshots(sessions, allocator) catch |err| blk: {
                                std.debug.print("Failed to snapshot session positions: {}\n", .{err});
                                break :blk null;
                            };
                        }

                        // Close the terminal
                        session.despawn(allocator);
                        self.session_interaction_component.resetView(session_idx);
                        session.markDirty();

                        compactSessions(sessions, self.session_interaction_component.viewSlice(), &self.render_cache, &self.anim_state);

                        // Count remaining spawned sessions after closing
                        const remaining_count = countVisibleSessions(sessions);
                        const max_spawned_idx = highestVisibleIndex(sessions);
                        const required_slots = if (max_spawned_idx) |max_idx| max_idx + 1 else 0;

                        // Don't shrink below 1 terminal
                        if (remaining_count == 0) {
                            // Re-spawn a fresh terminal in slot 0
                            try sessions[0].ensureSpawnedWithLoop(&app.loop);
                            self.anim_state.focused_session = 0;
                            self.grid.cols = 1;
                            self.grid.rows = 1;
                            self.cell_width_pixels = self.render_width;
                            self.cell_height_pixels = self.render_height;
                            self.anim_state.mode = .Full;
                            self.applyTerminalLayout();
                        } else if (remaining_count == 1) {
                            // Only 1 terminal remains - go directly to Full mode, no resize animation
                            self.grid.cols = 1;
                            self.grid.rows = 1;
                            self.cell_width_pixels = self.render_width;
                            self.cell_height_pixels = self.render_height;
                            if (!sessions[self.anim_state.focused_session].isVisible()) {
                                for (sessions, 0..) |s, idx| {
                                    if (s.isVisible()) {
                                        self.anim_state.focused_session = idx;
                                        break;
                                    }
                                }
                            }
                            self.anim_state.mode = .Full;
                            self.applyTerminalLayout();
                        } else {
                            const new_dims = GridLayout.calculateDimensions(required_slots);
                            const should_shrink = new_dims.cols < self.grid.cols or new_dims.rows < self.grid.rows;

                            if (should_shrink) {
                                const can_animate_reflow = app.animations_enabled and self.anim_state.mode == .Grid;
                                const grid_will_resize = new_dims.cols != self.grid.cols or new_dims.rows != self.grid.rows;
                                if (can_animate_reflow) {
                                    if (old_positions) |snapshots| {
                                        var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                            std.debug.print("Failed to collect session moves: {}\n", .{err});
                                            break :blk null;
                                        };
                                        if (move_result) |*moves| {
                                            defer moves.list.deinit(allocator);
                                            if (grid_will_resize or moves.moved) {
                                                self.grid.startResize(new_dims.cols, new_dims.rows, now, self.render_width, self.render_height, moves.list.items) catch |err| {
                                                    std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                                                };
                                                self.anim_state.mode = .GridResizing;
                                            } else {
                                                self.grid.cols = new_dims.cols;
                                                self.grid.rows = new_dims.rows;
                                            }
                                        } else {
                                            self.grid.cols = new_dims.cols;
                                            self.grid.rows = new_dims.rows;
                                        }
                                    } else {
                                        self.grid.cols = new_dims.cols;
                                        self.grid.rows = new_dims.rows;
                                    }
                                } else {
                                    self.grid.cols = new_dims.cols;
                                    self.grid.rows = new_dims.rows;
                                }

                                self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
                                self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));
                                self.applyTerminalLayout();

                                // Update focus to a valid session
                                if (!sessions[self.anim_state.focused_session].isVisible()) {
                                    var new_focus: usize = 0;
                                    for (sessions, 0..) |s, idx| {
                                        if (s.isVisible()) {
                                            new_focus = idx;
                                            break;
                                        }
                                    }
                                    self.anim_state.focused_session = new_focus;
                                }

                                std.debug.print("Grid shrunk to {d}x{d} with {d} terminals\n", .{ self.grid.cols, self.grid.rows, remaining_count });
                            } else {
                                const can_animate_reflow = app.animations_enabled and self.anim_state.mode == .Grid;
                                if (can_animate_reflow) {
                                    if (old_positions) |snapshots| {
                                        var move_result: ?SessionMoves = collectSessionMovesFromSnapshots(sessions, snapshots.items, allocator) catch |err| blk: {
                                            std.debug.print("Failed to collect session moves: {}\n", .{err});
                                            break :blk null;
                                        };
                                        if (move_result) |*moves| {
                                            defer moves.list.deinit(allocator);
                                            if (moves.moved) {
                                                self.grid.startResize(self.grid.cols, self.grid.rows, now, self.render_width, self.render_height, moves.list.items) catch |err| {
                                                    std.debug.print("Failed to start grid reflow animation: {}\n", .{err});
                                                };
                                                self.anim_state.mode = .GridResizing;
                                            }
                                        }
                                    }
                                }
                                // Grid doesn't need to shrink, just update focus if needed
                                if (!sessions[self.anim_state.focused_session].isVisible()) {
                                    // Find the next spawned session
                                    var new_focus: usize = 0;
                                    for (sessions, 0..) |s, idx| {
                                        if (s.isVisible()) {
                                            new_focus = idx;
                                            break;
                                        }
                                    }
                                    self.anim_state.focused_session = new_focus;
                                }
                            }
                        }
                    }
                    return;
                }

                // Cmd+J hides the focused terminal (keeps it alive, drops it from
                // the grid); Cmd+Shift+J opens the reveal picker — but the switcher
                // consumes ⌘⇧J before this whenever anything is hidden, so here it
                // only means "nothing to reveal". (Cmd+H is reserved by macOS.)
                if (has_gui and !has_blocking_mod and key == c.SDLK_J) {
                    if ((mod & c.SDL_KMOD_SHIFT) == 0) {
                        if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘J", now);
                        const idx = self.anim_state.focused_session;
                        if (idx < sessions.len and sessions[idx].isVisible()) {
                            if (countVisibleSessions(sessions) <= 1) {
                                self.ui.showToast("Can't hide the last terminal", now);
                            } else {
                                self.despawnSessionAtIndex(idx, true, now);
                                self.ui.showToast("Hidden — ⌘⇧J to reveal", now);
                            }
                        }
                    } else {
                        if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⇧J", now);
                        self.ui.showToast("No hidden terminals", now);
                    }
                    return;
                }

                if (key == c.SDLK_K and has_gui and !has_blocking_mod) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘K", now);
                    terminal_actions.clearTerminal(focused);
                    self.ui.showToast("Cleared terminal", now);
                } else if (key == c.SDLK_C and has_gui and !has_blocking_mod) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘C", now);
                    terminal_actions.copySelectionToClipboard(focused, allocator, &self.ui, now) catch |err| {
                        std.debug.print("Copy failed: {}\n", .{err});
                    };
                } else if (key == c.SDLK_V and has_gui and !has_blocking_mod) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘V", now);
                    // Opt-in: if the clipboard holds an image, forward Ctrl+V so a
                    // CLI in the terminal inlines it; otherwise paste text as usual.
                    var handled_paste = false;
                    if (app.config.paste.image_passthrough) {
                        handled_paste = terminal_actions.tryPasteImagePassthrough(focused, allocator, &self.ui, now, self.session_interaction_component) catch |err| blk: {
                            std.debug.print("Image paste passthrough failed: {}\n", .{err});
                            break :blk false;
                        };
                    }
                    if (!handled_paste) {
                        terminal_actions.pasteClipboardIntoSession(focused, allocator, &self.ui, now, self.session_interaction_component) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    }
                } else if (input.fontSizeShortcut(key, mod)) |direction| {
                    // Zoom is context-aware: in grid view it changes the GRID
                    // font size; in focus view it changes the FOCUS font size.
                    // The two are persisted independently and don't bleed into
                    // each other.
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey(if (direction == .increase) "⌘+" else "⌘-", now);
                    if (self.anim_state.mode == .Grid or self.anim_state.mode == .GridResizing) {
                        const grid_scale_step: f32 = 0.1;
                        const delta: f32 = if (direction == .increase) grid_scale_step else -grid_scale_step;
                        const target_scale = std.math.clamp(self.grid_font_scale + delta, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
                        if (target_scale != self.grid_font_scale) {
                            self.grid_font_scale = target_scale;
                            self.applyTerminalLayout();
                            app.persistence.grid_font_scale = self.grid_font_scale;
                            app.persistence.setGridFontPreset(allocator, self.grid.cols, self.grid.rows, self.grid_font_scale) catch |err| {
                                log.warn("failed to save grid font preset: {}", .{err});
                            };
                            app.persistence_dirty = true;
                            savePersistenceIfDirty(&app.persistence, allocator, &app.persistence_dirty);
                        }
                        var grid_scale_buf: [64]u8 = undefined;
                        const grid_scale_msg = std.fmt.bufPrint(&grid_scale_buf, "Grid font: {d:.0}%", .{self.grid_font_scale * 100.0}) catch |err| blk: {
                            log.warn("failed to format grid scale toast: {}", .{err});
                            break :blk "Grid font changed";
                        };
                        self.ui.showToast(grid_scale_msg, now);
                    } else {
                        const delta: c_int = if (direction == .increase) font_step else -font_step;
                        const target_size = std.math.clamp(self.font_size + delta, min_font_size, max_font_size);
                        if (target_size != self.font_size) {
                            const new_font = try initSharedFont(allocator, self.pw.renderer, &app.shared_font_cache, layout.scaledFontSize(target_size, self.ui_scale));
                            self.font.deinit();
                            self.font = new_font;
                            self.font.metrics = app.metrics_ptr;
                            // Grid text size scales with the focus font size, so
                            // compensate the grid scale to hold the grid steady.
                            const comp = @as(f32, @floatFromInt(self.font_size)) / @as(f32, @floatFromInt(target_size));
                            self.grid_font_scale = std.math.clamp(self.grid_font_scale * comp, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
                            self.font_size = target_size;

                            self.applyTerminalLayout();
                            std.debug.print("Font size -> {d}px, terminal size: {d}x{d}\n", .{ self.font_size, self.full_cols, self.full_rows });

                            app.persistence.font_size = self.font_size;
                            app.persistence.grid_font_scale = self.grid_font_scale;
                            app.persistence_dirty = true;
                            savePersistenceIfDirty(&app.persistence, allocator, &app.persistence_dirty);
                        }
                        var notification_buf: [64]u8 = undefined;
                        const notification_msg = std.fmt.bufPrint(&notification_buf, "Font size: {d}pt", .{self.font_size}) catch |err| blk: {
                            log.warn("failed to format font size toast: {}", .{err});
                            break :blk "Font size changed";
                        };
                        self.ui.showToast(notification_msg, now);
                    }
                } else if (key == c.SDLK_N and has_gui and !has_blocking_mod and !has_shift and (self.anim_state.mode == .Full or self.anim_state.mode == .Grid)) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘N", now);

                    // Grid sizing is driven by VISIBLE sessions; hidden ones are
                    // parked off-grid by compactSessions and must not reserve a cell.
                    const visible_count = countVisibleSessions(sessions);

                    // Check if we need to expand the grid
                    if (self.grid.needsExpansion(visible_count)) {
                        // Calculate new grid dimensions
                        const new_dims = GridLayout.calculateDimensions(visible_count + 1);
                        if (new_dims.cols * new_dims.rows > grid_layout.max_terminals) {
                            self.ui.showToast("Maximum terminals reached", now);
                            return;
                        }

                        // Get working directory from focused session
                        var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                        defer working_dir.deinit(allocator);

                        const new_capacity = new_dims.cols * new_dims.rows;
                        const new_idx = findNextFreeSlotAfter(sessions, new_capacity, self.anim_state.focused_session) orelse {
                            self.ui.showToast("All terminals in use", now);
                            return;
                        };

                        // Collect active sessions for animation
                        var moves = collectSessionMovesCurrent(sessions, allocator) catch |err| {
                            std.debug.print("Failed to collect session moves: {}\n", .{err});
                            return;
                        };
                        defer moves.deinit(allocator);

                        // Update grid dimensions and start animation
                        if (app.animations_enabled) {
                            self.grid.startResize(new_dims.cols, new_dims.rows, now, self.render_width, self.render_height, moves.items) catch |err| {
                                std.debug.print("Failed to start grid resize animation: {}\n", .{err});
                            };
                            self.anim_state.mode = .GridResizing;
                        } else {
                            self.grid.cols = new_dims.cols;
                            self.grid.rows = new_dims.rows;
                        }

                        // Spawn new terminal
                        try sessions[new_idx].ensureSpawnedFresh(working_dir.cwd_z, &app.loop);
                        self.session_interaction_component.setAttention(new_idx, false, now);

                        // Update cell dimensions for new grid
                        self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
                        self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));
                        self.applyTerminalLayout();

                        self.session_interaction_component.clearSelection(self.anim_state.focused_session);
                        self.session_interaction_component.clearSelection(new_idx);

                        self.anim_state.previous_session = self.anim_state.focused_session;
                        self.anim_state.focused_session = new_idx;

                        const buf_size = grid_nav.gridNotificationBufferSize(self.grid.cols, self.grid.rows);
                        const notification_buf = try allocator.alloc(u8, buf_size);
                        defer allocator.free(notification_buf);
                        const notification_msg = try grid_nav.formatGridNotification(notification_buf, new_idx, self.grid.cols, self.grid.rows);
                        self.ui.showToast(notification_msg, now);
                        std.debug.print("Grid expanded to {d}x{d}, new terminal at index {d}\n", .{ self.grid.cols, self.grid.rows, new_idx });
                    } else {
                        // Grid has space, find next free slot
                        const target_idx: ?usize = if (!focused.spawned)
                            self.anim_state.focused_session
                        else
                            findNextFreeSlotAfter(sessions, self.grid.capacity(), self.anim_state.focused_session);

                        if (target_idx) |next_free_idx| {
                            var working_dir = WorkingDir.init(allocator, focused.cwd_path);
                            defer working_dir.deinit(allocator);

                            try sessions[next_free_idx].ensureSpawnedFresh(working_dir.cwd_z, &app.loop);
                            self.session_interaction_component.setAttention(next_free_idx, false, now);

                            self.session_interaction_component.clearSelection(self.anim_state.focused_session);
                            self.session_interaction_component.clearSelection(next_free_idx);

                            self.anim_state.previous_session = self.anim_state.focused_session;
                            self.anim_state.focused_session = next_free_idx;

                            const buf_size = grid_nav.gridNotificationBufferSize(self.grid.cols, self.grid.rows);
                            const notification_buf = try allocator.alloc(u8, buf_size);
                            defer allocator.free(notification_buf);
                            const notification_msg = try grid_nav.formatGridNotification(notification_buf, next_free_idx, self.grid.cols, self.grid.rows);
                            self.ui.showToast(notification_msg, now);
                        } else {
                            self.ui.showToast("All terminals in use", now);
                        }
                    }
                } else if (terminal_shortcut) |idx| {
                    const hotkey_label = input.terminalHotkeyLabel(idx) orelse "⌘?";
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey(hotkey_label, now);

                    if (self.anim_state.mode == .Grid) {
                        try sessions[idx].ensureSpawnedWithLoop(&app.loop);
                        self.session_interaction_component.acknowledgeAttention(idx);
                        self.session_interaction_component.setAttention(idx, false, now);

                        const grid_row: c_int = @intCast(idx / self.grid.cols);
                        const grid_col: c_int = @intCast(idx % self.grid.cols);
                        const start_rect = Rect{
                            .x = grid_col * self.cell_width_pixels,
                            .y = grid_row * self.cell_height_pixels,
                            .w = self.cell_width_pixels,
                            .h = self.cell_height_pixels,
                        };
                        const target_rect = Rect{ .x = 0, .y = 0, .w = self.render_width, .h = self.render_height };

                        self.anim_state.focused_session = idx;
                        if (app.animations_enabled) {
                            self.anim_state.mode = .Expanding;
                            self.anim_state.start_time = now;
                            self.anim_state.start_rect = start_rect;
                            self.anim_state.target_rect = target_rect;
                        } else {
                            self.anim_state.mode = .Full;
                            self.anim_state.start_time = now;
                            self.anim_state.start_rect = target_rect;
                            self.anim_state.target_rect = target_rect;
                            self.anim_state.previous_session = idx;
                        }
                        std.debug.print("Expanding session via hotkey: {d}\n", .{idx});
                    } else if (self.anim_state.mode == .Full and idx != self.anim_state.focused_session) {
                        try sessions[idx].ensureSpawnedWithLoop(&app.loop);
                        self.session_interaction_component.clearSelection(self.anim_state.focused_session);
                        self.session_interaction_component.clearSelection(idx);
                        self.session_interaction_component.acknowledgeAttention(idx);
                        self.session_interaction_component.setAttention(idx, false, now);
                        self.anim_state.focused_session = idx;

                        const buf_size = grid_nav.gridNotificationBufferSize(self.grid.cols, self.grid.rows);
                        const notification_buf = try allocator.alloc(u8, buf_size);
                        defer allocator.free(notification_buf);
                        const notification_msg = try grid_nav.formatGridNotification(notification_buf, idx, self.grid.cols, self.grid.rows);
                        self.ui.showToast(notification_msg, now);
                        std.debug.print("Switched to session via hotkey: {d}\n", .{idx});
                    }
                } else if (input.gridNavShortcut(key, mod)) |direction| {
                    if (self.anim_state.mode == .Grid) {
                        if (app.config.ui.show_hotkey_feedback) {
                            const arrow = switch (direction) {
                                .up => "⇧↑",
                                .down => "⇧↓",
                                .left => "⇧←",
                                .right => "⇧→",
                            };
                            self.ui.showHotkey(arrow, now);
                        }
                        try grid_nav.navigateGrid(&self.anim_state, sessions, self.session_interaction_component, direction, now, true, false, self.grid.cols, self.grid.rows, &app.loop);
                        const new_session = self.anim_state.focused_session;
                        self.session_interaction_component.acknowledgeAttention(new_session);
                        self.session_interaction_component.triggerNavWave(new_session, now);
                        std.debug.print("Grid nav to session {d} (with wrapping)\n", .{new_session});
                    } else if (self.anim_state.mode == .Full) {
                        if (app.config.ui.show_hotkey_feedback) {
                            const arrow = switch (direction) {
                                .up => "⇧↑",
                                .down => "⇧↓",
                                .left => "⇧←",
                                .right => "⇧→",
                            };
                            self.ui.showHotkey(arrow, now);
                        }
                        try grid_nav.navigateGrid(&self.anim_state, sessions, self.session_interaction_component, direction, now, true, app.animations_enabled, self.grid.cols, self.grid.rows, &app.loop);
                        self.session_interaction_component.acknowledgeAttention(self.anim_state.focused_session);

                        const buf_size = grid_nav.gridNotificationBufferSize(self.grid.cols, self.grid.rows);
                        const notification_buf = try allocator.alloc(u8, buf_size);
                        defer allocator.free(notification_buf);
                        const notification_msg = try grid_nav.formatGridNotification(notification_buf, self.anim_state.focused_session, self.grid.cols, self.grid.rows);
                        self.ui.showToast(notification_msg, now);

                        std.debug.print("Full mode grid nav to session {d}\n", .{self.anim_state.focused_session});
                    } else {
                        if (focused.spawned and !focused.dead) {
                            self.session_interaction_component.resetScrollIfNeeded(self.anim_state.focused_session);
                            try input_keys.handleKeyInput(focused, key, mod);
                        }
                    }
                } else if (input.jumpToBottomShortcut(key, mod)) {
                    // Cmd+Shift+Down → send Ctrl+End so the focused TUI (e.g.
                    // Claude Code) jumps to the bottom of its scroll. Stands in
                    // for the physical Ctrl+End, which macOS window managers
                    // grab as Ctrl+Fn+→. Focused live pane only.
                    if (focused.spawned and !focused.dead) {
                        if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⇧↓", now);
                        self.session_interaction_component.resetScrollIfNeeded(self.anim_state.focused_session);
                        focused.sendInput(input.ctrl_end_sequence) catch |err| {
                            log.warn("jump-to-bottom send failed: {}", .{err});
                        };
                    }
                } else if (key == c.SDLK_RETURN and (mod & c.SDL_KMOD_GUI) != 0 and self.anim_state.mode == .Grid) {
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘↵", now);
                    if (countSpawnedSessions(sessions) == 1) {
                        return;
                    }
                    const clicked_session = self.anim_state.focused_session;
                    try sessions[clicked_session].ensureSpawnedWithLoop(&app.loop);

                    self.session_interaction_component.acknowledgeAttention(clicked_session);
                    self.session_interaction_component.setAttention(clicked_session, false, now);

                    const grid_row: c_int = @intCast(clicked_session / self.grid.cols);
                    const grid_col: c_int = @intCast(clicked_session % self.grid.cols);
                    const start_rect = Rect{
                        .x = grid_col * self.cell_width_pixels,
                        .y = grid_row * self.cell_height_pixels,
                        .w = self.cell_width_pixels,
                        .h = self.cell_height_pixels,
                    };
                    const target_rect = Rect{ .x = 0, .y = 0, .w = self.render_width, .h = self.render_height };

                    self.anim_state.focused_session = clicked_session;
                    if (app.animations_enabled) {
                        self.anim_state.mode = .Expanding;
                        self.anim_state.start_time = now;
                        self.anim_state.start_rect = start_rect;
                        self.anim_state.target_rect = target_rect;
                    } else {
                        self.anim_state.mode = .Full;
                        self.anim_state.start_time = now;
                        self.anim_state.start_rect = target_rect;
                        self.anim_state.target_rect = target_rect;
                        self.anim_state.previous_session = clicked_session;
                    }
                    std.debug.print("Expanding session: {d}\n", .{clicked_session});
                } else if (focused.spawned and !focused.dead and !input_keys.isModifierKey(key)) {
                    self.session_interaction_component.resetScrollIfNeeded(self.anim_state.focused_session);
                    if (self.anim_state.mode == .Grid) {
                        self.session_interaction_component.setAttention(self.anim_state.focused_session, false, now);
                    }
                    try input_keys.handleKeyInput(focused, key, mod);
                }
            },
            c.SDL_EVENT_KEY_UP => {
                const key = scaled_event.key.key;
                if (key == c.SDLK_ESCAPE and input.canHandleEscapePress(self.anim_state.mode)) {
                    const focused = sessions[self.anim_state.focused_session];
                    if (focused.spawned and !focused.dead and focused.shell != null) {
                        const esc_byte: [1]u8 = .{27};
                        _ = focused.shell.?.write(&esc_byte) catch |err| {
                            log.warn("session {d}: failed to send escape key: {}", .{ self.anim_state.focused_session, err });
                        };
                    }
                }
            },
            else => {},
        }
    }

    /// Feed PTY output into terminals, flush pending writes, track cwd changes.
    /// Write this window's position/size into its persistence entry.
    fn persistGeometry(self: *Window) void {
        const app = self.app;
        const idx = app.windowIndex(self);
        if (idx >= app.persistence.windows.items.len) return;
        const entry = &app.persistence.windows.items[idx];
        entry.window.x = self.window_x;
        entry.window.y = self.window_y;
        entry.window.width = self.window_width_points;
        entry.window.height = self.window_height_points;
        app.persistence_dirty = true;
    }

    fn pumpSessions(self: *Window, now: i64) void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        for (sessions) |session| {
            if (self.relaunch_trace_frames > 0 and session.spawned) {
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
                    app.persistence.appendRecentFolder(allocator, new_cwd) catch |err| {
                        log.warn("failed to update recent folders: {}", .{err});
                    };
                    app.refreshRecentFolders();
                    app.persistence_dirty = true;
                }
            }
            if (self.relaunch_trace_frames > 0 and session.spawned) {
                log.info("frame trace after process session idx={d} id={d}", .{ session.slot_index, session.id });
            }
        }
    }

    /// Apply one external notification to this window. Returns true when a
    /// fresh agent session id was captured (caller re-syncs persistence).
    fn applyNotification(self: *Window, note: notify.Notification, now: i64) bool {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        var captured_agent_session_id = false;
        switch (note) {
            .status => |s| {
                const session_idx = findSessionIndexById(sessions, s.session) orelse return false;
                self.session_interaction_component.setStatus(session_idx, s.state);
                const wants_attention = switch (s.state) {
                    .awaiting_approval, .done => true,
                    else => false,
                };
                // Chime when an agent needs you or finishes, but only while
                // Cadre is backgrounded (foreground already shows the border).
                if (wants_attention and app.config.notifications.sound and !app.anyWindowFocused()) {
                    notify_sound.play(allocator, s.state);
                }
                const is_focused_full = self.anim_state.mode == .Full and self.anim_state.focused_session == session_idx;
                self.session_interaction_component.setAttention(session_idx, if (is_focused_full) false else wants_attention, now);
                std.debug.print("Session {d} (slot {d}) status -> {s}\n", .{ s.session, session_idx, @tagName(s.state) });
            },
            .story => |s| {
                if (!self.story_overlay_component.show(s.path, now)) {
                    self.ui.showToast("Failed to open story file", now);
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
                const session_idx = findSessionIndexById(sessions, s.session) orelse return false;
                const agent_kind = session_state.AgentKind.fromComm(s.agent) orelse return false;
                const session = sessions[session_idx];
                // Skip if nothing changed, to avoid needless persistence churn.
                const unchanged = session.agent_metadata_captured and
                    session.agent_kind == agent_kind and
                    session.agent_session_id != null and
                    std.mem.eql(u8, session.agent_session_id.?, s.session_id);
                if (unchanged) return false;
                const id_dupe = allocator.dupe(u8, s.session_id) catch |err| {
                    log.warn("failed to store agent session id for slot {d}: {}", .{ session_idx, err });
                    return false;
                };
                if (session.agent_session_id) |old| allocator.free(old);
                session.agent_kind = agent_kind;
                session.agent_session_id = id_dupe;
                session.agent_metadata_captured = true;
                app.persistence_dirty = true;
                captured_agent_session_id = true;
                log.info("captured agent session: slot {d} {s} {s}", .{ session_idx, s.agent, s.session_id });
            },
        }
        return captured_agent_session_id;
    }

    /// Per-frame state advance: pending sends, hosting poll, UI update + action
    /// drain, animation completion, grid font preset, terminal layout.
    fn update(self: *Window, now: i64) !void {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        if (self.pending_comment_send) |pcs| {
            const prompt_ready = pcs.session < sessions.len and
                sessions[pcs.session].hasForegroundProcess();
            if (now >= pcs.send_after_ms or prompt_ready) {
                if (pcs.session < sessions.len) {
                    sessions[pcs.session].sendInput(pcs.text) catch |err| {
                        log.warn("failed to send pending diff comments: {}", .{err});
                    };
                }
                allocator.free(pcs.text);
                self.pending_comment_send = null;
            }
        }

        if (self.hidden_switcher_comp_ptr.open) {
            if (self.hosting_last_poll_ms == null or now - self.hosting_last_poll_ms.? >= hosting_poll_interval_ms) {
                self.hosting_last_poll_ms = now;
                // ponytail: synchronous subprocess poll (~tens of ms) while a
                // static modal is up; move to a worker thread if it hitches.
                hosting_mod.detectHosting(allocator, sessions, self.hosting_flags);
                for (self.hosting_flags, 0..) |flag, i| {
                    self.session_interaction_component.setHosting(i, flag);
                }
            }
        } else {
            self.hosting_last_poll_ms = null; // re-poll immediately on next open
        }

        const focused_has_foreground_process = self.foreground_cache.get(now, self.anim_state.focused_session, sessions);
        const ui_update_host = ui_host.makeUiHost(
            now,
            self.render_width,
            self.render_height,
            self.ui_scale,
            self.cell_width_pixels,
            self.cell_height_pixels,
            self.grid_font.cell_width,
            self.grid_font.cell_height,
            self.grid_font_size,
            self.grid.cols,
            self.grid.rows,
            self.full_cols,
            self.full_rows,
            &self.anim_state,
            sessions,
            self.session_ui_info,
            self.session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &app.theme,
        );
        self.ui.update(&ui_update_host);

        ui_action_loop: while (self.ui.popAction()) |action| switch (action) {
            .RestartSession => |idx| {
                if (idx < sessions.len) {
                    try sessions[idx].restart();
                    self.session_interaction_component.resetView(idx);
                    std.debug.print("UI requested restart: {d}\n", .{idx});
                }
            },
            .FocusSession => |idx| {
                if (self.anim_state.mode != .Grid) continue;
                if (idx >= sessions.len) continue;

                self.session_interaction_component.clearSelection(self.anim_state.focused_session);
                try sessions[idx].ensureSpawnedWithLoop(&app.loop);
                self.session_interaction_component.acknowledgeAttention(idx);
                self.session_interaction_component.setAttention(idx, false, now);

                const grid_row: c_int = @intCast(idx / self.grid.cols);
                const grid_col: c_int = @intCast(idx % self.grid.cols);
                const cell_rect = Rect{
                    .x = grid_col * self.cell_width_pixels,
                    .y = grid_row * self.cell_height_pixels,
                    .w = self.cell_width_pixels,
                    .h = self.cell_height_pixels,
                };
                const target_rect = Rect{ .x = 0, .y = 0, .w = self.render_width, .h = self.render_height };

                self.anim_state.focused_session = idx;
                if (app.animations_enabled) {
                    self.anim_state.mode = .Expanding;
                    self.anim_state.start_time = now;
                    self.anim_state.start_rect = cell_rect;
                    self.anim_state.target_rect = target_rect;
                } else {
                    self.anim_state.mode = .Full;
                    self.anim_state.start_time = now;
                    self.anim_state.start_rect = target_rect;
                    self.anim_state.target_rect = target_rect;
                    self.anim_state.previous_session = idx;
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
                if (self.anim_state.mode != .Grid) continue;
                if (idx >= sessions.len) continue;
                if (idx == self.anim_state.focused_session) continue;

                // Clear the pane we're leaving, but NOT the one we're moving to:
                // the same mouse-down that queued this action already ran
                // `beginSelection` on `idx`, which cleared that pane's screen
                // selection and armed a drag (selection_pending/anchor). Clearing
                // `idx` here would reset those flags before the following motion
                // events could build the selection, so a drag-select on a
                // non-focused grid pane produced nothing to copy.
                self.session_interaction_component.clearSelection(self.anim_state.focused_session);
                // Selecting is a focus: acknowledge a sticky "done"/"needs you"
                // back to idle AND drop the attention border, same as every
                // keyboard/zoom focus path (status alone leaves an orange
                // fallback border while `attention` is still set).
                self.session_interaction_component.acknowledgeAttention(idx);
                self.session_interaction_component.setAttention(idx, false, now);
                self.anim_state.focused_session = idx;
            },
            .ReorderGridSessions => |move| self.reorderVisible(move.from, move.to, now),
            .CloseHiddenTerminal => |idx| {
                if (idx >= sessions.len) continue;
                if (!(sessions[idx].spawned and sessions[idx].hidden)) continue;
                if (sessions[idx].hasForegroundProcessThorough()) {
                    self.confirm_dialog_component.show(
                        "Delete Terminal?",
                        "A process is running. Delete anyway?",
                        "Delete",
                        "Cancel",
                        .{ .DespawnSession = idx },
                    );
                } else {
                    self.despawnSessionAtIndex(idx, false, now);
                    self.ui.showToast("Closed terminal", now);
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
                compactSessions(sessions, self.session_interaction_component.viewSlice(), &self.render_cache, &self.anim_state);
                const new_dims = GridLayout.calculateDimensions(countVisibleSessions(sessions));
                self.grid.cols = new_dims.cols;
                self.grid.rows = new_dims.rows;
                self.cell_width_pixels = @divFloor(self.render_width, @as(c_int, @intCast(self.grid.cols)));
                self.cell_height_pixels = @divFloor(self.render_height, @as(c_int, @intCast(self.grid.rows)));
                self.anim_state.mode = .Grid;
                if (findSessionIndexById(sessions, reveal_id)) |new_idx| {
                    self.anim_state.focused_session = new_idx;
                    // Revealing is a focus: acknowledge a sticky "done"/"needs you" back to idle.
                    self.session_interaction_component.acknowledgeAttention(new_idx);
                }
                self.applyTerminalLayout();
                self.ui.showToast("Revealed terminal", now);
            },
            .DespawnSession => |idx| {
                self.despawnSessionAtIndex(idx, false, now);
            },
            .RequestCollapseFocused => {
                if (self.anim_state.mode == .Full) {
                    const spawned_count = countSpawnedSessions(sessions);
                    if (spawned_count == 1) {
                        std.debug.print("UI requested collapse ignored (single terminal)\n", .{});
                    } else if (app.animations_enabled) {
                        grid_nav.startCollapseToGrid(&self.anim_state, now, self.cell_width_pixels, self.cell_height_pixels, self.render_width, self.render_height, self.grid.cols);
                    } else {
                        const grid_row: c_int = @intCast(self.anim_state.focused_session / self.grid.cols);
                        const grid_col: c_int = @intCast(self.anim_state.focused_session % self.grid.cols);
                        self.anim_state.mode = .Grid;
                        self.anim_state.start_time = now;
                        self.anim_state.start_rect = Rect{ .x = 0, .y = 0, .w = self.render_width, .h = self.render_height };
                        self.anim_state.target_rect = Rect{
                            .x = grid_col * self.cell_width_pixels,
                            .y = grid_row * self.cell_height_pixels,
                            .w = self.cell_width_pixels,
                            .h = self.cell_height_pixels,
                        };
                    }
                    std.debug.print("UI requested collapse of focused session: {d}\n", .{self.anim_state.focused_session});
                }
            },
            .PasteIntoFocused => {
                // Same paste path as Cmd+V: try image passthrough first (opt-in),
                // then fall back to text.
                if (self.anim_state.focused_session < sessions.len) {
                    const focused = sessions[self.anim_state.focused_session];
                    var handled_paste = false;
                    if (app.config.paste.image_passthrough) {
                        handled_paste = terminal_actions.tryPasteImagePassthrough(focused, allocator, &self.ui, now, self.session_interaction_component) catch |err| blk: {
                            std.debug.print("Image paste passthrough failed: {}\n", .{err});
                            break :blk false;
                        };
                    }
                    if (!handled_paste) {
                        terminal_actions.pasteClipboardIntoSession(focused, allocator, &self.ui, now, self.session_interaction_component) catch |err| {
                            std.debug.print("Paste failed: {}\n", .{err});
                        };
                    }
                }
            },
            .ConfirmQuit => {
                if (!app.quit_teardown.active) {
                    if (self.startQuitFlow()) {
                        app.running = false;
                    }
                }
            },
            .CloseWindow => {
                if (!app.quit_teardown.active) app.closing_window = self;
            },
            .MoveSessionToNewWindow => |idx| {
                app.requestMoveToNewWindow(self, idx);
            },
            .MoveSessionToWindow => |mv| {
                if (mv.window_index >= app.windows.items.len) continue;
                const dst = app.windows.items[mv.window_index];
                if (dst == self or app.pending_move != null) continue;
                app.pending_move = .{ .src = self, .idx = mv.idx, .dst = dst };
            },
            .DragSessionOut => |d| {
                if (app.pending_drag_out != null) continue;
                app.pending_drag_out = .{ .src = self, .idx = d.idx, .origin = d.origin, .screen_x = d.screen_x, .screen_y = d.screen_y };
            },
            .OpenConfig => {
                if (config_mod.Config.getConfigPath(allocator)) |config_path| {
                    defer allocator.free(config_path);
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘,", now);

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
                    self.ui.showToast("Opening config file", now);
                } else |err| {
                    std.debug.print("Failed to get config path: {}\n", .{err});
                }
            },
            .SwitchWorktree => |switch_action| {
                defer allocator.free(switch_action.path);
                if (switch_action.session >= sessions.len) continue;

                var session = sessions[switch_action.session];
                if (session.hasForegroundProcessThorough()) {
                    self.ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    self.ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, switch_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ switch_action.session, err });
                    self.ui.showToast("Could not switch worktree", now);
                    continue;
                };

                self.session_interaction_component.setAttention(switch_action.session, false, now);
                self.ui.showToast("Switched worktree", now);
            },
            .CreateWorktree => |create_action| {
                defer allocator.free(create_action.base_path);
                defer allocator.free(create_action.name);
                if (create_action.session >= sessions.len) continue;
                var session = sessions[create_action.session];

                if (session.hasForegroundProcessThorough()) {
                    self.ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    self.ui.showToast("Start the shell first", now);
                    continue;
                }

                const target_path = worktree.resolveWorktreeDir(
                    allocator,
                    create_action.base_path,
                    create_action.name,
                    app.config.worktree.directory,
                ) catch |err| {
                    std.debug.print("Failed to resolve worktree directory: {}\n", .{err});
                    self.ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(target_path);

                const command = worktree.buildCreateWorktreeCommand(
                    allocator,
                    create_action.base_path,
                    target_path,
                    create_action.name,
                    app.config.worktree.init_command,
                ) catch |err| {
                    std.debug.print("Failed to build worktree command: {}\n", .{err});
                    self.ui.showToast("Could not create worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send worktree command: {}\n", .{err});
                    self.ui.showToast("Could not create worktree", now);
                    continue;
                };

                session.recordCwd(target_path) catch |err| {
                    log.warn("session {d}: failed to record cwd: {}", .{ create_action.session, err });
                };

                self.session_interaction_component.setAttention(create_action.session, false, now);
                self.ui.showToast("Creating worktree…", now);
            },
            .RemoveWorktree => |remove_action| {
                defer allocator.free(remove_action.path);
                if (remove_action.session >= sessions.len) continue;
                var session = sessions[remove_action.session];

                if (session.hasForegroundProcessThorough()) {
                    self.ui.showToast("Stop the running process first", now);
                    continue;
                }
                if (!session.spawned or session.dead) {
                    self.ui.showToast("Start the shell first", now);
                    continue;
                }

                for (app.windows.items) |other_window| {
                    for (other_window.sessions) |other_session| {
                        if (other_session == session) continue;
                        if (!other_session.spawned or other_session.dead) continue;

                        const other_cwd = other_session.cwd_path orelse continue;
                        if (std.mem.eql(u8, other_cwd, remove_action.path)) {
                            self.ui.showToast("Worktree in use by another session", now);
                            continue :ui_action_loop;
                        }
                        if (std.mem.startsWith(u8, other_cwd, remove_action.path)) {
                            const suffix = other_cwd[remove_action.path.len..];
                            if (suffix.len > 0 and suffix[0] == '/') {
                                self.ui.showToast("Worktree in use by another session", now);
                                continue :ui_action_loop;
                            }
                        }
                    }
                }

                const command = worktree.buildRemoveWorktreeCommand(allocator, remove_action.path) catch |err| {
                    std.debug.print("Failed to build remove worktree command: {}\n", .{err});
                    self.ui.showToast("Could not remove worktree", now);
                    continue;
                };
                defer allocator.free(command);

                session.sendInput(command) catch |err| {
                    std.debug.print("Failed to send remove worktree command: {}\n", .{err});
                    self.ui.showToast("Could not remove worktree", now);
                    continue;
                };

                self.session_interaction_component.setAttention(remove_action.session, false, now);
                self.ui.showToast("Removing worktree…", now);
            },
            .ChangeDirectory => |cd_action| {
                defer allocator.free(cd_action.path);
                if (cd_action.session >= sessions.len) continue;

                var session = sessions[cd_action.session];
                if (session.hasForegroundProcessThorough()) {
                    self.ui.showToast("Stop the running process first", now);
                    continue;
                }

                if (!session.spawned or session.dead) {
                    self.ui.showToast("Start the shell first", now);
                    continue;
                }

                worktree.changeSessionDirectory(session, allocator, cd_action.path) catch |err| {
                    std.debug.print("Failed to change directory for session {d}: {}\n", .{ cd_action.session, err });
                    self.ui.showToast("Could not change directory", now);
                    continue;
                };

                // Note: appendRecentFolder is handled by the per-frame updateCwd loop
                // to avoid double-counting when cwd changes are detected

                self.session_interaction_component.setAttention(cd_action.session, false, now);

                const basename = std.fs.path.basename(cd_action.path);
                const toast_msg_buf: ?[]u8 = std.fmt.allocPrint(allocator, "Changed to {s}", .{basename}) catch |err| blk: {
                    log.warn("failed to allocate cd toast: {}", .{err});
                    break :blk null;
                };
                const toast_msg = toast_msg_buf orelse "Changed directory";
                defer if (toast_msg_buf) |buf| allocator.free(buf);
                self.ui.showToast(toast_msg, now);
            },
            .ToggleMetrics => {
                if (app.config.metrics.enabled) {
                    self.metrics_overlay_component.toggle();
                    if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘⇧M", now);
                } else {
                    self.ui.showToast("Metrics disabled in config", now);
                }
            },
            .ToggleDiffOverlay => {
                const focused_cwd = if (self.anim_state.focused_session < sessions.len)
                    sessions[self.anim_state.focused_session].cwd_path
                else
                    null;
                switch (self.diff_overlay_component.toggle(focused_cwd, now)) {
                    .not_a_repo => self.ui.showToast("Not a git repository", now),
                    .clean => self.ui.showToast("Working tree clean", now),
                    .opened => if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘D", now),
                }
            },
            .ToggleReaderOverlay => {
                const focused_has_foreground = self.foreground_cache.get(now, self.anim_state.focused_session, sessions);
                const host_snapshot = ui_host.makeUiHost(
                    now,
                    self.render_width,
                    self.render_height,
                    self.ui_scale,
                    self.cell_width_pixels,
                    self.cell_height_pixels,
                    self.grid_font.cell_width,
                    self.grid_font.cell_height,
                    self.grid_font_size,
                    self.grid.cols,
                    self.grid.rows,
                    self.full_cols,
                    self.full_rows,
                    &self.anim_state,
                    sessions,
                    self.session_ui_info,
                    self.session_interaction_component.viewSlice(),
                    focused_has_foreground,
                    &app.theme,
                );
                switch (self.reader_overlay_component.toggle(&host_snapshot, now)) {
                    .opened => {
                        self.ui.showToast("Reader Mode", now);
                        if (app.config.ui.show_hotkey_feedback) self.ui.showHotkey("⌘R", now);
                    },
                    .closed => {},
                    .unavailable => self.ui.showToast("Reader mode requires a selected running terminal", now),
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
                    if (self.pending_comment_send) |prev| allocator.free(prev.text);
                    self.pending_comment_send = .{
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
                if (!self.story_overlay_component.show(story_action.path, now)) {
                    self.ui.showToast("Failed to open story file", now);
                }
                allocator.free(story_action.path);
            },
        };

        if (self.anim_state.mode == .Expanding or self.anim_state.mode == .Collapsing or
            self.anim_state.mode == .PanningLeft or self.anim_state.mode == .PanningRight or
            self.anim_state.mode == .PanningUp or self.anim_state.mode == .PanningDown)
        {
            if (self.anim_state.isComplete(now)) {
                const previous_mode = self.anim_state.mode;
                const next_mode = switch (self.anim_state.mode) {
                    .Expanding, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => .Full,
                    .Collapsing => .Grid,
                    else => self.anim_state.mode,
                };
                self.anim_state.mode = next_mode;
                if (previous_mode == .Collapsing and next_mode == .Grid and self.anim_state.focused_session < sessions.len) {
                    sessions[self.anim_state.focused_session].markDirty();
                }
                std.debug.print("Animation complete, new mode: {s}\n", .{@tagName(self.anim_state.mode)});
            }
        }

        // Handle grid resize animation completion
        if (self.anim_state.mode == .GridResizing) {
            if (self.grid.updateResize(now)) {
                self.anim_state.mode = .Grid;
                // Mark all sessions dirty to refresh render cache
                for (sessions) |session| {
                    session.markDirty();
                }
                std.debug.print("Grid resize complete: {d}x{d}\n", .{ self.grid.cols, self.grid.rows });
            }
        }

        // When the grid shape changes, resolve its saved per-shape font scale
        // (falling back to the global) before the per-frame layout so the PTY
        // dims and the grid font agree.
        if (self.grid.cols != self.resolved_grid_cols or self.grid.rows != self.resolved_grid_rows) {
            self.resolved_grid_cols = self.grid.cols;
            self.resolved_grid_rows = self.grid.rows;
            const preset = app.persistence.getGridFontPreset(self.grid.cols, self.grid.rows) orelse app.persistence.grid_font_scale;
            self.grid_font_scale = std.math.clamp(preset, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
        }

        const terminal_layout_changed = self.applyTerminalLayoutIfSizeChanged();
        if (terminal_layout_changed) {
            self.any_session_dirty = true;
            std.debug.print("Terminal layout adjusted for {s}: {d}x{d}\n", .{
                @tagName(self.anim_state.mode),
                self.full_cols,
                self.full_rows,
            });
        }

        if (self.anim_state.mode != self.last_logged_mode) {
            emitViewModeTransitionEvents(self.last_logged_mode, self.anim_state.mode, self.anim_state.focused_session, countSpawnedSessions(sessions));
            self.last_logged_mode = self.anim_state.mode;
        }
    }

    /// Render when anything changed. Returns true when the frame was idle.
    fn renderIfNeeded(self: *Window, now: i64, frame_start_ns: i128, had_notifications: bool, had_control_requests: bool) !bool {
        const app = self.app;
        const allocator = app.allocator;
        const sessions = self.sessions;
        const focused_has_foreground_process = self.foreground_cache.get(now, self.anim_state.focused_session, sessions);
        const ui_render_host = ui_host.makeUiHost(
            now,
            self.render_width,
            self.render_height,
            self.ui_scale,
            self.cell_width_pixels,
            self.cell_height_pixels,
            self.grid_font.cell_width,
            self.grid_font.cell_height,
            self.grid_font_size,
            self.grid.cols,
            self.grid.rows,
            self.full_cols,
            self.full_rows,
            &self.anim_state,
            sessions,
            self.session_ui_info,
            self.session_interaction_component.viewSlice(),
            focused_has_foreground_process,
            &app.theme,
        );

        // E2E harness observability (no-op unless CADRE_TEST_MODE is set).
        // One state file: the focused window owns it.
        if (self == app.focusedWindow()) test_probe.writeState(allocator, &ui_render_host);

        const animating = self.anim_state.mode != .Grid and self.anim_state.mode != .Full;
        const ui_needs_frame = self.ui.needsFrame(&ui_render_host);
        const last_render_stale = self.last_render_ns == 0 or (frame_start_ns - self.last_render_ns) >= max_idle_render_gap_ns;
        const should_render = animating or self.any_session_dirty or ui_needs_frame or self.processed_event or had_notifications or had_control_requests or last_render_stale;

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
                const grid_dim = @max(self.grid.cols, self.grid.rows);
                const eff_scale = (1.0 / @as(f32, @floatFromInt(grid_dim))) * self.grid_font_scale;
                // Estimate the grid font size directly: cell size scales ~linearly
                // with point size, so size ~= base_size * eff_scale. Opens one font
                // instead of probing every size (which caused a one-time hitch on
                // the first resize).
                const base_pt: f32 = @floatFromInt(layout.scaledFontSize(self.font_size, self.ui_scale));
                const desired = std.math.clamp(@as(c_int, @intFromFloat(@round(base_pt * eff_scale))), min_grid_font_size, max_font_size);
                if (desired != self.grid_font_size or app.shared_font_cache.generation != self.grid_font_generation) {
                    if (initSharedFont(allocator, self.pw.renderer, &app.shared_font_cache, desired)) |new_grid_font| {
                        self.grid_font.deinit();
                        self.grid_font = new_grid_font;
                        self.grid_font.metrics = app.metrics_ptr;
                        self.grid_font_size = desired;
                        self.grid_font_generation = app.shared_font_cache.generation;
                    } else |err| {
                        log.warn("failed to rebuild grid font at size {d}: {}", .{ desired, err });
                    }
                }
                self.grid_render_scale = 1.0;
            }
            if (self.relaunch_trace_frames > 0) {
                log.info("frame trace before render", .{});
            }
            renderer_mod.render(
                self.pw.renderer,
                &self.render_cache,
                sessions,
                self.session_interaction_component.viewSlice(),
                self.cell_width_pixels,
                self.cell_height_pixels,
                self.grid.cols,
                self.grid.rows,
                &self.anim_state,
                now,
                &self.font,
                &self.grid_font,
                self.grid_render_scale,
                self.full_cols,
                self.full_rows,
                self.render_width,
                self.render_height,
                &app.theme,
                self.ui_scale,
                self.grid_font_scale,
                &self.grid,
                self.window_focused,
                @intCast(app.config.ui.inactive_overlay_alpha),
            ) catch |err| {
                log.err("render failed: {}", .{err});
                return err;
            };
            self.ui.render(&ui_render_host, self.pw.renderer);
            _ = c.SDL_RenderPresent(self.pw.renderer);
            if (self.relaunch_trace_frames > 0) {
                log.info("frame trace after render", .{});
            }
            metrics_mod.increment(.frame_count);
            self.last_render_ns = std.time.nanoTimestamp();
        }

        return !animating and !self.any_session_dirty and !ui_needs_frame and !self.processed_event and !had_notifications and !had_control_requests;
    }

    fn endFrame(self: *Window) void {
        if (self.relaunch_trace_frames > 0) {
            self.relaunch_trace_frames -= 1;
        }
        if (self.window_close_suppress_countdown > 0) {
            self.window_close_suppress_countdown -= 1;
        }
    }
};

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // App-wide state is initialized field by field, in the same order as
    // before the App/Window split, so every defer keeps its original slot.
    var app: App = undefined;
    app.allocator = allocator;

    // Socket listener relays external "awaiting approval / done" signals from
    // shells (or other tools) into the UI thread without blocking rendering.
    app.notify_queue = NotificationQueue{};
    defer app.notify_queue.deinit(allocator);

    app.control_queue = ControlQueue{};
    defer app.control_queue.deinit(allocator);

    app.close_queue = control.CloseQueue{};
    defer app.close_queue.deinit(allocator);

    app.notify_sock = try notify.getNotifySocketPath(allocator);
    defer allocator.free(app.notify_sock);

    app.control_sock = try control.getControlSocketPath(allocator);
    defer allocator.free(app.control_sock);

    app.control_discovery_path = try control.getControlDiscoveryPath(allocator);
    defer allocator.free(app.control_discovery_path);

    app.notify_stop = std.atomic.Value(bool).init(false);
    app.control_stop = std.atomic.Value(bool).init(false);

    app.config = config_mod.Config.load(allocator) catch |err| blk: {
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
    defer app.config.deinit(allocator);

    var file_logging_enabled = false;
    logging_mod.init(allocator, .{
        .min_level = app.config.logging.getMinLevel(),
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

    app.persistence = config_mod.Persistence.load(allocator) catch |err| blk: {
        std.debug.print("Failed to load persistence: {}, using defaults\n", .{err});
        var fallback = config_mod.Persistence.init(allocator);
        fallback.font_size = app.config.font.size;
        fallback.window = app.config.window;
        break :blk fallback;
    };
    errdefer app.persistence.deinit(allocator);
    app.persistence.font_size = std.math.clamp(app.persistence.font_size, min_font_size, max_font_size);
    try app.persistence.ensureWindowEntries(allocator);

    // Mint the per-install tmux-name epoch (first launch after upgrade) and hand
    // it to the tmux layer BEFORE any session spawns, so `cadre-<epoch>-<n>`
    // names are used from the very first buildPersist. Save immediately so the
    // epoch is stable across relaunch (reattach depends on the name being equal).
    if (app.persistence.ensurePersistEpoch(allocator) catch |err| blk: {
        log.warn("failed to generate persist epoch: {}", .{err});
        break :blk false;
    }) {
        app.persistence.save(allocator) catch |err| {
            log.warn("failed to save freshly generated persist epoch: {}", .{err});
        };
    }
    tmux.setEpoch(app.persistence.persist_epoch);
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
    // mirror it back so future persistence saves keep it in sync. The window
    // copies config.grid.font_scale into its own live grid_font_scale.
    if (app.persistence.grid_font_scale != 0) {
        app.config.grid.font_scale = std.math.clamp(app.persistence.grid_font_scale, config_mod.min_grid_font_scale, config_mod.max_grid_font_scale);
    }
    app.persistence.grid_font_scale = app.config.grid.font_scale;

    // Initialize recent folders with home directory if empty
    if (app.persistence.recent_folders.items.len == 0) {
        if (std.posix.getenv("HOME")) |home| {
            app.persistence.appendRecentFolder(allocator, home) catch |err| {
                log.warn("failed to initialize recent folders with home: {}", .{err});
            };
        }
    }

    app.theme = colors_mod.Theme.fromConfig(app.config.theme);
    app.animations_enabled = app.config.ui.enable_animations;

    // Load persisted terminals to determine initial grid size
    const restored_entries = if (builtin.os.tag == .macos) app.persistence.terminal_entries.items else &[_]config_mod.Persistence.TerminalEntry{};
    const restored_limit = @min(restored_entries.len, grid_layout.max_terminals);
    const restored_slice = restored_entries[0..restored_limit];

    app.core = try platform.initCore();
    defer platform.deinitCore(&app.core);

    const notify_thread = try notify.startNotifyThread(
        allocator,
        app.notify_sock,
        &app.notify_queue,
        &app.notify_stop,
        .{
            .context = &app.core,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        app.notify_stop.store(true, .seq_cst);
        notify_thread.join();
    }
    notify.linkLegacySocketPath(allocator, app.notify_sock);
    const control_thread = try control.startControlThread(
        allocator,
        app.control_sock,
        app.control_discovery_path,
        &app.control_queue,
        &app.close_queue,
        &app.control_stop,
        .{
            .context = &app.core,
            .callback = platform.pushWakeEventFromOpaque,
        },
    );
    defer {
        app.control_stop.store(true, .seq_cst);
        control.failPending(&app.control_queue, allocator, .app_not_running, "Cadre is shutting down");
        control.failPendingClose(&app.close_queue, allocator, .app_not_running, "Cadre is shutting down");
        control_thread.join();
        control.cleanupControlFiles(app.control_sock, app.control_discovery_path);
    }
    app.input_source_tracker = macos_input.InputSourceTracker.init();
    defer app.input_source_tracker.deinit();
    if (builtin.os.tag == .macos) {
        app.input_source_tracker.capture() catch |err| {
            log.warn("Failed to capture input source: {}", .{err});
        };
    }

    app.font_paths = try font_paths_mod.FontPaths.init(allocator, app.config.font.family);
    defer app.font_paths.deinit();

    app.shared_font_cache = font_cache_mod.FontCache.initWithFallbacks(allocator, false);
    defer app.shared_font_cache.deinit();
    app.shared_font_cache.setPaths(
        app.font_paths.regular,
        app.font_paths.bold,
        app.font_paths.italic,
        app.font_paths.bold_italic,
        app.font_paths.symbol_fallback,
        app.font_paths.symbol_fallback_secondary,
        app.font_paths.emoji_fallback,
    );

    app.ui_font_cache = font_cache_mod.FontCache.initWithFallbacks(allocator, true);
    defer app.ui_font_cache.deinit();
    app.ui_font_cache.setPaths(
        app.font_paths.regular,
        app.font_paths.bold,
        app.font_paths.italic,
        app.font_paths.bold_italic,
        app.font_paths.symbol_fallback,
        app.font_paths.symbol_fallback_secondary,
        app.font_paths.emoji_fallback,
    );

    app.metrics_storage = metrics_mod.Metrics.init();
    app.metrics_ptr = if (app.config.metrics.enabled) &app.metrics_storage else null;
    metrics_mod.global = app.metrics_ptr;

    app.shell_path = std.posix.getenv("SHELL") orelse "/bin/zsh";

    app.loop = try xev.Loop.init(.{});
    defer app.loop.deinit();

    app.running = true;
    app.persistence_dirty = false;
    app.quit_teardown = QuitTeardownState{};
    defer app.quit_teardown.deinit(allocator);
    app.next_frame_wait = .none;
    app.windows = .{};
    app.pool = .{};
    app.last_focused = null;
    app.pending_new_window = null;
    app.closing_window = null;
    app.pending_move = null;
    app.pending_drag_out = null;

    // Pool sessions outlive every window (UI components reference them), so
    // this defer is registered first and runs after the windows are destroyed.
    defer {
        for (app.pool.items) |session| {
            session.deinit(allocator);
            allocator.destroy(session);
        }
        app.pool.deinit(allocator);
    }
    defer {
        for (app.windows.items) |w| w.destroy();
        app.windows.deinit(allocator);
        if (app.pending_new_window) |req| {
            if (req.cwd) |cwd| allocator.free(cwd);
        }
    }
    defer app.quit_teardown.join();

    // One window per persisted [[windows]] entry (a legacy file yields one),
    // each restoring the terminals that belong to it. Entries pointing past
    // the window list fall back to window 0 instead of being dropped.
    {
        const window_count = app.persistence.windows.items.len;
        var k: usize = 0;
        while (k < app.persistence.windows.items.len) {
            var group: std.ArrayListUnmanaged(config_mod.Persistence.TerminalEntry) = .{};
            defer group.deinit(allocator);
            for (restored_slice) |entry| {
                const wi = if (entry.window_index < window_count) entry.window_index else 0;
                if (wi != k or group.items.len >= grid_layout.max_terminals) continue;
                try group.append(allocator, entry);
            }
            const entry = app.persistence.windows.items[k];
            const created = Window.create(&app, group.items, entry.window, entry.focused_session, entry.zoomed, null, true) catch |err| {
                if (k == 0) return err;
                log.err("failed to restore window {d}: {}; its terminals stay detached in tmux", .{ k, err });
                _ = app.persistence.windows.orderedRemove(k);
                app.persistence_dirty = true;
                continue;
            };
            try app.windows.append(allocator, created);
            k += 1;
        }
    }
    app.applyVsyncFocus(app.focusedWindow());
    log.info("restored {d} window(s)", .{app.windows.items.len});
    // A bare-binary launch (dev instance) can come up behind other apps.
    _ = c.SDL_RaiseWindow(app.focusedWindow().pw.window);

    // Now that every restored/first session has reattached and holds a client,
    // drain the socket's detached-session graveyard (crashed instances, closed
    // terminals, pre-epoch fossils). Ours read as attached, so they're spared,
    // and so are the persisted indices we still want (a spawn failure above
    // must not cost the agent its session). Same-epoch sessions are only fair
    // game once every restored entry carried an index — a legacy file without
    // them can't tell a graveyard fossil from a live terminal's session.
    if (app.windows.items[0].sessions[0].tmux_backed) {
        var keep: std.ArrayListUnmanaged(usize) = .{};
        defer keep.deinit(allocator);
        var all_indexed = true;
        for (restored_slice) |entry| {
            if (entry.persist_index) |pi| {
                keep.append(allocator, pi) catch |err| {
                    log.warn("reaper keep list allocation failed: {}", .{err});
                };
            } else all_indexed = false;
        }
        tmux.reapDetachedSessions(allocator, keep.items, all_indexed);
    }

    // Main loop: optionally wait for the next wake-worthy event, then handle SDL
    // input, feed PTY output into terminals, apply async notifications, drive
    // animations, and render each window at the current cadence.
    while (app.running) {
        var next_event = waitForNextFrame(app.next_frame_wait);
        const frame_start_ns: i128 = std.time.nanoTimestamp();
        const now = std.time.milliTimestamp();
        for (app.windows.items) |window| {
            if (window.relaunch_trace_frames > 0) {
                log.info("frame trace start mode={s} grid_resizing={} grid={d}x{d}", .{
                    @tagName(window.anim_state.mode),
                    window.grid.is_resizing,
                    window.grid.cols,
                    window.grid.rows,
                });
            }
            window.processed_event = false;
        }

        var event: c.SDL_Event = undefined;
        while (true) {
            if (next_event) |ready_event| {
                event = ready_event;
                next_event = null;
            } else if (!c.SDL_PollEvent(&event)) {
                break;
            }
            if (platform.isWakeEvent(&app.core, &event)) continue;
            if (app.windows.items.len == 0) break;
            try app.dispatchEvent(&event, now);
        }

        if (!app.running) break;
        app.createWindowFromRequest();

        app.loop.run(.no_wait) catch |err| {
            log.err("xev loop run failed: {}", .{err});
            return err;
        };

        for (app.windows.items) |window| {
            if (window.relaunch_trace_frames > 0) {
                log.info("frame trace after xev run", .{});
            }
            window.pumpSessions(now);
        }

        const terminal_entries_changed = app.syncPersistenceFromWindows() catch |err| blk: {
            log.warn("failed to sync terminal persistence state: {}", .{err});
            break :blk false;
        };
        if (terminal_entries_changed) {
            app.persistence_dirty = true;
        }
        // Persist focus + zoom so the active/zoomed pane is restored on relaunch (2c).
        app.syncWindowViewState();
        savePersistenceIfDirty(&app.persistence, allocator, &app.persistence_dirty);

        if (app.quit_teardown.isFinished()) {
            app.running = false;
        }
        for (app.windows.items) |window| {
            window.any_session_dirty = window.render_cache.anyDirty(window.sessions);
        }

        var control_requests = app.control_queue.drainAll();
        defer control_requests.deinit(allocator);
        var had_control_requests = control_requests.items.len > 0;
        for (control_requests.items) |*request| {
            app.handleControlSpawn(request, now);
            request.request.deinit(allocator);
        }

        var close_requests = app.close_queue.drainAll();
        defer close_requests.deinit(allocator);
        if (close_requests.items.len > 0) had_control_requests = true;
        for (close_requests.items) |*request| {
            app.handleControlClose(request, now);
        }

        var notifications = app.notify_queue.drainAll();
        defer notifications.deinit(allocator);
        const had_notifications = notifications.items.len > 0;
        var captured_agent_session_id = false;
        for (notifications.items) |note| {
            if (app.applyNotification(note, now)) captured_agent_session_id = true;
        }

        // A SessionStart hook just delivered a fresh resume id this frame — but
        // AFTER the earlier entry-sync/save (which read the sessions before the id
        // landed). Re-sync so the entry carries the new id, then flush now instead
        // of a frame later, closing the window where a reboot could lose an id we
        // already hold in memory.
        if (captured_agent_session_id) {
            if (app.syncPersistenceFromWindows() catch |err| blk: {
                log.warn("failed to re-sync terminal persistence after agent-session capture: {}", .{err});
                break :blk false;
            }) {
                app.persistence_dirty = true;
            }
            savePersistenceIfDirty(&app.persistence, allocator, &app.persistence_dirty);
        }

        for (app.windows.items) |window| {
            try window.update(now);
        }
        app.applyPendingMove(now);
        app.applyPendingDragOut(now);
        app.updateDropHints();

        var is_idle = true;
        for (app.windows.items) |window| {
            const window_idle = try window.renderIfNeeded(now, frame_start_ns, had_notifications, had_control_requests);
            if (!window_idle) is_idle = false;
            window.endFrame();
        }

        // Window closes are applied after every window rendered this frame.
        app.finishClosingWindow();
        if (app.windows.items.len == 0) app.running = false;

        const frame_end_ns: i128 = std.time.nanoTimestamp();
        const frame_ns = frame_end_ns - frame_start_ns;
        const focused_vsync = if (app.windows.items.len > 0) app.focusedWindow().pw.vsync_enabled else false;
        app.next_frame_wait = computeFrameWaitDecision(is_idle, focused_vsync, frame_ns);
    }

    app.finalizeOnExit();

    app.persistence.save(allocator) catch |err| {
        std.debug.print("Failed to save persistence: {}\n", .{err});
    };
    app.persistence.deinit(allocator);
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

test "transferSlot swaps the slot pointers and re-homes the moved session" {
    var a0: SessionState = undefined;
    var a1: SessionState = undefined;
    var b0: SessionState = undefined;
    testSession(&a0, 10, 1, true, false);
    testSession(&a1, 11, 2, true, true); // hidden: moving un-hides it
    testSession(&b0, 20, 0, false, false); // target placeholder, never spawned
    a0.slot_index = 0;
    a1.slot_index = 1;
    b0.slot_index = 0;
    var src = [_]*SessionState{ &a0, &a1 };
    var dst = [_]*SessionState{&b0};
    const seq_before = session_state.mintOrderSeqBlock(1);

    transferSlot(&src, 1, &dst, 0);

    try std.testing.expectEqual(@as(usize, 11), dst[0].id);
    try std.testing.expectEqual(@as(usize, 20), src[1].id);
    try std.testing.expectEqual(@as(usize, 0), dst[0].slot_index);
    try std.testing.expectEqual(@as(usize, 1), src[1].slot_index);
    try std.testing.expect(!dst[0].hidden);
    try std.testing.expect(dst[0].order_seq > seq_before);
    // persist_index travels with the pointer: the tmux name is untouched.
    try std.testing.expectEqual(@as(usize, 11), dst[0].persist_index);
    try std.testing.expectEqual(@as(usize, 10), src[0].id);
}

test "carryViewState keeps badges and resets window-bound view state" {
    var src = SessionViewState{};
    var dst = SessionViewState{};
    src.status = .done;
    src.claude_seen = true;
    src.attention = true;
    src.hosting = true;
    src.selection_dragging = true;
    src.is_viewing_scrollback = true;
    src.wave_start_time = 42;
    dst.status = .running;
    dst.scroll_velocity = 3.0;

    carryViewState(&src, &dst);

    try std.testing.expectEqual(app_state.SessionStatus.done, dst.status);
    try std.testing.expect(dst.claude_seen and dst.attention and dst.hosting);
    try std.testing.expect(!dst.selection_dragging and !dst.is_viewing_scrollback);
    try std.testing.expectEqual(@as(i64, 0), dst.wave_start_time);
    try std.testing.expectEqual(@as(f32, 0.0), dst.scroll_velocity);
    try std.testing.expectEqual(app_state.SessionStatus.idle, src.status);
    try std.testing.expect(!src.attention and !src.hosting);
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

test "eventWindowId reads the window id for routed event types only" {
    var key = std.mem.zeroes(c.SDL_Event);
    key.type = c.SDL_EVENT_KEY_DOWN;
    key.key.windowID = 7;
    try std.testing.expectEqual(@as(?c.SDL_WindowID, 7), eventWindowId(&key));

    var resized = std.mem.zeroes(c.SDL_Event);
    resized.type = c.SDL_EVENT_WINDOW_RESIZED;
    resized.window.windowID = 3;
    try std.testing.expectEqual(@as(?c.SDL_WindowID, 3), eventWindowId(&resized));

    var wheel = std.mem.zeroes(c.SDL_Event);
    wheel.type = c.SDL_EVENT_MOUSE_WHEEL;
    wheel.wheel.windowID = 9;
    try std.testing.expectEqual(@as(?c.SDL_WindowID, 9), eventWindowId(&wheel));

    var quit = std.mem.zeroes(c.SDL_Event);
    quit.type = c.SDL_EVENT_QUIT;
    try std.testing.expectEqual(@as(?c.SDL_WindowID, null), eventWindowId(&quit));
}

test "syncPersistenceTerminalEntriesFromSlices groups entries by window" {
    const allocator = std.testing.allocator;

    var persistence = config_mod.Persistence.init(allocator);
    defer persistence.deinit(allocator);

    var storage: [3]SessionState = undefined;
    for (&storage, 0..) |*session, i| {
        session.* = undefined;
        session.spawned = true;
        session.dead = false;
        session.hidden = false;
        session.cwd_path = null;
        session.agent_kind = null;
        session.agent_session_id = null;
        session.agent_metadata_captured = false;
        session.persist_index = i;
    }
    storage[0].cwd_path = "/w0a";
    storage[1].cwd_path = "/w0b";
    storage[2].cwd_path = "/w1";
    var win0 = [_]*SessionState{ &storage[0], &storage[1] };
    var win1 = [_]*SessionState{&storage[2]};
    const groups = [_][]const *SessionState{ &win0, &win1 };

    try std.testing.expect(try syncPersistenceTerminalEntriesFromSlices(&persistence, &groups, allocator));
    try std.testing.expectEqual(@as(usize, 3), persistence.terminal_entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), persistence.terminal_entries.items[1].window_index);
    try std.testing.expectEqual(@as(usize, 1), persistence.terminal_entries.items[2].window_index);
    try std.testing.expectEqualStrings("/w1", persistence.terminal_entries.items[2].path);
    // Stable: a second sync with the same windows is a no-op.
    try std.testing.expect(!(try syncPersistenceTerminalEntriesFromSlices(&persistence, &groups, allocator)));
    // Moving a terminal to another window is a change.
    const moved = [_][]const *SessionState{ &win1, &win0 };
    try std.testing.expect(try syncPersistenceTerminalEntriesFromSlices(&persistence, &moved, allocator));
    try std.testing.expectEqual(@as(usize, 0), persistence.terminal_entries.items[0].window_index);
    try std.testing.expectEqualStrings("/w1", persistence.terminal_entries.items[0].path);
}

test "pickWindowAtPoint prefers the focused window when windows overlap" {
    const rects = [_]WindowRect{
        .{ .x = 0, .y = 0, .w = 800, .h = 600 },
        .{ .x = 400, .y = 300, .w = 800, .h = 600 },
    };
    // Overlap region: both contain (500, 400); preferred wins.
    try std.testing.expectEqual(@as(?usize, 1), pickWindowAtPoint(&rects, 1, 500, 400));
    try std.testing.expectEqual(@as(?usize, 0), pickWindowAtPoint(&rects, 0, 500, 400));
    // Preferred not under the point: first match.
    try std.testing.expectEqual(@as(?usize, 0), pickWindowAtPoint(&rects, 1, 10, 10));
    try std.testing.expectEqual(@as(?usize, 1), pickWindowAtPoint(&rects, 0, 1100, 800));
    // Empty screen and a stale preferred index.
    try std.testing.expectEqual(@as(?usize, null), pickWindowAtPoint(&rects, 0, 1300, 10));
    try std.testing.expectEqual(@as(?usize, null), pickWindowAtPoint(&rects, 7, 1300, 10));
}

test "dropSlotForPoint maps a screen point to the target grid slot" {
    // 800x600pt window at (100, 100), 2x retina, 2x2 grid of 800x600px cells.
    const rect = WindowRect{ .x = 100, .y = 100, .w = 800, .h = 600 };
    try std.testing.expectEqual(@as(?usize, 0), dropSlotForPoint(110, 110, rect, 2.0, 2.0, 800, 600, 2, 2, 4));
    try std.testing.expectEqual(@as(?usize, 1), dropSlotForPoint(600, 110, rect, 2.0, 2.0, 800, 600, 2, 2, 4));
    try std.testing.expectEqual(@as(?usize, 2), dropSlotForPoint(110, 500, rect, 2.0, 2.0, 800, 600, 2, 2, 4));
    try std.testing.expectEqual(@as(?usize, 3), dropSlotForPoint(899, 699, rect, 2.0, 2.0, 800, 600, 2, 2, 4));
    // Past the last visible tile (3 tiles in a 2x2 grid): no slot.
    try std.testing.expectEqual(@as(?usize, null), dropSlotForPoint(899, 699, rect, 2.0, 2.0, 800, 600, 2, 2, 3));
    // Outside the window.
    try std.testing.expectEqual(@as(?usize, null), dropSlotForPoint(50, 110, rect, 2.0, 2.0, 800, 600, 2, 2, 4));
    // A single full-window pane is slot 0 anywhere inside.
    try std.testing.expectEqual(@as(?usize, 0), dropSlotForPoint(700, 500, rect, 2.0, 2.0, 1600, 1200, 1, 1, 1));
}
