//! Checked install of a downloaded Zig release (L1, std only).
//!
//! Order: size, SHA-256, minisign (`minisign.verifyFile`), unpack into a
//! fresh `<toolchains>/.zig-<pin>.tmp-<random>/`, require exactly one top
//! folder `zig-<arch>-<os>-<pin>/` holding the `zig` executable and `lib/`,
//! run `zig version` (must print the pin), then rename the top folder to
//! `<toolchains>/zig-<pin>` (the path `zig_locator` checks). Every failure
//! deletes the temporary folder; nothing unchecked is ever moved into place.
const std = @import("std");
const builtin = @import("builtin");
const pins = @import("pins.zig");
const minisign = @import("minisign.zig");
const process = @import("process.zig");

const Io = std.Io;
const Dir = Io.Dir;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

/// The installed folder's name inside the toolchains folder.
pub const target_name = "zig-" ++ pins.zig_version;
/// Temporary folders are `<temp_prefix><16 hex digits>`.
pub const temp_prefix = "." ++ target_name ++ ".tmp-";
/// A broken folder at the target is moved to `<old_prefix><hex>` and deleted.
pub const old_prefix = "." ++ target_name ++ ".old-";

const exe_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";

pub const Options = struct {
    /// The downloaded archive (a file on disk).
    archive_path: []const u8,
    /// The downloaded `.minisig` text.
    sig_text: []const u8,
    /// The requested file name, e.g. `zig-x86_64-linux-0.17.0.tar.xz`. It
    /// must match the signed `file:` field; its stem is the top folder.
    archive_name: []const u8,
    expected_size: u64,
    expected_sha256: [32]u8,
    key: minisign.PublicKey,
    /// The per-user toolchains folder; created when missing.
    toolchains_dir: []const u8,
    /// How long `zig version` may take.
    version_timeout_ms: u32 = 60_000,
    /// Test builds only (an empty struct otherwise).
    test_hooks: TestHooks = .{},
};

/// Points where tests step in. Outside test builds there are none.
pub const TestHooks = if (builtin.is_test) struct {
    /// Runs after the size, SHA-256 and signature check, before the unpack.
    after_check: ?Hook = null,
    /// Runs after `zig version`, just before the rename.
    before_rename: ?Hook = null,
    /// Runs when a broken target was found, just before it is moved aside.
    before_move_aside: ?Hook = null,
} else struct {};

pub const Hook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,
};

fn runHook(opts: Options, comptime name: []const u8) void {
    if (!builtin.is_test) return;
    if (@field(opts.test_hooks, name)) |h| h.call(h.ctx);
}

pub const Result = enum {
    /// The archive was checked and moved into place.
    installed,
    /// A working `zig-<pin>` was already there (it is kept).
    already_present,
};

pub const InstallError = error{
    /// `archive_name` is not `zig-<arch>-<os>-<pin>.tar.xz` or `.zip`.
    BadArchiveName,
    SizeMismatch,
    ShaMismatch,
    /// The archive could not be unpacked (corrupt, unsupported entry, a
    /// link, a bad name or a path outside the folder).
    BadArchive,
    /// The file changed on disk between the check and the unpack.
    ArchiveChanged,
    /// Not exactly one top folder named after the archive, or no `zig` or
    /// `lib/` in it.
    BadLayout,
    /// The unpacked `zig version` did not print the pinned version.
    VersionCheckFailed,
} || minisign.Error;

/// Everything `install` can return. Errors of the environment keep their
/// name; any other file system error is `FileSystem`.
pub const Error = InstallError || error{
    OutOfMemory,
    /// The archive or a folder on its path does not exist.
    FileNotFound,
    NoSpaceLeft,
    DiskQuota,
    AccessDenied,
    PermissionDenied,
    ReadOnlyFileSystem,
    Canceled,
    FileSystem,
};

/// Checks and installs the archive. An error leaves no temporary folder
/// and nothing new at the target. A folder already at the target whose
/// `zig version` does not print the pin is moved aside and deleted once the
/// new one is checked (also when the final rename then fails); if the
/// folder moved aside turns out to work (another install just placed it),
/// it is put back. Callers should still hold the toolchain lock. Blocking;
/// run it off the main thread. `describe` gives a short reason.
pub fn install(io: Io, gpa: std.mem.Allocator, opts: Options) Error!Result {
    return installAny(io, gpa, opts) catch |err| return toError(err);
}

fn toError(err: anyerror) Error {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return @field(Error, name);
    }
    return error.FileSystem;
}

fn installAny(io: Io, gpa: std.mem.Allocator, opts: Options) !Result {
    const parts = splitName(opts.archive_name) orelse return error.BadArchiveName;

    var tc = try Dir.cwd().createDirPathOpen(io, opts.toolchains_dir, .{});
    defer tc.close(io);
    const tc_abs = try tc.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(tc_abs);

    if (try targetWorks(io, gpa, tc_abs, opts.version_timeout_ms)) return .already_present;

    // One handle for the check and the unpack.
    var file = try Dir.cwd().openFile(io, opts.archive_path, .{});
    defer file.close(io);
    try checkArchive(io, gpa, file, opts);
    runHook(opts, "after_check");

    var temp_buf: [temp_prefix.len + 16]u8 = undefined;
    const temp = randomName(io, &temp_buf, temp_prefix);
    try tc.createDir(io, temp, .default_dir);
    defer tc.deleteTree(io, temp) catch {};
    {
        var td = try tc.openDir(io, temp, .{ .iterate = true });
        defer td.close(io);
        const seen = unpack(io, gpa, td, file, parts.format) catch |err| return unpackFailure(err);
        // The unpacked bytes must be the checked bytes.
        if (seen.size != opts.expected_size or !std.mem.eql(u8, &seen.sha256, &opts.expected_sha256))
            return error.ArchiveChanged;
        try checkLayout(io, td, parts.top);
        if (parts.format == .zip and builtin.os.tag != .windows) {
            // zip keeps no file modes; the Windows zip is the only real one.
            var top = try td.openDir(io, parts.top, .{ .follow_symlinks = false });
            defer top.close(io);
            try top.setFilePermissions(io, exe_name, .fromMode(0o755), .{ .follow_symlinks = false });
        }
    }

    const src = try std.fs.path.join(gpa, &.{ temp, parts.top });
    defer gpa.free(src);
    const exe = try std.fs.path.join(gpa, &.{ tc_abs, src, exe_name });
    defer gpa.free(exe);
    if (!try runsPin(io, gpa, exe, opts.version_timeout_ms)) return error.VersionCheckFailed;

    runHook(opts, "before_rename");
    return moveIntoPlace(io, gpa, tc, tc_abs, src, opts);
}

