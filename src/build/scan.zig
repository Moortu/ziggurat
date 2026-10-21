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
//!
//! Finding `pub const extends` needs a full parse of the file, which is the
//! largest part of a small build in a Debug build of the service. `scanCached`
//! keeps each file's result in a `Cache` between scans and reads and parses
//! only files whose size, modification time or inode changed.
const std = @import("std");
const platform = @import("ziggurat_platform");
const OsPath = platform.path.OsPath;
const rootgen = @import("rootgen.zig");

/// Project-relative path, `/`-separated.
pub const Script = struct {
    rel: []const u8,
    /// Hash of the file's size, modification time, status-change time and
    /// inode: equal between two scans when the file did not change. 0 when
    /// the file could not be stat'ed (then it counts as changed).
    fingerprint: u64 = 0,
};

pub const Problem = struct { rel: []const u8, message: []const u8 };

pub const ScanResult = struct {
    /// Sorted by `rel` (byte order).
    scripts: []Script,
    /// Number of helper files; equals `helper_paths.len`.
    helpers: u32,
    /// Helper `.zig` files (not scripts), sorted by `rel` (byte order).
    helper_paths: []Script,
    problems: []Problem,
    /// Number of files read and parsed by this scan (the others came from
    /// the cache).
    parsed: u32 = 0,
    /// 16 lowercase hex characters: the first 8 bytes of a sha256 over every
    /// scanned `.zig` file's `rel`, size, modification time, status-change
    /// time and inode, sorted by `rel`. Editing, adding, removing or
    /// renaming a file changes it; a scan with no change keeps it. The
    /// generated root writes it into the table (see `rootgen.zig`). It does
    /// not cover `@embedFile` data, `.zig` helpers outside `script_dirs`,
    /// or SDK edits, so a stale export after only such an edit is not caught
    /// by the id comparison.
    build_id: [16]u8 = @splat('0'),
};

/// Each file's classification from earlier scans, so an unchanged file is
/// neither read nor parsed again. Owned by one caller; not thread-safe.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    /// Keyed by `rel`; keys are owned by the cache.
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Incremented by every scan; entries not seen by a scan are removed.
    epoch: u32 = 0,

    const Entry = struct {
        size: u64,
        mtime: i96,
        /// Status-change time where the OS has one: it also changes when a
        /// tool restores an old mtime, or a `chmod` makes the file unreadable.
        ctime: i96,
        inode: std.Io.File.INode,
        script: bool,
        epoch: u32,
    };

    /// A file modified less than this long before a scan is parsed but not
    /// stored, so it is parsed again on every scan until it is older. On file
    /// systems with coarse modification times, a second edit of the same size
    /// within the same tick keeps the mtime; an entry stored inside this window
    /// could then hide that edit for good ("racy git").
    pub const racy_ns: i96 = 2 * std.time.ns_per_s;

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.map.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: *const Cache) usize {
        return self.map.count();
    }

    /// Entries are stored only outside the racy window (see `store`), so a
    /// matching key is safe to trust.
    fn lookup(self: *Cache, rel: []const u8, st: std.Io.File.Stat) ?bool {
        const e = self.map.getPtr(rel) orelse return null;
        if (e.size != st.size or e.mtime != st.mtime.nanoseconds or
            e.ctime != st.ctime.nanoseconds or e.inode != st.inode) return null;
        e.epoch = self.epoch;
        return e.script;
    }

    /// Stores the result for `rel` only when the file was last modified at
    /// least `racy_ns` before this scan (`now`); otherwise drops any old entry.
    fn store(self: *Cache, rel: []const u8, st: std.Io.File.Stat, script: bool, now: i96) !void {
        if (now - st.mtime.nanoseconds < racy_ns) {
            if (self.map.fetchRemove(rel)) |kv| self.gpa.free(kv.key);
            return;
        }
        const gop = try self.map.getOrPut(self.gpa, rel);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, rel) catch |err| {
                self.map.removeByPtr(gop.key_ptr);
                return err;
            };
        }
        gop.value_ptr.* = .{
            .size = st.size,
            .mtime = st.mtime.nanoseconds,
            .ctime = st.ctime.nanoseconds,
            .inode = st.inode,
            .script = script,
            .epoch = self.epoch,
        };
    }

    /// Removes entries that the scan with the current epoch did not see.
    fn prune(self: *Cache) !void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.gpa);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.epoch != self.epoch) try stale.append(self.gpa, kv.key_ptr.*);
        }
        for (stale.items) |k| {
            _ = self.map.remove(k);
            self.gpa.free(k);
        }
    }
};

