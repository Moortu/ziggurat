//! Swap fixture, version 1 of two (see `../swap_v2/mover.zig`): a changed
//! layout. `speed`, `title`, `item`, `id` and `inits` keep their name and
//! type and move; `hp`, `tag` and `junk` are removed and `count`, `kind`
//! and `skin` change type in version 2, so the old `destroy` releases the
//! owned ones among them.
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
tag: z.String = .empty,
junk: z.Ref(g.Resource) = .{},
/// A `z.StringName` in version 2.
kind: z.String = .empty,
/// A `z.Ref(g.Texture2D)` in version 2.
skin: z.Ref(g.Resource) = .{},
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
