//! Reload stress fixture: the tool script whose method triggers a nested
//! `Main::iteration()`. `preview` emits `wants_previews`; the driver's
//! handler calls `EditorInterface.make_mesh_previews`, which iterates the
//! main loop twice per mesh while this method is on the stack.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;
pub const tool = true;

pub const signals = struct {
    pub const wants_previews = struct {};
};

base: *g.Node,
previews: i64 = 0,

pub fn preview(self: *@This()) i64 {
    self.previews += 1;
    z.emit(self, .wants_previews, .{});
    return self.previews;
}

pub fn version(self: *const @This()) i64 {
    _ = self;
    return 0;
}
