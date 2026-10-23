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
//!     { "version": 2, "generation": <n>, "scripts": [ {
//!         "path", "class_name", "base_class", "flags",
//!         "layout_hash": "<decimal>",
//!         "properties": [ { "name", "class_name", "type", "hint",
//!                           "hint_string", "usage", "default"? } ],
//!         "methods": [ { "name", "flags", "ret": <arg>, "args": [<arg>] } ],
//!         "signals": [ { "name", "args": [<arg>] } ] } ] }
//!
//! with `<arg>` = `{ "name", "class_name", "type" }`. `default` is the
//! property's default value as typed JSON (`default_value.zig`; never text
//! for `str_to_var`); group entries and properties without a default have
//! none. `layout_hash` is `ziggurat_abi.layoutHash` of the descriptor, as a
//! decimal string because a JSON number cannot hold every u64 exactly.
//! Version 2 came with ABI version 2, which changed how the layout hash is
//! made; a version 1 file is ignored with the usual one log line. Method
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
const Dictionary = godot.builtin.Dictionary;
const String = godot.builtin.String;
const ProjectSettings = godot.class.ProjectSettings;
const Variant = godot.builtin.Variant;
const OsPath = platform.path.OsPath;
const Default = default_value.Default;

/// The `version` this host writes and reads.
pub const format_version: u32 = 2;

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
        for (0..s.methods.len) |i| {
            var d = s.methodInfo(@intCast(i));
            defer d.deinit();
            props.pushDict(&arr, d);
        }
        return arr;
    }

    /// As `props.methodInfo`: method `i`, which must be below `methods.len`.
    pub fn methodInfo(s: *const Script, i: u32) Dictionary {
        const m = s.methods[i];
        var args = argArray(m.args);
        defer args.deinit();
        return props.methodDict(m.name, args, props.godotMethodFlags(m.flags.v), m.ret.info());
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

/// A property whose module default differs from its table default.
pub const DefaultMismatch = struct { script: []const u8, property: []const u8 };

/// The first property of `scripts` whose default from `defaults` (with
/// `value(a, desc, prop_index) !Default`; `GodotDefaults` calls the module's
/// `get_default`) differs from the default `snap` decoded from the same
/// build's defaults image by field offsets, with no module code. The two
/// are independent: `get_default` is code, the image and offsets are data.
/// A difference means the compiler kept old code (an incremental build
/// that went stale). Only properties whose snapshot default has a stored
/// form are compared; scripts missing from `snap` are skipped. Plain values
/// come first, so a stale `get_default` is caught on them before it reads
/// a String or object default (which it could crash on). Allocates in `a`
/// (an arena).
pub fn defaultMismatch(a: Allocator, scripts: []const abi.ScriptDesc, snap: *const abi.snapshot.Snapshot, defaults: anytype) Allocator.Error!?DefaultMismatch {
    for ([_]bool{ true, false }) |plain_pass| {
        for (scripts) |*d| {
            const sn = snap.find(props.text(d.path)) orelse continue;
            if (sn.properties.len != d.property_count) continue;
            for (sn.properties, 0..) |p, i| {
                if (!p.has_field) continue;
                const plain = switch (p.default) {
                    .none => continue,
                    .string_empty, .object_null => false,
                    else => true,
                };
                if (plain != plain_pass) continue;
                const want = try snapshotDefault(a, p.variant_type, p.default);
                if (want == .absent) continue;
                const got = try defaults.value(a, d, @intCast(i));
                if (!sameDefault(want, got)) return .{ .script = sn.path, .property = p.name };
            }
        }
    }
    return null;
}

/// Equal tag and value; floats compare bit for bit.
fn sameDefault(x: Default, y: Default) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .absent, .null_ => true,
        .boolean => |b| b == y.boolean,
        .int => |i| i == y.int,
        .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(y.float)),
        .text => |t| std.mem.eql(u8, t, y.text),
        .nums => |ns| ns.len == y.nums.len and std.mem.eql(u64, @ptrCast(ns), @ptrCast(y.nums)),
    };
}

