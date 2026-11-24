// Quick entry's box: a small floating panel of its own, near the bottom of
// the screen the pointer is on, over whatever app the user is in.
//
// It is a non-activating NSPanel: it takes the keyboard without making Cadre
// the active app, so the app underneath stays as it was and has the keyboard
// again once the panel is gone. In it, an NSTextView to write in (real Mac
// editing, dictation, paste, IME) and a caption saying where Claude is
// starting and whether it is up.
//
// It is not an SDL window. SDL never draws into it, and what is typed in it
// reaches no Cadre window: while a window SDL doesn't know has the keyboard,
// SDL's key events carry no window id and the runtime drops them. Return and
// Esc are taken by the text view's delegate and handed to the runtime through
// `take`, polled from the frame loop like the shortcut (macos_hotkey.zig).
//
// One panel per process, made the first time it is shown and kept. arm64
// macOS only; elsewhere `show` returns false.

const std = @import("std");
const builtin = @import("builtin");
const hotkey = @import("macos_hotkey.zig");

const log = std.log.scoped(.quick_panel);

pub const supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// The panel in the app's theme.
pub const Colors = struct {
    background: Rgb,
    text: Rgb,
    caret: Rgb,
    border: Rgb,
    caption: Rgb,
};

pub const Event = union(enum) {
    /// Return: the text as written. Allocated; the caller frees it.
    submit: []u8,
    /// Esc.
    cancel,
};

/// A rectangle in AppKit's screen points: the origin is the bottom-left
/// corner and y runs upward.
pub const Frame = struct { x: f64, y: f64, w: f64, h: f64 };

const width_pt: f64 = 680;
/// Kept free left and right of the panel on a screen narrower than it.
const side_margin_pt: f64 = 24;
const pad_pt: f64 = 12;
const caption_h_pt: f64 = 30;
/// The field grows with the text between these, then scrolls.
const min_field_pt: f64 = 40;
const max_field_pt: f64 = 240;
/// How far up the screen's usable height the panel's bottom edge sits.
/// By-eye knob for "close to the bottom".
const bottom_fraction: f64 = 0.10;
const radius_pt: f64 = 12;
const font_pt: f64 = 15;
const caption_font_pt: f64 = 12;
const inset_w_pt: f64 = 8;
const inset_h_pt: f64 = 10;
/// After Esc closes the panel, its key-up is swallowed for this long (see
/// `swallowsKey`); a later Esc is somebody else's.
const escape_up_ms: i64 = 2000;

const hint_text = "return to send  \u{00B7}  esc to cancel";

/// Where the panel goes on a screen whose usable area (without the menu bar
/// and the Dock) is `visible`: centred, its bottom edge a fixed share of the
/// height up from the bottom, as tall as `content_h` points of text need.
/// With y running upward, a taller panel grows upward from that edge.
pub fn panelFrame(visible: Frame, content_h: f64) Frame {
    const w = @max(0, @min(width_pt, visible.w - side_margin_pt * 2));
    return .{
        .x = visible.x + (visible.w - w) / 2,
        .y = visible.y + visible.h * bottom_fraction,
        .w = w,
        .h = panelHeight(content_h),
    };
}

pub fn panelHeight(content_h: f64) f64 {
    return pad_pt + std.math.clamp(content_h, min_field_pt, max_field_pt) + caption_h_pt;
}

pub const Command = enum {
    submit,
    cancel,
    /// A line break in the text.
    newline,
    /// Taken, and nothing done.
    ignore,
    /// The text view's own business.
    pass,
};

/// What an editing command (the selector the text view's key bindings make of
/// a key) does in the panel. `has_text`: something other than blanks is written.
pub fn command(name: []const u8, shift: bool, option: bool, has_text: bool) Command {
    if (eql(name, "insertNewline:")) {
        if (shift or option) return .newline;
        return if (has_text) .submit else .ignore;
    }
    // Shift+Return arrives as insertLineBreak: (U+2028); a prompt wants "\n".
    if (eql(name, "insertLineBreak:") or eql(name, "insertParagraphSeparator:")) return .newline;
    if (eql(name, "cancelOperation:")) return .cancel;
    return .pass;
}

