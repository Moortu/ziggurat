//! Editor reload fixture without tool scripts: the editor never loads a
//! build of this project. The host test changes the default of `speed`,
//! then adds a property, and saves each time; a game run of saved.tscn
//! then loads the build whose manifest the editor wrote.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;

base: *g.Node,
speed: f32 = 5,

pub const signals = struct {
    pub const arrived = struct {};
};

pub fn _ready(self: *@This()) void {
    z.log(.info, "walker ready speed={d}", .{self.speed});
}