/// The cache file's bytes for `scripts` as generation `gen`. `defaults` has
/// `value(a, desc, prop_index) !Default` (allocated with `a`).
pub fn serialize(a: Allocator, gen: u32, scripts: []const abi.ScriptDesc, defaults: anytype) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try arena.alloc(Script, scripts.len);
    for (scripts, out) |*d, *o| o.* = try scriptJson(arena, d, defaults);
    return stringify(a, gen, out);
}

fn stringify(a: Allocator, gen: u32, scripts: []const Script) ![]u8 {
    const file: FileJson = .{ .version = .{ .v = format_version }, .generation = .{ .v = gen }, .scripts = scripts };
    var w: std.Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, &w.writer);
    try w.writer.writeByte('\n');
    return w.toOwnedSlice();
}

/// The cache file's bytes for `snap` as generation `gen`, made without the
/// module: for the same build it equals what `serialize` makes from the
/// loaded generation. Pure Zig; no Godot call.
pub fn fromSnapshot(a: Allocator, gen: u32, snap: *const abi.snapshot.Snapshot) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const out = try arena.alloc(Script, snap.scripts.len);
    for (snap.scripts, out) |*d, *o| o.* = try snapshotScriptJson(arena, d);
    return stringify(a, gen, out);
}

fn snapArgJsons(arena: Allocator, list: []const abi.snapshot.ArgSnap) ![]ArgJson {
    const out = try arena.alloc(ArgJson, list.len);
    for (list, out) |d, *o| o.* = snapArgJson(d);
    return out;
}

fn snapArgJson(d: abi.snapshot.ArgSnap) ArgJson {
    return .{ .name = d.name, .class_name = d.class_name, .type = .{ .v = d.variant_type } };
}

fn snapshotScriptJson(arena: Allocator, d: *const abi.snapshot.ScriptSnap) !Script {
    const ps = try arena.alloc(PropertyJson, d.properties.len);
    for (d.properties, ps) |p, *o| {
        o.* = .{
            .name = p.name,
            .class_name = p.class_name,
            .type = .{ .v = p.variant_type },
            .hint = .{ .v = p.hint },
            .hint_string = p.hint_string,
            .usage = .{ .v = p.usage },
            .default = try snapshotDefault(arena, p.variant_type, p.default),
        };
    }
    const ms = try arena.alloc(MethodJson, d.methods.len);
    for (d.methods, ms) |m, *o| {
        o.* = .{ .name = m.name, .flags = .{ .v = m.flags }, .ret = snapArgJson(m.ret), .args = try snapArgJsons(arena, m.args) };
    }
    const ss = try arena.alloc(SignalJson, d.signals.len);
    for (d.signals, ss) |g, *o| o.* = .{ .name = g.name, .args = try snapArgJsons(arena, g.args) };
    return .{
        .path = d.path,
        .class_name = d.class_name,
        .base_class = d.base_class,
        .flags = .{ .v = d.flags },
        .layout_hash = try std.fmt.allocPrint(arena, "{d}", .{d.layout_hash}),
        .properties = ps,
        .methods = ms,
        .signals = ss,
    };
}

