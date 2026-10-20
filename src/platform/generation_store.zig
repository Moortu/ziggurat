//! Generation store (L1): versioned copies of the compiled library. The
//! compiler's output is copied into `gen/<n>/` before anything loads it, so a
//! running game keeps its generation while a newer build replaces the output.
//!
//! Layout under `root`: `store.lock`, `gen/<n>/<libName>`, `gen/<n>/.lock`.
//! `stage` and `sweep` hold `store.lock` exclusive. A running game pins a
//! generation by holding `gen/<n>/.lock` shared (`pin`); `sweep` deletes a
//! generation only when it can take that lock exclusive without waiting.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const elf = @import("elf.zig");
const lock = @import("lock.zig");
const testing_support = @import("testing_support.zig");
const Allocator = std.mem.Allocator;
const OsPath = path.OsPath;
const Dir = std.Io.Dir;

pub const FileLock = lock.FileLock;

/// Paths are allocated; free them with `deinit`.
pub const Generation = struct {
    n: u32,
    dir: OsPath,
    lib: OsPath,

    pub fn deinit(self: Generation, a: Allocator) void {
        a.free(self.dir.bytes);
        a.free(self.lib.bytes);
    }
};

pub const Caps = struct { max_count: u32 = 8, max_bytes: u64 = 1 << 30 };

pub const SweepReport = struct {
    /// Generations removed by this sweep.
    deleted: u32,
    /// Generations left on disk (newest, pinned, and those within the caps).
    kept: u32,
    /// Total size of the files in the kept generations.
    bytes_kept: u64,
    /// Unpinned generations whose delete failed; they count as kept.
    failed: u32 = 0,
};

const store_lock_timeout_ms = 30_000;
const pin_timeout_ms = 1_000;

fn isElfTarget(os: std.Target.Os.Tag) bool {
    return switch (os) {
        .windows, .macos, .ios, .tvos, .watchos, .visionos => false,
        else => true,
    };
}