/// A short reason for the user, for an error from `install`.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.BadArchiveName => "the file name is not a Zig " ++ pins.zig_version ++ " release",
        error.SizeMismatch => "the download has the wrong size",
        error.ShaMismatch => "the download does not match the pinned SHA-256",
        error.Malformed => "the signature file is not a minisign signature",
        error.LegacyAlgorithm => "the signature uses the legacy minisign format",
        error.KeyIdMismatch => "the signature is not from the Zig release key",
        error.BadSignature => "the signature does not match the download",
        error.BadGlobalSignature => "the signed comment was changed",
        error.FileNameMismatch => "the signature is for another file",
        error.BadArchive => "the archive could not be unpacked",
        error.ArchiveChanged => "the download changed on disk during the install",
        error.BadLayout => "the archive does not hold one Zig folder with zig and lib",
        error.VersionCheckFailed => "the unpacked zig did not report version " ++ pins.zig_version,
        error.OutOfMemory => "out of memory",
        error.FileNotFound => "the downloaded file or the toolchains folder is missing",
        error.NoSpaceLeft, error.DiskQuota => "the disk is full",
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => "no permission to write the toolchains folder",
        error.Canceled => "the install was canceled",
        error.FileSystem => "a file system error",
    };
}

const Format = enum { tar_xz, zip };

const NameParts = struct {
    /// The archive's top folder, `zig-<arch>-<os>-<pin>`.
    top: []const u8,
    format: Format,
};

/// `zig-<arch>-<os>-<pin>.tar.xz` or `.zip`, with letters, digits and `-._`.
fn splitName(name: []const u8) ?NameParts {
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._", c) == null) return null;
    const head = "zig-";
    const tail = "-" ++ pins.zig_version;
    inline for (.{ .{ ".tar.xz", Format.tar_xz }, .{ ".zip", Format.zip } }) |ext| {
        if (std.mem.endsWith(u8, name, tail ++ ext[0]) and name.len > head.len + tail.len + ext[0].len and
            std.mem.startsWith(u8, name, head))
        {
            const top = name[0 .. name.len - ext[0].len];
            const middle = top[head.len .. top.len - tail.len];
            const dash = std.mem.indexOfScalar(u8, middle, '-') orelse return null;
            if (dash == 0 or dash + 1 == middle.len) return null;
            return .{ .top = top, .format = ext[1] };
        }
    }
    return null;
}

/// `<prefix><16 random hex digits>` in `buf`.
fn randomName(io: Io, buf: []u8, comptime prefix: []const u8) []const u8 {
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..hex.len], &hex);
    return buf[0 .. prefix.len + hex.len];
}

/// Size, SHA-256 and minisign, in one pass over the file.
fn checkArchive(io: Io, gpa: std.mem.Allocator, file: Io.File, opts: Options) !void {
    if ((try file.length(io)) != opts.expected_size) return error.SizeMismatch;
    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    var r = file.reader(io, buf);
    var sha: Sha256 = .init(.{});
    var b2: Blake2b512 = .init(.{});
    var total: u64 = 0;
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return r.err orelse error.ReadFailed,
        };
        total += chunk.len;
        if (total > opts.expected_size) return error.SizeMismatch;
        sha.update(chunk);
        b2.update(chunk);
        r.interface.toss(chunk.len);
    }
    if (total != opts.expected_size) return error.SizeMismatch;
    var sha_out: [32]u8 = undefined;
    sha.final(&sha_out);
    if (!std.mem.eql(u8, &sha_out, &opts.expected_sha256)) return error.ShaMismatch;
    var digest: [minisign.digest_length]u8 = undefined;
    b2.final(&digest);
    try minisign.verifyFile(opts.key, opts.sig_text, digest, opts.archive_name);
}

/// Size and SHA-256 of the file bytes the unpack read.
const Seen = struct { size: u64, sha256: [32]u8 };

fn unpack(io: Io, gpa: std.mem.Allocator, dir: Dir, file: Io.File, format: Format) !Seen {
    const buf = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buf);
    var fr = file.reader(io, buf);
    switch (format) {
        .tar_xz => {
            // Every byte that reaches xz passes the hash, in file order.
            const hash_buf = try gpa.alloc(u8, 64 * 1024);
            defer gpa.free(hash_buf);
            var hashing: Hashing = .init(&fr.interface, hash_buf);
            var xz = try std.compress.xz.Decompress.init(&hashing.reader, gpa, &.{});
            defer xz.deinit();
            var adapter_buf: [4096]u8 = undefined;
            var adapter: NoDiscard = .init(&xz.reader, &adapter_buf);
            try unpackTar(io, dir, &adapter.reader);
            // Read the xz stream to its end, so a cut-off archive fails
            // even when the tar part looks complete. The std reader reports
            // a cut at a block end as a normal end; only a read index and
            // footer (`block_count` set to the max by `finish`) is complete.
            _ = try adapter.reader.discardRemaining();
            if (xz.block_count != std.math.maxInt(usize)) return error.TruncatedArchive;
            // Hash any bytes after the xz stream too (there should be none).
            _ = try hashing.reader.discardRemaining();
            return hashing.result();
        },
        .zip => {
            try unpackZip(io, dir, &fr);
            // std.zip seeks, so its reads cannot be hashed in order. Hash
            // the file once more after the unpack instead: a file changed
            // during the unpack and changed back stays possible, but only for
            // someone who can already write the user's files.
            var again = file.reader(io, buf);
            var hash_buf: [4096]u8 = undefined;
            var hashing: Hashing = .init(&again.interface, &hash_buf);
            _ = try hashing.reader.discardRemaining();
            return hashing.result();
        },
    }
}

/// Keeps the environment's errors; everything else means a bad archive.
fn unpackFailure(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfMemory,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        error.Canceled,
        => err,
        else => error.BadArchive,
    };
}