pub const Edit = enum { select_all, copy, cut, paste, undo, redo };

/// The edit a Cmd key stands for. `chars`: the key without its modifiers.
/// No Edit menu gives these keys their meaning in a panel like this one.
pub fn keyEquivalent(chars: []const u8, shift: bool) ?Edit {
    if (chars.len != 1) return null;
    return switch (std.ascii.toLower(chars[0])) {
        'a' => .select_all,
        'c' => .copy,
        'x' => .cut,
        'v' => .paste,
        'z' => if (shift) .redo else .undo,
        else => null,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Impl = if (supported) AppKit else None;

/// Once, before the first `show`: how to break the frame loop's idle wait
/// when Return or Esc is pressed in the panel.
pub fn install(wake: hotkey.Wake) void {
    Impl.install(wake);
}

/// Show the panel, empty, with the keyboard in it, for a Claude starting in
/// `place`. False when there is no panel to show.
pub fn show(place: []const u8, colors: Colors) bool {
    return Impl.show(place, colors);
}

/// Take the panel away without a word to the runtime.
pub fn hide() void {
    Impl.hide();
}

pub fn isOpen() bool {
    return Impl.isOpen();
}

/// Give an open panel the keyboard again (the shortcut, pressed once more).
pub fn focus() void {
    Impl.focus();
}

/// Claude's input box is up in the terminal started for this entry.
pub fn setReady(ready: bool) void {
    Impl.setReady(ready);
}

/// What the user did in the panel since the last call, if anything. The
/// panel is already gone from the screen by then.
pub fn take(allocator: std.mem.Allocator) ?Event {
    return Impl.take(allocator);
}

/// Whether an SDL keyboard event is the panel's and must not reach a
/// terminal: any while the panel is up, and the key-up of the Esc that just
/// closed it (`escape_up`), which SDL can report against the Cadre window
/// that got the keyboard back, where a bare Esc key-up is sent to the shell.
pub fn swallowsKey(escape_up: bool) bool {
    return Impl.swallowsKey(escape_up);
}

const None = struct {
    fn install(_: hotkey.Wake) void {}
    fn show(_: []const u8, _: Colors) bool {
        return false;
    }
    fn hide() void {}
    fn isOpen() bool {
        return false;
    }
    fn focus() void {}
    fn setReady(_: bool) void {}
    fn take(_: std.mem.Allocator) ?Event {
        return null;
    }
    fn swallowsKey(_: bool) bool {
        return false;
    }
};

const AppKit = struct {
    const objc = @import("objc.zig");
    const Id = objc.Id;
    const send = objc.send;
    const cls = objc.cls;

    const NSPoint = extern struct { x: f64, y: f64 };
    const NSSize = extern struct { w: f64, h: f64 };
    const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

    const flag_shift: usize = 1 << 17;
    const flag_option: usize = 1 << 19;
    const flag_cmd: usize = 1 << 20;
    const huge: f64 = 1.0e7;

    var panel: Id = null;
    var text: Id = null;
    var status: Id = null;
    var hint: Id = null;
    var wake: ?hotkey.Wake = null;
    var open = false;
    var ready = false;
    var pending: enum { none, submit, cancel } = .none;
    /// When Esc closed the panel, until its key-up has been seen.
    var escape_closed_ms: ?i64 = null;
    var place_buf: [64]u8 = undefined;
    var place_len: usize = 0;

    fn install(on_event: hotkey.Wake) void {
        wake = on_event;
    }

    fn isOpen() bool {
        return open;
    }

    fn show(place: []const u8, colors: Colors) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (!create()) {
            log.warn("quick entry panel unavailable", .{});
            return false;
        }
        place_len = @min(place.len, place_buf.len);
        @memcpy(place_buf[0..place_len], place[0..place_len]);
        ready = false;
        pending = .none;
        escape_closed_ms = null;
        applyColors(colors);
        send(void, text, "setString:", .{objc.string("")});

        const frame = panelFrame(pointerScreen(), 0);
        send(void, panel, "setFrame:display:", .{ frame.x, frame.y, frame.w, frame.h, false });
        fitHeight();
        layoutCaption();
        // Regardless: Cadre is usually not the active app here, and stays so.
        send(void, panel, "orderFrontRegardless", .{});
        send(void, panel, "makeKeyWindow", .{});
        _ = send(bool, panel, "makeFirstResponder:", .{text});
        open = true;
        log.info("quick entry panel shown at {d:.0},{d:.0} ({d:.0} wide)", .{ frame.x, frame.y, frame.w });
        return true;
    }

    fn hide() void {
        if (!open) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        open = false;
        pending = .none;
        send(void, panel, "orderOut:", .{@as(Id, null)});
        send(void, text, "setString:", .{objc.string("")});
    }

    fn focus() void {
        if (!open) return;
        send(void, panel, "orderFrontRegardless", .{});
        send(void, panel, "makeKeyWindow", .{});
    }

    fn setReady(now_ready: bool) void {
        if (now_ready == ready) return;
        ready = now_ready;
        if (!open) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        layoutCaption();
    }

    fn take(allocator: std.mem.Allocator) ?Event {
        const kind = pending;
        if (kind == .none) return null;
        pending = .none;
        const pool = objc.Pool.push();
        defer pool.pop();
        defer send(void, text, "setString:", .{objc.string("")});
        if (kind == .cancel) return .cancel;
        const copy = allocator.dupe(u8, written()) catch |err| {
            // Nothing to send: let the runtime close the terminal it started.
            log.warn("failed to copy the quick entry text: {}", .{err});
            return .cancel;
        };
        return .{ .submit = copy };
    }

    fn swallowsKey(escape_up: bool) bool {
        if (open) return true;
        if (!escape_up) return false;
        const closed = escape_closed_ms orelse return false;
        escape_closed_ms = null;
        return std.time.milliTimestamp() - closed < escape_up_ms;
    }

    /// Return or Esc in the panel: off the screen at once, the runtime told
    /// on its next frame.
    fn close(kind: @TypeOf(pending)) void {
        open = false;
        pending = kind;
        if (kind == .cancel) escape_closed_ms = std.time.milliTimestamp();
        send(void, panel, "orderOut:", .{@as(Id, null)});
        log.info("quick entry panel closed ({s})", .{@tagName(kind)});
        if (wake) |w| w.callback(w.context);
    }

    /// The text view's text. Valid until the text changes or the pool drains.
    fn written() []const u8 {
        const utf8 = send(?[*:0]const u8, send(Id, text, "string", .{}), "UTF8String", .{}) orelse return "";
        return std.mem.span(utf8);
    }

    fn create() bool {
        if (panel != null) return true;
        const panel_cls = panelClass() orelse return false;
        const delegate_cls = delegateClass() orelse return false;

        const h = panelHeight(0);
        // Borderless, and non-activating: it can have the keyboard while
        // another app stays the active one. Only settable at creation.
        const style: usize = 1 << 7; // NSWindowStyleMaskNonactivatingPanel
        const p = send(Id, send(Id, panel_cls, "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
            @as(f64, 0), @as(f64, 0), width_pt, h,
            style,
            @as(usize, 2), // NSBackingStoreBuffered
            true,
        }) orelse return false;
        send(void, p, "setReleasedWhenClosed:", .{false});
        // A panel hides itself while its app is not the active one, by default.
        send(void, p, "setHidesOnDeactivate:", .{false});
        send(void, p, "setFloatingPanel:", .{true});
        // On whichever Space is showing, another app's full-screen one included.
        send(void, p, "setCollectionBehavior:", .{@as(usize, (1 << 0) | (1 << 8))}); // canJoinAllSpaces | fullScreenAuxiliary
        send(void, p, "setOpaque:", .{false});
        send(void, p, "setBackgroundColor:", .{send(Id, cls("NSColor"), "clearColor", .{})});
        send(void, p, "setHasShadow:", .{true});
        send(void, p, "setMovableByWindowBackground:", .{true});

        // The card: the content view's layer, rounded.
        const content = send(Id, p, "contentView", .{});
        send(void, content, "setWantsLayer:", .{true});
        const layer = send(Id, content, "layer", .{});
        send(void, layer, "setCornerRadius:", .{radius_pt});
        send(void, layer, "setMasksToBounds:", .{true});
        send(void, layer, "setBorderWidth:", .{@as(f64, 1)});

        // The field sits above the caption row (y runs upward) and takes up
        // any change in the panel's size.
        const scroll = send(Id, objc.alloc("NSScrollView"), "initWithFrame:", .{ pad_pt, caption_h_pt, width_pt - pad_pt * 2, h - pad_pt - caption_h_pt }) orelse return false;
        send(void, scroll, "setHasVerticalScroller:", .{true});
        send(void, scroll, "setAutohidesScrollers:", .{true});
        send(void, scroll, "setBorderType:", .{@as(usize, 0)}); // NSNoBorder
        send(void, scroll, "setDrawsBackground:", .{false});
        send(void, scroll, "setAutoresizingMask:", .{@as(usize, 2 | 16)}); // width, height
        const size = send(NSSize, scroll, "contentSize", .{});

        const view = send(Id, objc.alloc("NSTextView"), "initWithFrame:", .{ @as(f64, 0), @as(f64, 0), size.w, size.h }) orelse return false;
        // Standard "text view in a scroll view" wiring: grow vertically, wrap
        // at the visible width.
        send(void, view, "setMinSize:", .{ @as(f64, 0), size.h });
        send(void, view, "setMaxSize:", .{ huge, huge });
        send(void, view, "setVerticallyResizable:", .{true});
        send(void, view, "setHorizontallyResizable:", .{false});
        send(void, view, "setAutoresizingMask:", .{@as(usize, 2)}); // width
        const container = send(Id, view, "textContainer", .{});
        send(void, container, "setContainerSize:", .{ size.w, huge });
        send(void, container, "setWidthTracksTextView:", .{true});
        // Plain text for a prompt, as in the composer (composer_view.zig).
        send(void, view, "setRichText:", .{false});
        send(void, view, "setImportsGraphics:", .{false});
        send(void, view, "setAllowsUndo:", .{true});
        send(void, view, "setAutomaticQuoteSubstitutionEnabled:", .{false});
        send(void, view, "setAutomaticDashSubstitutionEnabled:", .{false});
        send(void, view, "setAutomaticTextReplacementEnabled:", .{false});
        send(void, view, "setAutomaticSpellingCorrectionEnabled:", .{false});
        send(void, view, "setContinuousSpellCheckingEnabled:", .{true});
        send(void, view, "setDrawsBackground:", .{false});
        send(void, view, "setTextContainerInset:", .{ inset_w_pt, inset_h_pt });
        if (send(Id, cls("NSFont"), "systemFontOfSize:", .{font_pt})) |font| send(void, view, "setFont:", .{font});
        send(void, view, "setDelegate:", .{send(Id, send(Id, delegate_cls, "alloc", .{}), "init", .{})});
        send(void, scroll, "setDocumentView:", .{view});
        send(void, content, "addSubview:", .{scroll});

        status = makeLabel(content);
        hint = makeLabel(content);
        send(void, hint, "setStringValue:", .{objc.string(hint_text)});
        send(void, hint, "sizeToFit", .{});
        text = view;
        panel = p;
        return true;
    }

    /// A line of caption text: a text field with everything turned off.
    fn makeLabel(parent: Id) Id {
        const label = send(Id, objc.alloc("NSTextField"), "initWithFrame:", .{ @as(f64, 0), @as(f64, 0), @as(f64, 10), @as(f64, 10) });
        send(void, label, "setBezeled:", .{false});
        send(void, label, "setDrawsBackground:", .{false});
        send(void, label, "setEditable:", .{false});
        send(void, label, "setSelectable:", .{false});
        if (send(Id, cls("NSFont"), "systemFontOfSize:", .{caption_font_pt})) |font| send(void, label, "setFont:", .{font});
        send(void, parent, "addSubview:", .{label});
        return label;
    }

    fn applyColors(colors: Colors) void {
        const layer = send(Id, send(Id, panel, "contentView", .{}), "layer", .{});
        send(void, layer, "setBackgroundColor:", .{send(Id, color(colors.background), "CGColor", .{})});
        send(void, layer, "setBorderColor:", .{send(Id, color(colors.border), "CGColor", .{})});
        send(void, text, "setTextColor:", .{color(colors.text)});
        send(void, text, "setInsertionPointColor:", .{color(colors.caret)});
        send(void, status, "setTextColor:", .{color(colors.caption)});
        send(void, hint, "setTextColor:", .{color(colors.caption)});
        // Scroller and selection in the theme's light or dark, whatever the
        // system is set to (as platform/macos_titlebar.zig does for windows).
        const bg = colors.background;
        const light = @as(u32, bg.r) + @as(u32, bg.g) + @as(u32, bg.b) > 382;
        const name = objc.string(if (light) "NSAppearanceNameAqua" else "NSAppearanceNameDarkAqua");
        send(void, panel, "setAppearance:", .{send(Id, cls("NSAppearance"), "appearanceNamed:", .{name})});
    }

    fn color(rgb: Rgb) Id {
        return send(Id, cls("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
            @as(f64, @floatFromInt(rgb.r)) / 255.0,
            @as(f64, @floatFromInt(rgb.g)) / 255.0,
            @as(f64, @floatFromInt(rgb.b)) / 255.0,
            @as(f64, 1.0),
        });
    }

    /// The usable area of the screen the pointer is on.
    fn pointerScreen() Frame {
        const mouse = send(NSPoint, cls("NSEvent"), "mouseLocation", .{});
        const screens = send(Id, cls("NSScreen"), "screens", .{});
        const count = send(usize, screens, "count", .{});
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const screen = send(Id, screens, "objectAtIndex:", .{i});
            const f = send(NSRect, screen, "frame", .{});
            if (mouse.x < f.x or mouse.x >= f.x + f.w or mouse.y < f.y or mouse.y >= f.y + f.h) continue;
            return toFrame(send(NSRect, screen, "visibleFrame", .{}));
        }
        const main = send(Id, cls("NSScreen"), "mainScreen", .{}) orelse return .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
        return toFrame(send(NSRect, main, "visibleFrame", .{}));
    }

    fn toFrame(rect: NSRect) Frame {
        return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    }

    /// Make the panel as tall as its text needs, from the same bottom edge.
    fn fitHeight() void {
        const layout = send(Id, text, "layoutManager", .{});
        const container = send(Id, text, "textContainer", .{});
        send(void, layout, "ensureLayoutForTextContainer:", .{container});
        const used = send(NSRect, layout, "usedRectForTextContainer:", .{container});
        const frame = send(NSRect, panel, "frame", .{});
        const h = panelHeight(used.h + inset_h_pt * 2);
        if (h == frame.h) return;
        send(void, panel, "setFrame:display:", .{ frame.x, frame.y, frame.w, h, true });
    }

    /// The caption row: where Claude is starting and whether it is up on the
    /// left, what the keys do on the right (left out when both don't fit).
    fn layoutCaption() void {
        const state = if (ready) "Claude is ready" else "starting Claude\u{2026}";
        var buf: [160]u8 = undefined;
        const line = std.fmt.bufPrintZ(&buf, "{s}  \u{00B7}  {s}", .{ place_buf[0..place_len], state }) catch |err| blk: {
            log.warn("quick entry caption left out the folder: {}", .{err});
            break :blk state;
        };
        send(void, status, "setStringValue:", .{objc.string(line.ptr)});
        send(void, status, "sizeToFit", .{});
        const width = send(NSRect, panel, "frame", .{}).w;
        const status_size = send(NSRect, status, "frame", .{});
        const hint_size = send(NSRect, hint, "frame", .{});
        const left = pad_pt + inset_w_pt;
        send(void, status, "setFrameOrigin:", .{ left, (caption_h_pt - status_size.h) / 2 });
        const hint_x = width - left - hint_size.w;
        send(void, hint, "setFrameOrigin:", .{ hint_x, (caption_h_pt - hint_size.h) / 2 });
        send(void, hint, "setHidden:", .{hint_x < left + status_size.w + pad_pt});
    }

    // Both classes are built at runtime (no Objective-C sources in the build).

    /// NSPanel, except that it may have the keyboard (a borderless window may
    /// not, by default) and that Cmd keys mean an edit or nothing.
    fn panelClass() Id {
        const name = "CadreQuickEntryPanel";
        if (objc.runtime.objc_getClass(name)) |existing| return @ptrCast(existing);
        const new_cls = objc.runtime.objc_allocateClassPair(objc.runtime.objc_getClass("NSPanel"), name, 0) orelse return null;
        _ = objc.runtime.class_addMethod(new_cls, objc.runtime.sel_registerName("canBecomeKeyWindow"), @ptrCast(&canBecomeKeyWindow), "B@:");
        _ = objc.runtime.class_addMethod(new_cls, objc.runtime.sel_registerName("performKeyEquivalent:"), @ptrCast(&performKeyEquivalent), "B@:@");
        objc.runtime.objc_registerClassPair(new_cls);
        return @ptrCast(new_cls);
    }

    fn canBecomeKeyWindow(_: Id, _: Id) callconv(.c) u8 {
        return 1;
    }

    fn performKeyEquivalent(_: Id, _: Id, event: Id) callconv(.c) u8 {
        const flags = send(usize, event, "modifierFlags", .{});
        if (flags & flag_cmd == 0) return 0;
        const chars = send(?[*:0]const u8, send(Id, event, "charactersIgnoringModifiers", .{}), "UTF8String", .{}) orelse "";
        if (keyEquivalent(std.mem.span(chars), flags & flag_shift != 0)) |edit| perform(edit);
        // Every other Cmd key ends here: Cadre's menu (Quit, Hide, Minimize)
        // is not what a key pressed in this box is meant for.
        return 1;
    }

    /// Straight to the text view, as composer_view.zig does: the responder
    /// chain an Edit menu would use starts from whichever window AppKit
    /// counts as key, which need not be this one.
    fn perform(edit: Edit) void {
        switch (edit) {
            .select_all => send(void, text, "selectAll:", .{@as(Id, null)}),
            .copy => send(void, text, "copy:", .{@as(Id, null)}),
            .cut => send(void, text, "cut:", .{@as(Id, null)}),
            .paste => send(void, text, "paste:", .{@as(Id, null)}),
            .undo, .redo => {
                const undo = send(Id, text, "undoManager", .{});
                if (edit == .undo) {
                    if (send(bool, undo, "canUndo", .{})) send(void, undo, "undo", .{});
                } else {
                    if (send(bool, undo, "canRedo", .{})) send(void, undo, "redo", .{});
                }
            },
        }
    }

    fn delegateClass() Id {
        const name = "CadreQuickEntryDelegate";
        if (objc.runtime.objc_getClass(name)) |existing| return @ptrCast(existing);
        const new_cls = objc.runtime.objc_allocateClassPair(objc.runtime.objc_getClass("NSObject"), name, 0) orelse return null;
        _ = objc.runtime.class_addMethod(new_cls, objc.runtime.sel_registerName("textView:doCommandBySelector:"), @ptrCast(&doCommandBySelector), "B@:@:");
        _ = objc.runtime.class_addMethod(new_cls, objc.runtime.sel_registerName("textDidChange:"), @ptrCast(&textDidChange), "v@:@");
        objc.runtime.objc_registerClassPair(new_cls);
        return @ptrCast(new_cls);
    }

    fn doCommandBySelector(_: Id, _: Id, text_view: Id, selector: Id) callconv(.c) u8 {
        const app = send(Id, cls("NSApplication"), "sharedApplication", .{});
        const flags: usize = if (send(Id, app, "currentEvent", .{})) |event| send(usize, event, "modifierFlags", .{}) else 0;
        const name = std.mem.span(objc.runtime.sel_getName(@ptrCast(selector)));
        const has_text = std.mem.trim(u8, written(), " \t\r\n").len > 0;
        switch (command(name, flags & flag_shift != 0, flags & flag_option != 0, has_text)) {
            .pass => return 0,
            .ignore => {},
            .newline => send(void, text_view, "insertNewlineIgnoringFieldEditor:", .{@as(Id, null)}),
            .submit => close(.submit),
            .cancel => close(.cancel),
        }
        return 1;
    }

    fn textDidChange(_: Id, _: Id, _: Id) callconv(.c) void {
        fitHeight();
    }
};

