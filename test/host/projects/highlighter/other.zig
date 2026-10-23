//! Fixture for the host test "zig tab uses the Zig highlighter": a second
//! tab gets its own highlighter.
const z = @import("ziggurat");

pub const extends = z.godot.Node;

base: *z.godot.Node,
