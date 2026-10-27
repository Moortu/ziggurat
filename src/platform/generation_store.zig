//! Generation store (L1): versioned copies of the compiled library. The
//! compiler's output is copied into `gen/<n>/` before anything loads it, so a
//! running game keeps its generation while a newer build replaces the output.
//!
//! Layout under `root`: `store.lock`, `gen/<n>/<libName>`, `gen/<n>/.lock`.
//! `stage` and `sweep` hold `store.lock` exclusive. A running game pins a
//! generation by holding `gen/<n>/.lock` shared (`pin`); `stage` returns
//! the new generation already pinned, so it survives every sweep until its
//! user has loaded it; `sweep` deletes a generation only when it can take
//! that lock exclusive without waiting, and pinned generations do not
//! count toward the byte cap.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const elf = @import("elf.zig");
const pe = @import("pe.zig");
const macho = @import("macho.zig");
const lock = @import("lock.zig");
const testing_support = @import("testing_support.zig");
const Allocator = std.mem.Allocator;
const OsPath = path.OsPath;
const Dir = std.Io.Dir;

pub const FileLock = lock.FileLock;

/// The folder under the store root where generations go that a sweep could
/// not delete (Windows: a loaded DLL); each sweep deletes what it can there.
pub const trash_dir = ".trash";

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

/// A generation `stage` just made, with a shared lock on its `.lock`
/// (what `pin` returns). Free `gen` with `deinit`; release `pin` once the
/// generation is loaded and pinned elsewhere, or not needed.
pub const Staged = struct {
    gen: Generation,
    pin: FileLock,
};

/// Generation sizes are allocated bytes (`allocatedBytes`), not apparent
/// sizes: a staged library keeps the holes of the compiler's sparse output.
pub const Caps = struct {
    /// The count above which a sweep deletes the oldest unpinned generations.
    /// Pinned generations count toward it (they are never deleted), so with
    /// many pinned builds fewer unpinned ones stay.
    max_count: u32 = 8,
    /// The most allocated bytes of unpinned generations a sweep keeps
    /// (pinned ones do not count).
    max_bytes: u64 = 1 << 30,
};

/// The bytes `file` occupies on disk. On Linux that is the allocated block
/// count (`statx` blocks, 512 bytes each), so the holes of a sparse file do
/// not count. Elsewhere, and on a Linux file system whose `statx` reports no
/// block count, it is the apparent size (`File.stat().size`): the
/// allocated size on Windows and macOS is not measured yet (planned with
/// the other platform work).
pub fn allocatedBytes(io: std.Io, file: std.Io.File) !u64 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stx: linux.Statx = undefined;
        const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .BLOCKS = true }, &stx);
        if (linux.errno(rc) == .SUCCESS and stx.mask.BLOCKS) return stx.blocks * 512;
    }
    return (try file.stat(io)).size;
}

/// `allocatedBytes` of the file at `p`.
pub fn allocatedBytesOfPath(io: std.Io, p: OsPath) !u64 {
    const file = try Dir.cwd().openFile(io, p.bytes, .{});
    defer file.close(io);
    return allocatedBytes(io, file);
}

