//! Editor reload fixture: a tool script. The host test opens a node with it
//! in the editor, changes `level`, then edits `value` to return 2 and saves:
//! the node runs the new code and keeps `level`.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;
pub const tool = true;

base: *g.Node,
level: i32 = 0,

pub fn value(self: *const @This()) i32 {
    _ = self;
    return 1;
}