/// A reader over `inner` that hashes and counts every byte it passes on.
/// It reads `inner` only with `readSliceShort` (no peek, no discard). Its
/// own buffer must not be empty.
const Hashing = struct {
    inner: *Io.Reader,
    reader: Io.Reader,
    sha: Sha256 = .init(.{}),
    size: u64 = 0,

    fn init(inner: *Io.Reader, buffer: []u8) Hashing {
        return .{ .inner = inner, .reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Hashing = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = try self.inner.readSliceShort(dest);
        if (n == 0) return error.EndOfStream;
        self.sha.update(dest[0..n]);
        self.size += n;
        w.advance(n);
        return n;
    }

    fn result(self: *Hashing) Seen {
        var out: Seen = .{ .size = self.size, .sha256 = undefined };
        self.sha.final(&out.sha256);
        return out;
    }
};

/// A reader over `inner` whose skips are reads. The std xz reader panics
/// when asked to skip bytes it has not decoded yet (`discard` is a TODO),
/// and the tar iterator skips padding.
const NoDiscard = struct {
    inner: *Io.Reader,
    reader: Io.Reader,

    fn init(inner: *Io.Reader, buffer: []u8) NoDiscard {
        return .{ .inner = inner, .reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *NoDiscard = @alignCast(@fieldParentPtr("reader", r));
        // `readSliceShort` only uses `readVec` on the inner reader; the xz
        // reader cannot `peek` either (its buffer starts empty).
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = try self.inner.readSliceShort(dest);
        if (n == 0) return error.EndOfStream;
        w.advance(n);
        return n;
    }
};

/// Unpacks a tar stream into `dir`: regular files and folders only. A
/// symlink, hard link or other entry, a name `cleanName` refuses, or the
/// same file twice is refused.
fn unpackTar(io: Io, dir: Dir, reader: *Io.Reader) !void {
    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var link_buf: [Dir.max_path_bytes]u8 = undefined;
    var clean_buf: [Dir.max_path_bytes]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var it: std.tar.Iterator = .init(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |entry| {
        const name = try cleanName(&clean_buf, entry.name);
        switch (entry.kind) {
            .directory => if (name.len != 0) try dir.createDirPath(io, name),
            .file => {
                const perms: Io.File.Permissions = if (entry.mode & 0o100 != 0) .executable_file else .default_file;
                var out = try createNewFile(io, dir, name, perms);
                defer out.close(io);
                var fw = out.writer(io, &write_buf);
                it.streamRemaining(entry, &fw.interface) catch |err| switch (err) {
                    error.WriteFailed => return fw.err orelse err,
                    else => return err,
                };
                fw.interface.flush() catch return fw.err orelse error.WriteFailed;
            },
            .sym_link => return error.SymlinkRefused,
        }
    }
}

/// Unpacks a zip entry by entry, with the same name rules as the tar path
/// (std.zip's own check lets `C:/x` and `:` through). File modes are not
/// kept; zip symlinks become plain files.
fn unpackZip(io: Io, dir: Dir, fr: *Io.File.Reader) !void {
    var name_buf: [Dir.max_path_bytes]u8 = undefined;
    var clean_buf: [Dir.max_path_bytes]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var it = try std.zip.Iterator.init(fr);
    while (try it.next()) |entry| {
        // Also refuses `\`, a leading `/` and `..` parts.
        const raw = try entry.getFilename(fr, &name_buf, .{});
        const name = try cleanName(&clean_buf, raw);
        if (raw[raw.len - 1] == '/') {
            if (entry.uncompressed_size != 0) return error.ZipBadDirectorySize;
            if (name.len != 0) try dir.createDirPath(io, name);
            continue;
        }
        var out = try createNewFile(io, dir, name, .default_file);
        defer out.close(io);
        var fw = out.writer(io, &write_buf);
        entry.extractTo(fr, &fw.interface) catch |err| switch (err) {
            error.WriteFailed => return fw.err orelse err,
            else => return err,
        };
        fw.interface.flush() catch return fw.err orelse error.WriteFailed;
    }
}

/// Creates `name` (a cleaned path) and its parent folders; an existing
/// file or folder at `name` is an error.
fn createNewFile(io: Io, dir: Dir, name: []const u8, perms: Io.File.Permissions) !Io.File {
    if (name.len == 0) return error.BadEntryName;
    if (std.fs.path.dirnamePosix(name)) |parent| try dir.createDirPath(io, parent);
    return dir.createFile(io, name, .{ .exclusive = true, .permissions = perms });
}

/// `name` without `.` and empty parts, joined with `/`. Refused: an
/// absolute name, `..`, `\`, `:`, control characters, and (on every host,
/// so a Linux test sees what Windows would do) Windows device names such as
/// `CON` or `nul.txt` and parts ending in `.` or a space.
fn cleanName(buf: []u8, name: []const u8) error{BadEntryName}![]const u8 {
    if (name.len == 0 or name[0] == '/') return error.BadEntryName;
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.BadEntryName;
        for (part) |c| if (c < 0x20 or c == 0x7f or c == '\\' or c == ':') return error.BadEntryName;
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.BadEntryName;
        if (windowsDeviceName(part)) return error.BadEntryName;
        const sep: usize = @intFromBool(n != 0);
        if (n + sep + part.len > buf.len) return error.BadEntryName;
        if (sep != 0) buf[n] = '/';
        n += sep;
        @memcpy(buf[n..][0..part.len], part);
        n += part.len;
    }
    return buf[0..n];
}

/// `CON`, `PRN`, `AUX`, `NUL`, `COM0`-`COM9`, `LPT0`-`LPT9`, in any case,
/// alone or before an extension.
fn windowsDeviceName(part: []const u8) bool {
    const stem_end = std.mem.indexOfScalar(u8, part, '.') orelse part.len;
    const stem = std.mem.trimEnd(u8, part[0..stem_end], " ");
    for ([_][]const u8{ "con", "prn", "aux", "nul" }) |d| {
        if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    }
    if (stem.len == 4 and std.ascii.isDigit(stem[3])) {
        if (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) return true;
    }
    return false;
}

/// Exactly one entry, the folder `top`, holding the `zig` file and `lib/`
/// (no symlinks).
fn checkLayout(io: Io, dir: Dir, top: []const u8) !void {
    var it = dir.iterate();
    var count: usize = 0;
    var found = false;
    while (try it.next(io)) |e| {
        count += 1;
        if (e.kind == .directory and std.mem.eql(u8, e.name, top)) found = true;
    }
    if (count != 1 or !found) return error.BadLayout;
    var top_dir = dir.openDir(io, top, .{ .follow_symlinks = false }) catch return error.BadLayout;
    defer top_dir.close(io);
    const exe = top_dir.statFile(io, exe_name, .{ .follow_symlinks = false }) catch return error.BadLayout;
    if (exe.kind != .file) return error.BadLayout;
    const lib = top_dir.statFile(io, "lib", .{ .follow_symlinks = false }) catch return error.BadLayout;
    if (lib.kind != .directory) return error.BadLayout;
}

/// True when `exe version` prints exactly the pinned version.
fn runsPin(io: Io, gpa: std.mem.Allocator, exe: []const u8, timeout_ms: u32) !bool {
    const r = process.runCapture(gpa, io, &.{ exe, "version" }, null, timeout_ms, 256) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return r.term.success() and std.mem.eql(u8, std.mem.trim(u8, r.stdout, " \t\r\n"), pins.zig_version);
}

/// True when `<toolchains>/<sub>/zig version` prints the pin.
fn folderWorks(io: Io, gpa: std.mem.Allocator, tc_abs: []const u8, sub: []const u8, timeout_ms: u32) !bool {
    const exe = try std.fs.path.join(gpa, &.{ tc_abs, sub, exe_name });
    defer gpa.free(exe);
    const st = Dir.cwd().statFile(io, exe, .{}) catch return false;
    if (st.kind != .file) return false;
    return runsPin(io, gpa, exe, timeout_ms);
}

/// True when `<toolchains_dir>/zig-<pin>` (an absolute path) holds a `zig`
/// whose `zig version` prints the pin within `timeout_ms`. Blocking.
pub fn installedWorks(io: Io, gpa: std.mem.Allocator, toolchains_dir: []const u8, timeout_ms: u32) bool {
    return targetWorks(io, gpa, toolchains_dir, timeout_ms) catch false;
}

fn targetWorks(io: Io, gpa: std.mem.Allocator, tc_abs: []const u8, timeout_ms: u32) !bool {
    return folderWorks(io, gpa, tc_abs, target_name, timeout_ms);
}

/// True for the rename errors that mean "something is at the target".
fn targetTaken(err: anyerror) bool {
    return switch (err) {
        // Windows may answer AccessDenied for an existing folder.
        error.PathAlreadyExists, error.DirNotEmpty, error.AccessDenied, error.NotDir, error.IsDir => true,
        else => false,
    };
}

/// Renames `old` to `new` in `dir` without replacing anything at `new`.
fn renameNoReplace(io: Io, dir: Dir, old: []const u8, new: []const u8) !void {
    dir.renamePreserve(old, dir, new, io) catch |err| switch (err) {
        // A plain rename replaces at most an empty folder, never a filled one.
        error.OperationUnsupported => return dir.rename(old, dir, new, io),
        else => return err,
    };
}

fn moveIntoPlace(io: Io, gpa: std.mem.Allocator, tc: Dir, tc_abs: []const u8, src: []const u8, opts: Options) !Result {
    const timeout_ms = opts.version_timeout_ms;
    if (renameNoReplace(io, tc, src, target_name)) |_| {
        return .installed;
    } else |err| if (!targetTaken(err)) return err;

    // Another install got there first, or a broken folder is in the way.
    if (try targetWorks(io, gpa, tc_abs, timeout_ms)) return .already_present;
    runHook(opts, "before_move_aside");
    var old_buf: [old_prefix.len + 16]u8 = undefined;
    const old = randomName(io, &old_buf, old_prefix);
    tc.rename(target_name, tc, old, io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer tc.deleteTree(io, old) catch {};
    // Another install may have placed a good folder between the check and
    // the move: if the folder moved aside works, put it back and keep it.
    if (try folderWorks(io, gpa, tc_abs, old, timeout_ms)) {
        if (renameNoReplace(io, tc, old, target_name)) |_| {
            return .already_present;
        } else |err| if (!targetTaken(err)) return err;
        if (try targetWorks(io, gpa, tc_abs, timeout_ms)) return .already_present;
    }
    renameNoReplace(io, tc, src, target_name) catch |err| {
        if (targetTaken(err) and try targetWorks(io, gpa, tc_abs, timeout_ms)) return .already_present;
        return err;
    };
    return .installed;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const build_options = @import("build_options");
const good_name = "zig-x86_64-linux-0.17.0.tar.xz";
const good_zip_name = "zig-x86_64-linux-0.17.0.zip";

const Fixture = struct {
    tmp: testing.TmpDir,
    /// Absolute path of `tmp`.
    root: []u8,
    archive: []u8,
    toolchains: []u8,
    sig: []u8,
    sha: [32]u8,
    size: u64,
    signer: minisign.TestSigner,

    /// Copies `fixture_path` into a fresh temp folder as `name`, and signs it
    /// with a test key for `signed_name`.
    fn init(fixture_path: []const u8, name: []const u8, signed_name: []const u8) !Fixture {
        const data = try readFixture(fixture_path);
        defer testing.allocator.free(data);
        return initBytes(data, name, signed_name);
    }

    /// As `init`, with the archive bytes given.
    fn initBytes(data: []const u8, name: []const u8, signed_name: []const u8) !Fixture {
        const a = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
        try tmp.dir.createDirPath(io, "toolchains");
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const root_owned = try a.dupe(u8, root);
        errdefer a.free(root_owned);
        const archive = try std.fs.path.join(a, &.{ root, name });
        errdefer a.free(archive);
        const toolchains = try std.fs.path.join(a, &.{ root, "toolchains" });
        errdefer a.free(toolchains);
        const signer = minisign.TestSigner.init(42, .{ 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8 });
        const sig = try signer.signFile(a, data, signed_name);
        var sha: [32]u8 = undefined;
        Sha256.hash(data, &sha, .{});
        return .{
            .tmp = tmp,
            .root = root_owned,
            .archive = archive,
            .toolchains = toolchains,
            .sig = sig,
            .sha = sha,
            .size = data.len,
            .signer = signer,
        };
    }

    fn deinit(f: *Fixture) void {
        const a = testing.allocator;
        a.free(f.root);
        a.free(f.archive);
        a.free(f.toolchains);
        a.free(f.sig);
        f.tmp.cleanup();
    }

    fn options(f: *const Fixture, name: []const u8) Options {
        return .{
            .archive_path = f.archive,
            .sig_text = f.sig,
            .archive_name = name,
            .expected_size = f.size,
            .expected_sha256 = f.sha,
            .key = f.signer.publicKey(),
            .toolchains_dir = f.toolchains,
        };
    }

    /// Names in the toolchains folder, sorted, joined with ",".
    fn listing(f: *const Fixture, buf: []u8) ![]const u8 {
        const io = testing.io;
        var dir = try f.tmp.dir.openDir(io, "toolchains", .{ .iterate = true });
        defer dir.close(io);
        var names: [16][]const u8 = undefined;
        var store: [16][64]u8 = undefined;
        var n: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (n == names.len) return error.TooManyEntries;
            const len = @min(e.name.len, 64);
            @memcpy(store[n][0..len], e.name[0..len]);
            names[n] = store[n][0..len];
            n += 1;
        }
        std.mem.sort([]const u8, names[0..n], {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        var w: Io.Writer = .fixed(buf);
        for (names[0..n], 0..) |name, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll(name);
        }
        return w.buffered();
    }

    fn expectListing(f: *const Fixture, want: []const u8) !void {
        var buf: [1024]u8 = undefined;
        try testing.expectEqualStrings(want, try f.listing(&buf));
    }

    fn expectInstalled(f: *const Fixture) !void {
        const io = testing.io;
        try f.expectListing(target_name);
        const st = try f.tmp.dir.statFile(io, "toolchains/" ++ target_name ++ "/" ++ exe_name, .{});
        try testing.expectEqual(Io.File.Kind.file, st.kind);
        const lib = try f.tmp.dir.statFile(io, "toolchains/" ++ target_name ++ "/lib", .{});
        try testing.expectEqual(Io.File.Kind.directory, lib.kind);
    }
};

fn readFixture(path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
}

fn skipOnWindows() !void {
    // The fixtures hold a POSIX shell script as `zig`.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

test "tar.xz installs" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    try testing.expectEqual(Result.installed, try install(testing.io, testing.allocator, f.options(good_name)));
    try f.expectInstalled();
    // A second install keeps the working folder.
    try testing.expectEqual(Result.already_present, try install(testing.io, testing.allocator, f.options(good_name)));
    try f.expectInstalled();
}

test "zip installs" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_good_zip, good_zip_name, good_zip_name);
    defer f.deinit();
    try testing.expectEqual(Result.installed, try install(testing.io, testing.allocator, f.options(good_zip_name)));
    try f.expectInstalled();
}

test "toolchains folder is created" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    var opts = f.options(good_name);
    const nested = try std.fs.path.join(testing.allocator, &.{ f.root, "new", "toolchains" });
    defer testing.allocator.free(nested);
    opts.toolchains_dir = nested;
    try testing.expectEqual(Result.installed, try install(testing.io, testing.allocator, opts));
    try f.tmp.dir.access(testing.io, "new/toolchains/" ++ target_name ++ "/" ++ exe_name, .{});
}

test "size or sha mismatch leaves nothing" {
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    var opts = f.options(good_name);
    opts.expected_size += 1;
    try testing.expectError(error.SizeMismatch, install(testing.io, testing.allocator, opts));
    try f.expectListing("");
    opts = f.options(good_name);
    opts.expected_size -= 1;
    try testing.expectError(error.SizeMismatch, install(testing.io, testing.allocator, opts));
    opts = f.options(good_name);
    opts.expected_sha256[31] ^= 1;
    try testing.expectError(error.ShaMismatch, install(testing.io, testing.allocator, opts));
    try f.expectListing("");
    try testing.expectEqualStrings("the download has the wrong size", describe(error.SizeMismatch));
    try testing.expectEqualStrings("a file system error", describe(error.FileSystem));
}

test "bad signature leaves nothing" {
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    var opts = f.options(good_name);
    // Signed by another key with the same id.
    const other = minisign.TestSigner.init(43, f.signer.key_id);
    opts.key = other.publicKey();
    try testing.expectError(error.BadSignature, install(testing.io, testing.allocator, opts));
    try f.expectListing("");
    // The real Zig signature is for another file.
    opts = f.options(good_name);
    const real = try Dir.cwd().readFileAlloc(testing.io, build_options.toolchain_real_minisig, testing.allocator, .limited(4096));
    defer testing.allocator.free(real);
    opts.sig_text = real;
    opts.key = try minisign.PublicKey.parse(pins.zig_minisign_key);
    try testing.expectError(error.BadSignature, install(testing.io, testing.allocator, opts));
    try f.expectListing("");
    // Signed for another name (a downgrade).
    var g = try Fixture.init(build_options.toolchain_good_tar, good_name, "zig-x86_64-linux-0.16.0.tar.xz");
    defer g.deinit();
    try testing.expectError(error.FileNameMismatch, install(testing.io, testing.allocator, g.options(good_name)));
    try g.expectListing("");
}

test "archive name is checked" {
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    for ([_][]const u8{ "", "zig-x86_64-linux-0.16.0.tar.xz", "zig-x86_64-linux-0.17.0.tar.gz", "../zig-x86_64-linux-0.17.0.tar.xz", "x/zig-x86_64-linux-0.17.0.tar.xz", "zig-0.17.0.tar.xz", "zig--0.17.0.tar.xz" }) |name| {
        try testing.expectError(error.BadArchiveName, install(testing.io, testing.allocator, f.options(name)));
    }
    try f.expectListing("");
}

test "two top folders refused" {
    var f = try Fixture.init(build_options.toolchain_two_top, good_name, good_name);
    defer f.deinit();
    try testing.expectError(error.BadLayout, install(testing.io, testing.allocator, f.options(good_name)));
    try f.expectListing("");
}

test "top folder must match the archive name" {
    // A good archive presented under another (signed) name.
    var f = try Fixture.init(build_options.toolchain_good_tar, "zig-aarch64-linux-0.17.0.tar.xz", "zig-aarch64-linux-0.17.0.tar.xz");
    defer f.deinit();
    try testing.expectError(error.BadLayout, install(testing.io, testing.allocator, f.options("zig-aarch64-linux-0.17.0.tar.xz")));
    try f.expectListing("");
}

test "version check fails leaves nothing" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_bad_version, good_name, good_name);
    defer f.deinit();
    try testing.expectError(error.VersionCheckFailed, install(testing.io, testing.allocator, f.options(good_name)));
    try f.expectListing("");
}

