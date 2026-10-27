//! Windows loader: `LoadLibraryExW`, `GetProcAddress` and `FreeLibrary`.
//! Before a load the file is checked with `pe.checkComplete`, so a truncated
//! or corrupt DLL is refused before Windows sees it.
const std = @import("std");
const path = @import("path.zig");
const elf = @import("elf.zig");
const pe = @import("pe.zig");
const safe_open = @import("safe_open.zig");
const win32 = @import("win32.zig");

pub const LoadError = error{ LoadFailed, Unsupported } || elf.ElfError || pe.Error;

/// Handle of an open DLL (an `HMODULE`).
pub const Library = struct {
    handle: *anyopaque,
};

const setDiag = elf.setDiag;

const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: u32 = 0x0000_0100;
const LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: u32 = 0x0000_1000;
const FORMAT_MESSAGE_IGNORE_INSERTS: u32 = 0x0000_0200;
const FORMAT_MESSAGE_FROM_SYSTEM: u32 = 0x0000_1000;
const FORMAT_MESSAGE_MAX_WIDTH_MASK: u32 = 0x0000_00ff;

/// Opens the DLL at `p` with
/// `LoadLibraryExW(path, null, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)`:
/// the DLL's own folder and the system folders are searched for its
/// dependencies, never the working folder or PATH. `p` is made fully
/// qualified first (`GetFullPathNameW`); a path of 260 characters or more
/// gets the `\\?\` prefix.
/// The file is first checked with `pe.checkComplete`.
/// On failure `diag` holds one NUL-terminated sentence (read it with
/// `elf.diagText`): `error.LoadFailed` carries the Windows message text
/// (`FormatMessageW`), or the reason the file could not be read for the check;
/// `error.Truncated`, `error.NotPe` or `error.BadHeader` the check's reason.
pub fn open(a: std.mem.Allocator, io: std.Io, p: path.OsPath, diag: *[256]u8) LoadError!Library {
    try checkFile(a, io, p, diag);
    const wide = win32.fullPath(a, p.bytes) catch |err| {
        setDiag(diag, "Cannot make a full path of {s}: {s}.", .{ p.bytes, @errorName(err) });
        return error.LoadFailed;
    };
    defer a.free(wide);
    const handle = win32.LoadLibraryExW(wide.ptr, null, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS) orelse {
        const code = win32.GetLastError();
        var buf: [256]u8 = undefined;
        setDiag(diag, "{s} (Windows error {d}, while loading {s})", .{ errorText(code, &buf), code, p.bytes });
        return error.LoadFailed;
    };
    return .{ .handle = handle };
}

fn checkFile(a: std.mem.Allocator, io: std.Io, p: path.OsPath, diag: *[256]u8) LoadError!void {
    return safe_open.checkWholeFile(a, io, p.bytes, diag, pe.Error, pe.checkCompleteDiag);
}

/// The system's text for the Windows error `code`, without a final period
/// or line break, or "unknown error" when there is none.
fn errorText(code: u32, out: *[256]u8) []const u8 {
    var wbuf: [256]u16 = undefined;
    const n = win32.FormatMessageW(
        FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS | FORMAT_MESSAGE_MAX_WIDTH_MASK,
        null,
        code,
        0,
        &wbuf,
        wbuf.len,
        null,
    );
    if (n == 0 or n > wbuf.len) return "unknown error";
    // Convert unit by unit so the result always fits `out`.
    var len: usize = 0;
    var it = std.unicode.Wtf16LeIterator.init(wbuf[0..n]);
    while (it.nextCodepoint()) |cp| {
        var enc: [4]u8 = undefined;
        const k = std.unicode.wtf8Encode(cp, &enc) catch continue;
        if (len + k > out.len) break;
        @memcpy(out[len..][0..k], enc[0..k]);
        len += k;
    }
    return std.mem.trimEnd(u8, out[0..len], " \t\r\n.");
}