/// The typed default for a property of Variant type `type_id` whose snapshot
/// default is `d`: what `default_value.fromVariant` makes from the module's
/// value, for every kind the snapshot decodes; `.absent` when the value has
/// no stored form for that type.
fn snapshotDefault(arena: Allocator, type_id: u32, d: abi.snapshot.Default) !Default {
    const out: Default = switch (d) {
        .none => .absent,
        .boolean => |b| .{ .boolean = b },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .floats => |f| blk: {
            const nums = try arena.alloc(f64, f.len);
            for (f.slice(), nums) |x, *o| o.* = x;
            break :blk .{ .nums = nums };
        },
        .ints => |f| blk: {
            const nums = try arena.alloc(f64, f.len);
            for (f.slice(), nums) |x, *o| o.* = @floatFromInt(x);
            break :blk .{ .nums = nums };
        },
        .string_empty => .{ .text = "" },
        .object_null => .null_,
    };
    // A float keeps NaN and infinity (written as text); a vector must be
    // finite, as `fromVariant` has it.
    switch (out) {
        .float => return if (type_id == default_value.t_float) out else .absent,
        .nums => |ns| for (ns) |x| if (!std.math.isFinite(x)) return .absent,
        else => {},
    }
    return if (default_value.fits(type_id, out)) out else .absent;
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
        .layout_hash = try std.fmt.allocPrint(arena, "{d}", .{abi.layoutHash(d)}),
        .properties = ps,
        .methods = ms,
        .signals = ss,
    };
}

/// Writes the cache of `snap` as generation `gen` to `path` (atomically;
/// missing folders are created). Needs no Godot call, so any thread may do it.
pub fn writeSnapshot(a: Allocator, io: std.Io, path: OsPath, gen: u32, snap: *const abi.snapshot.Snapshot) !void {
    const bytes = try fromSnapshot(a, gen, snap);
    defer a.free(bytes);
    try platform.atomic_file.write(io, path, bytes);
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

/// `parse` with every allocation through `counter`, so `counter.live` is
/// then exactly what the parsed cache holds (spec section 6: the editor's
/// memory figures). `counter` must not move while the cache lives:
/// `Cache.deinit` frees through it.
pub fn parseCounted(counter: *platform.counting_allocator.CountingAllocator, bytes: []const u8, diag: *[256]u8) ReadError!Cache {
    return parse(counter.allocator(), bytes, diag);
}

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

/// The cache file's path inside the project data folder.
pub const project_rel = "ziggurat/descriptors.json";

/// The absolute path of the open project's cache file, written into `buf`;
/// null when it does not fit. The project data folder is `.godot`, or
/// `godot` when `application/config/use_hidden_project_data_directory` is
/// off (Godot's `ProjectSettings::get_project_data_dir_name`,
/// core/config/project_settings.cpp:885-886). Main thread.
pub fn projectPath(buf: []u8) ?[]const u8 {
    return dataPath(buf, project_rel);
}

/// The absolute path of `rel` inside the open project's data folder
/// (`.godot`, see `projectPath`), written into `buf`; null when it does not
/// fit. Main thread.
pub fn dataPath(buf: []u8, comptime rel: []const u8) ?[]const u8 {
    var setting = String.fromLatin1("application/config/use_hidden_project_data_directory");
    defer setting.deinit();
    const v = ProjectSettings.getSetting(setting, .{ .default_value = Variant.init(bool, true) });
    defer v.deinit();
    const hidden = v.as(bool) orelse true;
    var res = String.fromLatin1(if (hidden) "res://.godot/" ++ rel else "res://godot/" ++ rel);
    defer res.deinit();
    var abs = ProjectSettings.globalizePath(res);
    defer abs.deinit();
    const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(abs.constPtr(), null, 0)));
    if (n == 0 or n > buf.len) return null;
    _ = godot.raw.stringToUtf8Chars(abs.constPtr(), buf.ptr, @intCast(n));
    return buf[0..n];
}

