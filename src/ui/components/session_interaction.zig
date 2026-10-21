const std = @import("std");
const c = @import("../../c.zig");
const ghostty_vt = @import("ghostty-vt");
const input = @import("../../input/mapper.zig");
const open_url = @import("../../os/open.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const renderer_mod = @import("../../render/renderer.zig");
const dpi = @import("../../dpi.zig");
const session_state = @import("../../session/state.zig");
const tmux = @import("../../tmux.zig");
const url_matcher = @import("../../url_matcher.zig");
const path_matcher = @import("../../path_matcher.zig");
const font_mod = @import("../../font.zig");
const app_state = @import("../../app/app_state.zig");
const types = @import("../types.zig");
const scrollbar = @import("scrollbar.zig");
const cwd_bar_metrics = @import("cwd_bar_metrics.zig");
const view_state = @import("../session_view_state.zig");
const UiComponent = @import("../component.zig").UiComponent;
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;

const log = std.log.scoped(.session_interaction);

const SessionState = session_state.SessionState;
const SessionViewState = view_state.SessionViewState;

const scroll_lines_per_tick: isize = 1;
const max_scroll_velocity: f32 = 30.0;
pub const wave_total_ms: i64 = 400;
pub const nav_wave_total_ms: i64 = 250;
pub const wave_row_anim_ms: i64 = 150;
pub const wave_amplitude: f32 = 0.08;
pub const nav_wave_amplitude: f32 = 0.02;
pub const wave_strip_height: i64 = 8;

const CursorKind = enum { arrow, ibeam, pointer, grab };

/// Click-hold-drag tile reorder (grid view): a plain press becomes a drag
/// after `reorder_hold_ms` without traveling more than `reorder_drag_slop_px`;
/// traveling early demotes the press to the normal text-selection drag.
pub const reorder_hold_ms: i64 = 220;
pub const reorder_drag_slop_px: f32 = 6.0;
const ReorderPhase = enum { idle, pending, active };

/// A press withheld from a mouse-tracking program while a lone-terminal hold
/// resolves (Full view). Forwarded late for a click/drag, dropped for a drag.
const DeferredPress = struct { button: u8, x: c_int, y: c_int };

/// What a pending hold should do now. Pure so it is testable.
const HoldOutcome = enum { forward_now, promote, wait };
fn holdOutcome(elapsed_ms: i64, moved: bool, released: bool) HoldOutcome {
    if (released or moved) return .forward_now;
    if (elapsed_ms >= reorder_hold_ms) return .promote;
    return .wait;
}

/// The hold-to-drag gesture lives in grid view, and in Full view when the
/// window holds exactly one visible terminal (the window IS the tile).
fn dragAllowedFor(mode: app_state.ViewMode, visible: usize) bool {
    return inGridView(mode) or (mode == .Full and visible == 1);
}

pub const SessionInteractionComponent = struct {
    allocator: std.mem.Allocator,
    sessions: []*SessionState,
    views: []SessionViewState,
    font: *font_mod.Font,
    arrow_cursor: ?*c.SDL_Cursor = null,
    ibeam_cursor: ?*c.SDL_Cursor = null,
    pointer_cursor: ?*c.SDL_Cursor = null,
    grab_cursor: ?*c.SDL_Cursor = null,
    current_cursor: CursorKind = .arrow,
    last_update_ms: i64 = 0,
    /// Grid-view text selection: the pane index a drag-select started in, so motion
    /// and release stay bound to that pane. Null when not selecting in grid view.
    grid_selection_idx: ?usize = null,
    /// Hold-to-reorder drag state. `reorder_slot` is the slot the dragged tile
    /// currently occupies — each re-slot is committed live via
    /// UiAction.ReorderGridSessions, so no permutation is held here.
    reorder_phase: ReorderPhase = .idle,
    reorder_slot: usize = 0,
    /// Slot the drag started from; Escape re-slots the tile back here.
    reorder_origin_slot: usize = 0,
    reorder_first_frame: FirstFrameGuard = .{},
    reorder_press_x: f32 = 0,
    reorder_press_y: f32 = 0,
    reorder_press_ms: i64 = 0,
    /// A single click's SelectGridSession is deferred to release so a press
    /// that becomes a hold-drag never flashes a focus change first. Fired on
    /// release, or immediately when the press demotes into a text selection.
    deferred_select: ?usize = null,
    /// Slot to outline while ANOTHER window's drag hovers over this window
    /// (set per frame by the app); draws the same lift cue as a local drag.
    drop_hint: ?usize = null,
    /// Full-view lone-terminal hold: press withheld from the program.
    deferred_press: ?DeferredPress = null,

    fn dragAllowed(self: *const SessionInteractionComponent, host: *const types.UiHost) bool {
        return dragAllowedFor(host.view_mode, visibleCount(self.sessions));
    }

    pub fn isReordering(self: *const SessionInteractionComponent) bool {
        return self.reorder_phase == .active;
    }

    pub fn setDropHint(self: *SessionInteractionComponent, hint: ?usize) void {
        if (std.meta.eql(self.drop_hint, hint)) return;
        self.drop_hint = hint;
        self.reorder_first_frame.markTransition();
    }

    pub fn init(
        allocator: std.mem.Allocator,
        sessions: []*SessionState,
        font: *font_mod.Font,
    ) !*SessionInteractionComponent {
        const self = try allocator.create(SessionInteractionComponent);
        errdefer allocator.destroy(self);

        const views = try allocator.alloc(SessionViewState, sessions.len);
        for (views) |*view| {
            view.* = .{};
        }
        errdefer allocator.free(views);

        self.* = .{
            .allocator = allocator,
            .sessions = sessions,
            .views = views,
            .font = font,
        };

        self.arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
        self.ibeam_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT);
        self.pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
        self.grab_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_MOVE);
        if (self.arrow_cursor) |cursor| {
            _ = c.SDL_SetCursor(cursor);
            self.current_cursor = .arrow;
        }

        return self;
    }

    pub fn asComponent(self: *SessionInteractionComponent) UiComponent {
        return .{
            .ptr = self,
            .vtable = &vtable,
            .z_index = -100,
        };
    }

    pub fn destroy(self: *SessionInteractionComponent, renderer: *c.SDL_Renderer) void {
        _ = renderer;
        for (self.views) |*view| {
            view.terminal_scrollbar.deinit();
        }
        if (self.arrow_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        if (self.ibeam_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        if (self.pointer_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        if (self.grab_cursor) |cursor| {
            c.SDL_DestroyCursor(cursor);
        }
        self.allocator.free(self.views);
        self.allocator.destroy(self);
    }

    pub fn viewSlice(self: *SessionInteractionComponent) []SessionViewState {
        return self.views;
    }

    pub fn resetView(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        self.views[idx].reset();
        self.sessions[idx].markDirty();
    }

    pub fn clearSelection(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        view.clearSelection();
        view.clearHover();
        if (self.sessions[idx].terminal) |*terminal| {
            terminal.screens.active.clearSelection();
        }
        self.sessions[idx].markDirty();
    }

    /// Record a Claude notify-hook status. This is the only path that sets
    /// "working"/"needs you"/"done"; user interaction never fakes a status.
    pub fn setStatus(self: *SessionInteractionComponent, idx: usize, status: app_state.SessionStatus) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        if (self.views[idx].applyClaudeStatus(status)) self.sessions[idx].markDirty();
    }

    pub fn setHosting(self: *SessionInteractionComponent, idx: usize, hosting: bool) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        if (view.hosting == hosting) return;
        view.hosting = hosting;
        self.sessions[idx].markDirty();
    }

    /// Focusing a session acknowledges a sticky "done" or "needs you" status
    /// back to "idle"; both stay as attention cues only until the user looks
    /// at the terminal.
    pub fn acknowledgeAttention(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        if (self.views[idx].acknowledgeAttention()) self.sessions[idx].markDirty();
    }

    pub fn setAttention(self: *SessionInteractionComponent, idx: usize, attention: bool, now_ms: i64) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        if (attention) {
            view.wave_start_time = now_ms;
            view.attention = true;
            self.sessions[idx].markDirty();
        } else {
            if (!view.attention) return;
            view.attention = false;
            self.sessions[idx].markDirty();
        }
    }

    pub fn triggerNavWave(self: *SessionInteractionComponent, idx: usize, now_ms: i64) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        self.views[idx].nav_wave_start_time = now_ms;
        self.sessions[idx].markDirty();
    }

    pub fn resetScrollIfNeeded(self: *SessionInteractionComponent, idx: usize) void {
        if (idx >= self.views.len or idx >= self.sessions.len) return;
        const view = &self.views[idx];
        if (!view.is_viewing_scrollback) return;

        if (self.sessions[idx].terminal) |*terminal| {
            terminal.screens.active.pages.scroll(.{ .active = {} });
            view.clearScroll();
            self.sessions[idx].markDirty();
        }
    }

    /// Promote a pending hold to an active reorder drag once the time bar is
    /// crossed. Disarms the text selection the same press started — the two
    /// gestures are mutually exclusive from here on — and drops the deferred
    /// select (a drag is not a click).
    fn maybePromoteReorder(self: *SessionInteractionComponent, host: *const types.UiHost) void {
        if (host.now_ms - self.reorder_press_ms < reorder_hold_ms) return;
        self.reorder_phase = .active;
        self.reorder_origin_slot = self.reorder_slot;
        self.deferred_select = null;
        // The program never sees a press that became a drag.
        self.deferred_press = null;
        if (self.grid_selection_idx) |idx| {
            if (idx < self.views.len) endSelection(&self.views[idx]);
            self.grid_selection_idx = null;
        }
        // Closed fist (macOS closed-hand) from the moment the hold arms, even
        // before any motion event arrives.
        self.updateCursor(.grab);
        self.reorder_first_frame.markTransition();
    }

    /// End the reorder gesture (release, Escape, focus loss). Re-slots are
    /// committed live, so ending is just state cleanup plus one frame to
    /// erase the lift cue.
    fn endReorder(self: *SessionInteractionComponent) void {
        self.reorder_phase = .idle;
        self.deferred_select = null;
        self.deferred_press = null;
        self.updateCursor(.arrow);
        self.reorder_first_frame.markTransition();
    }

    /// Encode and send a button press to the focused program at the cell under
    /// (x, y). Returns false when the button or cell can't be mapped.
    fn forwardPressToProgram(self: *SessionInteractionComponent, host: *const types.UiHost, focused: *SessionState, button: u8, x: c_int, y: c_int) bool {
        const terminal = &(focused.terminal orelse return false);
        const btn = sdlToMouseButton(button) orelse return false;
        const cell = fullViewCellFromMouse(x, y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale) orelse return false;
        const sgr = terminal.modes.get(.mouse_format_sgr);
        var buf: [32]u8 = undefined;
        const n = input.encodeMouseButton(btn, cell.col, cell.row, true, sgr, &buf);
        if (n > 0) {
            focused.sendInput(buf[0..n]) catch |err| {
                log.warn("failed to send mouse button: {}", .{err});
            };
        }
        return true;
    }

    /// A plain grid click on a tile whose program tracks the mouse (Claude, vim)
    /// reaches that program as a full click, so its clickable UI works without
    /// expanding the tile first. Sent on release because the press could still
    /// have become a hold-drag or a drag-select.
    fn forwardGridClick(self: *SessionInteractionComponent, host: *const types.UiHost, x: c_int, y: c_int) void {
        const idx = calculateHoveredSession(x, y, host) orelse return;
        if (idx >= self.sessions.len or idx >= self.views.len) return;
        const session = self.sessions[idx];
        if (!session.spawned) return;
        const terminal = &(session.terminal orelse return);
        const shift_held = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;
        if (!forwardMouseToProgram(terminalHasMouseTracking(terminal), self.views[idx].is_viewing_scrollback, shift_held)) return;
        const cell = gridTileCellFromMouse(host, x, y, idx, terminal.cols, terminal.rows) orelse return;
        var buf: [64]u8 = undefined;
        session.sendInput(encodeClick(cell.col, cell.row, terminal.modes.get(.mouse_format_sgr), &buf)) catch |err| {
            log.warn("session {d}: failed to send grid click: {}", .{ idx, err });
        };
    }

    /// The hold resolved as a click or an ordinary drag: deliver the press the
    /// program was owed, so what follows (motion, release) reads as one gesture.
    fn flushDeferredPress(self: *SessionInteractionComponent, host: *const types.UiHost) void {
        const press = self.deferred_press orelse return;
        self.deferred_press = null;
        if (host.focused_session >= self.sessions.len) return;
        const focused = self.sessions[host.focused_session];
        if (!focused.spawned) return;
        _ = self.forwardPressToProgram(host, focused, press.button, press.x, press.y);
    }

    /// Release of an active drag. Inside the window the re-slots were already
    /// committed live (grid) or there was nothing to re-slot (Full), so it just
    /// ends; outside, the tile is handed to the app, which picks between another
    /// window and a brand-new one at the drop point.
    fn finishActiveDrag(self: *SessionInteractionComponent, host: *const types.UiHost, up_x: c_int, up_y: c_int, actions: *types.UiActionQueue) void {
        if (!pointerInsideWindow(up_x, up_y, host.window_w, host.window_h)) {
            var gx: f32 = 0;
            var gy: f32 = 0;
            _ = c.SDL_GetGlobalMouseState(&gx, &gy);
            actions.append(.{ .DragSessionOut = .{
                .idx = self.reorder_slot,
                .origin = self.reorder_origin_slot,
                .screen_x = @intFromFloat(gx),
                .screen_y = @intFromFloat(gy),
            } }) catch |err| {
                log.warn("failed to queue drag-out of slot {d}: {}", .{ self.reorder_slot, err });
            };
        }
        self.endReorder();
    }

    fn handleEvent(self_ptr: *anyopaque, host: *const types.UiHost, event: *const c.SDL_Event, actions: *types.UiActionQueue) bool {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));

        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                // Escape cancels an active reorder drag: springboard the tile
                // back to where the drag started (re-slots were committed
                // live, so the way back is just one more move).
                if (event.key.key == c.SDLK_ESCAPE and self.reorder_phase == .active) {
                    if (self.reorder_slot != self.reorder_origin_slot) {
                        actions.append(.{ .ReorderGridSessions = .{ .from = self.reorder_slot, .to = self.reorder_origin_slot } }) catch |err| {
                            log.warn("failed to queue reorder cancel {d}->{d}: {}", .{ self.reorder_slot, self.reorder_origin_slot, err });
                        };
                    }
                    self.endReorder();
                    return true;
                }
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                // The release will land in another app; end the gesture but
                // let the runtime's own focus-lost handling run too. A still
                // held button means the drag is crossing into another Cadre
                // window (its release still reaches us via mouse capture).
                if (self.reorder_phase != .idle and !leftButtonHeldGlobally()) self.endReorder();
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                const mouse_x: c_int = @intFromFloat(event.button.x);
                const mouse_y: c_int = @intFromFloat(event.button.y);
                if (event.button.button == c.SDL_BUTTON_LEFT and
                    self.handleTerminalScrollbarMouseDown(host, mouse_x, mouse_y))
                {
                    return true;
                }

                if (host.view_mode == .Grid) {
                    const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, host.cell_w))), host.grid_cols - 1);
                    const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, host.cell_h))), host.grid_rows - 1);
                    const clicked_session: usize = grid_row_idx * host.grid_cols + grid_col_idx;
                    if (clicked_session >= self.sessions.len) return false;

                    // Cmd+Left-click opens the link under the cursor (OSC 8 or
                    // detected URL/path), same as full view. Checked before the
                    // focus/select logic so a Cmd-click on a link opens it instead
                    // of focusing the pane. Falls through to normal handling when
                    // there's no link under the cursor.
                    if (event.button.button == c.SDL_BUTTON_LEFT and event.button.clicks == 1 and
                        (c.SDL_GetModState() & c.SDL_KMOD_GUI) != 0)
                    {
                        if (gridViewHitFromMouse(self.sessions, self.views, host, mouse_x, mouse_y)) |hit| {
                            const session = self.sessions[hit.idx];
                            if (session.terminal) |*terminal| {
                                if (getLinkAtPin(self.allocator, terminal, hit.pin, self.views[hit.idx].is_viewing_scrollback, session.cwd_path)) |uri| {
                                    defer self.allocator.free(uri);
                                    open_url.openTarget(self.allocator, uri) catch |err| {
                                        log.err("failed to open link: {}", .{err});
                                    };
                                    return true;
                                }
                            }
                        }
                    }

                    // Single click on a different pane moves the focus/selection
                    // highlight (no zoom, no spawn); double-click focuses (zooms)
                    // the pane. A single click on the already-focused pane is a
                    // no-op. Uses SDL's native click counter, which respects the
                    // OS double-click speed.
                    const cmd_held = (c.SDL_GetModState() & c.SDL_KMOD_GUI) != 0;
                    switch (gridClickOutcome(event.button.clicks, clicked_session, host.focused_session, host.grid_cols * host.grid_rows)) {
                        .none => {},
                        // Deferred to release for plain left presses: the same
                        // press may become a hold-drag reorder, and selecting
                        // first would flash the focus highlight mid-gesture.
                        .select => if (!cmd_held and event.button.button == c.SDL_BUTTON_LEFT and event.button.clicks == 1) {
                            self.deferred_select = clicked_session;
                        } else {
                            actions.append(.{ .SelectGridSession = clicked_session }) catch |err| {
                                log.warn("failed to queue select action for session {d}: {}", .{ clicked_session, err });
                            };
                        },
                        .focus => actions.append(.{ .FocusSession = clicked_session }) catch |err| {
                            log.warn("failed to queue focus action for session {d}: {}", .{ clicked_session, err });
                        },
                    }
                    // Arm drag-to-select on the clicked pane. A plain click just
                    // focuses (above); this only becomes a real selection once the
                    // mouse moves far enough (handled in MOUSE_MOTION).
                    if (event.button.button == c.SDL_BUTTON_LEFT and event.button.clicks == 1) {
                        if (gridViewHitFromMouse(self.sessions, self.views, host, mouse_x, mouse_y)) |hit| {
                            beginSelection(self.sessions[hit.idx], &self.views[hit.idx], hit.pin);
                            self.grid_selection_idx = hit.idx;
                        }
                        // Arm hold-to-reorder on visible tiles. Cmd presses never
                        // arm (Cmd is the link-open modifier); double-click zoom
                        // is excluded by clicks == 1.
                        if (!cmd_held and clicked_session < visibleCount(self.sessions)) {
                            self.reorder_phase = .pending;
                            self.reorder_slot = clicked_session;
                            self.reorder_press_x = event.button.x;
                            self.reorder_press_y = event.button.y;
                            self.reorder_press_ms = host.now_ms;
                        }
                    }
                    return true;
                }

                if (host.view_mode == .Full) {
                    const focused_idx = host.focused_session;
                    if (focused_idx >= self.sessions.len) return false;
                    const focused = self.sessions[focused_idx];
                    const view = &self.views[focused_idx];

                    if (focused.spawned and focused.terminal != null) {
                        const terminal = &focused.terminal.?;

                        // Shift bypasses the focused program's mouse reporting so
                        // text selection works locally even inside Claude/vim/pagers
                        // (standard terminal behavior — iTerm/Ghostty/kitty/xterm all
                        // do this). Without it, the mouse-tracking forward below
                        // swallows every click/drag and no selection is ever made,
                        // so Cmd+C has nothing to copy.
                        const shift_held = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;

                        // Right-click opens the context menu (context_menu.zig, which
                        // sits above this component and consumes the press). Swallow a
                        // stray press here so the program never sees it.
                        if (event.button.button == c.SDL_BUTTON_RIGHT) return true;

                        // Double-click in a focused pane returns to grid, even when
                        // the focused program (Claude/vim/pagers) has mouse reporting
                        // on. Checked BEFORE the mouse-tracking forward below,
                        // otherwise the program swallows the double-click and there's
                        // no mouse path back to the grid. Shift+double-click instead
                        // word-selects (see the Shift bypass above). Single clicks and
                        // drags still forward. Mirrors grid-view double-click-to-zoom.
                        if (!shift_held and event.button.button == c.SDL_BUTTON_LEFT and event.button.clicks == 2) {
                            actions.append(.RequestCollapseFocused) catch |err| {
                                log.warn("failed to queue collapse action: {}", .{err});
                            };
                            return true;
                        }

                        // Cmd+Left-click opens the link under the cursor (OSC 8 or
                        // detected URL), bypassing the focused program's mouse
                        // reporting — same reasoning as the double-click case above.
                        // Without this, the mouse-tracking forward below swallows
                        // the click and links never open under Claude/vim/pagers.
                        // Standard terminal behavior (Cmd/Super+Click follows links
                        // regardless of mouse mode). Fully consumes the click so a
                        // stray Cmd-click never reaches the app.
                        if (event.button.button == c.SDL_BUTTON_LEFT and event.button.clicks == 1 and
                            (c.SDL_GetModState() & c.SDL_KMOD_GUI) != 0)
                        {
                            if (fullViewPinFromMouse(focused, view, mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale)) |pin| {
                                if (getLinkAtPin(self.allocator, &focused.terminal.?, pin, view.is_viewing_scrollback, focused.cwd_path)) |uri| {
                                    defer self.allocator.free(uri);
                                    open_url.openTarget(self.allocator, uri) catch |err| {
                                        log.err("failed to open link: {}", .{err});
                                    };
                                } else {
                                    beginSelection(focused, view, pin);
                                }
                                return true;
                            }
                        }

                        const forward_press = forwardMouseToProgram(terminalHasMouseTracking(terminal), view.is_viewing_scrollback, shift_held);

                        // Arm hold-to-drag when this window's only terminal fills
                        // it (the window is the tile). A tracked press is withheld
                        // until the hold resolves: forwarded late for a click or an
                        // immediate drag, never for a drag of the tile.
                        if (event.button.button == c.SDL_BUTTON_LEFT and event.button.clicks == 1 and
                            self.dragAllowed(host))
                        {
                            self.reorder_phase = .pending;
                            self.reorder_slot = focused_idx;
                            self.reorder_press_x = event.button.x;
                            self.reorder_press_y = event.button.y;
                            self.reorder_press_ms = host.now_ms;
                            self.deferred_select = null;
                            if (forward_press) {
                                self.deferred_press = .{ .button = event.button.button, .x = mouse_x, .y = mouse_y };
                                return true;
                            }
                        }

                        if (forward_press) {
                            if (self.forwardPressToProgram(host, focused, event.button.button, mouse_x, mouse_y)) return true;
                        }

                        if (event.button.button == c.SDL_BUTTON_LEFT) {
                            if (fullViewPinFromMouse(focused, view, mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale)) |pin| {
                                const clicks = event.button.clicks;
                                if (clicks >= 3) {
                                    selectLine(focused, view, pin);
                                } else if (clicks == 2) {
                                    selectWord(focused, view, pin);
                                } else {
                                    // Cmd+Click (link-open) is handled above, before
                                    // the mouse-tracking forward; a plain single
                                    // click here just starts a selection.
                                    beginSelection(focused, view, pin);
                                }
                                return true;
                            }
                        }
                    }
                }
            },
            c.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (event.button.button == c.SDL_BUTTON_LEFT and self.finishTerminalScrollbarDrag(host.now_ms)) {
                    return true;
                }
                if (host.view_mode == .Full) {
                    const focused_idx = host.focused_session;
                    if (focused_idx >= self.sessions.len) return false;
                    const focused = self.sessions[focused_idx];
                    const view = &self.views[focused_idx];

                    // Right-click paste (button-down) is fully consumed there;
                    // swallow its release too so the program never sees a dangling
                    // right-button event.
                    if (event.button.button == c.SDL_BUTTON_RIGHT) return true;

                    // Lone-terminal hold: an active drag ends here (swallowed, the
                    // program never saw the press); a hold released early was a
                    // click, so the withheld press goes out now and the release
                    // follows through the normal path below.
                    if (event.button.button == c.SDL_BUTTON_LEFT and self.reorder_phase != .idle) {
                        if (self.reorder_phase == .active) {
                            self.finishActiveDrag(host, @intFromFloat(event.button.x), @intFromFloat(event.button.y), actions);
                            return true;
                        }
                        self.reorder_phase = .idle;
                        self.flushDeferredPress(host);
                    }

                    // A local Shift-selection was made without forwarding the press,
                    // so don't forward the release either — end the selection locally.
                    // The screen selection persists for Cmd+C; only the drag-state
                    // flags reset.
                    if (event.button.button == c.SDL_BUTTON_LEFT and
                        (view.selection_dragging or view.selection_pending))
                    {
                        endSelection(view);
                        return true;
                    }

                    if (focused.spawned and focused.terminal != null) {
                        const terminal = &focused.terminal.?;
                        if (forwardMouseToProgram(terminalHasMouseTracking(terminal), view.is_viewing_scrollback, false)) {
                            if (sdlToMouseButton(event.button.button)) |btn| {
                                const mouse_x: c_int = @intFromFloat(event.button.x);
                                const mouse_y: c_int = @intFromFloat(event.button.y);
                                if (fullViewCellFromMouse(mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale)) |cell| {
                                    const sgr = terminal.modes.get(.mouse_format_sgr);
                                    var buf: [32]u8 = undefined;
                                    const n = input.encodeMouseButton(btn, cell.col, cell.row, false, sgr, &buf);
                                    if (n > 0) {
                                        focused.sendInput(buf[0..n]) catch |err| {
                                            log.warn("failed to send mouse release: {}", .{err});
                                        };
                                    }
                                    return true;
                                }
                            }
                        }
                    }

                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        if (focused_idx >= self.views.len) return false;
                        endSelection(&self.views[focused_idx]);
                        return true;
                    }
                }

                if (inGridView(host.view_mode) and event.button.button == c.SDL_BUTTON_LEFT) {
                    var plain_click = false;
                    switch (self.reorder_phase) {
                        // The drag owned this press; every re-slot was already
                        // committed live, so release just ends the gesture.
                        // Released outside the window: hand the tile to the
                        // app, which decides between another window and a
                        // brand-new one at the drop point.
                        .active => {
                            self.finishActiveDrag(host, @intFromFloat(event.button.x), @intFromFloat(event.button.y), actions);
                            return true;
                        },
                        // Hold never satisfied: this was a plain click — fire
                        // the select that was deferred on press.
                        .pending => {
                            self.reorder_phase = .idle;
                            plain_click = true;
                            if (self.deferred_select) |idx| {
                                self.deferred_select = null;
                                actions.append(.{ .SelectGridSession = idx }) catch |err| {
                                    log.warn("failed to queue select action for session {d}: {}", .{ idx, err });
                                };
                            }
                        },
                        .idle => {},
                    }
                    if (self.grid_selection_idx) |idx| {
                        const was_dragging = idx < self.views.len and self.views[idx].selection_dragging;
                        if (idx < self.views.len) endSelection(&self.views[idx]);
                        self.grid_selection_idx = null;
                        if (was_dragging) return true; // consumed the drag-select release
                    }
                    if (plain_click) self.forwardGridClick(host, @intFromFloat(event.button.x), @intFromFloat(event.button.y));
                }
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                const mouse_x: c_int = @intFromFloat(event.motion.x);
                const mouse_y: c_int = @intFromFloat(event.motion.y);

                var desired_cursor: CursorKind = .arrow;
                const dragging_scrollbar = self.handleTerminalScrollbarDrag(host, mouse_x, mouse_y);
                const over_scrollbar = self.updateTerminalScrollbarHover(host, mouse_x, mouse_y) or dragging_scrollbar;

                // Lone-terminal hold (Full view), ahead of the motion forward so
                // a tracking program sees nothing until the hold resolves.
                // Pending: travel past the slop demotes it to a click/drag (the
                // withheld press goes out, then motion flows as usual); staying
                // put promotes on the time bar. Active: the drag owns the pointer.
                if (!dragging_scrollbar and host.view_mode == .Full and self.reorder_phase != .idle) {
                    if (self.reorder_phase == .active) {
                        self.updateCursor(.grab);
                        return true;
                    }
                    const dx = event.motion.x - self.reorder_press_x;
                    const dy = event.motion.y - self.reorder_press_y;
                    switch (holdOutcome(host.now_ms - self.reorder_press_ms, reorderPressMoved(dx, dy), false)) {
                        .forward_now => {
                            self.reorder_phase = .idle;
                            self.flushDeferredPress(host);
                        },
                        .promote => {
                            self.maybePromoteReorder(host);
                            return true;
                        },
                        // A withheld press means the program must not get motion yet.
                        .wait => if (self.deferred_press != null) return true,
                    }
                }

                if (!dragging_scrollbar and host.view_mode == .Full) {
                    const focused_idx = host.focused_session;
                    if (focused_idx < self.sessions.len) {
                        var focused = self.sessions[focused_idx];
                        const view = &self.views[focused_idx];

                        if (focused.spawned and focused.terminal != null and !view.is_viewing_scrollback) {
                            const terminal = &focused.terminal.?;
                            const any_tracking = terminal.modes.get(.mouse_event_any);
                            const btn_tracking = terminal.modes.get(.mouse_event_button);
                            const btn_held = (event.motion.state & c.SDL_BUTTON_LMASK) != 0 or
                                (event.motion.state & c.SDL_BUTTON_MMASK) != 0 or
                                (event.motion.state & c.SDL_BUTTON_RMASK) != 0;
                            // Cmd+hover must reach the link-underline detection below,
                            // so don't forward motion while Cmd is held — the same
                            // bypass as Cmd+Click. Without this, an app in any-motion
                            // mode (DECSET 1003, e.g. Claude Code) swallows every
                            // motion event and links never underline on Cmd-hover.
                            const cmd_held = (c.SDL_GetModState() & c.SDL_KMOD_GUI) != 0;
                            // Shift bypasses mouse reporting so a Shift+drag selection
                            // runs locally instead of being forwarded to the program
                            // (matches the button-down/up bypass above).
                            const shift_held = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;
                            if (!cmd_held and !shift_held and (any_tracking or (btn_tracking and btn_held))) {
                                if (fullViewCellFromMouse(mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale)) |cell| {
                                    const held_btn: ?input.MouseButton = if ((event.motion.state & c.SDL_BUTTON_LMASK) != 0)
                                        .left
                                    else if ((event.motion.state & c.SDL_BUTTON_MMASK) != 0)
                                        .middle
                                    else if ((event.motion.state & c.SDL_BUTTON_RMASK) != 0)
                                        .right
                                    else
                                        null;
                                    const sgr = terminal.modes.get(.mouse_format_sgr);
                                    var buf: [32]u8 = undefined;
                                    const n = input.encodeMouseMotion(held_btn, cell.col, cell.row, sgr, &buf);
                                    if (n > 0) {
                                        focused.sendInput(buf[0..n]) catch |err| {
                                            log.warn("failed to send mouse motion: {}", .{err});
                                        };
                                    }
                                    self.updateCursor(desired_cursor);
                                    return true;
                                }
                            }
                        }

                        const pin = fullViewPinFromMouse(focused, view, mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale);

                        if (view.selection_dragging) {
                            if (pin) |p| {
                                updateSelectionDrag(focused, view, p);
                            }

                            const edge_threshold: c_int = 50;
                            const scroll_speed: isize = 1;
                            if (mouse_y < edge_threshold) {
                                scrollSession(focused, view, -scroll_speed, host.now_ms);
                            } else if (mouse_y > host.window_h - edge_threshold) {
                                scrollSession(focused, view, scroll_speed, host.now_ms);
                            }
                        } else if (view.selection_pending) {
                            if (view.selection_anchor) |anchor| {
                                if (pin) |p| {
                                    if (!pinsEqual(anchor, p)) {
                                        startSelectionDrag(focused, view, p);
                                    }
                                }
                            } else {
                                view.selection_pending = false;
                            }
                        }

                        if (!host.mouse_over_ui and pin != null and focused.terminal != null) {
                            const mod = c.SDL_GetModState();
                            const cmd_held = (mod & c.SDL_KMOD_GUI) != 0;

                            if (cmd_held) {
                                if (getLinkMatchAtPin(self.allocator, &focused.terminal.?, pin.?, view.is_viewing_scrollback, focused.cwd_path)) |link_match| {
                                    desired_cursor = .pointer;
                                    view.hovered_link_start = link_match.start_pin;
                                    view.hovered_link_end = link_match.end_pin;
                                    self.allocator.free(link_match.url);
                                    focused.markDirty();
                                } else {
                                    desired_cursor = .ibeam;
                                    if (view.hovered_link_start != null) {
                                        view.clearHover();
                                        focused.markDirty();
                                    }
                                }
                            } else {
                                desired_cursor = .ibeam;
                                if (view.hovered_link_start != null) {
                                    view.clearHover();
                                    focused.markDirty();
                                }
                            }
                        } else {
                            if (view.hovered_link_start != null) {
                                view.clearHover();
                                focused.markDirty();
                            }
                        }
                    }
                }

                // Hold-to-reorder. Pending: pointer travel past the slop before
                // the hold elapses demotes the press to the text-selection drag
                // below (firing the deferred select the press was holding);
                // staying put lets update()/this path promote on the time bar.
                // Active: the drag owns the pointer — re-slot when the cursor
                // enters the CENTER zone of another tile, and skip hover and
                // selection handling entirely.
                if (self.reorder_phase != .idle and !self.dragAllowed(host)) {
                    // View changed mid-press (zoom animation etc.) — abandon.
                    // GridResizing still counts as grid: every committed
                    // re-slot flips the mode there for its slide animation,
                    // and the drag must keep running through it.
                    self.endReorder();
                }
                if (!dragging_scrollbar and inGridView(host.view_mode) and self.reorder_phase == .pending) {
                    const dx = event.motion.x - self.reorder_press_x;
                    const dy = event.motion.y - self.reorder_press_y;
                    if (reorderPressMoved(dx, dy)) {
                        self.reorder_phase = .idle;
                        if (self.deferred_select) |idx| {
                            self.deferred_select = null;
                            actions.append(.{ .SelectGridSession = idx }) catch |err| {
                                log.warn("failed to queue select action for session {d}: {}", .{ idx, err });
                            };
                        }
                    } else {
                        self.maybePromoteReorder(host);
                    }
                }
                if (!dragging_scrollbar and inGridView(host.view_mode) and self.reorder_phase == .active) {
                    const inside = pointerInsideWindow(mouse_x, mouse_y, host.window_w, host.window_h);
                    if (if (inside) reorderTargetSlot(mouse_x, mouse_y, host.grid_cols, host.grid_rows, host.cell_w, host.cell_h, visibleCount(self.sessions)) else null) |target| {
                        if (target != self.reorder_slot) {
                            actions.append(.{ .ReorderGridSessions = .{ .from = self.reorder_slot, .to = target } }) catch |err| {
                                log.warn("failed to queue reorder action {d}->{d}: {}", .{ self.reorder_slot, target, err });
                            };
                            self.reorder_slot = target;
                        }
                    }
                    self.updateCursor(.grab);
                    return true;
                }

                // Grid-view Cmd+hover: underline the link under the cursor and show
                // the pointer cursor, matching full view. The hovered pane can be any
                // tile, so clear any stale hover on the other panes first.
                if (!dragging_scrollbar and host.view_mode == .Grid and !host.mouse_over_ui) {
                    const cmd_held = (c.SDL_GetModState() & c.SDL_KMOD_GUI) != 0;
                    var hovered_idx: ?usize = null;
                    if (cmd_held) {
                        if (gridViewHitFromMouse(self.sessions, self.views, host, mouse_x, mouse_y)) |hit| {
                            const session = self.sessions[hit.idx];
                            const view = &self.views[hit.idx];
                            if (session.terminal) |*terminal| {
                                if (getLinkMatchAtPin(self.allocator, terminal, hit.pin, view.is_viewing_scrollback, session.cwd_path)) |link_match| {
                                    desired_cursor = .pointer;
                                    view.hovered_link_start = link_match.start_pin;
                                    view.hovered_link_end = link_match.end_pin;
                                    self.allocator.free(link_match.url);
                                    session.markDirty();
                                    hovered_idx = hit.idx;
                                }
                            }
                        }
                    }
                    // Clear hover on every pane except the one currently hovered.
                    for (self.views, 0..) |*view, i| {
                        if (hovered_idx == i) continue;
                        if (view.hovered_link_start != null) {
                            view.clearHover();
                            self.sessions[i].markDirty();
                        }
                    }
                }

                // Grid-view drag selection, bound to the pane the drag started in.
                if (!dragging_scrollbar and host.view_mode == .Grid) {
                    if (self.grid_selection_idx) |idx| {
                        if (idx < self.sessions.len) {
                            const session = self.sessions[idx];
                            const view = &self.views[idx];
                            if (gridViewHitFromMouse(self.sessions, self.views, host, mouse_x, mouse_y)) |hit| {
                                if (hit.idx == idx) {
                                    if (view.selection_dragging) {
                                        updateSelectionDrag(session, view, hit.pin);
                                        desired_cursor = .ibeam;
                                    } else if (view.selection_pending) {
                                        if (view.selection_anchor) |anchor| {
                                            if (!pinsEqual(anchor, hit.pin)) {
                                                startSelectionDrag(session, view, hit.pin);
                                                desired_cursor = .ibeam;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (over_scrollbar) {
                    desired_cursor = .pointer;
                }
                self.updateCursor(desired_cursor);
                return true;
            },
            c.SDL_EVENT_MOUSE_WHEEL => {
                const mouse_x: c_int = @intFromFloat(event.wheel.mouse_x);
                const mouse_y: c_int = @intFromFloat(event.wheel.mouse_y);

                const hovered_session = calculateHoveredSession(
                    mouse_x,
                    mouse_y,
                    host,
                );
                if (hovered_session) |session_idx| {
                    if (session_idx >= self.sessions.len) return false;
                    var session = self.sessions[session_idx];
                    const view = &self.views[session_idx];
                    const ticks_per_notch: isize = scroll_lines_per_tick;
                    const wheel_ticks: isize = if (event.wheel.integer_y != 0)
                        @as(isize, @intCast(event.wheel.integer_y)) * ticks_per_notch
                    else
                        @as(isize, @intFromFloat(event.wheel.y * @as(f32, @floatFromInt(scroll_lines_per_tick))));
                    const scroll_delta = -wheel_ticks;
                    if (scroll_delta != 0) {
                        const terminal_opt = session.terminal;
                        const should_forward = blk: {
                            // Forward the wheel to a mouse-tracking program (Claude,
                            // vim, pagers) so it scrolls ITS own view — in grid as
                            // well as full. Previously grid refused to forward and
                            // fell through to tmux copy-mode, which is empty for a
                            // full-screen (alternate-screen) app, so scrolling a
                            // Claude tile in grid showed "0/0" while focus worked.
                            if (host.view_mode != .Full and host.view_mode != .Grid) break :blk false;
                            if (view.is_viewing_scrollback) break :blk false;
                            const terminal = terminal_opt orelse break :blk false;
                            const mouse_tracking = terminal.modes.get(.mouse_event_normal) or
                                terminal.modes.get(.mouse_event_button) or
                                terminal.modes.get(.mouse_event_any) or
                                terminal.modes.get(.mouse_event_x10);
                            break :blk mouse_tracking;
                        };

                        var forwarded = false;
                        if (should_forward) {
                            if (terminal_opt) |terminal| {
                                // In grid view the pane is a tile, so map the mouse
                                // to that tile's cell; in full view use the whole
                                // window. Both yield the pane-local (col,row) the
                                // mouse-scroll encoding needs.
                                const cell_opt = if (host.view_mode == .Grid)
                                    gridTileCellFromMouse(host, mouse_x, mouse_y, session_idx, terminal.cols, terminal.rows)
                                else
                                    fullViewCellFromMouse(mouse_x, mouse_y, host.window_w, host.window_h, self.font, host.term_cols, host.term_rows, host.ui_scale);
                                if (cell_opt) |cell| {
                                    forwarded = true;
                                    const sgr_format = terminal.modes.get(.mouse_format_sgr);
                                    const direction: input.MouseScrollDirection = if (scroll_delta < 0) .up else .down;
                                    const count = @abs(scroll_delta);
                                    var buf: [32]u8 = undefined;
                                    var i: usize = 0;
                                    while (i < count) : (i += 1) {
                                        const n = input.encodeMouseScroll(direction, cell.col, cell.row, sgr_format, &buf);
                                        if (n > 0) {
                                            session.sendInput(buf[0..n]) catch |err| {
                                                log.warn("session {d}: failed to send mouse scroll: {}", .{ session_idx, err });
                                            };
                                        }
                                    }
                                }
                            }
                        }

                        if (!forwarded) {
                            if (session.tmux_backed) {
                                // tmux owns the scrollback (the shell runs inside it), so
                                // ghostty-vt's scrollback is empty — drive tmux copy-mode
                                // out-of-band. Works the same in grid and focus view.
                                const lines: u16 = @intCast(@min(@abs(scroll_delta), 100));
                                tmux.scrollHistory(self.allocator, session.persist_index, lines, scroll_delta < 0);
                                // Pane is now in modal copy-mode; the next keystroke (sendInput)
                                // cancels it so the cursor returns to the live prompt.
                                session.scrolled_in_copy_mode = true;
                            } else {
                                scrollSession(session, view, scroll_delta, host.now_ms);
                                if (event.wheel.which == c.SDL_TOUCH_MOUSEID) {
                                    view.scroll_inertia_allowed = false;
                                }
                            }
                        }
                    }
                }
                return true;
            },
            else => {},
        }

        return false;
    }

    fn hitTest(_: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        return false;
    }

    /// Lift cue: while a reorder drag is active, outline the dragged tile's
    /// current cell with a thicker accent border so it reads as "picked up".
    fn render(self_ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        _ = assets;
        defer self.reorder_first_frame.markDrawn();
        const slot: usize = if (self.reorder_phase == .active and self.dragAllowed(host))
            self.reorder_slot
        else
            self.drop_hint orelse return;
        const rect = sessionRectForIndex(host, slot) orelse return;
        const thickness = dpi.scale(renderer_mod.grid_border_thickness + 2, host.ui_scale);
        // Theme text color at reduced alpha: reads as a lifted outline on both
        // light and dark themes.
        const lift_fg = host.theme.chromeText();
        const lift_gray: c.SDL_Color = .{ .r = lift_fg.r, .g = lift_fg.g, .b = lift_fg.b, .a = 220 };
        primitives.drawThickBorder(renderer, rect, thickness, dpi.scale(6, host.ui_scale), lift_gray);
    }

    fn update(self_ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        if (self.last_update_ms == 0) {
            self.last_update_ms = host.now_ms;
            return;
        }
        const delta_ms = host.now_ms - self.last_update_ms;
        self.last_update_ms = host.now_ms;
        if (delta_ms <= 0) return;

        // A motionless hold gets no mouse events; the per-frame tick is what
        // promotes it to a reorder drag (wantsFrame keeps frames coming).
        if (self.reorder_phase == .pending and self.dragAllowed(host)) {
            self.maybePromoteReorder(host);
        }

        const delta_time_s: f32 = @as(f32, @floatFromInt(delta_ms)) / 1000.0;
        for (self.sessions, 0..) |session, idx| {
            const view = &self.views[idx];
            updateScrollInertia(session, view, delta_time_s, host.now_ms);
            view.terminal_scrollbar.update(host.now_ms);
            if (view.wave_start_time > 0) {
                const wave_elapsed = host.now_ms - view.wave_start_time;
                if (wave_elapsed >= wave_total_ms) {
                    view.wave_start_time = 0;
                    session.markDirty();
                }
            }
            if (view.nav_wave_start_time > 0) {
                const nav_wave_elapsed = host.now_ms - view.nav_wave_start_time;
                if (nav_wave_elapsed >= nav_wave_total_ms) {
                    view.nav_wave_start_time = 0;
                    session.markDirty();
                }
            }
        }
    }

    fn wantsFrame(self_ptr: *anyopaque, host: *const types.UiHost) bool {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        // A pending hold must keep update() ticking so a motionless press can
        // cross the time threshold even under idle throttling; the guard buys
        // one more frame after the gesture ends to erase the lift cue.
        if (self.reorder_phase != .idle) return true;
        if (self.reorder_first_frame.wantsFrame()) return true;
        for (self.views) |view| {
            if (view.scroll_velocity != 0.0) return true;
            if (view.wave_start_time > 0 and (host.now_ms - view.wave_start_time) < wave_total_ms) return true;
            if (view.nav_wave_start_time > 0 and (host.now_ms - view.nav_wave_start_time) < nav_wave_total_ms) return true;
            if (view.terminal_scrollbar.wantsFrame(host.now_ms)) return true;
        }
        return false;
    }

    const ScrollbarContext = struct {
        session: *SessionState,
        view: *SessionViewState,
        metrics: scrollbar.Metrics,
        layout: scrollbar.Layout,
    };

    fn finishTerminalScrollbarDrag(self: *SessionInteractionComponent, now_ms: i64) bool {
        var handled = false;
        for (self.views) |*view| {
            if (view.terminal_scrollbar.dragging) {
                view.terminal_scrollbar.endDrag(now_ms);
                handled = true;
            }
        }
        return handled;
    }

    fn handleTerminalScrollbarMouseDown(self: *SessionInteractionComponent, host: *const types.UiHost, mouse_x: c_int, mouse_y: c_int) bool {
        const hovered_session = calculateHoveredSession(mouse_x, mouse_y, host) orelse return false;
        const ctx = self.terminalScrollbarContext(host, hovered_session) orelse return false;

        switch (scrollbar.hitTest(ctx.layout, mouse_x, mouse_y)) {
            .thumb => {
                ctx.view.terminal_scrollbar.beginDrag(ctx.layout, mouse_y, host.now_ms);
                ctx.session.markDirty();
                return true;
            },
            .track => {
                const target_offset = scrollbar.offsetForTrackClick(ctx.layout, ctx.metrics, mouse_y);
                self.applyTerminalScrollbarOffset(ctx, target_offset, host.now_ms);
                return true;
            },
            .none => return false,
        }
    }

    fn handleTerminalScrollbarDrag(self: *SessionInteractionComponent, host: *const types.UiHost, _: c_int, mouse_y: c_int) bool {
        for (self.views, 0..) |*view, idx| {
            if (!view.terminal_scrollbar.dragging) continue;
            if (self.terminalScrollbarContext(host, idx)) |ctx| {
                const target_offset = scrollbar.offsetForDrag(&view.terminal_scrollbar, ctx.layout, ctx.metrics, mouse_y);
                self.applyTerminalScrollbarOffset(ctx, target_offset, host.now_ms);
            } else {
                view.terminal_scrollbar.endDrag(host.now_ms);
            }
            return true;
        }
        return false;
    }

    fn updateTerminalScrollbarHover(self: *SessionInteractionComponent, host: *const types.UiHost, mouse_x: c_int, mouse_y: c_int) bool {
        const hovered_session = calculateHoveredSession(mouse_x, mouse_y, host);
        var over_scrollbar = false;

        for (self.views, 0..) |*view, idx| {
            if (view.terminal_scrollbar.dragging) {
                view.terminal_scrollbar.setHovered(true, host.now_ms);
                over_scrollbar = true;
                continue;
            }

            if (hovered_session != null and hovered_session.? == idx) {
                if (self.terminalScrollbarContext(host, idx)) |ctx| {
                    const hovered = scrollbar.hitTest(ctx.layout, mouse_x, mouse_y) != .none;
                    view.terminal_scrollbar.setHovered(hovered, host.now_ms);
                    if (hovered) {
                        over_scrollbar = true;
                    }
                } else {
                    view.terminal_scrollbar.setHovered(false, host.now_ms);
                }
                continue;
            }

            view.terminal_scrollbar.setHovered(false, host.now_ms);
        }

        return over_scrollbar;
    }

    fn terminalScrollbarContext(self: *SessionInteractionComponent, host: *const types.UiHost, session_idx: usize) ?ScrollbarContext {
        if (session_idx >= self.sessions.len or session_idx >= self.views.len) return null;
        const session = self.sessions[session_idx];
        if (!session.spawned) return null;
        const terminal = session.terminal orelse return null;
        const session_rect = sessionRectForIndex(host, session_idx) orelse return null;
        const content_rect = terminalContentRect(session_rect, host.ui_scale) orelse return null;
        const bar = terminal.screens.active.pages.scrollbar();
        const metrics = scrollbar.Metrics.init(
            @as(f32, @floatFromInt(bar.total)),
            @as(f32, @floatFromInt(bar.offset)),
            @as(f32, @floatFromInt(bar.len)),
        );
        const layout = scrollbar.computeLayout(content_rect, host.ui_scale, metrics) orelse return null;
        return .{
            .session = session,
            .view = &self.views[session_idx],
            .metrics = metrics,
            .layout = layout,
        };
    }

    fn applyTerminalScrollbarOffset(_: *SessionInteractionComponent, ctx: ScrollbarContext, raw_offset: f32, now_ms: i64) void {
        const clamped_offset = std.math.clamp(raw_offset, 0.0, ctx.metrics.maxOffset());
        if (ctx.session.terminal) |*terminal| {
            var pages = &terminal.screens.active.pages;
            const target_row: usize = @intFromFloat(std.math.round(clamped_offset));
            pages.scroll(.{ .row = target_row });
            ctx.view.is_viewing_scrollback = (pages.viewport != .active);
            ctx.view.scroll_velocity = 0.0;
            ctx.view.scroll_remainder = 0.0;
            ctx.view.scroll_inertia_allowed = false;
            ctx.view.last_scroll_time = now_ms;
            ctx.view.terminal_scrollbar.noteActivity(now_ms);
            ctx.session.markDirty();
        }
    }

    fn updateCursor(self: *SessionInteractionComponent, desired: CursorKind) void {
        if (desired == self.current_cursor) return;
        const target_cursor = switch (desired) {
            .arrow => self.arrow_cursor,
            .ibeam => self.ibeam_cursor,
            .pointer => self.pointer_cursor,
            .grab => self.grab_cursor,
        };
        if (target_cursor) |cursor| {
            _ = c.SDL_SetCursor(cursor);
            self.current_cursor = desired;
        }
    }

    fn deinitComp(self_ptr: *anyopaque, renderer: *c.SDL_Renderer) void {
        const self: *SessionInteractionComponent = @ptrCast(@alignCast(self_ptr));
        self.destroy(renderer);
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEvent,
        .update = update,
        .render = render,
        .hitTest = hitTest,
        .deinit = deinitComp,
        .wantsFrame = wantsFrame,
    };
};

const GridClickOutcome = enum { none, select, focus };

/// Decide what a left mouse-button-down in grid mode should do. A single click
/// on a pane other than the focused one moves the selection/focus highlight
/// (handled as `SelectGridSession`: no spawn, no zoom). A double-click focuses
/// (zooms) the pane (`FocusSession`), but only when the grid holds more than one
/// pane — with a single window open there is nothing to zoom into, so the
/// double-click is ignored (`pane_count` is grid_cols*grid_rows; hidden windows
/// are pulled out of the grid so they don't count). A single click on the
/// already-focused pane does nothing.
fn gridClickOutcome(clicks: u8, clicked_session: usize, focused_session: usize, pane_count: usize) GridClickOutcome {
    if (clicks >= 2 and pane_count > 1) return .focus;
    if (clicked_session == focused_session) return .none;
    return .select;
}

fn terminalHasMouseTracking(terminal: anytype) bool {
    return terminal.modes.get(.mouse_event_normal) or
        terminal.modes.get(.mouse_event_button) or
        terminal.modes.get(.mouse_event_any) or
        terminal.modes.get(.mouse_event_x10);
}

/// Whether a mouse button event should be forwarded to the focused program's
/// mouse reporting instead of handled locally as a text selection. Holding
/// Shift bypasses reporting so drag-select works even inside programs that grab
/// the mouse (Claude/vim/pagers) — standard terminal behavior. Scrollback view
/// is always local (no live program owns it).
fn forwardMouseToProgram(has_mouse_tracking: bool, viewing_scrollback: bool, shift_held: bool) bool {
    return has_mouse_tracking and !viewing_scrollback and !shift_held;
}

/// Left press + release in one write, so the program gets the click whole.
fn encodeClick(col: u16, row: u16, sgr: bool, buf: *[64]u8) []const u8 {
    const n = input.encodeMouseButton(.left, col, row, true, sgr, buf[0..32]);
    const m = input.encodeMouseButton(.left, col, row, false, sgr, buf[n..]);
    return buf[0 .. n + m];
}

fn sdlToMouseButton(sdl_button: u8) ?input.MouseButton {
    return switch (sdl_button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        else => null,
    };
}

const CellPosition = struct { col: u16, row: u16 };

fn fullViewCellFromMouse(
    mouse_x: c_int,
    mouse_y: c_int,
    render_width: c_int,
    render_height: c_int,
    font: *const font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    ui_scale: f32,
) ?CellPosition {
    const padding = dpi.scale(renderer_mod.terminal_padding, ui_scale);
    const origin_x: c_int = padding;
    const origin_y: c_int = padding;
    const drawable_w: c_int = render_width - padding * 2;
    const drawable_h: c_int = render_height - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return null;

    const cell_w: c_int = font.cell_width;
    const cell_h: c_int = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return null;

    if (mouse_x < origin_x or mouse_y < origin_y) return null;
    if (mouse_x >= origin_x + drawable_w or mouse_y >= origin_y + drawable_h) return null;

    const col = @as(u16, @intCast(@divFloor(mouse_x - origin_x, cell_w)));
    const row = @as(u16, @intCast(@divFloor(mouse_y - origin_y, cell_h)));
    if (col >= term_cols or row >= term_rows) return null;

    return .{ .col = col, .row = row };
}

fn fullViewPinFromMouse(
    session: *SessionState,
    view: *SessionViewState,
    mouse_x: c_int,
    mouse_y: c_int,
    render_width: c_int,
    render_height: c_int,
    font: *const font_mod.Font,
    term_cols: u16,
    term_rows: u16,
    ui_scale: f32,
) ?ghostty_vt.Pin {
    if (!session.spawned or session.terminal == null) return null;

    const padding = dpi.scale(renderer_mod.terminal_padding, ui_scale);
    const origin_x: c_int = padding;
    const origin_y: c_int = padding;
    const drawable_w: c_int = render_width - padding * 2;
    const drawable_h: c_int = render_height - padding * 2;
    if (drawable_w <= 0 or drawable_h <= 0) return null;

    const cell_w: c_int = font.cell_width;
    const cell_h: c_int = font.cell_height;
    if (cell_w == 0 or cell_h == 0) return null;

    if (mouse_x < origin_x or mouse_y < origin_y) return null;
    if (mouse_x >= origin_x + drawable_w or mouse_y >= origin_y + drawable_h) return null;

    const col = @as(u16, @intCast(@divFloor(mouse_x - origin_x, cell_w)));
    const row = @as(u16, @intCast(@divFloor(mouse_y - origin_y, cell_h)));
    if (col >= term_cols or row >= term_rows) return null;

    const point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = col, .y = row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = col, .y = row } };

    const terminal = session.terminal orelse return null;
    return terminal.screens.active.pages.pin(point);
}

fn beginSelection(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = session.terminal orelse return;
    terminal.screens.active.clearSelection();
    view.selection_anchor = pin;
    view.selection_pending = true;
    view.selection_dragging = false;
    session.markDirty();
}

fn startSelectionDrag(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = session.terminal orelse return;
    const anchor = view.selection_anchor orelse return;

    view.selection_dragging = true;
    view.selection_pending = false;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(anchor, pin, false)) catch |err| {
        log.warn("session {d}: failed to start selection: {}", .{ session.id, err });
    };
    session.markDirty();
}

fn updateSelectionDrag(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    if (!view.selection_dragging) return;
    const anchor = view.selection_anchor orelse return;
    const terminal = session.terminal orelse return;
    terminal.screens.active.select(ghostty_vt.Selection.init(anchor, pin, false)) catch |err| {
        log.warn("session {d}: failed to update selection: {}", .{ session.id, err });
    };
    session.markDirty();
}

fn endSelection(view: *SessionViewState) void {
    view.selection_dragging = false;
    view.selection_pending = false;
    view.selection_anchor = null;
}

fn pinsEqual(a: ghostty_vt.Pin, b: ghostty_vt.Pin) bool {
    return a.node == b.node and a.x == b.x and a.y == b.y;
}

const GridHit = struct { idx: usize, pin: ghostty_vt.Pin };

/// Map a mouse position in grid view to (pane index, terminal pin). Finds the pane
/// under the cursor, then the cell within that pane's content area.
///
/// Mirrors `renderer.renderSessionContent` cell-for-cell: cells are laid out at the
/// grid font's native pixel size (grid_render_scale is 1.0), the cwd bar reserves
/// height at the bottom of each tile, and the active screen scrolls by
/// `activeScreenRowOffset` to keep the cursor visible. The earlier version stretched
/// the rows proportionally over the full (un-reserved) tile height, so selection
/// landed ~one row above the click — worse toward the bottom of the pane.
fn gridViewHitFromMouse(
    sessions: []*SessionState,
    views: []SessionViewState,
    host: *const types.UiHost,
    mouse_x: c_int,
    mouse_y: c_int,
) ?GridHit {
    if (host.view_mode != .Grid) return null;
    if (mouse_x < 0 or mouse_y < 0) return null;
    if (host.cell_w <= 0 or host.cell_h <= 0 or host.grid_cols == 0 or host.grid_rows == 0) return null;
    if (host.grid_cell_w <= 0 or host.grid_cell_h <= 0) return null;

    const gc: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, host.cell_w))), host.grid_cols - 1);
    const gr: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, host.cell_h))), host.grid_rows - 1);
    const idx = gr * host.grid_cols + gc;
    if (idx >= sessions.len) return null;

    const session = sessions[idx];
    if (!session.spawned or session.terminal == null) return null;
    const terminal = &session.terminal.?;
    const term_cols: c_int = terminal.cols;
    const term_rows: c_int = terminal.rows;
    if (term_cols == 0 or term_rows == 0) return null;

    const padding = dpi.scale(renderer_mod.terminal_padding, host.ui_scale);
    const origin_x = @as(c_int, @intCast(gc)) * host.cell_w + padding;
    const origin_y = @as(c_int, @intCast(gr)) * host.cell_h + padding;
    // Grid panes reserve a strip at the bottom for the cwd bar; the renderer drops
    // it from the drawable height, so the hit-test must too (this was the missing
    // vertical offset). Same guard as renderer.renderSessionContent.
    const grid_reserved_h: c_int = if (host.cell_h >= cwd_bar_metrics.minCellHeight(host.ui_scale, renderer_mod.grid_border_thickness))
        cwd_bar_metrics.reservedHeight(host.ui_scale, renderer_mod.grid_border_thickness)
    else
        0;
    const drawable_w = host.cell_w - padding * 2;
    const drawable_h = host.cell_h - padding * 2 - grid_reserved_h;
    if (drawable_w <= 0 or drawable_h <= 0) return null;
    if (mouse_x < origin_x or mouse_y < origin_y) return null;

    const hit = gridCellAt(mouse_x - origin_x, mouse_y - origin_y, drawable_w, drawable_h, host.grid_cell_w, host.grid_cell_h, term_cols, term_rows) orelse return null;

    const view = &views[idx];
    const point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = @intCast(hit.col), .y = @intCast(hit.row) } }
    else blk: {
        const row_offset = renderer_mod.activeScreenRowOffset(
            @intCast(term_rows),
            @intCast(hit.visible_rows),
            terminal.screens.active.cursor.y,
            true,
            false,
        );
        break :blk ghostty_vt.point.Point{ .active = .{ .x = @intCast(hit.col), .y = @intCast(@as(usize, @intCast(hit.row)) + row_offset) } };
    };
    const pin = terminal.screens.active.pages.pin(point) orelse return null;
    return .{ .idx = idx, .pin = pin };
}