pub const GenerationStore = struct {
    a: Allocator,
    io: std.Io,
    root: OsPath,
    os: std.Target.Os.Tag,
    stem: []const u8,
    caps: Caps,
    /// Lowest number the next `stage` may use; raised by `remove`, so a
    /// removed generation's number (and its library path, which a process
    /// may have loaded once) is never reused by this store.
    min_next: u64 = 1,

    /// Borrows `root` and `stem`; both must outlive the store. Creates nothing
    /// on disk until the first `stage`.
    pub fn init(a: Allocator, io: std.Io, root: OsPath, os: std.Target.Os.Tag, stem: []const u8, caps: Caps) GenerationStore {
        return .{ .a = a, .io = io, .root = root, .os = os, .stem = stem, .caps = caps };
    }

    /// Copies `built` (never moves it) to `gen/<n>/<libName>` where n is the
    /// highest existing generation plus one, and copies each of `extras` into
    /// the same folder under its own file name. On an ELF target the built file
    /// is checked with `elf.checkComplete` first. On any error no `gen/<n>`
    /// folder is left behind. The caller frees the result with `deinit`.
    pub fn stage(self: *GenerationStore, built: OsPath, extras: []const OsPath) !Generation {
        var diag: [256]u8 = undefined;
        return self.stageDiag(built, extras, &diag);
    }

    /// Like `stage`, and on any failure `diag` holds one NUL-terminated
    /// sentence (read it with `elf.diagText`): the ELF check's text, or a
    /// generic sentence naming the error and the built file.
    pub fn stageDiag(self: *GenerationStore, built: OsPath, extras: []const OsPath, diag: *[256]u8) !Generation {
        @memset(diag, 0);
        return self.stageInner(built, extras, diag) catch |e| {
            if (diag[0] == 0)
                elf.setDiag(diag, "Staging {s} failed: {s}.", .{ built.bytes, @errorName(e) });
            return e;
        };
    }

    fn stageInner(self: *GenerationStore, built: OsPath, extras: []const OsPath, diag: *[256]u8) !Generation {
        const a = self.a;
        const io = self.io;
        const gen_root = try path.join(a, self.root, &.{"gen"});
        defer a.free(gen_root.bytes);
        try Dir.cwd().createDirPath(io, gen_root.bytes);

        var store_lock = try self.lockStore(.exclusive);
        defer store_lock.release();

        const gens = try self.listGens(gen_root);
        defer a.free(gens);
        const after_last: u32 = if (gens.len == 0) 1 else std.math.add(u32, gens[gens.len - 1], 1) catch {
            elf.setDiag(diag, "The generation numbers under {s} are used up.", .{gen_root.bytes});
            return error.GenerationOverflow;
        };
        const n = std.math.cast(u32, @max(after_last, self.min_next)) orelse {
            elf.setDiag(diag, "The generation numbers under {s} are used up.", .{gen_root.bytes});
            return error.GenerationOverflow;
        };

        var nb: [16]u8 = undefined;
        const n_name = try std.fmt.bufPrint(&nb, "{d}", .{n});
        const dir = try path.join(a, gen_root, &.{n_name});
        errdefer a.free(dir.bytes);
        try Dir.cwd().createDir(io, dir.bytes, .default_dir);
        errdefer Dir.cwd().deleteTree(io, dir.bytes) catch {};

        var name_buf: [256]u8 = undefined;
        const lib_name = try path.libName(&name_buf, self.os, self.stem, n);
        const lib = try path.join(a, dir, &.{lib_name});
        errdefer a.free(lib.bytes);
        try copyFile(io, built.bytes, lib.bytes);
        if (isElfTarget(self.os)) {
            // Check the exact bytes that will be loaded, not the original.
            const f = try Dir.cwd().openFile(io, lib.bytes, .{});
            defer f.close(io);
            try elf.checkComplete(io, f, diag);
        }

        for (extras) |extra| {
            const dst = try path.join(a, dir, &.{baseName(extra.bytes)});
            defer a.free(dst.bytes);
            try copyFile(io, extra.bytes, dst.bytes);
        }

        const lock_path = try path.join(a, dir, &.{".lock"});
        defer a.free(lock_path.bytes);
        const lf = try Dir.cwd().createFile(io, lock_path.bytes, .{ .truncate = false });
        lf.close(io);

        return .{ .n = n, .dir = dir, .lib = lib };
    }

    /// Deletes generation `n`, which nothing may have pinned (the build
    /// service removes a generation it staged but never handed out), and
    /// keeps later `stage` calls from reusing its number. `error.Pinned`
    /// when it is pinned after all; it then stays on disk.
    pub fn remove(self: *GenerationStore, n: u32) !void {
        var store_lock = try self.lockStore(.exclusive);
        defer store_lock.release();
        self.min_next = @max(self.min_next, @as(u64, n) + 1);
        if (!try self.deleteIfUnpinned(n)) return error.Pinned;
    }

    /// Takes a shared lock on `gen/<n>/.lock`. Hold it while the generation is
    /// loaded; `sweep` skips a generation that is pinned. Release with
    /// `FileLock.release`. `error.FileNotFound` when `gen/<n>` does not exist.
    pub fn pin(self: *GenerationStore, n: u32) !FileLock {
        const a = self.a;
        // Wait out a running sweep, so a generation cannot vanish between the
        // check and the lock.
        var store_lock = try self.lockStore(.shared);
        defer store_lock.release();
        const lock_path = try self.genLockPath(n);
        defer a.free(lock_path.bytes);
        return FileLock.acquire(self.io, lock_path, .shared, pin_timeout_ms);
    }

    /// Keeps the newest `caps.max_count` generations, then drops older ones
    /// (oldest first) while total bytes exceed `caps.max_bytes`. Never deletes
    /// the newest generation or a pinned one.
    pub fn sweep(self: *GenerationStore) !SweepReport {
        const a = self.a;
        const io = self.io;
        const gen_root = try path.join(a, self.root, &.{"gen"});
        defer a.free(gen_root.bytes);
        try Dir.cwd().createDirPath(io, gen_root.bytes);

        var store_lock = try self.lockStore(.exclusive);
        defer store_lock.release();

        const gens = try self.listGens(gen_root);
        defer a.free(gens);
        const sizes = try a.alloc(u64, gens.len);
        defer a.free(sizes);
        var total: u64 = 0;
        for (gens, sizes) |n, *sz| {
            sz.* = try self.genBytes(n);
            total += sz.*;
        }

        const over_count: usize = if (gens.len > self.caps.max_count) gens.len - self.caps.max_count else 0;
        var deleted: u32 = 0;
        var failed: u32 = 0;
        // The last entry is the newest: never a candidate.
        const candidates = if (gens.len == 0) 0 else gens.len - 1;
        for (gens[0..candidates], sizes[0..candidates], 0..) |n, sz, i| {
            if (i >= over_count and total <= self.caps.max_bytes) continue;
            const gone = self.deleteIfUnpinned(n) catch {
                failed += 1;
                continue;
            };
            if (gone) {
                deleted += 1;
                total -= sz;
            }
        }
        return .{
            .deleted = deleted,
            .kept = @intCast(gens.len - deleted),
            .bytes_kept = total,
            .failed = failed,
        };
    }

    fn lockStore(self: *GenerationStore, mode: lock.Mode) !FileLock {
        const p = try path.join(self.a, self.root, &.{"store.lock"});
        defer self.a.free(p.bytes);
        return FileLock.acquire(self.io, p, mode, store_lock_timeout_ms);
    }

    fn genLockPath(self: *GenerationStore, n: u32) !OsPath {
        var nb: [16]u8 = undefined;
        const n_name = try std.fmt.bufPrint(&nb, "{d}", .{n});
        return path.join(self.a, self.root, &.{ "gen", n_name, ".lock" });
    }

    fn genDirPath(self: *GenerationStore, n: u32) !OsPath {
        var nb: [16]u8 = undefined;
        const n_name = try std.fmt.bufPrint(&nb, "{d}", .{n});
        return path.join(self.a, self.root, &.{ "gen", n_name });
    }

    /// Generation numbers found under `gen_root`, ascending. Caller frees.
    fn listGens(self: *GenerationStore, gen_root: OsPath) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(self.a);
        var d = Dir.cwd().openDir(self.io, gen_root.bytes, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return out.toOwnedSlice(self.a),
            else => return e,
        };
        defer d.close(self.io);
        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            const n = std.fmt.parseInt(u32, entry.name, 10) catch continue;
            // Only canonical names ("7", not "007" or "+7").
            var nb: [16]u8 = undefined;
            const canon = std.fmt.bufPrint(&nb, "{d}", .{n}) catch continue;
            if (!std.mem.eql(u8, canon, entry.name)) continue;
            try out.append(self.a, n);
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        return out.toOwnedSlice(self.a);
    }

    /// Sum of the sizes of the files directly inside `gen/<n>`.
    fn genBytes(self: *GenerationStore, n: u32) !u64 {
        const dp = try self.genDirPath(n);
        defer self.a.free(dp.bytes);
        var d = try Dir.cwd().openDir(self.io, dp.bytes, .{ .iterate = true });
        defer d.close(self.io);
        var total: u64 = 0;
        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            total += (try d.statFile(self.io, entry.name, .{})).size;
        }
        return total;
    }

    /// Deletes `gen/<n>` when its `.lock` can be taken exclusive without
    /// waiting. Returns false when it is pinned.
    fn deleteIfUnpinned(self: *GenerationStore, n: u32) !bool {
        const lp = try self.genLockPath(n);
        defer self.a.free(lp.bytes);
        const dp = try self.genDirPath(n);
        defer self.a.free(dp.bytes);
        var l = FileLock.acquire(self.io, lp, .exclusive, 0) catch |e| switch (e) {
            error.Timeout => return false,
            else => return e,
        };
        if (builtin.os.tag == .windows) {
            // Windows cannot delete a file that is still open. `store.lock`
            // is held exclusive, so no `pin` can slip in.
            l.release();
            try Dir.cwd().deleteTree(self.io, dp.bytes);
        } else {
            defer l.release();
            try Dir.cwd().deleteTree(self.io, dp.bytes);
        }
        return true;
    }
};

