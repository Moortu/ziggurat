//! Editor build fixture: the host test changes this file outside the editor
//! and checks that the cached script gets the new text.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