pub const SweepReport = struct {
    /// Generations removed by this sweep.
    deleted: u32,
    /// Generations left on disk (newest, pinned, and those within the caps).
    kept: u32,
    /// Total allocated size of the files in the kept generations.
    bytes_kept: u64,
    /// Generations whose pin could not be checked (kept as if pinned) plus
    /// unpinned generations whose delete failed; they count as kept.
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
    /// the same folder under its own file name. The staged copy is checked
    /// with `elf.checkComplete` on an ELF target, with
    /// `pe.checkCompleteDiag` on Windows and with `macho.checkCompleteDiag`
    /// on macOS. On any error no `gen/<n>`
    /// folder is left behind. The new generation comes back pinned
    /// (`Staged.pin`, taken before `store.lock` is released), so no sweep can
    /// delete it before its user loads it (spec risk 20). The caller frees
    /// `Staged.gen` with `deinit` and releases `Staged.pin`.
    pub fn stage(self: *GenerationStore, built: OsPath, extras: []const OsPath) !Staged {
        var diag: [256]u8 = undefined;
        return self.stageDiag(built, extras, &diag);
    }

    /// Like `stage`, and on any failure `diag` holds one NUL-terminated
    /// sentence (read it with `elf.diagText`): the ELF, PE or Mach-O check's text, or a
    /// generic sentence naming the error and the built file.
    pub fn stageDiag(self: *GenerationStore, built: OsPath, extras: []const OsPath, diag: *[256]u8) !Staged {
        @memset(diag, 0);
        return self.stageInner(built, extras, diag) catch |e| {
            if (diag[0] == 0)
                elf.setDiag(diag, "Staging {s} failed: {s}.", .{ built.bytes, @errorName(e) });
            return e;
        };
    }

    fn stageInner(self: *GenerationStore, built: OsPath, extras: []const OsPath, diag: *[256]u8) !Staged {
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
        } else if (self.os == .windows) {
            const bytes = try Dir.cwd().readFileAlloc(io, lib.bytes, a, .unlimited);
            defer a.free(bytes);
            try pe.checkCompleteDiag(bytes, diag);
        } else if (self.os.isDarwin()) {
            const bytes = try Dir.cwd().readFileAlloc(io, lib.bytes, a, .unlimited);
            defer a.free(bytes);
            try macho.checkCompleteDiag(bytes, diag);
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
        // `store.lock` is held exclusive, so `pin` would wait for it; take the
        // shared lock directly. Nothing else knows the generation yet.
        const pin_lock = try FileLock.acquire(io, lock_path, .shared, pin_timeout_ms);

        return .{ .gen = .{ .n = n, .dir = dir, .lib = lib }, .pin = pin_lock };
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

    /// Keeps the newest `caps.max_count` generations (pinned ones count),
    /// then drops older unpinned ones (oldest first) while the unpinned
    /// generations' total allocated bytes exceed `caps.max_bytes`. Pinned
    /// generations are in use (loaded by an editor or a game, or staged and
    /// not loaded yet) and deleting others frees none of their bytes, so
    /// they do not count toward `max_bytes` (spec risk 20). Never deletes
    /// the newest generation or a pinned one.
    ///
    /// A generation folder that cannot be deleted (Windows: a loaded DLL, or
    /// a file another process holds open) is renamed into
    /// `<root>/.trash/<n>-<16 hex>` and counts as deleted; each sweep first
    /// deletes what it can from `.trash/`, quietly leaving what is still in
    /// use. A pinned generation is never renamed.
    pub fn sweep(self: *GenerationStore) !SweepReport {
        const a = self.a;
        const io = self.io;
        const gen_root = try path.join(a, self.root, &.{"gen"});
        defer a.free(gen_root.bytes);
        try Dir.cwd().createDirPath(io, gen_root.bytes);

        var store_lock = try self.lockStore(.exclusive);
        defer store_lock.release();
        self.emptyTrash();

        const gens = try self.listGens(gen_root);
        defer a.free(gens);
        const sizes = try a.alloc(u64, gens.len);
        defer a.free(sizes);
        const pinned = try a.alloc(bool, gens.len);
        defer a.free(pinned);
        // `store.lock` is held exclusive, so no generation is pinned or
        // unpinned through `pin` while this runs (a process can still
        // release a pin; such a generation stays until the next sweep).
        var total: u64 = 0;
        var unpinned_total: u64 = 0;
        var failed: u32 = 0;
        for (gens, sizes, pinned) |n, *sz, *pn| {
            sz.* = try self.genBytes(n);
            // A lock that cannot be checked (a link, a file of another
            // user) counts as pinned: never delete it, and go on with the
            // others.
            pn.* = self.isPinned(n) catch blk: {
                failed += 1;
                break :blk true;
            };
            total += sz.*;
            if (!pn.*) unpinned_total += sz.*;
        }

        const over_count: usize = if (gens.len > self.caps.max_count) gens.len - self.caps.max_count else 0;
        var deleted: u32 = 0;
        // The last entry is the newest: never a candidate.
        const candidates = if (gens.len == 0) 0 else gens.len - 1;
        for (gens[0..candidates], sizes[0..candidates], pinned[0..candidates], 0..) |n, sz, pn, i| {
            if (pn) continue;
            if (i >= over_count and unpinned_total <= self.caps.max_bytes) continue;
            const gone = self.deleteIfUnpinned(n) catch {
                failed += 1;
                continue;
            };
            if (gone) {
                deleted += 1;
                total -= sz;
                unpinned_total -= sz;
            }
        }
        return .{
            .deleted = deleted,
            .kept = @intCast(gens.len - deleted),
            .bytes_kept = total,
            .failed = failed,
        };
    }

    /// How many generations are pinned now, by this process or another
    /// (their `.lock` cannot be taken exclusive without waiting). For checks
    /// and tests; deletes nothing.
    pub fn heldPins(self: *GenerationStore) !u32 {
        const a = self.a;
        const gen_root = try path.join(a, self.root, &.{"gen"});
        defer a.free(gen_root.bytes);
        var store_lock = try self.lockStore(.exclusive);
        defer store_lock.release();
        const gens = try self.listGens(gen_root);
        defer a.free(gens);
        var held: u32 = 0;
        for (gens) |n| {
            // As in `sweep`: a lock that cannot be checked counts as held.
            if (self.isPinned(n) catch true) held += 1;
        }
        return held;
    }

    /// True when `gen/<n>/.lock` cannot be taken exclusive without waiting.
    /// Hold `store.lock` exclusive, so no `pin` slips in after the check.
    fn isPinned(self: *GenerationStore, n: u32) !bool {
        const lp = try self.genLockPath(n);
        defer self.a.free(lp.bytes);
        var l = FileLock.acquire(self.io, lp, .exclusive, 0) catch |e| switch (e) {
            error.Timeout => return true,
            else => return e,
        };
        l.release();
        return false;
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

    /// Sum of the allocated sizes (`allocatedBytes`) of the files directly
    /// inside `gen/<n>`.
    fn genBytes(self: *GenerationStore, n: u32) !u64 {
        const dp = try self.genDirPath(n);
        defer self.a.free(dp.bytes);
        var d = try Dir.cwd().openDir(self.io, dp.bytes, .{ .iterate = true });
        defer d.close(self.io);
        var total: u64 = 0;
        var it = d.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const file = try d.openFile(self.io, entry.name, .{});
            defer file.close(self.io);
            total += try allocatedBytes(self.io, file);
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
            Dir.cwd().deleteTree(self.io, dp.bytes) catch |err| {
                // A loaded DLL cannot be deleted, but it can be renamed.
                self.moveToTrash(dp, n) catch return err;
            };
        } else {
            defer l.release();
            try Dir.cwd().deleteTree(self.io, dp.bytes);
        }
        return true;
    }

    /// Moves the generation `dp` into `<root>/.trash/<n>-<16 hex>`. On Windows
    /// its files are moved one by one with `MoveFileExW` into a new folder of
    /// that name and the emptied folder is deleted; elsewhere the folder is
    /// renamed.
    fn moveToTrash(self: *GenerationStore, dp: OsPath, n: u32) !void {
        const a = self.a;
        const io = self.io;
        const trash = try path.join(a, self.root, &.{trash_dir});
        defer a.free(trash.bytes);
        try Dir.cwd().createDirPath(io, trash.bytes);
        // The store is inside the project folder, which may carry a `.trash`
        // link: never rename a generation out of the store.
        if (!isRealDir(io, trash)) return error.TrashNotADirectory;
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        var nb: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "{d}-{s}", .{ n, &std.fmt.bytesToHex(rnd, .lower) });
        const dst = try path.join(a, trash, &.{name});
        defer a.free(dst.bytes);
        if (builtin.os.tag == .windows) {
            // The folder rename is skipped on Windows: std's rename asks for
            // write access, which Windows refuses for a loaded DLL (and for
            // a folder with a running image in it), and it retries a refusal
            // for about 4 s while `store.lock` is held. `MoveFileExW`
            // (`win32.moveFile`) asks for delete access only.
            const win32 = @import("win32.zig");
            try Dir.cwd().createDir(io, dst.bytes, .default_dir);
            {
                var d = try Dir.cwd().openDir(io, dp.bytes, .{ .iterate = true, .follow_symlinks = false });
                defer d.close(io);
                var it = d.iterate();
                while (try it.next(io)) |entry| {
                    // `deleteTree` removed everything it could; a generation
                    // holds plain files only. Links are never followed.
                    if (entry.kind != .file) return error.NotAFile;
                    const from = try path.join(a, dp, &.{entry.name});
                    defer a.free(from.bytes);
                    const to = try path.join(a, dst, &.{entry.name});
                    defer a.free(to.bytes);
                    try win32.moveFile(a, from.bytes, to.bytes);
                }
            }
            try Dir.cwd().deleteDir(io, dp.bytes);
            return;
        }
        try Dir.cwd().rename(dp.bytes, Dir.cwd(), dst.bytes, io);
    }

    /// Deletes each entry of `<root>/.trash/` that `moveToTrash` made
    /// (`isTrashName`) and that can be deleted now, and the folder itself
    /// once it is empty. What is still in use stays for a later sweep;
    /// nothing is reported. A `.trash` that is a link (or a junction) or
    /// not a folder is left alone, and so is every entry with another name:
    /// the sweep never deletes outside the store or what it did not put there.
    fn emptyTrash(self: *GenerationStore) void {
        const a = self.a;
        const io = self.io;
        const trash = path.join(a, self.root, &.{trash_dir}) catch return;
        defer a.free(trash.bytes);
        if (!isRealDir(io, trash)) return;
        var d = Dir.cwd().openDir(io, trash.bytes, .{ .iterate = true, .follow_symlinks = false }) catch return;
        var left = false;
        {
            defer d.close(io);
            var it = d.iterate();
            while (it.next(io) catch null) |entry| {
                if (!isTrashName(entry.name)) {
                    left = true;
                    continue;
                }
                d.deleteTree(io, entry.name) catch {
                    left = true;
                };
            }
        }
        if (!left) Dir.cwd().deleteDir(io, trash.bytes) catch {};
    }
};

