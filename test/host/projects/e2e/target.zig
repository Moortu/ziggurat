//! End-to-end fixture: a script with signals. `strike` emits `hit` with
//! `z.emit`; `rest` emits `idle`, which nothing connects to.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
strikes: i32 = 0,

pub const signals = struct {
    pub const hit = struct { damage: i32 };
    pub const idle = struct {};
};

pub fn strike(self: *@This(), damage: i32) i32 {
    self.strikes += 1;
    z.emit(self, .hit, .{ .damage = damage });
    return self.strikes;
}

pub fn rest(self: *@This()) void {
    z.emit(self, .idle, .{});
}
