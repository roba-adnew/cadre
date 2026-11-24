// Quick entry: a prompt box in the middle of the window, opened from any app
// with a double tap of Option (platform/macos_hotkey.zig).
//
// While the box is up, the runtime boots Claude in a terminal kept out of the
// grid (Window.openQuickEntry), so Claude is ready, or nearly, by the time the
// text is written. Enter hands the text to the runtime
// (UiAction.QuickEntrySubmit), which shows that terminal and pastes the text
// into Claude as soon as its input box is up. Esc drops the box and the
// terminal (UiAction.QuickEntryCancel).
//
// The text field is the composer's AppKit view (composer_view.zig), for the
// same reasons: dictation, paste, IME, real Mac editing. The card around it
// and the caption under it are drawn here.

const std = @import("std");
const c = @import("../../c.zig");
const colors = @import("../../colors.zig");
const dpi = @import("../../dpi.zig");
const geom = @import("../../geom.zig");
const primitives = @import("../../gfx/primitives.zig");
const types = @import("../types.zig");
const UiComponent = @import("../component.zig").UiComponent;
const FirstFrameGuard = @import("../first_frame_guard.zig").FirstFrameGuard;
const composer = @import("composer.zig");
const view_mod = @import("composer_view.zig");
const search_utils = @import("search_utils.zig");

const log = std.log.scoped(.quick_entry);

const ComposerView = view_mod.ComposerView;
const Rect = geom.Rect;

/// Above every overlay (the highest is the story viewer's 1200), below the
/// confirm and quit dialogs.
const z_index: i32 = 1500;
const font_pt: f64 = 15;
const card_width_pt: c_int = 680;
const card_margin_pt: c_int = 24;
const card_radius_pt: c_int = 12;
const pad_pt: c_int = 14;
const caption_h_pt: c_int = 30;
const caption_font_pt: c_int = 13;
/// The field grows with the text between these, then scrolls.
const min_field_pt: c_int = 40;
const max_field_pt: c_int = 240;
/// How far down the window the card's top edge sits.
const top_fraction: f32 = 0.22;
const scrim_alpha: u8 = 120;

const hint_text = "return to send  \u{00B7}  esc to cancel";

/// The card: centred across the window, its top edge a fixed way down, as
/// tall as a field of `content_h` pixels of text needs.
pub fn cardRect(window_w: c_int, window_h: c_int, ui_scale: f32, content_h: c_int) Rect {
    const margin = dpi.scale(card_margin_pt, ui_scale);
    const w = @max(0, @min(dpi.scale(card_width_pt, ui_scale), window_w - margin * 2));
    const field_h = std.math.clamp(content_h, dpi.scale(min_field_pt, ui_scale), dpi.scale(max_field_pt, ui_scale));
    return .{
        .x = @divFloor(window_w - w, 2),
        .y = @intFromFloat(@as(f32, @floatFromInt(window_h)) * top_fraction),
        .w = w,
        .h = dpi.scale(pad_pt, ui_scale) + field_h + dpi.scale(caption_h_pt, ui_scale),
    };
}

/// The text field inside `card`: everything above the caption row.
pub fn fieldRect(card: Rect, ui_scale: f32) Rect {
    const pad = dpi.scale(pad_pt, ui_scale);
    return .{
        .x = card.x + pad,
        .y = card.y + pad,
        .w = @max(0, card.w - pad * 2),
        .h = @max(0, card.h - pad - dpi.scale(caption_h_pt, ui_scale)),
    };
}

pub const KeyAction = union(enum) {
    cancel,
    submit,
    /// There is no Edit menu, so these reach the text view from here.
    edit: view_mod.Edit,
    /// The text view's own business (typing, arrows, a new line).
    text,
};

