//! Host-side validator for the `Table` a user module returns. The module is
//! not trusted, so every byte the validator reads is proven valid first, in
//! this order: the table header, then each count against its limit before any
//! array is indexed, then each array element and the strings it points to.
//!
//! What it cannot prove: that a non-null, aligned pointer points to real
//! memory. It relies on the module being loaded in this process (so the
//! pointers the table holds refer to the module's own data) and on every
//! index and length being bounded by a limit before use. Null and misaligned
//! pointers are rejected.
//!
//! Pointer fields declared non-optional are tested through their address, so
//! the compiler never sees a null test on a pointer it believes is non-null.

const std = @import("std");
const abi = @import("abi.zig");

const Table = abi.Table;
const ScriptDesc = abi.ScriptDesc;
const FieldDesc = abi.FieldDesc;
const ArgDesc = abi.ArgDesc;
const PropertyDesc = abi.PropertyDesc;
const MethodDesc = abi.MethodDesc;
const SignalDesc = abi.SignalDesc;
const Str = abi.Str;

/// Number of Godot Variant types (`Variant::VARIANT_MAX`); valid ids are below it.
pub const variant_max: u32 = 39;

pub const Limits = struct {
    max_scripts: u32 = 65536,
    max_fields: u32 = 4096,
    max_properties: u32 = 4096,
    max_methods: u32 = 4096,
    max_signals: u32 = 1024,
    max_args: u32 = 64,
    max_string: u32 = 4096,
    max_instance_size: u32 = 1 << 24,
};

pub const ValidateError = error{
    BadMagic,
    BadVersion,
    BadSize,
    BadStamp,
    TooMany,
    BadString,
    BadName,
    BadType,
    BadLayout,
    NullPointer,
    Duplicate,
};

/// Writes one sentence into `diag` (zero padded, always NUL terminated).
fn setDiag(diag: *[256]u8, comptime fmt: []const u8, args: anytype) void {
    @memset(diag, 0);
    var w: std.Io.Writer = .fixed(diag[0..255]);
    w.print(fmt, args) catch {};
}

/// Checks `t` and everything it points to. On failure returns the error for
/// the first broken rule and puts one sentence in `diag`; on success `diag`
/// is empty.
pub fn validate(t: *const Table, expected_stamp: u64, limits: Limits, diag: *[256]u8) ValidateError!void {
    @memset(diag, 0);
    if (t.magic != abi.magic) {
        setDiag(diag, "The table magic is 0x{x}, expected 0x{x}.", .{ t.magic, abi.magic });
        return error.BadMagic;
    }
    if (t.abi_version != abi.abi_version) {
        setDiag(diag, "The table ABI version is {d}, expected {d}.", .{ t.abi_version, abi.abi_version });
        return error.BadVersion;
    }
    if (t.size != @sizeOf(Table)) {
        setDiag(diag, "The table size field is {d}, expected {d}.", .{ t.size, @sizeOf(Table) });
        return error.BadSize;
    }
    if (t.layout_stamp != expected_stamp) {
        setDiag(diag, "The table layout stamp is 0x{x}, expected 0x{x}.", .{ t.layout_stamp, expected_stamp });
        return error.BadStamp;
    }

    var c: Ctx = .{ .diag = diag, .limits = limits };
    _ = try c.str(&t.sdk_version, .{ .kind = "table", .what = "SDK version" });
    _ = try c.str(&t.build_id, .{ .kind = "table", .what = "build id" });
    if (t.script_count > limits.max_scripts) {
        return c.fail(error.TooMany, "The table lists {d} scripts, above the maximum {d}.", .{ t.script_count, limits.max_scripts });
    }
    const scripts = try c.array(ScriptDesc, &t.scripts, t.script_count, "scripts");

    for (scripts, 0..) |*s, i| {
        c.script_index = @intCast(i);
        c.path = "";
        try c.script(s);
    }
    c.script_index = null;

    // Paths are unique. Each one was validated above.
    for (scripts, 0..) |*a, i| {
        const pa = slice(&a.path);
        for (scripts[0..i], 0..) |*b, j| {
            if (std.mem.eql(u8, pa, slice(&b.path))) {
                return c.fail(error.Duplicate, "Scripts {d} and {d} share the path \"{f}\".", .{ j, i, Clip{ .s = pa } });
            }
        }
    }
}

/// The bytes of a `Str` already accepted by `Ctx.str`.
fn slice(s: *const Str) []const u8 {
    if (s.len == 0) return "";
    return s.ptr.?[0..s.len];
}

