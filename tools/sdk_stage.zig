//! Build tool: stages the shipped SDK (spec section 1), the folder that
//! goes into a project as `addons/ziggurat/sdk/`.
//!
//! Usage: sdk_stage [--replace] <out dir> <sdk_version> (<name> <root> <deps> <strip>)...
//!
//! `<deps>` is a comma-separated list of module names (empty for none).
//! `<strip>` is `none`, `docs` (lines that hold only a `///` doc comment
//! are left out) or `comments` (lines that hold only a `//` comment of any
//! kind are left out). `//!` file comments stay with `docs`.
//!
//! Each module goes to `<out dir>/<name>/`: its root and every file the
//! root reaches through `@import` or `@embedFile` of a relative path, at
//! the same place relative to the root's folder. A module cannot reach a
//! file above its root's folder (the compiler forbids it), so neither can
//! this tool. Then `.gdignore` (Godot's editor does not scan the folder)
//! and `sdk-manifest.json`, whose roots are relative to the out dir.
//!
//! The out dir must be missing or empty. Every stripped file is parsed
//! again; one that no longer parses stops the tool.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Strip = enum { none, docs, comments };

const Module = struct {
    name: []const u8,
    root: []const u8,
    deps: []const []const u8,
};

/// The largest source file the tool reads.
const max_file = 256 << 20;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const all_args = try init.minimal.args.toSlice(arena);
    var args = all_args;
    var mode: Mode = .user_folder;
    if (all_args.len > 1 and std.mem.eql(u8, all_args[1], replace_flag)) {
        mode = .cache_folder;
        args = try std.mem.concat(arena, [:0]const u8, &.{ all_args[0..1], all_args[2..] });
    }
    if (args.len < 3 or (args.len - 3) % 4 != 0) {
        std.debug.print("usage: sdk_stage [--replace] <out dir> <sdk_version> (<name> <root> <deps> <none|docs|comments>)...\n", .{});
        std.process.exit(2);
    }
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    var staging = begin(gpa, io, args[1], mode, &held) catch |err| switch (err) {
        error.NotEmpty => fail("the output folder {s} is not empty (it holds {s})", .{ args[1], std.mem.sliceTo(&held, 0) }),
        else => fail("cannot prepare the output folder {s} ({t})", .{ args[1], err }),
    };
    defer staging.deinit(gpa);
    try fillOutput(gpa, arena, io, args, staging.stage_path);
    staging.finish(io) catch |err|
        fail("cannot replace the output folder {s} with the finished one ({t})", .{ staging.final_path, err });
}

/// Writes the whole SDK into the existing folder `out_path`.
fn fillOutput(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, args: []const [:0]const u8, out_path: []const u8) !void {
    var out = try Io.Dir.cwd().openDir(io, out_path, .{ .iterate = true });
    defer out.close(io);

    var modules: std.ArrayList(Module) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 4) {
        const name = args[i];
        const root = args[i + 1];
        const strip = std.meta.stringToEnum(Strip, args[i + 3]) orelse
            fail("module \"{s}\": unknown strip mode \"{s}\"", .{ name, args[i + 3] });
        var deps: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, args[i + 2], ',');
        while (it.next()) |d| if (d.len != 0) try deps.append(arena, d);
        const base = std.fs.path.dirname(root) orelse ".";
        const root_file = std.fs.path.basename(root);
        try stageModule(gpa, io, base, root_file, out, name, strip);
        try modules.append(arena, .{
            .name = name,
            .root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ name, root_file }),
            .deps = deps.items,
        });
    }

    try out.writeFile(io, .{ .sub_path = ".gdignore", .data = "" });
    const manifest = .{
        .zig_version = builtin.zig_version_string,
        .sdk_version = args[2],
        .modules = modules.items,
    };
    const json = try std.json.Stringify.valueAlloc(arena, manifest, .{ .whitespace = .indent_2 });
    try out.writeFile(io, .{ .sub_path = "sdk-manifest.json", .data = json });
}

/// The first argument that makes the tool replace its output folder.
const replace_flag = "--replace";

const Mode = enum {
    /// A folder the user named: it must be missing or empty and is filled
    /// in place.
    user_folder,
    /// The output folder of a cached build step: the build system made it,
    /// it may hold what an interrupted run left, and nobody else uses it.
    /// The tool stages into a fresh sibling and swaps it in at the end.
    cache_folder,
};