const GridCellHit = struct { col: c_int, row: c_int, visible_cols: c_int, visible_rows: c_int };

/// Pure pixel->cell mapping for one grid pane's content area. `rel_x`/`rel_y` are
/// mouse coords relative to the content origin (after padding). Cells are laid out
/// at the fixed native cell size, exactly as the renderer draws them — NOT stretched
/// to fill the drawable. `drawable_h` already has the cwd-bar strip removed.
fn gridCellAt(rel_x: c_int, rel_y: c_int, drawable_w: c_int, drawable_h: c_int, cell_w: c_int, cell_h: c_int, term_cols: c_int, term_rows: c_int) ?GridCellHit {
    if (rel_x < 0 or rel_y < 0 or cell_w <= 0 or cell_h <= 0) return null;
    const visible_cols: c_int = @min(term_cols, @divFloor(drawable_w, cell_w));
    const visible_rows: c_int = @min(term_rows, @divFloor(drawable_h, cell_h));
    if (visible_cols <= 0 or visible_rows <= 0) return null;
    return .{
        .col = @min(visible_cols - 1, @divFloor(rel_x, cell_w)),
        .row = @min(visible_rows - 1, @divFloor(rel_y, cell_h)),
        .visible_cols = visible_cols,
        .visible_rows = visible_rows,
    };
}