/// True when the pointer-sized field at `field` holds 0. Reads the address,
/// not the pointer, so non-optional pointer types are safe to test.
fn isNull(field: anytype) bool {
    comptime std.debug.assert(@sizeOf(@typeInfo(@TypeOf(field)).pointer.child) == @sizeOf(usize));
    const raw: *align(1) const usize = @ptrCast(field);
    return raw.* == 0;
}

fn addr(field: anytype) usize {
    const raw: *align(1) const usize = @ptrCast(field);
    return raw.*;
}

/// Prints at most 48 bytes of untrusted text, replacing anything that is not
/// printable ASCII with '?'.
const Clip = struct {
    s: []const u8,

    pub fn format(self: Clip, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const max = 48;
        for (self.s[0..@min(self.s.len, max)]) |ch| {
            try w.writeByte(if (ch >= 0x20 and ch < 0x7f and ch != '"') ch else '?');
        }
        if (self.s.len > max) try w.writeAll("...");
    }
};

/// Names the item being checked, e.g. `property 3 name`.
const Where = struct {
    kind: []const u8,
    index: ?u32 = null,
    what: []const u8,

    pub fn format(self: Where, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.kind);
        if (self.index) |i| try w.print(" {d}", .{i});
        if (self.what.len > 0) try w.print(" {s}", .{self.what});
    }
};

