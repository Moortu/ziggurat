//! Instance fixture: a Node2D script with `_ready`, `_process`,
//! `_notification`, `_toString`, exported properties in a group and a method
//! with a return value. Node2D rather than the `sdk_project` player's
//! CharacterBody2D, so the tests need nothing from the physics servers.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;
pub const class_name = "Mover";

base: *g.Node2D,
speed: f32 = 5,
title: z.String = .empty,
steps: i32 = 0,
ready_calls: i32 = 0,
notifications: i32 = 0,

pub const meta = .{
    .speed = .{ .group = "Motion" },
    .steps = .{ .group = "Motion" },
};

pub fn _ready(self: *@This()) void {
    self.ready_calls += 1;
    z.log(.info, "mover ready speed={d}", .{self.speed});
}

pub fn _process(self: *@This(), delta: f64) void {
    _ = delta;
    self.steps += 1;
}

pub fn _notification(self: *@This(), what: i32) void {
    _ = what;
    self.notifications += 1;
}

pub fn _toString(self: *const @This()) g.String {
    return self.title.get();
}

pub fn scaled(self: *const @This(), x: i32) i32 {
    return x * @as(i32, @intFromFloat(self.speed));
}
