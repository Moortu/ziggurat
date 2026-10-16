//! SDK tests that run inside a headless Godot through gdzig's test harness.
//!
//! Every test also runs once more in a single Godot that exits normally
//! (see `clean_exit.zig`), so leaks reported at exit fail the build.
const std = @import("std");
const testing = std.testing;
const ziggurat = @import("ziggurat");
const abi = @import("ziggurat_abi");
const clean_exit = @import("clean_exit.zig");
const godot = ziggurat.godot;
const convert = ziggurat.convert;
const b = godot.builtin;
const Variant = b.Variant;

comptime {
    _ = clean_exit;
}

// Variant types (GDExtensionVariantType).
const t_nil: u32 = 0;
const t_bool: u32 = 1;
const t_int: u32 = 2;
const t_float: u32 = 3;
const t_string: u32 = 4;
const t_vector2: u32 = 5;
const t_string_name: u32 = 21;
const t_node_path: u32 = 22;

const Ctor = *const fn (*anyopaque, *anyopaque) callconv(.c) void;

fn fromType(t: u32) Ctor {
    return @ptrCast(godot.raw.getVariantFromTypeConstructor(t).?);
}

fn toType(t: u32) Ctor {
    return @ptrCast(godot.raw.getVariantToTypeConstructor(t).?);
}

fn typeOf(v: *const Variant) u32 {
    return @intCast(godot.raw.variantGetType(v));
}

fn destroy(v: *Variant) void {
    godot.raw.variantDestroy(v);
}

// Source Variants built without `convert`, so a reject test does not trust
// the code under test to build its input.
fn makeInt(x: i64) Variant {
    var v: Variant = undefined;
    var in = x;
    fromType(t_int)(&v, &in);
    return v;
}

fn makeFloat(x: f64) Variant {
    var v: Variant = undefined;
    var in = x;
    fromType(t_float)(&v, &in);
    return v;
}

fn makeNil() Variant {
    var v: Variant = undefined;
    godot.raw.variantNewNil(&v);
    return v;
}

fn makeString(utf8: []const u8) !Variant {
    var s = try b.String.fromUtf8(utf8);
    defer s.deinit();
    var v: Variant = undefined;
    fromType(t_string)(&v, &s);
    return v;
}

fn expectUtf8(expected: []const u8, s: *const b.String) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, s.toUtf8Buf(&buf));
}

/// Builds an engine string type from UTF-8; the caller frees it.
fn makeStringLike(comptime T: type, utf8: []const u8) !T {
    var s = try b.String.fromUtf8(utf8);
    if (T == b.String) return s;
    defer s.deinit();
    return switch (T) {
        b.StringName => b.StringName.fromString(s),
        b.NodePath => b.NodePath.fromString(s),
        else => @compileError("not a string type"),
    };
}

fn freeStringLike(comptime T: type, value: *T) void {
    value.deinit();
}

fn expectStringLike(comptime T: type, expected: []const u8, value: *const T) !void {
    if (T == b.String) return expectUtf8(expected, value);
    var s = switch (T) {
        b.StringName => b.String.fromStringName(value.*),
        b.NodePath => b.String.fromNodePath(value.*),
        else => @compileError("not a string type"),
    };
    defer s.deinit();
    try expectUtf8(expected, &s);
}

/// Writes `value`, checks the Variant type, destroys the Variant, then
/// reads back. Bitwise equality, so -0.0 stays distinct from 0.0.
fn roundTrip(comptime T: type, value: T) !void {
    var v: Variant = undefined;
    convert.write(T, &value, &v);
    defer destroy(&v);
    try testing.expectEqual(convert.variantType(T), typeOf(&v));
    var out: T = undefined;
    if (convert.read(T, &v, &out)) |e| {
        std.debug.print("read {s} failed, expected type {d}\n", .{ @typeName(T), e.expected });
        return error.ReadFailed;
    }
    try testing.expectEqualSlices(u8, std.mem.asBytes(&value), std.mem.asBytes(&out));
}