const Ctx = struct {
    diag: *[256]u8,
    limits: Limits,
    /// Set while a script is being checked.
    script_index: ?u32 = null,
    /// The script path once it has passed its checks, else empty.
    path: []const u8 = "",

    fn fail(c: *Ctx, err: ValidateError, comptime fmt: []const u8, args: anytype) ValidateError {
        @memset(c.diag, 0);
        var w: std.Io.Writer = .fixed(c.diag[0..255]);
        if (c.script_index) |i| {
            if (c.path.len > 0) {
                w.print("Script \"{f}\" ", .{Clip{ .s = c.path }}) catch {};
            } else {
                w.print("Script {d} ", .{i}) catch {};
            }
        }
        w.print(fmt, args) catch {};
        return err;
    }

    /// Reads a `Str`: a non-null pointer when `len > 0`, `len` within the
    /// limit, valid UTF-8, no NUL. Returns the bytes.
    fn str(c: *Ctx, s: *const Str, where: Where) ValidateError![]const u8 {
        if (s.len == 0) return "";
        if (s.len > c.limits.max_string) {
            return c.fail(error.BadString, "{f} is {d} bytes long, above the maximum {d}.", .{ where, s.len, c.limits.max_string });
        }
        if (isNull(&s.ptr)) {
            return c.fail(error.NullPointer, "{f} has length {d} but a null pointer.", .{ where, s.len });
        }
        const bytes = s.ptr.?[0..s.len];
        if (std.mem.findScalar(u8, bytes, 0)) |pos| {
            return c.fail(error.BadString, "{f} contains a NUL byte at position {d}.", .{ where, pos });
        }
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return c.fail(error.BadString, "{f} is not valid UTF-8.", .{where});
        }
        return bytes;
    }

    fn identifier(c: *Ctx, s: *const Str, where: Where, allow_empty: bool) ValidateError![]const u8 {
        const bytes = try c.str(s, where);
        if (bytes.len == 0 and allow_empty) return bytes;
        if (!isIdentifier(bytes)) {
            return c.fail(error.BadName, "{f} \"{f}\" is not a valid identifier.", .{ where, Clip{ .s = bytes } });
        }
        return bytes;
    }

    /// The elements of an array whose count the caller already checked
    /// against its limit. A zero count needs no pointer.
    fn array(c: *Ctx, comptime T: type, field: anytype, count: u32, comptime what: []const u8) ValidateError![]const T {
        if (count == 0) return &.{};
        if (isNull(field)) {
            return c.fail(error.NullPointer, "The {s} pointer is null but the count is {d}.", .{ what, count });
        }
        const a = addr(field);
        if (a % @alignOf(T) != 0) {
            return c.fail(error.BadLayout, "The {s} pointer 0x{x} is not aligned to {d} bytes.", .{ what, a, @alignOf(T) });
        }
        const p: [*]const T = @ptrFromInt(a);
        return p[0..count];
    }

    fn limit(c: *Ctx, count: u32, max: u32, comptime what: []const u8) ValidateError!void {
        if (count > max) {
            return c.fail(error.TooMany, "it has {d} " ++ what ++ ", above the maximum {d}.", .{ count, max });
        }
    }

    fn fnPtr(c: *Ctx, field: anytype, comptime name: []const u8) ValidateError!void {
        if (isNull(field)) return c.fail(error.NullPointer, "its {s} function pointer is null.", .{name});
    }

    fn variant(c: *Ctx, v: u32, where: Where) ValidateError!void {
        if (v >= variant_max) {
            return c.fail(error.BadType, "{f} has variant type {d}, above the maximum {d}.", .{ where, v, variant_max - 1 });
        }
    }

    fn script(c: *Ctx, s: *const ScriptDesc) ValidateError!void {
        const idx = c.script_index.?;
        const path = try c.str(&s.path, .{ .kind = "script", .index = idx, .what = "path" });
        if (!isRelativePath(path)) {
            return c.fail(error.BadName, "path \"{f}\" is not a relative path of non-empty parts without \".\" or \"..\".", .{Clip{ .s = path }});
        }
        c.path = path;
        _ = try c.identifier(&s.class_name, .{ .kind = "script", .what = "class name" }, true);
        const base = try c.identifier(&s.base_class, .{ .kind = "script", .what = "base class" }, false);
        _ = base;

        if (s.instance_size > c.limits.max_instance_size) {
            return c.fail(error.BadLayout, "instance size {d} is above the maximum {d}.", .{ s.instance_size, c.limits.max_instance_size });
        }
        const al = s.instance_align;
        if (al == 0 or al > 4096 or !std.math.isPowerOfTwo(al)) {
            return c.fail(error.BadLayout, "instance alignment {d} is not a power of two up to 4096.", .{al});
        }

        // Every count against its limit before any array is indexed.
        try c.limit(s.field_count, c.limits.max_fields, "fields");
        try c.limit(s.property_count, c.limits.max_properties, "properties");
        try c.limit(s.method_count, c.limits.max_methods, "methods");
        try c.limit(s.signal_count, c.limits.max_signals, "signals");

        if (isNull(&s.defaults)) return c.fail(error.NullPointer, "its defaults pointer is null.", .{});
        try c.fnPtr(&s.create, "create");
        try c.fnPtr(&s.destroy, "destroy");
        try c.fnPtr(&s.call, "call");
        try c.fnPtr(&s.get, "get");
        try c.fnPtr(&s.set, "set");
        try c.fnPtr(&s.get_default, "get_default");
        try c.fnPtr(&s.notification, "notification");

        const fields = try c.array(FieldDesc, &s.fields, s.field_count, "fields");
        for (fields, 0..) |*f, i| {
            const w: Where = .{ .kind = "field", .index = @intCast(i), .what = "name" };
            const name = try c.identifier(&f.name, w, false);
            const end = @as(u64, f.offset) + f.size;
            if (end > s.instance_size) {
                return c.fail(error.BadLayout, "field {d} \"{f}\" ends at byte {d}, past the instance size {d}.", .{ i, Clip{ .s = name }, end, s.instance_size });
            }
        }

        const props = try c.array(PropertyDesc, &s.properties, s.property_count, "properties");
        for (props, 0..) |*p, i| {
            const idx_u: u32 = @intCast(i);
            const name = try c.identifier(&p.name, .{ .kind = "property", .index = idx_u, .what = "name" }, false);
            try c.variant(p.variant_type, .{ .kind = "property", .index = idx_u, .what = "" });
            _ = try c.identifier(&p.class_name, .{ .kind = "property", .index = idx_u, .what = "class name" }, true);
            _ = try c.str(&p.hint_string, .{ .kind = "property", .index = idx_u, .what = "hint string" });
            if (p.field_index != abi.no_field and p.field_index >= s.field_count) {
                return c.fail(error.BadLayout, "property {d} \"{f}\" has field index {d}, but there are {d} fields.", .{ i, Clip{ .s = name }, p.field_index, s.field_count });
            }
            for (props[0..i], 0..) |*q, j| {
                if (std.mem.eql(u8, name, slice(&q.name))) {
                    return c.fail(error.Duplicate, "it has two properties named \"{f}\" (properties {d} and {d}).", .{ Clip{ .s = name }, j, i });
                }
            }
        }

        const methods = try c.array(MethodDesc, &s.methods, s.method_count, "methods");
        for (methods, 0..) |*m, i| {
            const idx_u: u32 = @intCast(i);
            const name = try c.identifier(&m.name, .{ .kind = "method", .index = idx_u, .what = "name" }, false);
            try c.variant(m.ret.variant_type, .{ .kind = "method", .index = idx_u, .what = "return" });
            _ = try c.identifier(&m.ret.class_name, .{ .kind = "method", .index = idx_u, .what = "return class name" }, true);
            if (m.arg_count > c.limits.max_args) {
                return c.fail(error.TooMany, "method {d} \"{f}\" has {d} arguments, above the maximum {d}.", .{ i, Clip{ .s = name }, m.arg_count, c.limits.max_args });
            }
            const args = try c.array(ArgDesc, &m.args, m.arg_count, "method arguments");
            for (args, 0..) |*a, k| try c.argument(a, "method", idx_u, @intCast(k));
            for (methods[0..i], 0..) |*q, j| {
                if (std.mem.eql(u8, name, slice(&q.name))) {
                    return c.fail(error.Duplicate, "it has two methods named \"{f}\" (methods {d} and {d}).", .{ Clip{ .s = name }, j, i });
                }
            }
        }

        const sigs = try c.array(SignalDesc, &s.signals, s.signal_count, "signals");
        for (sigs, 0..) |*g, i| {
            const idx_u: u32 = @intCast(i);
            const name = try c.identifier(&g.name, .{ .kind = "signal", .index = idx_u, .what = "name" }, false);
            if (g.arg_count > c.limits.max_args) {
                return c.fail(error.TooMany, "signal {d} \"{f}\" has {d} arguments, above the maximum {d}.", .{ i, Clip{ .s = name }, g.arg_count, c.limits.max_args });
            }
            const args = try c.array(ArgDesc, &g.args, g.arg_count, "signal arguments");
            for (args, 0..) |*a, k| try c.argument(a, "signal", idx_u, @intCast(k));
            for (sigs[0..i], 0..) |*q, j| {
                if (std.mem.eql(u8, name, slice(&q.name))) {
                    return c.fail(error.Duplicate, "it has two signals named \"{f}\" (signals {d} and {d}).", .{ Clip{ .s = name }, j, i });
                }
            }
        }
    }

    /// One argument of method or signal `owner`.
    fn argument(c: *Ctx, a: *const ArgDesc, kind: []const u8, owner: u32, k: u32) ValidateError!void {
        const name = try c.identifier(&a.name, .{ .kind = kind, .index = owner, .what = "argument name" }, false);
        if (a.variant_type >= variant_max) {
            return c.fail(error.BadType, "{s} {d} argument {d} \"{f}\" has variant type {d}, above the maximum {d}.", .{ kind, owner, k, Clip{ .s = name }, a.variant_type, variant_max - 1 });
        }
        _ = try c.identifier(&a.class_name, .{ .kind = kind, .index = owner, .what = "argument class name" }, true);
    }
};

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |ch, i| {
        const alpha = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
        const digit = ch >= '0' and ch <= '9';
        if (!(alpha or (digit and i > 0))) return false;
    }
    return true;
}

