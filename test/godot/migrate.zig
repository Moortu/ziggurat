//! Migration tests, run inside headless Godot (pulled into the test root by
//! `convert.zig`). Two versions of one fixture script (`mover.zig` in
//! `test/fixtures/migrate_v1` and `migrate_v2`, so their type names agree as
//! two builds of one script do) are described in this one module. The host's
//! part of a migration is played here through the ABI only: `create_blank`,
//! a byte copy of the fields whose name and exact type identity match, a
//! `PrevView` with `moved` flags, the `migrate` call, a reset of every moved
//! old field to the old defaults, then the old `destroy`.
const std = @import("std");
const testing = std.testing;
const ziggurat = @import("ziggurat");
const abi = @import("ziggurat_abi");
const godot = @import("gdzig");
const v1 = @import("fixture_mover_v1");
const v2 = @import("fixture_mover_v2");
const b = godot.builtin;
const Node = godot.class.Node;
const RefCounted = godot.class.RefCounted;
const Resource = godot.class.Resource;

const v1_desc = ziggurat.describe(v1, "mover.zig");
const v2_desc = ziggurat.describe(v2, "mover.zig");

// ---- test HostApi (counts live instance bytes) ----

const test_gen: u32 = 5;
var api: abi.HostApi = undefined;
var live_bytes: usize = 0;

fn hostAlloc(_: u32, size: usize, alignment: u32) callconv(.c) ?*anyopaque {
    const p = std.heap.page_allocator.rawAlloc(size, .fromByteUnits(alignment), @returnAddress()) orelse return null;
    live_bytes += size;
    return p;
}

fn hostFree(_: u32, ptr: ?*anyopaque, size: usize, alignment: u32) callconv(.c) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    live_bytes -= size;
    std.heap.page_allocator.rawFree(p[0..size], .fromByteUnits(alignment), @returnAddress());
}

fn hostLog(_: u32, _: [*]const u8, _: usize) callconv(.c) void {}

fn hostSwap() callconv(.c) void {}

fn setup() void {
    api = .{
        .size = @sizeOf(abi.HostApi),
        .get_proc_address = null,
        .library = null,
        .alloc = &hostAlloc,
        .free = &hostFree,
        .log = &hostLog,
        .request_swap = &hostSwap,
    };
    ziggurat.moduleInit(&api, test_gen);
}

// ---- helpers ----

fn str(s: abi.Str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

fn fieldIndex(d: *const abi.ScriptDesc, name: []const u8) !usize {
    for (d.fields[0..d.field_count], 0..) |f, i| {
        if (std.mem.eql(u8, str(f.name), name)) return i;
    }
    return error.NoSuchField;
}

/// Exact type identity, as the host decides it.
fn sameType(x: abi.FieldDesc, y: abi.FieldDesc) bool {
    return std.mem.eql(u8, str(x.type_name), str(y.type_name)) and x.shape == y.shape and x.size == y.size and x.@"align" == y.@"align";
}

fn setText(field: *ziggurat.String, utf8: []const u8) !void {
    var s = try b.String.fromUtf8(utf8);
    defer s.deinit();
    field.set(s);
}

fn expectText(expected: []const u8, field: *const ziggurat.String) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, field.get().toUtf8Buf(&buf));
}

fn alive(id: u64) bool {
    return godot.raw.objectGetInstanceFromId(id) != null;
}

/// A new Resource held only by `field`.
fn holdResource(field: *ziggurat.Ref(Resource)) u64 {
    const res = Resource.init();
    field.* = .adopt(res);
    return godot.raw.objectGetInstanceId(@ptrCast(res));
}

const max_fields = 32;

/// The view the host passes `migrate`; `moved` starts all 0.
const View = struct {
    moved: [max_fields]u8 = @splat(0),
    view: abi.PrevView = undefined,

    fn init(self: *View, d: *const abi.ScriptDesc, inst: *anyopaque) void {
        self.view = .{ .data = inst, .fields = d.fields, .field_count = d.field_count, .moved = &self.moved };
    }
};

