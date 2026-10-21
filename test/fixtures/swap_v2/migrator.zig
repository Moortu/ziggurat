//! Swap fixture, version 2 of two (see `../swap_v1/migrator.zig`).
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
health: i32 = 0,
migrated: bool = false,
memo: z.String = .empty,
asset: z.Ref(g.Resource) = .{},
/// Same name and type as in version 1: the host moves it in, then
/// `migrate` replaces it with `alt_slot`.
slot: z.Ref(g.Resource) = .{},

pub fn migrate(self: *@This(), old: z.Previous(@This())) void {
    self.migrated = true;
    if (old.get(i32, "hp")) |hp| self.health = hp;
    _ = old.takeInto(z.String, &self.memo, "note");
    _ = old.takeInto(z.Ref(g.Resource), &self.asset, "res");
    _ = old.takeInto(z.Ref(g.Resource), &self.slot, "alt_slot");
}