/// Where a run writes: `stage_path` is `final_path` itself (user folder)
/// or a fresh sibling folder that `finish` swaps in (cache folder).
const Staging = struct {
    final_path: []const u8,
    stage_path: []const u8,
    swap: bool,

    fn deinit(self: *Staging, gpa: std.mem.Allocator) void {
        if (self.swap) gpa.free(self.stage_path);
    }

    /// Swaps a finished stage folder in: the old output folder (whatever
    /// an interrupted run left in it) goes first, then the stage folder is
    /// renamed. An interruption between the two leaves no output folder,
    /// which the next run makes again.
    fn finish(self: *Staging, io: Io) !void {
        if (!self.swap) return;
        const cwd = Io.Dir.cwd();
        try cwd.deleteTree(io, self.final_path);
        try cwd.rename(self.stage_path, cwd, self.final_path, io);
    }
};

/// Infix of the stage folder's name: `<out>.tmp-<16 hex digits>`.
const tmp_infix = ".tmp-";

/// Whether `name` is exactly `<base>.tmp-` and 16 lowercase hex digits.
fn isStageName(name: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, name, base)) return false;
    const rest = name[base.len..];
    if (!std.mem.startsWith(u8, rest, tmp_infix)) return false;
    const hex = rest[tmp_infix.len..];
    if (hex.len != 16) return false;
    for (hex) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// Prepares the output folder. `held` receives the name of the first entry