/// Resets every moved field of `inst` to the defaults of `d` (the host does
/// this before the old `destroy`, so a moved value is not released twice).
fn resetMoved(d: *const abi.ScriptDesc, inst: *anyopaque, moved: []const u8) void {
    const data: [*]u8 = @ptrCast(inst);
    const defaults: [*]const u8 = @ptrCast(d.defaults);
    for (d.fields[0..d.field_count], 0..) |f, i| {
        if (moved[i] == 1) @memcpy(data[f.offset..][0..f.size], defaults[f.offset..][0..f.size]);
    }
}

/// The host's whole migration of `old_inst` (an instance of `old_d`) into a
/// new instance of `new_d` with the same owner; `old_inst` is destroyed.
fn hostMigrate(old_d: *const abi.ScriptDesc, old_inst: *anyopaque, new_d: *const abi.ScriptDesc, owner: *anyopaque) !*anyopaque {
    const new_inst = new_d.create_blank(owner, test_gen) orelse return error.CreateFailed;
    var v: View = .{};
    v.init(old_d, old_inst);
    const old_data: [*]const u8 = @ptrCast(old_inst);
    const new_data: [*]u8 = @ptrCast(new_inst);
    for (new_d.fields[0..new_d.field_count]) |nf| {
        // `create_blank` set `base` from the owner.
        if (std.mem.eql(u8, str(nf.name), "base")) continue;
        const i = fieldIndex(old_d, str(nf.name)) catch continue;
        const of = old_d.fields[i];
        if (!sameType(of, nf)) continue;
        @memcpy(new_data[nf.offset..][0..nf.size], old_data[of.offset..][0..of.size]);
        v.moved[i] = 1;
    }
    if (new_d.migrate) |m| m(new_inst, &v.view);
    resetMoved(old_d, old_inst, v.moved[0..old_d.field_count]);
    old_d.destroy(old_inst);
    return new_inst;
}

// ---- tests ----

test "migrate: the hook is in the descriptor, not a method" {
    try testing.expect(v1_desc.migrate == null);
    try testing.expect(v2_desc.migrate != null);
    for (v2_desc.methods[0..v2_desc.method_count]) |m| {
        try testing.expect(!std.mem.eql(u8, str(m.name), "migrate"));
    }
}

test "migrate: type identity" {
    setup();
    const start = live_bytes;
    const owner = Node.init();
    defer godot.raw.objectDestroy(@ptrCast(owner));
    const inst = v1_desc.create(@ptrCast(owner), test_gen) orelse return error.CreateFailed;
    const old: *v1 = @ptrCast(@alignCast(inst));
    old.count = 7;
    old.mood = .angry;
    old._stats = .{ .a = 1, .b = 2 };
    old.speed = 3;

    // The changed types keep their names; only their shape differs.
    for ([_][]const u8{ "mood", "_stats" }) |name| {
        const f1 = v1_desc.fields[try fieldIndex(&v1_desc, name)];
        const f2 = v2_desc.fields[try fieldIndex(&v2_desc, name)];
        try testing.expectEqualStrings(str(f1.type_name), str(f2.type_name));
        try testing.expect(f1.shape != f2.shape);
    }

    var v: View = .{};
    v.init(&v1_desc, inst);
    const prev: ziggurat.Previous(v2) = .{ .view = &v.view };
    // An i32 that became u32, a struct whose inner layout changed, an enum
    // whose tags changed: no value.
    try testing.expectEqual(@as(?u32, null), prev.get(u32, "count"));
    try testing.expectEqual(@as(?v2.Stats, null), prev.get(v2.Stats, "_stats"));
    try testing.expectEqual(@as(?v2.Mood, null), prev.get(v2.Mood, "mood"));
    // Wrong width, a missing name: no value.
    try testing.expectEqual(@as(?i64, null), prev.get(i64, "hp"));
    try testing.expectEqual(@as(?i32, null), prev.get(i32, "missing"));
    // The old types themselves match.
    try testing.expectEqual(@as(?i32, 7), prev.get(i32, "count"));
    try testing.expectEqual(@as(?v1.Mood, .angry), prev.get(v1.Mood, "mood"));
    try testing.expectEqual(@as(?v1.Stats, .{ .a = 1, .b = 2 }), prev.get(v1.Stats, "_stats"));
    try testing.expectEqual(@as(?f32, 3), prev.get(f32, "speed"));
    try testing.expectEqual(@as(?i32, 100), prev.get(i32, "hp"));
    // `get` copies: nothing is marked moved.
    for (v.moved[0..v1_desc.field_count]) |m| try testing.expectEqual(@as(u8, 0), m);

    v1_desc.destroy(inst);
    try testing.expectEqual(start, live_bytes);
}