/// Reads the cache at `path`. A missing file is `error.FileNotFound`, with
/// no log line. Anything else wrong with it logs one line naming the file
/// and returns `error.Rejected`.
pub fn read(a: Allocator, io: std.Io, path: OsPath) ReadError!Cache {
    const bytes = readBytes(a, io, path) catch |err| switch (err) {
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

/// The bytes of the cache file at `path` (at most `max_file_bytes`). The
/// project may hold anything at that path, so the open never blocks (a
/// FIFO or device is `error.NotRegular`) and only a regular file is read.
fn readBytes(a: Allocator, io: std.Io, path: OsPath) ![]u8 {
    const file = try platform.safe_open.openRegular(io, path.bytes, .{});
    defer file.close(io);
    const st = file.stat(io) catch return error.Unreadable;
    if (st.size > max_file_bytes) return error.FileTooBig;
    const buf = try a.alloc(u8, @intCast(st.size));
    errdefer a.free(buf);
    const n = file.readPositionalAll(io, buf, 0) catch return error.Unreadable;
    if (n != buf.len) return error.Unreadable;
    return buf;
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
        .create_blank = &create,
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
    try testing.expectEqual(abi.layoutHash(&Stub.script), s.layoutHash());
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

test "a snapshot makes the same file as the module's defaults" {
    var image: [8]u8 = @splat(0);
    std.mem.writeInt(u32, image[0..4], @bitCast(@as(f32, 300.5)), .little);
    const fields = [_]abi.FieldDesc{.{ .name = Stub.str("speed"), .type_name = Stub.str("f32"), .shape = 0, .offset = 0, .size = 4, .@"align" = 4, .value_kind = @backingInt(abi.ValueKind.float), .bits = 0 }};
    var d = Stub.script;
    d.defaults = &image;
    d.fields = &fields;
    d.field_count = 1;
    const table: abi.Table = .{ .magic = abi.magic, .abi_version = abi.abi_version, .size = @sizeOf(abi.Table), .layout_stamp = 0, .sdk_version = Stub.str("1"), .build_id = Stub.str("0123456789abcdef"), .scripts = @ptrCast(&d), .script_count = 1 };

    const live = try serialize(testing.allocator, 3, &.{d}, StubDefaults{});
    defer testing.allocator.free(live);
    const snap = try abi.snapshot.take(testing.allocator, &table);
    defer snap.deinit(testing.allocator);
    const from_snap = try fromSnapshot(testing.allocator, 3, &snap);
    defer testing.allocator.free(from_snap);
    try testing.expectEqualStrings(live, from_snap);
}

/// Stub.script with two fields: `note` (a String, property 1) and `speed`
/// (f32 300.5, property 2), and its table.
const MismatchFixture = struct {
    image: [8]u8 = @splat(0),
    props: [3]abi.PropertyDesc = .{
        Stub.props_arr[0],
        .{ .name = Stub.str("note"), .field_index = 0, .variant_type = default_value.t_string, .class_name = Stub.str(""), .hint = 0, .hint_string = Stub.str(""), .usage = 4102 },
        .{ .name = Stub.str("speed"), .field_index = 1, .variant_type = default_value.t_float, .class_name = Stub.str(""), .hint = 0, .hint_string = Stub.str(""), .usage = 4102 },
    },
    fields: [2]abi.FieldDesc = .{
        .{ .name = Stub.str("note"), .type_name = Stub.str("String"), .shape = 0, .offset = 0, .size = 0, .@"align" = 1, .value_kind = @backingInt(abi.ValueKind.string_empty), .bits = 0 },
        .{ .name = Stub.str("speed"), .type_name = Stub.str("f32"), .shape = 0, .offset = 0, .size = 4, .@"align" = 4, .value_kind = @backingInt(abi.ValueKind.float), .bits = 0 },
    },
    desc: abi.ScriptDesc = Stub.script,

    fn snapshot(f: *MismatchFixture) !abi.snapshot.Snapshot {
        std.mem.writeInt(u32, f.image[0..4], @bitCast(@as(f32, 300.5)), .little);
        f.desc.defaults = &f.image;
        f.desc.fields = &f.fields;
        f.desc.field_count = 2;
        f.desc.properties = &f.props;
        f.desc.property_count = 3;
        const table: abi.Table = .{ .magic = abi.magic, .abi_version = abi.abi_version, .size = @sizeOf(abi.Table), .layout_stamp = 0, .sdk_version = Stub.str("1"), .build_id = Stub.str("0123456789abcdef"), .scripts = @ptrCast(&f.desc), .script_count = 1 };
        return abi.snapshot.take(testing.allocator, &table);
    }
};

/// Module defaults for MismatchFixture: `speed` is `speed`; records the
/// order in which properties are asked for.
const FakeDefaults = struct {
    speed: f64,
    asked: *std.ArrayList(u32),

    pub fn value(self: FakeDefaults, a: Allocator, _: *const abi.ScriptDesc, i: u32) Allocator.Error!Default {
        try self.asked.append(a, i);
        return switch (i) {
            1 => .{ .text = "" },
            2 => .{ .float = self.speed },
            else => .absent,
        };
    }
};

test "defaultMismatch: equal defaults pass, a stale value is named" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: MismatchFixture = .{};
    const snap = try f.snapshot();
    defer snap.deinit(testing.allocator);

    var asked: std.ArrayList(u32) = .empty;
    try testing.expect(try defaultMismatch(a, &.{f.desc}, &snap, FakeDefaults{ .speed = 300.5, .asked = &asked }) == null);
    // The plain value first, then the String.
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, asked.items);

    // A stale `get_default` that reads another field's bytes: found on the
    // plain value, and the String default is never asked for.
    asked.clearRetainingCapacity();
    const m = (try defaultMismatch(a, &.{f.desc}, &snap, FakeDefaults{ .speed = 0, .asked = &asked })).?;
    try testing.expectEqualStrings("a/b.zig", m.script);
    try testing.expectEqualStrings("speed", m.property);
    try testing.expectEqualSlices(u32, &.{2}, asked.items);

    // A script the snapshot does not know is skipped.
    var other = f.desc;
    other.path = Stub.str("other.zig");
    asked.clearRetainingCapacity();
    try testing.expect(try defaultMismatch(a, &.{other}, &snap, FakeDefaults{ .speed = 0, .asked = &asked }) == null);
    try testing.expectEqual(@as(usize, 0), asked.items.len);
}

test "sameDefault compares floats bit for bit and texts by bytes" {
    try testing.expect(sameDefault(.{ .float = std.math.nan(f64) }, .{ .float = std.math.nan(f64) }));
    try testing.expect(!sameDefault(.{ .float = 0.0 }, .{ .float = -0.0 }));
    try testing.expect(!sameDefault(.{ .int = 1 }, .{ .float = 1 }));
    try testing.expect(sameDefault(.{ .text = "ab" }, .{ .text = "ab" }));
    try testing.expect(!sameDefault(.{ .nums = &.{ 1, 2 } }, .{ .nums = &.{ 1, 3 } }));
    try testing.expect(sameDefault(.null_, .null_));
}

test "snapshot defaults keep only what fits the property type" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var fl: abi.snapshot.Floats = .{ .len = 2 };
    fl.v[0] = 1;
    fl.v[1] = 2;
    var bad = fl;
    bad.v[0] = std.math.inf(f32);
    const ints: abi.snapshot.Ints = .{ .v = .{ -1, 2, 0, 0 }, .len = 2 };
    try testing.expectEqualSlices(f64, &.{ 1, 2 }, (try snapshotDefault(a, 5, .{ .floats = fl })).nums);
    // Vector2 is type 5, Vector2i type 6; a Vector3 (type 9) needs 3 numbers.
    try testing.expect((try snapshotDefault(a, 9, .{ .floats = fl })) == .absent);
    try testing.expect((try snapshotDefault(a, 5, .{ .floats = bad })) == .absent);
    try testing.expectEqualSlices(f64, &.{ -1, 2 }, (try snapshotDefault(a, 6, .{ .ints = ints })).nums);
    try testing.expectEqual(@as(i64, 4), (try snapshotDefault(a, 2, .{ .int = 4 })).int);
    try testing.expect((try snapshotDefault(a, 1, .{ .int = 4 })) == .absent);
    try testing.expect(std.math.isNan((try snapshotDefault(a, 3, .{ .float = std.math.nan(f64) })).float));
    try testing.expect((try snapshotDefault(a, 2, .{ .float = 1 })) == .absent);
    try testing.expectEqualStrings("", (try snapshotDefault(a, 4, .string_empty)).text);
    try testing.expect((try snapshotDefault(a, 21, .string_empty)).text.len == 0);
    try testing.expect((try snapshotDefault(a, 2, .string_empty)) == .absent);
    try testing.expect((try snapshotDefault(a, 24, .object_null)) == .null_);
    try testing.expect((try snapshotDefault(a, 24, .none)) == .absent);
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
        .{ .name = "version 1", .text = "{\"version\":1,\"generation\":1,\"scripts\":[]}", .reason = "has version 1, but this host reads version 2" },
        .{ .name = "version 3", .text = "{\"version\":3,\"generation\":1,\"scripts\":[]}", .reason = "version 3" },
        .{ .name = "version as numeric string", .text = "{\"version\":\"1\",\"generation\":1,\"scripts\":[]}", .reason = "version" },
        .{ .name = "usage as numeric string", .text = "{\"version\":2,\"generation\":1,\"scripts\":[{\"path\":\"a\",\"layout_hash\":\"5\",\"properties\":[{\"name\":\"x\",\"type\":2,\"usage\":\"4102\"}]}]}", .reason = "expected shape" },
        .{ .name = "generation as numeric string", .text = "{\"version\":2,\"generation\":\"1\",\"scripts\":[]}", .reason = "expected shape" },
        .{ .name = "fractional type", .text = "{\"version\":2,\"generation\":1,\"scripts\":[{\"path\":\"a\",\"layout_hash\":\"5\",\"properties\":[{\"name\":\"x\",\"type\":2.5,\"usage\":1}]}]}", .reason = "expected shape" },
        .{ .name = "version word", .text = "{\"version\":\"one\",\"generation\":1,\"scripts\":[]}", .reason = "version" },
        .{ .name = "negative version", .text = "{\"version\":-1}", .reason = "version" },
        .{ .name = "scripts not an array", .text = "{\"version\":2,\"generation\":1,\"scripts\":5}", .reason = "expected shape" },
        .{ .name = "script not an object", .text = "{\"version\":2,\"generation\":1,\"scripts\":[1]}", .reason = "expected shape" },
        .{ .name = "no generation", .text = "{\"version\":2,\"scripts\":[]}", .reason = "expected shape" },
        .{ .name = "bad hash", .text = "{\"version\":2,\"generation\":1,\"scripts\":[{\"path\":\"a.zig\",\"layout_hash\":\"x1\"}]}", .reason = "layout hash" },
        .{ .name = "hash as number", .text = "{\"version\":2,\"generation\":1,\"scripts\":[{\"path\":\"a.zig\",\"layout_hash\":5}]}", .reason = "expected shape" },
        .{ .name = "empty path", .text = "{\"version\":2,\"generation\":1,\"scripts\":[{\"path\":\"\",\"layout_hash\":\"5\"}]}", .reason = "without a path" },
        .{ .name = "type too big", .text = "{\"version\":2,\"generation\":1,\"scripts\":[{\"path\":\"a\",\"layout_hash\":\"5\",\"properties\":[{\"name\":\"x\",\"type\":99999999999,\"usage\":1}]}]}", .reason = "expected shape" },
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
    try deep.appendSlice(testing.allocator, "{\"version\":2,\"generation\":1,\"x\":");
    try deep.appendNTimes(testing.allocator, '[', 100_000);
    var diag: [256]u8 = undefined;
    try testing.expectError(error.Rejected, parse(testing.allocator, deep.items, &diag));
}

