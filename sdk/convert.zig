//! Checked conversion between Godot Variants and Zig values.
//!
//! Rules: the Variant type must match the Zig type exactly, with these
//! extra pairs: INT into a float; FLOAT into an integer only when the value
//! is finite, integral and in range; STRING and STRING_NAME into each other.
//! Integers are range-checked. An enum value with no Zig tag is rejected; a
//! flag struct (a packed struct with a backing integer) takes any value that
//! fits its backing integer, as Godot allows any bits in a bitfield.
//!
//! v1 types: `bool`; `i8`..`i64`, `u8`..`u32`; `f32`, `f64`; Zig enums and
//! flag structs whose integer fits in `i64`; the gdzig builtins Vector2,
//! Vector2i, Vector3, Vector3i, Vector4, Vector4i, Color, Rect2, Rect2i,
//! Quaternion, Plane, Aabb, Basis, Transform2d, Transform3d, Projection,
//! String, StringName and NodePath. Not in v1: `u64`, `usize`, arrays,
//! dictionaries, slices. Objects (and NIL into a null object) come later.
//!
//! Only Godot's raw variant-from-type and type-from-variant constructors are
//! used, with locals at Godot's widths (int64, double, one-byte bool), and no
//! lazy caches. Nothing here panics on bad input.
const std = @import("std");
const godot = @import("gdzig");
const b = godot.builtin;

/// A failed read. `expected` is the Variant type the Zig type needs, for
/// `CallError.expected`.
pub const ReadError = struct { expected: u32 };

// GDExtensionVariantType values.
const t_bool: u32 = 1;
const t_int: u32 = 2;
const t_float: u32 = 3;
const t_string: u32 = 4;
const t_string_name: u32 = 21;

const Kind = enum { bool, int, float, enum_int, flags, builtin, unsupported };

const builtins = .{
    .{ b.String, 4 },   .{ b.Vector2, 5 },     .{ b.Vector2i, 6 },     .{ b.Rect2, 7 },
    .{ b.Rect2i, 8 },   .{ b.Vector3, 9 },     .{ b.Vector3i, 10 },    .{ b.Transform2d, 11 },
    .{ b.Vector4, 12 }, .{ b.Vector4i, 13 },   .{ b.Plane, 14 },       .{ b.Quaternion, 15 },
    .{ b.Aabb, 16 },    .{ b.Basis, 17 },      .{ b.Transform3d, 18 }, .{ b.Projection, 19 },
    .{ b.Color, 20 },   .{ b.StringName, 21 }, .{ b.NodePath, 22 },
};

fn builtinType(comptime T: type) ?u32 {
    inline for (builtins) |pair| {
        if (pair[0] == T) return pair[1];
    }
    return null;
}

/// True when every value of the integer type `I` fits in an `i64`.
fn fitsI64(comptime I: type) bool {
    const info = @typeInfo(I).int;
    return switch (info.signedness) {
        .signed => info.bits <= 64,
        .unsigned => info.bits <= 63,
    };
}

fn kind(comptime T: type) Kind {
    if (T == bool) return .bool;
    if (builtinType(T) != null) return .builtin;
    return switch (T) {
        i8, i16, i32, i64, u8, u16, u32 => .int,
        f32, f64 => .float,
        else => switch (@typeInfo(T)) {
            .@"enum" => |e| if (fitsI64(e.tag_type)) .enum_int else .unsupported,
            .@"struct" => |s| if (s.backing_integer) |I| (if (fitsI64(I)) .flags else .unsupported) else .unsupported,
            else => .unsupported,
        },
    };
}

/// Whether `T` converts to and from a Variant in v1.
pub fn supported(comptime T: type) bool {
    return comptime kind(T) != .unsupported;
}

/// The Variant type `T` is written as, and expects on read.
pub fn variantType(comptime T: type) u32 {
    return switch (comptime kind(T)) {
        .bool => t_bool,
        .int, .enum_int, .flags => t_int,
        .float => t_float,
        .builtin => builtinType(T).?,
        .unsupported => @compileError("ziggurat: no Variant conversion for type " ++ @typeName(T)),
    };
}

const FromType = *const fn (*anyopaque, *anyopaque) callconv(.c) void;
const ToType = *const fn (*anyopaque, *anyopaque) callconv(.c) void;

fn fromTypeCtor(t: u32) ?FromType {
    return @ptrCast(godot.raw.getVariantFromTypeConstructor(t));
}

fn toTypeCtor(t: u32) ?ToType {
    return @ptrCast(godot.raw.getVariantToTypeConstructor(t));
}

