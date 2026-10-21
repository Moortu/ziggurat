//! A pure-Zig copy of a validated table: what the host needs to know about
//! every script without touching the module again. Strings are copied, so
//! the snapshot stays valid after the library is closed; defaults are
//! decoded from the defaults image by value kind and bit width, so no module
//! code runs. Imports only `std` and `abi`.
//!
//! `take` may assume `validate` passed, but every read is still bounded by
//! the validated counts and sizes.
//!
//! Defaults: only the kinds the host can decode give a value. `bool`, the
//! integer, enum and flags kinds (masked to `bits`, sign-extended for the
//! signed kinds), `float` (by size), `vector_f32`, `vector_i32` (components
//! from the size) and `color` give a number or a list of numbers;
//! `string_empty` and `object_null` give their own marker. `none` and
//! `other` (and any field that does not fit its kind) give `Default.none`.
const std = @import("std");
const abi = @import("abi.zig");

const Allocator = std.mem.Allocator;

/// Up to 16 `f32` (`vector_f32`, `color`).
pub const Floats = struct {
    v: [16]f32 = @splat(0),
    len: u8 = 0,

    pub fn slice(f: *const Floats) []const f32 {
        return f.v[0..f.len];
    }
};

/// Up to 4 `i32` (`vector_i32`).
pub const Ints = struct {
    v: [4]i32 = @splat(0),
    len: u8 = 0,

    pub fn slice(f: *const Ints) []const i32 {
        return f.v[0..f.len];
    }
};

pub const Default = union(enum) {
    /// No default the host can read.
    none,
    boolean: bool,
    int: i64,
    float: f64,
    floats: Floats,
    ints: Ints,
    /// An empty String, StringName or NodePath (of the property's type).
    string_empty,
    /// A null object handle.
    object_null,

    /// Equal tag and value; floats compare bit for bit (so NaN equals NaN).
    pub fn eql(x: Default, y: Default) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .none, .string_empty, .object_null => true,
            .boolean => |b| b == y.boolean,
            .int => |i| i == y.int,
            .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(y.float)),
            .floats => |f| f.len == y.floats.len and std.mem.eql(u32, @ptrCast(f.v[0..f.len]), @ptrCast(y.floats.v[0..f.len])),
            .ints => |f| f.len == y.ints.len and std.mem.eql(i32, f.v[0..f.len], y.ints.v[0..f.len]),
        };
    }
};

pub const ArgSnap = struct {
    name: []const u8 = "",
    variant_type: u32 = 0,
    class_name: []const u8 = "",
};

pub const PropertySnap = struct {
    name: []const u8 = "",
    variant_type: u32 = 0,
    class_name: []const u8 = "",
    hint: u32 = 0,
    hint_string: []const u8 = "",
    usage: u32 = 0,
    /// `.none` for group entries.
    default: Default = .none,
};

pub const MethodSnap = struct {
    name: []const u8 = "",
    flags: u32 = 0,
    ret: ArgSnap = .{},
    args: []ArgSnap = &.{},
};

pub const SignalSnap = struct {
    name: []const u8 = "",
    args: []ArgSnap = &.{},
};

pub const ScriptSnap = struct {
    path: []const u8 = "",
    class_name: []const u8 = "",
    base_class: []const u8 = "",
    flags: u32 = 0,
    /// `abi.layoutHash` of the descriptor.
    layout_hash: u64 = 0,
    properties: []PropertySnap = &.{},
    methods: []MethodSnap = &.{},
    signals: []SignalSnap = &.{},
};