test "truncated archive leaves nothing" {
    const a = testing.allocator;
    const io = testing.io;
    const full = try Dir.cwd().readFileAlloc(io, build_options.toolchain_good_tar, a, .limited(1 << 20));
    defer a.free(full);
    const zip_full = try Dir.cwd().readFileAlloc(io, build_options.toolchain_good_zip, a, .limited(1 << 20));
    defer a.free(zip_full);
    // Every cut of both archives, signed as they are: the check passes and
    // the unpack must fail cleanly (no panic, nothing left).
    for ([_]struct { data: []const u8, name: []const u8 }{
        .{ .data = full, .name = good_name },
        .{ .data = zip_full, .name = good_zip_name },
    }) |c| {
        var cut: usize = 0;
        while (cut < c.data.len) : (cut += 7) {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = c.data[0..cut] });
            try tmp.dir.createDirPath(io, "tc");
            const root = try tmp.dir.realPathFileAlloc(io, ".", a);
            defer a.free(root);
            const archive = try std.fs.path.join(a, &.{ root, "a" });
            defer a.free(archive);
            const tc = try std.fs.path.join(a, &.{ root, "tc" });
            defer a.free(tc);
            const signer = minisign.TestSigner.init(42, @splat(1));
            const sig = try signer.signFile(a, c.data[0..cut], c.name);
            defer a.free(sig);
            var sha: [32]u8 = undefined;
            Sha256.hash(c.data[0..cut], &sha, .{});
            const r = install(io, a, .{
                .archive_path = archive,
                .sig_text = sig,
                .archive_name = c.name,
                .expected_size = cut,
                .expected_sha256 = sha,
                .key = signer.publicKey(),
                .toolchains_dir = tc,
            });
            if (r) |_| {
                std.debug.print("{s} cut at {d} of {d} installed\n", .{ c.name, cut, c.data.len });
                return error.TestUnexpectedResult;
            } else |err| switch (err) {
                error.BadArchive, error.BadLayout => {},
                else => return err,
            }
            var dir = try tmp.dir.openDir(io, "tc", .{ .iterate = true });
            defer dir.close(io);
            var it = dir.iterate();
            try testing.expect((try it.next(io)) == null);
        }
    }
}

