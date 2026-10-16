//! Descriptor tests (see `convert.zig`, which pulls this file into the test
//! root). `describe` runs at compile time; these tests read its output.
const std = @import("std");
const testing = std.testing;
const ziggurat = @import("ziggurat");
const abi = @import("ziggurat_abi");
const player = @import("fixture_player");
const godot = ziggurat.godot;
const Node = godot.class.Node;

const t_nil: u32 = 0;
const t_bool: u32 = 1;
const t_int: u32 = 2;
const t_float: u32 = 3;
const t_string: u32 = 4;
const t_vector2: u32 = 5;
const t_object: u32 = 24;

const usage_script: u32 = 4102;
const usage_group: u32 = 64;
const hint_range: u32 = 1;

fn str(s: abi.Str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

const PropWant = struct {
    name: []const u8,
    field: u32,
    vt: u32,
    class: []const u8 = "",
    hint: u32 = 0,
    hint_string: []const u8 = "",
    usage: u32 = usage_script,
};

const player_desc = ziggurat.describe(player, "player.zig");

test "describe player: script facts" {
    const d = &player_desc;
    try testing.expectEqualStrings("player.zig", str(d.path));
    try testing.expectEqualStrings("Player", str(d.class_name));
    try testing.expectEqualStrings("CharacterBody2D", str(d.base_class));
    try testing.expectEqual(@as(u32, 0), d.flags);
    try testing.expectEqual(@as(u32, @sizeOf(player)), d.instance_size);
    try testing.expectEqual(@as(u32, @alignOf(player)), d.instance_align);
    try testing.expect(d.migrate == null);
}

test "describe player: fields" {
    const d = &player_desc;
    const names = [_][]const u8{ "base", "speed", "health", "alive", "mood", "layers", "spawn", "title", "target", "_dash_timer" };
    try testing.expectEqual(@as(u32, names.len), d.field_count);
    for (names, 0..) |n, i| {
        const f = d.fields[i];
        try testing.expectEqualStrings(n, str(f.name));
    }
    try testing.expectEqual(@as(u32, @offsetOf(player, "speed")), d.fields[1].offset);
    try testing.expectEqual(@as(u32, @sizeOf(f32)), d.fields[1].size);
    try testing.expectEqual(@as(u32, @offsetOf(player, "target")), d.fields[8].offset);
    try testing.expect(d.fields[1].type_id != d.fields[2].type_id);
    try testing.expectEqual(d.fields[1].type_id, d.fields[9].type_id); // both f32
}

test "describe player: properties, group position, hints" {
    const d = &player_desc;
    const want = [_]PropWant{
        .{ .name = "health", .field = 2, .vt = t_int, .hint = hint_range, .hint_string = "0,100" },
        .{ .name = "alive", .field = 3, .vt = t_bool },
        .{ .name = "mood", .field = 4, .vt = t_int },
        .{ .name = "layers", .field = 5, .vt = t_int },
        .{ .name = "title", .field = 7, .vt = t_string },
        .{ .name = "target", .field = 8, .vt = t_object, .class = "Node" },
        .{ .name = "Movement", .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "speed", .field = 1, .vt = t_float, .hint = hint_range, .hint_string = "0,1000,5" },
        .{ .name = "spawn_point", .field = 6, .vt = t_vector2 },
    };
    try testing.expectEqual(@as(u32, want.len), d.property_count);
    for (want, 0..) |w, i| {
        const p = d.properties[i];
        errdefer std.debug.print("property {d} ({s})\n", .{ i, w.name });
        try testing.expectEqualStrings(w.name, str(p.name));
        try testing.expectEqual(w.field, p.field_index);
        try testing.expectEqual(w.vt, p.variant_type);
        try testing.expectEqualStrings(w.class, str(p.class_name));
        try testing.expectEqual(w.hint, p.hint);
        try testing.expectEqualStrings(w.hint_string, str(p.hint_string));
        try testing.expectEqual(w.usage, p.usage);
    }
}

test "describe player: methods" {
    const d = &player_desc;
    try testing.expectEqual(@as(u32, 3), d.method_count);

    const m0 = d.methods[0];
    try testing.expectEqualStrings("_physics_process", str(m0.name));
    try testing.expectEqual(abi.method_flag_virtual, m0.flags);
    try testing.expectEqual(@as(u32, 1), m0.arg_count);
    try testing.expectEqualStrings("arg0", str(m0.args[0].name));
    try testing.expectEqual(t_float, m0.args[0].variant_type);
    try testing.expectEqual(t_nil, m0.ret.variant_type);

    const m1 = d.methods[1];
    try testing.expectEqualStrings("take_damage", str(m1.name));
    try testing.expectEqual(@as(u32, 0), m1.flags);
    try testing.expectEqual(@as(u32, 2), m1.arg_count);
    try testing.expectEqualStrings("amount", str(m1.args[0].name));
    try testing.expectEqual(t_int, m1.args[0].variant_type);
    try testing.expectEqualStrings("critical", str(m1.args[1].name));
    try testing.expectEqual(t_bool, m1.args[1].variant_type);
    try testing.expectEqual(t_nil, m1.ret.variant_type);

    const m2 = d.methods[2];
    try testing.expectEqualStrings("leap", str(m2.name));
    try testing.expectEqual(@as(u32, 1), m2.arg_count);
    try testing.expectEqualStrings("arg0", str(m2.args[0].name));
    try testing.expectEqual(t_float, m2.args[0].variant_type);
    try testing.expectEqual(t_float, m2.ret.variant_type);
}

test "describe player: signals" {
    const d = &player_desc;
    try testing.expectEqual(@as(u32, 2), d.signal_count);
    try testing.expectEqualStrings("died", str(d.signals[0].name));
    try testing.expectEqual(@as(u32, 0), d.signals[0].arg_count);
    const hit = d.signals[1];
    try testing.expectEqualStrings("hit", str(hit.name));
    try testing.expectEqual(@as(u32, 2), hit.arg_count);
    try testing.expectEqualStrings("damage", str(hit.args[0].name));
    try testing.expectEqual(t_int, hit.args[0].variant_type);
    try testing.expectEqualStrings("source", str(hit.args[1].name));
    try testing.expectEqual(t_object, hit.args[1].variant_type);
    try testing.expectEqualStrings("Node", str(hit.args[1].class_name));
}

test "describe player: defaults image" {
    const v: *const player = @ptrCast(@alignCast(player_desc.defaults));
    try testing.expectEqual(@as(f32, 300), v.speed);
    try testing.expectEqual(@as(i32, 100), v.health);
    try testing.expect(v.alive);
    try testing.expectEqual(player.Mood.calm, v.mood);
    try testing.expectEqual(@as(f32, 2), v.spawn.y);
    try testing.expectEqual(@as(u64, 0), v.target.id);
    try testing.expectEqual(@as(f32, 0), v._dash_timer);
}

test "describe player: placeholder wrappers" {
    const d = &player_desc;
    var dummy: u64 = 0;
    var err: abi.CallError = .{ .@"error" = abi.call_ok, .argument = 0, .expected = 0 };
    d.call(&dummy, 0, undefined, 0, &dummy, &err);
    try testing.expectEqual(abi.call_invalid_method, err.@"error");
    try testing.expectEqual(@as(u8, 0), d.get(&dummy, 0, &dummy));
    try testing.expectEqual(@as(u8, 0), d.set(&dummy, 0, &dummy));
    try testing.expectEqual(@as(u8, 0), d.get_default(0, &dummy));
    try testing.expect(d.create(&dummy, 1) == null);
}

const A = struct {
    pub const extends = Node;
    base: *Node,
    x: i32 = 0,
    pub fn f(self: *@This()) i32 {
        return self.x;
    }
};
const B = struct {
    pub const extends = Node;
    base: *Node,
    x: i64 = 0,
    pub fn f(self: *@This()) i32 {
        return @intCast(self.x);
    }
};
const C = struct {
    pub const extends = Node;
    base: *Node,
    x: i32 = 0,
    pub fn f(self: *@This()) i32 {
        return self.x + 1;
    }
};
const D = struct {
    pub const extends = Node;
    base: *Node,
    y: i32 = 0,
    pub fn f(self: *@This()) i32 {
        return self.y;
    }
};

test "describe: layout hash follows fields, not method bodies" {
    const ha = ziggurat.describe(A, "a.zig").layout_hash;
    try testing.expect(ha != ziggurat.describe(B, "a.zig").layout_hash);
    try testing.expectEqual(ha, ziggurat.describe(C, "a.zig").layout_hash);
    try testing.expect(ha != ziggurat.describe(D, "a.zig").layout_hash);
}

const Tool = struct {
    pub const extends = godot.class.Label;
    pub const tool = true;
    text_size: f64 = 1,
};

test "describe: tool flag, no class name, no base field" {
    const d = ziggurat.describe(Tool, "ui/tool.zig");
    try testing.expectEqual(abi.script_flag_tool, d.flags);
    try testing.expectEqualStrings("", str(d.class_name));
    try testing.expectEqualStrings("Label", str(d.base_class));
    try testing.expectEqual(@as(u32, 1), d.property_count);
    try testing.expectEqual(@as(u32, 0), d.method_count);
}

const tool_desc = ziggurat.describe(Tool, "ui/tool.zig");
const table = ziggurat.makeTable(&.{ &player_desc, &tool_desc });

test "makeTable: header and scripts" {
    const t = &table;
    try testing.expectEqual(abi.magic, t.magic);
    try testing.expectEqual(abi.abi_version, t.abi_version);
    try testing.expectEqual(@as(u32, @sizeOf(abi.Table)), t.size);
    try testing.expectEqual(ziggurat.layout_stamp, t.layout_stamp);
    try testing.expectEqualStrings(ziggurat.version, str(t.sdk_version));
    try testing.expectEqual(@as(u32, 2), t.script_count);
    try testing.expectEqualStrings("player.zig", str(t.scripts[0].path));
    try testing.expectEqualStrings("ui/tool.zig", str(t.scripts[1].path));

    var diag: [256]u8 = undefined;
    // The harness test runner does not set up `testing.allocator`.
    abi.validate(std.heap.page_allocator, t, ziggurat.layout_stamp, .{}, &diag) catch |err| {
        std.debug.print("validate: {s}\n", .{std.mem.sliceTo(&diag, 0)});
        return err;
    };
}
