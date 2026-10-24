//! Linked fixture: a Node script in a subfolder whose `_ready` prints one
//! line.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,

pub fn _ready(_: *@This()) void {
    z.log(.info, "beta ready", .{});
}
