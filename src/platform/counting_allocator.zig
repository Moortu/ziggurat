//! An allocator that passes every call to a child allocator and counts the
//! bytes live through it: what a data structure built with it holds, for
//! the editor's memory figures (spec section 6). Not thread-safe: one
//! thread allocates and frees through one counter at a time.
//!
//! Memory allocated through the counter may also be freed through the child
//! directly (the counter then stays higher than what is live).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const CountingAllocator = struct {
    child: Allocator,
    /// Bytes allocated through this counter and not freed through it.
    live: u64 = 0,
    /// The highest `live` seen.
    peak: u64 = 0,

    pub fn init(child: Allocator) CountingAllocator {
        return .{ .child = child };
    }

    /// The counter must not move while the result is in use.
    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn grow(self: *CountingAllocator, old: usize, new: usize) void {
        self.live = self.live - @min(self.live, old) + new;
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, al: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, al, ra) orelse return null;
        self.grow(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, al: Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(m, al, n, ra)) return false;
        self.grow(m.len, n);
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, al: Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(m, al, n, ra) orelse return null;
        self.grow(m.len, n);
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, al: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, al, ra);
        self.grow(m.len, 0);
    }
};

test "counts live and peak bytes" {
    var c: CountingAllocator = .init(std.testing.allocator);
    const a = c.allocator();
    const x = try a.alloc(u8, 100);
    const y = try a.alloc(u64, 10);
    try std.testing.expectEqual(@as(u64, 180), c.live);
    a.free(x);
    try std.testing.expectEqual(@as(u64, 80), c.live);
    try std.testing.expectEqual(@as(u64, 180), c.peak);
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, "hello");
    try std.testing.expectEqual(@as(u64, 80 + list.capacity), c.live);
    list.deinit(a);
    a.free(y);
    try std.testing.expectEqual(@as(u64, 0), c.live);
}

test "an arena on the counter counts what the arena holds" {
    var c: CountingAllocator = .init(std.testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(c.allocator());
    _ = try arena.allocator().alloc(u8, 1000);
    try std.testing.expect(c.live >= 1000);
    arena.deinit();
    try std.testing.expectEqual(@as(u64, 0), c.live);
}
