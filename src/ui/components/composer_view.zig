// AppKit text box behind the composer (composer.zig).
//
// An NSTextView inside an NSScrollView, added on top of the SDL view, so the
// composer gets real Mac text editing for free: click-to-place, drag-select and
// type-over, word/line selection, undo, spellcheck, dictation and IME. Same
// runtime objc_msgSend interop as platform/macos_titlebar.zig, so no AppKit
// headers. arm64 only, like the title bar's right-aligned name: struct returns
// (NSRect) need objc_msgSend_stret on x86_64; there `create` returns null and
// the composer stays off.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../../c.zig");
const geom = @import("../../geom.zig");

const log = std.log.scoped(.composer_view);

pub const supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

/// What the text view does with an AppKit editing command (the selector its key
/// bindings produce). Mirrors `composer.routeKeyDown`, which decides the same key
/// on the SDL side: a key routed to the terminal must be consumed here, or the
/// text view would also act on it.
pub const CommandAction = enum { allow, consume, newline };

pub const CommandMods = struct {
    ctrl: bool = false,
    shift: bool = false,
    option: bool = false,
};

pub fn commandAction(name: []const u8, mods: CommandMods, empty: bool) CommandAction {
    // Ctrl chords belong to the program in the terminal (Ctrl+C, Ctrl+O, ...).
    if (mods.ctrl) return .consume;
    if (eql(name, "insertNewline:")) return if (mods.shift or mods.option) .newline else .consume;
    // Shift+Return arrives as insertLineBreak: (U+2028); a prompt wants "\n".
    if (eql(name, "insertLineBreak:") or eql(name, "insertParagraphSeparator:")) return .newline;
    if (eql(name, "cancelOperation:") or eql(name, "insertTab:") or eql(name, "insertBacktab:") or
        eql(name, "noop:") or eql(name, "complete:")) return .consume;
    if (startsWith(name, "scrollPage") or startsWith(name, "page")) return .consume;
    // An empty box hands navigation to the terminal (Claude's menus, history).
    if (empty and (startsWith(name, "move") or startsWith(name, "scroll"))) return .consume;
    return .allow;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(a: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, a, prefix);
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const ComposerView = if (supported) AppKitView else NoView;

const NoView = struct {
    pub fn create(_: *c.SDL_Window, _: f64) ?NoView {
        return null;
    }
    pub fn destroy(_: *NoView) void {}
    pub fn setFrame(_: *NoView, _: geom.Rect, _: c_int, _: c_int) void {}
    pub fn setHidden(_: *NoView, _: bool) void {}
    pub fn setColors(_: *NoView, _: Rgb, _: Rgb, _: Rgb) void {}
    pub fn focus(_: *NoView) void {}
    pub fn unfocus(_: *NoView) void {}
    pub fn isFocused(_: *const NoView) bool {
        return false;
    }
    pub fn textLength(_: *const NoView) usize {
        return 0;
    }
    pub fn hasMarkedText(_: *const NoView) bool {
        return false;
    }
    pub fn copyText(_: *const NoView, allocator: std.mem.Allocator) ![]u8 {
        return allocator.alloc(u8, 0);
    }
    pub fn setText(_: *NoView, _: std.mem.Allocator, _: []const u8) void {}
    pub fn contentHeightPx(_: *const NoView, _: c_int) c_int {
        return 0;
    }
    pub fn perform(_: *NoView, _: Edit) void {}
    pub fn clipboardIsImageOnly() bool {
        return false;
    }
};

pub const Edit = enum { cut, copy, paste, select_all, undo, redo };

const AppKitView = struct {
    window: *c.SDL_Window,
    ns_window: Id,
    scroll: Id,
    text: Id,
    delegate: Id,
    frame: [4]f64 = .{ -1, -1, -1, -1 },

    const inset_w: f64 = 12;
    const inset_h: f64 = 9;
    const huge: f64 = 1.0e7;

    pub fn create(window: *c.SDL_Window, font_pt: f64) ?AppKitView {
        const props = c.SDL_GetWindowProperties(window);
        const ns_window: Id = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return null;
        const content = send(Id, ns_window, "contentView", .{}) orelse return null;
        const delegate_cls = delegateClass() orelse return null;

        const scroll = send(Id, alloc("NSScrollView"), "initWithFrame:", .{ @as(f64, 0), @as(f64, 0), @as(f64, 100), @as(f64, 40) }) orelse return null;
        send(void, scroll, "setHasVerticalScroller:", .{true});
        send(void, scroll, "setAutohidesScrollers:", .{true});
        send(void, scroll, "setBorderType:", .{@as(usize, 0)}); // NSNoBorder
        send(void, scroll, "setDrawsBackground:", .{true});
        const size = send(NSSize, scroll, "contentSize", .{});

        const text = send(Id, alloc("NSTextView"), "initWithFrame:", .{ @as(f64, 0), @as(f64, 0), size.w, size.h }) orelse {
            send(void, scroll, "release", .{});
            return null;
        };
        // Standard "text view in a scroll view" wiring: grow vertically, wrap at
        // the visible width.
        send(void, text, "setMinSize:", .{ @as(f64, 0), size.h });
        send(void, text, "setMaxSize:", .{ huge, huge });
        send(void, text, "setVerticallyResizable:", .{true});
        send(void, text, "setHorizontallyResizable:", .{false});
        send(void, text, "setAutoresizingMask:", .{@as(usize, 2)}); // NSViewWidthSizable
        const container = send(Id, text, "textContainer", .{});
        send(void, container, "setContainerSize:", .{ size.w, huge });
        send(void, container, "setWidthTracksTextView:", .{true});

        // Plain text for a prompt: no rich text, no images, and none of the
        // "smart" substitutions that would rewrite quotes and dashes in code.
        send(void, text, "setRichText:", .{false});
        send(void, text, "setImportsGraphics:", .{false});
        send(void, text, "setAllowsUndo:", .{true});
        send(void, text, "setAutomaticQuoteSubstitutionEnabled:", .{false});
        send(void, text, "setAutomaticDashSubstitutionEnabled:", .{false});
        send(void, text, "setAutomaticTextReplacementEnabled:", .{false});
        send(void, text, "setAutomaticSpellingCorrectionEnabled:", .{false});
        send(void, text, "setContinuousSpellCheckingEnabled:", .{true});
        send(void, text, "setTextContainerInset:", .{ inset_w, inset_h });
        if (send(Id, cls("NSFont"), "systemFontOfSize:", .{font_pt})) |font| send(void, text, "setFont:", .{font});

        const delegate = send(Id, allocClass(delegate_cls), "init", .{});
        send(void, text, "setDelegate:", .{delegate});
        send(void, scroll, "setDocumentView:", .{text});
        send(void, scroll, "setHidden:", .{true});
        send(void, content, "addSubview:", .{scroll});

        registerView(text, window);
        return .{ .window = window, .ns_window = ns_window, .scroll = scroll, .text = text, .delegate = delegate };
    }

    pub fn destroy(self: *AppKitView) void {
        unregisterView(self.text);
        send(void, self.text, "setDelegate:", .{@as(Id, null)});
        send(void, self.scroll, "removeFromSuperview", .{});
        send(void, self.text, "release", .{});
        send(void, self.scroll, "release", .{});
        send(void, self.delegate, "release", .{});
    }

    /// Place the box at `rect` (render pixels, top-left origin) over a window
    /// whose render size is `render_w` x `render_h`.
    pub fn setFrame(self: *AppKitView, rect: geom.Rect, render_w: c_int, render_h: c_int) void {
        const scale = pointScale(self.window, render_w, render_h) orelse return;
        const frame = [4]f64{
            fl(rect.x) / scale.x,
            scale.points_h - fl(rect.y + rect.h) / scale.y, // AppKit's origin is bottom-left
            fl(rect.w) / scale.x,
            fl(rect.h) / scale.y,
        };
        if (std.mem.eql(f64, &frame, &self.frame)) return;
        self.frame = frame;
        send(void, self.scroll, "setFrame:", .{ frame[0], frame[1], frame[2], frame[3] });
    }

    pub fn setHidden(self: *AppKitView, hidden: bool) void {
        send(void, self.scroll, "setHidden:", .{hidden});
    }

    pub fn setColors(self: *AppKitView, bg: Rgb, fg: Rgb, caret: Rgb) void {
        const bg_color = color(bg);
        send(void, self.scroll, "setBackgroundColor:", .{bg_color});
        send(void, self.text, "setBackgroundColor:", .{bg_color});
        send(void, self.text, "setTextColor:", .{color(fg)});
        send(void, self.text, "setInsertionPointColor:", .{color(caret)});
    }

    /// Caller stops SDL text input first; otherwise SDL's own text field keeps
    /// turning keystrokes into TEXT_INPUT for the terminal as well.
    pub fn focus(self: *AppKitView) void {
        _ = send(bool, self.ns_window, "makeFirstResponder:", .{self.text});
    }

    pub fn unfocus(self: *AppKitView) void {
        if (self.isFocused()) _ = send(bool, self.ns_window, "makeFirstResponder:", .{@as(Id, null)});
    }

    pub fn isFocused(self: *const AppKitView) bool {
        return send(Id, self.ns_window, "firstResponder", .{}) == self.text;
    }

    pub fn textLength(self: *const AppKitView) usize {
        return send(usize, send(Id, self.text, "string", .{}), "length", .{});
    }

    /// Mid-composition (IME candidates, dictation in progress): Return belongs
    /// to the input method, not to "send".
    pub fn hasMarkedText(self: *const AppKitView) bool {
        return send(bool, self.text, "hasMarkedText", .{});
    }

    pub fn copyText(self: *const AppKitView, allocator: std.mem.Allocator) ![]u8 {
        const str = send(Id, self.text, "string", .{});
        const utf8 = send(?[*:0]const u8, str, "UTF8String", .{}) orelse return allocator.alloc(u8, 0);
        return allocator.dupe(u8, std.mem.span(utf8));
    }

    pub fn setText(self: *AppKitView, allocator: std.mem.Allocator, value: []const u8) void {
        const buf = allocator.alloc(u8, value.len + 1) catch |err| {
            log.warn("failed to copy composer text: {}", .{err});
            return;
        };
        defer allocator.free(buf);
        @memcpy(buf[0..value.len], value);
        buf[value.len] = 0;
        const z: [:0]const u8 = buf[0..value.len :0];
        const str = send(Id, cls("NSString"), "stringWithUTF8String:", .{z.ptr});
        send(void, self.text, "setString:", .{str});
        const len = self.textLength();
        send(void, self.text, "setSelectedRange:", .{ len, @as(usize, 0) });
        send(void, self.text, "scrollRangeToVisible:", .{ len, @as(usize, 0) });
        // Undo history pointed into the replaced text; drop it.
        send(void, send(Id, self.text, "undoManager", .{}), "removeAllActions", .{});
    }

    /// Height (render pixels) the text needs at the current width, insets included.
    pub fn contentHeightPx(self: *const AppKitView, render_h: c_int) c_int {
        var points_w: c_int = 0;
        var points_h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &points_w, &points_h);
        if (points_h <= 0 or render_h <= 0) return 0;
        const layout = send(Id, self.text, "layoutManager", .{});
        const container = send(Id, self.text, "textContainer", .{});
        send(void, layout, "ensureLayoutForTextContainer:", .{container});
        const used = send(NSRect, layout, "usedRectForTextContainer:", .{container});
        const points = used.h + inset_h * 2;
        return @intFromFloat(@ceil(points * fl(render_h) / fl(points_h)));
    }

    /// There is no Edit menu (SDL builds none), so Cmd+C/X/V/A/Z reach the text
    /// view through the composer's key routing instead of menu key equivalents.
    pub fn perform(self: *AppKitView, edit: Edit) void {
        switch (edit) {
            .cut => send(void, self.text, "cut:", .{@as(Id, null)}),
            .copy => send(void, self.text, "copy:", .{@as(Id, null)}),
            .paste => send(void, self.text, "paste:", .{@as(Id, null)}),
            .select_all => send(void, self.text, "selectAll:", .{@as(Id, null)}),
            .undo, .redo => {
                const undo = send(Id, self.text, "undoManager", .{});
                if (edit == .undo) {
                    if (send(bool, undo, "canUndo", .{})) send(void, undo, "undo", .{});
                } else {
                    if (send(bool, undo, "canRedo", .{})) send(void, undo, "redo", .{});
                }
            },
        }
    }

    /// An image with no text on the clipboard (a screenshot): Cmd+V should go to
    /// the terminal's image passthrough, not into the text box.
    pub fn clipboardIsImageOnly() bool {
        const board = send(Id, cls("NSPasteboard"), "generalPasteboard", .{}) orelse return false;
        const can_read = struct {
            fn f(pb: Id, class_name: [*:0]const u8) bool {
                const classes = send(Id, cls("NSArray"), "arrayWithObject:", .{cls(class_name)}) orelse return false;
                return send(bool, pb, "canReadObjectForClasses:options:", .{ classes, @as(Id, null) });
            }
        }.f;
        return can_read(board, "NSImage") and !can_read(board, "NSString");
    }

    // --- objc runtime glue ---

    const objc = @cImport({
        @cInclude("objc/runtime.h");
        @cInclude("objc/message.h");
    });

    const Id = ?*anyopaque;
    const NSSize = extern struct { w: f64, h: f64 };
    const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };

    fn cls(name: [*:0]const u8) Id {
        return @ptrCast(objc.objc_getClass(name));
    }

    fn alloc(class_name: [*:0]const u8) Id {
        return allocClass(cls(class_name));
    }

    fn allocClass(class: Id) Id {
        return send(Id, class, "alloc", .{});
    }

    /// Typed objc_msgSend: `send(R, target, "selector:", .{args...})` casts
    /// objc_msgSend to `fn (id, SEL, args...) R` (C ABI) and calls it. Args must
    /// be runtime-typed (no comptime literals): `@as(f64, 0)`, not `0`.
    fn send(comptime R: type, target: Id, comptime selector: [*:0]const u8, args: anytype) R {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        const arg_types = comptime blk: {
            var types: [fields.len]type = undefined;
            for (fields, 0..) |field, i| types[i] = field.type;
            break :blk types;
        };
        const func: *const msgFnType(R, &arg_types) = @ptrCast(&objc.objc_msgSend);
        const sel: Id = @ptrCast(objc.sel_registerName(selector));
        return @call(.auto, func, .{ target, sel } ++ args);
    }

    fn msgFnType(comptime R: type, comptime args: []const type) type {
        var params: [args.len + 2]std.builtin.Type.Fn.Param = undefined;
        params[0] = .{ .is_generic = false, .is_noalias = false, .type = Id };
        params[1] = .{ .is_generic = false, .is_noalias = false, .type = Id };
        for (args, 0..) |arg_type, i| params[i + 2] = .{ .is_generic = false, .is_noalias = false, .type = arg_type };
        return @Type(.{ .@"fn" = .{
            .calling_convention = .c,
            .is_generic = false,
            .is_var_args = false,
            .return_type = R,
            .params = &params,
        } });
    }

    fn color(rgb: Rgb) Id {
        return send(Id, cls("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
            @as(f64, @floatFromInt(rgb.r)) / 255.0,
            @as(f64, @floatFromInt(rgb.g)) / 255.0,
            @as(f64, @floatFromInt(rgb.b)) / 255.0,
            @as(f64, 1.0),
        });
    }

    fn fl(v: c_int) f64 {
        return @floatFromInt(v);
    }

    const PointScale = struct { x: f64, y: f64, points_h: f64 };

    fn pointScale(window: *c.SDL_Window, render_w: c_int, render_h: c_int) ?PointScale {
        var points_w: c_int = 0;
        var points_h: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &points_w, &points_h);
        if (points_w <= 0 or points_h <= 0 or render_w <= 0 or render_h <= 0) return null;
        return .{
            .x = fl(render_w) / fl(points_w),
            .y = fl(render_h) / fl(points_h),
            .points_h = fl(points_h),
        };
    }

    // The delegate class is built at runtime (no Objective-C sources in the
    // build): it vetoes the text view's editing commands for keys that belong
    // to the terminal, and grabs focus from SDL the instant the box is clicked.
    fn delegateClass() Id {
        const name = "CadreComposerDelegate";
        if (objc.objc_getClass(name)) |existing| return @ptrCast(existing);
        const new_cls = objc.objc_allocateClassPair(objc.objc_getClass("NSObject"), name, 0) orelse return null;
        _ = objc.class_addMethod(new_cls, objc.sel_registerName("textView:doCommandBySelector:"), @ptrCast(&doCommandBySelector), "c@:@:");
        _ = objc.class_addMethod(new_cls, objc.sel_registerName("textViewDidChangeSelection:"), @ptrCast(&didChangeSelection), "v@:@");
        objc.objc_registerClassPair(new_cls);
        return @ptrCast(new_cls);
    }

    const flag_shift: usize = 1 << 17;
    const flag_ctrl: usize = 1 << 18;
    const flag_option: usize = 1 << 19;

    fn doCommandBySelector(_: Id, _: Id, text_view: Id, command: Id) callconv(.c) u8 {
        const app = send(Id, cls("NSApplication"), "sharedApplication", .{});
        const flags: usize = if (send(Id, app, "currentEvent", .{})) |event| send(usize, event, "modifierFlags", .{}) else 0;
        const name = std.mem.span(objc.sel_getName(@ptrCast(command)));
        const empty = send(usize, send(Id, text_view, "string", .{}), "length", .{}) == 0;
        const mods = CommandMods{
            .ctrl = flags & flag_ctrl != 0,
            .shift = flags & flag_shift != 0,
            .option = flags & flag_option != 0,
        };
        return switch (commandAction(name, mods, empty)) {
            .allow => 0,
            .consume => 1,
            .newline => blk: {
                send(void, text_view, "insertNewlineIgnoringFieldEditor:", .{@as(Id, null)});
                break :blk 1;
            },
        };
    }

    // A click on the box makes it first responder inside AppKit; SDL never sees
    // that click. Stop SDL text input right here, before the next keystroke, or
    // SDL would feed that keystroke to the terminal as well.
    fn didChangeSelection(_: Id, _: Id, notification: Id) callconv(.c) void {
        const text_view = send(Id, notification, "object", .{});
        const window = lookupWindow(text_view) orelse return;
        const ns_window = send(Id, text_view, "window", .{});
        if (send(Id, ns_window, "firstResponder", .{}) != text_view) return;
        if (c.SDL_TextInputActive(window)) _ = c.SDL_StopTextInput(window);
    }

    // Text view -> SDL window, for the delegate callbacks (main thread only).
    const Registration = struct { text_view: Id = null, window: ?*c.SDL_Window = null };
    var registry: [16]Registration = [_]Registration{.{}} ** 16;

    fn registerView(text_view: Id, window: *c.SDL_Window) void {
        for (&registry) |*entry| {
            if (entry.text_view == null) {
                entry.* = .{ .text_view = text_view, .window = window };
                return;
            }
        }
        log.warn("composer registry full; click-to-focus waits a frame", .{});
    }

    fn unregisterView(text_view: Id) void {
        for (&registry) |*entry| {
            if (entry.text_view == text_view) entry.* = .{};
        }
    }

    fn lookupWindow(text_view: Id) ?*c.SDL_Window {
        if (text_view == null) return null;
        for (registry) |entry| {
            if (entry.text_view == text_view) return entry.window;
        }
        return null;
    }
};

