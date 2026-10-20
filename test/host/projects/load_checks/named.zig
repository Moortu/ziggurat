//! Load-check fixture: a property and a method whose Godot names already
//! exist in Node.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
name: i32 = 0,

pub fn getName(self: *@This()) i32 {
    return self.name;
}
