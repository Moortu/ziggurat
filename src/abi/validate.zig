//! Host-side validator for the `Table` a user module returns. The module is
//! not trusted, so every byte the validator reads is proven valid first, in
//! this order: the table header, then each count against its limit before any
//! array is indexed, then each array element and the strings it points to.
//!
//! Work is bounded: every count has a limit, and the whole table has a budget
//! of items (`Limits.max_total_items`) and string bytes
//! (`Limits.max_total_string_bytes`), however much the module shares arrays
//! or strings between scripts. Duplicate checks use a hash set, so they are
//! linear. The set uses a fixed hash seed; a module that crafts colliding
//! names can only slow a check by a factor bounded by the item budget.
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
    /// Scripts + fields + properties + methods + signals + arguments, summed
    /// over the whole table.
    max_total_items: u32 = 262144,
    /// Sum of the length of every `Str` the validator looks at.
    max_total_string_bytes: u32 = 16 << 20,
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
/// is empty. `a` is used for temporary hash sets, all freed before return.
pub fn validate(
    a: std.mem.Allocator,
    t: *const Table,
    expected_stamp: u64,
    limits: Limits,
    diag: *[256]u8,
) (ValidateError || error{OutOfMemory})!void {
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

    var c: Ctx = .{ .a = a, .diag = diag, .limits = limits };
    _ = try c.str(&t.sdk_version, .{ .what = "SDK version" });
    _ = try c.str(&t.build_id, .{ .what = "build id" });
    if (t.script_count > limits.max_scripts) {
        return c.fail(error.TooMany, "has {d} scripts, above the limit {d}.", .{ t.script_count, limits.max_scripts });
    }
    try c.items(t.script_count);
    const scripts = try c.array(ScriptDesc, &t.scripts, t.script_count, "scripts");

    for (scripts, 0..) |*s, i| {
        c.script_index = @intCast(i);
        c.path = "";
        try c.script(s);
    }
    c.script_index = null;
    c.path = "";

    // Paths are unique. Each one was validated above.
    var seen: Set = .empty;
    defer seen.deinit(a);
    try seen.ensureTotalCapacity(a, @intCast(scripts.len));
    for (scripts, 0..) |*sc, i| {
        const gop = seen.getOrPutAssumeCapacity(slice(&sc.path));
        if (gop.found_existing) {
            return c.fail(error.Duplicate, "has two scripts with the path \"{f}\" (scripts {d} and {d}).", .{ Clip{ .s = slice(&sc.path) }, gop.value_ptr.*, i });
        }
        gop.value_ptr.* = @intCast(i);
    }
}

const Set = std.StringHashMapUnmanaged(u32);

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

/// Names the item being checked, e.g. `property 3 name` or
/// `method 1 argument 0 class name`. Empty `kind` names a script or table
/// string directly (`class name`).
const Where = struct {
    kind: []const u8 = "",
    index: ?u32 = null,
    sub: []const u8 = "",
    sub_index: ?u32 = null,
    what: []const u8 = "",

    pub fn format(self: Where, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        inline for (.{ self.kind, self.sub, self.what }, 0..) |word, k| {
            if (word.len > 0) {
                if (!first) try w.writeByte(' ');
                try w.writeAll(word);
                first = false;
                const idx = if (k == 0) self.index else if (k == 1) self.sub_index else null;
                if (idx) |i| try w.print(" {d}", .{i});
            }
        }
    }
};