fn baseName(p: []const u8) []const u8 {
    const i = if (builtin.os.tag == .windows)
        std.mem.lastIndexOfAny(u8, p, "/\\")
    else
        std.mem.lastIndexOfScalar(u8, p, '/');
    return if (i) |x| p[x + 1 ..] else p;
}

/// Copies a file. On Linux, holes are kept (`SEEK_DATA`/`SEEK_HOLE`); anywhere
/// else, or when the file system cannot report holes, it is a plain copy.
fn copyFile(io: std.Io, src_path: []const u8, dst_path: []const u8) !void {
    const src = try Dir.cwd().openFile(io, src_path, .{});
    defer src.close(io);
    const dst = try Dir.cwd().createFile(io, dst_path, .{});
    defer dst.close(io);
    const size = try src.length(io);
    if (builtin.os.tag == .linux) {
        if (try copySparse(io, src, dst, size)) return;
    }
    try copyRange(io, src, dst, 0, size);
    try dst.setLength(io, size);
}

/// Returns false when the file system does not support hole seeking (nothing
/// has been written then).
fn copySparse(io: std.Io, src: std.Io.File, dst: std.Io.File, size: u64) !bool {
    const linux = std.os.linux;
    const seek_data = 3;
    const seek_hole = 4;
    var pos: u64 = 0;
    var first = true;
    while (pos < size) : (first = false) {
        const rc = linux.lseek(src.handle, @intCast(pos), seek_data);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NXIO => break, // no data at or after pos
            .INVAL, .OPNOTSUPP => if (first) return false else return error.Unexpected,
            else => return error.Unexpected,
        }
        const data_start: u64 = rc;
        const rc2 = linux.lseek(src.handle, @intCast(data_start), seek_hole);
        if (linux.errno(rc2) != .SUCCESS) return error.Unexpected;
        const data_end: u64 = @min(rc2, size);
        try copyRange(io, src, dst, data_start, data_end);
        pos = data_end;
    }
    try dst.setLength(io, size);
    return true;
}

