//! Instance fixture: a tool script. The editor gives it a real instance, so
//! its `_ready` runs there; the log line lets a test see that.
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