const Ctx = struct {
    a: std.mem.Allocator,
    diag: *[256]u8,
    limits: Limits,
    total_items: u64 = 0,
    total_bytes: u64 = 0,
    /// Set while a script is being checked.
    script_index: ?u32 = null,
    /// The script path once it has passed its checks, else empty.
    path: []const u8 = "",

    /// Writes the subject ("The table ", `Script "p" ` or `Script 3 `) and then
    /// the sentence in `fmt`, which continues it.
    fn fail(c: *Ctx, err: ValidateError, comptime fmt: []const u8, args: anytype) ValidateError {
        @memset(c.diag, 0);
        var w: std.Io.Writer = .fixed(c.diag[0..255]);
        if (c.script_index) |i| {
            if (c.path.len > 0) {
                w.print("Script \"{f}\" ", .{Clip{ .s = c.path }}) catch {};
            } else {
                w.print("Script {d} ", .{i}) catch {};
            }
        } else {
            w.writeAll("The table ") catch {};
        }
        w.print(fmt, args) catch {};
        return err;
    }

    /// Adds `k` to the whole-table item budget.
    fn items(c: *Ctx, k: u64) ValidateError!void {
        c.total_items += k;
        if (c.total_items > c.limits.max_total_items) {
            return c.fail(error.TooMany, "reaches {d} items in total, above the limit {d}.", .{ c.total_items, c.limits.max_total_items });
        }
    }

    /// Reads a `Str`: a non-null pointer when `len > 0`, `len` within the
    /// limit, valid UTF-8, no NUL. Returns the bytes.
    fn str(c: *Ctx, s: *const Str, where: Where) ValidateError![]const u8 {
        if (s.len == 0) return "";
        if (s.len > c.limits.max_string) {
            return c.fail(error.BadString, "{f} is {d} bytes long, above the limit {d}.", .{ where, s.len, c.limits.max_string });
        }
        if (isNull(&s.ptr)) {
            return c.fail(error.NullPointer, "{f} has length {d} but a null pointer.", .{ where, s.len });
        }
        c.total_bytes += s.len;
        if (c.total_bytes > c.limits.max_total_string_bytes) {
            return c.fail(error.TooMany, "reaches {d} string bytes in total, above the limit {d}.", .{ c.total_bytes, c.limits.max_total_string_bytes });
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
        if (bytes.len == 0) {
            if (allow_empty) return bytes;
            return c.fail(error.BadName, "has an empty {f}.", .{where});
        }
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
            return c.fail(error.NullPointer, "has a null " ++ what ++ " pointer but a count of {d}.", .{count});
        }
        const p_addr = addr(field);
        if (p_addr % @alignOf(T) != 0) {
            return c.fail(error.BadLayout, "has a misaligned " ++ what ++ " pointer 0x{x}, which needs {d}-byte alignment.", .{ p_addr, @alignOf(T) });
        }
        const p: [*]const T = @ptrFromInt(p_addr);
        return p[0..count];
    }

    fn limit(c: *Ctx, count: u32, max: u32, comptime what: []const u8) ValidateError!void {
        if (count > max) {
            return c.fail(error.TooMany, "has {d} " ++ what ++ ", above the limit {d}.", .{ count, max });
        }
    }

    fn fnPtr(c: *Ctx, field: anytype, comptime name: []const u8) ValidateError!void {
        if (isNull(field)) return c.fail(error.NullPointer, "has a null " ++ name ++ " function pointer.", .{});
    }

    fn variant(c: *Ctx, v: u32, where: Where) ValidateError!void {
        if (v >= variant_max) {
            return c.fail(error.BadType, "{f} has variant type {d}, above the maximum {d}.", .{ where, v, variant_max - 1 });
        }
    }

    /// Fails when two names in `list` (an array of structs with a `name: Str`)
    /// are equal. The names were validated by the caller. When `counts` is
    /// given, only the entries it accepts take part.
    fn unique(c: *Ctx, comptime T: type, list: []const T, comptime plural: []const u8, comptime counts: ?fn (*const T) bool) (ValidateError || error{OutOfMemory})!void {
        if (list.len < 2) return;
        var seen: Set = .empty;
        defer seen.deinit(c.a);
        try seen.ensureTotalCapacity(c.a, @intCast(list.len));
        for (list, 0..) |*e, i| {
            if (counts) |f| {
                if (!f(e)) continue;
            }
            const gop = seen.getOrPutAssumeCapacity(slice(&e.name));
            if (gop.found_existing) {
                return c.fail(error.Duplicate, "has two " ++ plural ++ " named \"{f}\" (numbers {d} and {d}).", .{ Clip{ .s = slice(&e.name) }, gop.value_ptr.*, i });
            }
            gop.value_ptr.* = @intCast(i);
        }
    }

    /// The arguments of method or signal `owner`.
    fn checkArgs(c: *Ctx, kind: []const u8, owner: u32, name: []const u8, p: anytype, count: u32) ValidateError!void {
        if (count > c.limits.max_args) {
            return c.fail(error.TooMany, "has {s} {d} \"{f}\" with {d} arguments, above the limit {d}.", .{ kind, owner, Clip{ .s = name }, count, c.limits.max_args });
        }
        try c.items(count);
        const list = try c.array(ArgDesc, p, count, "arguments");
        for (list, 0..) |*a, k| {
            const k32: u32 = @intCast(k);
            _ = try c.identifier(&a.name, .{ .kind = kind, .index = owner, .sub = "argument", .sub_index = k32, .what = "name" }, false);
            try c.variant(a.variant_type, .{ .kind = kind, .index = owner, .sub = "argument", .sub_index = k32 });
            _ = try c.identifier(&a.class_name, .{ .kind = kind, .index = owner, .sub = "argument", .sub_index = k32, .what = "class name" }, true);
        }
    }

    fn script(c: *Ctx, s: *const ScriptDesc) (ValidateError || error{OutOfMemory})!void {
        const idx = c.script_index.?;
        const path = try c.str(&s.path, .{ .what = "path" });
        if (path.len == 0) return c.fail(error.BadName, "has an empty path.", .{});
        if (!isRelativePath(path)) {
            return c.fail(error.BadName, "has the path \"{f}\", which is not a relative path of non-empty parts without \".\" or \"..\".", .{Clip{ .s = path }});
        }
        _ = idx;
        c.path = path;
        _ = try c.identifier(&s.class_name, .{ .what = "class name" }, true);
        _ = try c.identifier(&s.base_class, .{ .what = "base class" }, false);

        if (s.instance_size > c.limits.max_instance_size) {
            return c.fail(error.BadLayout, "has instance size {d}, above the limit {d}.", .{ s.instance_size, c.limits.max_instance_size });
        }
        const al = s.instance_align;
        if (al == 0 or al > 4096 or !std.math.isPowerOfTwo(al)) {
            return c.fail(error.BadLayout, "has instance alignment {d}, which is not a power of two up to 4096.", .{al});
        }

        // Every count against its limit, and the item budget, before any
        // array is indexed.
        try c.limit(s.field_count, c.limits.max_fields, "fields");
        try c.limit(s.property_count, c.limits.max_properties, "properties");
        try c.limit(s.method_count, c.limits.max_methods, "methods");
        try c.limit(s.signal_count, c.limits.max_signals, "signals");
        try c.items(@as(u64, s.field_count) + s.property_count + s.method_count + s.signal_count);

        if (isNull(&s.defaults)) return c.fail(error.NullPointer, "has a null defaults pointer.", .{});
        try c.fnPtr(&s.create, "create");
        try c.fnPtr(&s.destroy, "destroy");
        try c.fnPtr(&s.call, "call");
        try c.fnPtr(&s.get, "get");
        try c.fnPtr(&s.set, "set");
        try c.fnPtr(&s.get_default, "get_default");
        try c.fnPtr(&s.notification, "notification");

        const fields = try c.array(FieldDesc, &s.fields, s.field_count, "fields");
        for (fields, 0..) |*f, i| {
            const name = try c.identifier(&f.name, .{ .kind = "field", .index = @intCast(i), .what = "name" }, false);
            const end = @as(u64, f.offset) + f.size;
            if (end > s.instance_size) {
                return c.fail(error.BadLayout, "has field {d} \"{f}\" ending at byte {d}, past the instance size {d}.", .{ i, Clip{ .s = name }, end, s.instance_size });
            }
        }

        const props = try c.array(PropertyDesc, &s.properties, s.property_count, "properties");
        for (props, 0..) |*p, i| {
            const i32_: u32 = @intCast(i);
            // A group entry's name is a label (any text; empty ends a group).
            const name = if (isGroupEntry(p))
                try c.str(&p.name, .{ .kind = "property", .index = i32_, .what = "name" })
            else
                try c.identifier(&p.name, .{ .kind = "property", .index = i32_, .what = "name" }, false);
            try c.variant(p.variant_type, .{ .kind = "property", .index = i32_ });
            _ = try c.identifier(&p.class_name, .{ .kind = "property", .index = i32_, .what = "class name" }, true);
            _ = try c.str(&p.hint_string, .{ .kind = "property", .index = i32_, .what = "hint string" });
            if (p.field_index != abi.no_field and p.field_index >= s.field_count) {
                return c.fail(error.BadLayout, "has property {d} \"{f}\" with field index {d}, but only {d} fields.", .{ i, Clip{ .s = name }, p.field_index, s.field_count });
            }
        }
        try c.unique(PropertyDesc, props, "properties", notGroupEntry);

        const methods = try c.array(MethodDesc, &s.methods, s.method_count, "methods");
        for (methods, 0..) |*m, i| {
            const i32_: u32 = @intCast(i);
            const name = try c.identifier(&m.name, .{ .kind = "method", .index = i32_, .what = "name" }, false);
            try c.variant(m.ret.variant_type, .{ .kind = "method", .index = i32_, .what = "return" });
            _ = try c.str(&m.ret.name, .{ .kind = "method", .index = i32_, .what = "return name" });
            _ = try c.identifier(&m.ret.class_name, .{ .kind = "method", .index = i32_, .what = "return class name" }, true);
            try c.checkArgs("method", i32_, name, &m.args, m.arg_count);
        }
        try c.unique(MethodDesc, methods, "methods", null);

        const sigs = try c.array(SignalDesc, &s.signals, s.signal_count, "signals");
        for (sigs, 0..) |*g, i| {
            const i32_: u32 = @intCast(i);
            const name = try c.identifier(&g.name, .{ .kind = "signal", .index = i32_, .what = "name" }, false);
            try c.checkArgs("signal", i32_, name, &g.args, g.arg_count);
        }
        try c.unique(SignalDesc, sigs, "signals", null);
    }
};

