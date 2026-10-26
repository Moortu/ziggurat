//! Advisory file locks (L1). One lock per open file description, so two
//! handles in one process conflict (ruling P2). Linux and macOS use
//! `std.Io.File.tryLock` (`flock`). Windows uses kernel32 `LockFileEx` with
//! `LOCKFILE_FAIL_IMMEDIATELY` on the whole file, and `UnlockFileEx`: std's
//! `tryLock` there calls `NtLockFile` with an I/O status block, which Wine
//! refuses (NOT_IMPLEMENTED). The caller retries until its timeout ends.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const safe_open = @import("safe_open.zig");

pub const Mode = enum { shared, exclusive };

pub const FileLock = struct {
    file: std.Io.File,
    io: std.Io,

    pub const Error = error{Timeout} ||
        safe_open.OpenError ||
        std.Io.File.LockError ||
        std.Io.Cancelable;

    /// Opens (creating if needed, never truncating, never following a
    /// symbolic link and never blocking on a FIFO: `safe_open.openLockFile`)
    /// the regular lock file at `p` and takes the lock. The parent folder must exist. Returns `error.Timeout`
    /// when the lock is still held by someone else after `timeout_ms`.
    /// `timeout_ms = 0` tries exactly once.
    pub fn acquire(io: std.Io, p: path.OsPath, mode: Mode, timeout_ms: u32) Error!FileLock {
        const file = try safe_open.openLockFile(io, p.bytes);
        errdefer file.close(io);
        const start = std.Io.Clock.awake.now(io);
        while (true) {
            if (try tryLock(io, file, mode)) return .{ .file = file, .io = io };
            const elapsed_ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
            if (elapsed_ms >= timeout_ms) return error.Timeout;
            const left: i64 = @as(i64, timeout_ms) - elapsed_ms;
            try io.sleep(.fromMilliseconds(@min(left, 10)), .awake);
        }
    }

    /// Drops the lock and closes the lock file. The file stays on disk.
    pub fn release(self: *FileLock) void {
        unlock(self.io, self.file);
        self.file.close(self.io);
        self.* = undefined;
    }
};

const is_windows = builtin.os.tag == .windows;

/// True when the lock was taken, false when another handle holds a
/// conflicting lock.
fn tryLock(io: std.Io, file: std.Io.File, mode: Mode) std.Io.File.LockError!bool {
    if (!is_windows) return file.tryLock(io, switch (mode) {
        .shared => .shared,
        .exclusive => .exclusive,
    });
    var flags: u32 = LOCKFILE_FAIL_IMMEDIATELY;
    if (mode == .exclusive) flags |= LOCKFILE_EXCLUSIVE_LOCK;
    var ov: OVERLAPPED = .{};
    if (LockFileEx(file.handle, flags, 0, whole_low, whole_high, &ov) != 0) return true;
    return switch (GetLastError()) {
        ERROR_LOCK_VIOLATION => false,
        else => error.Unexpected,
    };
}

fn unlock(io: std.Io, file: std.Io.File) void {
    if (!is_windows) return file.unlock(io);
    var ov: OVERLAPPED = .{};
    _ = UnlockFileEx(file.handle, 0, whole_low, whole_high, &ov);
}

// kernel32 file locks. The range is the whole file: offset 0 (in `ov`),
// length 2^64 - 1, as std uses.
const LOCKFILE_FAIL_IMMEDIATELY: u32 = 0x1;
const LOCKFILE_EXCLUSIVE_LOCK: u32 = 0x2;
const ERROR_LOCK_VIOLATION: u32 = 33;
const whole_low: u32 = 0xffff_ffff;
const whole_high: u32 = 0xffff_ffff;

const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?*anyopaque = null,
};

extern "kernel32" fn LockFileEx(file: *anyopaque, flags: u32, reserved: u32, len_low: u32, len_high: u32, ov: *OVERLAPPED) callconv(.winapi) c_int;
extern "kernel32" fn UnlockFileEx(file: *anyopaque, reserved: u32, len_low: u32, len_high: u32, ov: *OVERLAPPED) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

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