fn roundTripString(comptime T: type, utf8: []const u8) !void {
    var value = try makeStringLike(T, utf8);
    defer freeStringLike(T, &value);
    var v: Variant = undefined;
    convert.write(T, &value, &v);
    try testing.expectEqual(convert.variantType(T), typeOf(&v));
    var out: T = undefined;
    const err = convert.read(T, &v, &out);
    // The read value must not depend on the source Variant.
    destroy(&v);
    if (err) |e| {
        std.debug.print("read {s} failed, expected type {d}\n", .{ @typeName(T), e.expected });
        return error.ReadFailed;
    }
    defer freeStringLike(T, &out);
    try expectStringLike(T, utf8, &out);
}

/// Reading `v` as `T` must fail with `expected`.
fn expectReject(comptime T: type, v: *const Variant, expected: u32) !void {
    var out: T = undefined;
    const err = convert.read(T, v, &out) orelse return error.AcceptedBadValue;
    try testing.expectEqual(expected, err.expected);
}

const Three = enum { a, b, c };
const ThreeU8 = enum(u8) { a, b, c };
const Signed = enum(i16) { low = -300, high = 300 };
const Open = enum(u8) { a, b, _ };

test "harness runs" {
    var v = makeInt(7);
    defer destroy(&v);
    try testing.expectEqual(t_int, typeOf(&v));
    var out: i64 = 0;
    toType(t_int)(&out, &v);
    try testing.expectEqual(@as(i64, 7), out);
}

test "convert supported types" {
    inline for (.{
        bool,         i8,         i16,        i32,       i64,           u8,            u16,                      u32,
        f32,          f64,        Three,      ThreeU8,   Signed,        Open,          godot.global.MethodFlags, b.Vector2,
        b.Vector2i,   b.Vector3,  b.Vector3i, b.Vector4, b.Vector4i,    b.Color,       b.Rect2,                  b.Rect2i,
        b.Quaternion, b.Plane,    b.Aabb,     b.Basis,   b.Transform2d, b.Transform3d, b.Projection,             b.String,
        b.StringName, b.NodePath,
    }) |T| try testing.expect(convert.supported(T));
    inline for (.{ u64, usize, i128, u63, f16, b.Array, b.Dictionary, []const u8, [3]i32, *i32, void, b.Rid }) |T|
        try testing.expect(!convert.supported(T));
    try testing.expectEqual(t_bool, convert.variantType(bool));
    try testing.expectEqual(t_int, convert.variantType(u32));
    try testing.expectEqual(t_int, convert.variantType(Three));
    try testing.expectEqual(t_int, convert.variantType(godot.global.MethodFlags));
    try testing.expectEqual(t_float, convert.variantType(f32));
    try testing.expectEqual(t_vector2, convert.variantType(b.Vector2));
    try testing.expectEqual(@as(u32, 19), convert.variantType(b.Projection));
    try testing.expectEqual(@as(u32, 20), convert.variantType(b.Color));
    try testing.expectEqual(t_string_name, convert.variantType(b.StringName));
    try testing.expectEqual(t_node_path, convert.variantType(b.NodePath));
}