/// A group entry: usage GROUP and no backing field. Godot shows its name as a
/// section label and never looks it up, so any text is allowed, the empty
/// name (which ends a group) included, and the name need not be unique.
fn isGroupEntry(p: *const PropertyDesc) bool {
    return p.usage & abi.usage_group != 0 and p.field_index == abi.no_field;
}

fn notGroupEntry(p: *const PropertyDesc) bool {
    return !isGroupEntry(p);
}

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
fn dummyCall(_: *anyopaque, _: u32, _: ?[*]const *const anyopaque, _: i64, _: *anyopaque, _: *abi.CallError) callconv(.c) void {}
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

    fn check(f: *const Fixture, limits: Limits, diag: *[256]u8) (ValidateError || error{OutOfMemory})!void {
        return validate(testing.allocator, &f.table, stamp, limits, diag);
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
    }.m, error.TooMany, "has 70000 scripts, above the limit 65536");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].field_count = 5000;
        }
    }.m, error.TooMany, "Script \"a/x.zig\" has 5000 fields, above the limit 4096.");
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
    }.m, error.TooMany, "has method 1 \"hit\" with 65 arguments");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.signals[0][0].arg_count = 65;
        }
    }.m, error.TooMany, "has signal 0 \"died\" with 65 arguments");
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
    }.m, error.BadString, "5000 bytes long, above the limit 4096");
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
    }.m, error.BadName, "has an empty base class");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[1].path = .{ .ptr = null, .len = 0 };
        }
    }.m, error.BadName, "Script 1 has an empty path.");
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
    }.m, error.BadName, "method 1 argument 0 class name \"9\"");
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
    }.m, error.BadType, "method 1 argument 0 has variant type 100");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.signal_args[0][0][0].variant_type = 0xFFFF_FFFF;
        }
    }.m, error.BadType, "signal 0 argument 0 has variant type 4294967295");
}

