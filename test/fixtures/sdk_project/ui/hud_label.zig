//! Fixture script: a tool script without `base`.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Label;
pub const class_name = "HudLabel";
pub const tool = true;

prefix: z.String = .empty,
blink: f64 = 0.5,

pub fn _process(self: *@This(), delta: f64) void {
    self.blink -= delta;
}