/// True when `p` is a folder itself, not a link (or a Windows junction) to one.
fn isRealDir(io: std.Io, p: OsPath) bool {
    const st = Dir.cwd().statFile(io, p.bytes, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .directory;
}

/// True for a name `moveToTrash` writes: a canonical generation number,
/// `-`, and 16 lowercase hex digits.
fn isTrashName(name: []const u8) bool {
    const dash = std.mem.indexOfScalar(u8, name, '-') orelse return false;
    const num = name[0..dash];
    const hex = name[dash + 1 ..];
    if (num.len == 0 or hex.len != 16) return false;
    const n = std.fmt.parseInt(u32, num, 10) catch return false;
    var nb: [16]u8 = undefined;
    const canon = std.fmt.bufPrint(&nb, "{d}", .{n}) catch return false;
    if (!std.mem.eql(u8, canon, num)) return false;
    for (hex) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

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
    /// A library the store's check accepts for this target, holding
    /// `payload`: `writePe` on Windows, `writeMachO` on macOS, `writeElf`
    /// elsewhere.
    fn writeLib(f: *Fixture, name: []const u8, payload: []const u8) !void {
        if (os_tag == .windows) return f.writePe(name, payload);
        if (os_tag.isDarwin()) return f.writeMachO(name, payload);
        return f.writeElf(name, payload);
    }
    /// A minimal complete Mach-O image: a 64-bit header with no load
    /// commands, followed by `payload` bytes.
    fn writeMachO(f: *Fixture, name: []const u8, payload: []const u8) !void {
        var b: [32]u8 = @splat(0);
        std.mem.writeInt(u32, b[0..4], std.macho.MH_MAGIC_64, .little);
        std.mem.writeInt(u32, b[4..8], std.macho.CPU_TYPE_ARM64, .little);
        std.mem.writeInt(u32, b[12..16], std.macho.MH_DYLIB, .little);
        var file = try f.tmp.dir.createFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &b, 0);
        try file.writePositionalAll(std.testing.io, payload, 32);
    }
    /// A minimal complete PE32+ file: headers up to byte 0x200, then one
    /// section holding `payload`.
    fn writePe(f: *Fixture, name: []const u8, payload: []const u8) !void {
        var b: [0x200]u8 = @splat(0);
        @memcpy(b[0..2], "MZ");
        std.mem.writeInt(u32, b[0x3c..][0..4], 0x40, .little);
        @memcpy(b[0x40..0x44], "PE\x00\x00");
        std.mem.writeInt(u16, b[0x44..][0..2], 0x8664, .little); // machine
        std.mem.writeInt(u16, b[0x46..][0..2], 1, .little); // sections
        std.mem.writeInt(u16, b[0x54..][0..2], 240, .little); // optional header size
        const opt = 0x58;
        std.mem.writeInt(u16, b[opt..][0..2], 0x20b, .little); // PE32+
        std.mem.writeInt(u64, b[opt + 24 ..][0..8], 0x1_8000_0000, .little); // image base
        std.mem.writeInt(u32, b[opt + 60 ..][0..4], 0x200, .little); // SizeOfHeaders
        std.mem.writeInt(u32, b[opt + 108 ..][0..4], 16, .little); // data directories
        const sec = opt + 240;
        const len: u32 = @intCast(payload.len);
        @memcpy(b[sec..][0..5], ".data");
        std.mem.writeInt(u32, b[sec + 8 ..][0..4], len, .little); // VirtualSize
        std.mem.writeInt(u32, b[sec + 12 ..][0..4], 0x1000, .little); // VirtualAddress
        std.mem.writeInt(u32, b[sec + 16 ..][0..4], len, .little); // SizeOfRawData
        std.mem.writeInt(u32, b[sec + 20 ..][0..4], 0x200, .little); // PointerToRawData
        var file = try f.tmp.dir.createFile(std.testing.io, name, .{});
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &b, 0);
        try file.writePositionalAll(std.testing.io, payload, 0x200);
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

/// Stages `built` and releases the staging pin at once.
fn stageOne(a: Allocator, s: *GenerationStore, built: OsPath) !u32 {
    var st = try s.stage(built, &.{});
    st.pin.release();
    defer st.gen.deinit(a);
    return st.gen.n;
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
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "payload bytes");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    const extra = try f.p(a, &.{"extra.txt"});
    defer a.free(extra.bytes);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "extra.txt", .data = "xtra" });
    var s = f.store(a, .{});
    var st = try s.stage(built, &.{extra});
    defer st.gen.deinit(a);
    defer st.pin.release();
    const g = st.gen;
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
    try f.writeLib("built.so", "");
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
    var st = try s.stage(built, &.{});
    defer st.gen.deinit(a);
    defer st.pin.release();
    const g = st.gen;
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