test "validate layout" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].instance_size = 1 << 25;
        }
    }.m, error.BadLayout, "has instance size 33554432, above the limit 16777216");
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
    }.m, error.BadLayout, "has field 1 \"name\" ending at byte 36, past the instance size 32");
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
    }.m, error.BadLayout, "has property 0 \"hp\" with field index 2, but only 2 fields");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            const misaligned: usize = @intFromPtr(&f.fields[0]) + 1;
            std.mem.asBytes(&f.scripts[0].fields)[0..@sizeOf(usize)].* = std.mem.toBytes(misaligned);
        }
    }.m, error.BadLayout, "misaligned fields pointer");
}

test "validate null pointers" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.table.scripts), 0);
        }
    }.m, error.NullPointer, "null scripts pointer");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[0].properties), 0);
        }
    }.m, error.NullPointer, "null properties pointer");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.methods[0][1].args), 0);
        }
    }.m, error.NullPointer, "null arguments pointer");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[0].defaults), 0);
        }
    }.m, error.NullPointer, "null defaults pointer");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[1].notification), 0);
        }
    }.m, error.NullPointer, "Script \"b/y.zig\" has a null notification function pointer.");
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
    }.m, error.Duplicate, "two properties named \"hp\" (numbers 0 and 1)");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.methods[0][1].name, "_ready");
        }
    }.m, error.Duplicate, "two methods named \"_ready\"");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.scripts[1].path = f.scripts[0].path;
        }
    }.m, error.Duplicate, "has two scripts with the path \"a/x.zig\" (scripts 0 and 1)");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.signals[0][0].arg_count = 0;
            f.scripts[0].signal_count = 2;
            f.signals[0][1] = f.signals[0][0];
        }
    }.m, error.Duplicate, "two signals named \"died\"");
}