test "convert round trips" {
    try roundTrip(bool, false);
    try roundTrip(bool, true);
    inline for (.{ i8, i16, i32, i64, u8, u16, u32 }) |T| {
        try roundTrip(T, std.math.minInt(T));
        try roundTrip(T, std.math.maxInt(T));
    }
    inline for (.{ f32, f64 }) |T| {
        try roundTrip(T, -0.0);
        try roundTrip(T, std.math.floatTrueMin(T));
        try roundTrip(T, 1e30);
    }
    try roundTrip(Three, .a);
    try roundTrip(Three, .c);
    try roundTrip(Signed, .low);
    try roundTrip(Signed, .high);
    try roundTrip(godot.global.MethodFlags, .method_flags_default);
    // Bitfields accept bits outside the named fields.
    try roundTrip(godot.global.MethodFlags, @bitCast(@as(u32, 0xFFFF_FFFF)));
    try roundTrip(b.Vector2, .{ .x = 1.5, .y = -2.25 });
    try roundTrip(b.Vector2, .{ .x = -0.0, .y = 3e38 });
    try roundTrip(b.Vector2i, .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) });
    try roundTrip(b.Vector2i, .{ .x = 0, .y = -1 });
    try roundTrip(b.Vector3, .{ .x = 1, .y = 2, .z = 3 });
    try roundTrip(b.Vector3, .{ .x = -1e-3, .y = 0, .z = 1e30 });
    try roundTrip(b.Vector3i, .{ .x = 1, .y = 2, .z = 3 });
    try roundTrip(b.Vector3i, .{ .x = std.math.minInt(i32), .y = 0, .z = std.math.maxInt(i32) });
    try roundTrip(b.Vector4, .{ .x = 1, .y = 2, .z = 3, .w = 4 });
    try roundTrip(b.Vector4, .{ .x = -0.5, .y = 0.25, .z = -8, .w = 1e20 });
    try roundTrip(b.Vector4i, .{ .x = 1, .y = 2, .z = 3, .w = 4 });
    try roundTrip(b.Vector4i, .{ .x = -9, .y = 0, .z = 9, .w = std.math.maxInt(i32) });
    try roundTrip(b.Color, .{ .r = 1, .g = 0.5, .b = 0.25, .a = 1 });
    try roundTrip(b.Color, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try roundTrip(b.Rect2, .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .x = 3, .y = 4 } });
    try roundTrip(b.Rect2, .{ .position = .{ .x = -1, .y = -2 }, .size = .{ .x = 0, .y = 0.5 } });
    try roundTrip(b.Rect2i, .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .x = 3, .y = 4 } });
    try roundTrip(b.Rect2i, .{ .position = .{ .x = -5, .y = 0 }, .size = .{ .x = 0, .y = 7 } });
    try roundTrip(b.Quaternion, .{ .x = 0, .y = 0, .z = 0, .w = 1 });
    try roundTrip(b.Quaternion, .{ .x = 0.5, .y = -0.5, .z = 0.5, .w = -0.5 });
    try roundTrip(b.Plane, .{ .normal = .{ .x = 0, .y = 1, .z = 0 }, .d = 2 });
    try roundTrip(b.Plane, .{ .normal = .{ .x = 1, .y = 0, .z = 0 }, .d = -3.5 });
    try roundTrip(b.Aabb, .{ .position = .{ .x = 1, .y = 2, .z = 3 }, .size = .{ .x = 4, .y = 5, .z = 6 } });
    try roundTrip(b.Aabb, .{ .position = .{ .x = -1, .y = 0, .z = 0 }, .size = .{ .x = 0, .y = 0, .z = 0 } });
    const basis_a: b.Basis = .{ .x = .{ .x = 1, .y = 0, .z = 0 }, .y = .{ .x = 0, .y = 1, .z = 0 }, .z = .{ .x = 0, .y = 0, .z = 1 } };
    const basis_b: b.Basis = .{ .x = .{ .x = 1, .y = 2, .z = 3 }, .y = .{ .x = 4, .y = 5, .z = 6 }, .z = .{ .x = 7, .y = 8, .z = 9 } };
    try roundTrip(b.Basis, basis_a);
    try roundTrip(b.Basis, basis_b);
    try roundTrip(b.Transform2d, .{ .x = .{ .x = 1, .y = 0 }, .y = .{ .x = 0, .y = 1 }, .origin = .{ .x = 0, .y = 0 } });
    try roundTrip(b.Transform2d, .{ .x = .{ .x = 1, .y = 2 }, .y = .{ .x = 3, .y = 4 }, .origin = .{ .x = 5, .y = 6 } });
    try roundTrip(b.Transform3d, .{ .basis = basis_a, .origin = .{ .x = 0, .y = 0, .z = 0 } });
    try roundTrip(b.Transform3d, .{ .basis = basis_b, .origin = .{ .x = 10, .y = 11, .z = 12 } });
    const v4a: b.Vector4 = .{ .x = 1, .y = 2, .z = 3, .w = 4 };
    const v4b: b.Vector4 = .{ .x = -1, .y = 0.5, .z = 0, .w = 9 };
    try roundTrip(b.Projection, .{ .x = v4a, .y = v4b, .z = v4a, .w = v4b });
    try roundTrip(b.Projection, .{ .x = v4b, .y = v4b, .z = v4a, .w = v4a });
    try roundTripString(b.String, "plain");
    try roundTripString(b.String, "h\u{e9}llo \u{2728} \u{65e5}\u{672c}\u{8a9e}");
    try roundTripString(b.StringName, "a_name");
    try roundTripString(b.StringName, "n\u{e4}me_\u{2728}");
    try roundTripString(b.NodePath, "Root/Child:position");
    try roundTripString(b.NodePath, "../Sibling");
}