const Meanwhile = struct {
    opts: Options,
    result: ?anyerror!Result = null,

    fn run(ctx: *anyopaque) void {
        const m: *Meanwhile = @ptrCast(@alignCast(ctx));
        m.result = install(testing.io, testing.allocator, m.opts);
    }
};

test "install when the target appears meanwhile" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    var second: Meanwhile = .{ .opts = f.options(good_name) };
    var opts = f.options(good_name);
    opts.test_hooks.before_rename = .{ .ctx = &second, .call = Meanwhile.run };
    try testing.expectEqual(Result.already_present, try install(testing.io, testing.allocator, opts));
    try testing.expectEqual(Result.installed, try second.result.?);
    try f.expectInstalled();
}

test "broken target is replaced" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    const io = testing.io;
    // A folder with a zig that prints another version.
    try f.tmp.dir.createDirPath(io, "toolchains/" ++ target_name ++ "/lib");
    try f.tmp.dir.writeFile(io, .{
        .sub_path = "toolchains/" ++ target_name ++ "/zig",
        .data = "#!/bin/sh\necho 0.16.0\n",
        .flags = .{ .permissions = .executable_file },
    });
    try testing.expectEqual(Result.installed, try install(io, testing.allocator, f.options(good_name)));
    try f.expectInstalled();
    var buf: [64]u8 = undefined;
    const script = try f.tmp.dir.readFile(io, "toolchains/" ++ target_name ++ "/zig", &buf);
    try testing.expectEqualStrings("#!/bin/sh\necho 0.17.0\n", script);
}