test "sweep counts allocated bytes" {
    if (os_tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    // A sparse 64 MiB library with one 4 KiB data block: about 8 KiB on
    // disk, far below the 32 MiB cap, so a sweep that measures allocated
    // blocks keeps both generations.
    try f.writeLib("built.so", "");
    {
        var file = try f.tmp.dir.openFile(io, "built.so", .{ .mode = .read_write });
        defer file.close(io);
        const block: [4096]u8 = @splat(0xAB);
        try file.writePositionalAll(io, &block, 32 << 20);
        try file.setLength(io, 64 << 20);
    }
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_bytes = 32 << 20 });
    _ = try stageOne(a, &s, built);
    _ = try stageOne(a, &s, built);
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 0), rep.deleted);
    try std.testing.expectEqual(@as(u32, 2), rep.kept);
    try std.testing.expect(rep.bytes_kept < (1 << 20));
    try std.testing.expect(try genExists(a, &f, 1));
    // The helper itself: allocated bytes of the staged file.
    const lib = try f.p(a, &.{ "zig-store", "gen", "2", "libdemo.2.so" });
    defer a.free(lib.bytes);
    const file = try std.Io.Dir.cwd().openFile(io, lib.bytes, .{});
    defer file.close(io);
    const bytes = try allocatedBytes(io, file);
    try std.testing.expect(bytes > 0 and bytes < (1 << 20));
}

