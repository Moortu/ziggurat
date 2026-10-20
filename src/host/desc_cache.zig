//! The descriptor cache: `.godot/ziggurat/descriptors.json`.
//!
//! After each good load the host writes what the editor needs to know about
//! every script (path, class name, base class, flags, layout hash,
//! properties with their defaults, methods, signals). At the next start it
//! reads the file, so the Inspector and placeholder instances work before
//! the first build of the session has finished (plan, "Descriptor cache
//! format").
//!
//! The file is one JSON object:
//!
//!     { "version": 1, "generation": <n>, "scripts": [ {
//!         "path", "class_name", "base_class", "flags",
//!         "layout_hash": "<decimal>",
//!         "properties": [ { "name", "class_name", "type", "hint",
//!                           "hint_string", "usage", "default"? } ],
//!         "methods": [ { "name", "flags", "ret": <arg>, "args": [<arg>] } ],
//!         "signals": [ { "name", "args": [<arg>] } ] } ] }
//!
//! with `<arg>` = `{ "name", "class_name", "type" }`. `default` is Godot's
//! `var_to_str` text of the property's default value; group entries and
//! properties without a default have none. `layout_hash` is a decimal
//! string because a JSON number cannot hold every u64 exactly. Method
//! `flags` are the ABI's (`abi.method_flag_virtual`).
//!
//! Writing is atomic (temporary file, `fsync`, rename). Reading never
//! panics on bad input: an unknown version, truncated or malformed JSON,
//! wrong types or an unreadable file make `read` return `error.Rejected`
//! after logging one line that names the file; the caller then carries on
//! as if there were no cache.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const platform = @import("ziggurat_platform");
const props = @import("props.zig");
const default_value = @import("default_value.zig");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const Array = godot.builtin.Array;
const Variant = godot.builtin.Variant;
const OsPath = platform.path.OsPath;
const Default = default_value.Default;

/// The `version` this host writes and reads.
pub const format_version: u32 = 1;

/// Largest cache file read; a bigger file is rejected.
pub const max_file_bytes = 16 * 1024 * 1024;