// Hostile tar contents, unpacked without the xz layer.

fn tarWith(a: std.mem.Allocator, build: *const fn (w: *std.tar.Writer) anyerror!void) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var w: std.tar.Writer = .{ .underlying_writer = &out.writer };
    try build(&w);
    try w.finishPedantically();
    return out.toOwnedSlice();
}

fn unpackTarBytes(data: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var r: Io.Reader = .fixed(data);
    try unpackTar(testing.io, tmp.dir, &r);
}

test "tar: symlinks and paths outside are refused" {
    const a = testing.allocator;
    const cases = [_]*const fn (w: *std.tar.Writer) anyerror!void{
        struct {
            fn f(w: *std.tar.Writer) anyerror!void {
                try w.writeLink("zig-x86_64-linux-0.17.0/lib", "/etc", .{});
            }
        }.f,
        struct {
            fn f(w: *std.tar.Writer) anyerror!void {
                try w.writeFileBytes("zig-x86_64-linux-0.17.0/../../evil", "x", .{});
            }
        }.f,
        struct {
            fn f(w: *std.tar.Writer) anyerror!void {
                try w.writeFileBytes("/tmp/evil", "x", .{});
            }
        }.f,
        struct {
            fn f(w: *std.tar.Writer) anyerror!void {
                try w.writeFileBytes("a\\b", "x", .{});
            }
        }.f,
        struct {
            fn f(w: *std.tar.Writer) anyerror!void {
                // The same file twice.
                try w.writeFileBytes("a/b", "x", .{});
                try w.writeFileBytes("a/b", "y", .{});
            }
        }.f,
    };
    for (cases) |build| {
        const data = try tarWith(a, build);
        defer a.free(data);
        if (unpackTarBytes(data)) |_| return error.TestUnexpectedResult else |_| {}
    }
    // A plain tree unpacks.
    const ok = try tarWith(a, struct {
        fn f(w: *std.tar.Writer) anyerror!void {
            try w.writeDir("top", .{});
            try w.writeFileBytes("top/./x/y", "hello", .{ .mode = 0o755 });
        }
    }.f);
    defer a.free(ok);
    try unpackTarBytes(ok);
}

test "cleanName: Windows device names and odd endings" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a/b/c.txt", try cleanName(&buf, "./a//b/./c.txt"));
    try testing.expectEqualStrings("a/console/com10/nul_x", try cleanName(&buf, "a/console/com10/nul_x"));
    for ([_][]const u8{ "a/CON", "a/nul.txt", "Aux", "a/com1", "LPT9.h", "a/prn.x.y", "a/b.", "a/b ", "con /x", "C:/x", "a:b", "..", "/x", "a\\b", "a/\x01" }) |bad| {
        try testing.expectError(error.BadEntryName, cleanName(&buf, bad));
    }
}

// Archives built in the tests: a stored zip, and a tar in an xz container
// with uncompressed LZMA2 chunks (std has no xz compressor).

const top_entry = "zig-x86_64-linux-0.17.0/";
const good_script = "#!/bin/sh\necho 0.17.0\n";

const ZipEntry = struct { name: []const u8, data: []const u8 = "" };

fn zipStore(a: std.mem.Allocator, entries: []const ZipEntry) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    var offsets: [16]u32 = undefined;
    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(w.end);
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x03\x04");
        for ([_]u16{ 20, 0, 0, 0, 0x21 }) |v| try w.writeInt(u16, v, .little);
        for ([_]u32{ crc, @intCast(e.data.len), @intCast(e.data.len) }) |v| try w.writeInt(u32, v, .little);
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(e.name);
        try w.writeAll(e.data);
    }
    const cd_start: u32 = @intCast(w.end);
    for (entries, 0..) |e, i| {
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x01\x02");
        for ([_]u16{ 20, 20, 0, 0, 0, 0x21 }) |v| try w.writeInt(u16, v, .little);
        for ([_]u32{ crc, @intCast(e.data.len), @intCast(e.data.len) }) |v| try w.writeInt(u32, v, .little);
        for ([_]u16{ @intCast(e.name.len), 0, 0, 0, 0 }) |v| try w.writeInt(u16, v, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, offsets[i], .little);
        try w.writeAll(e.name);
    }
    const cd_size: u32 = @as(u32, @intCast(w.end)) - cd_start;
    try w.writeAll("PK\x05\x06");
    for ([_]u16{ 0, 0, @intCast(entries.len), @intCast(entries.len) }) |v| try w.writeInt(u16, v, .little);
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

