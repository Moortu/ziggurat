//! Swap fixture, version 2 of two (see `../swap_v1/migrator.zig`).
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
health: i32 = 0,
migrated: bool = false,

pub fn migrate(self: *@This(), old: z.Previous(@This())) void {
    self.migrated = true;
    if (old.get(i32, "hp")) |hp| self.health = hp;
}