/// An unsigned integer that must be a JSON number: std.json would also take
/// the string "5" for a `u32`, which is the wrong type.
pub const U32 = struct {
    v: u32 = 0,

    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !U32 {
        _ = options;
        const tok = try source.nextAlloc(a, .alloc_if_needed);
        switch (tok) {
            .number, .allocated_number => |s| return .{ .v = std.fmt.parseInt(u32, s, 10) catch return error.InvalidNumber },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonStringify(self: U32, jw: anytype) !void {
        try jw.write(self.v);
    }
};

pub const ArgJson = struct {
    name: []const u8,
    class_name: []const u8 = "",
    type: U32,

    fn info(a: ArgJson) props.PropInfo {
        return .{ .name = a.name, .class_name = a.class_name, .type = a.type.v };
    }
};

pub const PropertyJson = struct {
    name: []const u8,
    class_name: []const u8 = "",
    type: U32,
    hint: U32 = .{},
    hint_string: []const u8 = "",
    usage: U32,
    /// Typed JSON, see `default_value`; `.absent` (no field) for none.
    default: Default = .absent,

    /// Writes every field, but `default` only when there is one.
    pub fn jsonStringify(p: PropertyJson, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(p.name);
        try jw.objectField("class_name");
        try jw.write(p.class_name);
        try jw.objectField("type");
        try jw.write(p.type);
        try jw.objectField("hint");
        try jw.write(p.hint);
        try jw.objectField("hint_string");
        try jw.write(p.hint_string);
        try jw.objectField("usage");
        try jw.write(p.usage);
        if (p.default != .absent) {
            try jw.objectField("default");
            try jw.write(p.default);
        }
        try jw.endObject();
    }
};

pub const MethodJson = struct {
    name: []const u8,
    flags: U32 = .{},
    ret: ArgJson,
    args: []const ArgJson = &.{},
};

pub const SignalJson = struct {
    name: []const u8,
    args: []const ArgJson = &.{},
};

/// One script of the cache. Its lists are the same Godot data `props` makes
/// from a loaded descriptor.
pub const Script = struct {
    path: []const u8,
    class_name: []const u8 = "",
    base_class: []const u8 = "",
    flags: U32 = .{},
    layout_hash: []const u8,
    properties: []const PropertyJson = &.{},
    methods: []const MethodJson = &.{},
    signals: []const SignalJson = &.{},

    /// The layout hash. `read` has checked that it parses.
    pub fn layoutHash(s: *const Script) u64 {
        return std.fmt.parseInt(u64, s.layout_hash, 10) catch 0;
    }

    /// As `props.propertyList`.
    pub fn propertyList(s: *const Script) Array {
        var arr = Array.init();
        for (s.properties) |p| props.pushProp(&arr, .{
            .name = p.name,
            .class_name = p.class_name,
            .type = p.type.v,
            .hint = p.hint.v,
            .hint_string = p.hint_string,
            .usage = p.usage.v,
        });
        return arr;
    }

    /// As `props.methodList`.
    pub fn methodList(s: *const Script) Array {
        var arr = Array.init();
        for (s.methods) |m| {
            var args = argArray(m.args);
            defer args.deinit();
            var d = props.methodDict(m.name, args, props.godotMethodFlags(m.flags.v), m.ret.info());
            defer d.deinit();
            props.pushDict(&arr, d);
        }
        return arr;
    }

    /// As `props.signalList`.
    pub fn signalList(s: *const Script) Array {
        var arr = Array.init();
        for (s.signals) |sig| {
            var args = argArray(sig.args);
            defer args.deinit();
            var d = props.signalDict(sig.name, args);
            defer d.deinit();
            props.pushDict(&arr, d);
        }
        return arr;
    }

    /// As `props.defaultValue`: a Variant of the property's declared type
    /// built from the stored typed default. Null when there is none.
    pub fn defaultValue(s: *const Script, prop_index: u32) ?Variant {
        if (prop_index >= s.properties.len) return null;
        const p = s.properties[prop_index];
        return default_value.toVariant(p.type.v, p.default);
    }
};

fn argArray(args: []const ArgJson) Array {
    var arr = Array.init();
    for (args) |a| props.pushProp(&arr, a.info());
    return arr;
}

const FileJson = struct {
    version: U32,
    generation: U32,
    scripts: []const Script = &.{},
};

/// A cache file read from disk. Valid until `deinit`.
pub const Cache = struct {
    parsed: std.json.Parsed(FileJson),
    /// Stored defaults that did not fit their property's type; `parse`
    /// dropped them.
    dropped_defaults: u32 = 0,

    pub fn deinit(c: *Cache) void {
        c.parsed.deinit();
    }

    /// The generation number that wrote the file.
    pub fn generation(c: *const Cache) u32 {
        return c.parsed.value.generation.v;
    }

    pub fn scripts(c: *const Cache) []const Script {
        return c.parsed.value.scripts;
    }

    /// The script at project-relative path `rel`, or null.
    pub fn find(c: *const Cache, rel: []const u8) ?*const Script {
        for (c.scripts()) |*s| {
            if (std.mem.eql(u8, s.path, rel)) return s;
        }
        return null;
    }
};

// ------------------------------------------------------------- writing

/// The typed default of property `i` of `desc`, from the module's
/// `get_default`.
pub const GodotDefaults = struct {
    pub fn value(_: GodotDefaults, a: Allocator, desc: *const abi.ScriptDesc, i: u32) Allocator.Error!Default {
        const v = props.defaultValue(desc, i) orelse return .absent;
        defer v.deinit();
        return default_value.fromVariant(a, desc.properties[i].variant_type, v);
    }
};

/// The cache file's bytes for `scripts` as generation `gen`. `defaults` has
/// `value(a, desc, prop_index) !Default` (allocated with `a`).
pub fn serialize(a: Allocator, gen: u32, scripts: []const abi.ScriptDesc, defaults: anytype) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try arena.alloc(Script, scripts.len);
    for (scripts, out) |*d, *o| o.* = try scriptJson(arena, d, defaults);
    const file: FileJson = .{ .version = .{ .v = format_version }, .generation = .{ .v = gen }, .scripts = out };

    var w: std.Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &w.writer);
    try w.writer.writeByte('\n');
    return w.toOwnedSlice();
}