pub const default_script_dirs: []const []const u8 = &.{""};

const max_file_bytes = 16 * 1024 * 1024;

/// What `ScanResult.build_id` hashes for one file. A file that cannot be
/// stat'ed counts with zeros, so it still changes the id when it appears.
const Stamp = struct {
    rel: []const u8,
    size: u64 = 0,
    mtime: i96 = 0,
    ctime: i96 = 0,
    inode: u128 = 0,

    fn fromStat(rel: []const u8, st: ?std.Io.File.Stat) Stamp {
        const x = st orelse return .{ .rel = rel };
        return .{ .rel = rel, .size = x.size, .mtime = x.mtime.nanoseconds, .ctime = x.ctime.nanoseconds, .inode = @intCast(x.inode) };
    }

    fn fingerprint(self: Stamp) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.size));
        h.update(std.mem.asBytes(&self.mtime));
        h.update(std.mem.asBytes(&self.ctime));
        h.update(std.mem.asBytes(&self.inode));
        // 0 is reserved for "unknown".
        return h.final() | 1;
    }

    fn lessThan(_: void, x: Stamp, y: Stamp) bool {
        return std.mem.lessThan(u8, x.rel, y.rel);
    }
};

/// See `ScanResult.build_id`. Sorts `stamps`.
fn buildId(stamps: []Stamp) [16]u8 {
    std.mem.sort(Stamp, stamps, {}, Stamp.lessThan);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (stamps) |st| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, st.rel.len, .little);
        h.update(&len);
        h.update(st.rel);
        var buf: [8 + 16 + 16 + 16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], st.size, .little);
        std.mem.writeInt(i128, buf[8..24], st.mtime, .little);
        std.mem.writeInt(i128, buf[24..40], st.ctime, .little);
        std.mem.writeInt(u128, buf[40..56], st.inode, .little);
        h.update(&buf);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

const Scanner = struct {
    a: std.mem.Allocator,
    io: std.Io,
    project: std.Io.Dir,
    scripts: std.ArrayList(Script) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    walked: std.StringHashMapUnmanaged(void) = .empty,
    helper_list: std.ArrayList(Script) = .empty,
    cache: ?*Cache = null,
    /// One entry per scanned `.zig` file, for `ScanResult.build_id`.
    stamps: std.ArrayList(Stamp) = .empty,
    /// Wall-clock time at the start of the scan, for `Cache.racy_ns`.
    now: i96 = 0,
    parsed: u32 = 0,

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
        // Without a usable stat the file is read and parsed, and not cached.
        const st: ?std.Io.File.Stat = dir.statFile(self.io, name, .{}) catch null;
        const stamp: Stamp = .fromStat(rel, st);
        const fp: u64 = if (st != null) stamp.fingerprint() else 0;
        try self.stamps.append(self.a, stamp);
        if (self.cache) |c| if (st) |x| if (c.lookup(rel, x)) |script| return self.classify(rel, script, fp);
        const src = dir.readFileAllocOptions(self.io, name, self.a, .limited(max_file_bytes), .of(u8), 0) catch |err| {
            try self.problem(rel, "Could not read \"{s}\": {t}.", .{ rel, err });
            return;
        };
        self.parsed += 1;
        const script = try hasTopLevelExtends(self.a, src);
        // The stat was taken before the read: a write in between changes the
        // key, so the next scan reads the file again.
        if (self.cache) |c| if (st) |x| try c.store(rel, x, script, self.now);
        try self.classify(rel, script, fp);
    }

    fn classify(self: *Scanner, rel: []const u8, script: bool, fp: u64) !void {
        if (script) {
            try self.scripts.append(self.a, .{ .rel = rel, .fingerprint = fp });
        } else {
            try self.helper_list.append(self.a, .{ .rel = rel, .fingerprint = fp });
        }
    }

    fn problem(self: *Scanner, rel: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.a, .{ .rel = rel, .message = try std.fmt.allocPrint(self.a, fmt, args) });
    }
};

