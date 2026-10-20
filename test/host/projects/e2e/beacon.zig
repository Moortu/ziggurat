//! End-to-end fixture: a tool script. The editor gives it a real instance
//! once a build is loaded; the game runs it like any other script.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;
pub const tool = true;

base: *g.Node,
pulses: i32 = 0,

pub fn _ready(self: *@This()) void {
    z.log(.info, "beacon ready pulses={d}", .{self.pulses});
}

pub fn pulse(self: *@This()) i32 {
    self.pulses += 1;
    return self.pulses;
}