/// of a user folder that is not empty (zero-terminated).
fn begin(gpa: std.mem.Allocator, io: Io, out_path: []const u8, mode: Mode, held: *[Io.Dir.max_name_bytes]u8) !Staging {
    const cwd = Io.Dir.cwd();
    switch (mode) {
        .user_folder => {
            try cwd.createDirPath(io, out_path);
            var out = try cwd.openDir(io, out_path, .{ .iterate = true });
            defer out.close(io);
            var it = out.iterate();
            if (try it.next(io)) |entry| {
                @memset(held, 0);
                @memcpy(held[0..entry.name.len], entry.name);
                return error.NotEmpty;
            }
            return .{ .final_path = out_path, .stage_path = out_path, .swap = false };
        },
        .cache_folder => {
            const final = std.mem.trimEnd(u8, out_path, "/");
            const base = std.fs.path.basename(final);
            const parent_path = std.fs.path.dirname(final) orelse return error.BadOutputPath;
            if (final.len == 0 or parent_path.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, ".."))
                return error.BadOutputPath;
            try cwd.createDirPath(io, parent_path);
            var parent = try cwd.openDir(io, parent_path, .{ .iterate = true });
            defer parent.close(io);
            // Stage folders of earlier runs that were interrupted.
            var stale: std.ArrayList([]u8) = .empty;
            defer {
                for (stale.items) |n| gpa.free(n);
                stale.deinit(gpa);
            }
            var it = parent.iterate();
            while (try it.next(io)) |entry| {
                if (isStageName(entry.name, base)) try stale.append(gpa, try gpa.dupe(u8, entry.name));
            }
            for (stale.items) |n| try parent.deleteTree(io, n);
            var random: [8]u8 = undefined;
            io.random(&random);
            const stage = try std.fmt.allocPrint(gpa, "{s}{s}{x}", .{ final, tmp_infix, random });
            errdefer gpa.free(stage);
            try cwd.createDirPath(io, stage);
            return .{ .final_path = final, .stage_path = stage, .swap = true };
        },
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("sdk_stage: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Copies `root_file` of folder `base` and every file it reaches to
/// `<out>/<name>/`, stripping as `strip` says.
fn stageModule(gpa: std.mem.Allocator, io: Io, base: []const u8, root_file: []const u8, out: Io.Dir, name: []const u8, strip: Strip) !void {
    var src = Io.Dir.cwd().openDir(io, base, .{}) catch |err|
        fail("module \"{s}\": cannot open {s} ({t})", .{ name, base, err });
    defer src.close(io);
    try out.createDirPath(io, name);
    var dst = try out.openDir(io, name, .{});
    defer dst.close(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    try seen.put(arena, try arena.dupe(u8, root_file), {});
    var next: usize = 0;
    while (next < seen.count()) : (next += 1) {
        const rel = seen.keys()[next];
        const bytes = src.readFileAllocOptions(io, rel, gpa, .limited(max_file), .of(u8), 0) catch |err|
            fail("module \"{s}\": cannot read {s}/{s} ({t})", .{ name, base, rel, err });
        defer gpa.free(bytes);
        const is_zig = std.mem.endsWith(u8, rel, ".zig");
        if (is_zig) {
            var reached: std.ArrayList([]const u8) = .empty;
            defer {
                for (reached.items) |r| gpa.free(r);
                reached.deinit(gpa);
            }
            try fileRefs(gpa, bytes, &reached);
            const dir = std.fs.path.dirnamePosix(rel) orelse "";
            for (reached.items) |r| {
                const joined = try std.fs.path.resolvePosix(arena, &.{ dir, r });
                if (std.fs.path.isAbsolutePosix(joined) or std.mem.eql(u8, joined, "..") or std.mem.startsWith(u8, joined, "../"))
                    fail("module \"{s}\": {s} reaches \"{s}\", outside the module's folder", .{ name, rel, r });
                try seen.put(arena, joined, {});
            }
        }
        const data = if (is_zig and strip != .none) try stripLines(gpa, bytes, strip) else try gpa.dupe(u8, bytes);
        defer gpa.free(data);
        if (is_zig and strip != .none) {
            const z = try gpa.dupeSentinel(u8, data, 0);
            defer gpa.free(z);
            var tree = try std.zig.Ast.parse(gpa, z, .{});
            defer tree.deinit(gpa);
            if (tree.errors.len != 0) fail("module \"{s}\": {s} does not parse after stripping", .{ name, rel });
        }
        if (std.fs.path.dirnamePosix(rel)) |d| try dst.createDirPath(io, d);
        try dst.writeFile(io, .{ .sub_path = rel, .data = data });
    }
}

/// Appends to `out` the relative file paths that `source` names in
/// `@import("<path>.zig")`, `@import("<path>.zon")` and `@embedFile("<path>")`
/// (module names such as `@import("std")` are not files). Each is
/// allocated with `gpa`.
fn fileRefs(gpa: std.mem.Allocator, source: [:0]const u8, out: *std.ArrayList([]const u8)) !void {
    var tok: std.zig.Tokenizer = .init(source);
    // The two tokens before the current one.
    var before: [2]std.zig.Token = .{ .{ .tag = .invalid, .loc = .{ .start = 0, .end = 0 } }, .{ .tag = .invalid, .loc = .{ .start = 0, .end = 0 } } };
    while (true) {
        const t = tok.next();
        if (t.tag == .eof) break;
        defer before = .{ before[1], t };
        if (t.tag != .string_literal or before[1].tag != .l_paren or before[0].tag != .builtin) continue;
        const name = source[before[0].loc.start..before[0].loc.end];
        const is_import = std.mem.eql(u8, name, "@import");
        const is_embed = std.mem.eql(u8, name, "@embedFile");
        if (!is_import and !is_embed) continue;
        const path = std.zig.string_literal.parseAlloc(gpa, source[t.loc.start..t.loc.end]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => fail("a string after {s} does not parse", .{name}),
        };
        const file = is_embed or std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon");
        if (file) try out.append(gpa, path) else gpa.free(path);
    }
}

/// `source` without the lines that hold only a comment of the kind `strip`
/// names. A line that holds only a comment is never inside a multi-line
/// string literal (each of its lines starts with `\\`), so this is exact.
fn stripLines(gpa: std.mem.Allocator, source: []const u8, strip: Strip) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, source.len);
    var it = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (it.next()) |line| {
        if (dropLine(line, strip)) continue;
        if (!first) out.appendAssumeCapacity('\n');
        first = false;
        out.appendSliceAssumeCapacity(line);
    }
    return out.toOwnedSlice(gpa);
}

fn dropLine(line: []const u8, strip: Strip) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return switch (strip) {
        .none => false,
        .docs => std.mem.startsWith(u8, t, "///") and !std.mem.startsWith(u8, t, "////"),
        .comments => std.mem.startsWith(u8, t, "//"),
    };
}

const testing = std.testing;

fn tmpPath(buf: []u8, tmp: *const testing.TmpDir, rest: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, rest }) catch unreachable;
}