fn writeUleb(w: *Io.Writer, value: u64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7f);
        v >>= 7;
        if (v == 0) return w.writeByte(byte);
        try w.writeByte(byte | 0x80);
    }
}

fn xzStore(a: std.mem.Allocator, data: []const u8) ![]u8 {
    const Crc32 = std.hash.Crc32;
    var out: Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    const flags = [2]u8{ 0, 0 }; // no check
    try w.writeAll(&.{ 0xFD, '7', 'z', 'X', 'Z', 0 });
    try w.writeAll(&flags);
    try w.writeInt(u32, Crc32.hash(&flags), .little);
    const block_start = w.end;
    // Block header: size (2 * 4 bytes before the CRC), flags (one filter),
    // LZMA2 filter id, one property byte, padding.
    const header = [8]u8{ 2, 0, 0x21, 1, 0, 0, 0, 0 };
    try w.writeAll(&header);
    try w.writeInt(u32, Crc32.hash(&header), .little);
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(data.len - off, 1 << 16);
        try w.writeByte(if (off == 0) 0x01 else 0x02); // uncompressed chunk
        try w.writeInt(u16, @intCast(n - 1), .big);
        try w.writeAll(data[off..][0..n]);
        off += n;
    }
    try w.writeByte(0);
    const unpadded = w.end - block_start;
    try w.splatByteAll(0, (4 - unpadded % 4) % 4);
    // Index with one record.
    var index: Io.Writer.Allocating = .init(a);
    defer index.deinit();
    try index.writer.writeByte(0);
    try writeUleb(&index.writer, 1);
    try writeUleb(&index.writer, unpadded);
    try writeUleb(&index.writer, data.len);
    try index.writer.splatByteAll(0, (4 - index.writer.end % 4) % 4);
    const index_bytes = index.written();
    try w.writeAll(index_bytes);
    try w.writeInt(u32, Crc32.hash(index_bytes), .little);
    const index_size = index_bytes.len + 4;
    // Footer.
    var tail: [6]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], @intCast(index_size / 4 - 1), .little);
    tail[4..6].* = flags;
    try w.writeInt(u32, Crc32.hash(&tail), .little);
    try w.writeAll(&tail);
    try w.writeAll("YZ");
    return out.toOwnedSlice();
}

/// One raw ustar header (any type flag and size field) and its body.
fn tarEntry(w: *Io.Writer, name: []const u8, typeflag: u8, size_field: u64, body: []const u8, link: []const u8) !void {
    var h: [512]u8 = @splat(0);
    @memcpy(h[0..name.len], name);
    _ = try std.fmt.bufPrint(h[100..108], "{o:0>7}\x00", .{@as(u32, 0o755)});
    _ = try std.fmt.bufPrint(h[108..116], "{o:0>7}\x00", .{@as(u32, 0)});
    _ = try std.fmt.bufPrint(h[116..124], "{o:0>7}\x00", .{@as(u32, 0)});
    _ = try std.fmt.bufPrint(h[124..136], "{o:0>11}\x00", .{size_field});
    _ = try std.fmt.bufPrint(h[136..148], "{o:0>11}\x00", .{@as(u32, 0)});
    @memset(h[148..156], ' ');
    h[156] = typeflag;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..265], "ustar\x0000");
    var sum: u32 = 0;
    for (h) |c| sum += c;
    _ = try std.fmt.bufPrint(h[148..156], "{o:0>6}\x00 ", .{sum});
    try w.writeAll(&h);
    try w.writeAll(body);
    try w.splatByteAll(0, (512 - body.len % 512) % 512);
}

fn paxRecord(a: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    const body_len = key.len + value.len + 3; // ' ', '=', '\n'
    var digits: usize = 1;
    while (std.fmt.count("{d}", .{body_len + digits}) != digits) digits += 1;
    return std.fmt.allocPrint(a, "{d} {s}={s}\n", .{ body_len + digits, key, value });
}

/// A good tree, then `extra` entries, then the end blocks.
fn tarWithGood(a: std.mem.Allocator, extra: *const fn (a: std.mem.Allocator, w: *Io.Writer) anyerror!void) ![]u8 {
    var out: Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try tarEntry(w, top_entry, '5', 0, "", "");
    try tarEntry(w, top_entry ++ "lib/", '5', 0, "", "");
    try tarEntry(w, top_entry ++ "zig", '0', good_script.len, good_script, "");
    try extra(a, w);
    try w.splatByteAll(0, 1024);
    return out.toOwnedSlice();
}

fn installBytes(archive: []const u8, name: []const u8) !Fixture {
    return Fixture.initBytes(archive, name, name);
}

test "built archives install (helpers are right)" {
    try skipOnWindows();
    const a = testing.allocator;
    const tar = try tarWithGood(a, struct {
        fn f(_: std.mem.Allocator, _: *Io.Writer) anyerror!void {}
    }.f);
    defer a.free(tar);
    const xz = try xzStore(a, tar);
    defer a.free(xz);
    var f = try installBytes(xz, good_name);
    defer f.deinit();
    try testing.expectEqual(Result.installed, try install(testing.io, a, f.options(good_name)));
    try f.expectInstalled();

    const zip = try zipStore(a, &.{ .{ .name = top_entry }, .{ .name = top_entry ++ "lib/" }, .{ .name = top_entry ++ "zig", .data = good_script } });
    defer a.free(zip);
    var g = try installBytes(zip, good_zip_name);
    defer g.deinit();
    try testing.expectEqual(Result.installed, try install(testing.io, a, g.options(good_zip_name)));
    try g.expectInstalled();
}

test "zip: hostile names leave nothing" {
    const a = testing.allocator;
    const hostile = [_][]const u8{ "../evil", "/abs", "C:/x", "C:x", top_entry ++ "zig", top_entry ++ "..\\evil", top_entry ++ "CON", top_entry ++ "lib/aux.h", top_entry ++ "a\x01" };
    for (hostile) |name| {
        const zip = try zipStore(a, &.{
            .{ .name = top_entry },
            .{ .name = top_entry ++ "lib/" },
            .{ .name = top_entry ++ "zig", .data = good_script },
            .{ .name = name, .data = "x" },
        });
        defer a.free(zip);
        var f = try installBytes(zip, good_zip_name);
        defer f.deinit();
        try testing.expectError(error.BadArchive, install(testing.io, a, f.options(good_zip_name)));
        try f.expectListing("");
        // Nothing next to the toolchains folder either.
        try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "evil", .{}));
    }
}

