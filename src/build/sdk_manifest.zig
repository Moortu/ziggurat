//! SDK module manifest (L2): the JSON file that lists the SDK's modules for
//! `BuildService.Config.sdk`. `zig build sdk-manifest` writes it.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("ziggurat_platform");
const workspace = @import("workspace.zig");
const OsPath = platform.path.OsPath;
const ModuleDep = workspace.ModuleDep;

/// The longest manifest `load` reads.
const max_bytes = 1 << 20;

/// Module names the compiler gives a meaning of its own (`root` is the
/// generated root's module in `Workspace.argv`).
const reserved_names = [_][]const u8{ "root", "std", "builtin", "c" };

pub const Manifest = struct {
    zig_version: []const u8,
    sdk_version: []const u8,
    /// `name`, `root.bytes` and each dep are owned by the manifest.
    modules: []ModuleDep,

    pub fn deinit(self: *Manifest, a: std.mem.Allocator) void {
        a.free(self.zig_version);
        a.free(self.sdk_version);
        for (self.modules) |m| freeModule(a, m);
        a.free(self.modules);
        self.* = undefined;
    }
};

fn freeModule(a: std.mem.Allocator, m: ModuleDep) void {
    a.free(m.name);
    a.free(m.root.bytes);
    for (m.deps) |d| a.free(d);
    a.free(m.deps);
}

/// The JSON shape, as `zig build sdk-manifest` writes it.
const Raw = struct {
    zig_version: []const u8,
    sdk_version: []const u8,
    modules: []const struct {
        name: []const u8,
        root: []const u8,
        deps: []const []const u8,
    },
};

/// Reads and checks the manifest at `path`. On `error.InvalidManifest`,
/// `msg` holds one sentence that names the bad value.
pub fn load(a: std.mem.Allocator, io: std.Io, path: OsPath, msg: *std.ArrayList(u8)) !Manifest {
    msg.clearRetainingCapacity();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path.bytes, a, .limited(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try msg.print(a, "Could not read the SDK manifest {s} ({t}).", .{ path.bytes, err });
            return error.InvalidManifest;
        },
    };
    defer a.free(bytes);

    const parsed = std.json.parseFromSlice(Raw, a, bytes, .{
        // A later SDK may add fields; this loader reads the ones it knows.
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try msg.print(a, "The SDK manifest {s} is not valid manifest JSON ({t}).", .{ path.bytes, err });
            return error.InvalidManifest;
        },
    };
    defer parsed.deinit();
    const raw = parsed.value;

    if (!std.mem.eql(u8, raw.zig_version, platform.pins.zig_version)) {
        try msg.print(a, "The SDK manifest is for Zig \"{s}\", but Ziggurat needs Zig {s}.", .{ raw.zig_version, platform.pins.zig_version });
        return error.InvalidManifest;
    }
    var has_ziggurat = false;
    for (raw.modules, 0..) |m, i| {
        if (!validName(m.name)) {
            try msg.print(a, "The SDK manifest has the module name \"{f}\"; module names use only A-Z, a-z, 0-9, _ and . and are not empty.", .{std.zig.fmtString(m.name)});
            return error.InvalidManifest;
        }
        for (reserved_names) |r| if (std.mem.eql(u8, m.name, r)) {
            try msg.print(a, "The SDK manifest has a module named \"{s}\", a name the compiler reserves.", .{m.name});
            return error.InvalidManifest;
        };
        for (raw.modules[0..i]) |prev| if (std.mem.eql(u8, prev.name, m.name)) {
            try msg.print(a, "The SDK manifest lists the module \"{s}\" twice.", .{m.name});
            return error.InvalidManifest;
        };
        if (!std.fs.path.isAbsolute(m.root)) {
            try msg.print(a, "The SDK manifest gives module \"{s}\" the relative root \"{s}\"; roots must be absolute.", .{ m.name, m.root });
            return error.InvalidManifest;
        }
        if (std.mem.eql(u8, m.name, "ziggurat")) has_ziggurat = true;
    }
    if (!has_ziggurat) {
        try msg.print(a, "The SDK manifest lists no module named \"ziggurat\".", .{});
        return error.InvalidManifest;
    }
    for (raw.modules) |m| {
        for (m.deps) |d| {
            const known = for (raw.modules) |other| {
                if (std.mem.eql(u8, other.name, d)) break true;
            } else false;
            if (!known) {
                try msg.print(a, "The SDK manifest module \"{s}\" depends on \"{s}\", which the manifest does not list.", .{ m.name, d });
                return error.InvalidManifest;
            }
        }
    }

    // Copy out of the parse arena into memory the manifest owns.
    const zig_version = try a.dupe(u8, raw.zig_version);
    errdefer a.free(zig_version);
    const sdk_version = try a.dupe(u8, raw.sdk_version);
    errdefer a.free(sdk_version);
    const modules = try a.alloc(ModuleDep, raw.modules.len);
    var done: usize = 0;
    errdefer {
        for (modules[0..done]) |m| freeModule(a, m);
        a.free(modules);
    }
    for (raw.modules, modules) |src, *dst| {
        dst.* = try dupeModule(a, src.name, src.root, src.deps);
        done += 1;
    }
    return .{ .zig_version = zig_version, .sdk_version = sdk_version, .modules = modules };
}

