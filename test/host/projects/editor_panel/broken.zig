//! Editor panel fixture: the host test breaks line 3 and repairs it.
const z = @import("ziggurat");
const start_speed: f32 = 5;
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
speed: f32 = start_speed,
