//! Swap fixture, version 1 of two (see `../swap_v2/migrator.zig`): version
//! 2's `migrate` hook renames `hp` to `health` (read with `get`), moves
//! `note` into `memo` and `res` into `asset` (`takeInto` into empty
//! fields), and replaces `slot`, which the host moves itself, with
//! `alt_slot` (`takeInto` over a filled field releases the moved value).
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
hp: i32 = 100,
note: z.String = .empty,
res: z.Ref(g.Resource) = .{},
slot: z.Ref(g.Resource) = .{},
alt_slot: z.Ref(g.Resource) = .{},