/// Module names reach the compiler command line (`-M<name>=`, `--dep <name>`),
/// so they are limited to `[A-Za-z0-9_.]`.
fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '.' => {},
        else => return false,
    };
    return true;
}

fn dupeModule(a: std.mem.Allocator, name: []const u8, root: []const u8, deps: []const []const u8) !ModuleDep {
    const n = try a.dupe(u8, name);
    errdefer a.free(n);
    const r = try a.dupe(u8, root);
    errdefer a.free(r);
    const ds = try a.alloc([]const u8, deps.len);
    var done: usize = 0;
    errdefer {
        for (ds[0..done]) |d| a.free(d);
        a.free(ds);
    }
    for (deps, ds) |src, *dst| {
        dst.* = try a.dupe(u8, src);
        done += 1;
    }
    return .{ .name = n, .root = .fromTrusted(r), .deps = ds };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRejected(json: []const u8, want_in_msg: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.json", .data = json });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const p = try std.fs.path.join(testing.allocator, &.{ dir, "m.json" });
    defer testing.allocator.free(p);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    if (load(testing.allocator, testing.io, .fromTrusted(p), &msg)) |m| {
        var mm = m;
        mm.deinit(testing.allocator);
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.InvalidManifest, err);
    }
    if (std.mem.indexOf(u8, msg.items, want_in_msg) == null) {
        std.debug.print("message \"{s}\" does not name \"{s}\"\n", .{ msg.items, want_in_msg });
        return error.TestUnexpectedResult;
    }
}

/// An absolute root for the host OS.
const abs = if (builtin.os.tag == .windows) "C:\\\\sdk\\\\" else "/sdk/";