/// Map a grid-view mouse position to the (col,row) cell inside the hovered tile,
/// for forwarding a wheel scroll or click to a mouse-tracking program (the grid
/// analogue of fullViewCellFromMouse). Geometry mirrors
/// gridViewHitFromMouse / renderer.renderSessionContent (same padding + cwd-bar
/// reserved strip + native grid cell size).
fn gridTileCellFromMouse(
    host: *const types.UiHost,
    mouse_x: c_int,
    mouse_y: c_int,
    session_idx: usize,
    term_cols: u16,
    term_rows: u16,
) ?CellPosition {
    if (host.grid_cols == 0) return null;
    if (host.cell_w <= 0 or host.cell_h <= 0) return null;
    if (host.grid_cell_w <= 0 or host.grid_cell_h <= 0) return null;
    if (term_cols == 0 or term_rows == 0) return null;

    const gc = session_idx % host.grid_cols;
    const gr = session_idx / host.grid_cols;

    const padding = dpi.scale(renderer_mod.terminal_padding, host.ui_scale);
    const origin_x = @as(c_int, @intCast(gc)) * host.cell_w + padding;
    const origin_y = @as(c_int, @intCast(gr)) * host.cell_h + padding;
    const grid_reserved_h: c_int = if (host.cell_h >= cwd_bar_metrics.minCellHeight(host.ui_scale, renderer_mod.grid_border_thickness))
        cwd_bar_metrics.reservedHeight(host.ui_scale, renderer_mod.grid_border_thickness)
    else
        0;
    const drawable_w = host.cell_w - padding * 2;
    const drawable_h = host.cell_h - padding * 2 - grid_reserved_h;
    if (drawable_w <= 0 or drawable_h <= 0) return null;
    if (mouse_x < origin_x or mouse_y < origin_y) return null;

    const hit = gridCellAt(mouse_x - origin_x, mouse_y - origin_y, drawable_w, drawable_h, host.grid_cell_w, host.grid_cell_h, @intCast(term_cols), @intCast(term_rows)) orelse return null;
    return .{ .col = @intCast(hit.col), .row = @intCast(hit.row) };
}

