//! Gate fixture: a Node script, for an instance freed while it is being
//! migrated.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
value: i32 = 7,

pub fn answer(self: *const @This()) i32 {
    return self.value + 1;
}
