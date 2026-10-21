//! Editor defaults fixture: a tool script. The host test saves it with
//! `level` changed from i32 to i64, which moves `note` and the fields after
//! it to new offsets, and reads every property's default from the
//! incremental build that follows.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;
pub const tool = true;

base: *g.RefCounted,
bumps: i64 = 0,
points: i64 = 0,
level: i32 = 0,
extra: i32 = 2,
note: z.String = .empty,
migrations: i64 = 0,

pub fn version(self: *const @This()) i64 {
    _ = self;
    return 1;
}