test "pin blocks sweep" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "hello");
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

test "a lock that cannot be checked does not end the sweep" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeLib("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_count = 1 });
    for (0..4) |_| _ = try stageOne(a, &s, built);
    // Gen 2's lock is replaced by a link (a restore, a copy as another
    // user): its pin state cannot be checked.
    const lock_file = try path.join(a, f.root, &.{ "gen", "2", ".lock" });
    defer a.free(lock_file.bytes);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, lock_file.bytes);
    const target = try f.p(a, &.{"elsewhere"});
    defer a.free(target.bytes);
    try std.Io.Dir.cwd().symLink(std.testing.io, target.bytes, lock_file.bytes, .{});
    // It counts as pinned and failed; the others are still swept.
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 2), rep.deleted);
    try std.testing.expectEqual(@as(u32, 1), rep.failed);
    try std.testing.expect(!try genExists(a, &f, 1));
    try std.testing.expect(try genExists(a, &f, 2));
    try std.testing.expect(!try genExists(a, &f, 3));
    try std.testing.expect(try genExists(a, &f, 4));
    try std.testing.expectEqual(@as(u32, 1), try s.heldPins());
}

test "sweep keeps newest" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "hello");
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
    try f.writeLib("built.so", "hello");
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

test "staged build survives a sweep before load" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeLib("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    // Spec risk 20: build 1 is staged and its outcome waits for the main
    // thread while two more builds stage and sweep with room for one.
    var s = f.store(a, .{ .max_count = 1 });
    var first = try s.stage(built, &.{});
    defer first.gen.deinit(a);
    for (0..2) |_| {
        _ = try stageOne(a, &s, built);
        _ = try s.sweep();
    }
    try std.testing.expect(try genExists(a, &f, first.gen.n));
    try std.testing.expect(!try genExists(a, &f, 2));
    try std.testing.expectEqual(@as(u32, 1), try s.heldPins());
    // The load reads the staged file; then the pin can go.
    const lib = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, first.gen.lib.bytes, a, .limited(1 << 20));
    a.free(lib);
    first.pin.release();
    try std.testing.expectEqual(@as(u32, 0), try s.heldPins());
    _ = try s.sweep();
    try std.testing.expect(!try genExists(a, &f, first.gen.n));
}