test "tar: hostile entries leave nothing" {
    const a = testing.allocator;
    const cases = [_]*const fn (a: std.mem.Allocator, w: *Io.Writer) anyerror!void{
        // A hard link.
        struct {
            fn f(_: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                try tarEntry(w, top_entry ++ "lib/hard", '1', 0, "", top_entry ++ "zig");
            }
        }.f,
        // A symlink.
        struct {
            fn f(_: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                try tarEntry(w, top_entry ++ "lib/std", '2', 0, "", "/etc");
            }
        }.f,
        // A GNU long name longer than the name buffer.
        struct {
            fn f(al: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                const long = try al.alloc(u8, Dir.max_path_bytes + 100);
                defer al.free(long);
                @memset(long, 'a');
                try tarEntry(w, "././@LongLink", 'L', long.len, long, "");
                try tarEntry(w, "short", '0', 1, "x", "");
            }
        }.f,
        // A pax path longer than the name buffer.
        struct {
            fn f(al: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                const long = try al.alloc(u8, Dir.max_path_bytes + 100);
                defer al.free(long);
                @memset(long, 'b');
                const rec = try paxRecord(al, "path", long);
                defer al.free(rec);
                try tarEntry(w, "pax", 'x', rec.len, rec, "");
                try tarEntry(w, "short", '0', 1, "x", "");
            }
        }.f,
        // A pax size larger than the data that follows.
        struct {
            fn f(al: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                const rec = try paxRecord(al, "size", "1000000");
                defer al.free(rec);
                try tarEntry(w, "pax", 'x', rec.len, rec, "");
                try tarEntry(w, top_entry ++ "lib/big", '0', 5, "hello", "");
            }
        }.f,
        // A pax path that leaves the folder.
        struct {
            fn f(al: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                const rec = try paxRecord(al, "path", "../../evil");
                defer al.free(rec);
                try tarEntry(w, "pax", 'x', rec.len, rec, "");
                try tarEntry(w, top_entry ++ "lib/ok", '0', 1, "x", "");
            }
        }.f,
        // A file where a folder already is.
        struct {
            fn f(_: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                try tarEntry(w, top_entry ++ "lib", '0', 1, "x", "");
            }
        }.f,
        // A folder where a file already is, then a file inside it.
        struct {
            fn f(_: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                try tarEntry(w, top_entry ++ "zig/", '5', 0, "", "");
                try tarEntry(w, top_entry ++ "zig/x", '0', 1, "x", "");
            }
        }.f,
        // The same file twice.
        struct {
            fn f(_: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                try tarEntry(w, top_entry ++ "zig", '0', 1, "x", "");
            }
        }.f,
        // A Windows device name.
        struct {
            fn f(_: std.mem.Allocator, w: *Io.Writer) anyerror!void {
                try tarEntry(w, top_entry ++ "lib/nul.txt", '0', 1, "x", "");
            }
        }.f,
    };
    for (cases, 0..) |extra, i| {
        const tar = try tarWithGood(a, extra);
        defer a.free(tar);
        const xz = try xzStore(a, tar);
        defer a.free(xz);
        var f = try installBytes(xz, good_name);
        defer f.deinit();
        _ = install(testing.io, a, f.options(good_name)) catch |err| {
            if (err != error.BadArchive) {
                std.debug.print("case {d}: {t}\n", .{ i, err });
                return error.TestUnexpectedResult;
            }
            try f.expectListing("");
            try testing.expectError(error.FileNotFound, f.tmp.dir.access(testing.io, "evil", .{}));
            continue;
        };
        std.debug.print("case {d} installed\n", .{i});
        return error.TestUnexpectedResult;
    }
}

const Swap = struct {
    path: []const u8,
    data: []const u8,

    fn run(ctx: *anyopaque) void {
        const s: *Swap = @ptrCast(@alignCast(ctx));
        // Same file (same inode), new content.
        Dir.cwd().writeFile(testing.io, .{ .sub_path = s.path, .data = s.data }) catch @panic("swap failed");
    }
};

test "archive swapped after the check leaves nothing" {
    try skipOnWindows();
    const a = testing.allocator;
    // tar.xz: a valid archive of another size and content.
    {
        var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
        defer f.deinit();
        const other = try readFixture(build_options.toolchain_bad_version);
        defer a.free(other);
        var swap: Swap = .{ .path = f.archive, .data = other };
        var opts = f.options(good_name);
        opts.test_hooks.after_check = .{ .ctx = &swap, .call = Swap.run };
        try testing.expectError(error.ArchiveChanged, install(testing.io, a, opts));
        try f.expectListing("");
    }
    // zip: the same size, one central directory byte changed (still valid).
    {
        var f = try Fixture.init(build_options.toolchain_good_zip, good_zip_name, good_zip_name);
        defer f.deinit();
        const other = try readFixture(build_options.toolchain_good_zip);
        defer a.free(other);
        const cd = std.mem.indexOf(u8, other, "PK\x01\x02").?;
        other[cd + 4] ^= 1; // "version made by"
        var swap: Swap = .{ .path = f.archive, .data = other };
        var opts = f.options(good_zip_name);
        opts.test_hooks.after_check = .{ .ctx = &swap, .call = Swap.run };
        try testing.expectError(error.ArchiveChanged, install(testing.io, a, opts));
        try f.expectListing("");
    }
}

const PlaceGood = struct {
    fixture: *const Fixture,
    result: ?Error!Result = null,

    /// Replaces the broken target with a good install, as a second editor would.
    fn run(ctx: *anyopaque) void {
        const p: *PlaceGood = @ptrCast(@alignCast(ctx));
        const f = p.fixture;
        f.tmp.dir.deleteTree(testing.io, "toolchains/" ++ target_name) catch @panic("delete failed");
        p.result = install(testing.io, testing.allocator, f.options(good_name));
    }
};

test "a good folder placed meanwhile is never deleted" {
    try skipOnWindows();
    var f = try Fixture.init(build_options.toolchain_good_tar, good_name, good_name);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.createDirPath(io, "toolchains/" ++ target_name ++ "/lib");
    try f.tmp.dir.writeFile(io, .{
        .sub_path = "toolchains/" ++ target_name ++ "/zig",
        .data = "#!/bin/sh\necho 0.16.0\n",
        .flags = .{ .permissions = .executable_file },
    });
    var place: PlaceGood = .{ .fixture = &f };
    var opts = f.options(good_name);
    opts.test_hooks.before_move_aside = .{ .ctx = &place, .call = PlaceGood.run };
    try testing.expectEqual(Result.already_present, try install(io, testing.allocator, opts));
    try testing.expectEqual(Result.installed, try place.result.?);
    try f.expectInstalled();
}