fn argJsons(arena: Allocator, list: []const abi.ArgDesc) ![]ArgJson {
    const out = try arena.alloc(ArgJson, list.len);
    for (list, out) |d, *o| o.* = argJson(d);
    return out;
}

fn argJson(d: abi.ArgDesc) ArgJson {
    return .{ .name = props.text(d.name), .class_name = props.text(d.class_name), .type = .{ .v = d.variant_type } };
}

fn scriptJson(arena: Allocator, d: *const abi.ScriptDesc, defaults: anytype) !Script {
    const ps = try arena.alloc(PropertyJson, d.property_count);
    for (d.properties[0..d.property_count], ps, 0..) |p, *o, i| {
        o.* = .{
            .name = props.text(p.name),
            .class_name = props.text(p.class_name),
            .type = .{ .v = p.variant_type },
            .hint = .{ .v = p.hint },
            .hint_string = props.text(p.hint_string),
            .usage = .{ .v = p.usage },
            .default = if (p.field_index == abi.no_field) .absent else try defaults.value(arena, d, @intCast(i)),
        };
    }
    const ms = try arena.alloc(MethodJson, d.method_count);
    for (d.methods[0..d.method_count], ms) |m, *o| {
        o.* = .{
            .name = props.text(m.name),
            .flags = .{ .v = m.flags },
            .ret = argJson(m.ret),
            .args = try argJsons(arena, if (m.arg_count == 0) &.{} else m.args[0..m.arg_count]),
        };
    }
    const ss = try arena.alloc(SignalJson, d.signal_count);
    for (d.signals[0..d.signal_count], ss) |s, *o| {
        o.* = .{
            .name = props.text(s.name),
            .args = try argJsons(arena, if (s.arg_count == 0) &.{} else s.args[0..s.arg_count]),
        };
    }
    return .{
        .path = props.text(d.path),
        .class_name = props.text(d.class_name),
        .base_class = props.text(d.base_class),
        .flags = .{ .v = d.flags },
        .layout_hash = try std.fmt.allocPrint(arena, "{d}", .{d.layout_hash}),
        .properties = ps,
        .methods = ms,
        .signals = ss,
    };
}

/// Writes the cache of the loaded generation `gen` to `path` (atomically;
/// missing folders are created). Main thread: it calls the module's
/// `get_default` and Godot's constructors.
pub fn write(a: Allocator, io: std.Io, path: OsPath, gen: *const runtime.Generation) !void {
    const bytes = try serialize(a, gen.n, gen.scripts(), GodotDefaults{});
    defer a.free(bytes);
    try platform.atomic_file.write(io, path, bytes);
}

// ------------------------------------------------------------- reading

pub const ReadError = error{ Rejected, FileNotFound, OutOfMemory };

/// How many `Rejected` results `read` has logged (for tests).
pub var rejections_logged: std.atomic.Value(u32) = .init(0);
/// How many "dropped defaults" lines `read` has logged (for tests).
pub var drops_logged: std.atomic.Value(u32) = .init(0);

/// Parses cache file bytes. On `error.Rejected` `diag` holds the reason, a
/// clause that completes "the file ...". Pure: no engine calls.
pub fn parse(a: Allocator, bytes: []const u8, diag: *[256]u8) ReadError!Cache {
    @memset(diag, 0);
    const Head = struct { version: U32 };
    const head = std.json.parseFromSlice(Head, a, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return reject(diag, "is not valid JSON with a version number ({s})", .{@errorName(err)}),
    };
    defer head.deinit();
    if (head.value.version.v != format_version)
        return reject(diag, "has version {d}, but this host reads version {d}", .{ head.value.version.v, format_version });

    var parsed = std.json.parseFromSlice(FileJson, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return reject(diag, "does not hold descriptors in the expected shape ({s})", .{@errorName(err)}),
    };
    errdefer parsed.deinit();
    var dropped: u32 = 0;
    for (parsed.value.scripts) |s| {
        _ = std.fmt.parseInt(u64, s.layout_hash, 10) catch
            return reject(diag, "has a script with a bad layout hash", .{});
        if (s.path.len == 0) return reject(diag, "has a script without a path", .{});
        // The strings and slices are the parse arena's, ours to change.
        for (@constCast(s.properties)) |*p| {
            if (!default_value.fits(p.type.v, p.default)) {
                p.default = .absent;
                dropped += 1;
            }
        }
    }
    return .{ .parsed = parsed, .dropped_defaults = dropped };
}

