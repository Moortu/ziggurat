//! Editor build fixture: a Node2D script. The host test changes the default
//! of `speed` through the saver, then breaks the script and repairs it.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;

base: *g.Node2D,
speed: f32 = 5,

pub const signals = struct {
    pub const arrived = struct {};
};
