//! Swap fixture: only in version 1. Its instances keep running this code
//! after a swap to version 2.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;

base: *g.RefCounted,
value: i32 = 9,

pub fn answer(self: *const @This()) i32 {
    return self.value + 1;
}
