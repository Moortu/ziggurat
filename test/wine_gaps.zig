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

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// Wine's ntdll exports `wine_get_version`; Windows' does not.
fn underWine() bool {
    const ntdll = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return GetProcAddress(ntdll, "wine_get_version") != null;
}