/// Scans each folder of `script_dirs` (project-relative, `/`-separated, `""` is
/// the project root). Entries are normalised first: `.` and empty parts are
/// dropped, so `./a//b/` means `a/b`. `error.InvalidScriptDir` when an entry is
/// absolute or contains `..`. Every file is read and parsed; see `scanCached`.
pub fn scan(
    a: std.mem.Allocator,
    io: std.Io,
    project: OsPath,
    script_dirs: []const []const u8,
) !ScanResult {
    return scanCached(a, io, project, script_dirs, null);
}

/// Like `scan`, but with a `cache` it reads and parses only files that are
/// new or changed since the last scan with the same cache (key: `rel`, size,
/// modification time, status-change time, inode), and files modified in the
/// `Cache.racy_ns` before a scan (those are never stored). The result is
/// the same as `scan`'s. Entries for files that were not seen are removed.
pub fn scanCached(
    a: std.mem.Allocator,
    io: std.Io,
    project: OsPath,
    script_dirs: []const []const u8,
    cache: ?*Cache,
) !ScanResult {
    for (script_dirs) |d| {
        if (std.mem.startsWith(u8, d, "/") or std.mem.indexOfScalar(u8, d, '\\') != null) return error.InvalidScriptDir;
        var parts = std.mem.splitScalar(u8, d, '/');
        while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return error.InvalidScriptDir;
    }
    var root = try std.Io.Dir.cwd().openDir(io, project.bytes, .{});
    defer root.close(io);
    var s: Scanner = .{ .a = a, .io = io, .project = root, .cache = cache };
    if (cache) |c| {
        c.epoch +%= 1;
        s.now = std.Io.Clock.real.now(io).nanoseconds;
    }
    for (script_dirs) |d| try s.walk(try normalizeDir(a, d));
    if (cache) |c| try c.prune();
    std.mem.sort(Script, s.scripts.items, {}, lessThan);
    std.mem.sort(Script, s.helper_list.items, {}, lessThan);
    try checkCase(&s);
    return .{
        .scripts = s.scripts.items,
        .helpers = @intCast(s.helper_list.items.len),
        .helper_paths = s.helper_list.items,
        .problems = s.problems.items,
        .parsed = s.parsed,
        .build_id = buildId(s.stamps.items),
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
    try testing.expectEqual(@as(usize, 4), res.helper_paths.len);
    try testing.expectEqualStrings("lib/util.zig", res.helper_paths[0].rel);
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

/// Sets the modification time of `sub` to 10 s ago, outside the cache's
/// coarse-mtime guard.
fn age(tmp: std.testing.TmpDir, sub: []const u8) !void {
    const now = std.Io.Clock.real.now(testing.io);
    const old: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - 10 * std.time.ns_per_s };
    try tmp.dir.setTimestamps(testing.io, sub, .{ .modify_timestamp = .{ .new = old } });
}

test "build id changes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "a.zig", "pub const extends = \"Node\";\n");
    try put(tmp, "lib/h.zig", "pub fn f() void {}\n");
    const project = try tmpProject(tmp, a);
    var cache: Cache = .init(testing.allocator);
    defer cache.deinit();

    const r1 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    for (r1.build_id) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));

    // Touching nothing keeps it, with or without the cache.
    const r2 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqualStrings(&r1.build_id, &r2.build_id);
    const r2b = try scan(a, testing.io, project, default_script_dirs);
    try testing.expectEqualStrings(&r1.build_id, &r2b.build_id);

    // Editing one file (here a helper, with the same size) changes it.
    try put(tmp, "lib/h.zig", "pub fn g() void {}\n");
    const r3 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expect(!std.mem.eql(u8, &r2.build_id, &r3.build_id));

    // So do a new file and a removed one.
    try put(tmp, "b.zig", "pub const extends = \"Node\";\n");
    const r4 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expect(!std.mem.eql(u8, &r3.build_id, &r4.build_id));
    try tmp.dir.deleteFile(testing.io, "b.zig");
    const r5 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expect(!std.mem.eql(u8, &r4.build_id, &r5.build_id));
}

