//! POSIX loader (Linux and macOS): a thin wrapper over `dlopen`. Stub.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const elf = @import("elf.zig");
const safe_open = @import("safe_open.zig");
const testing_support = @import("testing_support.zig");

pub const LoadError = error{ LoadFailed, Unsupported } || elf.ElfError;

/// Handle of an open shared library.
pub const Library = struct {
    handle: *anyopaque,
};

const setDiag = elf.setDiag;

/// Opens the shared library at `p` with `RTLD_NOW | RTLD_LOCAL`. On ELF targets
/// the file is first checked with `elf.checkComplete`, so a truncated or
/// corrupt file is refused before `dlopen` sees it. macOS skips the check
/// (Mach-O checking is stage 7 work).
/// On failure `diag` holds one NUL-terminated sentence (read it with
/// `elf.diagText`): `error.LoadFailed` carries the `dlerror` text, or the
/// reason the file could not be read for the check.
pub fn open(a: std.mem.Allocator, io: std.Io, p: path.OsPath, diag: *[256]u8) LoadError!Library {
    if (builtin.object_format == .elf) {
        try checkFile(io, p, diag);
    }
    const z = a.dupeSentinel(u8, p.bytes, 0) catch {
        setDiag(diag, "Out of memory while loading {s}.", .{p.bytes});
        return error.LoadFailed;
    };
    defer a.free(z);
    var flags: std.c.RTLD = .{ .NOW = true };
    if (@hasField(std.c.RTLD, "LOCAL")) flags.LOCAL = true;
    const handle = std.c.dlopen(z.ptr, flags) orelse {
        const msg: []const u8 = if (std.c.dlerror()) |m| std.mem.span(m) else "no dlerror message";
        setDiag(diag, "{s} (while loading {s})", .{ msg, p.bytes });
        return error.LoadFailed;
    };
    return .{ .handle = handle };
}

fn checkFile(io: std.Io, p: path.OsPath, diag: *[256]u8) LoadError!void {
    // Never blocks on a FIFO swapped in for the library; only a regular
    // file goes on to `dlopen`.
    const file = safe_open.openRegular(io, p.bytes, .{}) catch |err| {
        setDiag(diag, "Cannot open {s} to check it: {s}.", .{ p.bytes, switch (err) {
            error.NotRegular => "it is not a regular file",
            else => @errorName(err),
        } });
        return error.LoadFailed;
    };
    defer file.close(io);
    elf.checkComplete(io, file, diag) catch |err| switch (err) {
        error.NotElf64, error.Truncated, error.Corrupt => |e| return e,
        else => {
            setDiag(diag, "Cannot read {s} to check it: {s}.", .{ p.bytes, @errorName(err) });
            return error.LoadFailed;
        },
    };
}

/// Looks up the symbol `name`. `T` must be a pointer to a function type.
/// Returns null when the library has no such symbol.
pub fn lookup(lib: Library, comptime T: type, name: [:0]const u8) ?T {
    comptime {
        const ok = switch (@typeInfo(T)) {
            .pointer => |ptr| @typeInfo(ptr.child) == .@"fn",
            else => false,
        };
        if (!ok) @compileError("lookup: T must be a pointer to a function type, got " ++ @typeName(T));
    }
    const sym = std.c.dlsym(lib.handle, name.ptr) orelse return null;
    return @ptrCast(@alignCast(sym));
}

pub fn close(lib: Library) void {
    _ = std.c.dlclose(lib.handle);
}

test "integration: loader open lookup close" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lib_path = try testing_support.buildAnswerLib(a, tmp);
    defer a.free(lib_path.bytes);
    var diag: [256]u8 = undefined;
    const lib = try open(a, std.testing.io, lib_path, &diag);
    defer close(lib);
    const answer = lookup(lib, *const fn () callconv(.c) i32, "answer") orelse return error.SymbolMissing;
    try std.testing.expectEqual(@as(i32, 42), answer());
}

test "loader missing symbol" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lib_path = try testing_support.buildAnswerLib(a, tmp);
    defer a.free(lib_path.bytes);
    var diag: [256]u8 = undefined;
    const lib = try open(a, std.testing.io, lib_path, &diag);
    defer close(lib);
    try std.testing.expect(lookup(lib, *const fn () callconv(.c) i32, "no_such_symbol") == null);
}

test "loader refuses a truncated library" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lib_path = try testing_support.buildAnswerLib(a, tmp);
    defer a.free(lib_path.bytes);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, lib_path.bytes, a, .unlimited);
    defer a.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "cut.so", .data = bytes[0 .. bytes.len / 2] });
    const cut = try path.join(a, path.OsPath.fromTrusted(std.fs.path.dirname(lib_path.bytes).?), &.{"cut.so"});
    defer a.free(cut.bytes);
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, open(a, io, cut, &diag));
}

test "loader reports a dlopen failure" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    var diag: [256]u8 = undefined;
    const r = open(a, std.testing.io, path.OsPath.fromTrusted("/no/such/dir/libx.so"), &diag);
    try std.testing.expectError(error.LoadFailed, r);
    try std.testing.expect(std.mem.indexOf(u8, elf.diagText(&diag), "/no/such/dir/libx.so") != null);
}