test "a cache folder left half-filled by an interrupted run is replaced" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "o/h1/sdk/gdzig");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "o/h1/sdk/gdzig/half.zig", .data = "old" });
    var pb: [256]u8 = undefined;
    const out_path = tmpPath(&pb, &tmp, "o/h1/sdk");
    var held: [Io.Dir.max_name_bytes]u8 = undefined;

    var staging = try begin(testing.allocator, testing.io, out_path, .cache_folder, &held);
    defer staging.deinit(testing.allocator);
    const file = try std.fmt.allocPrint(testing.allocator, "{s}/sdk-manifest.json", .{staging.stage_path});
    defer testing.allocator.free(file);
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = "new" });
    try staging.finish(testing.io);

    const got = try tmp.dir.readFileAlloc(testing.io, "o/h1/sdk/sdk-manifest.json", testing.allocator, .limited(100));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("new", got);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "o/h1/sdk/gdzig", .{}));
    // Only the swapped-in folder is left next to the others.
    var n: usize = 0;
    var d = try tmp.dir.openDir(testing.io, "o/h1", .{ .iterate = true });
    defer d.close(testing.io);
    var it = d.iterate();
    while (try it.next(testing.io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);
}

test "a cache folder that is missing is made" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "o/h1");
    var pb: [256]u8 = undefined;
    const out_path = tmpPath(&pb, &tmp, "o/h1/sdk");
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    var staging = try begin(testing.allocator, testing.io, out_path, .cache_folder, &held);
    defer staging.deinit(testing.allocator);
    try staging.finish(testing.io);
    try tmp.dir.access(testing.io, "o/h1/sdk", .{});
}

test "temporary folders of earlier interrupted runs do not matter and are removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "o/h1/sdk.tmp-0123456789abcdef/gdzig");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "o/h1/sdk.tmp-0123456789abcdef/gdzig/x.zig", .data = "x" });
    try tmp.dir.createDirPath(testing.io, "o/h1/other");
    var pb: [256]u8 = undefined;
    const out_path = tmpPath(&pb, &tmp, "o/h1/sdk");
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    var staging = try begin(testing.allocator, testing.io, out_path, .cache_folder, &held);
    defer staging.deinit(testing.allocator);
    try staging.finish(testing.io);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "o/h1/sdk.tmp-0123456789abcdef", .{}));
    try tmp.dir.access(testing.io, "o/h1/other", .{});
    try tmp.dir.access(testing.io, "o/h1/sdk", .{});
}

test "a user folder that is not empty is refused and left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "mine");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mine/precious.txt", .data = "keep" });
    var pb: [256]u8 = undefined;
    const out_path = tmpPath(&pb, &tmp, "mine");
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    try testing.expectError(error.NotEmpty, begin(testing.allocator, testing.io, out_path, .user_folder, &held));
    try testing.expectEqualStrings("precious.txt", std.mem.sliceTo(&held, 0));
    const got = try tmp.dir.readFileAlloc(testing.io, "mine/precious.txt", testing.allocator, .limited(100));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("keep", got);
}

test "a user folder that is missing or empty is filled in place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "empty");
    var pb: [256]u8 = undefined;
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    for ([_][]const u8{ "empty", "missing/deeper" }) |rel| {
        const out_path = tmpPath(&pb, &tmp, rel);
        var staging = try begin(testing.allocator, testing.io, out_path, .user_folder, &held);
        defer staging.deinit(testing.allocator);
        try testing.expectEqualStrings(out_path, staging.stage_path);
        try staging.finish(testing.io);
        try tmp.dir.access(testing.io, rel, .{});
    }
}

test "only exact stage folder names are removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "o/sdk.tmp-backup", "o/sdk.tmp-0123456789abcdef0", "o/sdk.tmp-0123456789abcdeg", "o/sdk.tmp-0123456789abcdef" }) |n| try tmp.dir.createDirPath(testing.io, n);
    var pb: [256]u8 = undefined;
    const out_path = tmpPath(&pb, &tmp, "o/sdk");
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    var staging = try begin(testing.allocator, testing.io, out_path, .cache_folder, &held);
    defer staging.deinit(testing.allocator);
    try staging.finish(testing.io);
    try tmp.dir.access(testing.io, "o/sdk.tmp-backup", .{});
    try tmp.dir.access(testing.io, "o/sdk.tmp-0123456789abcdef0", .{});
    try tmp.dir.access(testing.io, "o/sdk.tmp-0123456789abcdeg", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "o/sdk.tmp-0123456789abcdef", .{}));
}

test "a cache output path that could hit something else is refused" {
    var held: [Io.Dir.max_name_bytes]u8 = undefined;
    for ([_][]const u8{ "/", "", ".", "..", "sdk", "a/..", "a/." }) |p|
        try testing.expectError(error.BadOutputPath, begin(testing.allocator, testing.io, p, .cache_folder, &held));
}