/// `/`-separated, no empty part, no `.` or `..` part. A leading `/` gives an
/// empty first part; `\` is refused because Windows treats it as a separator.
fn isRelativePath(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.findScalar(u8, s, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const n = 16; // room for every count a fuzz mutation may set (see `fuzz_limits`)
const stamp: u64 = 0xABCD_1234;

const fuzz_limits: Limits = .{
    .max_scripts = n,
    .max_fields = n,
    .max_properties = n,
    .max_methods = n,
    .max_signals = n,
    .max_args = n,
    .max_string = 64,
    .max_instance_size = 1 << 16,
};

const text = "a/x.zig b/y.zig X Node Node2D hp name amount _ready hit died ab_c Ünï";

fn lit(comptime needle: []const u8) Str {
    const at = comptime std.mem.indexOf(u8, text, needle).?;
    return .{ .ptr = text.ptr + at, .len = needle.len };
}

fn dummyCreate(_: *anyopaque, _: u32) callconv(.c) ?*anyopaque {
    return null;
}
fn dummyDestroy(_: *anyopaque) callconv(.c) void {}
fn dummyCall(_: *anyopaque, _: u32, _: [*]const *const anyopaque, _: i64, _: *anyopaque, _: *abi.CallError) callconv(.c) void {}
fn dummyGet(_: *anyopaque, _: u32, _: *anyopaque) callconv(.c) u8 {
    return 0;
}
fn dummySet(_: *anyopaque, _: u32, _: *const anyopaque) callconv(.c) u8 {
    return 0;
}
fn dummyGetDefault(_: u32, _: *anyopaque) callconv(.c) u8 {
    return 0;
}
fn dummyNotification(_: *anyopaque, _: i32, _: u8) callconv(.c) void {}

var defaults_byte: u8 = 0;

/// A good two-script table in storage the test owns. Every array has room for
/// `n` entries (the unused ones are zero bytes) so a count mutated up to `n`
/// still reads only this struct. `link` points the table at the arrays of
/// whichever copy it runs on.
const Fixture = struct {
    table: Table,
    scripts: [n]ScriptDesc,
    fields: [2][n]FieldDesc,
    props: [2][n]PropertyDesc,
    methods: [2][n]MethodDesc,
    method_args: [2][n][n]ArgDesc,
    signals: [2][n]SignalDesc,
    signal_args: [2][n][n]ArgDesc,

    fn init() Fixture {
        var f: Fixture = undefined;
        @memset(std.mem.asBytes(&f), 0);
        const no_str: Str = .{ .ptr = null, .len = 0 };

        f.table = .{
            .magic = abi.magic,
            .abi_version = abi.abi_version,
            .size = @sizeOf(Table),
            .layout_stamp = stamp,
            .sdk_version = lit("ab_c"),
            .build_id = no_str,
            .scripts = &f.scripts,
            .script_count = 2,
        };
        inline for (0..2) |i| {
            f.scripts[i] = .{
                .path = if (i == 0) lit("a/x.zig") else lit("b/y.zig"),
                .class_name = if (i == 0) lit("X") else no_str,
                .base_class = if (i == 0) lit("Node") else lit("Node2D"),
                .flags = 0,
                .layout_hash = 7,
                .instance_size = 32,
                .instance_align = 8,
                .defaults = &defaults_byte,
                .fields = &f.fields[i],
                .field_count = 0,
                .properties = &f.props[i],
                .property_count = 0,
                .methods = &f.methods[i],
                .method_count = 0,
                .signals = &f.signals[i],
                .signal_count = 0,
                .create = &dummyCreate,
                .destroy = &dummyDestroy,
                .call = &dummyCall,
                .get = &dummyGet,
                .set = &dummySet,
                .get_default = &dummyGetDefault,
                .notification = &dummyNotification,
                .migrate = null,
            };
        }
        // Script 0 has content; script 1 is bare.
        var x = &f.scripts[0];
        x.field_count = 2;
        f.fields[0][0] = .{ .name = lit("hp"), .type_id = 1, .offset = 0, .size = 4 };
        f.fields[0][1] = .{ .name = lit("name"), .type_id = 2, .offset = 8, .size = 16 };
        x.property_count = 2;
        f.props[0][0] = .{ .name = lit("hp"), .field_index = 0, .variant_type = 2, .class_name = no_str, .hint = 0, .hint_string = no_str, .usage = 6 };
        f.props[0][1] = .{ .name = lit("name"), .field_index = abi.no_field, .variant_type = 0, .class_name = no_str, .hint = 0, .hint_string = lit("Ünï"), .usage = 6 };
        x.method_count = 2;
        f.methods[0][0] = .{ .name = lit("_ready"), .args = &f.method_args[0][0], .arg_count = 0, .ret = .{ .name = no_str, .variant_type = 0, .class_name = no_str }, .flags = abi.method_flag_virtual };
        f.methods[0][1] = .{ .name = lit("hit"), .args = &f.method_args[0][1], .arg_count = 1, .ret = .{ .name = no_str, .variant_type = 0, .class_name = no_str }, .flags = 0 };
        f.method_args[0][1][0] = .{ .name = lit("amount"), .variant_type = 2, .class_name = no_str };
        x.signal_count = 1;
        f.signals[0][0] = .{ .name = lit("died"), .args = &f.signal_args[0][0], .arg_count = 1 };
        f.signal_args[0][0][0] = .{ .name = lit("name"), .variant_type = 4, .class_name = no_str };
        // The caller must `link` after the copy: pointers made here refer to this frame.
        return f;
    }

    /// Points every array pointer at this copy's own storage.
    fn link(f: *Fixture) void {
        f.table.scripts = &f.scripts;
        for (&f.scripts, 0..) |*sc, i| {
            if (i >= 2) break;
            sc.fields = &f.fields[i];
            sc.properties = &f.props[i];
            sc.methods = &f.methods[i];
            sc.signals = &f.signals[i];
            for (&f.methods[i], 0..) |*m, j| m.args = &f.method_args[i][j];
            for (&f.signals[i], 0..) |*g, j| g.args = &f.signal_args[i][j];
        }
    }

    fn check(f: *const Fixture, limits: Limits, diag: *[256]u8) ValidateError!void {
        return validate(&f.table, stamp, limits, diag);
    }
};

fn diagText(diag: *const [256]u8) []const u8 {
    return std.mem.sliceTo(diag, 0);
}

/// Applies `mutate` to a fresh good table and expects `err` and a diag that
/// contains `needle`.
fn expectRule(comptime mutate: fn (*Fixture) void, err: ValidateError, needle: []const u8) !void {
    var f = Fixture.init();
    f.link();
    mutate(&f);
    var diag: [256]u8 = undefined;
    try testing.expectError(err, f.check(.{}, &diag));
    const got = diagText(&diag);
    if (std.mem.indexOf(u8, got, needle) == null) {
        std.debug.print("diag \"{s}\" lacks \"{s}\"\n", .{ got, needle });
        return error.TestExpectedEqual;
    }
    try testing.expect(got.len > 0 and got[got.len - 1] == '.');
}

fn setStr(dst: *Str, comptime v: []const u8) void {
    dst.* = .{ .ptr = v.ptr, .len = v.len };
}

test "validate accepts" {
    var f = Fixture.init();
    f.link();
    var diag: [256]u8 = undefined;
    try f.check(.{}, &diag);
    try testing.expectEqualStrings("", diagText(&diag));
    try f.check(fuzz_limits, &diag);
}

test "validate accepts an empty table and a null scripts pointer" {
    var f = Fixture.init();
    f.link();
    f.table.script_count = 0;
    @memset(std.mem.asBytes(&f.table.scripts), 0);
    var diag: [256]u8 = undefined;
    try f.check(.{}, &diag);
}

test "validate header rules" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.magic = 1;
        }
    }.m, error.BadMagic, "0x1");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.abi_version = 9;
        }
    }.m, error.BadVersion, "version is 9");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.size = 3;
        }
    }.m, error.BadSize, "size field is 3");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.layout_stamp = 0x55;
        }
    }.m, error.BadStamp, "stamp is 0x55");
}

