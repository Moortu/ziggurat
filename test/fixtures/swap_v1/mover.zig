//! Swap fixture, version 1 of two (see `../swap_v2/mover.zig`): a changed
//! layout. `speed`, `title`, `item`, `id` and `inits` keep their name and
//! type and move; `hp` is removed and `count` changes type in version 2.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
id: i32 = 0,
speed: f32 = 1.5,
title: z.String = .empty,
item: z.Ref(g.Resource) = .{},
hp: i32 = 100,
count: i32 = 0,
/// Times `init` ran on this instance's data.
inits: i32 = 0,

pub fn init(self: *@This()) void {
    self.inits += 1;
}

/// `hp` does not move (version 2 removes it), so this still sees it after
/// a swap (the checks set it to the id); `id` moves and is reset to its
/// default before this runs.
pub fn deinit(self: *@This()) void {
    z.log(.info, "mover deinit gen={d} hp={d} id={d}", .{ z.generation(), self.hp, self.id });
}

pub fn version(self: *const @This()) i32 {
    _ = self;
    return 1;
}