pub const Snapshot = struct {
    build_id: []const u8 = "",
    scripts: []ScriptSnap = &.{},

    /// Frees everything with the allocator that made it (`take` or `clone`).
    pub fn deinit(self: Snapshot, a: Allocator) void {
        for (self.scripts) |s| {
            a.free(s.path);
            a.free(s.class_name);
            a.free(s.base_class);
            for (s.properties) |p| {
                a.free(p.name);
                a.free(p.class_name);
                a.free(p.hint_string);
            }
            a.free(s.properties);
            for (s.methods) |m| {
                a.free(m.name);
                freeArg(a, m.ret);
                freeArgs(a, m.args);
            }
            a.free(s.methods);
            for (s.signals) |g| {
                a.free(g.name);
                freeArgs(a, g.args);
            }
            a.free(s.signals);
        }
        a.free(self.scripts);
        a.free(self.build_id);
    }

    /// The script at project-relative path `path`, or null.
    pub fn find(self: *const Snapshot, path: []const u8) ?*const ScriptSnap {
        for (self.scripts) |*s| {
            if (std.mem.eql(u8, s.path, path)) return s;
        }
        return null;
    }

    /// A deep copy made with `a`.
    pub fn clone(self: *const Snapshot, a: Allocator) Allocator.Error!Snapshot {
        var out: Snapshot = .{};
        errdefer out.deinit(a);
        out.build_id = try a.dupe(u8, self.build_id);
        out.scripts = try a.alloc(ScriptSnap, self.scripts.len);
        // Empty entries first, so `deinit` of a half-built copy is safe.
        for (out.scripts) |*s| s.* = .{};
        for (self.scripts, out.scripts) |src, *dst| {
            dst.flags = src.flags;
            dst.layout_hash = src.layout_hash;
            dst.path = try a.dupe(u8, src.path);
            dst.class_name = try a.dupe(u8, src.class_name);
            dst.base_class = try a.dupe(u8, src.base_class);
            dst.properties = try a.alloc(PropertySnap, src.properties.len);
            for (dst.properties) |*p| p.* = .{};
            for (src.properties, dst.properties) |sp, *dp| {
                dp.* = .{ .variant_type = sp.variant_type, .hint = sp.hint, .usage = sp.usage, .default = sp.default };
                dp.name = try a.dupe(u8, sp.name);
                dp.class_name = try a.dupe(u8, sp.class_name);
                dp.hint_string = try a.dupe(u8, sp.hint_string);
            }
            dst.methods = try a.alloc(MethodSnap, src.methods.len);
            for (dst.methods) |*m| m.* = .{};
            for (src.methods, dst.methods) |sm, *dm| {
                dm.flags = sm.flags;
                dm.name = try a.dupe(u8, sm.name);
                dm.ret = try cloneArg(a, sm.ret);
                dm.args = try cloneArgs(a, sm.args);
            }
            dst.signals = try a.alloc(SignalSnap, src.signals.len);
            for (dst.signals) |*g| g.* = .{};
            for (src.signals, dst.signals) |sg, *dg| {
                dg.name = try a.dupe(u8, sg.name);
                dg.args = try cloneArgs(a, sg.args);
            }
        }
        return out;
    }
};

fn freeArg(a: Allocator, x: ArgSnap) void {
    a.free(x.name);
    a.free(x.class_name);
}

fn freeArgs(a: Allocator, list: []ArgSnap) void {
    for (list) |x| freeArg(a, x);
    a.free(list);
}

fn cloneArg(a: Allocator, x: ArgSnap) Allocator.Error!ArgSnap {
    const name = try a.dupe(u8, x.name);
    errdefer a.free(name);
    return .{ .name = name, .variant_type = x.variant_type, .class_name = try a.dupe(u8, x.class_name) };
}

fn cloneArgs(a: Allocator, list: []const ArgSnap) Allocator.Error![]ArgSnap {
    const out = try a.alloc(ArgSnap, list.len);
    for (out) |*x| x.* = .{};
    errdefer freeArgs(a, out);
    for (list, out) |src, *dst| dst.* = try cloneArg(a, src);
    return out;
}

