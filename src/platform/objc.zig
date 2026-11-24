// Objective-C runtime interop shared by the AppKit glue in this directory:
// classes, strings, a typed objc_msgSend and autorelease pools. There are no
// Objective-C sources in the build, so everything goes through the runtime.
// macOS only: import it from code that is compiled for macOS alone.

const std = @import("std");

pub const runtime = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});

pub const Id = ?*anyopaque;

pub fn cls(name: [*:0]const u8) Id {
    return @ptrCast(runtime.objc_getClass(name));
}

pub fn alloc(class_name: [*:0]const u8) Id {
    return send(Id, cls(class_name), "alloc", .{});
}

/// An autoreleased NSString.
pub fn string(utf8: [*:0]const u8) Id {
    return send(Id, cls("NSString"), "stringWithUTF8String:", .{utf8});
}

/// Typed objc_msgSend: `send(R, target, "selector:", .{args...})` casts
/// objc_msgSend to `fn (id, SEL, args...) R` (C ABI) and calls it. Args must
/// be runtime-typed (no comptime literals): `@as(f64, 0)`, not `0`. On arm64 a
/// struct of up to four doubles (NSPoint, NSSize, NSRect) is passed and
/// returned like that many separate doubles.
pub fn send(comptime R: type, target: Id, comptime selector: [*:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    const arg_types = comptime blk: {
        var types: [fields.len]type = undefined;
        for (fields, 0..) |field, i| types[i] = field.type;
        break :blk types;
    };
    const func: *const msgFnType(R, &arg_types) = @ptrCast(&runtime.objc_msgSend);
    const sel: Id = @ptrCast(runtime.sel_registerName(selector));
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

extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

/// An autorelease pool for AppKit calls made from the frame loop, which runs
/// outside the pool SDL keeps around its own event pump:
/// `const pool = objc.Pool.push(); defer pool.pop();`
pub const Pool = struct {
    token: ?*anyopaque,

    pub fn push() Pool {
        return .{ .token = objc_autoreleasePoolPush() };
    }

    pub fn pop(self: Pool) void {
        objc_autoreleasePoolPop(self.token);
    }
};
