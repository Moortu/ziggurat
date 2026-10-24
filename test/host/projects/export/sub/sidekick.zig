//! Export fixture: a Node script in a subfolder. The marker
//! ZIGG_EXPORT_SOURCE_MARKER_5c2e must never reach an exported game.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,

pub fn _ready(_: *@This()) void {
    z.log(.info, "sidekick ready", .{});
}