/// The bytes of a validated `Str`; empty for a null pointer.
fn text(s: abi.Str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

/// `n` entries at `p`; empty when `n` is 0 (`p` may then be undefined).
fn items(comptime T: type, p: [*]const T, n: u32) []const T {
    return if (n == 0) &.{} else p[0..n];
}

fn takeArg(a: Allocator, x: abi.ArgDesc) Allocator.Error!ArgSnap {
    const name = try a.dupe(u8, text(x.name));
    errdefer a.free(name);
    return .{ .name = name, .variant_type = x.variant_type, .class_name = try a.dupe(u8, text(x.class_name)) };
}

fn takeArgs(a: Allocator, p: [*]const abi.ArgDesc, n: u32) Allocator.Error![]ArgSnap {
    const list = items(abi.ArgDesc, p, n);
    const out = try a.alloc(ArgSnap, list.len);
    for (out) |*x| x.* = .{};
    errdefer freeArgs(a, out);
    for (list, out) |src, *dst| dst.* = try takeArg(a, src);
    return out;
}

/// Copies the validated `table`. Call only after `validate` passed.
pub fn take(a: Allocator, table: *const abi.Table) Allocator.Error!Snapshot {
    var out: Snapshot = .{};
    errdefer out.deinit(a);
    out.build_id = try a.dupe(u8, text(table.build_id));
    const descs = items(abi.ScriptDesc, table.scripts, table.script_count);
    out.scripts = try a.alloc(ScriptSnap, descs.len);
    for (out.scripts) |*s| s.* = .{};
    for (descs, out.scripts) |*d, *s| {
        s.flags = d.flags;
        s.layout_hash = abi.layoutHash(d);
        s.path = try a.dupe(u8, text(d.path));
        s.class_name = try a.dupe(u8, text(d.class_name));
        s.base_class = try a.dupe(u8, text(d.base_class));

        const fields = items(abi.FieldDesc, d.fields, d.field_count);
        const ps = items(abi.PropertyDesc, d.properties, d.property_count);
        s.properties = try a.alloc(PropertySnap, ps.len);
        for (s.properties) |*p| p.* = .{};
        for (ps, s.properties) |sp, *dp| {
            dp.variant_type = sp.variant_type;
            dp.hint = sp.hint;
            dp.usage = sp.usage;
            dp.default = if (sp.field_index < fields.len) decode(d, &fields[sp.field_index]) else .none;
            dp.name = try a.dupe(u8, text(sp.name));
            dp.class_name = try a.dupe(u8, text(sp.class_name));
            dp.hint_string = try a.dupe(u8, text(sp.hint_string));
        }

        const ms = items(abi.MethodDesc, d.methods, d.method_count);
        s.methods = try a.alloc(MethodSnap, ms.len);
        for (s.methods) |*m| m.* = .{};
        for (ms, s.methods) |sm, *dm| {
            dm.flags = sm.flags;
            dm.name = try a.dupe(u8, text(sm.name));
            dm.ret = try takeArg(a, sm.ret);
            dm.args = try takeArgs(a, sm.args, sm.arg_count);
        }

        const gs = items(abi.SignalDesc, d.signals, d.signal_count);
        s.signals = try a.alloc(SignalSnap, gs.len);
        for (s.signals) |*g| g.* = .{};
        for (gs, s.signals) |sg, *dg| {
            dg.name = try a.dupe(u8, text(sg.name));
            dg.args = try takeArgs(a, sg.args, sg.arg_count);
        }
    }
    return out;
}

/// The default of field `f` of `d`, read from the defaults image.
fn decode(d: *const abi.ScriptDesc, f: *const abi.FieldDesc) Default {
    const kind = std.enums.fromInt(abi.ValueKind, f.value_kind) orelse return .none;
    switch (kind) {
        .none, .other => return .none,
        .string_empty => return .string_empty,
        .object_null => return .object_null,
        else => {},
    }
    // The bytes of the field, copied (the image has no promised alignment
    // here, and the copy bounds every read by `size` <= 16 below).
    const end = @as(u64, f.offset) + f.size;
    if (end > d.instance_size or f.size > 16) return .none;
    var buf: [16]u8 = @splat(0);
    const image: [*]const u8 = @ptrCast(d.defaults);
    if (f.size > 0) @memcpy(buf[0..f.size], image[f.offset..][0..f.size]);
    const bytes = buf[0..f.size];

    switch (kind) {
        .bool => return if (f.size == 1) .{ .boolean = bytes[0] != 0 } else .none,
        .int_signed, .enum_signed => return .{ .int = integer(bytes, f.bits, true) },
        .int_unsigned, .enum_unsigned, .flags => return .{ .int = integer(bytes, f.bits, false) },
        .float => switch (f.size) {
            4 => return .{ .float = @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))) },
            8 => return .{ .float = @as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little))) },
            else => return .none,
        },
        .vector_f32 => {
            if (f.size % 4 != 0) return .none;
            const n = f.size / 4;
            if (n < 2 or n > 16) return .none;
            return floatsOf(bytes, n);
        },
        .color => return if (f.size == 16) floatsOf(bytes, 4) else .none,
        .vector_i32 => {
            if (f.size % 4 != 0) return .none;
            const n = f.size / 4;
            if (n < 2 or n > 4) return .none;
            var r: Ints = .{ .len = @intCast(n) };
            for (0..n) |i| r.v[i] = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
            return .{ .ints = r };
        },
        else => return .none,
    }
}

