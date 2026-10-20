//! Opening files that an untrusted folder may have replaced (L1): never
//! block on a FIFO or a device, optionally refuse a symbolic link as the
//! last path part, and accept only a regular file. Also a file's identity
//! (device, inode, size, modification time), so a caller can tell whether
//! two paths name one file or whether a file changed between two checks.
//!
//! On POSIX the file is opened with `O_NONBLOCK` (an open of a FIFO with no
//! writer returns at once instead of waiting), checked with `fstat`, and
//! switched back to blocking mode. Windows has no FIFOs in the file system;
//! there the ordinary open is used and the identity is unavailable.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const File = std.Io.File;

const is_windows = builtin.os.tag == .windows;

pub const OpenError = error{
    /// The last path part is a symbolic link (with `follow_symlinks = false`).
    SymLink,
    /// A FIFO, device, socket or folder.
    NotRegular,
    FileNotFound,
    AccessDenied,
    /// Anything else the open or `fstat` reported.
    Unreadable,
};

pub const Options = struct {
    follow_symlinks: bool = true,
};

/// Opens `p` (absolute, or relative to the working folder) for reading. The
/// result is a regular file in blocking mode; close it with `close`.
pub fn openRegular(io: std.Io, p: []const u8, opts: Options) OpenError!File {
    if (is_windows) {
        const f = std.Io.Dir.cwd().openFile(io, p, .{ .follow_symlinks = opts.follow_symlinks, .allow_directory = false }) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.IsDir => error.NotRegular,
            error.SymLinkLoop => error.SymLink,
            else => error.Unreadable,
        };
        errdefer f.close(io);
        const st = f.stat(io) catch return error.Unreadable;
        if (st.kind != .file) return error.NotRegular;
        return f;
    }
    var flags: posix.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true };
    flags.NOFOLLOW = !opts.follow_symlinks;
    return finishOpen(io, posix.openat(posix.AT.FDCWD, p, flags, 0));
}

/// Opens or creates the lock file `p` for reading and writing, never
/// truncating it and never following a symbolic link as its last part. The
/// result is a regular file in blocking mode.
pub fn openLockFile(io: std.Io, p: []const u8) OpenError!File {
    if (is_windows) {
        const f = std.Io.Dir.cwd().createFile(io, p, .{ .read = true, .truncate = false }) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.IsDir => error.NotRegular,
            else => error.Unreadable,
        };
        return f;
    }
    const flags: posix.O = .{ .ACCMODE = .RDWR, .CREAT = true, .NONBLOCK = true, .CLOEXEC = true, .NOCTTY = true, .NOFOLLOW = true };
    return finishOpen(io, posix.openat(posix.AT.FDCWD, p, flags, 0o644));
}

fn finishOpen(io: std.Io, opened: posix.OpenError!posix.fd_t) OpenError!File {
    const fd = opened catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.SymLinkLoop => error.SymLink,
        error.IsDir => error.NotRegular,
        else => error.Unreadable,
    };
    var f: File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    errdefer f.close(io);
    const st = f.stat(io) catch return error.Unreadable;
    if (st.kind != .file) return error.NotRegular;
    // A regular file: blocking mode again, as every other file the
    // process reads.
    const fl = std.c.fcntl(fd, posix.F.GETFL);
    if (fl < 0) return error.Unreadable;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
    if (std.c.fcntl(fd, posix.F.SETFL, fl & ~nonblock) < 0) return error.Unreadable;
    f.flags.nonblocking = false;
    return f;
}

