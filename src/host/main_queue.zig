//! Work for the main thread (Stage 3 ruling R3).
//!
//! Any thread may `push` a callback with a context; `ZigLanguage._frame`
//! calls `drain` on the main thread, which runs each queued callback once,
//! in push order. The build service (Task 8) pushes build outcomes here,
//! because only the main thread may touch scripts and the scene.
//!
//! One `drain` runs at most `per_frame` callbacks, so a flood of pushes
//! cannot stall one frame; the rest run on later frames. `_frame` is not a
//! safe point (spec section 2): Godot's nested `Main::iteration()` calls it
//! again while a callback may be on the stack, so a nested `drain` runs
//! nothing.
//!
//! Callbacks run outside the lock and may push again; what they push runs
//! no earlier than the next `drain`.
//!
//! Imports only std (and the std-only `host_io.zig`), so the unit tests run
//! without Godot.
const std = @import("std");
const host_io = @import("host_io.zig");

const Allocator = std.mem.Allocator;

pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// Most callbacks one `drain` runs.
pub const per_frame = 64;

const Item = struct { cb: Callback, ctx: ?*anyopaque };

const gpa = std.heap.c_allocator;

var mu: std.Io.Mutex = .init;
var items: std.ArrayList(Item) = .empty;
/// Main thread only: set while `drain` runs callbacks.
var draining = false;

/// Queues `cb(ctx)` for the main thread. Any thread. On OutOfMemory nothing
/// is queued and the caller still owns `ctx`.
pub fn push(cb: Callback, ctx: ?*anyopaque) Allocator.Error!void {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    try items.append(gpa, .{ .cb = cb, .ctx = ctx });
}

/// Runs up to `per_frame` queued callbacks, oldest first, and returns how
/// many ran. Main thread. A nested call (from inside a callback) runs
/// nothing.
pub fn drain() usize {
    if (draining) return 0;
    var batch: [per_frame]Item = undefined;
    const n = take(&batch);
    draining = true;
    defer draining = false;
    for (batch[0..n]) |it| it.cb(it.ctx);
    return n;
}

/// Callbacks waiting. Any thread.
pub fn pending() usize {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    return items.items.len;
}

/// Drops every queued callback without running it and frees the queue.
/// Main thread, at SCENE exit, when nothing pushes any more. Returns how
/// many were dropped.
pub fn reset() usize {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    const n = items.items.len;
    items.deinit(gpa);
    items = .empty;
    return n;
}

/// Moves the oldest queued items into `out`; returns how many.
fn take(out: []Item) usize {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    const n = @min(out.len, items.items.len);
    @memcpy(out[0..n], items.items[0..n]);
    items.replaceRangeAssumeCapacity(0, n, &.{});
    return n;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

const Counter = struct {
    runs: std.atomic.Value(u32) = .init(0),

    fn bump(ctx: ?*anyopaque) void {
        const c: *Counter = @ptrCast(@alignCast(ctx.?));
        _ = c.runs.fetchAdd(1, .monotonic);
    }
};

test "callbacks run once, in order, bounded per drain" {
    defer _ = reset();
    const Rec = struct {
        var seen: [200]usize = undefined;
        var n: usize = 0;
        fn note(ctx: ?*anyopaque) void {
            seen[n] = @intFromPtr(ctx);
            n += 1;
        }
    };
    Rec.n = 0;
    for (1..151) |i| try push(Rec.note, @ptrFromInt(i));
    try testing.expectEqual(@as(usize, 150), pending());
    try testing.expectEqual(@as(usize, per_frame), drain());
    try testing.expectEqual(@as(usize, per_frame), drain());
    try testing.expectEqual(@as(usize, 150 - 2 * per_frame), drain());
    try testing.expectEqual(@as(usize, 0), drain());
    try testing.expectEqual(@as(usize, 150), Rec.n);
    for (Rec.seen[0..150], 1..) |v, i| try testing.expectEqual(i, v);
}

test "a nested drain runs nothing; a push from a callback waits for the next drain" {
    defer _ = reset();
    const Nest = struct {
        var inner: usize = 99;
        var later_ran = false;
        fn later(_: ?*anyopaque) void {
            later_ran = true;
        }
        fn outer(_: ?*anyopaque) void {
            inner = drain();
            push(later, null) catch {};
        }
    };
    try push(Nest.outer, null);
    try testing.expectEqual(@as(usize, 1), drain());
    try testing.expectEqual(@as(usize, 0), Nest.inner);
    try testing.expect(!Nest.later_ran);
    try testing.expectEqual(@as(usize, 1), drain());
    try testing.expect(Nest.later_ran);
}

test "pushes from several threads all run" {
    defer _ = reset();
    var c: Counter = .{};
    const Worker = struct {
        fn run(counter: *Counter) void {
            for (0..100) |_| push(Counter.bump, counter) catch {};
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&c});
    for (threads) |t| t.join();
    while (drain() != 0) {}
    try testing.expectEqual(@as(u32, 400), c.runs.load(.monotonic));
}

test "reset drops what is queued" {
    var c: Counter = .{};
    try push(Counter.bump, &c);
    try push(Counter.bump, &c);
    try testing.expectEqual(@as(usize, 2), reset());
    try testing.expectEqual(@as(usize, 0), drain());
    try testing.expectEqual(@as(u32, 0), c.runs.load(.monotonic));
}
