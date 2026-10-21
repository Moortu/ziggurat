//! Reload stress fixture. The stress driver (test/host/stress/driver.gd)
//! rewrites this file on most edits: method bodies, an added and removed
//! field, a field renamed between `score` and `points` (copied by
//! `migrate`), and `level` changing between i32 and i64.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;
pub const tool = true;

base: *g.RefCounted,
bumps: i64 = 0,
score: i64 = 0,
level: i32 = 0,
note: z.String = .empty,
migrations: i64 = 0,

pub fn bump(self: *@This()) i64 {
    self.bumps += 1;
    return self.bumps;
}

pub fn version(self: *const @This()) i64 {
    _ = self;
    return 0;
}

pub fn migrate(self: *@This(), old: z.Previous(@This())) void {
    self.migrations += 1;
    if (old.get(i64, "points")) |v| self.score = v;
}