test "validate count limits" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.script_count = 70000;
        }
    }.m, error.TooMany, "70000 scripts, above the maximum 65536");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].field_count = 5000;
        }
    }.m, error.TooMany, "Script \"a/x.zig\" it has 5000 fields");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].property_count = 4097;
        }
    }.m, error.TooMany, "4097 properties");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].method_count = 4097;
        }
    }.m, error.TooMany, "4097 methods");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].signal_count = 1025;
        }
    }.m, error.TooMany, "1025 signals");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.methods[0][1].arg_count = 65;
        }
    }.m, error.TooMany, "method 1 \"hit\" has 65 arguments");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.signals[0][0].arg_count = 65;
        }
    }.m, error.TooMany, "signal 0 \"died\" has 65 arguments");
}

test "validate strings" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].class_name = .{ .ptr = null, .len = 3 };
        }
    }.m, error.NullPointer, "class name has length 3 but a null pointer");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].class_name.len = 5000;
        }
    }.m, error.BadString, "5000 bytes long, above the maximum 4096");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.props[0][0].hint_string, "a\x00b");
        }
    }.m, error.BadString, "property 0 hint string contains a NUL byte at position 1");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.props[0][1].hint_string, "\xff\xfe");
        }
    }.m, error.BadString, "property 1 hint string is not valid UTF-8");
}

