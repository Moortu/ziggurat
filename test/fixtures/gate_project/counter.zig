//! Gate fixture: a RefCounted script (no node, so any thread may call it)
//! with a signal that a check connects to GDScript code, which then runs
//! while this script's method is on the stack.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;

pub const signals = struct {
    pub const ping = struct {};
};

base: *g.RefCounted,
value: i32 = 41,
bumps: i64 = 0,

/// Emits `ping`, then returns `value`.
pub fn fire(self: *@This()) i32 {
    z.emit(self, .ping, .{});
    return self.value;
}

/// Counts calls on this instance.
pub fn bump(self: *@This()) i64 {
    self.bumps += 1;
    return self.bumps;
}

pub fn answer(self: *const @This()) i32 {
    return self.value + 1;
}