fn isWordCharacter(codepoint: u21) bool {
    if (codepoint > 127) return false;
    const ch: u8 = @intCast(codepoint);
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Reads a terminal cell's codepoint while honoring `content_tag`. Only text
/// cells (`.codepoint` / `.codepoint_grapheme`) carry a real codepoint; palette
/// or RGB background cells and wide-char spacers store unrelated bits in the
/// `content` union, so reading `content.codepoint` for them yields garbage.
/// Mirrors the guard in `renderer.zig` so selection and URL detection never act
/// on non-text cells.
fn cellCodepoint(cell: anytype) u21 {
    return if (cell.content_tag == .codepoint or cell.content_tag == .codepoint_grapheme)
        cell.content.codepoint
    else
        0;
}

fn selectWord(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = &(session.terminal orelse return);
    const page = &pin.node.data;
    const max_col: u16 = @intCast(page.size.cols - 1);

    const pin_point = if (view.is_viewing_scrollback)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point = pin_point orelse return;
    const click_x = if (view.is_viewing_scrollback) point.viewport.x else point.active.x;
    const click_y = if (view.is_viewing_scrollback) point.viewport.y else point.active.y;

    const clicked_cell = terminal.screens.active.pages.getCell(
        if (view.is_viewing_scrollback)
            ghostty_vt.point.Point{ .viewport = .{ .x = click_x, .y = click_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = click_x, .y = click_y } },
    ) orelse return;
    const clicked_cp = cellCodepoint(clicked_cell.cell);
    if (!isWordCharacter(clicked_cp)) return;

    var start_x = click_x;
    while (start_x > 0) {
        const prev_x = start_x - 1;
        const prev_cell = terminal.screens.active.pages.getCell(
            if (view.is_viewing_scrollback)
                ghostty_vt.point.Point{ .viewport = .{ .x = prev_x, .y = click_y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = prev_x, .y = click_y } },
        ) orelse break;
        if (!isWordCharacter(cellCodepoint(prev_cell.cell))) break;
        start_x = prev_x;
    }

    var end_x = click_x;
    while (end_x < max_col) {
        const next_x = end_x + 1;
        const next_cell = terminal.screens.active.pages.getCell(
            if (view.is_viewing_scrollback)
                ghostty_vt.point.Point{ .viewport = .{ .x = next_x, .y = click_y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = next_x, .y = click_y } },
        ) orelse break;
        if (!isWordCharacter(cellCodepoint(next_cell.cell))) break;
        end_x = next_x;
    }

    const start_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = start_x, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = start_x, .y = click_y } };
    const end_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = end_x, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = end_x, .y = click_y } };

    const start_pin = terminal.screens.active.pages.pin(start_point) orelse return;
    const end_pin = terminal.screens.active.pages.pin(end_point) orelse return;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(start_pin, end_pin, false)) catch |err| {
        log.err("failed to select word: {}", .{err});
        return;
    };
    session.markDirty();
}