test "validate group entries" {
    var f = Fixture.init();
    f.link();
    // Script 0 has properties "hp" (field 0) and "name" (no field).
    f.scripts[0].property_count = 4;
    const label = "Stats and more/Sub";
    const group: PropertyDesc = .{ .name = .{ .ptr = label.ptr, .len = label.len }, .field_index = abi.no_field, .variant_type = 0, .class_name = .{ .ptr = null, .len = 0 }, .hint = 0, .hint_string = .{ .ptr = null, .len = 0 }, .usage = abi.usage_group };
    f.props[0][2] = group;
    f.props[0][3] = group;
    setStr(&f.props[0][3].name, "hp"); // same name as a property: allowed for a group
    var diag: [256]u8 = undefined;
    try f.check(.{}, &diag);
    // The empty name ends a group.
    f.props[0][3].name = .{ .ptr = null, .len = 0 };
    try f.check(.{}, &diag);
    // Two groups with one name.
    f.props[0][3] = group;
    try f.check(.{}, &diag);

    try expectRule(struct {
        fn m(g: *Fixture) void {
            g.props[0][1].usage = abi.usage_group;
            setStr(&g.props[0][1].name, "a\x00b");
        }
    }.m, error.BadString, "property 1 name contains a NUL byte");
    try expectRule(struct {
        fn m(g: *Fixture) void {
            g.props[0][1].usage = abi.usage_group;
            setStr(&g.props[0][1].name, "\xff");
        }
    }.m, error.BadString, "property 1 name is not valid UTF-8");
    // A group usage on a property with a field is a plain property: identifier rules.
    try expectRule(struct {
        fn m(g: *Fixture) void {
            g.props[0][0].usage = abi.usage_group;
            setStr(&g.props[0][0].name, "h p");
        }
    }.m, error.BadName, "property 0 name \"h p\"");
    // A non-group entry without a field still needs an identifier and a unique name.
    try expectRule(struct {
        fn m(g: *Fixture) void {
            setStr(&g.props[0][1].name, "");
        }
    }.m, error.BadName, "has an empty property 1 name");
    try expectRule(struct {
        fn m(g: *Fixture) void {
            g.props[0][1].usage = 6;
            setStr(&g.props[0][1].name, "hp");
        }
    }.m, error.Duplicate, "two properties named \"hp\"");
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

test "validate table strings and return names" {
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.sdk_version = .{ .ptr = null, .len = 4 };
        }
    }.m, error.NullPointer, "The table SDK version has length 4 but a null pointer.");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.table.sdk_version, "a\xffb");
        }
    }.m, error.BadString, "The table SDK version is not valid UTF-8.");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.table.build_id = .{ .ptr = text.ptr, .len = 9999 };
        }
    }.m, error.BadString, "The table build id is 9999 bytes long, above the limit 4096.");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.table.build_id, "x\x00y");
        }
    }.m, error.BadString, "The table build id contains a NUL byte at position 1.");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            f.methods[0][1].ret.name = .{ .ptr = null, .len = 5 };
        }
    }.m, error.NullPointer, "method 1 return name has length 5 but a null pointer");
    try expectRule(struct {
        fn m(f: *Fixture) void {
            setStr(&f.methods[0][1].ret.name, "\xc0");
        }
    }.m, error.BadString, "method 1 return name is not valid UTF-8");
}

