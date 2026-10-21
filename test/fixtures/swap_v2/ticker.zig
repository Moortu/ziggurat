//! Swap fixture, version 2 of two (see `../swap_v1/ticker.zig`).
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;

base: *g.RefCounted,
bumps: i64 = 0,
pad2: f64 = 0.5,

/// Counts calls on this instance.
pub fn bump(self: *@This()) i64 {
    self.bumps += 1;
    return self.bumps;
}

pub fn version(self: *const @This()) i32 {
    _ = self;
    return 2;
}