fn selectLine(session: *SessionState, view: *SessionViewState, pin: ghostty_vt.Pin) void {
    const terminal = &(session.terminal orelse return);
    const page = &pin.node.data;
    const max_col: u16 = @intCast(page.size.cols - 1);

    const pin_point = if (view.is_viewing_scrollback)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point = pin_point orelse return;
    const click_y = if (view.is_viewing_scrollback) point.viewport.y else point.active.y;

    const start_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = 0, .y = click_y } };
    const end_point = if (view.is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = max_col, .y = click_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = max_col, .y = click_y } };

    const start_pin = terminal.screens.active.pages.pin(start_point) orelse return;
    const end_pin = terminal.screens.active.pages.pin(end_point) orelse return;

    terminal.screens.active.clearSelection();
    terminal.screens.active.select(ghostty_vt.Selection.init(start_pin, end_pin, false)) catch |err| {
        log.err("failed to select line: {}", .{err});
        return;
    };
    session.markDirty();
}

const LinkMatch = struct {
    url: []u8,
    start_pin: ghostty_vt.Pin,
    end_pin: ghostty_vt.Pin,
};

fn getLinkMatchAtPin(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, pin: ghostty_vt.Pin, is_viewing_scrollback: bool, cwd: ?[]const u8) ?LinkMatch {
    const page = &pin.node.data;
    const row_and_cell = pin.rowAndCell();
    const cell = row_and_cell.cell;

    if (page.lookupHyperlink(cell)) |hyperlink_id| {
        const entry = page.hyperlink_set.get(page.memory, hyperlink_id);
        const url = resolveHyperlinkTarget(allocator, cwd, entry.uri.slice(page.memory)) orelse return null;
        return LinkMatch{
            .url = url,
            .start_pin = pin,
            .end_pin = pin,
        };
    }

    const pin_point = if (is_viewing_scrollback)
        terminal.screens.active.pages.pointFromPin(.viewport, pin)
    else
        terminal.screens.active.pages.pointFromPin(.active, pin);
    const point_or_null = pin_point orelse return null;
    const start_y_orig = if (is_viewing_scrollback) point_or_null.viewport.y else point_or_null.active.y;

    var start_y = start_y_orig;
    var current_row = row_and_cell.row;

    while (current_row.wrap_continuation and start_y > 0) {
        start_y -= 1;
        const prev_point = if (is_viewing_scrollback)
            ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = start_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = 0, .y = start_y } };
        const prev_pin = terminal.screens.active.pages.pin(prev_point) orelse break;
        current_row = prev_pin.rowAndCell().row;
    }

    var end_y = start_y_orig;
    current_row = row_and_cell.row;
    const max_y: u16 = @intCast(page.size.rows - 1);

    while (current_row.wrap and end_y < max_y) {
        end_y += 1;
        const next_point = if (is_viewing_scrollback)
            ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = end_y } }
        else
            ghostty_vt.point.Point{ .active = .{ .x = 0, .y = end_y } };
        const next_pin = terminal.screens.active.pages.pin(next_point) orelse break;
        current_row = next_pin.rowAndCell().row;
    }

    const max_x: u16 = @intCast(page.size.cols - 1);
    const row_start_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = 0, .y = start_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = 0, .y = start_y } };
    const row_end_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = max_x, .y = end_y } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = max_x, .y = end_y } };
    const row_start_pin = terminal.screens.active.pages.pin(row_start_point) orelse return null;
    const row_end_pin = terminal.screens.active.pages.pin(row_end_point) orelse return null;

    const selection = ghostty_vt.Selection.init(row_start_pin, row_end_pin, false);
    const row_text = terminal.screens.active.selectionString(allocator, .{
        .sel = selection,
        .trim = false,
    }) catch return null;
    defer allocator.free(row_text);

    var cell_to_byte: std.ArrayList(usize) = .empty;
    defer cell_to_byte.deinit(allocator);

    var byte_pos: usize = 0;
    var cell_idx: usize = 0;
    var y = start_y;
    while (y <= end_y) : (y += 1) {
        var x: u16 = 0;
        while (x < page.size.cols) : (x += 1) {
            const point = if (is_viewing_scrollback)
                ghostty_vt.point.Point{ .viewport = .{ .x = x, .y = y } }
            else
                ghostty_vt.point.Point{ .active = .{ .x = x, .y = y } };
            const list_cell = terminal.screens.active.pages.getCell(point) orelse {
                cell_to_byte.append(allocator, byte_pos) catch return null;
                cell_idx += 1;
                continue;
            };

            cell_to_byte.append(allocator, byte_pos) catch return null;

            const list_cell_cell = list_cell.cell;
            const cp = cellCodepoint(list_cell_cell);
            const encoded_len: usize = blk: {
                if (cp != 0 and cp != ' ') {
                    var utf8_buf: [4]u8 = undefined;
                    break :blk std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                }
                break :blk 1;
            };

            if (list_cell_cell.wide == .wide) {
                byte_pos += encoded_len;
                if (x + 1 < page.size.cols) {
                    x += 1;
                    const char_start_pos = cell_to_byte.items[cell_to_byte.items.len - 1];
                    cell_to_byte.append(allocator, char_start_pos) catch return null;
                    cell_idx += 1;
                }
            } else {
                byte_pos += encoded_len;
            }
            cell_idx += 1;
        }
        if (y < end_y) {
            byte_pos += 1;
        }
    }

    const pin_x = if (is_viewing_scrollback) point_or_null.viewport.x else point_or_null.active.x;
    const click_cell_idx = (start_y_orig - start_y) * page.size.cols + pin_x;
    if (click_cell_idx >= cell_to_byte.items.len) return null;
    const click_byte_pos = cell_to_byte.items[click_cell_idx];

    // Match a scheme URL first (http://, file://, ...); if none, fall back to a
    // bare filesystem path that exists relative to the pane's working directory.
    var match_start: usize = undefined;
    var match_end: usize = undefined;
    var url_slice: ?[]const u8 = null;
    var path_token: ?[]const u8 = null;
    if (url_matcher.findUrlMatchAtPosition(row_text, click_byte_pos)) |m| {
        match_start = m.start;
        match_end = m.end;
        url_slice = m.url;
    } else if (path_matcher.findPathMatchAtPosition(row_text, click_byte_pos)) |m| {
        match_start = m.start;
        match_end = m.end;
        path_token = m.path;
    } else {
        return null;
    }

    var start_cell_idx: usize = 0;
    for (cell_to_byte.items, 0..) |byte, idx| {
        if (byte >= match_start) {
            start_cell_idx = idx;
            break;
        }
    }

    var end_cell_idx: usize = cell_to_byte.items.len - 1;
    for (cell_to_byte.items, 0..) |byte, idx| {
        if (byte >= match_end) {
            end_cell_idx = if (idx > 0) idx - 1 else 0;
            break;
        }
    }

    const start_row = start_y + @as(u16, @intCast(start_cell_idx / page.size.cols));
    const start_col: u16 = @intCast(start_cell_idx % page.size.cols);
    const end_row = start_y + @as(u16, @intCast(end_cell_idx / page.size.cols));
    const end_col: u16 = @intCast(end_cell_idx % page.size.cols);

    const link_start_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = start_col, .y = start_row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = start_col, .y = start_row } };
    const link_end_point = if (is_viewing_scrollback)
        ghostty_vt.point.Point{ .viewport = .{ .x = end_col, .y = end_row } }
    else
        ghostty_vt.point.Point{ .active = .{ .x = end_col, .y = end_row } };
    const link_start_pin = terminal.screens.active.pages.pin(link_start_point) orelse return null;
    const link_end_pin = terminal.screens.active.pages.pin(link_end_point) orelse return null;

    // Build the owned target string. URLs are duped from the row text; bare
    // paths are resolved to an absolute path and must exist on disk.
    const url = if (url_slice) |s|
        allocator.dupe(u8, s) catch return null
    else
        resolveExistingPath(allocator, cwd, path_token.?) orelse return null;

    return LinkMatch{
        .url = url,
        .start_pin = link_start_pin,
        .end_pin = link_end_pin,
    };
}

