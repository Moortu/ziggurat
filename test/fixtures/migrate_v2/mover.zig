//! Fixture script, version 2 of two (see `../migrate_v1/mover.zig`).
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

pub const Mood = enum { calm, angry, sleepy };
pub const Stats = struct { a: i32 = 0, c: i64 = 0 };

base: *g.Node,
health: i32 = 0,
count: u32 = 0,
mood: Mood = .calm,
_stats: Stats = .{},
speed: f32 = 0,
title: z.String = .empty,
memo: z.String = .empty,
item: z.Ref(g.Resource) = .{},
/// What `migrate` saw: whether it ran, and whether a second take of
/// `note` and a take of `title` (which the host already moved) gave
/// anything.
_migrated: bool = false,
_note_twice: bool = false,
_title_taken: bool = false,

/// Renames: `hp` becomes `health`, `note` becomes `memo`. Fields that kept
/// their name and type are already here.
pub fn migrate(self: *@This(), old: z.Previous(@This())) void {
    self._migrated = true;
    if (old.get(i32, "hp")) |hp| self.health = hp;
    if (old.take(z.String, "note")) |text| self.memo = text;
    self._note_twice = old.take(z.String, "note") != null;
    self._title_taken = old.take(z.String, "title") != null;
}
