//! Editor reload fixture without tool scripts: the editor never loads a
//! build of this project. The host test changes the default of `speed`,
//! then adds a property, and saves each time.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
speed: f32 = 5,