/// Turn an OSC 8 URI into an openable target. Claude Code (and other CLIs)
/// emit cwd-relative targets like `docs/FOO.md` for local files; opened
/// verbatim, the opener resolves them against Cadre's own cwd and silently
/// fails. Scheme-less relative targets are resolved against the pane's cwd
/// (existing files only); everything else — scheme URLs, absolute paths, or a
/// relative path that doesn't resolve — passes through verbatim. Caller owns
/// the result.
fn resolveHyperlinkTarget(allocator: std.mem.Allocator, cwd: ?[]const u8, uri: []const u8) ?[]u8 {
    if (uri.len > 0 and uri[0] != '/' and std.mem.indexOf(u8, uri, "://") == null) {
        if (resolveExistingPath(allocator, cwd, uri)) |abs| return abs;
    }
    return allocator.dupe(u8, uri) catch |err| {
        log.warn("failed to dupe hyperlink target: {}", .{err});
        return null;
    };
}

/// Resolve a path token against the pane's working directory and return an
/// owned absolute path IFF it exists on disk. The existence check is what keeps
/// arbitrary path-ish text from being treated as an openable link. Relative
/// tokens need `cwd`; `~` expands to $HOME. Caller owns/frees the result.
fn resolveExistingPath(allocator: std.mem.Allocator, cwd: ?[]const u8, token: []const u8) ?[]u8 {
    if (token.len == 0) return null;

    const candidate: []u8 = if (token[0] == '/')
        (allocator.dupe(u8, token) catch return null)
    else if (token[0] == '~') blk: {
        const home = std.posix.getenv("HOME") orelse return null;
        if (token.len == 1) break :blk (allocator.dupe(u8, home) catch return null);
        const rest = if (token[1] == '/') token[2..] else token[1..];
        if (rest.len == 0) break :blk (allocator.dupe(u8, home) catch return null);
        break :blk std.fs.path.join(allocator, &.{ home, rest }) catch return null;
    } else blk: {
        const base = cwd orelse return null;
        break :blk std.fs.path.join(allocator, &.{ base, token }) catch return null;
    };

    // Absolute candidate; cwd().access handles absolute paths without asserting.
    std.fs.cwd().access(candidate, .{}) catch {
        allocator.free(candidate);
        return null;
    };
    return candidate;
}

