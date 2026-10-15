//! Finds a usable Zig 0.17.0 (L1).
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const pins = @import("pins.zig");
const process = @import("process.zig");
const testing_support = @import("testing_support.zig");
const build_options = @import("build_options");

const OsPath = path.OsPath;
const HostEnv = path.HostEnv;

pub const ZigInstall = struct {
    exe: OsPath,
    version: []const u8,

    pub fn deinit(self: ZigInstall, a: std.mem.Allocator) void {
        a.free(self.exe.bytes);
        a.free(self.version);
    }
};

pub const LocateConfig = struct {
    configured: ?OsPath,
    toolchain_dir: OsPath,
    env: HostEnv,
};

fn exeName(os: std.Target.Os.Tag) []const u8 {
    return if (os == .windows) "zig.exe" else "zig";
}

fn isFile(io: std.Io, p: OsPath) bool {
    const st = std.Io.Dir.cwd().statFile(io, p.bytes, .{}) catch return false;
    return st.kind == .file;
}

/// True when `text` matches `^\d+\.\d+\.\d+(-[0-9A-Za-z.+-]+)?$`.
fn isVersion(text: []const u8) bool {
    var rest = text;
    for (0..3) |i| {
        var n: usize = 0;
        while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
        if (n == 0) return false;
        rest = rest[n..];
        if (i < 2) {
            if (rest.len == 0 or rest[0] != '.') return false;
            rest = rest[1..];
        }
    }
    if (rest.len == 0) return true;
    if (rest[0] != '-' or rest.len == 1) return false;
    for (rest[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '+' and c != '-') return false;
    }
    return true;
}

const not_usable_head = "Ziggurat needs Zig " ++ pins.zig_version ++ ", but ";
const not_usable_tail = ". Set the Zig path in Editor Settings > Ziggurat, or use \"Download Zig " ++ pins.zig_version ++ "\".";

fn fail(a: std.mem.Allocator, msg: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !ZigInstall {
    try msg.appendSlice(a, not_usable_head);
    try msg.print(a, fmt, args);
    try msg.appendSlice(a, not_usable_tail);
    return error.ZigNotUsable;
}

/// Finds a Zig that reports `pins.zig_version`. Search order: the configured
/// path, `<toolchain_dir>/zig-<pin>/zig`, then each `PATH` entry. The first
/// candidate that exists as a file is run with `zig version`; later
/// candidates are not tried. On failure `msg` holds one plain sentence for
/// the user and the error is `error.ZigNotUsable`. The caller calls
/// `ZigInstall.deinit` on success.
pub fn locate(a: std.mem.Allocator, io: std.Io, cfg: LocateConfig, msg: *std.ArrayList(u8)) !ZigInstall {
    const os = cfg.env.os;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var candidates: std.ArrayList(OsPath) = .empty;
    if (cfg.configured) |c| try candidates.append(arena, c);
    const pin_dir = "zig-" ++ pins.zig_version;
    try candidates.append(arena, try path.joinFor(os, arena, cfg.toolchain_dir, &.{ pin_dir, exeName(os) }));
    if (cfg.env.path) |list| {
        const sep: u8 = if (os == .windows) ';' else ':';
        var it = std.mem.splitScalar(u8, list, sep);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            try candidates.append(arena, try path.joinFor(os, arena, OsPath.fromTrusted(entry), &.{exeName(os)}));
        }
    }

    var chosen: ?OsPath = null;
    for (candidates.items) |c| {
        if (isFile(io, c)) {
            chosen = c;
            break;
        }
    }
    const exe = chosen orelse {
        var list: std.ArrayList(u8) = .empty;
        for (candidates.items, 0..) |c, i| {
            if (i != 0) try list.appendSlice(arena, ", ");
            try list.appendSlice(arena, c.bytes);
        }
        return fail(a, msg, "no zig was found (checked: {s})", .{list.items});
    };

    const r = process.runCapture(a, io, &.{ exe.bytes, "version" }, null, 5000, 256) catch |err| switch (err) {
        error.Timeout => return fail(a, msg, "{s} did not answer \"zig version\" within 5 seconds", .{exe.bytes}),
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(a, msg, "{s} did not print a version", .{exe.bytes}),
    };
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    const text = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (!r.term.success() or !isVersion(text))
        return fail(a, msg, "{s} did not print a version", .{exe.bytes});
    if (!std.mem.eql(u8, text, pins.zig_version))
        return fail(a, msg, "{s} is Zig {s}", .{ exe.bytes, text });

    const exe_owned = try a.dupe(u8, exe.bytes);
    errdefer a.free(exe_owned);
    return .{ .exe = OsPath.fromTrusted(exe_owned), .version = try a.dupe(u8, text) };
}

fn fakeZig(tmp: std.testing.TmpDir, sub: []const u8, body: []const u8) ![:0]u8 {
    const io = std.testing.io;
    const a = std.testing.allocator;
    try tmp.dir.createDirPath(io, sub);
    const rel = try std.fs.path.join(a, &.{ sub, "zig" });
    defer a.free(rel);
    try tmp.dir.writeFile(io, .{
        .sub_path = rel,
        .data = body,
        .flags = .{ .permissions = .executable_file },
    });
    const abs = try tmp.dir.realPathFileAlloc(io, rel, a);
    return abs;
}

const Probe = struct {
    ok: bool,
    msg: []u8,
};

