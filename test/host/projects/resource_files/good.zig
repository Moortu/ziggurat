//! Loader fixture: a script that compiles. The loader only reads its text.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;
pub const class_name = "LoaderGood";

base: *g.Node,
count: i32 = 0,

// Non-ASCII text must survive a load: ä ö ü € 日本語
pub fn ping(self: *@This(), x: i32) i32 {
    self.count += x;
    return self.count;
}
