//! Linked fixture: a Node2D script whose `_ready` prints one line. The
//! host test "uid-only scene runs" finds it through its uid.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;

base: *g.Node2D,
speed: f32 = 3,

pub fn _ready(self: *@This()) void {
    z.log(.info, "alpha ready speed={d}", .{self.speed});
}