fn expectExact(comptime mutate: fn (*Fixture) void, err: ValidateError, exact: []const u8) !void {
    var f = Fixture.init();
    f.link();
    mutate(&f);
    var diag: [256]u8 = undefined;
    try testing.expectError(err, f.check(.{}, &diag));
    try testing.expectEqualStrings(exact, diagText(&diag));
}

test "validate diag text is exact" {
    try expectExact(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].field_count = 5000;
        }
    }.m, error.TooMany, "Script \"a/x.zig\" has 5000 fields, above the limit 4096.");
    try expectExact(struct {
        fn m(f: *Fixture) void {
            f.scripts[0].path = .{ .ptr = null, .len = 0 };
        }
    }.m, error.BadName, "Script 0 has an empty path.");
    try expectExact(struct {
        fn m(f: *Fixture) void {
            f.props[0][0].variant_type = 57;
        }
    }.m, error.BadType, "Script \"a/x.zig\" property 0 has variant type 57, above the maximum 38.");
    try expectExact(struct {
        fn m(f: *Fixture) void {
            f.table.script_count = 70000;
        }
    }.m, error.TooMany, "The table has 70000 scripts, above the limit 65536.");
    try expectExact(struct {
        fn m(f: *Fixture) void {
            @memset(std.mem.asBytes(&f.scripts[1].defaults), 0);
        }
    }.m, error.NullPointer, "Script \"b/y.zig\" has a null defaults pointer.");
}

fn validateGood(a: std.mem.Allocator) !void {
    var f = Fixture.init();
    f.link();
    var diag: [256]u8 = undefined;
    try validate(a, &f.table, stamp, .{}, &diag);
}

test "validate frees its sets and passes out of memory on" {
    try testing.checkAllAllocationFailures(testing.allocator, validateGood, .{});
}

/// A table of `count` bare scripts with unique paths, owned by the test. When
/// `props` is set, script 0 (or all scripts if `share`) uses an array of
/// `props` properties.
const Big = struct {
    scripts: []ScriptDesc,
    path_bytes: []u8,
    prop_names: []u8,
    props: []PropertyDesc,
    table: Table,
    fx: *Fixture,

    fn init(a: std.mem.Allocator, count: u32, prop_count: u32, share: bool) !Big {
        const fx = try a.create(Fixture);
        errdefer a.destroy(fx);
        fx.* = Fixture.init();
        fx.link();
        const scripts = try a.alloc(ScriptDesc, count);
        errdefer a.free(scripts);
        const path_bytes = try a.alloc(u8, @as(usize, count) * 16);
        errdefer a.free(path_bytes);
        const prop_names = try a.alloc(u8, @as(usize, prop_count) * 8);
        errdefer a.free(prop_names);
        const props = try a.alloc(PropertyDesc, prop_count);
        errdefer a.free(props);
        for (props, 0..) |*p, i| {
            const nm = prop_names[i * 8 ..][0..8];
            _ = std.fmt.bufPrint(nm, "p{d:0>6}", .{i}) catch unreachable;
            p.* = std.mem.zeroes(PropertyDesc);
            p.name = .{ .ptr = nm.ptr, .len = 7 };
            p.field_index = abi.no_field;
        }
        for (scripts, 0..) |*sc, i| {
            sc.* = fx.scripts[1];
            const pb = path_bytes[i * 16 ..][0..16];
            const used = std.fmt.bufPrint(pb, "d/{d}.zig", .{i}) catch unreachable;
            sc.path = .{ .ptr = used.ptr, .len = @intCast(used.len) };
            if (prop_count > 0 and (share or i == 0)) {
                sc.properties = props.ptr;
                sc.property_count = prop_count;
            }
        }
        var table = fx.table;
        table.scripts = scripts.ptr;
        table.script_count = count;
        return .{ .scripts = scripts, .path_bytes = path_bytes, .prop_names = prop_names, .props = props, .table = table, .fx = fx };
    }

    fn deinit(b: *Big, a: std.mem.Allocator) void {
        a.free(b.scripts);
        a.free(b.path_bytes);
        a.free(b.prop_names);
        a.free(b.props);
        a.destroy(b.fx);
    }

    fn run(b: *const Big, limits: Limits, diag: *[256]u8) (ValidateError || error{OutOfMemory})!void {
        return validate(testing.allocator, &b.table, stamp, limits, diag);
    }
};

