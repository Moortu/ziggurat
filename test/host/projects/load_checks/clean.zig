//! Load-check fixture: nothing to report.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
speed: f32 = 1,

pub fn run(self: *@This()) f32 {
    return self.speed;
}
