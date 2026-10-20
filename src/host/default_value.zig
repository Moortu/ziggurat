//! Property defaults as typed JSON, for the descriptor cache.
//!
//! A default is stored as plain data of the property's declared Variant
//! type and rebuilt with Godot's own constructors. No text is ever handed to
//! `str_to_var` (it can build any engine object and overflows the stack on
//! deep nesting). The JSON forms, by declared type:
//! - bool: `true`/`false`; int (also enums and flags): a JSON integer;
//! - float: a finite JSON number, or the strings "nan", "inf", "-inf";
//! - String, StringName, NodePath: a JSON string;
//! - Vector2/2i/3/3i/4/4i, Color, Rect2/2i, Plane, Quaternion, AABB, Basis,
//!   Transform2D, Transform3D, Projection: a flat array of exactly the
//!   right number of numbers (2, 2, 3, 3, 4, 4, 4, 4, 4, 4, 4, 6, 9, 6, 12,
//!   16), in the field order of the gdzig struct (the same order Godot
//!   documents for each constructor: for Rect2 position then size, for
//!   Transform2D the x, y and origin columns, for Basis the x, y, z rows of
//!   gdzig's struct, for Transform3D the basis then origin, for Projection
//!   the x, y, z, w columns);
//! - object handles: `null`, which restores as a null object.
//! Integer components of the `i` vectors and rects must be integral and fit
//! an i32. Anything else (a wrong shape for the type, a nested array, a
//! non-finite component) does not fit: `fits` is false and the cache drops
//! that default.
//!
//! `fits`, parsing and writing are pure; `fromVariant` and `toVariant` call
//! into Godot.
const std = @import("std");
const godot = @import("gdzig");
const props = @import("props.zig");

const Allocator = std.mem.Allocator;
const Variant = godot.builtin.Variant;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const NodePath = godot.builtin.NodePath;

/// Godot's Variant type numbers (core/variant/variant.h, `Variant::Type`).
pub const t_bool: u32 = 1;
pub const t_int: u32 = 2;
pub const t_float: u32 = 3;
pub const t_string: u32 = 4;
pub const t_string_name: u32 = 21;
pub const t_node_path: u32 = 22;
pub const t_object: u32 = 24;

/// Most numbers an array default may hold (Projection).
pub const max_components = 16;