fn nowNs() i96 {
    return std.Io.Clock.awake.now(testing.io).nanoseconds;
}

/// Fails when `ms` is 1000 or more. Prints only then: any output on stderr
/// makes the build runner print the test command as if it had failed.
fn expectFast(what: []const u8, ms: i96) !void {
    if (ms < 1000) return;
    std.debug.print("{s}: {d} ms, above the 1000 ms budget\n", .{ what, ms });
    return error.TooSlow;
}

test "validate at the default limits is fast" {
    var diag: [256]u8 = undefined;
    // 65536 scripts with unique paths and one script with 4096 properties:
    // 69632 items, inside the 262144 budget.
    var big = try Big.init(testing.allocator, 65536, 4096, false);
    defer big.deinit(testing.allocator);
    var t0 = nowNs();
    try big.run(.{}, &diag);
    var ms = @divTrunc(nowNs() - t0, std.time.ns_per_ms);
    try expectFast("validate at limits", ms);

    // Every script shares the 4096-property array: 65536 * 4097 items, far
    // over the budget. Rejected after the first few scripts.
    var shared = try Big.init(testing.allocator, 65536, 4096, true);
    defer shared.deinit(testing.allocator);
    t0 = nowNs();
    try testing.expectError(error.TooMany, shared.run(.{}, &diag));
    ms = @divTrunc(nowNs() - t0, std.time.ns_per_ms);
    try expectFast("validate over budget", ms);
    try testing.expect(std.mem.indexOf(u8, diagText(&diag), "items in total, above the limit 262144.") != null);

    // Two equal paths at the far ends of 65536 are found in linear time.
    big.scripts[65535].path = big.scripts[0].path;
    t0 = nowNs();
    try testing.expectError(error.Duplicate, big.run(.{}, &diag));
    ms = @divTrunc(nowNs() - t0, std.time.ns_per_ms);
    try expectFast("validate duplicate path", ms);
}