fn reject(diag: *[256]u8, comptime fmt: []const u8, a: anytype) error{Rejected} {
    @memset(diag, 0);
    var w: std.Io.Writer = .fixed(diag[0..255]);
    w.print(fmt, a) catch {};
    return error.Rejected;
}

/// Reads the cache at `path`. A missing file is `error.FileNotFound`, with
/// no log line. Anything else wrong with it logs one line naming the file
/// and returns `error.Rejected`.
pub fn read(a: Allocator, io: std.Io, path: OsPath) ReadError!Cache {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path.bytes, a, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var diag: [256]u8 = undefined;
            reject(&diag, "could not be read ({s})", .{@errorName(err)}) catch {};
            logRejected(path, &diag);
            return error.Rejected;
        },
    };
    defer a.free(bytes);
    var diag: [256]u8 = undefined;
    const c = parse(a, bytes, &diag) catch |err| switch (err) {
        error.Rejected => {
            logRejected(path, &diag);
            return error.Rejected;
        },
        else => |e| return e,
    };
    if (c.dropped_defaults != 0) logDropped(path, c.dropped_defaults);
    return c;
}

/// `path` with every byte that is not printable ASCII replaced by `?`, so a
/// file name cannot add lines to the log. Writes into `buf`.
fn printable(buf: []u8, path: []const u8) []const u8 {
    const n = @min(path.len, buf.len);
    for (path[0..n], buf[0..n]) |c, *o| o.* = if (c >= 0x20 and c <= 0x7e) c else '?';
    return buf[0..n];
}

/// One warning line. `fmt` takes the cleaned path, then `extra`. Only the
/// path and fixed text (and numbers we computed) appear in it, never bytes
/// read from the file.
fn logLine(comptime fmt: []const u8, path: OsPath, extra: anytype) void {
    var pbuf: [512]u8 = undefined;
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, .{printable(&pbuf, path.bytes)} ++ extra) catch buf[0..0];
    buf[line.len] = 0;
    godot.raw.printWarning(@ptrCast(&buf), "ziggurat descriptor cache", "", 0, 0);
}

fn logRejected(path: OsPath, diag: *const [256]u8) void {
    _ = rejections_logged.fetchAdd(1, .acq_rel);
    logLine("Ziggurat ignored the descriptor cache {s}: the file {s}.", path, .{std.mem.sliceTo(diag, 0)});
}

fn logDropped(path: OsPath, n: u32) void {
    _ = drops_logged.fetchAdd(1, .acq_rel);
    logLine("Ziggurat dropped default values from the descriptor cache {s}: {d} value(s) did not fit the type of their property.", path, .{n});
}

// ------------------------------------------------------------- tests

const testing = std.testing;

