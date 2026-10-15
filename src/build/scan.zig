//! Finds the user's script files in a project (L2).
//!
//! A script is a `.zig` file with `pub const extends = ...` as a direct member
//! of the file. Any other `.zig` file is a helper. Skipped everywhere: names
//! starting with `.` (this covers the generated root and `.godot`), directories
//! that contain a `.gdignore` file, and symbolic links to directories (loop
//! risk). `addons/` is skipped at the project root only. A symbolic link to a
//! `.zig` file is read like a normal file.
//!
//! All results are allocated from `a`; pass an arena and free it as a whole.
const std = @import("std");
const platform = @import("ziggurat_platform");
const OsPath = platform.path.OsPath;
const rootgen = @import("rootgen.zig");

/// Project-relative path, `/`-separated.
pub const Script = struct { rel: []const u8 };

pub const Problem = struct { rel: []const u8, message: []const u8 };

pub const ScanResult = struct {
    /// Sorted by `rel` (byte order).
    scripts: []Script,
    helpers: u32,
    problems: []Problem,
};

pub const default_script_dirs: []const []const u8 = &.{""};

const max_file_bytes = 16 * 1024 * 1024;

const Scanner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    project: std.Io.Dir,
    scripts: std.ArrayList(Script) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    walked: std.StringHashMapUnmanaged(void) = .empty,
    helpers: u32 = 0,

    fn walk(self: *Scanner, rel: []const u8) !void {
        // Overlapping script folders: visit each folder once.
        if ((try self.walked.getOrPut(self.a, rel)).found_existing) return;
        var dir = self.project.openDir(self.io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch |err| {
            try self.problem(rel, "Could not open script folder \"{s}\": {t}.", .{ rel, err });
            return;
        };
        defer dir.close(self.io);
        if (dir.access(self.io, ".gdignore", .{})) |_| return else |_| {}

        var it = dir.iterate();
        while (true) {
            const entry = (it.next(self.io) catch |err| {
                try self.problem(rel, "Could not list folder \"{s}\": {t}.", .{ rel, err });
                return;
            }) orelse break;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            var kind = entry.kind;
            if (kind == .sym_link) {
                // Links to files count as files; links to folders are not followed.
                const st = dir.statFile(self.io, entry.name, .{}) catch continue;
                if (st.kind != .file) continue;
                kind = .file;
            }
            const child = if (rel.len == 0)
                try self.a.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(self.a, "{s}/{s}", .{ rel, entry.name });
            switch (kind) {
                .directory => {
                    if (std.mem.eql(u8, child, "addons")) continue;
                    try self.walk(child);
                },
                .file => if (std.mem.endsWith(u8, entry.name, ".zig")) try self.file(dir, entry.name, child),
                else => {},
            }
        }
    }

    fn file(self: *Scanner, dir: std.Io.Dir, name: []const u8, rel: []const u8) !void {
        if ((try self.seen.getOrPut(self.a, rel)).found_existing) return;
        const src = dir.readFileAllocOptions(self.io, name, self.a, .limited(max_file_bytes), .of(u8), 0) catch |err| {
            try self.problem(rel, "Could not read \"{s}\": {t}.", .{ rel, err });
            return;
        };
        if (try hasTopLevelExtends(self.a, src)) {
            try self.scripts.append(self.a, .{ .rel = rel });
        } else {
            self.helpers += 1;
        }
    }

    fn problem(self: *Scanner, rel: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.a, .{ .rel = rel, .message = try std.fmt.allocPrint(self.a, fmt, args) });
    }
};

/// Scans each folder of `script_dirs` (project-relative, `/`-separated, `""` is
/// the project root). Entries are normalised first: `.` and empty parts are
/// dropped, so `./a//b/` means `a/b`. `error.InvalidScriptDir` when an entry is
/// absolute or contains `..`.
pub fn scan(
    a: std.mem.Allocator,
    io: std.Io,
    project: OsPath,
    script_dirs: []const []const u8,
) !ScanResult {
    for (script_dirs) |d| {
        if (std.mem.startsWith(u8, d, "/") or std.mem.indexOfScalar(u8, d, '\\') != null) return error.InvalidScriptDir;
        var parts = std.mem.splitScalar(u8, d, '/');
        while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return error.InvalidScriptDir;
    }
    var root = try std.Io.Dir.cwd().openDir(io, project.bytes, .{});
    defer root.close(io);
    var s: Scanner = .{ .a = a, .io = io, .project = root };
    for (script_dirs) |d| try s.walk(try normalizeDir(a, d));
    std.mem.sort(Script, s.scripts.items, {}, lessThan);
    try checkCase(&s);
    return .{
        .scripts = s.scripts.items,
        .helpers = s.helpers,
        .problems = s.problems.items,
    };
}

