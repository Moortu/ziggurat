//! The tests Wine cannot run, in one place.
//!
//! A test in this list calls `skip(name)` first and returns
//! `error.SkipZigTest` when it is true. `skip` is true only for a Windows
//! test binary that runs under Wine; on real Windows and elsewhere every
//! test runs.

const std = @import("std");
const builtin = @import("builtin");

/// One test Wine cannot run, and why.
pub const Gap = struct {
    /// The test's name as the test runner prints it.
    name: []const u8,
    /// The cause, from the Wine findings.
    cause: []const u8,
};

/// Each name is as the test runner prints it: `<file>.test.<test name>`.
/// Empty since the Windows locks moved to `LockFileEx` (which Wine runs);
/// the 17 lock tests that were listed here now run under Wine.
pub const gaps = [_]Gap{};

/// True when the test `name` is a listed gap and this binary runs under
/// Wine. A name that is not listed is a compile error.
pub fn skip(comptime name: []const u8) bool {
    comptime {
        for (gaps) |g| {
            if (std.mem.eql(u8, g.name, name)) break;
        } else @compileError("wine_gaps: \"" ++ name ++ "\" is not listed");
    }
    if (builtin.os.tag != .windows) return false;
    return underWine();
}

/// Gaps of the Wine end-to-end tests (test/host/wine_e2e.zig). Those tests
/// run on Linux and start Windows programs under Wine, so `skip` does not
/// apply: each one checks that its gap still holds, runs up to it, checks
/// what the gap looks like there, and only then skips. When Wine closes
/// the gap, the test runs to its end.
pub const e2e_gaps = [_]Gap{
    .{
        .name = "wine editor builds and runs a script",
        .cause = zig_lock_gap,
    },
    .{
        .name = "linux export from the windows editor",
        .cause = zig_lock_gap,
    },
};

/// Why the Windows Zig cannot compile under Wine 11.19.
const zig_lock_gap =
    "zig.exe 0.17.0 compiles nothing under Wine 11.19: its build cache opens " ++
    "every manifest with a file lock, std calls NtLockFile with an I/O status " ++
    "block, and Wine answers STATUS_NOT_IMPLEMENTED (`fixme:file:NtLockFile " ++
    "Unimplemented yet parameter`), so the compiler stops with " ++
    "`unable to load \"std.zig\": Unexpected` or `checking cache failed: " ++
    "manifest_create Unexpected`. `zig.exe version` works.";

/// The cause of the end-to-end gap `name`. A name that is not listed is a
/// compile error.
pub fn e2eGap(comptime name: []const u8) []const u8 {
    const cause = comptime for (e2e_gaps) |g| {
        if (std.mem.eql(u8, g.name, name)) break g.cause;
    } else @compileError("wine_gaps: \"" ++ name ++ "\" is not an end-to-end gap");
    return cause;
}

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// Wine's ntdll exports `wine_get_version`; Windows' does not.
fn underWine() bool {
    const ntdll = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return GetProcAddress(ntdll, "wine_get_version") != null;
}