test "unknown fields are ignored" {
    var diag: [256]u8 = undefined;
    var c = try parse(testing.allocator, "{\"version\":2,\"generation\":3,\"extra\":{\"a\":[1,2]},\"scripts\":[]}", &diag);
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

test "a FIFO in place of the cache file is refused without blocking" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const file = try std.fs.path.join(testing.allocator, &.{ root, "descriptors.json" });
    defer testing.allocator.free(file);
    const r = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "mkfifo", file } });
    defer testing.allocator.free(r.stdout);
    defer testing.allocator.free(r.stderr);
    try testing.expect(r.term.success());
    // A FIFO without a writer: a blocking open would wait forever.
    try testing.expectError(error.NotRegular, readBytes(testing.allocator, testing.io, .fromTrusted(file)));
}

/// A one-property cache file whose property has type `type_id` and the raw
/// JSON default `raw`.
fn withDefault(a: Allocator, type_id: u32, raw: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"version\":2,\"generation\":1,\"scripts\":[{{\"path\":\"a.zig\",\"layout_hash\":\"5\",\"properties\":[{{\"name\":\"x\",\"type\":{d},\"usage\":4102,\"default\":{s}}}]}}]}}", .{ type_id, raw });
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

test "snapshot bytes are exact" {
    // The shape Stage 4 measured (research log, 300 scripts of 31
    // properties and 30 methods): the parsed cache held 7,801,740 bytes for
    // a 3,651,083-byte file. The figure the editor keeps must be the parsed
    // size within 1 %, not the file length (about 47 % of it).
    const measured_parse_bytes: u64 = 7_801_740;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const n_scripts = 300;
    const scripts = try ar.alloc(abi.snapshot.ScriptSnap, n_scripts);
    for (scripts, 0..) |*s, k| {
        const pl = try ar.alloc(abi.snapshot.PropertySnap, 31);
        for (pl[0..30], 0..) |*p, f| {
            const v: i64 = @intCast((k + f) % 97);
            p.* = .{ .name = try std.fmt.allocPrint(ar, "f{d}", .{f}), .usage = 4102, .has_field = true, .variant_type = switch (f % 3) {
                0 => default_value.t_int,
                1 => default_value.t_float,
                else => default_value.t_bool,
            }, .default = switch (f % 3) {
                0 => .{ .int = v },
                1 => .{ .float = @as(f64, @floatFromInt(v)) + 0.5 },
                else => .{ .boolean = @rem(v, 2) == 0 },
            } };
        }
        pl[30] = .{ .name = "title", .usage = 4102, .has_field = true, .variant_type = default_value.t_string, .default = .string_empty };
        const methods = try ar.alloc(abi.snapshot.MethodSnap, 30);
        for (methods, 0..) |*m, j| m.* = .{ .name = try std.fmt.allocPrint(ar, "m{d}", .{j}), .flags = 1 };
        s.* = .{ .path = try std.fmt.allocPrint(ar, "s{d}/script{d}.zig", .{ k % 10, k }), .base_class = "Node", .layout_hash = k, .properties = pl, .methods = methods };
    }
    const snap: abi.snapshot.Snapshot = .{ .build_id = "0123456789abcdef", .scripts = scripts };

    // The editor's allocator for snapshot caches (script.installSnapshot).
    const a = std.heap.c_allocator;
    const bytes = try fromSnapshot(a, 0, &snap);
    defer a.free(bytes);
    var counter: platform.counting_allocator.CountingAllocator = .init(a);
    var diag: [256]u8 = undefined;
    var cache = try parseCounted(&counter, bytes, &diag);
    const held = counter.live;
    const diff = if (held > measured_parse_bytes) held - measured_parse_bytes else measured_parse_bytes - held;
    try testing.expect(diff * 100 <= measured_parse_bytes);
    try testing.expect(held > bytes.len * 2);
    cache.deinit();
    try testing.expectEqual(@as(u64, 0), counter.live);
}