test "validate names" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.scripts[0].class_name, "1X");
        }
    }.m, error.BadName, "class name \"1X\" is not a valid identifier");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].base_class = .{ .ptr = null, .len = 0 };
        }
    }.m, error.BadName, "base class \"\" is not a valid identifier");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[1].path = .{ .ptr = null, .len = 0 };
        }
    }.m, error.BadName, "Script 1 path");
    inline for (.{ "/abs.zig", "a//b.zig", "a/./b.zig", "a/../b.zig", "a\\b.zig", "a/" }) |bad| {
        try expectRule(struct {
            fn m(f: *Fixture) void {
                setStr(&f.scripts[0].path, bad);
            }
        }.m, error.BadName, "is not a relative path");
    }
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.fields[0][0].name, "h-p");
        }
    }.m, error.BadName, "field 0 name \"h-p\"");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.methods[0][1].name, "a b");
        }
    }.m, error.BadName, "method 1 name \"a b\"");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.method_args[0][1][0].class_name, "9");
        }
    }.m, error.BadName, "argument class name \"9\"");
}

test "validate variant types" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.props[0][0].variant_type = 57;
        }
    }.m, error.BadType, "Script \"a/x.zig\" property 0 has variant type 57, above the maximum 38.");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.methods[0][0].ret.variant_type = 39;
        }
    }.m, error.BadType, "method 0 return has variant type 39");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.method_args[0][1][0].variant_type = 100;
        }
    }.m, error.BadType, "method 1 argument 0 \"amount\" has variant type 100");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.signal_args[0][0][0].variant_type = 0xFFFF_FFFF;
        }
    }.m, error.BadType, "signal 0 argument 0 \"name\"");
}

