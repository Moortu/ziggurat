//! Advisory file locks (L1). One lock per open file description, so two
//! handles in one process conflict (ruling P2). Uses `std.Io.File.tryLock`:
//! `flock` on Linux and macOS, `NtLockFile` (the call behind `LockFileEx`) on
//! Windows. The caller retries until its timeout ends.
const std = @import("std");
const path = @import("path.zig");

pub const Mode = enum { shared, exclusive };

pub const FileLock = struct {
    file: std.Io.File,
    io: std.Io,

    pub const Error = error{Timeout} ||
        std.Io.File.OpenError ||
        std.Io.File.LockError ||
        std.Io.Cancelable;

    /// Opens (creating if needed, never truncating) the lock file at `p` and
    /// takes the lock. The parent folder must exist. Returns `error.Timeout`
    /// when the lock is still held by someone else after `timeout_ms`.
    /// `timeout_ms = 0` tries exactly once.
    pub fn acquire(io: std.Io, p: path.OsPath, mode: Mode, timeout_ms: u32) Error!FileLock {
        const file = try std.Io.Dir.cwd().createFile(io, p.bytes, .{ .read = true, .truncate = false });
        errdefer file.close(io);
        const kind: std.Io.File.Lock = switch (mode) {
            .shared => .shared,
            .exclusive => .exclusive,
        };
        const start = std.Io.Clock.awake.now(io);
        while (true) {
            if (try file.tryLock(io, kind)) return .{ .file = file, .io = io };
            const elapsed_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
            if (elapsed_ms >= timeout_ms) return error.Timeout;
            const left: i64 = @as(i64, timeout_ms) - elapsed_ms;
            try io.sleep(.fromMilliseconds(@min(left, 10)), .awake);
        }
    }

    /// Drops the lock and closes the lock file. The file stays on disk.
    pub fn release(self: *FileLock) void {
        self.file.unlock(self.io);
        self.file.close(self.io);
        self.* = undefined;
    }
};

fn tmpPath(a: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) !path.OsPath {
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    return path.join(a, path.OsPath.fromTrusted(base), &.{name});
}

test "shared locks coexist, exclusive conflicts" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try tmpPath(a, tmp, "x.lock");
    defer a.free(p.bytes);

    var s1 = try FileLock.acquire(io, p, .shared, 100);
    var s2 = try FileLock.acquire(io, p, .shared, 100);
    try std.testing.expectError(error.Timeout, FileLock.acquire(io, p, .exclusive, 50));
    s1.release();
    s2.release();
    var e = try FileLock.acquire(io, p, .exclusive, 100);
    try std.testing.expectError(error.Timeout, FileLock.acquire(io, p, .shared, 0));
    e.release();
}
