//! Swap fixture, version 1 of two (see `../swap_v2/keeper.zig`): the same
//! layout in both versions, so a swap keeps the data block; only the body
//! of `version` changes.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;

base: *g.RefCounted,
value: i32 = 5,

pub fn version(self: *const @This()) i32 {
    _ = self;
    return 1;
}