fn floatsOf(bytes: []const u8, n: usize) Default {
    var r: Floats = .{ .len = @intCast(n) };
    for (0..n) |i| r.v[i] = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    return .{ .floats = r };
}

/// A little-endian integer of `bytes.len` bytes (0 to 8): only the low
/// `bits` bits count; the signed form sign-extends from bit `bits - 1`.
fn integer(bytes: []const u8, bits: u32, signed: bool) i64 {
    if (bytes.len == 0 or bytes.len > 8 or bits == 0) return 0;
    var raw: u64 = 0;
    for (bytes, 0..) |b, i| raw |= @as(u64, b) << @intCast(8 * i);
    const w: u32 = @min(bits, 64);
    if (w < 64) {
        const mask = (@as(u64, 1) << @intCast(w)) - 1;
        raw &= mask;
        if (signed and (raw >> @intCast(w - 1)) & 1 == 1) raw |= ~mask;
    }
    return @bitCast(raw);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn str(comptime s: []const u8) abi.Str {
    return .{ .ptr = s.ptr, .len = s.len };
}

fn noop(_: *anyopaque, _: u32) callconv(.c) ?*anyopaque {
    return null;
}
fn noopDestroy(_: *anyopaque) callconv(.c) void {}
fn noopCall(_: *anyopaque, _: u32, _: ?[*]const *const anyopaque, _: i64, _: *anyopaque, _: *abi.CallError) callconv(.c) void {}
fn noopGet(_: *anyopaque, _: u32, _: *anyopaque) callconv(.c) u8 {
    return 0;
}
fn noopSet(_: *anyopaque, _: u32, _: *const anyopaque) callconv(.c) u8 {
    return 0;
}
fn noopDefault(_: u32, _: *anyopaque) callconv(.c) u8 {
    return 0;
}
fn noopNotification(_: *anyopaque, _: i32, _: u8) callconv(.c) void {}

fn field(kind: abi.ValueKind, offset: u32, size: u32, bits: u32) abi.FieldDesc {
    return .{ .name = str("f"), .type_name = str("t"), .shape = 0, .offset = offset, .size = size, .@"align" = 1, .value_kind = @backingInt(kind), .bits = bits };
}

fn descOf(image: []const u8, fields: []const abi.FieldDesc) abi.ScriptDesc {
    return .{
        .path = str("a.zig"),
        .class_name = str(""),
        .base_class = str("Node"),
        .flags = 0,
        .instance_size = @intCast(image.len),
        .instance_align = 1,
        .defaults = image.ptr,
        .fields = fields.ptr,
        .field_count = @intCast(fields.len),
        .properties = undefined,
        .property_count = 0,
        .methods = undefined,
        .method_count = 0,
        .signals = undefined,
        .signal_count = 0,
        .create = &noop,
        .create_blank = &noop,
        .destroy = &noopDestroy,
        .call = &noopCall,
        .get = &noopGet,
        .set = &noopSet,
        .get_default = &noopDefault,
        .notification = &noopNotification,
        .migrate = null,
    };
}

test "integers are masked to bits and sign-extended" {
    // enum(u3) tag 5 with junk in the unused bits.
    try testing.expectEqual(@as(i64, 5), integer(&.{0b1110_1101}, 3, false));
    // i3 value -3 (0b101) with junk in the unused bits.
    try testing.expectEqual(@as(i64, -3), integer(&.{0b0110_1101}, 3, true));
    try testing.expectEqual(@as(i64, 5), integer(&.{0b0110_1101}, 3, false));
    try testing.expectEqual(@as(i64, -1), integer(&.{ 0xFF, 0xFF }, 16, true));
    try testing.expectEqual(@as(i64, 0xFFFF), integer(&.{ 0xFF, 0xFF }, 16, false));
    try testing.expectEqual(@as(i64, -2), integer(&.{ 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, 64, true));
    try testing.expectEqual(@as(i64, 0), integer(&.{}, 0, true));
    // A one-bit flags value in a byte.
    try testing.expectEqual(@as(i64, 1), integer(&.{0xFF}, 1, false));
}

fn fl(comptime vals: []const f32) Default {
    var r: Floats = .{ .len = vals.len };
    for (vals, 0..) |v, i| r.v[i] = v;
    return .{ .floats = r };
}

test "defaults decode by value kind" {
    var image: [64]u8 = @splat(0);
    image[0] = 1; // bool
    std.mem.writeInt(i32, image[4..8], -7, .little);
    std.mem.writeInt(u32, image[8..12], @bitCast(@as(f32, 1.5)), .little);
    std.mem.writeInt(u64, image[16..24], @bitCast(@as(f64, -2.25)), .little);
    for (0..2) |i| std.mem.writeInt(u32, image[24 + 4 * i ..][0..4], @bitCast(@as(f32, @floatFromInt(i + 1))), .little);
    for (0..2) |i| std.mem.writeInt(i32, image[32 + 4 * i ..][0..4], -@as(i32, @intCast(i)) - 1, .little);
    image[40] = 0b1010_0011; // enum(u2) tag 3
    const fs = [_]abi.FieldDesc{
        field(.bool, 0, 1, 0),
        field(.int_signed, 4, 4, 32),
        field(.float, 8, 4, 0),
        field(.float, 16, 8, 0),
        field(.vector_f32, 24, 8, 0),
        field(.vector_i32, 32, 8, 0),
        field(.enum_unsigned, 40, 1, 2),
        field(.string_empty, 48, 16, 0),
        field(.object_null, 48, 8, 0),
        field(.none, 0, 8, 0),
        field(.other, 0, 8, 0),
        field(.vector_f32, 24, 12, 0), // 3 components
        field(.vector_f32, 24, 2, 0), // not a whole number of f32
        field(.float, 8, 3, 0), // size does not fit the kind
        .{ .name = str("f"), .type_name = str("t"), .shape = 0, .offset = 0, .size = 1, .@"align" = 1, .value_kind = 99, .bits = 0 },
        field(.int_signed, 60, 8, 64), // runs past the image
    };
    const d = descOf(&image, &fs);
    const want = [_]Default{
        .{ .boolean = true },
        .{ .int = -7 },
        .{ .float = 1.5 },
        .{ .float = -2.25 },
        fl(&.{ 1, 2 }),
        .{ .ints = .{ .v = .{ -1, -2, 0, 0 }, .len = 2 } },
        .{ .int = 3 },
        .string_empty,
        .object_null,
        .none,
        .none,
        fl(&.{ 1, 2, @as(f32, @bitCast(@as(i32, -1))) }),
        .none,
        .none,
        .none,
        .none,
    };
    for (&fs, want, 0..) |*f, w, i| {
        const got = decode(&d, f);
        if (!got.eql(w)) {
            std.debug.print("field {d}: got {any}, want {any}\n", .{ i, got, w });
            return error.TestExpectedEqual;
        }
    }
}

test "snapshot copies a table and survives clone" {
    var image: [8]u8 = .{ 9, 0, 0, 0, 0, 0, 0, 0 };
    const fs = [_]abi.FieldDesc{field(.int_unsigned, 0, 4, 32)};
    var d = descOf(&image, &fs);
    const props = [_]abi.PropertyDesc{
        .{ .name = str("hp"), .field_index = 0, .variant_type = 2, .class_name = str(""), .hint = 1, .hint_string = str("0,9"), .usage = 6 },
        .{ .name = str("Group"), .field_index = abi.no_field, .variant_type = 0, .class_name = str(""), .hint = 0, .hint_string = str(""), .usage = abi.usage_group },
    };
    const margs = [_]abi.ArgDesc{.{ .name = str("n"), .variant_type = 2, .class_name = str("") }};
    const methods = [_]abi.MethodDesc{.{ .name = str("hit"), .args = &margs, .arg_count = 1, .ret = .{ .name = str(""), .variant_type = 0, .class_name = str("") }, .flags = 0 }};
    const sigs = [_]abi.SignalDesc{.{ .name = str("died"), .args = &margs, .arg_count = 1 }};
    d.properties = &props;
    d.property_count = 2;
    d.methods = &methods;
    d.method_count = 1;
    d.signals = &sigs;
    d.signal_count = 1;
    const table: abi.Table = .{ .magic = abi.magic, .abi_version = abi.abi_version, .size = @sizeOf(abi.Table), .layout_stamp = 0, .sdk_version = str("1"), .build_id = str("0123456789abcdef"), .scripts = @ptrCast(&d), .script_count = 1 };

    const snap = try take(testing.allocator, &table);
    defer snap.deinit(testing.allocator);
    try testing.expectEqualStrings("0123456789abcdef", snap.build_id);
    try testing.expectEqual(@as(usize, 1), snap.scripts.len);
    const s = snap.scripts[0];
    try testing.expectEqual(abi.layoutHash(&d), s.layout_hash);
    try testing.expectEqualStrings("a.zig", s.path);
    try testing.expect(s.properties[0].default.eql(.{ .int = 9 }));
    try testing.expectEqualStrings("0,9", s.properties[0].hint_string);
    try testing.expect(s.properties[1].default.eql(.none));
    try testing.expectEqualStrings("n", s.methods[0].args[0].name);
    try testing.expectEqualStrings("died", s.signals[0].name);
    try testing.expect(snap.find("a.zig") != null and snap.find("b.zig") == null);

    const copy = try snap.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expectEqualStrings("hit", copy.scripts[0].methods[0].name);
    try testing.expect(copy.scripts[0].properties[0].name.ptr != s.properties[0].name.ptr);
}

fn takeFresh(a: Allocator, table: *const abi.Table) !void {
    const snap = try take(a, table);
    defer snap.deinit(a);
    const copy = try snap.clone(a);
    copy.deinit(a);
}

test "snapshot frees everything when an allocation fails" {
    var image: [8]u8 = @splat(0);
    const fs = [_]abi.FieldDesc{field(.int_unsigned, 0, 4, 32)};
    var d = descOf(&image, &fs);
    const props = [_]abi.PropertyDesc{.{ .name = str("hp"), .field_index = 0, .variant_type = 2, .class_name = str("C"), .hint = 0, .hint_string = str("h"), .usage = 6 }};
    const margs = [_]abi.ArgDesc{.{ .name = str("n"), .variant_type = 2, .class_name = str("X") }};
    const methods = [_]abi.MethodDesc{.{ .name = str("hit"), .args = &margs, .arg_count = 1, .ret = .{ .name = str("r"), .variant_type = 0, .class_name = str("") }, .flags = 0 }};
    d.properties = &props;
    d.property_count = 1;
    d.methods = &methods;
    d.method_count = 1;
    const table: abi.Table = .{ .magic = abi.magic, .abi_version = abi.abi_version, .size = @sizeOf(abi.Table), .layout_stamp = 0, .sdk_version = str("1"), .build_id = str("id"), .scripts = @ptrCast(&d), .script_count = 1 };
    try testing.checkAllAllocationFailures(testing.allocator, takeFresh, .{&table});
}

test "snapshot of an empty table" {
    const table: abi.Table = .{ .magic = abi.magic, .abi_version = abi.abi_version, .size = @sizeOf(abi.Table), .layout_stamp = 0, .sdk_version = str("1"), .build_id = .{ .ptr = null, .len = 0 }, .scripts = undefined, .script_count = 0 };
    const snap = try take(testing.allocator, &table);
    defer snap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), snap.scripts.len);
}
