//! Global class fixture: a top-level `class_name` on a tool script. Only
//! scanned as text by the host tests, never built.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;
pub const class_name = "Alpha";
pub const tool = true;

base: *g.Node2D,
