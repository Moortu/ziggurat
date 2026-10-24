//! Build tool: stages the shipped SDK (spec section 1), the folder that
//! goes into a project as `addons/ziggurat/sdk/`.
//!
//! Usage: sdk_stage <out dir> <sdk_version> (<name> <root> <deps> <strip>)...
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
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or (args.len - 3) % 4 != 0) {
        std.debug.print("usage: sdk_stage <out dir> <sdk_version> (<name> <root> <deps> <none|docs|comments>)...\n", .{});
        std.process.exit(2);
    }
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, args[1]);
    var out = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer out.close(io);
    {
        var it = out.iterate();
        if (try it.next(io)) |entry| fail("the output folder {s} is not empty (it holds {s})", .{ args[1], entry.name });
    }

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
