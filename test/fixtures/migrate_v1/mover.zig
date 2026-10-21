//! Fixture script, version 1 of two (see `../migrate_v2/mover.zig`). Both
//! files are named `mover.zig`, so their types have the same names, as two
//! builds of one script do; only their layout differs.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

pub const Mood = enum { calm, angry };
pub const Stats = struct { a: i32 = 0, b: i32 = 0 };

base: *g.Node,
/// Renamed to `health` in version 2.
hp: i32 = 100,
/// `u32` in version 2.
count: i32 = 0,
/// Version 2 adds a tag.
mood: Mood = .calm,
/// Version 2 replaces `b` with `c: i64`.
_stats: Stats = .{},
/// Unchanged: the host moves these two.
speed: f32 = 1.5,
title: z.String = .empty,
/// Renamed to `memo` in version 2.
note: z.String = .empty,
/// Unchanged; version 2's `migrate` takes nothing from it.
item: z.Ref(g.Resource) = .{},