fn copyRange(io: std.Io, src: std.Io.File, dst: std.Io.File, start: u64, end: u64) !void {
    var buf: [64 * 1024]u8 = undefined;
    var off = start;
    while (off < end) {
        const want: usize = @intCast(@min(buf.len, end - off));
        const n = try src.readPositionalAll(io, buf[0..want], off);
        if (n == 0) return error.Unexpected;
        try dst.writePositionalAll(io, buf[0..n], off);
        off += n;
    }
}

const os_tag = builtin.os.tag;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: OsPath,
    base: [:0]u8,

    fn init(a: Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        errdefer a.free(base);
        const root = try path.join(a, OsPath.fromTrusted(base), &.{"zig-store"});
        return .{ .tmp = tmp, .root = root, .base = base };
    }
    fn deinit(f: *Fixture, a: Allocator) void {
        a.free(f.root.bytes);
        a.free(f.base);
        f.tmp.cleanup();
    }
    fn p(f: *Fixture, a: Allocator, parts: []const []const u8) !OsPath {
        return path.join(a, OsPath.fromTrusted(f.base), parts);
    }
    fn store(f: *Fixture, a: Allocator, caps: Caps) GenerationStore {
        return GenerationStore.init(a, std.testing.io, f.root, os_tag, "demo", caps);
    }
    /// A minimal valid ELF64 header (no program or section headers) followed
    /// by `payload` bytes.
    fn writeElf(f: *Fixture, name: []const u8, payload: []const u8) !void {
        var buf: [64]u8 = @splat(0);
        @memcpy(buf[0..4], "\x7fELF");
        buf[4] = 2;
        buf[5] = 1;
        buf[6] = 1;
        var file = try f.tmp.dir.createFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &buf, 0);
        try file.writePositionalAll(std.testing.io, payload, 64);
    }
    fn exists(f: *Fixture, a: Allocator, rel: []const []const u8) !bool {
        const q = try path.join(a, f.root, rel);
        defer a.free(q.bytes);
        std.Io.Dir.cwd().access(std.testing.io, q.bytes, .{}) catch return false;
        return true;
    }
};

fn stageOne(a: Allocator, s: *GenerationStore, built: OsPath) !u32 {
    const g = try s.stage(built, &.{});
    defer {
        a.free(g.dir.bytes);
        a.free(g.lib.bytes);
    }
    return g.n;
}

fn rmGen(a: Allocator, f: *Fixture, n: u32) !void {
    var nb: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&nb, "{d}", .{n});
    const q = try path.join(a, f.root, &.{ "gen", name });
    defer a.free(q.bytes);
    try std.Io.Dir.cwd().deleteTree(std.testing.io, q.bytes);
}

fn genExists(a: Allocator, f: *Fixture, n: u32) !bool {
    var nb: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&nb, "{d}", .{n});
    return f.exists(a, &.{ "gen", name });
}

test "stage numbers" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    try std.testing.expectEqual(@as(u32, 1), try stageOne(a, &s, built));
    try std.testing.expectEqual(@as(u32, 2), try stageOne(a, &s, built));
    try rmGen(a, &f, 2);
    try std.testing.expectEqual(@as(u32, 2), try stageOne(a, &s, built));
    try rmGen(a, &f, 1);
    try std.testing.expectEqual(@as(u32, 3), try stageOne(a, &s, built));
}

