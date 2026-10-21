//! Reload stress fixture: owned values (`z.String`, `z.StringName`, a
//! `z.Ref`) that every swap must move. The stress driver rewrites this
//! file with a new `version` and with or without `pad`, which changes the
//! layout.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;
pub const tool = true;

base: *g.RefCounted,
label: z.String = .empty,
tag: z.StringName = .empty,
res: z.Ref(g.Resource) = .{},

pub fn version(self: *const @This()) i64 {
    _ = self;
    return 0;
}
