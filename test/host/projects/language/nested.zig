//! Global class fixture: a `class_name` only inside a nested struct.
const z = @import("ziggurat");

pub const extends = z.godot.Node;

pub const Inner = struct {
    pub const class_name = "Nested";
};