/// What a key press does while the box is up. `composing`: an input method or
/// dictation holds marked text, so Return and Esc are its to take.
pub fn keyAction(key: c.SDL_Keycode, mod: c.SDL_Keymod, composing: bool) KeyAction {
    const gui = (mod & c.SDL_KMOD_GUI) != 0;
    const ctrl = (mod & c.SDL_KMOD_CTRL) != 0;
    const alt = (mod & c.SDL_KMOD_ALT) != 0;
    const shift = (mod & c.SDL_KMOD_SHIFT) != 0;

    if (composing) return .text;
    if (key == c.SDLK_ESCAPE) return .cancel;
    if (key == c.SDLK_RETURN or key == c.SDLK_KP_ENTER) return if (shift or alt or ctrl) .text else .submit;
    if (gui and !ctrl and !alt) return switch (key) {
        c.SDLK_A => .{ .edit = .select_all },
        c.SDLK_C => .{ .edit = .copy },
        c.SDLK_X => .{ .edit = .cut },
        c.SDLK_V => .{ .edit = .paste },
        c.SDLK_Z => .{ .edit = if (shift) .redo else .undo },
        else => .text,
    };
    return .text;
}

pub const QuickEntryComponent = struct {
    allocator: std.mem.Allocator,
    window: *c.SDL_Window,
    /// Made the first time the box opens.
    view: ?ComposerView = null,
    open: bool = false,
    /// The text view is on screen at its place (from the first update on).
    placed: bool = false,
    /// Claude's input box is up in the terminal started for this entry.
    ready: bool = false,
    /// Folder that terminal runs in, for the caption. Borrowed.
    place: []const u8 = "",
    /// Esc closed the box; its key-up must not reach the terminal under it.
    escape_down: bool = false,
    content_h: c_int = 0,
    theme_key: ?[2]c.SDL_Color = null,
    status_tex: ?search_utils.TextTex = null,
    hint_tex: ?search_utils.TextTex = null,
    caption_key: ?CaptionKey = null,
    first_frame: FirstFrameGuard = .{},

    const CaptionKey = struct { ready: bool, px: c_int, font_generation: u64, color: c.SDL_Color };

    pub fn init(allocator: std.mem.Allocator, window: *c.SDL_Window) !*QuickEntryComponent {
        const self = try allocator.create(QuickEntryComponent);
        self.* = .{ .allocator = allocator, .window = window };
        return self;
    }

    pub fn asComponent(self: *QuickEntryComponent) UiComponent {
        return .{ .ptr = self, .vtable = &vtable, .z_index = z_index };
    }

    const vtable = UiComponent.VTable{
        .handleEvent = handleEventFn,
        .update = updateFn,
        .render = renderFn,
        .hitTest = hitTestFn,
        .deinit = deinitFn,
        .wantsFrame = wantsFrameFn,
    };

    /// Open the box, empty, for a Claude starting in `place`. False when there
    /// is no native text view to type into (off macOS).
    pub fn show(self: *QuickEntryComponent, place: []const u8) bool {
        if (self.view == null) self.view = ComposerView.create(self.window, font_pt);
        const view = &(self.view orelse {
            log.warn("quick entry text view unavailable", .{});
            return false;
        });
        view.setText(self.allocator, "");
        self.open = true;
        self.placed = false;
        self.ready = false;
        self.place = place;
        self.caption_key = null; // names `place`
        self.escape_down = false;
        self.content_h = 0;
        self.first_frame.markTransition();
        log.info("quick entry opened", .{});
        return true;
    }

    pub fn close(self: *QuickEntryComponent) void {
        if (!self.open) return;
        self.open = false;
        self.first_frame.markTransition();
        log.info("quick entry closed", .{});
        const view = &(self.view orelse return);
        view.setHidden(true);
        view.setText(self.allocator, "");
        view.unfocus();
        // The keyboard goes back to the terminal. Stop first so Start re-creates
        // SDL's field and makes it first responder.
        _ = c.SDL_StopTextInput(self.window);
        _ = c.SDL_StartTextInput(self.window);
    }

    pub fn setReady(self: *QuickEntryComponent, ready: bool) void {
        if (ready == self.ready) return;
        self.ready = ready;
        if (self.open) self.first_frame.markTransition();
    }

    fn handleEventFn(ptr: *anyopaque, _: *const types.UiHost, event: *const c.SDL_Event, out: *types.UiActionQueue) bool {
        const self: *QuickEntryComponent = @ptrCast(@alignCast(ptr));
        if (event.type == c.SDL_EVENT_KEY_UP and self.escape_down and event.key.key == c.SDLK_ESCAPE) {
            self.escape_down = false;
            return true;
        }
        if (!self.open) return false;
        switch (event.type) {
            c.SDL_EVENT_KEY_DOWN => {
                const view = &(self.view orelse return true);
                switch (keyAction(event.key.key, event.key.mod, view.hasMarkedText())) {
                    .cancel => {
                        self.escape_down = true;
                        self.close();
                        out.append(.QuickEntryCancel) catch |err| {
                            log.warn("failed to queue quick entry cancel: {}", .{err});
                        };
                    },
                    .submit => self.submit(view, out),
                    .edit => |edit| view.perform(edit),
                    .text => {},
                }
                return true;
            },
            // Modal: nothing typed or clicked reaches what is under the box.
            c.SDL_EVENT_KEY_UP,
            c.SDL_EVENT_TEXT_INPUT,
            c.SDL_EVENT_TEXT_EDITING,
            c.SDL_EVENT_MOUSE_BUTTON_DOWN,
            c.SDL_EVENT_MOUSE_BUTTON_UP,
            c.SDL_EVENT_MOUSE_MOTION,
            c.SDL_EVENT_MOUSE_WHEEL,
            => return true,
            else => return false,
        }
    }

    fn submit(self: *QuickEntryComponent, view: *ComposerView, out: *types.UiActionQueue) void {
        const raw = view.copyText(self.allocator) catch |err| {
            log.warn("failed to read quick entry text: {}", .{err});
            return;
        };
        defer self.allocator.free(raw);
        const text = (composer.normalizeSubmitText(self.allocator, raw) catch |err| {
            log.warn("failed to prepare quick entry text: {}", .{err});
            return;
        }) orelse return; // nothing written yet: the box stays up
        log.info("quick entry submit: {d} bytes", .{text.len});
        out.append(.{ .QuickEntrySubmit = .{ .text = text } }) catch |err| {
            log.warn("failed to queue quick entry submit: {}", .{err});
            self.allocator.free(text);
            return;
        };
        self.close();
    }

    fn updateFn(ptr: *anyopaque, host: *const types.UiHost, _: *types.UiActionQueue) void {
        const self: *QuickEntryComponent = @ptrCast(@alignCast(ptr));
        if (!self.open) return;
        const view = &(self.view orelse return);

        self.applyTheme(view, host.theme);
        // The width first: how tall the text is depends on where it wraps.
        view.setFrame(fieldRect(cardRect(host.window_w, host.window_h, host.ui_scale, self.content_h), host.ui_scale), host.window_w, host.window_h);
        const content_h = view.contentHeightPx(host.window_h);
        if (content_h != self.content_h) {
            self.content_h = content_h;
            self.first_frame.markTransition();
            view.setFrame(fieldRect(cardRect(host.window_w, host.window_h, host.ui_scale, content_h), host.ui_scale), host.window_w, host.window_h);
        }
        if (!self.placed) {
            self.placed = true;
            view.setHidden(false);
        }
        // Coming to the front, the runtime turns SDL text input back on, which
        // makes SDL's own field first responder; so does the composer when it
        // hides under this box.
        if (!view.isFocused() or c.SDL_TextInputActive(self.window)) {
            _ = c.SDL_StopTextInput(self.window);
            view.focus();
        }
    }

    fn applyTheme(self: *QuickEntryComponent, view: *ComposerView, theme: *const colors.Theme) void {
        const bg = theme.surface(1);
        const key = [2]c.SDL_Color{ bg, theme.foreground };
        if (self.theme_key) |prev| {
            if (std.meta.eql(prev, key)) return;
        }
        self.theme_key = key;
        view.setColors(
            .{ .r = bg.r, .g = bg.g, .b = bg.b },
            .{ .r = theme.foreground.r, .g = theme.foreground.g, .b = theme.foreground.b },
            .{ .r = theme.accent.r, .g = theme.accent.g, .b = theme.accent.b },
        );
    }

    fn renderFn(ptr: *anyopaque, host: *const types.UiHost, renderer: *c.SDL_Renderer, assets: *types.UiAssets) void {
        const self: *QuickEntryComponent = @ptrCast(@alignCast(ptr));
        defer self.first_frame.markDrawn();
        if (!self.open) return;
        const theme = host.theme;

        _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
        const scrim = theme.scrim(scrim_alpha);
        _ = c.SDL_SetRenderDrawColor(renderer, scrim.r, scrim.g, scrim.b, scrim.a);
        _ = c.SDL_RenderFillRect(renderer, &c.SDL_FRect{ .x = 0, .y = 0, .w = @floatFromInt(host.window_w), .h = @floatFromInt(host.window_h) });

        const card = cardRect(host.window_w, host.window_h, host.ui_scale, self.content_h);
        const radius = dpi.scale(card_radius_pt, host.ui_scale);
        const bg = theme.surface(1);
        _ = c.SDL_SetRenderDrawColor(renderer, bg.r, bg.g, bg.b, 255);
        primitives.fillRoundedRect(renderer, card, radius);
        const border = theme.chromeBorder();
        _ = c.SDL_SetRenderDrawColor(renderer, border.r, border.g, border.b, 255);
        primitives.drawRoundedBorder(renderer, card, radius);

        self.ensureCaption(renderer, host, assets);
        const pad = dpi.scale(pad_pt, host.ui_scale);
        const caption_h = dpi.scale(caption_h_pt, host.ui_scale);
        const caption_y = card.y + card.h - caption_h;
        if (self.status_tex) |tex| drawText(renderer, tex, card.x + pad, caption_y + @divFloor(caption_h - tex.h, 2));
        // The hint gives way when the card is too narrow for both.
        if (self.hint_tex) |tex| {
            const status_w = if (self.status_tex) |status| status.w else 0;
            const x = card.x + card.w - pad - tex.w;
            if (x >= card.x + pad + status_w + pad) drawText(renderer, tex, x, caption_y + @divFloor(caption_h - tex.h, 2));
        }
    }

    fn drawText(renderer: *c.SDL_Renderer, tex: search_utils.TextTex, x: c_int, y: c_int) void {
        _ = c.SDL_RenderTexture(renderer, tex.tex, null, &c.SDL_FRect{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .w = @floatFromInt(tex.w),
            .h = @floatFromInt(tex.h),
        });
    }

    /// The caption: where Claude is starting and whether it is up yet, and
    /// what the keys do.
    fn ensureCaption(self: *QuickEntryComponent, renderer: *c.SDL_Renderer, host: *const types.UiHost, assets: *types.UiAssets) void {
        const cache = assets.font_cache orelse return;
        const color = host.theme.chromeTextDim();
        const key = CaptionKey{
            .ready = self.ready,
            .px = dpi.scale(caption_font_pt, host.ui_scale),
            .font_generation = cache.generation,
            .color = color,
        };
        if (self.caption_key) |prev| {
            if (std.meta.eql(prev, key)) return;
        }
        self.caption_key = key;
        self.dropCaption();
        const fonts = cache.get(key.px) catch |err| {
            log.warn("no font for the quick entry caption: {}", .{err});
            return;
        };
        const state = if (self.ready) "Claude is ready" else "starting Claude\u{2026}";
        var buf: [192]u8 = undefined;
        const status = std.fmt.bufPrint(&buf, "{s}  \u{00B7}  {s}", .{ self.place, state }) catch |err| blk: {
            log.warn("quick entry caption left out the folder: {}", .{err});
            break :blk state;
        };
        self.status_tex = search_utils.makeTextTexture(self.allocator, renderer, fonts.regular, status, color) catch |err| blk: {
            log.warn("failed to draw the quick entry caption: {}", .{err});
            break :blk null;
        };
        self.hint_tex = search_utils.makeTextTexture(self.allocator, renderer, fonts.regular, hint_text, color) catch |err| blk: {
            log.warn("failed to draw the quick entry hint: {}", .{err});
            break :blk null;
        };
    }

    fn dropCaption(self: *QuickEntryComponent) void {
        if (self.status_tex) |tex| c.SDL_DestroyTexture(tex.tex);
        if (self.hint_tex) |tex| c.SDL_DestroyTexture(tex.tex);
        self.status_tex = null;
        self.hint_tex = null;
    }

    fn hitTestFn(ptr: *anyopaque, _: *const types.UiHost, _: c_int, _: c_int) bool {
        const self: *QuickEntryComponent = @ptrCast(@alignCast(ptr));
        return self.open;
    }

    fn wantsFrameFn(ptr: *anyopaque, _: *const types.UiHost) bool {
        const self: *QuickEntryComponent = @ptrCast(@alignCast(ptr));
        return self.first_frame.wantsFrame();
    }

    fn deinitFn(ptr: *anyopaque, _: *c.SDL_Renderer) void {
        const self: *QuickEntryComponent = @ptrCast(@alignCast(ptr));
        self.dropCaption();
        if (self.view) |*view| view.destroy();
        self.allocator.destroy(self);
    }
};

