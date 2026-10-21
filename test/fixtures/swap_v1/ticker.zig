//! Swap fixture, version 1 of two (see `../swap_v2/ticker.zig`): a
//! RefCounted script that threads call while swaps alternate between the
//! two versions. `bumps` moves at a different offset each time.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;

base: *g.RefCounted,
pad: i32 = 0,
bumps: i64 = 0,

/// Counts calls on this instance.
pub fn bump(self: *@This()) i64 {
    self.bumps += 1;
    return self.bumps;
}

pub fn version(self: *const @This()) i32 {
    _ = self;
    return 1;
}
