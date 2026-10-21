//! Swap fixture, version 2 of two (see `../swap_v1/mover.zig`).
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
id: i32 = 0,
/// New in version 2.
added: i32 = 7,
speed: f32 = 0,
title: z.String = .empty,
item: z.Ref(g.Resource) = .{},
/// `i32` in version 1: reset to this default by a swap.
count: u32 = 3,
inits: i32 = 0,

pub fn init(self: *@This()) void {
    self.inits += 1;
}

pub fn deinit(self: *@This()) void {
    z.log(.info, "mover deinit gen={d} id={d}", .{ z.generation(), self.id });
}

pub fn version(self: *const @This()) i32 {
    _ = self;
    return 2;
}