test "validate layout" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].instance_size = 1 << 25;
        }
    }.m, error.BadLayout, "instance size 33554432 is above the maximum 16777216");
    inline for (.{ 0, 3, 8192 }) |al| {
        try expectRule(struct {
            fn m(f: *Fixture) void {
                f.scripts[0].instance_align = al;
            }
        }.m, error.BadLayout, "instance alignment");
    }
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.fields[0][1].offset = 20;
        }
    }.m, error.BadLayout, "field 1 \"name\" ends at byte 36, past the instance size 32");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.fields[0][1].offset = 0xFFFF_FFF0;
            f.fields[0][1].size = 0x20;
        }
    }.m, error.BadLayout, "past the instance size");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.props[0][0].field_index = 2;
        }
    }.m, error.BadLayout, "property 0 \"hp\" has field index 2, but there are 2 fields");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            const misaligned: usize = @intFromPtr(&f.fields[0]) + 1;
            std.mem.asBytes(&f.scripts[0].fields)[0..@sizeOf(usize)].* = std.mem.toBytes(misaligned);
        }
    }.m, error.BadLayout, "fields pointer");
}

test "validate null pointers" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.table.scripts), 0);
        }
    }.m, error.NullPointer, "scripts pointer is null");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[0].properties), 0);
        }
    }.m, error.NullPointer, "properties pointer is null");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.methods[0][1].args), 0);
        }
    }.m, error.NullPointer, "method arguments pointer is null");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[0].defaults), 0);
        }
    }.m, error.NullPointer, "defaults pointer is null");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[1].notification), 0);
        }
    }.m, error.NullPointer, "Script \"b/y.zig\" its notification function pointer is null");
    inline for (.{ "create", "destroy", "call", "get", "set", "get_default" }) |name| {
        try expectRule(struct {
            fn m(f: *Fixture) void {
                @memset(std.mem.asBytes(&@field(f.scripts[0], name)), 0);
            }
        }.m, error.NullPointer, name ++ " function pointer");
    }
}

test "validate duplicates" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.props[0][1].name, "hp");
        }
    }.m, error.Duplicate, "two properties named \"hp\" (properties 0 and 1)");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.methods[0][1].name, "_ready");
        }
    }.m, error.Duplicate, "two methods named \"_ready\"");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[1].path = f.scripts[0].path;
        }
    }.m, error.Duplicate, "Scripts 0 and 1 share the path \"a/x.zig\"");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.signals[0][0].arg_count = 0;
            f.scripts[0].signal_count = 2;
            f.signals[0][1] = f.signals[0][0];
        }
    }.m, error.Duplicate, "two signals named \"died\"");
}

test "validate allows a null migrate and an empty class name" {
    var f = Fixture.init();
    f.link();
    try testing.expect(f.scripts[0].migrate == null);
    try testing.expectEqual(@as(u32, 0), f.scripts[1].class_name.len);
    f.scripts[0].migrate = &defaults_byte;
    var diag: [256]u8 = undefined;
    try f.check(.{}, &diag);
}

test "validate diag is clipped and printable" {
    var f = Fixture.init();
    f.link();
    f.scripts[0].class_name = .{ .ptr = text.ptr, .len = 60 };
    var diag: [256]u8 = undefined;
    try testing.expectError(error.BadName, f.check(.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diagText(&diag), "...") != null);
    for (diagText(&diag)) |ch| try testing.expect(ch >= 0x20 and ch < 0x7f);
}

// ---------------------------------------------------------------- fuzz