const testing = std.testing;

test "the panel sits near the bottom of the screen, centred, and grows upward" {
    // A 1440x900 screen with a menu bar on top and a Dock at the bottom.
    const visible = Frame{ .x = 0, .y = 70, .w = 1440, .h = 805 };
    const empty = panelFrame(visible, 0);
    try testing.expectEqual(width_pt, empty.w);
    try testing.expectEqual((1440 - width_pt) / 2, empty.x);
    // Its bottom edge: above the Dock, in the screen's lowest fifth.
    try testing.expect(empty.y > visible.y);
    try testing.expect(empty.y < visible.y + visible.h * 0.2);
    try testing.expectEqual(pad_pt + min_field_pt + caption_h_pt, empty.h);

    // More text: the same bottom edge, a taller panel, up to a limit.
    const some = panelFrame(visible, 120);
    try testing.expectEqual(empty.y, some.y);
    try testing.expectEqual(pad_pt + 120 + caption_h_pt, some.h);
    try testing.expectEqual(pad_pt + max_field_pt + caption_h_pt, panelFrame(visible, 5000).h);
}

test "the panel follows its screen, and fits a narrow one" {
    // A second display to the left of the main one, and lower.
    const left = Frame{ .x = -1920, .y = -200, .w = 1920, .h = 1055 };
    const on_left = panelFrame(left, 0);
    try testing.expect(on_left.x >= left.x and on_left.x + on_left.w <= left.x + left.w);
    try testing.expect(on_left.y >= left.y and on_left.y < left.y + left.h * 0.2);

    const narrow = panelFrame(.{ .x = 0, .y = 0, .w = 500, .h = 800 }, 0);
    try testing.expectEqual(500 - side_margin_pt * 2, narrow.w);
    try testing.expectEqual(side_margin_pt, narrow.x);
}