test "scan cache parses only changed files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "a.zig", "pub const extends = \"Node\";\n");
    try put(tmp, "b.zig", "pub const extends = \"Node\";\n");
    try put(tmp, "lib/h.zig", "pub fn f() void {}\n");
    for ([_][]const u8{ "a.zig", "b.zig", "lib/h.zig" }) |f| try age(tmp, f);
    const project = try tmpProject(tmp, a);

    var cache: Cache = .init(testing.allocator);
    defer cache.deinit();

    const r1 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(u32, 3), r1.parsed);
    try testing.expectEqual(@as(usize, 2), r1.scripts.len);

    // Nothing changed: nothing is read or parsed, and the result is the same.
    const r2 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(u32, 0), r2.parsed);
    try testing.expectEqual(@as(usize, 2), r2.scripts.len);
    try testing.expectEqualStrings("a.zig", r2.scripts[0].rel);
    try testing.expectEqualStrings("b.zig", r2.scripts[1].rel);
    try testing.expectEqual(@as(u32, 1), r2.helpers);

    // An edited file is parsed again; `b.zig` stops being a script.
    try put(tmp, "b.zig", "pub fn g() void {}\n");
    const r3 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(u32, 1), r3.parsed);
    try testing.expectEqual(@as(usize, 1), r3.scripts.len);
    try testing.expectEqual(@as(u32, 2), r3.helpers);

    // A file changed in the last 2 s is parsed on every scan (coarse mtime).
    const r4 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(u32, 1), r4.parsed);

    // A deleted file leaves the cache.
    try tmp.dir.deleteFile(testing.io, "a.zig");
    try age(tmp, "b.zig");
    const r5 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(usize, 0), r5.scripts.len);
    try testing.expectEqual(@as(usize, 2), cache.count());

    // Without a cache every file is parsed.
    const r6 = try scan(a, testing.io, project, default_script_dirs);
    try testing.expectEqual(@as(u32, 2), r6.parsed);
}

test "scan cache never trusts an entry stored inside the guard window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Modified 1.5 s ago: inside the 2 s guard when the first scan reads it.
    const now = std.Io.Clock.real.now(testing.io);
    const mtime: std.Io.Timestamp = .{ .nanoseconds = now.nanoseconds - 1500 * std.time.ns_per_ms };
    try put(tmp, "s.zig", "pub const extends = \"Node\";\n");
    try tmp.dir.setTimestamps(testing.io, "s.zig", .{ .modify_timestamp = .{ .new = mtime } });
    const project = try tmpProject(tmp, a);

    var cache: Cache = .init(testing.allocator);
    defer cache.deinit();
    const r1 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(usize, 1), r1.scripts.len);
    try testing.expectEqual(@as(usize, 0), cache.count());

    // A same-size edit in the same mtime tick (the mtime is restored), then a
    // scan after the guard has expired: the file must be parsed again.
    try put(tmp, "s.zig", "pub const extendz = \"Node\";\n");
    try tmp.dir.setTimestamps(testing.io, "s.zig", .{ .modify_timestamp = .{ .new = mtime } });
    try testing.io.sleep(.fromMilliseconds(700), .awake);
    const r2 = try scanCached(a, testing.io, project, default_script_dirs, &cache);
    try testing.expectEqual(@as(u32, 1), r2.parsed);
    try testing.expectEqual(@as(usize, 0), r2.scripts.len);
}

test "file fingerprints change with the file and only then" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put(tmp, "a.zig", "pub const extends = \"Node\";\n");
    try put(tmp, "lib/h.zig", "pub fn f() void {}\n");
    const project = try tmpProject(tmp, a);

    const r1 = try scan(a, testing.io, project, default_script_dirs);
    const r2 = try scan(a, testing.io, project, default_script_dirs);
    try testing.expect(r1.scripts[0].fingerprint != 0 and r1.helper_paths[0].fingerprint != 0);
    try testing.expectEqual(r1.scripts[0].fingerprint, r2.scripts[0].fingerprint);
    try testing.expectEqual(r1.helper_paths[0].fingerprint, r2.helper_paths[0].fingerprint);

    try put(tmp, "lib/h.zig", "pub fn g() void {}\n");
    const r3 = try scan(a, testing.io, project, default_script_dirs);
    try testing.expectEqual(r1.scripts[0].fingerprint, r3.scripts[0].fingerprint);
    try testing.expect(r1.helper_paths[0].fingerprint != r3.helper_paths[0].fingerprint);
}
