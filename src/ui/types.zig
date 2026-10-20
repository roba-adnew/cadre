const std = @import("std");
const app_state = @import("../app/app_state.zig");
const font_mod = @import("../font.zig");
const colors = @import("../colors.zig");
const font_cache = @import("../font_cache.zig");
const geom = @import("../geom.zig");

pub const SessionUiInfo = struct {
    dead: bool,
    spawned: bool,
    /// Spawned but pulled out of the grid (Cmd+J). Still alive; listed by the
    /// hidden-terminals switcher so it can be revealed.
    hidden: bool = false,
    cwd_path: ?[]const u8 = null,
    cwd_basename: ?[]const u8 = null,
    session_status: app_state.SessionStatus = .idle,
    /// A Claude notify-hook status has arrived at some point; "idle" means
    /// "Claude is resting" only when true, else the session never ran Claude.
    claude_seen: bool = false,
    /// The session's process tree owns a listening TCP socket (local server).
    hosting: bool = false,
    /// Terminal title set by the program (OSC 0/2) — e.g. the name from Claude
    /// Code's /rename — or null if unset. Borrows the session-owned string.
    agent_name: ?[]const u8 = null,
    /// Claude Code is running in this pane right now (its title is up).
    claude_live: bool = false,
    /// Claude is waiting on a permission/input answer (see
    /// `SessionViewState.approval_pending`; viewing the pane doesn't clear it).
    approval_pending: bool = false,
    /// Stable per-terminal id (`SessionState.persist_index`); unlike the slot
    /// index it survives grid reorders, so per-terminal UI state keys on it.
    persist_index: usize = 0,

    /// Spawned but pulled out of the grid — listed by the hidden-terminals switcher.
    pub fn isHidden(self: SessionUiInfo) bool {
        return self.spawned and self.hidden;
    }
};

/// Number of hidden terminals (spawned but pulled out of the grid).
pub fn hiddenCount(sessions: []const SessionUiInfo) usize {
    var n: usize = 0;
    for (sessions) |info| {
        if (info.isHidden()) n += 1;
    }
    return n;
}

/// True when any hidden terminal is awaiting approval ("needs you"), so the
/// count pill can adopt the attention border color.
pub fn hiddenNeedsAttention(sessions: []const SessionUiInfo) bool {
    for (sessions) |info| {
        if (info.isHidden() and info.session_status == .awaiting_approval) return true;
    }
    return false;
}

test "hiddenNeedsAttention only flags hidden awaiting_approval sessions" {
    var sessions = [_]SessionUiInfo{
        // Visible terminal needing attention must not light the badge.
        .{ .dead = false, .spawned = true, .hidden = false, .session_status = .awaiting_approval },
        .{ .dead = false, .spawned = true, .hidden = true },
    };
    try std.testing.expect(!hiddenNeedsAttention(&sessions));
    sessions[1].session_status = .awaiting_approval;
    try std.testing.expect(hiddenNeedsAttention(&sessions));
}

pub const UiHost = struct {
    now_ms: i64,

    window_w: c_int,
    window_h: c_int,
    ui_scale: f32,

    grid_cols: usize,
    grid_rows: usize,
    cell_w: c_int,
    cell_h: c_int,
    /// Grid font's native cell pixel size (grid_render_scale is 1.0). Lets the
    /// grid selection hit-test lay cells out exactly as the renderer does.
    /// Defaults to 0 (hit-test no-ops) for non-grid callers/tests.
    grid_cell_w: c_int = 0,
    grid_cell_h: c_int = 0,
    /// Grid font's pixel size (already DPI-scaled), so chrome text like the
    /// cwd bar can match the terminal text. 0 = unknown (fall back to fixed).
    grid_font_px: c_int = 0,
    term_cols: u16,
    term_rows: u16,

    view_mode: app_state.ViewMode,
    focused_session: usize,
    focused_cwd: ?[]const u8,
    focused_has_foreground_process: bool,
    animating_rect: ?geom.Rect = null,

    sessions: []const SessionUiInfo,
    theme: *const colors.Theme,

    mouse_x: c_int = 0,
    mouse_y: c_int = 0,
    mouse_has_position: bool = false,
    mouse_over_ui: bool = false,

    /// An overlay that types into its own field (find bar, switcher filter, ...)
    /// is open, so the composer hands SDL text input back to it.
    text_entry_open: bool = false,
};

