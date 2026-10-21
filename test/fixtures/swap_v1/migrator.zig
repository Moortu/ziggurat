//! Swap fixture, version 1 of two (see `../swap_v2/migrator.zig`): version
//! 2 renames `hp` to `health` in its `migrate` hook.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
hp: i32 = 100,
