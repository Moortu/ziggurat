//! Reload stress fixture: a signal. Threads call `fire`; one instance's
//! `pulse` handler holds the calling thread inside the method, so a swap
//! waits for it.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;
pub const tool = true;

pub const signals = struct {
    pub const pulse = struct {};
};

base: *g.RefCounted,
fired: i64 = 0,

/// Counts calls on this instance, then emits `pulse`.
pub fn fire(self: *@This()) i64 {
    self.fired += 1;
    z.emit(self, .pulse, .{});
    return self.fired;
}

pub fn version(self: *const @This()) i64 {
    _ = self;
    return 0;
}
