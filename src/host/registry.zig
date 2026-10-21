//! The live script instance records (`instance.Instance`), for the swap
//! engine: it finds every instance of a script and rewrites its record.
//!
//! One list for all scripts, rather than one per `ZigScript` object or per
//! path: several `ZigScript` objects can share a path, and a script's index
//! differs between generations, so the swap engine selects by the record's
//! script path (`collect`) when it plans. Each record keeps its position
//! (`Instance.slot`), so removal is O(1). An address set beside the list
//! answers `contains` in O(1) without reading a record's memory.
//!
//! Threads: `add` and `remove` run in `instance.create` and `instance.free`
//! on any thread, inside the gate, and take `mu`. During a swap (the gate's
//! write side) no other thread is inside, so only the swapper itself can
//! change the list (code it runs may make or free instances); the swap
//! engine therefore works on a copy (`all`, `byPath`) of `Entry`s and
//! checks `contains(entry)` before it touches a record again after running
//! module code. An entry carries the record's serial number: a record freed
//! during the swap and a new one made at the same address are told apart.
const std = @import("std");
const host_io = @import("host_io.zig");
const instance = @import("instance.zig");

const Instance = instance.Instance;
const Allocator = std.mem.Allocator;

/// A record as the registry saw it: pointer and serial number.
pub const Entry = struct {
    rec: *Instance,
    serial: u64,

    pub fn of(rec: *Instance) Entry {
        return .{ .rec = rec, .serial = rec.serial };
    }
};

/// The serial number of the next record (`nextSerial`). Starts at 1.
var serial_counter: std.atomic.Value(u64) = .init(1);

/// A new serial number, unique for the process.
pub fn nextSerial() u64 {
    return serial_counter.fetchAdd(1, .monotonic);
}

var mu: std.Io.Mutex = .init;
var items: std.ArrayList(*Instance) = .empty;
/// The addresses in `items`.
var addresses: std.AutoHashMapUnmanaged(*Instance, void) = .empty;
const list_allocator = std.heap.c_allocator;

/// Records `rec`. Out of memory is an error: the caller refuses the
/// instance.
pub fn add(rec: *Instance) Allocator.Error!void {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    try addresses.ensureUnusedCapacity(list_allocator, 1);
    rec.slot = @intCast(items.items.len);
    try items.append(list_allocator, rec);
    addresses.putAssumeCapacity(rec, {});
}

/// Forgets `rec`, which `add` recorded.
pub fn remove(rec: *Instance) void {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const i = rec.slot;
    if (i >= items.items.len or items.items[i] != rec) return;
    _ = items.swapRemove(i);
    _ = addresses.remove(rec);
    if (i < items.items.len) items.items[i].slot = i;
}

/// Live records now.
pub fn count() usize {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    return items.items.len;
}

/// True while the record `e` names is recorded: the same address and the
/// same serial number. A freed record, or a new one at a freed record's
/// address, is not. The record's memory is not read unless the address is
/// recorded (a recorded address is live).
pub fn contains(e: Entry) bool {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    if (!addresses.contains(e.rec)) return false;
    return e.rec.serial == e.serial;
}

/// A copy of every live record, owned by the caller (allocated with `a`).
pub fn all(a: Allocator) Allocator.Error![]Entry {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    const out = try a.alloc(Entry, items.items.len);
    for (items.items, out) |rec, *e| e.* = .of(rec);
    return out;
}

/// Live records grouped by the project-relative path of their script (as
/// in the table), in one pass. Keys point into the generations' tables
/// (never freed). Free with `deinitGroups`.
pub const Groups = std.StringArrayHashMapUnmanaged(std.ArrayList(Entry));

/// Call under the gate's write side (a record's generation does not change
/// then).
pub fn byPath(a: Allocator) Allocator.Error!Groups {
    const copy = try all(a);
    defer a.free(copy);
    var groups: Groups = .empty;
    errdefer deinitGroups(a, &groups);
    for (copy) |e| {
        const g = try groups.getOrPut(a, instance.scriptPath(e.rec));
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, e);
    }
    return groups;
}

pub fn deinitGroups(a: Allocator, groups: *Groups) void {
    for (groups.values()) |*l| l.deinit(a);
    groups.deinit(a);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "add, remove from the middle and the end, contains" {
    var recs: [4]Instance = undefined;
    for (&recs) |*r| {
        r.serial = nextSerial();
        try add(r);
    }
    defer for (&recs) |*r| remove(r);
    const base = count() - 4;
    remove(&recs[1]);
    try testing.expect(!contains(.of(&recs[1])));
    try testing.expect(contains(.of(&recs[3])));
    // Removing twice is harmless.
    remove(&recs[1]);
    remove(&recs[3]);
    try testing.expectEqual(base + 2, count());
    try testing.expect(contains(.of(&recs[0])) and contains(.of(&recs[2])));
    const copy = try all(testing.allocator);
    defer testing.allocator.free(copy);
    try testing.expectEqual(@as(usize, 2), copy.len);
}

test "a new record at a freed record's address is not the old one" {
    var mem: Instance = undefined;
    mem.serial = nextSerial();
    try add(&mem);
    const old: Entry = .of(&mem);
    // Freed during a swap, then a new record made at the same address.
    remove(&mem);
    mem.serial = nextSerial();
    try add(&mem);
    defer remove(&mem);
    try testing.expect(!contains(old));
    try testing.expect(contains(.of(&mem)));
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
