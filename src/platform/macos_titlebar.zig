// macOS title bar styling.
//
// Makes the native title bar take the window's background color so the app
// chrome blends into the terminal background instead of showing the system
// gray strip, hides the centered system title, and puts the app name at the
// far right of the title bar instead. Same objc_msgSend interop pattern as
// macos_clipboard.zig; the NSWindow comes from SDL's window properties, so no
// AppKit headers needed.

const std = @import("std");
const builtin = @import("builtin");
const c_sdl = @import("../c.zig");

const is_macos = builtin.os.tag == .macos;
const log = std.log.scoped(.titlebar);

const Impl = if (is_macos) struct {
    const c = @cImport({
        @cInclude("objc/runtime.h");
        @cInclude("objc/message.h");
    });

    const MsgSend = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const MsgSendIdArg = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;
    const MsgSendBoolArg = *const fn (?*anyopaque, ?*anyopaque, u8) callconv(.c) void;
    const MsgSendIntArg = *const fn (?*anyopaque, ?*anyopaque, i64) callconv(.c) void;
    const MsgSendFloatArg = *const fn (?*anyopaque, ?*anyopaque, f64) callconv(.c) ?*anyopaque;
    const MsgSendSizeArg = *const fn (?*anyopaque, ?*anyopaque, f64, f64) callconv(.c) void;
    const MsgSendRgba = *const fn (?*anyopaque, ?*anyopaque, f64, f64, f64, f64) callconv(.c) ?*anyopaque;
    const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
    const MsgSendRect = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) NSRect;

    const ns_window_title_hidden: i64 = 1; // NSWindowTitleHidden
    const ns_layout_attribute_right: i64 = 2; // NSLayoutAttributeRight
    const title_right_padding: f64 = 12;

    fn apply(window: *c_sdl.SDL_Window, name: [*:0]const u8, r: u8, g: u8, b: u8) bool {
        const props = c_sdl.SDL_GetWindowProperties(window);
        const ns_window = c_sdl.SDL_GetPointerProperty(props, c_sdl.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return false;
        const ns_color = c.objc_getClass("NSColor") orelse return false;
        const ns_string = c.objc_getClass("NSString") orelse return false;
        const ns_appearance = c.objc_getClass("NSAppearance") orelse return false;
        const sel_transparent = c.sel_registerName("setTitlebarAppearsTransparent:") orelse return false;
        const sel_set_bg = c.sel_registerName("setBackgroundColor:") orelse return false;
        const sel_rgba = c.sel_registerName("colorWithSRGBRed:green:blue:alpha:") orelse return false;
        const sel_utf8 = c.sel_registerName("stringWithUTF8String:") orelse return false;
        const sel_named = c.sel_registerName("appearanceNamed:") orelse return false;
        const sel_set_appearance = c.sel_registerName("setAppearance:") orelse return false;

        const msg_send_id = @as(MsgSendIdArg, @ptrCast(&c.objc_msgSend));
        const msg_send_bool = @as(MsgSendBoolArg, @ptrCast(&c.objc_msgSend));
        const msg_send_rgba = @as(MsgSendRgba, @ptrCast(&c.objc_msgSend));

        // [window setTitlebarAppearsTransparent:YES] lets backgroundColor show
        // through the title bar; the content view keeps its normal frame.
        msg_send_bool(ns_window, sel_transparent, 1);
        const color = msg_send_rgba(ns_color, sel_rgba, toUnit(r), toUnit(g), toUnit(b), 1.0) orelse return false;
        _ = msg_send_id(ns_window, sel_set_bg, color);

        // Pin the window appearance to the theme's luminance so the title text
        // and traffic lights stay legible regardless of the system appearance.
        const light_bg = @as(u32, r) + @as(u32, g) + @as(u32, b) > 382;
        const appearance_name: [*:0]const u8 = if (light_bg) "NSAppearanceNameAqua" else "NSAppearanceNameDarkAqua";
        const name_str = msg_send_id(ns_string, sel_utf8, cstrArg(appearance_name)) orelse return false;
        const appearance = msg_send_id(ns_appearance, sel_named, name_str) orelse return false;
        _ = msg_send_id(ns_window, sel_set_appearance, appearance);

        return placeNameAtRight(ns_window, ns_string, sel_utf8, name);
    }

    // Hide the centered system title and add the app name as a right-aligned
    // title bar accessory (NSTitlebarAccessoryViewController, the AppKit API for
    // views that live in the title bar beside the traffic lights).
    fn placeNameAtRight(ns_window: ?*anyopaque, ns_string: ?*anyopaque, sel_utf8: ?*anyopaque, name: [*:0]const u8) bool {
        // ponytail: `frame` returns NSRect by value, which plain objc_msgSend only
        // handles on arm64 (HFA in v0-v3); x86_64 needs objc_msgSend_stret. Keep
        // the centered title there instead of adding the second entry point.
        if (builtin.cpu.arch != .aarch64) return true;

        const ns_text_field = c.objc_getClass("NSTextField") orelse return false;
        const ns_font = c.objc_getClass("NSFont") orelse return false;
        const ns_accessory_vc = c.objc_getClass("NSTitlebarAccessoryViewController") orelse return false;
        const sel_label_with = c.sel_registerName("labelWithString:") orelse return false;
        const sel_title_font = c.sel_registerName("titleBarFontOfSize:") orelse return false;
        const sel_set_font = c.sel_registerName("setFont:") orelse return false;
        const sel_size_to_fit = c.sel_registerName("sizeToFit") orelse return false;
        const sel_frame = c.sel_registerName("frame") orelse return false;
        const sel_set_frame_size = c.sel_registerName("setFrameSize:") orelse return false;
        const sel_alloc = c.sel_registerName("alloc") orelse return false;
        const sel_init = c.sel_registerName("init") orelse return false;
        const sel_set_view = c.sel_registerName("setView:") orelse return false;
        const sel_set_layout = c.sel_registerName("setLayoutAttribute:") orelse return false;
        const sel_add_accessory = c.sel_registerName("addTitlebarAccessoryViewController:") orelse return false;
        const sel_title_visibility = c.sel_registerName("setTitleVisibility:") orelse return false;

        const msg_send = @as(MsgSend, @ptrCast(&c.objc_msgSend));
        const msg_send_id = @as(MsgSendIdArg, @ptrCast(&c.objc_msgSend));
        const msg_send_int = @as(MsgSendIntArg, @ptrCast(&c.objc_msgSend));
        const msg_send_float = @as(MsgSendFloatArg, @ptrCast(&c.objc_msgSend));
        const msg_send_size = @as(MsgSendSizeArg, @ptrCast(&c.objc_msgSend));
        const msg_send_rect = @as(MsgSendRect, @ptrCast(&c.objc_msgSend));

        const name_str = msg_send_id(ns_string, sel_utf8, cstrArg(name)) orelse return false;
        const label = msg_send_id(ns_text_field, sel_label_with, name_str) orelse return false;
        // Same face as the system title so it reads as the window title, not a widget.
        if (msg_send_float(ns_font, sel_title_font, 0)) |font| _ = msg_send_id(label, sel_set_font, font);
        _ = msg_send(label, sel_size_to_fit);
        // Widen the frame so the (left-aligned) text ends a padding before the window edge.
        const frame = msg_send_rect(label, sel_frame);
        msg_send_size(label, sel_set_frame_size, frame.w + title_right_padding, frame.h);

        const vc_alloc = msg_send(ns_accessory_vc, sel_alloc) orelse return false;
        const vc = msg_send(vc_alloc, sel_init) orelse return false;
        _ = msg_send_id(vc, sel_set_view, label);
        msg_send_int(vc, sel_set_layout, ns_layout_attribute_right);
        _ = msg_send_id(ns_window, sel_add_accessory, vc);
        msg_send_int(ns_window, sel_title_visibility, ns_window_title_hidden);
        return true;
    }

    fn cstrArg(s: [*:0]const u8) ?*anyopaque {
        return @ptrCast(@constCast(s));
    }

    fn toUnit(v: u8) f64 {
        return @as(f64, @floatFromInt(v)) / 255.0;
    }
} else struct {
    fn apply(_: *c_sdl.SDL_Window, _: [*:0]const u8, _: u8, _: u8, _: u8) bool {
        return false;
    }
};

/// Tint the native title bar to match the theme background and show `name`
/// at its far right in place of the centered system title. No-op off macOS.
pub fn style(window: *c_sdl.SDL_Window, name: [*:0]const u8, r: u8, g: u8, b: u8) void {
    if (!Impl.apply(window, name, r, g, b)) {
        log.warn("could not style title bar", .{});
    }
}
