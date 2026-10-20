//! The host's one process-wide `std.Io`. The runtime (the `HostApi` lock,
//! loading) and, later, the build service use it; nothing in the host takes
//! an Io from a caller.
//!
//! Before `init` (and in unit tests) `get` returns a statically initialised
//! single-threaded `std.Io.Threaded`: its mutex and futex calls already work
//! across threads, only `async`/`concurrent` are unavailable. `init`, at the
//! entry point, replaces it with a full `std.Io.Threaded` before Godot or any
//! module starts a thread that could call `get`. `deinit` runs at SCENE exit
//! after everything else. The storage is static and is never freed, so an
//! Io a late caller still holds stays a valid pointer; `Threaded`'s futex
//! calls do not use the instance, so its mutexes keep working.
//!
//! The full Io carries a copy of the process environment taken at `init`:
//! a library has no `main` that hands it over, and without it every child
//! process (the Zig compiler the build service runs) would start with an
//! empty environment (no `HOME`, so Zig finds no cache folder).
const std = @import("std");
const builtin = @import("builtin");

var threaded: std.Io.Threaded = .init_single_threaded;
var full = false;

/// Makes the full `std.Io.Threaded`. Main thread, at the entry point, once.
pub fn init() void {
    if (full) return;
    threaded = .init(std.heap.c_allocator, .{ .environ = environ() });
    full = true;
}

/// The process environment as `init` found it, copied (never freed: the Io
/// may still hold it after `deinit`). Empty when out of memory.
fn environ() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    if (!builtin.link_libc) return .empty;
    const src: [*:null]?[*:0]u8 = if (builtin.os.tag.isDarwin()) _NSGetEnviron().* else std.c.environ;
    return .{ .block = .{ .slice = copyBlock(std.heap.c_allocator, std.mem.span(src)) catch return .empty } };
}

/// Darwin's way for a library to reach the environment (`environ` belongs
/// to the executable there).
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

fn copyBlock(a: std.mem.Allocator, src: []const ?[*:0]u8) ![:null]const ?[*:0]const u8 {
    const out = try a.allocSentinel(?[*:0]const u8, src.len, null);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |e| a.free(std.mem.span(e.?));
        a.free(out);
    }
    while (n < src.len) : (n += 1) out[n] = (try a.dupeSentinel(u8, std.mem.span(src[n].?), 0)).ptr;
    return out;
}

/// Joins the Io's worker threads and restores the signal handlers it set.
/// Main thread, at SCENE exit, after every other user is done.
pub fn deinit() void {
    if (!full) return;
    threaded.deinit();
    full = false;
}

/// The process-wide Io.
pub fn get() std.Io {
    return threaded.io();
}

test "the environment copy keeps every entry" {
    const a = std.testing.allocator;
    var e1 = "HOME=/home/x".*;
    var e2 = "PATH=/bin".*;
    const src = [_]?[*:0]u8{ &e1, &e2 };
    const block = try copyBlock(a, &src);
    defer {
        for (block) |e| a.free(std.mem.span(e.?));
        a.free(block);
    }
    try std.testing.expectEqual(@as(usize, 2), block.len);
    try std.testing.expectEqualStrings("HOME=/home/x", std.mem.span(block[0].?));
    try std.testing.expectEqualStrings("PATH=/bin", std.mem.span(block[1].?));
    try std.testing.expect(block[2] == null);
}

test "get works before init" {
    var m: std.Io.Mutex = .init;
    m.lockUncancelable(get());
    m.unlock(get());
}
