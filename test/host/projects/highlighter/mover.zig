//! Fixture for the host test "zig tab uses the Zig highlighter": the
//! script editor colours it; it is never built into a module that loads.
const z = @import("ziggurat");

pub const extends = z.godot.Node;

pub const smile = if (true) "ä😀" else 42;

base: *z.godot.Node,
speed: f32 = 1.5,
