//! Editor build fixture: a tool script. Before the first build its node has
//! a placeholder; once a build is loaded the node gets a real instance.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;
pub const tool = true;

base: *g.Node,
ready_calls: i32 = 0,

pub fn _ready(self: *@This()) void {
    self.ready_calls += 1;
    z.log(.info, "gadget ready calls={d}", .{self.ready_calls});
}