test "pinned bytes do not evict" {
    if (os_tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    // A tool project in the editor: three loaded (pinned) builds hold far
    // more than the byte cap; the unpinned builds are small.
    try f.writeLib("small.so", "hello");
    const big_payload = try a.alloc(u8, 256 << 10);
    defer a.free(big_payload);
    @memset(big_payload, 0xAB);
    try f.writeLib("big.so", big_payload);
    const small = try f.p(a, &.{"small.so"});
    defer a.free(small.bytes);
    const big = try f.p(a, &.{"big.so"});
    defer a.free(big.bytes);
    var s = f.store(a, .{ .max_count = 5, .max_bytes = 128 << 10 });
    _ = try stageOne(a, &s, small);
    var pins: [3]FileLock = undefined;
    for (&pins) |*l| {
        var st = try s.stage(big, &.{});
        st.gen.deinit(a);
        l.* = st.pin;
    }
    defer for (&pins) |*l| l.release();
    for (0..3) |_| _ = try stageOne(a, &s, small);
    // gen 1 small, 2-4 pinned big, 5-7 small (7 newest). Seven is two over
    // max_count: the oldest two are over the count, and of those only the
    // unpinned gen 1 goes. The pinned bytes alone are over max_bytes, but
    // they do not count, so 5 and 6 stay.
    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 1), rep.deleted);
    try std.testing.expectEqual(@as(u32, 0), rep.failed);
    try std.testing.expect(!try genExists(a, &f, 1));
    for ([_]u32{ 2, 3, 4, 5, 6, 7 }) |n| try std.testing.expect(try genExists(a, &f, n));
    try std.testing.expectEqual(@as(u32, 3), try s.heldPins());
    // A second sweep finds nothing more to delete: the unpinned bytes are
    // within the cap and the count is.
    const rep2 = try s.sweep();
    try std.testing.expectEqual(@as(u32, 0), rep2.deleted);
}