test "manifest rejects" {
    // Missing `ziggurat` module.
    try expectRejected(
        \\{"zig_version":"0.17.0","sdk_version":"0.1.0","modules":[
    ++
        \\{"name":"gdzig","root":"
    ++ abs ++
        \\g.zig","deps":["gdzig"]}]}
    , "ziggurat");
    // Duplicate name.
    try expectRejected(
        \\{"zig_version":"0.17.0","sdk_version":"0.1.0","modules":[
    ++
        \\{"name":"ziggurat","root":"
    ++ abs ++
        \\z.zig","deps":[]},
    ++
        \\{"name":"ziggurat","root":"
    ++ abs ++
        \\y.zig","deps":[]}]}
    , "\"ziggurat\" twice");
    // Relative root.
    try expectRejected(
        \\{"zig_version":"0.17.0","sdk_version":"0.1.0","modules":[
    ++
        \\{"name":"ziggurat","root":"sdk/ziggurat.zig","deps":[]}]}
    , "sdk/ziggurat.zig");
    // A dep that names no listed module.
    try expectRejected(
        \\{"zig_version":"0.17.0","sdk_version":"0.1.0","modules":[
    ++
        \\{"name":"ziggurat","root":"
    ++ abs ++
        \\z.zig","deps":["nope"]}]}
    , "\"nope\"");
    // Wrong Zig version.
    try expectRejected(
        \\{"zig_version":"0.16.0","sdk_version":"0.1.0","modules":[
    ++
        \\{"name":"ziggurat","root":"
    ++ abs ++
        \\z.zig","deps":[]}]}
    , "0.16.0");
    // Module names outside [A-Za-z0-9_.].
    for ([_][]const u8{ "a b", "a,b", "a=b", "a\\u0001b", "" }) |bad| {
        const json = try std.fmt.allocPrint(testing.allocator,
            \\{{"zig_version":"0.17.0","sdk_version":"0.1.0","modules":[
            \\{{"name":"ziggurat","root":"{s}z.zig","deps":[]}},
            \\{{"name":"{s}","root":"{s}y.zig","deps":[]}}]}}
        , .{ abs, bad, abs });
        defer testing.allocator.free(json);
        try expectRejected(json, "module names use only");
    }
    // Not JSON of the expected shape.
    try expectRejected("{\"zig_version\":", "m.json");
    // An empty file.
    try expectRejected("", "m.json");
}

test "manifest rejects hostile input" {
    const a = testing.allocator;
    const valid_module = "{\"name\":\"ziggurat\",\"root\":\"" ++ abs ++ "z.zig\",\"deps\":[]}";
    // Larger than the 1 MiB read limit: valid JSON padded with spaces.
    const oversized = try a.alloc(u8, max_bytes + 16);
    defer a.free(oversized);
    @memset(oversized, ' ');
    const head = "{\"zig_version\":\"0.17.0\",\"sdk_version\":\"0.1.0\",\"modules\":[" ++ valid_module ++ "]}";
    @memcpy(oversized[0..head.len], head);
    // Deeply nested arrays where a string belongs.
    const depth = 100_000;
    const nested = try a.alloc(u8, 2 * depth + 64);
    defer a.free(nested);
    const prefix = "{\"zig_version\":";
    @memcpy(nested[0..prefix.len], prefix);
    @memset(nested[prefix.len..][0..depth], '[');
    @memset(nested[prefix.len + depth ..][0..depth], ']');
    const tail = nested[prefix.len + 2 * depth ..];
    @memset(tail, ' ');
    tail[0] = '}';

    const Case = struct { name: []const u8, json: []const u8 };
    const cases = [_]Case{
        .{ .name = "oversized", .json = oversized },
        .{ .name = "deeply nested", .json = nested },
        .{ .name = "number for a string", .json = "{\"zig_version\":17,\"sdk_version\":\"0.1.0\",\"modules\":[" ++ valid_module ++ "]}" },
        .{ .name = "string for deps", .json = "{\"zig_version\":\"0.17.0\",\"sdk_version\":\"0.1.0\",\"modules\":[{\"name\":\"ziggurat\",\"root\":\"" ++ abs ++ "z.zig\",\"deps\":\"gdzig\"}]}" },
        .{ .name = "null modules", .json = "{\"zig_version\":\"0.17.0\",\"sdk_version\":\"0.1.0\",\"modules\":null}" },
        .{ .name = "object for modules", .json = "{\"zig_version\":\"0.17.0\",\"sdk_version\":\"0.1.0\",\"modules\":{}}" },
    };
    for (cases) |c| {
        expectRejected(c.json, "m.json") catch |err| {
            std.debug.print("case \"{s}\" was not rejected cleanly\n", .{c.name});
            return err;
        };
    }
}

test "manifest ignores unknown fields" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const json =
        \\{"zig_version":"0.17.0","sdk_version":"0.1.0","future":{"x":[1,2]},"modules":[
    ++
        \\{"name":"ziggurat","root":"
    ++ abs ++
        \\z.zig","deps":[],"flags":["-fno-x"]}]}
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.json", .data = json });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const p = try std.fs.path.join(testing.allocator, &.{ dir, "m.json" });
    defer testing.allocator.free(p);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    var m = try load(testing.allocator, testing.io, .fromTrusted(p), &msg);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), m.modules.len);
    try testing.expectEqualStrings("ziggurat", m.modules[0].name);
}

test "manifest loads a self-dependency" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const json =
        \\{"zig_version":"0.17.0","sdk_version":"0.1.0","modules":[
    ++
        \\{"name":"ziggurat","root":"
    ++ abs ++
        \\z.zig","deps":["gdzig"]},
    ++
        \\{"name":"gdzig","root":"
    ++ abs ++
        \\g.zig","deps":["gdzig"]}]}
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.json", .data = json });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const p = try std.fs.path.join(testing.allocator, &.{ dir, "m.json" });
    defer testing.allocator.free(p);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    var m = try load(testing.allocator, testing.io, .fromTrusted(p), &msg);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("0.17.0", m.zig_version);
    try testing.expectEqualStrings("0.1.0", m.sdk_version);
    try testing.expectEqual(@as(usize, 2), m.modules.len);
    try testing.expectEqualStrings("gdzig", m.modules[1].name);
    try testing.expectEqualStrings(abs_plain ++ "g.zig", m.modules[1].root.bytes);
    try testing.expectEqualStrings("gdzig", m.modules[1].deps[0]);
}

const abs_plain = if (builtin.os.tag == .windows) "C:\\sdk\\" else "/sdk/";