test "convert rejects" {
    var int1 = makeInt(1);
    defer destroy(&int1);
    try expectReject(bool, &int1, t_bool);

    var big = makeInt(1 << 31);
    defer destroy(&big);
    try expectReject(i32, &big, t_int);

    var minus = makeInt(-1);
    defer destroy(&minus);
    try expectReject(u8, &minus, t_int);
    try expectReject(u32, &minus, t_int);

    for ([_]f64{ 1.5, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 0x1p63 }) |x| {
        var f = makeFloat(x);
        defer destroy(&f);
        try expectReject(i32, &f, t_int);
        try expectReject(i64, &f, t_int);
    }
    var huge = makeFloat(0x1p31);
    defer destroy(&huge);
    try expectReject(i32, &huge, t_int);

    var nil = makeNil();
    defer destroy(&nil);
    try expectReject(b.Vector2, &nil, t_vector2);
    try expectReject(b.String, &nil, t_string);
    try expectReject(i64, &nil, t_int);

    var str = try makeString("12");
    defer destroy(&str);
    try expectReject(i64, &str, t_int);
    try expectReject(f64, &str, t_float);
    try expectReject(b.NodePath, &str, t_node_path);

    var flt = makeFloat(1.0);
    defer destroy(&flt);
    try expectReject(bool, &flt, t_bool);
    try expectReject(b.String, &flt, t_string);
}

test "convert rejects at width boundaries" {
    inline for (.{ i8, i16, i32, u8, u16, u32 }) |T| {
        var above = makeInt(@as(i64, std.math.maxInt(T)) + 1);
        defer destroy(&above);
        try expectReject(T, &above, t_int);
        var below = makeInt(@as(i64, std.math.minInt(T)) - 1);
        defer destroy(&below);
        try expectReject(T, &below, t_int);
        // The same values as FLOAT.
        var above_f = makeFloat(@floatFromInt(@as(i64, std.math.maxInt(T)) + 1));
        defer destroy(&above_f);
        try expectReject(T, &above_f, t_int);
        var below_f = makeFloat(@floatFromInt(@as(i64, std.math.minInt(T)) - 1));
        defer destroy(&below_f);
        try expectReject(T, &below_f, t_int);
    }
    // FLOAT 2^31 fits u32.
    var f31 = makeFloat(0x1p31);
    defer destroy(&f31);
    var u: u32 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(u32, &f31, &u));
    try testing.expectEqual(@as(u32, 1 << 31), u);
}

test "float into f32 range" {
    // Finite but above f32's range: rejected.
    for ([_]f64{ 1e300, -1e300, 0x1p128 }) |x| {
        var v = makeFloat(x);
        defer destroy(&v);
        try expectReject(f32, &v, t_float);
        // f64 takes it unchanged.
        var d: f64 = 0;
        try testing.expectEqual(@as(?convert.ReadError, null), convert.read(f64, &v, &d));
        try testing.expectEqual(x, d);
    }
    // The largest f32 is accepted.
    var max = makeFloat(std.math.floatMax(f32));
    defer destroy(&max);
    var m: f32 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(f32, &max, &m));
    try testing.expectEqual(std.math.floatMax(f32), m);
    // inf and NaN pass through as themselves.
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64) }) |x| {
        var v = makeFloat(x);
        defer destroy(&v);
        var f: f32 = 0;
        try testing.expectEqual(@as(?convert.ReadError, null), convert.read(f32, &v, &f));
        try testing.expectEqual(@as(f32, @floatCast(x)), f);
    }
    var nan = makeFloat(std.math.nan(f64));
    defer destroy(&nan);
    var n: f32 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(f32, &nan, &n));
    try testing.expect(std.math.isNan(n));
}

test "enum out of range" {
    var v = makeInt(999);
    defer destroy(&v);
    try expectReject(Three, &v, t_int);
    try expectReject(ThreeU8, &v, t_int);
    // Fits the tag type but names no tag.
    var three = makeInt(3);
    defer destroy(&three);
    try expectReject(ThreeU8, &three, t_int);
    // A non-exhaustive enum takes any value of its tag type.
    var open: Open = .a;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(Open, &three, &open));
    try testing.expectEqual(@as(u8, 3), @backingInt(open));
    try expectReject(Open, &v, t_int);
    try roundTrip(Open, @fromBackingInt(@intCast(200)));
    // A flag struct takes any value that fits its backing integer.
    var neg = makeInt(-1);
    defer destroy(&neg);
    try expectReject(godot.global.MethodFlags, &neg, t_int);
    var too_big = makeInt(1 << 32);
    defer destroy(&too_big);
    try expectReject(godot.global.MethodFlags, &too_big, t_int);
}