test "remove deletes and never reuses the number" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    try std.testing.expectEqual(@as(u32, 1), try stageOne(a, &s, built));
    try std.testing.expectEqual(@as(u32, 2), try stageOne(a, &s, built));
    try s.remove(2);
    try std.testing.expect(!try genExists(a, &f, 2));
    try std.testing.expectEqual(@as(u32, 3), try stageOne(a, &s, built));
    // Past the last number, stage refuses instead of reusing one.
    const keep = s.min_next;
    s.min_next = @as(u64, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.GenerationOverflow, s.stage(built, &.{}));
    s.min_next = keep;
    // A pinned generation is kept.
    var l = try s.pin(3);
    try std.testing.expectError(error.Pinned, s.remove(3));
    l.release();
    try std.testing.expect(try genExists(a, &f, 3));
}

test "stage copies, never moves" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "payload bytes");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    const extra = try f.p(a, &.{"extra.txt"});
    defer a.free(extra.bytes);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "extra.txt", .data = "xtra" });
    var s = f.store(a, .{});
    const g = try s.stage(built, &.{extra});
    defer a.free(g.dir.bytes);
    defer a.free(g.lib.bytes);
    try std.testing.expectEqual(@as(u32, 1), g.n);
    const orig = try f.tmp.dir.readFileAlloc(io, "built.so", a, .limited(1 << 20));
    defer a.free(orig);
    const copy = try std.Io.Dir.cwd().readFileAlloc(io, g.lib.bytes, a, .limited(1 << 20));
    defer a.free(copy);
    try std.testing.expectEqualSlices(u8, orig, copy);
    var nbuf: [64]u8 = undefined;
    const lib_name = try path.libName(&nbuf, os_tag, "demo", 1);
    try std.testing.expect(std.mem.endsWith(u8, g.lib.bytes, lib_name));
    const ex = try path.join(a, g.dir, &.{"extra.txt"});
    defer a.free(ex.bytes);
    const exb = try std.Io.Dir.cwd().readFileAlloc(io, ex.bytes, a, .limited(1024));
    defer a.free(exb);
    try std.testing.expectEqualStrings("xtra", exb);
    try std.testing.expect(try f.exists(a, &.{ "gen", "1", ".lock" }));
}

test "stage keeps holes" {
    if (os_tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "");
    {
        var file = try f.tmp.dir.openFile(io, "built.so", .{ .mode = .read_write });
        defer file.close(io);
        const block: [4096]u8 = @splat(0xAB);
        try file.writePositionalAll(io, &block, 32 << 20);
        try file.setLength(io, 64 << 20);
    }
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    const g = try s.stage(built, &.{});
    defer a.free(g.dir.bytes);
    defer a.free(g.lib.bytes);
    const file = try std.Io.Dir.cwd().openFile(io, g.lib.bytes, .{});
    defer file.close(io);
    try std.testing.expectEqual(@as(u64, 64 << 20), try file.length(io));
    var stx: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(file.handle, "", std.os.linux.AT.EMPTY_PATH, .{ .BLOCKS = true }, &stx);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(rc));
    const allocated: u64 = stx.blocks * 512;
    try std.testing.expect(allocated < (1 << 20));
    // The data block survived at its offset.
    var back: [4096]u8 = undefined;
    _ = try file.readPositionalAll(io, &back, 32 << 20);
    try std.testing.expect(std.mem.allEqual(u8, &back, 0xAB));
}

test "pin blocks sweep" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_count = 3 });
    for (0..10) |_| _ = try stageOne(a, &s, built);
    var pinned = try s.pin(2);
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 6), rep.deleted);
    try std.testing.expectEqual(@as(u32, 4), rep.kept);
    for ([_]u32{ 2, 8, 9, 10 }) |n| try std.testing.expect(try genExists(a, &f, n));
    for ([_]u32{ 1, 3, 4, 5, 6, 7 }) |n| try std.testing.expect(!try genExists(a, &f, n));
    pinned.release();
    // Unpinned now: a second sweep drops gen 2.
    const rep2 = try s.sweep();
    try std.testing.expectEqual(@as(u32, 1), rep2.deleted);
    try std.testing.expectEqual(@as(u32, 3), rep2.kept);
}