const testing = std.testing;

test "keyAction: Return sends, Esc cancels, a modified Return is a new line" {
    try testing.expectEqual(KeyAction.submit, keyAction(c.SDLK_RETURN, 0, false));
    try testing.expectEqual(KeyAction.submit, keyAction(c.SDLK_KP_ENTER, 0, false));
    try testing.expectEqual(KeyAction.submit, keyAction(c.SDLK_RETURN, c.SDL_KMOD_GUI, false));
    try testing.expectEqual(KeyAction.text, keyAction(c.SDLK_RETURN, c.SDL_KMOD_SHIFT, false));
    try testing.expectEqual(KeyAction.text, keyAction(c.SDLK_RETURN, c.SDL_KMOD_ALT, false));
    try testing.expectEqual(KeyAction.cancel, keyAction(c.SDLK_ESCAPE, 0, false));
    try testing.expectEqual(KeyAction.text, keyAction(c.SDLK_A, 0, false));
}

test "keyAction: an input method keeps Return and Esc while it is composing" {
    try testing.expectEqual(KeyAction.text, keyAction(c.SDLK_RETURN, 0, true));
    try testing.expectEqual(KeyAction.text, keyAction(c.SDLK_ESCAPE, 0, true));
}

test "keyAction: the Cmd editing keys reach the text view" {
    try testing.expectEqual(KeyAction{ .edit = .paste }, keyAction(c.SDLK_V, c.SDL_KMOD_GUI, false));
    try testing.expectEqual(KeyAction{ .edit = .select_all }, keyAction(c.SDLK_A, c.SDL_KMOD_GUI, false));
    try testing.expectEqual(KeyAction{ .edit = .undo }, keyAction(c.SDLK_Z, c.SDL_KMOD_GUI, false));
    try testing.expectEqual(KeyAction{ .edit = .redo }, keyAction(c.SDLK_Z, c.SDL_KMOD_GUI | c.SDL_KMOD_SHIFT, false));
    // Cadre's own shortcuts do nothing while the box is up.
    try testing.expectEqual(KeyAction.text, keyAction(c.SDLK_W, c.SDL_KMOD_GUI, false));
}

test "the card is centred, grows with the text up to a limit, and fits a narrow window" {
    const empty = cardRect(1600, 1000, 1.0, 0);
    try testing.expectEqual(@as(c_int, card_width_pt), empty.w);
    try testing.expectEqual(@divFloor(1600 - empty.w, 2), empty.x);
    try testing.expectEqual(@as(c_int, pad_pt + min_field_pt + caption_h_pt), empty.h);

    const some = cardRect(1600, 1000, 1.0, 100);
    try testing.expectEqual(empty.y, some.y);
    try testing.expectEqual(@as(c_int, 100), fieldRect(some, 1.0).h);

    const long = cardRect(1600, 1000, 1.0, 5000);
    try testing.expectEqual(@as(c_int, max_field_pt), fieldRect(long, 1.0).h);

    const narrow = cardRect(400, 1000, 1.0, 0);
    try testing.expectEqual(@as(c_int, 400 - card_margin_pt * 2), narrow.w);
    try testing.expect(fieldRect(narrow, 1.0).w > 0);

    // Retina: twice the pixels, the same share of the window.
    const retina = cardRect(3200, 2000, 2.0, 0);
    try testing.expectEqual(empty.w * 2, retina.w);
    try testing.expectEqual(empty.y * 2, retina.y);
}