pub const UiAction = union(enum) {
    RestartSession: usize,
    FocusSession: usize,
    /// Move the grid's focus/selection highlight to this pane without zooming
    /// it to full screen or spawning a shell. Mirrors Cmd+Arrow grid nav.
    SelectGridSession: usize,
    /// Un-hide the session at this index (the hidden-terminals switcher picked it)
    /// and bring it back into the grid.
    RevealHiddenTerminal: usize,
    /// Close the hidden session at this index (the switcher row's X). Runtime
    /// confirms first when a foreground process is running, like Cmd+W.
    CloseHiddenTerminal: usize,
    RequestCollapseFocused: void,
    /// Right-click on a focused terminal: paste the clipboard into it
    /// (PuTTY/xterm-style). Routed as an action so the paste path (image
    /// passthrough + text) stays owned by runtime, same as Cmd+V.
    PasteIntoFocused: void,
    ConfirmQuit: void,
    /// Close the window that emitted it (confirm dialog accepted, or nothing
    /// was running). The last window goes through ConfirmQuit instead.
    CloseWindow: void,
    OpenConfig: void,
    SwitchWorktree: SwitchWorktreeAction,
    CreateWorktree: CreateWorktreeAction,
    RemoveWorktree: RemoveWorktreeAction,
    ChangeDirectory: ChangeDirAction,
    DespawnSession: usize,
    /// Springboard move committed live during a hold-drag reorder: the tile at
    /// visible slot `from` moves to slot `to`, tiles between shift by one.
    /// Emitted per re-slot (not once at release), so each move is validated
    /// against the live visible set and there is no stale permutation to hold.
    ReorderGridSessions: ReorderMove,
    /// Detach the session at this index into a brand-new window (Cmd+Shift+M).
    MoveSessionToNewWindow: usize,
    /// Move the session at `idx` into the existing window `window_index`.
    MoveSessionToWindow: MoveSessionAction,
    /// A hold-drag was released OUTSIDE the window: the tile at visible slot
    /// `idx` (started at `origin`) is dropped at screen point (x, y). The app
    /// resolves whether that is another window (move + land there) or empty
    /// screen (open a new window at the drop point).
    DragSessionOut: DragOutAction,
    ToggleMetrics: void,
    ToggleDiffOverlay: void,
    ToggleReaderOverlay: void,
    SendDiffComments: SendDiffCommentsAction,
    OpenStory: OpenStoryAction,
    /// The composer's Enter: paste the text into the session, then press Return.
    ComposerSubmit: ComposerSubmitAction,
    /// Pixels the composer occupies at the bottom of the full view (0 = hidden),
    /// so the focused PTY is sized to the rows left above it.
    SetComposerHeight: c_int,
};

pub const ComposerSubmitAction = struct {
    session: usize,
    /// Heap-allocated; ownership transfers to runtime, which frees after send.
    text: []const u8,
};

pub const ReorderMove = struct {
    from: usize,
    to: usize,
};

pub const MoveSessionAction = struct {
    idx: usize,
    window_index: usize,
};

pub const DragOutAction = struct {
    idx: usize,
    origin: usize,
    screen_x: c_int,
    screen_y: c_int,
};

pub const SwitchWorktreeAction = struct {
    session: usize,
    path: []const u8,
};

pub const CreateWorktreeAction = struct {
    session: usize,
    base_path: []const u8,
    name: []const u8,
};

pub const RemoveWorktreeAction = struct {
    session: usize,
    path: []const u8,
};

pub const ChangeDirAction = struct {
    session: usize,
    path: []const u8,
};

pub const SendDiffCommentsAction = struct {
    session: usize,
    /// Heap-allocated; ownership transfers to runtime, which frees after send.
    comments_text: []const u8,
    /// Heap-allocated; ownership transfers to runtime, which frees after send.
    agent_command: ?[]const u8,
};

pub const OpenStoryAction = struct {
    /// Heap-allocated path; ownership transfers to runtime, which frees after use.
    path: []const u8,
};

pub const UiAssets = struct {
    ui_font: ?*font_mod.Font = null,
    font_cache: ?*font_cache.FontCache = null,
};

pub const UiActionQueue = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(UiAction) = .{},

    pub fn init(allocator: std.mem.Allocator) UiActionQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *UiActionQueue) void {
        self.list.deinit(self.allocator);
    }

    pub fn append(self: *UiActionQueue, action: UiAction) std.mem.Allocator.Error!void {
        try self.list.append(self.allocator, action);
    }

    pub fn pop(self: *UiActionQueue) ?UiAction {
        if (self.list.items.len == 0) return null;
        return self.list.orderedRemove(0);
    }
};
