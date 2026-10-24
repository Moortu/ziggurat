//! Export fixture: a Node2D script with a stored property. The marker
//! ZIGG_EXPORT_SOURCE_MARKER_5c2e must never reach an exported game.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;

base: *g.Node2D,
speed: f32 = 3,

pub fn _ready(self: *@This()) void {
    z.log(.info, "hero ready speed={d}", .{self.speed});
}