const Stub = struct {
    var field_dummy: u8 = 0;
    fn create(_: *anyopaque, _: u32) callconv(.c) ?*anyopaque {
        return null;
    }
    fn destroy(_: *anyopaque) callconv(.c) void {}
    fn call(_: *anyopaque, _: u32, _: ?[*]const *const anyopaque, _: i64, _: *anyopaque, _: *abi.CallError) callconv(.c) void {}
    fn get(_: *anyopaque, _: u32, _: *anyopaque) callconv(.c) u8 {
        return 0;
    }
    fn set(_: *anyopaque, _: u32, _: *const anyopaque) callconv(.c) u8 {
        return 0;
    }
    fn getDefault(_: u32, _: *anyopaque) callconv(.c) u8 {
        return 0;
    }
    fn notification(_: *anyopaque, _: i32, _: u8) callconv(.c) void {}

    const ok_text = "ok";
    fn str(s: []const u8) abi.Str {
        return .{ .ptr = s.ptr, .len = @intCast(s.len) };
    }

    const props_arr = [_]abi.PropertyDesc{
        .{ .name = str("Group"), .field_index = abi.no_field, .variant_type = 0, .class_name = str(""), .hint = 0, .hint_string = str(""), .usage = abi.usage_group },
        .{ .name = str("speed"), .field_index = 0, .variant_type = 3, .class_name = str(""), .hint = 1, .hint_string = str("0,10"), .usage = 4102 },
    };
    const arg_arr = [_]abi.ArgDesc{.{ .name = str("amount"), .variant_type = 2, .class_name = str("") }};
    const method_arr = [_]abi.MethodDesc{
        .{ .name = str("_process"), .args = &arg_arr, .arg_count = 1, .ret = .{ .name = str(""), .variant_type = 0, .class_name = str("") }, .flags = abi.method_flag_virtual },
        .{ .name = str("go"), .args = &arg_arr, .arg_count = 0, .ret = .{ .name = str(""), .variant_type = 0, .class_name = str("") }, .flags = 0 },
    };
    const signal_arr = [_]abi.SignalDesc{.{ .name = str("hit"), .args = &arg_arr, .arg_count = 1 }};
    const field_arr = [_]abi.FieldDesc{};

    const script: abi.ScriptDesc = .{
        .path = str("a/b.zig"),
        .class_name = str("Bee"),
        .base_class = str("Node2D"),
        .flags = abi.script_flag_tool,
        .layout_hash = std.math.maxInt(u64),
        .instance_size = 8,
        .instance_align = 8,
        .defaults = &field_dummy,
        .fields = &field_arr,
        .field_count = 0,
        .properties = &props_arr,
        .property_count = 2,
        .methods = &method_arr,
        .method_count = 2,
        .signals = &signal_arr,
        .signal_count = 1,
        .create = &create,
        .destroy = &destroy,
        .call = &call,
        .get = &get,
        .set = &set,
        .get_default = &getDefault,
        .notification = &notification,
        .migrate = null,
    };
};

const StubDefaults = struct {
    pub fn value(_: StubDefaults, _: Allocator, _: *const abi.ScriptDesc, i: u32) Allocator.Error!Default {
        if (i == 1) return .{ .float = 300.5 };
        return .absent;
    }
};

test "serialize then parse keeps every field" {
    const bytes = try serialize(testing.allocator, 7, &.{Stub.script}, StubDefaults{});
    defer testing.allocator.free(bytes);
    var diag: [256]u8 = undefined;
    var c = try parse(testing.allocator, bytes, &diag);
    defer c.deinit();
    try testing.expectEqual(@as(u32, 7), c.generation());
    try testing.expectEqual(@as(usize, 1), c.scripts().len);
    const s = c.find("a/b.zig").?;
    try testing.expect(c.find("nope.zig") == null);
    try testing.expectEqualStrings("Bee", s.class_name);
    try testing.expectEqualStrings("Node2D", s.base_class);
    try testing.expectEqual(abi.script_flag_tool, s.flags.v);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), s.layoutHash());
    try testing.expectEqual(@as(usize, 2), s.properties.len);
    try testing.expectEqual(abi.usage_group, s.properties[0].usage.v);
    try testing.expect(s.properties[0].default == .absent);
    try testing.expectEqual(@as(f64, 300.5), s.properties[1].default.float);
    try testing.expectEqualStrings("0,10", s.properties[1].hint_string);
    try testing.expectEqual(@as(u32, 4102), s.properties[1].usage.v);
    try testing.expectEqual(@as(usize, 2), s.methods.len);
    try testing.expectEqualStrings("_process", s.methods[0].name);
    try testing.expectEqual(abi.method_flag_virtual, s.methods[0].flags.v);
    try testing.expectEqual(@as(usize, 1), s.methods[0].args.len);
    try testing.expectEqualStrings("amount", s.methods[0].args[0].name);
    try testing.expectEqual(@as(usize, 0), s.methods[1].args.len);
    try testing.expectEqual(@as(usize, 1), s.signals.len);
    try testing.expectEqual(@as(u32, 2), s.signals[0].args[0].type.v);
}

