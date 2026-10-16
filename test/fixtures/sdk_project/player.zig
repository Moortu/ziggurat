//! Fixture script: one field of each kind, a group, ranges, methods with
//! arguments, a virtual method and signals with arguments.
const z = @import("ziggurat");
const g = z.godot;
const class = g.class;

pub const extends = class.CharacterBody2d;
pub const class_name = "Player";

base: *class.CharacterBody2d,
speed: f32 = 300,
health: i32 = 100,
alive: bool = true,
mood: Mood = .calm,
layers: Layers = .{},
spawn: g.builtin.Vector2 = .{ .x = 1, .y = 2 },
title: g.builtin.String = .empty,
target: z.Obj(class.Node) = .{},
_dash_timer: f32 = 0,

pub const Mood = enum(u8) { calm, angry };
pub const Layers = packed struct(u8) { ground: bool = true, water: bool = false, _pad: u6 = 0 };

pub const meta = .{
    .speed = .{ .range = .{ 0, 1000, 5 }, .group = "Movement/Fast motion" },
    .health = .{ .range = .{ 0, 100 } },
    .spawn = .{ .group = "Movement/Fast motion", .name = "spawn_point" },
    .takeDamage = .{ .args = .{ "amount", "critical" } },
    .jump = .{ .name = "leap" },
};

pub const signals = struct {
    pub const died = struct {};
    pub const hit = struct { damage: i32, source: ?*class.Node };
};

pub fn init(self: *@This()) void {
    self._dash_timer = 0;
}

pub fn _physicsProcess(self: *@This(), delta: f64) void {
    self._dash_timer -= @floatCast(delta);
}

pub fn takeDamage(self: *@This(), amount: i32, critical: bool) void {
    self.health -= if (critical) amount * 2 else amount;
    self.alive = self.health > 0;
}

pub fn jump(self: *const @This(), height: f32) f32 {
    return height * self.speed;
}

/// Not a method: the first parameter is not the script.
pub fn clampHealth(h: i32) i32 {
    return @max(0, h);
}

fn hidden(self: *@This()) void {
    self.speed = 0;
}
