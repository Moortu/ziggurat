//! Instance fixture: a script on a RefCounted owner, with a `deinit` that
//! logs, so a test can see the instance freed when the last reference goes.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.RefCounted;

uses: i32 = 7,

pub fn deinit(self: *@This()) void {
    z.log(.info, "keeper deinit uses={d}", .{self.uses});
}