fn probe(tmp: std.testing.TmpDir, script: []const u8) !Probe {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const exe = try fakeZig(tmp, "bin", script);
    defer a.free(exe);
    var msg: std.ArrayList(u8) = .empty;
    errdefer msg.deinit(a);
    const tc = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tc);
    const res = locate(a, io, .{
        .configured = OsPath.fromTrusted(exe),
        .toolchain_dir = OsPath.fromTrusted(tc),
        .env = .{ .os = builtin.os.tag, .home = null, .path = "" },
    }, &msg);
    if (res) |inst| {
        inst.deinit(a);
        return .{ .ok = true, .msg = try msg.toOwnedSlice(a) };
    } else |err| {
        try std.testing.expectEqual(error.ZigNotUsable, err);
        return .{ .ok = false, .msg = try msg.toOwnedSlice(a) };
    }
}

test "integration: locator_finds_configured" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tc = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tc);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    const inst = try locate(a, io, .{
        .configured = OsPath.fromTrusted(build_options.zig_exe),
        .toolchain_dir = OsPath.fromTrusted(tc),
        .env = .{ .os = builtin.os.tag, .home = null, .path = "/nonexistent-dir-for-test" },
    }, &msg);
    defer inst.deinit(a);
    try std.testing.expectEqualStrings(build_options.zig_exe, inst.exe.bytes);
    try std.testing.expectEqualStrings(pins.zig_version, inst.version);
}

test "locator_rejects_bad_zig: wrong version" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try probe(tmp, "#!/bin/sh\necho 0.16.0\n");
    defer a.free(p.msg);
    try std.testing.expect(!p.ok);
    try std.testing.expect(std.mem.indexOf(u8, p.msg, "is Zig 0.16.0") != null);
    try std.testing.expect(std.mem.startsWith(u8, p.msg, "Ziggurat needs Zig 0.17.0, but "));
    try std.testing.expect(std.mem.endsWith(u8, p.msg, ". Set the Zig path in Editor Settings > Ziggurat, or use \"Download Zig 0.17.0\"."));
}

test "locator_rejects_bad_zig: 300 bytes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try probe(tmp, "#!/bin/sh\nhead -c 300 /dev/zero | tr '\\0' x\n");
    defer a.free(p.msg);
    try std.testing.expect(!p.ok);
    try std.testing.expect(std.mem.indexOf(u8, p.msg, "did not print a version") != null);
}

test "locator_rejects_bad_zig: exit 3" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try probe(tmp, "#!/bin/sh\nexit 3\n");
    defer a.free(p.msg);
    try std.testing.expect(!p.ok);
    try std.testing.expect(std.mem.indexOf(u8, p.msg, "did not print a version") != null);
}

test "locator_rejects_bad_zig: sleep 30 times out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const start = std.Io.Clock.awake.now(io);
    const p = try probe(tmp, "#!/bin/sh\nsleep 30\n");
    defer a.free(p.msg);
    const elapsed_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    std.debug.print("sleep-30 test took {d} ms\n", .{elapsed_ms});
    try std.testing.expect(!p.ok);
    try std.testing.expect(std.mem.indexOf(u8, p.msg, "within 5 seconds") != null);
    try std.testing.expect(elapsed_ms < 7000);
}

test "locator_none" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tc = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tc);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    try std.testing.expectError(error.ZigNotUsable, locate(a, io, .{
        .configured = null,
        .toolchain_dir = OsPath.fromTrusted(tc),
        .env = .{ .os = builtin.os.tag, .home = null, .path = "" },
    }, &msg));
    try std.testing.expect(std.mem.indexOf(u8, msg.items, "no zig was found") != null);
}

test "locator order: toolchain folder beats PATH" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const sub = "zig-" ++ pins.zig_version;
    const tool_exe = try fakeZig(tmp, sub, "#!/bin/sh\necho " ++ pins.zig_version ++ "\n");
    defer a.free(tool_exe);
    const path_exe = try fakeZig(tmp, "pathdir", "#!/bin/sh\necho 0.16.0\n");
    defer a.free(path_exe);
    const tc = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tc);
    const path_dir = try tmp.dir.realPathFileAlloc(io, "pathdir", a);
    defer a.free(path_dir);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    const inst = try locate(a, io, .{
        .configured = null,
        .toolchain_dir = OsPath.fromTrusted(tc),
        .env = .{ .os = builtin.os.tag, .home = null, .path = path_dir },
    }, &msg);
    defer inst.deinit(a);
    try std.testing.expectEqualStrings(tool_exe, inst.exe.bytes);
}

test "locator: PATH entry is used when nothing else exists" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_exe = try fakeZig(tmp, "pathdir", "#!/bin/sh\necho " ++ pins.zig_version ++ "\n");
    defer a.free(path_exe);
    const tc = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tc);
    const path_dir = try tmp.dir.realPathFileAlloc(io, "pathdir", a);
    defer a.free(path_dir);
    const env_path = try std.fmt.allocPrint(a, "/nonexistent-a:{s}", .{path_dir});
    defer a.free(env_path);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    const inst = try locate(a, io, .{
        .configured = null,
        .toolchain_dir = OsPath.fromTrusted(tc),
        .env = .{ .os = builtin.os.tag, .home = null, .path = env_path },
    }, &msg);
    defer inst.deinit(a);
    try std.testing.expectEqualStrings(path_exe, inst.exe.bytes);
}
