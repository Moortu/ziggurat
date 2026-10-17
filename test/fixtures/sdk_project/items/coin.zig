//! Fixture script: a pickup with a counted resource and a signal.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Area2D;
pub const class_name = "Coin";

base: *g.Area2D,
value: i32 = 1,
texture: z.Ref(g.Texture2D) = .{},

pub const signals = struct {
    pub const collected = struct { by: ?*g.Node, value: i32 };
};

pub fn collect(self: *@This(), by: ?*g.Node) i32 {
    _ = by;
    const v = self.value;
    self.value = 0;
    return v;
}