/// Looks up the symbol `name`. `T` must be a pointer to a function type.
/// Returns null when the DLL has no such symbol.
pub fn lookup(lib: Library, comptime T: type, name: [:0]const u8) ?T {
    comptime {
        const ok = switch (@typeInfo(T)) {
            .pointer => |ptr| @typeInfo(ptr.child) == .@"fn",
            else => false,
        };
        if (!ok) @compileError("lookup: T must be a pointer to a function type, got " ++ @typeName(T));
    }
    const sym = win32.GetProcAddress(lib.handle, name.ptr) orelse return null;
    return @ptrCast(@alignCast(sym));
}

pub fn close(lib: Library) void {
    _ = win32.FreeLibrary(lib.handle);
}

const builtin = @import("builtin");

/// Copies the fixture DLL (`build_options.answer_dll`) to `<tmp>/<parts...>/<name>`,
/// creating the folders, and returns the absolute path; the caller frees `.bytes`.
fn copyFixture(a: std.mem.Allocator, tmp: std.testing.TmpDir, parts: []const []const u8, name: []const u8, cut: bool) !path.OsPath {
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, @import("build_options").answer_dll, a, .unlimited);
    defer a.free(bytes);
    var dir_parts: std.ArrayList([]const u8) = .empty;
    defer dir_parts.deinit(a);
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    var cur: path.OsPath = .fromTrusted(try a.dupe(u8, base));
    for (parts) |part| {
        const next = try path.join(a, cur, &.{part});
        a.free(cur.bytes);
        cur = next;
        try std.Io.Dir.cwd().createDir(io, cur.bytes, .default_dir);
    }
    defer a.free(cur.bytes);
    const file = try path.join(a, cur, &.{name});
    errdefer a.free(file.bytes);
    const data = if (cut) bytes[0 .. bytes.len / 2] else bytes;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file.bytes, .data = data });
    return file;
}

test "load, lookup, close a DLL" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try copyFixture(a, tmp, &.{}, "answer.dll", false);
    defer a.free(p.bytes);
    var diag: [256]u8 = undefined;
    const lib = try open(a, std.testing.io, p, &diag);
    defer close(lib);
    const answer = lookup(lib, *const fn () callconv(.c) i32, "answer") orelse return error.SymbolMissing;
    try std.testing.expectEqual(@as(i32, 42), answer());
    try std.testing.expect(lookup(lib, *const fn () callconv(.c) i32, "no_such_symbol") == null);
}

test "long path over 260 characters" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var names: [5][61]u8 = undefined;
    var parts: [5][]const u8 = undefined;
    for (&names, &parts, 0..) |*n, *part, i| {
        n.* = @splat('a');
        n[60] = '1' + @as(u8, @intCast(i));
        part.* = n;
    }
    const p = try copyFixture(a, tmp, &parts, "answer.dll", false);
    defer a.free(p.bytes);
    try std.testing.expect(p.bytes.len > 300);
    var diag: [256]u8 = undefined;
    const lib = open(a, std.testing.io, p, &diag) catch |err| {
        std.debug.print("{t}: {s}\n", .{ err, elf.diagText(&diag) });
        return err;
    };
    defer close(lib);
    const answer = lookup(lib, *const fn () callconv(.c) i32, "answer") orelse return error.SymbolMissing;
    try std.testing.expectEqual(@as(i32, 42), answer());
}

test "a truncated DLL gives the completeness error, not a crash" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const p = try copyFixture(a, tmp, &.{}, "cut.dll", true);
    defer a.free(p.bytes);
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, open(a, std.testing.io, p, &diag));
    try std.testing.expect(std.mem.indexOf(u8, elf.diagText(&diag), "cut.dll") != null);
}

test "a missing DLL names the path" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const p = try path.join(a, .fromTrusted(base), &.{"none.dll"});
    defer a.free(p.bytes);
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.LoadFailed, open(a, std.testing.io, p, &diag));
    try std.testing.expect(std.mem.indexOf(u8, elf.diagText(&diag), "none.dll") != null);
}
