//! Global class fixture: a `class_name` only in comments and a string.
const z = @import("ziggurat");

// pub const class_name = "Commented";
/// pub const class_name = "DocCommented";
const text = "pub const class_name = \"InString\";";

pub const extends = z.godot.Node;
