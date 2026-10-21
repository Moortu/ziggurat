//! The live script instance records (`instance.Instance`), for the swap
//! engine: it finds every instance of a script and rewrites its record.
//!
//! One list for all scripts, rather than one per `ZigScript` object or per
//! path: several `ZigScript` objects can share a path, and a script's index
//! differs between generations, so the swap engine selects by the record's
//! script path (`collect`) when it plans. Each record keeps its position
//! (`Instance.slot`), so removal is O(1).
//!
//! Threads: `add` and `remove` run in `instance.create` and `instance.free`
//! on any thread, inside the gate, and take `mu`. During a swap (the gate's
//! write side) no other thread is inside, so only the swapper itself can
//! change the list (code it runs may make or free instances); the swap
//! engine therefore works on a copy (`collect`, `all`) and checks
//! `contains` before it touches a record again after running module code.
const std = @import("std");
const host_io = @import("host_io.zig");
const instance = @import("instance.zig");

const Instance = instance.Instance;
const Allocator = std.mem.Allocator;

var mu: std.Io.Mutex = .init;
var items: std.ArrayList(*Instance) = .empty;
const list_allocator = std.heap.c_allocator;

/// Records `rec`. Out of memory is an error: the caller refuses the
/// instance.
pub fn add(rec: *Instance) Allocator.Error!void {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    rec.slot = @intCast(items.items.len);
    try items.append(list_allocator, rec);
}

/// Forgets `rec`, which `add` recorded.
pub fn remove(rec: *Instance) void {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const i = rec.slot;
    if (i >= items.items.len or items.items[i] != rec) return;
    _ = items.swapRemove(i);
    if (i < items.items.len) items.items[i].slot = i;
}

/// Live records now.
pub fn count() usize {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    return items.items.len;
}

/// True while `rec` is recorded (not freed).
pub fn contains(rec: *const Instance) bool {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const i = rec.slot;
    return i < items.items.len and items.items[i] == rec;
}

/// A copy of every live record, owned by the caller (allocated with `a`).
pub fn all(a: Allocator) Allocator.Error![]*Instance {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    return a.dupe(*Instance, items.items);
}

/// A copy of the live records of the script at project-relative path
/// `rel` (as in the table), owned by the caller. Call under the gate's
/// write side (a record's generation does not change then).
pub fn collect(a: Allocator, rel: []const u8) Allocator.Error![]*Instance {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    var out: std.ArrayList(*Instance) = .empty;
    errdefer out.deinit(a);
    for (items.items) |rec| {
        if (std.mem.eql(u8, instance.scriptPath(rec), rel)) try out.append(a, rec);
    }
    return out.toOwnedSlice(a);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "add, remove from the middle and the end, contains" {
    var recs: [4]Instance = undefined;
    for (&recs) |*r| try add(r);
    defer for (&recs) |*r| remove(r);
    try testing.expectEqual(@as(usize, 4), count());
    remove(&recs[1]);
    try testing.expect(!contains(&recs[1]));
    try testing.expect(contains(&recs[3]));
    // Removing twice is harmless.
    remove(&recs[1]);
    remove(&recs[3]);
    try testing.expectEqual(@as(usize, 2), count());
    try testing.expect(contains(&recs[0]) and contains(&recs[2]));
    const copy = try all(testing.allocator);
    defer testing.allocator.free(copy);
    try testing.expectEqual(@as(usize, 2), copy.len);
}

test "add and remove from many threads" {
    const per_thread = 200;
    const Worker = struct {
        fn run(recs: *[per_thread]Instance) void {
            for (recs) |*r| add(r) catch @panic("out of memory");
            for (recs) |*r| remove(r);
        }
    };
    const base = count();
    var recs: [4][per_thread]Instance = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, &recs) |*t, *r| t.* = try std.Thread.spawn(.{}, Worker.run, .{r});
    for (threads) |t| t.join();
    try testing.expectEqual(base, count());
}