test "resolveHyperlinkTarget - relative resolves against cwd, others pass verbatim" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("docs");
    try tmp.dir.writeFile(.{ .sub_path = "docs/guide.md", .data = "hi" });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    // Relative target that exists -> absolute path under cwd.
    const rel = resolveHyperlinkTarget(allocator, dir_path, "docs/guide.md") orelse return error.TestExpectedMatch;
    defer allocator.free(rel);
    try std.testing.expect(rel[0] == '/');
    try std.testing.expect(std.mem.endsWith(u8, rel, "docs/guide.md"));

    // Scheme URL -> verbatim, never resolved as a path.
    const url = resolveHyperlinkTarget(allocator, dir_path, "https://example.com/docs") orelse return error.TestExpectedMatch;
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://example.com/docs", url);

    // Absolute path -> verbatim.
    const abs = resolveHyperlinkTarget(allocator, dir_path, "/etc/hosts") orelse return error.TestExpectedMatch;
    defer allocator.free(abs);
    try std.testing.expectEqualStrings("/etc/hosts", abs);

    // Relative target that doesn't exist -> verbatim fallback.
    const miss = resolveHyperlinkTarget(allocator, dir_path, "docs/nope.md") orelse return error.TestExpectedMatch;
    defer allocator.free(miss);
    try std.testing.expectEqualStrings("docs/nope.md", miss);
}

test "resolveExistingPath - relative resolves against cwd; missing returns null" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hi" });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    // Existing relative path -> resolved absolute path.
    const ok = resolveExistingPath(allocator, dir_path, "hello.txt") orelse return error.TestExpectedMatch;
    defer allocator.free(ok);
    try std.testing.expect(std.mem.endsWith(u8, ok, "hello.txt"));

    // Non-existent file -> null (the existence filter).
    try std.testing.expect(resolveExistingPath(allocator, dir_path, "nope.txt") == null);

    // A relative token with no cwd cannot resolve.
    try std.testing.expect(resolveExistingPath(allocator, null, "hello.txt") == null);

    // An absolute path that exists resolves even without a cwd.
    const abs = resolveExistingPath(allocator, null, ok) orelse return error.TestExpectedMatch;
    defer allocator.free(abs);
    try std.testing.expectEqualStrings(ok, abs);
}

fn getLinkAtPin(allocator: std.mem.Allocator, terminal: *ghostty_vt.Terminal, pin: ghostty_vt.Pin, is_viewing_scrollback: bool, cwd: ?[]const u8) ?[]u8 {
    if (getLinkMatchAtPin(allocator, terminal, pin, is_viewing_scrollback, cwd)) |match| {
        return match.url;
    }
    return null;
}

fn scrollSession(session: *SessionState, view: *SessionViewState, delta: isize, now: i64) void {
    if (!session.spawned) return;

    view.last_scroll_time = now;
    view.scroll_remainder = 0.0;
    view.scroll_inertia_allowed = true;

    if (session.terminal) |*terminal| {
        var pages = &terminal.screens.active.pages;
        pages.scroll(.{ .delta_row = delta });
        view.is_viewing_scrollback = (pages.viewport != .active);
        view.terminal_scrollbar.noteActivity(now);
        session.markDirty();
    }

    const sensitivity: f32 = 0.08;
    view.scroll_velocity += @as(f32, @floatFromInt(delta)) * sensitivity;
    view.scroll_velocity = std.math.clamp(view.scroll_velocity, -max_scroll_velocity, max_scroll_velocity);
}

fn updateScrollInertia(session: *SessionState, view: *SessionViewState, delta_time_s: f32, now_ms: i64) void {
    if (!session.spawned) return;
    if (!view.scroll_inertia_allowed) return;
    if (view.scroll_velocity == 0.0) return;
    if (view.last_scroll_time == 0) return;

    const decay_constant: f32 = 7.5;
    const decay_factor = std.math.exp(-decay_constant * delta_time_s);
    const velocity_threshold: f32 = 0.12;

    if (@abs(view.scroll_velocity) < velocity_threshold) {
        view.scroll_velocity = 0.0;
        view.scroll_remainder = 0.0;
        return;
    }

    const reference_fps: f32 = 60.0;

    if (session.terminal) |*terminal| {
        const scroll_amount = view.scroll_velocity * delta_time_s * reference_fps + view.scroll_remainder;
        const scroll_lines: isize = @intFromFloat(scroll_amount);

        if (scroll_lines != 0) {
            var pages = &terminal.screens.active.pages;
            pages.scroll(.{ .delta_row = scroll_lines });
            view.is_viewing_scrollback = (pages.viewport != .active);
            view.terminal_scrollbar.noteActivity(now_ms);
            session.markDirty();
        }

        view.scroll_remainder = scroll_amount - @as(f32, @floatFromInt(scroll_lines));
    }

    view.scroll_velocity *= decay_factor;
}

fn calculateHoveredSession(
    mouse_x: c_int,
    mouse_y: c_int,
    host: *const types.UiHost,
) ?usize {
    return switch (host.view_mode) {
        .Grid, .GridResizing => {
            if (mouse_x < 0 or mouse_x >= host.window_w or
                mouse_y < 0 or mouse_y >= host.window_h) return null;

            const grid_col_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, host.cell_w))), host.grid_cols - 1);
            const grid_row_idx: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, host.cell_h))), host.grid_rows - 1);
            return grid_row_idx * host.grid_cols + grid_col_idx;
        },
        .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => host.focused_session,
        .Expanding, .Collapsing => {
            const rect = host.animating_rect orelse return host.focused_session;
            if (mouse_x >= rect.x and mouse_x < rect.x + rect.w and
                mouse_y >= rect.y and mouse_y < rect.y + rect.h)
            {
                return host.focused_session;
            }
            return null;
        },
    };
}

/// Grid for gesture purposes: .GridResizing is the grid mid-slide (reorder
/// commits flip to it for every animated re-slot), so grid gestures must keep
/// working through it — same equivalence calculateHoveredSession uses.
fn inGridView(mode: app_state.ViewMode) bool {
    return mode == .Grid or mode == .GridResizing;
}

fn visibleCount(sessions: []const *SessionState) usize {
    var n: usize = 0;
    for (sessions) |s| {
        if (s.isVisible()) n += 1;
    }
    return n;
}

/// Release/motion decision for an active drag: inside the window's render
/// area the gesture is a local reorder; outside it is a drag-out.
fn pointerInsideWindow(mouse_x: c_int, mouse_y: c_int, window_w: c_int, window_h: c_int) bool {
    return mouse_x >= 0 and mouse_y >= 0 and mouse_x < window_w and mouse_y < window_h;
}

fn leftButtonHeldGlobally() bool {
    var gx: f32 = 0;
    var gy: f32 = 0;
    return (c.SDL_GetGlobalMouseState(&gx, &gy) & c.SDL_BUTTON_LMASK) != 0;
}

test "pointerInsideWindow: inside is a reorder, outside is a drag-out" {
    try std.testing.expect(pointerInsideWindow(0, 0, 800, 600));
    try std.testing.expect(pointerInsideWindow(799, 599, 800, 600));
    try std.testing.expect(!pointerInsideWindow(800, 10, 800, 600));
    try std.testing.expect(!pointerInsideWindow(10, 600, 800, 600));
    try std.testing.expect(!pointerInsideWindow(-1, 10, 800, 600));
    try std.testing.expect(!pointerInsideWindow(10, -5, 800, 600));
}

test "dragAllowedFor: grid always, Full only for a lone terminal" {
    try std.testing.expect(dragAllowedFor(.Grid, 3));
    try std.testing.expect(dragAllowedFor(.GridResizing, 2));
    try std.testing.expect(dragAllowedFor(.Full, 1));
    try std.testing.expect(!dragAllowedFor(.Full, 2));
    try std.testing.expect(!dragAllowedFor(.Expanding, 1));
}

test "holdOutcome: release or travel forwards, time promotes, otherwise wait" {
    try std.testing.expectEqual(HoldOutcome.forward_now, holdOutcome(10, false, true));
    try std.testing.expectEqual(HoldOutcome.forward_now, holdOutcome(10, true, false));
    try std.testing.expectEqual(HoldOutcome.forward_now, holdOutcome(reorder_hold_ms + 50, true, false));
    try std.testing.expectEqual(HoldOutcome.promote, holdOutcome(reorder_hold_ms, false, false));
    try std.testing.expectEqual(HoldOutcome.wait, holdOutcome(reorder_hold_ms - 1, false, false));
}

/// True when the pointer has traveled past the reorder slop — the press is a
/// text-selection drag, not a hold.
fn reorderPressMoved(dx: f32, dy: f32) bool {
    return dx * dx + dy * dy > reorder_drag_slop_px * reorder_drag_slop_px;
}