/// What tells one file from another, and one version of a file from the
/// next (short of a rewrite in place within the clock's resolution that
/// keeps the size).
pub const Identity = struct {
    dev: u64,
    ino: u64,
    size: u64,
    mtime_ns: i128,

    /// One file: the same device and inode.
    pub fn sameFile(a: Identity, b: Identity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }

    /// The same file, unchanged.
    pub fn eql(a: Identity, b: Identity) bool {
        return a.sameFile(b) and a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

pub const IdentityError = error{ Unsupported, Unreadable };

/// The identity of the open file `f`. `error.Unsupported` on Windows.
pub fn identity(f: File) IdentityError!Identity {
    switch (builtin.os.tag) {
        .windows => return error.Unsupported,
        .linux => {
            const linux = std.os.linux;
            var sx: linux.Statx = undefined;
            const rc = linux.statx(f.handle, "", linux.AT.EMPTY_PATH, .{ .INO = true, .SIZE = true, .MTIME = true }, &sx);
            if (linux.errno(rc) != .SUCCESS) return error.Unreadable;
            const dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor;
            return .{
                .dev = dev,
                .ino = sx.ino,
                .size = sx.size,
                .mtime_ns = @as(i128, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec,
            };
        },
        else => {
            var st: std.c.Stat = undefined;
            if (std.c.fstat(f.handle, &st) != 0) return error.Unreadable;
            const m = st.mtime();
            return .{
                .dev = @bitCast(@as(i64, st.dev)),
                .ino = @intCast(st.ino),
                .size = @intCast(st.size),
                .mtime_ns = @as(i128, m.sec) * std.time.ns_per_s + m.nsec,
            };
        },
    }
}

/// Opens `p` as `openRegular` does and returns its identity.
pub fn identityOfPath(io: std.Io, p: []const u8, opts: Options) (OpenError || IdentityError)!Identity {
    const f = try openRegular(io, p, opts);
    defer f.close(io);
    return identity(f);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn mkfifo(a: std.mem.Allocator, p: []const u8) !void {
    const r = try std.process.run(a, testing.io, .{ .argv = &.{ "mkfifo", p } });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    if (!r.term.success()) return error.MkfifoFailed;
}

test "openRegular refuses a FIFO without blocking, a link when asked, and a folder" {
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const fifo = try std.fs.path.join(a, &.{ root, "fifo" });
    defer a.free(fifo);
    try mkfifo(a, fifo);
    // No writer: a blocking open would wait for ever.
    try testing.expectError(error.NotRegular, openRegular(io, fifo, .{}));
    try testing.expectError(error.NotRegular, openLockFile(io, fifo));

    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "abc" });
    const file = try std.fs.path.join(a, &.{ root, "file" });
    defer a.free(file);
    try tmp.dir.symLink(io, file, "link", .{});
    const link = try std.fs.path.join(a, &.{ root, "link" });
    defer a.free(link);
    try testing.expectError(error.SymLink, openRegular(io, link, .{ .follow_symlinks = false }));
    try testing.expectError(error.SymLink, openLockFile(io, link));
    const f = try openRegular(io, link, .{});
    var buf: [8]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    f.close(io);
    try testing.expectEqualStrings("abc", buf[0..n]);
    try testing.expectError(error.NotRegular, openRegular(io, root, .{}));
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    try testing.expectError(error.FileNotFound, openRegular(io, missing, .{}));
}

test "identity tells hard links apart from copies and sees changes" {
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "one", .data = "abc" });
    try tmp.dir.copyFile("one", tmp.dir, "copy", io, .{});
    const one = try std.fs.path.join(a, &.{ root, "one" });
    defer a.free(one);
    const copy = try std.fs.path.join(a, &.{ root, "copy" });
    defer a.free(copy);
    const hard = try std.fs.path.join(a, &.{ root, "hard" });
    defer a.free(hard);
    try tmp.dir.hardLink("one", tmp.dir, "hard", io, .{});

    const id_one = try identityOfPath(io, one, .{});
    try testing.expect(id_one.sameFile(try identityOfPath(io, hard, .{})));
    try testing.expect(!id_one.sameFile(try identityOfPath(io, copy, .{})));
    try tmp.dir.writeFile(io, .{ .sub_path = "one", .data = "abcd" });
    const changed = try identityOfPath(io, one, .{});
    try testing.expect(changed.sameFile(id_one));
    try testing.expect(!changed.eql(id_one));
}
