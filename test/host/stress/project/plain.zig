//! Reload stress fixture: a plain script (not a tool script), so its node
//! in the editor holds a placeholder that shows `mark`'s default.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
mark: i32 = 0,

pub fn version(self: *const @This()) i64 {
    _ = self;
    return 0;
}