test "validate string byte budget" {
    var f = Fixture.init();
    f.link();
    var diag: [256]u8 = undefined;
    try testing.expectError(error.TooMany, f.check(.{ .max_total_string_bytes = 10 }, &diag));
    try testing.expect(std.mem.indexOf(u8, diagText(&diag), "string bytes in total, above the limit 10.") != null);
    try testing.expectError(error.TooMany, f.check(.{ .max_total_items = 5 }, &diag));
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

fn strBad(x: Str) bool {
    if (x.len == 0) return false;
    if (x.ptr == null or x.len > fuzz_limits.max_string) return true;
    return @intFromPtr(x.ptr.?) == @intFromPtr(&scratch); // all zero bytes: a NUL
}

fn nameBad(x: Str) bool {
    return x.len == 0 or strBad(x);
}

fn argsBad(list: *const [n]ArgDesc, own: *const [n]ArgDesc, ptr_field: anytype, count: u32) bool {
    if (count > n) return true;
    if (count == 0) return false;
    if (addr(ptr_field) != @intFromPtr(own)) return true;
    for (list[0..count]) |a| {
        if (nameBad(a.name) or a.variant_type >= variant_max or strBad(a.class_name)) return true;
    }
    return false;
}

/// An independent, conservative check: true only when the table certainly
/// breaks a rule. It reads the fixture's own arrays, and counts a pointer
/// that no longer points at its original array as a violation whenever the
/// count is above zero (a null pointer is refused, and the zero buffer holds
/// elements with empty names).
fn mustReject(f: *const Fixture) bool {
    const t = &f.table;
    if (t.magic != abi.magic or t.abi_version != abi.abi_version) return true;
    if (t.size != @sizeOf(Table) or t.layout_stamp != stamp) return true;
    if (strBad(t.sdk_version) or strBad(t.build_id)) return true;
    if (t.script_count > n) return true;
    if (t.script_count == 0) return false;
    if (addr(&t.scripts) != @intFromPtr(&f.scripts)) return true;
    for (f.scripts[0..t.script_count], 0..) |*sc, i| {
        if (nameBad(sc.path) or strBad(sc.class_name) or nameBad(sc.base_class)) return true;
        if (i >= 2) return true; // zero-filled spare script
        if (sc.instance_size > fuzz_limits.max_instance_size) return true;
        if (sc.instance_align == 0 or sc.instance_align > 4096 or !std.math.isPowerOfTwo(sc.instance_align)) return true;
        if (sc.field_count > n or sc.property_count > n or sc.method_count > n or sc.signal_count > n) return true;
        if (addr(&sc.defaults) == 0) return true;
        inline for (.{ "create", "destroy", "call", "get", "set", "get_default", "notification" }) |name| {
            if (addr(&@field(sc, name)) == 0) return true;
        }
        if (sc.field_count > 0) {
            if (addr(&sc.fields) != @intFromPtr(&f.fields[i])) return true;
            for (f.fields[i][0..sc.field_count]) |fd| {
                if (nameBad(fd.name) or @as(u64, fd.offset) + fd.size > sc.instance_size) return true;
            }
        }
        if (sc.property_count > 0) {
            if (addr(&sc.properties) != @intFromPtr(&f.props[i])) return true;
            for (f.props[i][0..sc.property_count]) |p| {
                const name_bad = if (isGroupEntry(&p)) strBad(p.name) else nameBad(p.name);
                if (name_bad or p.variant_type >= variant_max or strBad(p.class_name) or strBad(p.hint_string)) return true;
                if (p.field_index != abi.no_field and p.field_index >= sc.field_count) return true;
            }
        }
        if (sc.method_count > 0) {
            if (addr(&sc.methods) != @intFromPtr(&f.methods[i])) return true;
            for (f.methods[i][0..sc.method_count], 0..) |*m, j| {
                if (nameBad(m.name) or m.ret.variant_type >= variant_max) return true;
                if (strBad(m.ret.name) or strBad(m.ret.class_name)) return true;
                if (argsBad(&f.method_args[i][j], &f.method_args[i][j], &m.args, m.arg_count)) return true;
            }
        }
        if (sc.signal_count > 0) {
            if (addr(&sc.signals) != @intFromPtr(&f.signals[i])) return true;
            for (f.signals[i][0..sc.signal_count], 0..) |*g, j| {
                if (nameBad(g.name)) return true;
                if (argsBad(&f.signal_args[i][j], &f.signal_args[i][j], &g.args, g.arg_count)) return true;
            }
        }
    }
    return false;
}

const FuzzStats = struct { accepted: usize = 0, oracle_rejects: usize = 0 };

/// Runs `rounds` rounds of 1 to 3 mutations on copies of the good table.
/// `validate` must return, and must reject whenever `mustReject` says so.
fn fuzzRun(r: std.Random, rounds: usize) !FuzzStats {
    const pristine = Fixture.init();
    var stats: FuzzStats = .{};
    var diag: [256]u8 = undefined;
    for (0..rounds) |_| {
        var work = pristine;
        work.link();
        for (0..1 + r.uintLessThan(usize, 3)) |_| mutateOnce(&work, r);
        const must = mustReject(&work);
        if (must) stats.oracle_rejects += 1;
        if (work.check(fuzz_limits, &diag)) |_| {
            stats.accepted += 1;
            if (must) {
                std.debug.print("validate accepted a table the oracle rejects\n", .{});
                return error.OracleMismatch;
            }
        } else |err| {
            // The diag is always one terminated sentence.
            try testing.expect(err != error.OutOfMemory);
            try testing.expect(diag[0] != 0 and std.mem.indexOfScalar(u8, &diag, 0) != null);
        }
    }
    return stats;
}

test "fuzz validate" {
    var prng = std.Random.DefaultPrng.init(0x5A49_4747);
    const stats = try fuzzRun(prng.random(), 20000);
    // Many mutations are harmless (a changed `hint`, `usage`, `flags`), so
    // some pass; most must be caught, and the oracle must have been busy.
    try testing.expect(stats.accepted < 20000);
    try testing.expect(stats.oracle_rejects > 5000);
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var prng = std.Random.DefaultPrng.init(smith.value(u64));
    _ = try fuzzRun(prng.random(), 64);
}

test "fuzz validate with std.testing.fuzz" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{ "seed one", "seed two" } });
}