test "command: Return sends what is written, a modified Return breaks the line, Esc cancels" {
    try testing.expectEqual(Command.submit, command("insertNewline:", false, false, true));
    // Nothing written yet: Return does nothing, and the panel stays.
    try testing.expectEqual(Command.ignore, command("insertNewline:", false, false, false));
    try testing.expectEqual(Command.newline, command("insertNewline:", true, false, true));
    try testing.expectEqual(Command.newline, command("insertNewline:", false, true, false));
    try testing.expectEqual(Command.newline, command("insertLineBreak:", false, false, true));
    try testing.expectEqual(Command.cancel, command("cancelOperation:", false, false, true));
    try testing.expectEqual(Command.cancel, command("cancelOperation:", false, false, false));
    // Editing and moving about are the text view's.
    try testing.expectEqual(Command.pass, command("deleteBackward:", false, false, true));
    try testing.expectEqual(Command.pass, command("moveWordLeft:", false, true, true));
    try testing.expectEqual(Command.pass, command("insertNewlineIgnoringFieldEditor:", false, true, true));
}

test "keyEquivalent: the Cmd editing keys, and nothing else" {
    try testing.expectEqual(Edit.paste, keyEquivalent("v", false).?);
    try testing.expectEqual(Edit.copy, keyEquivalent("c", false).?);
    try testing.expectEqual(Edit.cut, keyEquivalent("x", false).?);
    try testing.expectEqual(Edit.select_all, keyEquivalent("a", false).?);
    try testing.expectEqual(Edit.undo, keyEquivalent("z", false).?);
    // With Shift the key comes through as a capital.
    try testing.expectEqual(Edit.redo, keyEquivalent("Z", true).?);
    try testing.expect(keyEquivalent("q", false) == null);
    try testing.expect(keyEquivalent("w", false) == null);
    try testing.expect(keyEquivalent("", false) == null);
    try testing.expect(keyEquivalent("\u{00E9}", false) == null);
}
