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

/// std's `File.tryLock`/`lock` on Windows is `NtLockFile` with an I/O
/// status block; Wine answers NOT_IMPLEMENTED (NTSTATUS 0xc0000002,
/// std/Io/Threaded.zig `fileTryLock`), so every test that takes a file lock
/// fails under Wine. Real Windows supports the call. Until the Windows locks
/// move to `LockFileEx`.
const lock_cause = "NtLockFile returns NOT_IMPLEMENTED under Wine (std File.tryLock/lock)";

/// Each name is as the test runner prints it: `<file>.test.<test name>`.
pub const gaps = [_]Gap{
    .{ .name = "generation_store.test.a game's pin keeps its generation from an editor's sweep", .cause = lock_cause },
    .{ .name = "generation_store.test.folders with non-canonical names are ignored", .cause = lock_cause },
    .{ .name = "generation_store.test.pin blocks sweep", .cause = lock_cause },
    .{ .name = "generation_store.test.pin of a missing generation", .cause = lock_cause },
    .{ .name = "generation_store.test.remove deletes and never reuses the number", .cause = lock_cause },
    .{ .name = "generation_store.test.stage copies, never moves", .cause = lock_cause },
    .{ .name = "generation_store.test.stage numbers", .cause = lock_cause },
    .{ .name = "generation_store.test.stage with a missing extra leaves no folder", .cause = lock_cause },
    .{ .name = "generation_store.test.staged build survives a sweep before load", .cause = lock_cause },
    .{ .name = "generation_store.test.store_lock_blocks_second_writer", .cause = lock_cause },
    .{ .name = "generation_store.test.sweep by bytes keeps a pinned oldest", .cause = lock_cause },
    .{ .name = "generation_store.test.sweep keeps newest", .cause = lock_cause },
    .{ .name = "lock.test.shared locks coexist, exclusive conflicts", .cause = lock_cause },
    .{ .name = "workspace.test.failed prepare releases the lock", .cause = lock_cause },
    .{ .name = "workspace.test.prepare lock timeout", .cause = lock_cause },
    .{ .name = "workspace.test.prepare writes root once", .cause = lock_cause },
    .{ .name = "workspace.test.prepare writes the given build id", .cause = lock_cause },
};

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