test "parse rejects unknown versions, truncation and wrong types" {
    const good = try serialize(testing.allocator, 1, &.{Stub.script}, StubDefaults{});
    defer testing.allocator.free(good);
    var diag: [256]u8 = undefined;

    // Truncated at every length: never a panic, always rejected.
    const whole = std.mem.trimEnd(u8, good, "\n");
    var cut_at: usize = 0;
    while (cut_at < whole.len) : (cut_at += 1) {
        try testing.expectError(error.Rejected, parse(testing.allocator, good[0..cut_at], &diag));
    }

    const cases = [_]struct { name: []const u8, text: []const u8, reason: []const u8 }{
        .{ .name = "empty", .text = "", .reason = "version" },
        .{ .name = "not json", .text = "hello", .reason = "version" },
        .{ .name = "an array", .text = "[1,2]", .reason = "version" },
        .{ .name = "no version", .text = "{\"generation\":1,\"scripts\":[]}", .reason = "version" },
        .{ .name = "version 2", .text = "{\"version\":2,\"generation\":1,\"scripts\":[]}", .reason = "version 2" },
        .{ .name = "version as numeric string", .text = "{\"version\":\"1\",\"generation\":1,\"scripts\":[]}", .reason = "version" },
        .{ .name = "usage as numeric string", .text = "{\"version\":1,\"generation\":1,\"scripts\":[{\"path\":\"a\",\"layout_hash\":\"5\",\"properties\":[{\"name\":\"x\",\"type\":2,\"usage\":\"4102\"}]}]}", .reason = "expected shape" },
        .{ .name = "generation as numeric string", .text = "{\"version\":1,\"generation\":\"1\",\"scripts\":[]}", .reason = "expected shape" },
        .{ .name = "fractional type", .text = "{\"version\":1,\"generation\":1,\"scripts\":[{\"path\":\"a\",\"layout_hash\":\"5\",\"properties\":[{\"name\":\"x\",\"type\":2.5,\"usage\":1}]}]}", .reason = "expected shape" },
        .{ .name = "version word", .text = "{\"version\":\"one\",\"generation\":1,\"scripts\":[]}", .reason = "version" },
        .{ .name = "negative version", .text = "{\"version\":-1}", .reason = "version" },
        .{ .name = "scripts not an array", .text = "{\"version\":1,\"generation\":1,\"scripts\":5}", .reason = "expected shape" },
        .{ .name = "script not an object", .text = "{\"version\":1,\"generation\":1,\"scripts\":[1]}", .reason = "expected shape" },
        .{ .name = "no generation", .text = "{\"version\":1,\"scripts\":[]}", .reason = "expected shape" },
        .{ .name = "bad hash", .text = "{\"version\":1,\"generation\":1,\"scripts\":[{\"path\":\"a.zig\",\"layout_hash\":\"x1\"}]}", .reason = "layout hash" },
        .{ .name = "hash as number", .text = "{\"version\":1,\"generation\":1,\"scripts\":[{\"path\":\"a.zig\",\"layout_hash\":5}]}", .reason = "expected shape" },
        .{ .name = "empty path", .text = "{\"version\":1,\"generation\":1,\"scripts\":[{\"path\":\"\",\"layout_hash\":\"5\"}]}", .reason = "without a path" },
        .{ .name = "type too big", .text = "{\"version\":1,\"generation\":1,\"scripts\":[{\"path\":\"a\",\"layout_hash\":\"5\",\"properties\":[{\"name\":\"x\",\"type\":99999999999,\"usage\":1}]}]}", .reason = "expected shape" },
    };
    for (cases) |c| {
        testing.expectError(error.Rejected, parse(testing.allocator, c.text, &diag)) catch |err| {
            std.debug.print("case '{s}' was not rejected\n", .{c.name});
            return err;
        };
        const reason = std.mem.sliceTo(&diag, 0);
        testing.expect(std.mem.indexOf(u8, reason, c.reason) != null) catch |err| {
            std.debug.print("case '{s}': reason '{s}' lacks '{s}'\n", .{ c.name, reason, c.reason });
            return err;
        };
    }
}

test "parse survives deep nesting" {
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendSlice(testing.allocator, "{\"version\":1,\"generation\":1,\"x\":");
    try deep.appendNTimes(testing.allocator, '[', 100_000);
    var diag: [256]u8 = undefined;
    try testing.expectError(error.Rejected, parse(testing.allocator, deep.items, &diag));
}