/// Slot the dragged tile should re-slot into, or null. Only fires when the
/// pointer is inside the inner half-size box around a tile's center — entering
/// the center zone is the trigger, so jitter on a tile boundary can never
/// flicker tiles back and forth — and only for slots holding a visible tile.
fn reorderTargetSlot(
    mouse_x: c_int,
    mouse_y: c_int,
    grid_cols: usize,
    grid_rows: usize,
    cell_w: c_int,
    cell_h: c_int,
    visible_count: usize,
) ?usize {
    if (cell_w <= 0 or cell_h <= 0 or grid_cols == 0 or grid_rows == 0) return null;
    if (mouse_x < 0 or mouse_y < 0) return null;
    const col: usize = @min(@as(usize, @intCast(@divFloor(mouse_x, cell_w))), grid_cols - 1);
    const row: usize = @min(@as(usize, @intCast(@divFloor(mouse_y, cell_h))), grid_rows - 1);
    const slot: usize = row * grid_cols + col;
    if (slot >= visible_count) return null;
    // Inner 50% box: within a quarter cell of the center on both axes.
    const local_x = mouse_x - @as(c_int, @intCast(col)) * cell_w;
    const local_y = mouse_y - @as(c_int, @intCast(row)) * cell_h;
    if (@abs(local_x - @divTrunc(cell_w, 2)) > @divTrunc(cell_w, 4)) return null;
    if (@abs(local_y - @divTrunc(cell_h, 2)) > @divTrunc(cell_h, 4)) return null;
    return slot;
}

fn sessionRectForIndex(host: *const types.UiHost, idx: usize) ?geom.Rect {
    return switch (host.view_mode) {
        .Grid, .GridResizing => {
            const max_slots = host.grid_cols * host.grid_rows;
            if (idx >= max_slots) return null;
            const grid_col: c_int = @intCast(idx % host.grid_cols);
            const grid_row: c_int = @intCast(idx / host.grid_cols);
            return .{
                .x = grid_col * host.cell_w,
                .y = grid_row * host.cell_h,
                .w = host.cell_w,
                .h = host.cell_h,
            };
        },
        .Full, .PanningLeft, .PanningRight, .PanningUp, .PanningDown => {
            if (idx != host.focused_session) return null;
            return .{ .x = 0, .y = 0, .w = host.window_w, .h = host.window_h };
        },
        .Expanding, .Collapsing => {
            if (idx != host.focused_session) return null;
            return host.animating_rect orelse geom.Rect{ .x = 0, .y = 0, .w = host.window_w, .h = host.window_h };
        },
    };
}

fn terminalContentRect(session_rect: geom.Rect, ui_scale: f32) ?geom.Rect {
    const padding = dpi.scale(renderer_mod.terminal_padding, ui_scale);
    const w = session_rect.w - padding * 2;
    const h = session_rect.h - padding * 2;
    if (w <= 0 or h <= 0) return null;
    return .{
        .x = session_rect.x + padding,
        .y = session_rect.y + padding,
        .w = w,
        .h = h,
    };
}

const testing = std.testing;

test "reorderTargetSlot fires only in a tile's center zone, only on visible slots" {
    // 2x2 grid of 100x100 cells. Tile 1 spans x 100..200; its inner box is
    // x 125..175, y 25..75.
    try testing.expectEqual(@as(?usize, 1), reorderTargetSlot(150, 50, 2, 2, 100, 100, 4));
    try testing.expectEqual(@as(?usize, 1), reorderTargetSlot(126, 30, 2, 2, 100, 100, 4));
    // Jitter on the tile 0/1 boundary lands in neither center zone.
    try testing.expectEqual(@as(?usize, null), reorderTargetSlot(101, 50, 2, 2, 100, 100, 4));
    try testing.expectEqual(@as(?usize, null), reorderTargetSlot(99, 50, 2, 2, 100, 100, 4));
    // The center of an empty slot (3 visible in a 2x2 grid) is inert; a
    // visible slot's center works.
    try testing.expectEqual(@as(?usize, null), reorderTargetSlot(150, 150, 2, 2, 100, 100, 3));
    try testing.expectEqual(@as(?usize, 2), reorderTargetSlot(50, 150, 2, 2, 100, 100, 3));
    // Off-window and beyond-grid pointers never re-slot.
    try testing.expectEqual(@as(?usize, null), reorderTargetSlot(-5, 50, 2, 2, 100, 100, 4));
    try testing.expectEqual(@as(?usize, null), reorderTargetSlot(500, 50, 2, 2, 100, 100, 4));
}

test "reorderPressMoved triggers strictly past the slop radius" {
    try testing.expect(!reorderPressMoved(0, 0));
    try testing.expect(!reorderPressMoved(reorder_drag_slop_px, 0));
    try testing.expect(reorderPressMoved(reorder_drag_slop_px + 0.1, 0));
    try testing.expect(reorderPressMoved(5, 5));
}

test "triggerNavWave sets nav_wave_start_time without touching attention or status" {
    var view = view_state.SessionViewState{};
    view.attention = false;
    view.status = .running;
    view.nav_wave_start_time = 0;

    view.nav_wave_start_time = 1000;

    try testing.expectEqual(@as(i64, 1000), view.nav_wave_start_time);
    try testing.expectEqual(false, view.attention);
    try testing.expectEqual(app_state.SessionStatus.running, view.status);
}

test "fresh views are idle with no Claude history or hosting flag" {
    const view = view_state.SessionViewState{};
    try testing.expectEqual(app_state.SessionStatus.idle, view.status);
    try testing.expect(!view.claude_seen);
    try testing.expect(!view.hosting);
}

test "applyClaudeStatus records claude_seen and reports visible changes" {
    var view = view_state.SessionViewState{};
    // First status: marks claude_seen and changes the visible status.
    try testing.expect(view.applyClaudeStatus(.running));
    try testing.expect(view.claude_seen);
    try testing.expectEqual(app_state.SessionStatus.running, view.status);
    // Re-applying the same status is not a visible change, but claude_seen stays.
    try testing.expect(!view.applyClaudeStatus(.running));
    try testing.expect(view.claude_seen);
}

test "acknowledgeAttention demotes done and needs-you, leaving other statuses untouched" {
    var view = view_state.SessionViewState{};
    // Running is never demoted by an acknowledge.
    view.status = .running;
    try testing.expect(!view.acknowledgeAttention());
    try testing.expectEqual(app_state.SessionStatus.running, view.status);
    // A done status is acknowledged back to idle exactly once.
    view.status = .done;
    try testing.expect(view.acknowledgeAttention());
    try testing.expectEqual(app_state.SessionStatus.idle, view.status);
    try testing.expect(!view.acknowledgeAttention());
    // "Needs you" is sticky the same way: looking at the terminal clears it,
    // so it can't outlive an agent that exited without sending another state.
    view.status = .awaiting_approval;
    try testing.expect(view.acknowledgeAttention());
    try testing.expectEqual(app_state.SessionStatus.idle, view.status);
}

test "approval_pending survives acknowledgeAttention until Claude's next status" {
    var view = view_state.SessionViewState{};
    _ = view.applyClaudeStatus(.awaiting_approval);
    try testing.expect(view.approval_pending);
    // Switching to the pane demotes the badge but Claude is still waiting.
    try testing.expect(view.acknowledgeAttention());
    try testing.expect(view.approval_pending);
    // Answering resumes Claude; its next hook status clears it.
    _ = view.applyClaudeStatus(.running);
    try testing.expect(!view.approval_pending);
}

test "setAttention does not affect nav_wave_start_time" {
    var view = view_state.SessionViewState{};
    view.nav_wave_start_time = 500;

    view.attention = true;
    view.wave_start_time = 1000;

    try testing.expectEqual(@as(i64, 500), view.nav_wave_start_time);
}

test "nav_wave_amplitude is smaller than wave_amplitude" {
    try testing.expect(nav_wave_amplitude < wave_amplitude);
}

test "gridClickOutcome: single click selects a different pane, no-ops the focused one" {
    // Single click on a different pane -> move the highlight (select).
    try testing.expectEqual(GridClickOutcome.select, gridClickOutcome(1, 3, 0, 4));
    // Single click on the already-focused pane -> nothing (no spawn, no zoom).
    try testing.expectEqual(GridClickOutcome.none, gridClickOutcome(1, 2, 2, 4));
}

test "gridClickOutcome: double-click focuses (zooms) regardless of current focus" {
    // Double-click on a different pane -> zoom it.
    try testing.expectEqual(GridClickOutcome.focus, gridClickOutcome(2, 3, 0, 4));
    // Double-click on the already-focused pane -> still zoom (expand it).
    try testing.expectEqual(GridClickOutcome.focus, gridClickOutcome(2, 1, 1, 4));
    // Triple-click (clicks > 2) still resolves to focus.
    try testing.expectEqual(GridClickOutcome.focus, gridClickOutcome(3, 4, 0, 4));
}

test "gridClickOutcome: single open window cannot be double-clicked into focus" {
    // 1x1 grid (one window, possibly with hidden ones) -> double-click is a no-op
    // on the focused pane, never a zoom.
    try testing.expectEqual(GridClickOutcome.none, gridClickOutcome(2, 0, 0, 1));
    try testing.expectEqual(GridClickOutcome.none, gridClickOutcome(3, 0, 0, 1));
}

test "forwardMouseToProgram: Shift bypasses mouse reporting so drag-select stays local" {
    // No tracking -> always local (a plain shell prompt).
    try testing.expect(!forwardMouseToProgram(false, false, false));
    // Program grabs the mouse, no Shift -> forward to it (normal mouse mode).
    try testing.expect(forwardMouseToProgram(true, false, false));
    // Program grabs the mouse, Shift held -> stay local so Cmd+C has a selection.
    try testing.expect(!forwardMouseToProgram(true, false, true));
    // Viewing scrollback -> always local, no live program owns it.
    try testing.expect(!forwardMouseToProgram(true, true, false));
}

test "cellCodepoint honors content_tag for text and non-text cells" {
    const MockTag = enum { codepoint, codepoint_grapheme, bg_color_palette, bg_color_rgb };
    const MockContent = union {
        codepoint: u21,
        color_palette: u8,
    };
    const MockCell = struct {
        content_tag: MockTag,
        content: MockContent,
    };

    // Text cells expose their codepoint, including grapheme bases.
    try testing.expectEqual(@as(u21, 'a'), cellCodepoint(MockCell{
        .content_tag = .codepoint,
        .content = .{ .codepoint = 'a' },
    }));
    try testing.expectEqual(@as(u21, 0x1F600), cellCodepoint(MockCell{
        .content_tag = .codepoint_grapheme,
        .content = .{ .codepoint = 0x1F600 },
    }));

    // Palette/RGB background cells carry unrelated bits in the union; they must
    // read as 0 instead of garbage so selection and URL detection ignore them.
    try testing.expectEqual(@as(u21, 0), cellCodepoint(MockCell{
        .content_tag = .bg_color_palette,
        .content = .{ .color_palette = 7 },
    }));
    try testing.expectEqual(@as(u21, 0), cellCodepoint(MockCell{
        .content_tag = .bg_color_rgb,
        .content = .{ .color_palette = 0xFF },
    }));
}

test "encodeClick: press then release at the 1-based cell" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;5;3M\x1b[<0;5;3m", encodeClick(4, 2, true, &buf));
}

test "gridCellAt maps by fixed cell size, not proportional stretch" {
    // 12x16 px cells, 30x20 terminal, content area 200x100 px (cwd bar already
    // removed). Only 8 rows / 16 cols actually fit and get drawn.
    const cw = 12;
    const ch = 16;

    const mid = gridCellAt(50, 40, 200, 100, cw, ch, 30, 20) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(c_int, 16), mid.visible_cols); // 200/12
    try std.testing.expectEqual(@as(c_int, 6), mid.visible_rows); //  100/16
    try std.testing.expectEqual(@as(c_int, 4), mid.col); // 50/12
    try std.testing.expectEqual(@as(c_int, 2), mid.row); // 40/16

    // Fixed-cell, not stretched: y in [16,32) is row 1. A proportional mapping
    // (rel_y*visible_rows/drawable_h) would have put this click on row 0 — the
    // off-by-one-row bug this guards against.
    try std.testing.expectEqual(@as(c_int, 1), gridCellAt(0, 16, 200, 100, cw, ch, 30, 20).?.row);
    try std.testing.expectEqual(@as(c_int, 0), gridCellAt(0, 15, 200, 100, cw, ch, 30, 20).?.row);

    // Past the last visible cell clamps to the last drawn row/col, never beyond.
    const far = gridCellAt(9999, 9999, 200, 100, cw, ch, 30, 20) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(c_int, 5), far.row);
    try std.testing.expectEqual(@as(c_int, 15), far.col);

    // Degenerate inputs are rejected.
    try std.testing.expect(gridCellAt(-1, 0, 200, 100, cw, ch, 30, 20) == null);
    try std.testing.expect(gridCellAt(0, 0, 200, 100, 0, ch, 30, 20) == null);
}
