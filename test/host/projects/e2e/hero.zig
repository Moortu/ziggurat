//! End-to-end fixture: a Node2D script with exported properties of several
//! kinds (a number with a range, an owned string, flags and a vector),
//! `_ready`, and a method GDScript calls. The scene stores values that
//! differ from every default.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;

base: *g.Node2D,
speed: f32 = 5,
title: z.String = .empty,
layers: Layers = .{},
spawn: g.Vector2 = .{ .x = 1, .y = 2 },
ready_calls: i32 = 0,

pub const Layers = packed struct(u3) {
    ground: bool = true,
    water: bool = false,
    air: bool = false,
};

pub const meta = .{
    .speed = .{ .range = .{ 0, 100, 0.5 } },
};

pub fn _ready(self: *@This()) void {
    self.ready_calls += 1;
    z.log(.info, "hero ready speed={d} spawn={d},{d}", .{ self.speed, self.spawn.x, self.spawn.y });
}

pub fn score(self: *const @This(), bonus: i32) i32 {
    return bonus + @as(i32, @intFromFloat(self.speed * 2));
}