test "folders with non-canonical names are ignored" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    try f.writeLib("built.so", "hello");
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

/// Entries in `<store>/.trash`, or 0 when it does not exist.
fn trashCount(a: Allocator, f: *Fixture) !u32 {
    const q = try path.join(a, f.root, &.{trash_dir});
    defer a.free(q.bytes);
    var d = Dir.cwd().openDir(std.testing.io, q.bytes, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer d.close(std.testing.io);
    var n: u32 = 0;
    var it = d.iterate();
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

/// Copies the fixture DLL (`build_options.answer_dll`) to `<tmp>/<name>`,
/// cut to half its size when `cut`; the caller frees the path.
fn copyAnswerDll(a: Allocator, f: *Fixture, name: []const u8, cut: bool) !OsPath {
    const io = std.testing.io;
    const bytes = try Dir.cwd().readFileAlloc(io, @import("build_options").answer_dll, a, .unlimited);
    defer a.free(bytes);
    try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = if (cut) bytes[0 .. bytes.len / 2] else bytes });
    return f.p(a, &.{name});
}

test "store: a loaded DLL's generation is renamed into trash and deleted later" {
    if (os_tag != .windows) return error.SkipZigTest;
    const loader = @import("loader.zig");
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    const built = try copyAnswerDll(a, &f, "answer.dll", false);
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_count = 1 });

    // Generation 1 is loaded, as the editor keeps it, and no longer pinned.
    var first = try s.stage(built, &.{});
    defer first.gen.deinit(a);
    var diag: [256]u8 = undefined;
    const lib = loader.open(a, std.testing.io, first.gen.lib, &diag) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, elf.diagText(&diag) });
        return err;
    };
    var loaded = true;
    defer if (loaded) loader.close(lib);
    first.pin.release();
    _ = try stageOne(a, &s, built);

    // Windows cannot delete the loaded DLL: it goes to the trash, with no
    // failure and without std's rename retries (about 4 s each), which
    // would keep `store.lock` for that long.
    const t0 = std.Io.Clock.awake.now(std.testing.io);
    const rep = try s.sweep();
    const ms = t0.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds();
    try std.testing.expect(ms < 2000);
    try std.testing.expectEqual(@as(u32, 1), rep.deleted);
    try std.testing.expectEqual(@as(u32, 0), rep.failed);
    try std.testing.expect(!try genExists(a, &f, 1));
    try std.testing.expect(try genExists(a, &f, 2));
    try std.testing.expectEqual(@as(u32, 1), try trashCount(a, &f));

    // While it stays loaded, a sweep leaves it in the trash quietly.
    const rep2 = try s.sweep();
    try std.testing.expectEqual(@as(u32, 0), rep2.failed);
    try std.testing.expectEqual(@as(u32, 1), try trashCount(a, &f));

    // Once it is freed, the next sweep deletes it.
    loader.close(lib);
    loaded = false;
    _ = try s.sweep();
    try std.testing.expectEqual(@as(u32, 0), try trashCount(a, &f));
    try std.testing.expect(try genExists(a, &f, 2));
}

test "store: PE check after staging refuses a truncated DLL" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    const cut = try copyAnswerDll(a, &f, "cut.dll", true);
    defer a.free(cut.bytes);
    var s = GenerationStore.init(a, std.testing.io, f.root, .windows, "demo", .{});
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, s.stageDiag(cut, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, elf.diagText(&diag), "truncated") != null);
    try std.testing.expect(!try genExists(a, &f, 1));
    // The whole DLL is staged.
    const whole = try copyAnswerDll(a, &f, "whole.dll", false);
    defer a.free(whole.bytes);
    var st = try s.stage(whole, &.{});
    defer st.gen.deinit(a);
    defer st.pin.release();
    try std.testing.expectEqual(@as(u32, 1), st.gen.n);
}