test "unknown fields are ignored" {
    var diag: [256]u8 = undefined;
    var c = try parse(testing.allocator, "{\"version\":1,\"generation\":3,\"extra\":{\"a\":[1,2]},\"scripts\":[]}", &diag);
    defer c.deinit();
    try testing.expectEqual(@as(u32, 3), c.generation());
    try testing.expectEqual(@as(usize, 0), c.scripts().len);
}

test "read of a missing file is FileNotFound and logs nothing" {
    const before = rejections_logged.load(.acquire);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "none.json" });
    defer testing.allocator.free(file);
    try testing.expectError(error.FileNotFound, read(testing.allocator, testing.io, .fromTrusted(file)));
    try testing.expectEqual(before, rejections_logged.load(.acquire));
}

/// A one-property cache file whose property has type `type_id` and the raw
/// JSON default `raw`.
fn withDefault(a: Allocator, type_id: u32, raw: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"version\":1,\"generation\":1,\"scripts\":[{{\"path\":\"a.zig\",\"layout_hash\":\"5\",\"properties\":[{{\"name\":\"x\",\"type\":{d},\"usage\":4102,\"default\":{s}}}]}}]}}", .{ type_id, raw });
}

test "a default that does not fit its type is dropped, the rest of the file stays" {
    var diag: [256]u8 = undefined;
    const attacks = [_]struct { type_id: u32, raw: []const u8 }{
        // Text that Godot's own parser would run as a constructor.
        .{ .type_id = 2, .raw = "\"Object ;c\\n(Node, \\\"name\\\": \\\"pwn\\\")\"" },
        .{ .type_id = 3, .raw = "\"Object(Node)\"" },
        .{ .type_id = 2, .raw = "\"5\"" }, // a number as text
        .{ .type_id = 2, .raw = "5.5" },
        .{ .type_id = 5, .raw = "[1]" },
        .{ .type_id = 5, .raw = "[1, 2, 3]" },
        .{ .type_id = 6, .raw = "[1.5, 2]" },
        .{ .type_id = 4, .raw = "7" },
        .{ .type_id = 1, .raw = "1" },
        .{ .type_id = 0, .raw = "1" },
        .{ .type_id = 2, .raw = "null" },
        .{ .type_id = 24, .raw = "5" },
        .{ .type_id = 24, .raw = "[1, 2]" },
    };
    for (attacks) |at| {
        const text = try withDefault(testing.allocator, at.type_id, at.raw);
        defer testing.allocator.free(text);
        var c = parse(testing.allocator, text, &diag) catch |err| {
            std.debug.print("type {d} default {s}: {s}\n", .{ at.type_id, at.raw, @errorName(err) });
            return err;
        };
        defer c.deinit();
        try testing.expectEqual(@as(u32, 1), c.dropped_defaults);
        try testing.expect(c.scripts()[0].properties[0].default == .absent);
    }
}

test "a string default is plain text, whatever it says" {
    var diag: [256]u8 = undefined;
    const text = try withDefault(testing.allocator, 4, "\"Object ;c\\n(Node)\"");
    defer testing.allocator.free(text);
    var c = parse(testing.allocator, text, &diag) catch |err| return err;
    defer c.deinit();
    try testing.expectEqual(@as(u32, 0), c.dropped_defaults);
    try testing.expectEqualStrings("Object ;c\n(Node)", c.scripts()[0].properties[0].default.text);
}

test "a default with deep nesting rejects the file without recursion" {
    var diag: [256]u8 = undefined;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    try raw.appendNTimes(testing.allocator, '[', 200_000);
    const text = try withDefault(testing.allocator, 5, raw.items);
    defer testing.allocator.free(text);
    try testing.expectError(error.Rejected, parse(testing.allocator, text, &diag));
    // Closed brackets too.
    try raw.appendNTimes(testing.allocator, ']', 200_000);
    const text2 = try withDefault(testing.allocator, 5, raw.items);
    defer testing.allocator.free(text2);
    try testing.expectError(error.Rejected, parse(testing.allocator, text2, &diag));
}

test "the printable path hides control bytes" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a?b?c?", printable(&buf, "a\nb\x00c\xff"));
}
