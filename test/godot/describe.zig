//! Descriptor tests (see `convert.zig`, which pulls this file into the test
//! root). `describe` runs at compile time; these tests read its output.
const std = @import("std");
const testing = std.testing;
const ziggurat = @import("ziggurat");
const abi = @import("ziggurat_abi");
const player = @import("fixture_player");
const coin = @import("fixture_coin");
const hud_label = @import("fixture_hud_label");
const godot = @import("gdzig");
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
const hint_enum: u32 = 2;
const hint_flags: u32 = 6;
const hint_resource_type: u32 = 17;
const hint_node_type: u32 = 34;
const group = "Movement/Fast motion";

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

test "describe player: properties in source order, groups, hints" {
    const d = &player_desc;
    const want = [_]PropWant{
        .{ .name = group, .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "speed", .field = 1, .vt = t_float, .hint = hint_range, .hint_string = "0,1000,5" },
        .{ .name = "", .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "health", .field = 2, .vt = t_int, .hint = hint_range, .hint_string = "0,100" },
        .{ .name = "alive", .field = 3, .vt = t_bool },
        .{ .name = "mood", .field = 4, .vt = t_int, .hint = hint_enum, .hint_string = "calm:0,angry:1" },
        .{ .name = "layers", .field = 5, .vt = t_int },
        .{ .name = group, .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "spawn_point", .field = 6, .vt = t_vector2 },
        .{ .name = "", .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "title", .field = 7, .vt = t_string },
        .{ .name = "target", .field = 8, .vt = t_object, .class = "Node", .hint = hint_node_type, .hint_string = "Node" },
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

const E1 = struct {
    pub const extends = Node;
    base: *Node,
    x: i32 = 5,
    pub fn f(self: *@This()) i32 {
        return self.x;
    }
};
const E2 = struct {
    pub const extends = Node;
    x: i32 = 0,
    base: *Node,
};

test "describe: layout hash ignores defaults, follows field order" {
    const ha = ziggurat.describe(A, "a.zig").layout_hash;
    try testing.expectEqual(ha, ziggurat.describe(E1, "a.zig").layout_hash);
    try testing.expect(ha != ziggurat.describe(E2, "a.zig").layout_hash);
}

test "describe coin: resource handle hint" {
    const d = ziggurat.describe(coin, "items/coin.zig");
    try testing.expectEqual(@as(u32, 2), d.property_count);
    const tex = d.properties[1];
    try testing.expectEqualStrings("texture", str(tex.name));
    try testing.expectEqual(t_object, tex.variant_type);
    try testing.expectEqualStrings("Texture2D", str(tex.class_name));
    try testing.expectEqual(hint_resource_type, tex.hint);
    try testing.expectEqualStrings("Texture2D", str(tex.hint_string));
}

/// Packed structs of bools as exported fields.
const Flagged = struct {
    pub const extends = Node;
    pub const meta = .{ .overridden = .{ .hint = 0, .hint_string = "" }, .marked = .{ .hint = 3 } };

    abilities: packed struct { can_fly: bool = false, swimFast: bool = true, glow: bool = false } = .{},
    one: packed struct(u8) { a: bool = false, b: bool = false, c: bool = false, d: bool = false, e: bool = false, f: bool = false, g: bool = false, h: bool = false } = .{},
    mixed: packed struct { a: bool = false, rest: u7 = 0 } = .{},
    wide: packed struct { b0: bool = false, b1: bool = false, b2: bool = false, b3: bool = false, b4: bool = false, b5: bool = false, b6: bool = false, b7: bool = false, b8: bool = false, b9: bool = false, b10: bool = false, b11: bool = false, b12: bool = false, b13: bool = false, b14: bool = false, b15: bool = false, b16: bool = false, b17: bool = false, b18: bool = false, b19: bool = false, b20: bool = false, b21: bool = false, b22: bool = false, b23: bool = false, b24: bool = false, b25: bool = false, b26: bool = false, b27: bool = false, b28: bool = false, b29: bool = false, b30: bool = false, b31: bool = false, b32: bool = false } = .{},
    overridden: packed struct { x: bool = false } = .{},
    marked: packed struct { x: bool = false } = .{},
};

test "flags hint" {
    const d = ziggurat.describe(Flagged, "flagged.zig");
    const want = [_]PropWant{
        .{ .name = "abilities", .field = 0, .vt = t_int, .hint = hint_flags, .hint_string = "can_fly:1,swim_fast:2,glow:4" },
        .{ .name = "one", .field = 1, .vt = t_int, .hint = hint_flags, .hint_string = "a:1,b:2,c:4,d:8,e:16,f:32,g:64,h:128" },
        // A packed struct with a field that is not a bool, or wider than
        // 32 bits, is a plain integer.
        .{ .name = "mixed", .field = 2, .vt = t_int },
        .{ .name = "wide", .field = 3, .vt = t_int },
        // meta wins over the type's hint.
        .{ .name = "overridden", .field = 4, .vt = t_int },
        .{ .name = "marked", .field = 5, .vt = t_int, .hint = 3, .hint_string = "x:1" },
    };
    try testing.expectEqual(@as(u32, want.len), d.property_count);
    for (want, 0..) |w, i| {
        const p = d.properties[i];
        errdefer std.debug.print("property {d} ({s})\n", .{ i, w.name });
        try testing.expectEqualStrings(w.name, str(p.name));
        try testing.expectEqual(w.field, p.field_index);
        try testing.expectEqual(w.vt, p.variant_type);
        try testing.expectEqual(w.hint, p.hint);
        try testing.expectEqualStrings(w.hint_string, str(p.hint_string));
    }
}

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
const coin_desc = ziggurat.describe(coin, "items/coin.zig");
const hud_desc = ziggurat.describe(hud_label, "ui/hud_label.zig");
const table = ziggurat.tableOf(ziggurat.scriptList(&.{ &coin_desc, &player_desc, &hud_desc, &tool_desc }), "0123456789abcdef");

test "tableOf: header, every fixture script, validate" {
    const t = &table;
    try testing.expectEqual(abi.magic, t.magic);
    try testing.expectEqual(abi.abi_version, t.abi_version);
    try testing.expectEqual(@as(u32, @sizeOf(abi.Table)), t.size);
    try testing.expectEqual(ziggurat.layout_stamp, t.layout_stamp);
    try testing.expectEqualStrings(ziggurat.version, str(t.sdk_version));
    try testing.expectEqual(@as(u32, 4), t.script_count);
    try testing.expectEqualStrings("items/coin.zig", str(t.scripts[0].path));
    try testing.expectEqualStrings("player.zig", str(t.scripts[1].path));
    try testing.expectEqualStrings("ui/hud_label.zig", str(t.scripts[2].path));
    try testing.expectEqualStrings("ui/tool.zig", str(t.scripts[3].path));
    try testing.expectEqual(abi.script_flag_tool, t.scripts[2].flags);

    var diag: [256]u8 = undefined;
    // The harness test runner does not set up `testing.allocator`.
    abi.validate(std.heap.page_allocator, t, ziggurat.layout_stamp, .{}, &diag) catch |err| {
        std.debug.print("validate: {s}\n", .{std.mem.sliceTo(&diag, 0)});
        return err;
    };
}

// ---- the SDK writes, the validator reads ----

/// A script at or near every limit the validator checks: a 4096-byte hint
/// string, a 64-argument method and signal, a large enum hint, groups,
/// name overrides, every handle hint.
const Stress = struct {
    pub const extends = godot.class.Node2d;
    pub const class_name = "Stress";
    pub const signals = struct {
        pub const wide = struct {
            s0: i32,
            s1: i32,
            s2: i32,
            s3: i32,
            s4: i32,
            s5: i32,
            s6: i32,
            s7: i32,
            s8: i32,
            s9: i32,
            s10: i32,
            s11: i32,
            s12: i32,
            s13: i32,
            s14: i32,
            s15: i32,
            s16: i32,
            s17: i32,
            s18: i32,
            s19: i32,
            s20: i32,
            s21: i32,
            s22: i32,
            s23: i32,
            s24: i32,
            s25: i32,
            s26: i32,
            s27: i32,
            s28: i32,
            s29: i32,
            s30: i32,
            s31: i32,
            s32: i32,
            s33: i32,
            s34: i32,
            s35: i32,
            s36: i32,
            s37: i32,
            s38: i32,
            s39: i32,
            s40: i32,
            s41: i32,
            s42: i32,
            s43: i32,
            s44: i32,
            s45: i32,
            s46: i32,
            s47: i32,
            s48: i32,
            s49: i32,
            s50: i32,
            s51: i32,
            s52: i32,
            s53: i32,
            s54: i32,
            s55: i32,
            s56: i32,
            s57: i32,
            s58: i32,
            s59: i32,
            s60: i32,
            s61: i32,
            s62: i32,
            s63: i32,
        };
        pub const target_lost = struct { who: ?*Node, why: godot.builtin.String };
    };
    pub const meta = .{
        .speed = .{ .range = .{ 0, 10, 0.5 }, .group = "Motion/Fast" },
        .accel = .{ .group = "Motion/Fast", .name = "acceleration" },
        .note = .{ .hint = 18, .hint_string = &@as([4096]u8, @splat('h')) },
        .wideMethod = .{ .name = "wide_method" },
        .aimAt = .{ .args = .{ "where", "how_fast" } },
    };

    base: *godot.class.Node2d,
    speed: f32 = 1,
    accel: f64 = 2,
    note: ziggurat.String = .empty,
    mode: enum { tag_0, tag_1, tag_2, tag_3, tag_4, tag_5, tag_6, tag_7, tag_8, tag_9, tag_10, tag_11, tag_12, tag_13, tag_14, tag_15, tag_16, tag_17, tag_18, tag_19, tag_20, tag_21, tag_22, tag_23, tag_24, tag_25, tag_26, tag_27, tag_28, tag_29, tag_30, tag_31, tag_32, tag_33, tag_34, tag_35, tag_36, tag_37, tag_38, tag_39, tag_40, tag_41, tag_42, tag_43, tag_44, tag_45, tag_46, tag_47, tag_48, tag_49, tag_50, tag_51, tag_52, tag_53, tag_54, tag_55, tag_56, tag_57, tag_58, tag_59, tag_60, tag_61, tag_62, tag_63, tag_64, tag_65, tag_66, tag_67, tag_68, tag_69, tag_70, tag_71, tag_72, tag_73, tag_74, tag_75, tag_76, tag_77, tag_78, tag_79, tag_80, tag_81, tag_82, tag_83, tag_84, tag_85, tag_86, tag_87, tag_88, tag_89, tag_90, tag_91, tag_92, tag_93, tag_94, tag_95, tag_96, tag_97, tag_98, tag_99, tag_100, tag_101, tag_102, tag_103, tag_104, tag_105, tag_106, tag_107, tag_108, tag_109, tag_110, tag_111, tag_112, tag_113, tag_114, tag_115, tag_116, tag_117, tag_118, tag_119, tag_120, tag_121, tag_122, tag_123, tag_124, tag_125, tag_126, tag_127, tag_128, tag_129, tag_130, tag_131, tag_132, tag_133, tag_134, tag_135, tag_136, tag_137, tag_138, tag_139, tag_140, tag_141, tag_142, tag_143, tag_144, tag_145, tag_146, tag_147, tag_148, tag_149, tag_150, tag_151, tag_152, tag_153, tag_154, tag_155, tag_156, tag_157, tag_158, tag_159, tag_160, tag_161, tag_162, tag_163, tag_164, tag_165, tag_166, tag_167, tag_168, tag_169, tag_170, tag_171, tag_172, tag_173, tag_174, tag_175, tag_176, tag_177, tag_178, tag_179, tag_180, tag_181, tag_182, tag_183, tag_184, tag_185, tag_186, tag_187, tag_188, tag_189, tag_190, tag_191, tag_192, tag_193, tag_194, tag_195, tag_196, tag_197, tag_198, tag_199, tag_200, tag_201, tag_202, tag_203, tag_204, tag_205, tag_206, tag_207, tag_208, tag_209, tag_210, tag_211, tag_212, tag_213, tag_214, tag_215, tag_216, tag_217, tag_218, tag_219, tag_220, tag_221, tag_222, tag_223, tag_224, tag_225, tag_226, tag_227, tag_228, tag_229, tag_230, tag_231, tag_232, tag_233, tag_234, tag_235, tag_236, tag_237, tag_238, tag_239, tag_240, tag_241, tag_242, tag_243, tag_244, tag_245, tag_246, tag_247, tag_248, tag_249, tag_250, tag_251, tag_252, tag_253, tag_254, tag_255, tag_256, tag_257, tag_258, tag_259, tag_260, tag_261, tag_262, tag_263, tag_264, tag_265, tag_266, tag_267, tag_268, tag_269, tag_270, tag_271, tag_272, tag_273, tag_274, tag_275, tag_276, tag_277, tag_278, tag_279, tag_280, tag_281, tag_282, tag_283, tag_284, tag_285, tag_286, tag_287, tag_288, tag_289, tag_290, tag_291, tag_292, tag_293, tag_294, tag_295, tag_296, tag_297, tag_298, tag_299 } = .tag_0,
    target: ziggurat.Obj(Node) = .{},
    skin: ziggurat.Ref(godot.class.Texture2d) = .{},
    spot: godot.builtin.Vector2 = .{ .x = 0, .y = 0 },
    _hidden: i64 = 0,

    pub fn wideMethod(self: *Stress, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32) i64 {
        return self._hidden;
    }

    pub fn aimAt(self: *Stress, where: godot.builtin.Vector2, how_fast: f32) void {
        self.spot = where;
        self.speed = how_fast;
    }

    pub fn _ready(self: *Stress) void {
        self._hidden = 1;
    }
};

const stress_desc = ziggurat.describe(Stress, "deep/er/stress test.zig");
const stress_table = ziggurat.tableOf(ziggurat.scriptList(&.{ &coin_desc, &stress_desc, &player_desc, &hud_desc, &tool_desc }), "fedcba9876543210");

test "tableOf: a script at the limits validates" {
    const d = &stress_desc;
    try testing.expectEqual(@as(u32, 64), d.signals[0].arg_count);
    var wide: ?abi.MethodDesc = null;
    for (d.methods[0..d.method_count]) |m| {
        if (std.mem.eql(u8, str(m.name), "wide_method")) wide = m;
    }
    try testing.expectEqual(@as(u32, 64), wide.?.arg_count);
    var diag: [256]u8 = undefined;
    abi.validate(std.heap.page_allocator, &stress_table, ziggurat.layout_stamp, .{}, &diag) catch |err| {
        std.debug.print("validate: {s}\n", .{std.mem.sliceTo(&diag, 0)});
        return err;
    };
}
