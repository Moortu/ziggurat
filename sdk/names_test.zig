//! Tests of the lazy caches in `names.zig` with the engine calls replaced
//! by counting fakes. This file is not part of the SDK module (nothing in
//! the SDK imports it), so it does not ship.
//!
//! `zig build test-unit` builds it with ThreadSanitizer on x86_64 and aarch64 Linux:
//! a cache that publishes its value without release and acquire ordering
//! is reported as a data race and fails the test.
const std = @import("std");
const godot = @import("gdzig");
const names = @import("names.zig");
const c = godot.c;

const thread_count = 16;
const calls_per_thread = 10_000;

/// The caches under test. Each name and bind is used by this test only, so
/// every one is empty when the threads start.
const test_names = [_][]const u8{ "lazy_cache_test_name_0", "lazy_cache_test_name_1", "lazy_cache_test_name_2", "lazy_cache_test_name_3" };
const test_class = "LazyCacheTestClass";
const test_methods = [_][]const u8{ "lazy_cache_test_method_0", "lazy_cache_test_method_1", "lazy_cache_test_method_2", "lazy_cache_test_method_3" };
const first_hash = 1001;

var names_made: std.atomic.Value(usize) = .init(0);
var binds_looked_up: std.atomic.Value(usize) = .init(0);
var names_freed: std.atomic.Value(usize) = .init(0);
var bad_bind_names: std.atomic.Value(usize) = .init(0);

/// Fake `string_name_new_with_latin1_chars`: the "StringName" holds the
/// address of the characters, so one name always gets the same bits.
fn fakeNameNew(dest: c.GDExtensionUninitializedStringNamePtr, contents: [*c]const u8, is_static: c.GDExtensionBool) callconv(.c) void {
    _ = is_static;
    _ = names_made.fetchAdd(1, .monotonic);
    const bits: usize = @intFromPtr(contents);
    @memcpy(@as([*]u8, @ptrCast(dest))[0..@sizeOf(usize)], std.mem.asBytes(&bits));
}

/// Fake `classdb_get_method_bind`: reads both names (as Godot does) and
/// returns the hash as the bind.
fn fakeGetMethodBind(class: c.GDExtensionConstStringNamePtr, method: c.GDExtensionConstStringNamePtr, hash: c.GDExtensionInt) callconv(.c) c.GDExtensionMethodBindPtr {
    _ = binds_looked_up.fetchAdd(1, .monotonic);
    if (nameBits(class) == 0 or nameBits(method) == 0) _ = bad_bind_names.fetchAdd(1, .monotonic);
    return @ptrFromInt(@as(usize, @intCast(hash)));
}

fn fakeDestroy(base: c.GDExtensionTypePtr) callconv(.c) void {
    _ = base;
    _ = names_freed.fetchAdd(1, .monotonic);
}

fn fakeGetDestructor(t: c.GDExtensionVariantType) callconv(.c) c.GDExtensionPtrDestructor {
    _ = t;
    return &fakeDestroy;
}

fn nameBits(p: ?*const anyopaque) usize {
    var bits: usize = 0;
    @memcpy(std.mem.asBytes(&bits), @as([*]const u8, @ptrCast(p.?))[0..@sizeOf(usize)]);
    return bits;
}

const Seen = struct {
    name_ptrs: [test_names.len]usize = @splat(0),
    name_bits: [test_names.len]usize = @splat(0),
    binds: [test_methods.len]usize = @splat(0),
    /// Calls that returned something other than this thread's first call.
    changed: usize = 0,
};

var go: std.atomic.Value(bool) = .init(false);

fn worker(seen: *Seen) void {
    while (!go.load(.acquire)) std.atomic.spinLoopHint();
    for (0..calls_per_thread) |call| {
        inline for (test_names, 0..) |n, i| {
            const p = names.StaticName(n).ptr();
            const now = .{ @intFromPtr(p), nameBits(p) };
            if (call == 0) {
                seen.name_ptrs[i], seen.name_bits[i] = now;
            } else if (now[0] != seen.name_ptrs[i] or now[1] != seen.name_bits[i]) {
                seen.changed += 1;
            }
        }
        inline for (test_methods, 0..) |m, i| {
            const bind: usize = @intFromPtr(names.MethodBind(test_class, m, first_hash + i).get());
            if (call == 0) {
                seen.binds[i] = bind;
            } else if (bind != seen.binds[i]) {
                seen.changed += 1;
            }
        }
    }
}

test "lazy caches: concurrent first use" {
    try std.testing.expect(@sizeOf(godot.builtin.StringName) >= @sizeOf(usize));
    godot.raw.stringNameNewWithLatin1Chars = &fakeNameNew;
    godot.raw.classdbGetMethodBind = &fakeGetMethodBind;
    godot.raw.variantGetPtrDestructor = &fakeGetDestructor;

    inline for (test_names) |n| try std.testing.expect(!names.StaticName(n).isReady());
    inline for (test_methods, 0..) |m, i| try std.testing.expect(!names.MethodBind(test_class, m, first_hash + i).isReady());

    var seen: [thread_count]Seen = @splat(.{});
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, &seen) |*t, *s| t.* = try std.Thread.spawn(.{}, worker, .{s});
    go.store(true, .release);
    for (threads) |t| t.join();

    for (seen) |s| {
        try std.testing.expectEqual(@as(usize, 0), s.changed);
        try std.testing.expectEqualSlices(usize, &seen[0].name_ptrs, &s.name_ptrs);
        try std.testing.expectEqualSlices(usize, &seen[0].name_bits, &s.name_bits);
        try std.testing.expectEqualSlices(usize, &seen[0].binds, &s.binds);
    }
    inline for (test_names, 0..) |n, i| {
        // The name holds its own characters' address (fakeNameNew).
        try std.testing.expect(seen[0].name_bits[i] != 0);
        try std.testing.expect(names.StaticName(n).isReady());
    }
    inline for (test_methods, 0..) |m, i| {
        try std.testing.expectEqual(@as(usize, first_hash + i), seen[0].binds[i]);
        try std.testing.expect(names.MethodBind(test_class, m, first_hash + i).isReady());
    }
    try std.testing.expectEqual(@as(usize, 0), bad_bind_names.load(.monotonic));
    // A thread that loses the race to fill a cache keeps its copy: a static
    // StringName is never freed (a second free deadlocks Godot).
    try std.testing.expectEqual(@as(usize, 0), names_freed.load(.monotonic));
    // Each name was built at least once: the test names, the class and the methods.
    try std.testing.expect(names_made.load(.monotonic) >= test_names.len + 1 + test_methods.len);
    try std.testing.expect(binds_looked_up.load(.monotonic) >= test_methods.len);
}