fn normalizeDir(a: std.mem.Allocator, d: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, d, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (out.items.len != 0) try out.append(a, '/');
        try out.appendSlice(a, p);
    }
    return out.items;
}

fn lessThan(_: void, x: Script, y: Script) bool {
    return std.mem.lessThan(u8, x.rel, y.rel);
}

/// Two scripts whose paths differ only by case break on Windows and macOS.
fn checkCase(s: *Scanner) !void {
    var lower: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (s.scripts.items) |sc| {
        const key = try std.ascii.allocLowerString(s.a, sc.rel);
        const gop = try lower.getOrPut(s.a, key);
        if (gop.found_existing) {
            try s.problem(sc.rel, "Scripts \"{s}\" and \"{s}\" differ only by case; rename one.", .{ gop.value_ptr.*, sc.rel });
        } else gop.value_ptr.* = sc.rel;
    }
}

/// True when `pub const extends` is a direct member of the file. If the file
/// does not parse, falls back to a line that starts with `pub const extends`,
/// so the compiler can report the real error later.
fn hasTopLevelExtends(a: std.mem.Allocator, src: [:0]const u8) !bool {
    var tree = try std.zig.Ast.parse(a, src, .{});
    defer tree.deinit(a);
    if (tree.errors.len != 0) return textCheck(src);
    for (tree.rootDecls()) |node| {
        const decl = tree.fullVarDecl(node) orelse continue;
        if (decl.visib_token == null) continue;
        if (tree.tokenTag(decl.ast.mut_token) != .keyword_const) continue;
        if (std.mem.eql(u8, tree.tokenSlice(decl.ast.mut_token + 1), "extends")) return true;
    }
    return false;
}

fn textCheck(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    const prefix = "pub const extends";
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        // Whole name only: spaces, then `=` or `:`.
        const rest = std.mem.trimStart(u8, line[prefix.len..], " \t");
        if (rest.len != 0 and (rest[0] == '=' or rest[0] == ':')) return true;
    }
    return false;
}

const testing = std.testing;

fn tmpProject(tmp: std.testing.TmpDir, a: std.mem.Allocator) !OsPath {
    return OsPath.fromTrusted(try tmp.dir.realPathFileAlloc(testing.io, ".", a));
}

fn put(tmp: std.testing.TmpDir, sub: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub)) |d| try tmp.dir.createDirPath(testing.io, d);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub, .data = data });
}

test "scan rules" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "a.zig", "pub const extends = \"Node\";\n");
    try put(tmp, "lib/util.zig", "pub fn f() void {}\n");
    try put(tmp, "addons/x/s.zig", "pub const extends = 1;\n");
    try put(tmp, "ignored/s.zig", "pub const extends = 1;\n");
    try put(tmp, "ignored/.gdignore", "");
    try put(tmp, ".hidden/s.zig", "pub const extends = 1;\n");
    try put(tmp, ".godot/s.zig", "pub const extends = 1;\n");
    try put(tmp, rootgen.root_file_name, "pub const extends = 1;\n");
    try put(tmp, "nested.zig", "const T = struct { pub const extends = 1; };\n");
    try put(tmp, "sub/addons/s.zig", "pub const extends = 1;\n");
    try put(tmp, "var.zig", "pub var extends: i32 = 1;\n");
    try put(tmp, "private.zig", "const extends = 1;\n");
    try put(tmp, "typed.zig", "pub const extends: []const u8 = \"Node\";\n");

    const res = try scan(a, testing.io, try tmpProject(tmp, a), default_script_dirs);
    // Typed `pub const extends: T = ...` counts; `pub var` and non-pub do not.
    try testing.expectEqual(@as(usize, 3), res.scripts.len);
    try testing.expectEqualStrings("a.zig", res.scripts[0].rel);
    try testing.expectEqualStrings("sub/addons/s.zig", res.scripts[1].rel);
    try testing.expectEqualStrings("typed.zig", res.scripts[2].rel);
    try testing.expectEqual(@as(u32, 4), res.helpers);
    try testing.expectEqual(@as(usize, 0), res.problems.len);
}

