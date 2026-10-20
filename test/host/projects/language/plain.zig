//! Global class fixture: no `class_name`, so no global class.
const z = @import("ziggurat");

pub const extends = z.godot.Node;

base: *z.godot.Node,