pub const Default = union(enum) {
    /// No default stored.
    absent,
    /// `null`: the default of an object handle.
    null_,
    boolean: bool,
    int: i64,
    float: f64,
    text: []const u8,
    nums: []const f64,

    /// Reads one default. Never recurses: an array may hold only numbers.
    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !Default {
        _ = options;
        const tok = try source.nextAlloc(a, .alloc_always);
        switch (tok) {
            .null => return .null_,
            .true => return .{ .boolean = true },
            .false => return .{ .boolean = false },
            .number, .allocated_number => |s| return parseNumber(s),
            .string, .allocated_string => |s| return .{ .text = s },
            .array_begin => {
                var list: std.ArrayList(f64) = .empty;
                while (true) {
                    const t = try source.nextAlloc(a, .alloc_always);
                    switch (t) {
                        .array_end => return .{ .nums = try list.toOwnedSlice(a) },
                        .number, .allocated_number => |s| {
                            if (list.items.len == max_components) return error.Overflow;
                            const f = std.fmt.parseFloat(f64, s) catch return error.InvalidNumber;
                            if (!std.math.isFinite(f)) return error.InvalidNumber;
                            try list.append(a, f);
                        },
                        else => return error.UnexpectedToken,
                    }
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(d: Default, jw: anytype) !void {
        switch (d) {
            .absent, .null_ => try jw.write(null),
            .boolean => |b| try jw.write(b),
            .int => |i| try jw.write(i),
            .float => |f| {
                if (std.math.isNan(f)) {
                    try jw.write("nan");
                } else if (std.math.isInf(f)) {
                    try jw.write(if (f < 0) "-inf" else "inf");
                } else try jw.write(f);
            },
            .text => |t| try jw.write(t),
            .nums => |ns| {
                try jw.beginArray();
                for (ns) |n| try jw.write(n);
                try jw.endArray();
            },
        }
    }
};

fn parseNumber(s: []const u8) !Default {
    const plain_int = for (s) |c| {
        if (!(std.ascii.isDigit(c) or c == '-')) break false;
    } else true;
    if (plain_int) {
        if (std.fmt.parseInt(i64, s, 10)) |i| return .{ .int = i } else |_| {}
    }
    const f = std.fmt.parseFloat(f64, s) catch return error.InvalidNumber;
    if (!std.math.isFinite(f)) return error.InvalidNumber;
    return .{ .float = f };
}

// ------------------------------------------------------------- shapes

const B = godot.builtin;

/// The types stored as number arrays, by Variant type number.
const array_types = .{
    .{ @as(u32, 5), B.Vector2 },
    .{ @as(u32, 6), B.Vector2i },
    .{ @as(u32, 7), B.Rect2 },
    .{ @as(u32, 8), B.Rect2i },
    .{ @as(u32, 9), B.Vector3 },
    .{ @as(u32, 10), B.Vector3i },
    .{ @as(u32, 11), B.Transform2d },
    .{ @as(u32, 12), B.Vector4 },
    .{ @as(u32, 13), B.Vector4i },
    .{ @as(u32, 14), B.Plane },
    .{ @as(u32, 15), B.Quaternion },
    .{ @as(u32, 16), B.Aabb },
    .{ @as(u32, 17), B.Basis },
    .{ @as(u32, 18), B.Transform3d },
    .{ @as(u32, 19), B.Projection },
    .{ @as(u32, 20), B.Color },
};

fn components(comptime T: type) comptime_int {
    return switch (@typeInfo(T)) {
        .float, .int => 1,
        .@"struct" => |s| blk: {
            var n = 0;
            for (s.field_types) |FT| n += components(FT);
            break :blk n;
        },
        else => @compileError("no components for " ++ @typeName(T)),
    };
}

fn flatten(comptime T: type, v: T, out: []f64, n: *usize) void {
    switch (@typeInfo(T)) {
        .float, .int => {
            out[n.*] = if (@typeInfo(T) == .float) @as(f64, @floatCast(v)) else @as(f64, @floatFromInt(v));
            n.* += 1;
        },
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, FT| flatten(FT, @field(v, name), out, n),
        else => @compileError("cannot flatten " ++ @typeName(T)),
    }
}

fn unflatten(comptime T: type, nums: []const f64, n: *usize) ?T {
    switch (@typeInfo(T)) {
        .float => {
            const x = nums[n.*];
            n.* += 1;
            const r: T = @floatCast(x);
            return if (std.math.isFinite(r)) r else null;
        },
        .int => {
            const x = nums[n.*];
            n.* += 1;
            if (x != @floor(x) or x < std.math.minInt(T) or x > std.math.maxInt(T)) return null;
            return @intFromFloat(x);
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names, s.field_types) |name, FT| @field(out, name) = unflatten(FT, nums, n) orelse return null;
            return out;
        },
        else => @compileError("cannot unflatten " ++ @typeName(T)),
    }
}

fn specialFloat(t: []const u8) ?f64 {
    if (std.mem.eql(u8, t, "nan")) return std.math.nan(f64);
    if (std.mem.eql(u8, t, "inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, t, "-inf")) return -std.math.inf(f64);
    return null;
}

/// True when `d` is a valid stored default for a property of Variant type
/// `type_id`. Pure.
pub fn fits(type_id: u32, d: Default) bool {
    switch (d) {
        .absent => return true,
        .null_ => return type_id == t_object,
        .boolean => return type_id == t_bool,
        .int => return type_id == t_int or type_id == t_float,
        .float => return type_id == t_float and std.math.isFinite(d.float),
        .text => |t| {
            if (type_id == t_float) return specialFloat(t) != null;
            if (type_id != t_string and type_id != t_string_name and type_id != t_node_path) return false;
            return std.unicode.utf8ValidateSlice(t) and std.mem.indexOfScalar(u8, t, 0) == null;
        },
        .nums => |ns| {
            inline for (array_types) |e| {
                if (type_id == e[0]) {
                    if (ns.len != components(e[1])) return false;
                    var n: usize = 0;
                    return unflatten(e[1], ns, &n) != null;
                }
            }
            return false;
        },
    }
}

// ------------------------------------------------------------- Godot

/// The default of a property of declared type `type_id` whose module value
/// is `v`; `.absent` when `v` is not of that type or has no stored form.
/// Calls Godot.
pub fn fromVariant(a: Allocator, type_id: u32, v: Variant) Allocator.Error!Default {
    switch (type_id) {
        t_bool => return if (v.as(bool)) |b| .{ .boolean = b } else .absent,
        t_int => return if (v.tag == .int) .{ .int = v.as(i64) orelse return .absent } else .absent,
        t_float => {
            if (v.tag != .float) return .absent;
            return .{ .float = v.as(f64) orelse return .absent };
        },
        t_string, t_string_name, t_node_path => {
            const want: Variant.Tag = switch (type_id) {
                t_string => .string,
                t_string_name => .string_name,
                else => .node_path,
            };
            if (v.tag != want) return .absent;
            var s = v.stringify();
            defer s.deinit();
            const bytes = try props.utf8Alloc(a, &s);
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return .absent;
            return .{ .text = bytes };
        },
        t_object => return .null_,
        else => {},
    }
    inline for (array_types) |e| {
        if (type_id == e[0]) {
            const x = v.as(e[1]) orelse return .absent;
            var buf: [max_components]f64 = undefined;
            var n: usize = 0;
            flatten(e[1], x, &buf, &n);
            for (buf[0..n]) |f| if (!std.math.isFinite(f)) return .absent;
            return .{ .nums = try a.dupe(f64, buf[0..n]) };
        }
    }
    return .absent;
}

/// The Variant of declared type `type_id` that `d` stands for, built with
/// Godot's constructors; null when `d` does not fit the type (`fits`) or is
/// `.absent`. The caller owns the Variant. Calls Godot.
pub fn toVariant(type_id: u32, d: Default) ?Variant {
    if (!fits(type_id, d)) return null;
    switch (d) {
        .absent => return null,
        .null_ => return Variant.nil,
        .boolean => |b| return Variant.init(bool, b),
        .int => |i| return if (type_id == t_float) Variant.init(f64, @floatFromInt(i)) else Variant.init(i64, i),
        .float => |f| return Variant.init(f64, f),
        .text => |t| {
            if (type_id == t_float) return Variant.init(f64, specialFloat(t) orelse return null);
            var s = String.fromUtf8(t) catch return null;
            defer s.deinit();
            switch (type_id) {
                t_string => return Variant.init(String, s),
                t_string_name => {
                    var sn = StringName.fromUtf8(t);
                    defer sn.deinit();
                    return Variant.init(StringName, sn);
                },
                else => {
                    var np = NodePath.fromString(s);
                    defer np.deinit();
                    return Variant.init(NodePath, np);
                },
            }
        },
        .nums => |ns| {
            inline for (array_types) |e| {
                if (type_id == e[0]) {
                    var n: usize = 0;
                    const x = unflatten(e[1], ns, &n) orelse return null;
                    return Variant.init(e[1], x);
                }
            }
            return null;
        },
    }
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn parseText(a: Allocator, text: []const u8) !std.json.Parsed(Default) {
    return std.json.parseFromSlice(Default, a, text, .{});
}

test "defaults parse from their JSON forms" {
    var p = try parseText(testing.allocator, "[1, 2.5, -3e1]");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.value.nums.len);
    try testing.expectEqual(@as(f64, -30), p.value.nums[2]);
    var q = try parseText(testing.allocator, "300");
    defer q.deinit();
    try testing.expectEqual(@as(i64, 300), q.value.int);
    var r = try parseText(testing.allocator, "300.5");
    defer r.deinit();
    try testing.expectEqual(@as(f64, 300.5), r.value.float);
    var s = try parseText(testing.allocator, "null");
    defer s.deinit();
    try testing.expect(s.value == .null_);
}

test "defaults refuse nesting, objects and bad numbers without recursion" {
    const bad = [_][]const u8{ "[[1]]", "{\"a\":1}", "[1,\"2\"]", "[true]", "[1e999]", "1e999", "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]" };
    for (bad) |t| try testing.expect(std.meta.isError(parseText(testing.allocator, t)));
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendNTimes(testing.allocator, '[', 200_000);
    try testing.expect(std.meta.isError(parseText(testing.allocator, deep.items)));
}

const zeros: [16]f64 = @splat(0);

test "fits follows the declared type" {
    const two: []const f64 = &.{ 1, 2 };
    try testing.expect(fits(5, .{ .nums = two }));
    try testing.expect(!fits(5, .{ .nums = &.{1} }));
    try testing.expect(!fits(5, .{ .nums = &.{ 1, 2, 3 } }));
    try testing.expect(fits(6, .{ .nums = two }));
    try testing.expect(!fits(6, .{ .nums = &.{ 1.5, 2 } }));
    try testing.expect(!fits(6, .{ .nums = &.{ 1, 3e10 } }));
    try testing.expect(!fits(5, .{ .nums = &.{ 1, 1e300 } })); // beyond f32
    try testing.expect(fits(17, .{ .nums = zeros[0..9] }));
    try testing.expect(fits(19, .{ .nums = zeros[0..16] }));
    try testing.expect(fits(18, .{ .nums = zeros[0..12] }));
    try testing.expect(fits(11, .{ .nums = zeros[0..6] }));
    try testing.expect(fits(16, .{ .nums = zeros[0..6] }));
    try testing.expect(fits(t_float, .{ .int = 3 }));
    try testing.expect(!fits(t_int, .{ .float = 3 }));
    try testing.expect(fits(t_float, .{ .text = "nan" }));
    try testing.expect(fits(t_float, .{ .text = "-inf" }));
    try testing.expect(!fits(t_float, .{ .text = "Object(Node)" }));
    try testing.expect(fits(t_string, .{ .text = "any text ; at all" }));
    try testing.expect(!fits(t_int, .{ .text = "5" }));
    try testing.expect(!fits(t_string, .{ .int = 5 }));
    try testing.expect(!fits(t_string, .{ .text = "a\x00b" }));
    try testing.expect(!fits(t_string, .{ .text = "\xff" }));
    try testing.expect(fits(t_object, .null_));
    try testing.expect(!fits(t_int, .null_));
    try testing.expect(!fits(t_bool, .{ .int = 1 }));
    try testing.expect(!fits(0, .{ .int = 1 }));
}

test "writing then parsing keeps a default" {
    const cases = [_]Default{ .null_, .{ .boolean = true }, .{ .int = -7 }, .{ .float = 0.25 }, .{ .float = std.math.inf(f64) }, .{ .text = "a \"q\" \n" }, .{ .nums = &.{ 1, -2.5, 3 } } };
    for (cases) |c| {
        const text = try std.json.Stringify.valueAlloc(testing.allocator, c, .{});
        defer testing.allocator.free(text);
        var p = try parseText(testing.allocator, text);
        defer p.deinit();
        switch (c) {
            .float => |f| if (std.math.isInf(f)) {
                try testing.expectEqualStrings("inf", p.value.text);
            } else try testing.expectEqual(f, p.value.float),
            .int => |i| try testing.expectEqual(i, p.value.int),
            .boolean => |b| try testing.expectEqual(b, p.value.boolean),
            .text => |t| try testing.expectEqualStrings(t, p.value.text),
            .nums => |ns| try testing.expectEqualSlices(f64, ns, p.value.nums),
            else => try testing.expect(p.value == .null_),
        }
    }
}
