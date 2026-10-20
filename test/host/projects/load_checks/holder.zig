//! Load-check fixture: a Resource script with a Node field.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Resource;

base: *g.Resource,
target: z.Obj(g.Node) = .{},