test "a game's pin keeps its generation from an editor's sweep" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    // The editor that staged the generations, and a game process with a
    // store of its own on the same folder (a separate lock description).
    var editor = f.store(a, .{ .max_count = 1 });
    for (0..4) |_| _ = try stageOne(a, &editor, built);
    var game = f.store(a, .{});
    var pinned = try game.pin(2);
    const rep = try editor.sweep();
    try std.testing.expectEqual(@as(u32, 2), rep.deleted);
    try std.testing.expect(try genExists(a, &f, 2));
    try std.testing.expect(try genExists(a, &f, 4));
    try std.testing.expectError(error.Pinned, editor.remove(2));
    pinned.release();
    const rep2 = try editor.sweep();
    try std.testing.expectEqual(@as(u32, 1), rep2.deleted);
    try std.testing.expect(!try genExists(a, &f, 2));
}

test "pin never follows a linked lock file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    _ = try stageOne(a, &s, built);
    const lock_file = try path.join(a, f.root, &.{ "gen", "1", ".lock" });
    defer a.free(lock_file.bytes);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, lock_file.bytes);
    const target = try f.p(a, &.{"elsewhere"});
    defer a.free(target.bytes);
    try std.Io.Dir.cwd().symLink(std.testing.io, target.bytes, lock_file.bytes, .{});
    try std.testing.expectError(error.SymLink, s.pin(1));
    // Nothing was created at the link's target.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, target.bytes, .{}));
}

test "sweep keeps newest" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_bytes = 1 });
    for (0..3) |_| _ = try stageOne(a, &s, built);
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 2), rep.deleted);
    try std.testing.expectEqual(@as(u32, 1), rep.kept);
    try std.testing.expect(try genExists(a, &f, 3));
    try std.testing.expect(!try genExists(a, &f, 1));
}

test "store_lock_blocks_second_writer" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try std.Io.Dir.cwd().createDirPath(io, f.root.bytes);
    const lp = try path.join(a, f.root, &.{"store.lock"});
    defer a.free(lp.bytes);
    var first = try FileLock.acquire(io, lp, .exclusive, 100);
    defer first.release();
    const t0 = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Timeout, FileLock.acquire(io, lp, .exclusive, 200));
    try std.testing.expect(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1000);
}

test "stage refuses a non-ELF output" {
    if (os_tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "bad.so", .data = "this is not an elf file at all, not even close, no" });
    const built = try f.p(a, &.{"bad.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    try std.testing.expectError(error.NotElf64, s.stage(built, &.{}));
    try std.testing.expect(!try genExists(a, &f, 1));
}

test "stageDiag leaves a sentence for a non-ELF output" {
    if (os_tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.so", .data = "not an elf, just text, long enough to matter here" });
    const built = try f.p(a, &.{"bad.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.NotElf64, s.stageDiag(built, &.{}, &diag));
    try std.testing.expect(elf.diagText(&diag).len > 0);
    try std.testing.expect(!try genExists(a, &f, 1));
}

test "stage with a missing extra leaves no folder" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    const missing = try f.p(a, &.{"nope.txt"});
    defer a.free(missing.bytes);
    var s = f.store(a, .{});
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, s.stageDiag(built, &.{missing}, &diag));
    try std.testing.expect(elf.diagText(&diag).len > 0);
    try std.testing.expect(!try genExists(a, &f, 1));
}

test "pin of a missing generation" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{});
    _ = try stageOne(a, &s, built);
    try std.testing.expectError(error.FileNotFound, s.pin(7));
    try std.testing.expect(!try genExists(a, &f, 7));
}

test "sweep by bytes keeps a pinned oldest" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_bytes = 1 });
    for (0..4) |_| _ = try stageOne(a, &s, built);
    var pinned = try s.pin(1);
    defer pinned.release();
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 2), rep.deleted);
    try std.testing.expectEqual(@as(u32, 0), rep.failed);
    try std.testing.expect(try genExists(a, &f, 1));
    try std.testing.expect(!try genExists(a, &f, 2));
    try std.testing.expect(!try genExists(a, &f, 3));
    try std.testing.expect(try genExists(a, &f, 4));
}

test "folders with non-canonical names are ignored" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeElf("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_count = 1 });
    _ = try stageOne(a, &s, built);
    const odd = try path.join(a, f.root, &.{ "gen", "007" });
    defer a.free(odd.bytes);
    try std.Io.Dir.cwd().createDirPath(io, odd.bytes);
    const big = try path.join(a, f.root, &.{ "gen", "99999999999" });
    defer a.free(big.bytes);
    try std.Io.Dir.cwd().createDirPath(io, big.bytes);
    try std.testing.expectEqual(@as(u32, 2), try stageOne(a, &s, built));
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 1), rep.deleted);
    try std.testing.expectEqual(@as(u32, 0), rep.failed);
}