test "migrate: take moves ownership" {
    setup();
    const start = live_bytes;
    const owner = Node.init();
    defer godot.raw.objectDestroy(@ptrCast(owner));

    // `take` by hand: the value moves out and its field is marked moved.
    {
        const inst = v1_desc.create(@ptrCast(owner), test_gen) orelse return error.CreateFailed;
        const old: *v1 = @ptrCast(@alignCast(inst));
        try setText(&old.note, "taken by hand");
        const res_id = holdResource(&old.item);
        var v: View = .{};
        v.init(&v1_desc, inst);
        const prev: ziggurat.Previous(v2) = .{ .view = &v.view };

        var text = prev.take(ziggurat.String, "note") orelse return error.NothingTaken;
        try expectText("taken by hand", &text);
        try testing.expectEqual(@as(u8, 1), v.moved[try fieldIndex(&v1_desc, "note")]);
        // Taking it again gives nothing; so does a take of another type.
        try testing.expect(prev.take(ziggurat.String, "note") == null);
        try testing.expect(prev.take(ziggurat.StringName, "title") == null);
        try testing.expectEqual(@as(u8, 0), v.moved[try fieldIndex(&v1_desc, "title")]);

        var item = prev.take(ziggurat.Ref(Resource), "item") orelse return error.NothingTaken;
        try testing.expectEqual(@as(u8, 1), v.moved[try fieldIndex(&v1_desc, "item")]);

        // The host resets the moved fields, then destroys the old instance:
        // the taken values survive it.
        resetMoved(&v1_desc, inst, v.moved[0..v1_desc.field_count]);
        v1_desc.destroy(inst);
        try expectText("taken by hand", &text);
        try testing.expect(alive(res_id));
        text._raw.deinit();
        item.release();
        try testing.expect(!alive(res_id));
    }

    // Through the host's migration: `title` and `item` are moved by the
    // host, `note` is taken by `migrate`. Each value is released once, by
    // the new instance's destroy.
    {
        const inst = v1_desc.create(@ptrCast(owner), test_gen) orelse return error.CreateFailed;
        const old: *v1 = @ptrCast(@alignCast(inst));
        try setText(&old.title, "the title");
        try setText(&old.note, "the note");
        const res_id = holdResource(&old.item);

        const new_inst = try hostMigrate(&v1_desc, inst, &v2_desc, @ptrCast(owner));
        const new: *v2 = @ptrCast(@alignCast(new_inst));
        try testing.expect(new._migrated);
        try expectText("the title", &new.title);
        try expectText("the note", &new.memo);
        try testing.expect(!new._note_twice);
        try testing.expect(!new._title_taken);
        try testing.expect(alive(res_id));
        try testing.expectEqual(@as(i32, 1), RefCounted.upcast(new.item.get().?).getReferenceCount());
        v2_desc.destroy(new_inst);
        try testing.expect(!alive(res_id));
    }
    try testing.expectEqual(start, live_bytes);
}

test "migrate: migrate renames a field" {
    setup();
    const start = live_bytes;
    const owner = Node.init();
    defer godot.raw.objectDestroy(@ptrCast(owner));
    const inst = v1_desc.create(@ptrCast(owner), test_gen) orelse return error.CreateFailed;
    const old: *v1 = @ptrCast(@alignCast(inst));
    old.hp = 42;
    old.count = 9;
    old.speed = 2.5;

    const new_inst = try hostMigrate(&v1_desc, inst, &v2_desc, @ptrCast(owner));
    const new: *v2 = @ptrCast(@alignCast(new_inst));
    try testing.expect(new._migrated);
    try testing.expectEqual(@as(i32, 42), new.health);
    // Moved by the host (same name and type); left at its default (changed
    // type, which `migrate` does not convert).
    try testing.expectEqual(@as(f32, 2.5), new.speed);
    try testing.expectEqual(@as(u32, 0), new.count);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(owner)), @as(*anyopaque, @ptrCast(new.base)));
    v2_desc.destroy(new_inst);
    try testing.expectEqual(start, live_bytes);
}