test "strict pairs" {
    var three = makeInt(3);
    defer destroy(&three);
    var f: f32 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(f32, &three, &f));
    try testing.expectEqual(@as(f32, 3.0), f);
    var d: f64 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(f64, &three, &d));
    try testing.expectEqual(@as(f64, 3.0), d);

    var four = makeFloat(4.0);
    defer destroy(&four);
    var i: i32 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(i32, &four, &i));
    try testing.expectEqual(@as(i32, 4), i);

    var neg_zero = makeFloat(-0.0);
    defer destroy(&neg_zero);
    var u: u8 = 9;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(u8, &neg_zero, &u));
    try testing.expectEqual(@as(u8, 0), u);

    var low = makeFloat(-0x1p63);
    defer destroy(&low);
    var l: i64 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(i64, &low, &l));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), l);

    // STRING into StringName, then the StringName back into a String.
    const text = "na\u{ef}ve_\u{2728}";
    var str = try makeString(text);
    defer destroy(&str);
    var name: b.StringName = undefined;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(b.StringName, &str, &name));
    defer name.deinit();
    try expectStringLike(b.StringName, text, &name);
    var name_v: Variant = undefined;
    convert.write(b.StringName, &name, &name_v);
    defer destroy(&name_v);
    try testing.expectEqual(t_string_name, typeOf(&name_v));
    var back: b.String = undefined;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(b.String, &name_v, &back));
    defer back.deinit();
    try expectUtf8(text, &back);
}

test "static name is stable" {
    const Name = ziggurat.StaticName("ziggurat_static_probe");
    const first = Name.ptr();
    const second = Name.ptr();
    try testing.expectEqual(first, second);
    const sn: *const b.StringName = @ptrCast(@alignCast(first));
    try expectStringLike(b.StringName, "ziggurat_static_probe", sn);
    // Usable as an engine argument: a StringName Variant built from it.
    var v: Variant = undefined;
    convert.write(b.StringName, sn, &v);
    defer destroy(&v);
    var s: b.String = undefined;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(b.String, &v, &s));
    defer s.deinit();
    try expectUtf8("ziggurat_static_probe", &s);
}

/// The marker the clean-exit run requires in Godot's output.
pub const module_init_marker = "ziggurat-test: moduleInit log ok";

var test_api: abi.HostApi = undefined;

fn hostAlloc(_: u32, _: usize, _: u32) callconv(.c) ?*anyopaque {
    return null;
}

fn hostFree(_: u32, _: ?*anyopaque, _: usize, _: u32) callconv(.c) void {}

fn hostSwap() callconv(.c) void {}

/// Prints through Godot's `print`, so the line reaches Godot's own output.
fn hostLog(_: u32, msg: [*]const u8, len: usize) callconv(.c) void {
    var s = b.String.fromUtf8(msg[0..len]) catch return;
    defer s.deinit();
    var v: Variant = undefined;
    fromType(t_string)(&v, &s);
    defer destroy(&v);
    godot.general.print(v, .{});
}

test "moduleInit with the real proc table" {
    // Only the clean-exit entry sees Godot's get_proc_address; the harness
    // entry keeps it to itself.
    const get_proc = clean_exit.real_get_proc_address orelse return error.SkipZigTest;
    test_api = .{
        .size = @sizeOf(abi.HostApi),
        .get_proc_address = get_proc,
        .library = clean_exit.real_library,
        .alloc = &hostAlloc,
        .free = &hostFree,
        .log = &hostLog,
        .request_swap = &hostSwap,
    };
    ziggurat.moduleInit(&test_api, 7);
    try testing.expectEqual(@as(u32, 7), ziggurat.generation());
    // gdzig still works after moduleInit re-initialised it.
    var v = makeInt(11);
    defer destroy(&v);
    var out: i64 = 0;
    try testing.expectEqual(@as(?convert.ReadError, null), convert.read(i64, &v, &out));
    try testing.expectEqual(@as(i64, 11), out);
    ziggurat.log(.info, "{s} gen={d}", .{ module_init_marker, ziggurat.generation() });
}