/// Builds a Variant of type `t` from `*value` in the uninitialised `ret`,
/// or NIL when Godot has no constructor for `t`.
fn construct(t: u32, ret: *anyopaque, value: *anyopaque) void {
    const ctor = fromTypeCtor(t) orelse return godot.raw.variantNewNil(ret);
    ctor(ret, value);
}

/// Copies Variant `v` into the uninitialised `out` as type `t`. False when
/// Godot has no constructor for `t`.
fn extract(t: u32, v: *const anyopaque, out: *anyopaque) bool {
    const ctor = toTypeCtor(t) orelse return false;
    // Godot takes the source as non-const but only reads it.
    ctor(out, @constCast(v));
    return true;
}

/// Writes `value.*` into `ret`, which must be uninitialised Variant storage.
/// The new Variant is owned by the caller, who destroys it. String-like
/// values are copied (Godot adds a reference); `value` stays the caller's.
pub fn write(comptime T: type, value: *const T, ret: *anyopaque) void {
    switch (comptime kind(T)) {
        .bool => {
            var x: bool = value.*;
            construct(t_bool, ret, &x);
        },
        .int => {
            var x: i64 = value.*;
            construct(t_int, ret, &x);
        },
        .enum_int => {
            var x: i64 = @backingInt(value.*);
            construct(t_int, ret, &x);
        },
        .flags => {
            const I = @typeInfo(T).@"struct".backing_integer.?;
            var x: i64 = @as(I, @bitCast(value.*));
            construct(t_int, ret, &x);
        },
        .float => {
            var x: f64 = value.*;
            construct(t_float, ret, &x);
        },
        .builtin => construct(builtinType(T).?, ret, @ptrCast(@constCast(value))),
        .unsupported => @compileError("ziggurat: no Variant conversion for type " ++ @typeName(T)),
    }
}

/// Reads Variant `v` into `out.*`. On failure returns the expected Variant
/// type and leaves `out` unchanged. Never panics.
///
/// Never keeps a reference to `v`. A String, StringName or NodePath read
/// is a new engine value owned by the caller, who frees it with `deinit`.
pub fn read(comptime T: type, v: *const anyopaque, out: *T) ?ReadError {
    const expected = variantType(T);
    const fail: ReadError = .{ .expected = expected };
    const t: u32 = @intCast(godot.raw.variantGetType(v));
    switch (comptime kind(T)) {
        .bool => {
            if (t != t_bool) return fail;
            var x: bool = false;
            if (!extract(t_bool, v, &x)) return fail;
            out.* = x;
        },
        .int => out.* = std.math.cast(T, readInt(t, v) orelse return fail) orelse return fail,
        .enum_int => {
            const Tag = @typeInfo(T).@"enum".tag_type;
            const x = std.math.cast(Tag, readInt(t, v) orelse return fail) orelse return fail;
            out.* = std.enums.fromInt(T, x) orelse return fail;
        },
        .flags => {
            const I = @typeInfo(T).@"struct".backing_integer.?;
            out.* = @bitCast(std.math.cast(I, readInt(t, v) orelse return fail) orelse return fail);
        },
        .float => {
            switch (t) {
                t_float => {
                    var x: f64 = 0;
                    if (!extract(t_float, v, &x)) return fail;
                    out.* = @floatCast(x);
                },
                t_int => {
                    var x: i64 = 0;
                    if (!extract(t_int, v, &x)) return fail;
                    out.* = @floatFromInt(x);
                },
                else => return fail,
            }
        },
        .builtin => {
            const string_pair = (T == b.String and t == t_string_name) or (T == b.StringName and t == t_string);
            if (t != expected and !string_pair) return fail;
            // Godot's constructor converts STRING and STRING_NAME into each
            // other; every other pair is an exact match.
            var x: T = undefined;
            if (!extract(expected, v, &x)) return fail;
            out.* = x;
        },
        .unsupported => @compileError("ziggurat: no Variant conversion for type " ++ @typeName(T)),
    }
    return null;
}

/// An INT, or a FLOAT that is finite, integral and inside `i64`.
fn readInt(t: u32, v: *const anyopaque) ?i64 {
    switch (t) {
        t_int => {
            var x: i64 = 0;
            if (!extract(t_int, v, &x)) return null;
            return x;
        },
        t_float => {
            var x: f64 = 0;
            if (!extract(t_float, v, &x)) return null;
            // NaN fails both comparisons; 2^63 itself is out of range.
            if (!(x >= -0x1p63 and x < 0x1p63)) return null;
            if (@trunc(x) != x) return null;
            return @intFromFloat(x);
        },
        else => return null,
    }
}