test "commandAction hands terminal keys to the terminal" {
    const none = CommandMods{};
    try std.testing.expectEqual(CommandAction.consume, commandAction("insertNewline:", none, false));
    try std.testing.expectEqual(CommandAction.newline, commandAction("insertNewline:", .{ .shift = true }, false));
    try std.testing.expectEqual(CommandAction.newline, commandAction("insertLineBreak:", none, false));
    try std.testing.expectEqual(CommandAction.consume, commandAction("cancelOperation:", none, false));
    try std.testing.expectEqual(CommandAction.consume, commandAction("insertBacktab:", none, false));
    try std.testing.expectEqual(CommandAction.consume, commandAction("moveToBeginningOfParagraph:", .{ .ctrl = true }, false));
    try std.testing.expectEqual(CommandAction.consume, commandAction("scrollPageDown:", none, false));
    try std.testing.expectEqual(CommandAction.consume, commandAction("noop:", none, false));
}

test "commandAction keeps navigation in the box only while it has text" {
    const none = CommandMods{};
    try std.testing.expectEqual(CommandAction.allow, commandAction("moveUp:", none, false));
    try std.testing.expectEqual(CommandAction.consume, commandAction("moveUp:", none, true));
    try std.testing.expectEqual(CommandAction.allow, commandAction("moveWordLeftAndModifySelection:", none, false));
    try std.testing.expectEqual(CommandAction.allow, commandAction("deleteBackward:", none, true));
    try std.testing.expectEqual(CommandAction.allow, commandAction("insertNewlineIgnoringFieldEditor:", none, false));
}
