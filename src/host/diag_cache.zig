//! Per-file build diagnostics for `ZigLanguage._validate` (spec section 7;
//! Stage 3 ruling R2).
//!
//! `_validate` never compiles: it reads what the last build said about the
//! file. The build side (Task 8) calls `set` after each build with the
//! diagnostics of each project-relative path (`player.zig`, `ui/hud.zig`:
//! the resource path without `res://`), an empty list for a file that built
//! clean. `get` returns a copy, so the caller holds no lock while it turns
//! the list into Godot values. A path never set has no entry: nothing is
//! known against it.
//!
//! Threads: any. One mutex, locked with the process Io (`host_io`), guards
//! the map; every slice stored is owned by the cache (C allocator).
//!
//! Imports only std (and the std-only `host_io.zig`), so the unit tests run
//! without Godot.
const std = @import("std");
const host_io = @import("host_io.zig");

const Allocator = std.mem.Allocator;

/// One build error in a file. `line` and `column` are 1-based; 0 when the
/// build could not place the error (a scan problem).
pub const Diagnostic = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

const gpa = std.heap.c_allocator;

var mu: std.Io.Mutex = .init;
/// Owned path -> owned list.
var map: std.StringHashMapUnmanaged([]Diagnostic) = .empty;

/// Replaces what is known about `rel` with a copy of `list`. An empty list
/// records a clean build. On OutOfMemory the old entry is dropped, so a
/// stale error never outlives a build that could not be recorded.
pub fn set(rel: []const u8, list: []const Diagnostic) Allocator.Error!void {
    const copy = dupeList(gpa, list) catch |err| {
        remove(rel);
        return err;
    };
    errdefer freeList(gpa, copy);

    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    if (map.getPtr(rel)) |old| {
        freeList(gpa, old.*);
        old.* = copy;
        return;
    }
    const key = try gpa.dupe(u8, rel);
    errdefer gpa.free(key);
    try map.put(gpa, key, copy);
}

/// A copy of the list recorded for `rel`, allocated with `a` (free it with
/// `freeList`), or null when nothing is known about `rel`.
pub fn get(a: Allocator, rel: []const u8) Allocator.Error!?[]Diagnostic {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    const list = map.get(rel) orelse return null;
    return try dupeList(a, list);
}

/// Forgets `rel` (a deleted or renamed file).
pub fn remove(rel: []const u8) void {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    const kv = map.fetchRemove(rel) orelse return;
    gpa.free(kv.key);
    freeList(gpa, kv.value);
}

/// Forgets everything. At SCENE exit, and between unit tests.
pub fn reset() void {
    mu.lockUncancelable(host_io.get());
    defer mu.unlock(host_io.get());
    var it = map.iterator();
    while (it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        freeList(gpa, kv.value_ptr.*);
    }
    map.deinit(gpa);
    map = .empty;
}

/// Frees a list from `get` (or one this module made).
pub fn freeList(a: Allocator, list: []Diagnostic) void {
    for (list) |d| a.free(d.message);
    a.free(list);
}

fn dupeList(a: Allocator, list: []const Diagnostic) Allocator.Error![]Diagnostic {
    const out = try a.alloc(Diagnostic, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |d| a.free(d.message);
        a.free(out);
    }
    for (list) |d| {
        out[n] = .{ .line = d.line, .column = d.column, .message = try a.dupe(u8, d.message) };
        n += 1;
    }
    return out;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "unknown path, error, clean build" {
    defer reset();
    try testing.expectEqual(@as(?[]Diagnostic, null), try get(testing.allocator, "player.zig"));

    var msg = "expected ';'".*;
    try set("player.zig", &.{.{ .line = 3, .column = 9, .message = &msg }});
    msg[0] = 'X'; // the cache holds its own copy
    {
        const l = (try get(testing.allocator, "player.zig")).?;
        defer freeList(testing.allocator, l);
        try testing.expectEqual(@as(usize, 1), l.len);
        try testing.expectEqual(@as(u32, 3), l[0].line);
        try testing.expectEqual(@as(u32, 9), l[0].column);
        try testing.expectEqualStrings("expected ';'", l[0].message);
    }

    try set("player.zig", &.{});
    {
        const l = (try get(testing.allocator, "player.zig")).?;
        defer freeList(testing.allocator, l);
        try testing.expectEqual(@as(usize, 0), l.len);
    }
    try testing.expectEqual(@as(?[]Diagnostic, null), try get(testing.allocator, "other.zig"));

    remove("player.zig");
    try testing.expectEqual(@as(?[]Diagnostic, null), try get(testing.allocator, "player.zig"));
}

test "get copies with the caller's allocator and fails cleanly" {
    defer reset();
    try set("a.zig", &.{ .{ .line = 1, .column = 1, .message = "one" }, .{ .line = 2, .column = 0, .message = "two" } });
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(a: Allocator) !void {
            const l = (try get(a, "a.zig")).?;
            freeList(a, l);
        }
    }.f, .{});
}

test "set and get from several threads" {
    defer reset();
    const Worker = struct {
        fn run(id: usize) void {
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "f{d}.zig", .{id % 3}) catch unreachable;
            for (0..200) |i| {
                set(name, &.{.{ .line = @intCast(i), .column = 1, .message = "m" }}) catch {};
                if (get(std.heap.c_allocator, name) catch null) |l| freeList(std.heap.c_allocator, l);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{i});
    for (threads) |t| t.join();
    const l = (try get(testing.allocator, "f0.zig")).?;
    defer freeList(testing.allocator, l);
    try testing.expectEqual(@as(usize, 1), l.len);
}