test "scan case collision" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "A.zig", "pub const extends = 1; // upper\n");
    try put(tmp, "a.zig", "pub const extends = 1; // lower\n");
    const check = try tmp.dir.readFileAlloc(testing.io, "A.zig", a, .limited(1024));
    if (std.mem.indexOf(u8, check, "lower") != null) return error.SkipZigTest; // case-folding file system

    const res = try scan(a, testing.io, try tmpProject(tmp, a), default_script_dirs);
    try testing.expectEqual(@as(usize, 1), res.problems.len);
    try testing.expectEqualStrings(
        "Scripts \"A.zig\" and \"a.zig\" differ only by case; rename one.",
        res.problems[0].message,
    );
}

test "scan parse error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "bad.zig", "pub const extends = \"Node\";\nfn broken( {{{\n");
    try put(tmp, "bad_helper.zig", "fn broken( {{{\n");
    const res = try scan(a, testing.io, try tmpProject(tmp, a), default_script_dirs);
    try testing.expectEqual(@as(usize, 1), res.scripts.len);
    try testing.expectEqualStrings("bad.zig", res.scripts[0].rel);
    try testing.expectEqual(@as(u32, 1), res.helpers);
}

test "scan script dirs and symlinks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "scripts/a.zig", "pub const extends = 1;\n");
    try put(tmp, "other/b.zig", "pub const extends = 1;\n");
    try tmp.dir.symLink(testing.io, "a.zig", "scripts/link.zig", .{});
    try tmp.dir.symLink(testing.io, "..", "scripts/loop", .{ .is_directory = true });

    const res = try scan(a, testing.io, try tmpProject(tmp, a), &.{"scripts"});
    try testing.expectEqual(@as(usize, 2), res.scripts.len);
    try testing.expectEqualStrings("scripts/a.zig", res.scripts[0].rel);
    try testing.expectEqualStrings("scripts/link.zig", res.scripts[1].rel);
    try testing.expectError(error.InvalidScriptDir, scan(a, testing.io, try tmpProject(tmp, a), &.{"../x"}));
}

test "scan text fallback needs the whole name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "x.zig", "pub const extends_all = 1;\nfn broken( {{{\n");
    try put(tmp, "y.zig", "pub const extends : type = 1;\nfn broken( {{{\n");
    const res = try scan(a, testing.io, try tmpProject(tmp, a), default_script_dirs);
    try testing.expectEqual(@as(usize, 1), res.scripts.len);
    try testing.expectEqualStrings("y.zig", res.scripts[0].rel);
    try testing.expectEqual(@as(u32, 1), res.helpers);
}

test "scan normalises and de-duplicates script dirs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "addons/x/s.zig", "pub const extends = 1;\n");
    try put(tmp, "game/s.zig", "pub const extends = 1;\n");
    const project = try tmpProject(tmp, a);
    const res = try scan(a, testing.io, project, &.{ "./game//", "game", ".", "" });
    try testing.expectEqual(@as(usize, 1), res.scripts.len);
    try testing.expectEqualStrings("game/s.zig", res.scripts[0].rel);
}

test "scan reports a problem once for overlapping dirs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "game/ok.zig", "pub const extends = 1;\n");
    try put(tmp, "game/locked/s.zig", "pub const extends = 1;\n");
    const locked = try tmp.dir.realPathFileAlloc(testing.io, "game/locked", a);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(locked, 0));
    defer _ = std.c.chmod(locked, 0o755);
    // Running as root can still open the folder; then there is nothing to count.
    if (tmp.dir.openDir(testing.io, "game/locked", .{ .iterate = true })) |d| {
        d.close(testing.io);
        return error.SkipZigTest;
    } else |_| {}

    const res = try scan(a, testing.io, try tmpProject(tmp, a), &.{ "", "game", "game/locked" });
    try testing.expectEqual(@as(usize, 1), res.problems.len);
}