test "store: Mach-O check after staging refuses a truncated dylib" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    const bytes = try Dir.cwd().readFileAlloc(io, @import("build_options").macho_arm64_dylib, a, .unlimited);
    defer a.free(bytes);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "cut.dylib", .data = bytes[0 .. bytes.len - 1] });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "whole.dylib", .data = bytes });
    const cut = try f.p(a, &.{"cut.dylib"});
    defer a.free(cut.bytes);
    var s = GenerationStore.init(a, io, f.root, .macos, "demo", .{});
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, s.stageDiag(cut, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, elf.diagText(&diag), "truncated") != null);
    try std.testing.expect(!try genExists(a, &f, 1));
    // The whole dylib is staged.
    const whole = try f.p(a, &.{"whole.dylib"});
    defer a.free(whole.bytes);
    var st = try s.stage(whole, &.{});
    defer st.gen.deinit(a);
    defer st.pin.release();
    try std.testing.expectEqual(@as(u32, 1), st.gen.n);
    try std.testing.expect(std.mem.endsWith(u8, st.gen.lib.bytes, "libdemo.1.dylib"));
}

test "isTrashName accepts only what moveToTrash writes" {
    try std.testing.expect(isTrashName("1-0123456789abcdef"));
    try std.testing.expect(isTrashName("4294967295-ffffffffffffffff"));
    for ([_][]const u8{
        "keep.txt",                    "1-0123456789abcde",  "1-0123456789abcdef0", "01-0123456789abcdef",
        "-0123456789abcdef",           "1-0123456789ABCDEF", "+1-0123456789abcdef", "1-0123456789abcdeg",
        "4294967296-0123456789abcdef",
    }) |bad| try std.testing.expect(!isTrashName(bad));
}

/// Two generations staged and released, gen 1 unpinned and over the count.
fn twoGens(a: Allocator, f: *Fixture) !GenerationStore {
    try f.writeLib("built.so", "hello");
    const built = try f.p(a, &.{"built.so"});
    defer a.free(built.bytes);
    var s = f.store(a, .{ .max_count = 1 });
    _ = try stageOne(a, &s, built);
    _ = try stageOne(a, &s, built);
    return s;
}

test "store: a .trash link to an outside folder is never emptied" {
    if (os_tag == .windows) return error.SkipZigTest; // no symbolic links under Wine
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var s = try twoGens(a, &f);
    // An outside folder with a file that looks like a trash entry.
    try f.tmp.dir.createDirPath(io, "outside/1-0123456789abcdef");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "outside/1-0123456789abcdef/precious", .data = "x" });
    const outside = try f.p(a, &.{"outside"});
    defer a.free(outside.bytes);
    const link = try path.join(a, f.root, &.{trash_dir});
    defer a.free(link.bytes);
    try Dir.cwd().symLink(io, outside.bytes, link.bytes, .{ .is_directory = true });

    const rep = try s.sweep();
    try std.testing.expectEqual(@as(u32, 1), rep.deleted);
    try std.testing.expectEqual(@as(u32, 0), rep.failed);
    _ = try f.tmp.dir.statFile(io, "outside/1-0123456789abcdef/precious", .{});
    // The link itself stays too: the store does not touch it.
    const st = try Dir.cwd().statFile(io, link.bytes, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, st.kind);
}

test "store: a foreign entry in .trash survives the sweep" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var s = try twoGens(a, &f);
    const trash = try path.join(a, f.root, &.{trash_dir});
    defer a.free(trash.bytes);
    try Dir.cwd().createDirPath(io, trash.bytes);
    const keep = try path.join(a, trash, &.{"keep.txt"});
    defer a.free(keep.bytes);
    try Dir.cwd().writeFile(io, .{ .sub_path = keep.bytes, .data = "x" });
    const ours = try path.join(a, trash, &.{"7-0123456789abcdef"});
    defer a.free(ours.bytes);
    try Dir.cwd().createDirPath(io, ours.bytes);

    _ = try s.sweep();
    _ = try Dir.cwd().statFile(io, keep.bytes, .{});
    try std.testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, ours.bytes, .{}));
    try std.testing.expectEqual(@as(u32, 1), try trashCount(a, &f));
}
