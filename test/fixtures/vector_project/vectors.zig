//! Fixture script: one exported field of every vector-like Variant type,
//! with distinct non-trivial default values, so a swapped component or
//! column shows up in the descriptor cache.
const z = @import("ziggurat");
const g = z.godot;

pub const extends = g.Node;
pub const class_name = "Vectors";

base: *g.Node,
v2: g.Vector2 = .{ .x = 1.5, .y = -2.25 },
v2i: g.Vector2i = .{ .x = 3, .y = -4 },
v3: g.Vector3 = .{ .x = 1, .y = 2, .z = 3 },
v3i: g.Vector3i = .{ .x = 5, .y = 6, .z = -7 },
v4: g.Vector4 = .{ .x = 1, .y = 2, .z = 3, .w = 4 },
v4i: g.Vector4i = .{ .x = 8, .y = 9, .z = 10, .w = -11 },
col: g.Color = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 0.125 },
r2: g.Rect2 = .{ .position = .{ .x = 1, .y = 2 }, .size = .{ .x = 3, .y = 4 } },
r2i: g.Rect2i = .{ .position = .{ .x = 5, .y = 6 }, .size = .{ .x = 7, .y = 8 } },
plane: g.Plane = .{ .normal = .{ .x = 1, .y = 2, .z = 3 }, .d = 4 },
quat: g.Quaternion = .{ .x = 0.5, .y = 0.25, .z = 0.125, .w = 1 },
aabb: g.AABB = .{ .position = .{ .x = 1, .y = 2, .z = 3 }, .size = .{ .x = 4, .y = 5, .z = 6 } },
basis: g.Basis = .{ .x = .{ .x = 1, .y = 2, .z = 3 }, .y = .{ .x = 4, .y = 5, .z = 6 }, .z = .{ .x = 7, .y = 8, .z = 9 } },
t2: g.Transform2D = .{ .x = .{ .x = 1, .y = 2 }, .y = .{ .x = 3, .y = 4 }, .origin = .{ .x = 5, .y = 6 } },
t3: g.Transform3D = .{
    .basis = .{ .x = .{ .x = 1, .y = 2, .z = 3 }, .y = .{ .x = 4, .y = 5, .z = 6 }, .z = .{ .x = 7, .y = 8, .z = 9 } },
    .origin = .{ .x = 10, .y = 11, .z = 12 },
},
proj: g.Projection = .{
    .x = .{ .x = 1, .y = 2, .z = 3, .w = 4 },
    .y = .{ .x = 5, .y = 6, .z = 7, .w = 8 },
    .z = .{ .x = 9, .y = 10, .z = 11, .w = 12 },
    .w = .{ .x = 13, .y = 14, .z = 15, .w = 16 },
},
