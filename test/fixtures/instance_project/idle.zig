//! Instance fixture: a Node script without `_process` or `_ready`.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
count: i32 = 0,

pub fn ping(self: *@This(), x: i32) i32 {
    self.count += x;
    return self.count;
}