/// Storage the mutations may point at. Large enough that `n` elements of any
/// descriptor fit, and that a `Str` of up to `max_string` bytes fits at any
/// offset up to 128.
var scratch: [4096]u8 align(16) = @splat(0);
var text_pool: [256]u8 = @splat('a');

fn interesting(r: std.Random) u32 {
    const table = [_]u32{ 0, 1, 2, 3, 15, 16, 17, 38, 39, 40, 63, 64, 65, 4096, 0xFFFF, 0x8000_0000, 0xFFFF_FFFF };
    return switch (r.uintLessThan(u8, 4)) {
        0 => r.int(u32),
        1 => r.uintLessThan(u32, 40),
        else => table[r.uintLessThan(usize, table.len)],
    };
}

fn mutateValue(comptime T: type, p: *T, r: std.Random) void {
    switch (T) {
        u32 => p.* = interesting(r),
        u64 => p.* = r.int(u64),
        Str => switch (r.uintLessThan(u8, 4)) {
            0 => p.len = interesting(r),
            1 => @memset(std.mem.asBytes(&p.ptr), 0),
            2 => p.* = .{ .ptr = &scratch, .len = r.uintLessThan(u32, 70) },
            else => p.* = .{ .ptr = text_pool[r.uintLessThan(usize, 128)..].ptr, .len = r.uintLessThan(u32, 65) },
        },
        ArgDesc => mutateStruct(ArgDesc, p, r),
        else => {
            // A pointer or function pointer: null or a valid, zeroed buffer.
            comptime std.debug.assert(@sizeOf(T) == @sizeOf(usize));
            const v: usize = if (r.boolean()) 0 else @intFromPtr(&scratch);
            std.mem.asBytes(p).* = std.mem.toBytes(v);
        },
    }
}

fn mutateStruct(comptime T: type, p: *T, r: std.Random) void {
    const info = @typeInfo(T).@"struct";
    const pick = r.uintLessThan(usize, info.field_names.len);
    inline for (info.field_names, info.field_types, 0..) |name, FT, i| {
        if (i == pick) mutateValue(FT, &@field(p, name), r);
    }
}

fn mutateOnce(f: *Fixture, r: std.Random) void {
    const sc = r.uintLessThan(usize, 2);
    const j = if (r.boolean()) r.uintLessThan(usize, 3) else r.uintLessThan(usize, n);
    const k = r.uintLessThan(usize, 3);
    switch (r.uintLessThan(u8, 9)) {
        0 => mutateStruct(Table, &f.table, r),
        1, 2 => mutateStruct(ScriptDesc, &f.scripts[sc], r),
        3 => mutateStruct(FieldDesc, &f.fields[sc][j], r),
        4 => mutateStruct(PropertyDesc, &f.props[sc][j], r),
        5 => mutateStruct(MethodDesc, &f.methods[sc][j], r),
        6 => mutateStruct(SignalDesc, &f.signals[sc][j], r),
        7 => mutateStruct(ArgDesc, &f.method_args[sc][j][k], r),
        else => mutateStruct(ArgDesc, &f.signal_args[sc][j][k], r),
    }
}

/// Runs `rounds` rounds of 1 to 3 mutations on copies of the good table and
/// checks `validate` returns. Returns how many were accepted.
fn fuzzRun(r: std.Random, rounds: usize) usize {
    const pristine = Fixture.init();
    var accepted: usize = 0;
    var diag: [256]u8 = undefined;
    for (0..rounds) |_| {
        var work = pristine;
        work.link();
        for (0..1 + r.uintLessThan(usize, 3)) |_| mutateOnce(&work, r);
        if (work.check(fuzz_limits, &diag)) |_| {
            accepted += 1;
        } else |_| {
            // The diag is always one terminated sentence.
            std.debug.assert(std.mem.indexOfScalar(u8, &diag, 0) != null);
        }
    }
    return accepted;
}

test "fuzz validate" {
    var prng = std.Random.DefaultPrng.init(0x5A49_4747);
    const accepted = fuzzRun(prng.random(), 20000);
    // Many mutations are harmless (a changed `hint`, `usage`, `flags`), so
    // some pass; most must be caught.
    try testing.expect(accepted < 20000);
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var prng = std.Random.DefaultPrng.init(smith.value(u64));
    _ = fuzzRun(prng.random(), 64);
}

test "fuzz validate with std.testing.fuzz" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{ "seed one", "seed two" } });
}
