//! Fixture script: a pickup with a counted resource and a signal.
const z = @import("ziggurat");
const class = z.godot.class;

pub const extends = class.Area2d;
pub const class_name = "Coin";

base: *class.Area2d,
value: i32 = 1,
texture: z.Ref(class.Texture2d) = .{},

pub const signals = struct {
    pub const collected = struct { by: ?*class.Node, value: i32 };
};

pub fn collect(self: *@This(), by: ?*class.Node) i32 {
    _ = by;
    const v = self.value;
    self.value = 0;
    return v;
}
