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
const std = @import("std");

var threaded: std.Io.Threaded = .init_single_threaded;
var full = false;

/// Makes the full `std.Io.Threaded`. Main thread, at the entry point, once.
pub fn init() void {
    if (full) return;
    threaded = .init(std.heap.c_allocator, .{});
    full = true;
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

test "get works before init" {
    var m: std.Io.Mutex = .init;
    m.lockUncancelable(get());
    m.unlock(get());
}
