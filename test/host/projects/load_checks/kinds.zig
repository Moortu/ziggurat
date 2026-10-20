//! Load-check fixture: members whose Godot names exist in an ancestor of
//! Node2D as another kind of member: a method named like the signal
//! CanvasItem.draw, a signal named like the method CanvasItem.hide and a
//! signal named like the property CanvasItem.visible.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node2D;

base: *g.Node2D,

pub const signals = struct {
    pub const hide = struct {};
    pub const visible = struct {};
};

pub fn draw(self: *@This()) i32 {
    _ = self;
    return 0;
}
