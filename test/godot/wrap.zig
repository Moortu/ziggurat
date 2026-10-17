//! Wrapper tests, run inside headless Godot (see `convert.zig`, which pulls
//! this file into the test root). The descriptors' C-ABI functions are
//! called as the host will call them, with a test HostApi whose `alloc`
//! and `free` count live bytes. Source Variants are built with Godot's own
//! constructors, results are read back with `convert`.
const std = @import("std");
const testing = std.testing;
const ziggurat = @import("ziggurat");
const abi = @import("ziggurat_abi");
const player = @import("fixture_player");
const godot = ziggurat.godot;
const convert = ziggurat.convert;
const Ref = ziggurat.Ref;
const b = godot.builtin;
const Variant = b.Variant;
const Node = godot.class.Node;
const RefCounted = godot.class.RefCounted;
const Resource = godot.class.Resource;

const t_nil: u32 = 0;
const t_bool: u32 = 1;
const t_int: u32 = 2;
const t_float: u32 = 3;
const t_string: u32 = 4;
const t_object: u32 = 24;

// ---- test HostApi ----

const test_gen: u32 = 3;
var api: abi.HostApi = undefined;
var live_bytes: usize = 0;
var refuse_alloc = false;
var log_count: usize = 0;

fn hostAlloc(_: u32, size: usize, alignment: u32) callconv(.c) ?*anyopaque {
    if (refuse_alloc) return null;
    const p = std.heap.page_allocator.rawAlloc(size, .fromByteUnits(alignment), @returnAddress()) orelse return null;
    live_bytes += size;
    return p;
}

fn hostFree(_: u32, ptr: ?*anyopaque, size: usize, alignment: u32) callconv(.c) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    std.heap.page_allocator.rawFree(p[0..size], .fromByteUnits(alignment), @returnAddress());
    live_bytes -= size;
}

fn hostLog(_: u32, _: [*]const u8, _: usize) callconv(.c) void {
    log_count += 1;
}

fn hostSwap() callconv(.c) void {}

/// Points the SDK at the counting HostApi. No proc table: gdzig keeps the
/// one the test harness set.
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
    refuse_alloc = false;
    log_count = 0;
}

// ---- Variants ----

const Ctor = *const fn (*anyopaque, *anyopaque) callconv(.c) void;

fn make(t: u32, value: anytype) Variant {
    var in = value;
    var v: Variant = undefined;
    const ctor: Ctor = @ptrCast(godot.raw.getVariantFromTypeConstructor(t).?);
    ctor(&v, @ptrCast(&in));
    return v;
}

fn makeInt(x: i64) Variant {
    return make(t_int, x);
}

fn makeFloat(x: f64) Variant {
    return make(t_float, x);
}

fn makeBool(x: bool) Variant {
    return make(t_bool, x);
}

fn makeObject(o: anytype) Variant {
    const p: ?*anyopaque = @ptrCast(o);
    return make(t_object, p);
}

fn makeString(utf8: []const u8) !Variant {
    var s = try b.String.fromUtf8(utf8);
    defer s.deinit();
    return make(t_string, s);
}

fn destroy(v: *Variant) void {
    godot.raw.variantDestroy(v);
}

fn typeOf(v: *const Variant) u32 {
    return @intCast(godot.raw.variantGetType(v));
}

fn readAs(comptime T: type, v: *const Variant) !T {
    var out: T = undefined;
    if (convert.read(T, v, &out)) |_| return error.ReadFailed;
    return out;
}

fn expectUtf8(expected: []const u8, v: *const Variant) !void {
    var s = try readAs(b.String, v);
    defer s.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, s.toUtf8Buf(&buf));
}

fn alive(id: u64) bool {
    return godot.raw.objectGetInstanceFromId(id) != null;
}

fn idOf(o: anytype) u64 {
    return godot.raw.objectGetInstanceId(@ptrCast(o));
}

fn refCount(r: *Resource) i32 {
    return RefCounted.upcast(r).getReferenceCount();
}

fn dropCreation(r: *Resource) void {
    if (RefCounted.upcast(r).unreference()) godot.raw.objectDestroy(@ptrCast(r));
}

// ---- descriptors ----

const player_desc = ziggurat.describe(player, "player.zig");

/// A script with every hook the wrappers call.
const Probe = struct {
    pub const extends = Node;

    base: *Node,
    level: i32 = 1,
    name: b.String = .empty,
    item: Ref(Resource) = .{},
    _inited: bool = false,
    _last_what: i32 = -1,
    _tag: b.StringName = .empty,

    pub fn init(self: *Probe) void {
        self._inited = true;
    }

    pub fn deinit(self: *Probe) void {
        // `deinit` runs while the fields still hold their values.
        deinit_saw_item = self.item.get() != null;
    }

    pub fn _notification(self: *Probe, what: i32) void {
        self._last_what = what;
    }

    pub fn get_level(self: *const Probe) i32 {
        return self.level + 1;
    }

    pub fn set_level(self: *Probe, value: i32) void {
        self.level = value * 10;
    }

    pub fn add(self: *const Probe, a: i32, c: i32) i32 {
        return a + c + self.level;
    }

    pub fn nameLength(self: *const Probe, s: b.String, extra: i32) i64 {
        _ = self;
        return s.length() + extra;
    }

    pub fn label(self: *const Probe) b.String {
        _ = self;
        return b.String.fromUtf8("probe") catch .empty;
    }
};

var deinit_saw_item = false;

const probe_desc = ziggurat.describe(Probe, "probe.zig");

fn str(s: abi.Str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

fn methodIndex(d: *const abi.ScriptDesc, name: []const u8) !u32 {
    for (d.methods[0..d.method_count], 0..) |m, i| {
        if (std.mem.eql(u8, str(m.name), name)) return @intCast(i);
    }
    return error.NoSuchMethod;
}

fn propertyIndex(d: *const abi.ScriptDesc, name: []const u8) !u32 {
    for (d.properties[0..d.property_count], 0..) |p, i| {
        if (std.mem.eql(u8, str(p.name), name) and p.field_index != abi.no_field) return @intCast(i);
    }
    return error.NoSuchProperty;
}

/// `d.get` of property `name` into a new Variant; the caller destroys it.
fn getProp(d: *const abi.ScriptDesc, inst: *anyopaque, name: []const u8) !Variant {
    var v: Variant = undefined;
    if (d.get(inst, try propertyIndex(d, name), &v) != 1) return error.GetFailed;
    return v;
}

fn setProp(d: *const abi.ScriptDesc, inst: *anyopaque, name: []const u8, value: *const Variant) !u8 {
    return d.set(inst, try propertyIndex(d, name), value);
}

const Call = struct {
    ret: Variant,
    err: abi.CallError,
};

fn callMethod(d: *const abi.ScriptDesc, inst: *anyopaque, method: u32, args: []const *const Variant) Call {
    var c: Call = .{ .ret = undefined, .err = .{ .@"error" = 99, .argument = 99, .expected = 99 } };
    d.call(inst, method, @ptrCast(args.ptr), @intCast(args.len), &c.ret, &c.err);
    return c;
}

fn expectCallOk(c: *const Call) !void {
    try testing.expectEqual(abi.call_ok, c.err.@"error");
}

/// An instance of `d` owned by a new node of class `Owner`.
fn Instance(comptime Owner: type) type {
    return struct {
        owner: *Owner,
        inst: *anyopaque,

        fn init(d: *const abi.ScriptDesc) !@This() {
            const owner = Owner.init();
            errdefer godot.raw.objectDestroy(@ptrCast(owner));
            const inst = d.create(@ptrCast(owner), test_gen) orelse return error.CreateFailed;
            return .{ .owner = owner, .inst = inst };
        }

        fn deinit(self: @This(), d: *const abi.ScriptDesc) void {
            d.destroy(self.inst);
            godot.raw.objectDestroy(@ptrCast(self.owner));
        }
    };
}

// ---- tests ----

test "wrap create and destroy" {
    setup();
    const d = &player_desc;
    const start = live_bytes;
    // A CharacterBody2D cannot be made at the SCENE init level these tests
    // run in (no physics server yet). The wrappers only store `base`, never
    // use it, so a plain Node stands in as the owner.
    const owner = Node.init();
    defer godot.raw.objectDestroy(@ptrCast(owner));
    const inst = d.create(@ptrCast(owner), test_gen) orelse return error.CreateFailed;
    try testing.expectEqual(start + @sizeOf(player), live_bytes);
    const p: *player = @ptrCast(@alignCast(inst));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(owner)), @as(*anyopaque, @ptrCast(p.base)));

    // Defaults through `get`.
    var speed = try getProp(d, inst, "speed");
    defer destroy(&speed);
    try testing.expectEqual(@as(f64, 300), try readAs(f64, &speed));
    var health = try getProp(d, inst, "health");
    defer destroy(&health);
    try testing.expectEqual(@as(i64, 100), try readAs(i64, &health));
    var alive_v = try getProp(d, inst, "alive");
    defer destroy(&alive_v);
    try testing.expectEqual(true, try readAs(bool, &alive_v));
    var mood = try getProp(d, inst, "mood");
    defer destroy(&mood);
    try testing.expectEqual(@as(i64, 0), try readAs(i64, &mood));
    var layers = try getProp(d, inst, "layers");
    defer destroy(&layers);
    try testing.expectEqual(@as(i64, 1), try readAs(i64, &layers));
    var spawn = try getProp(d, inst, "spawn_point");
    defer destroy(&spawn);
    const sp = try readAs(b.Vector2, &spawn);
    try testing.expectEqual(@as(f32, 1), sp.x);
    try testing.expectEqual(@as(f32, 2), sp.y);
    var title = try getProp(d, inst, "title");
    defer destroy(&title);
    try expectUtf8("", &title);
    var target = try getProp(d, inst, "target");
    defer destroy(&target);
    try testing.expectEqual(t_nil, typeOf(&target));

    // A group entry and an index past the end have no value.
    var unused: Variant = undefined;
    try testing.expectEqual(@as(u32, abi.no_field), d.properties[0].field_index);
    try testing.expectEqual(@as(u8, 0), d.get(inst, 0, &unused));
    try testing.expectEqual(@as(u8, 0), d.get(inst, d.property_count, &unused));
    try testing.expectEqual(@as(u8, 0), d.get(inst, std.math.maxInt(u32), &unused));

    d.destroy(inst);
    try testing.expectEqual(start, live_bytes);

    // `init` ran after `base` was set; `notification` reaches `_notification`.
    const q = try Instance(Node).init(&probe_desc);
    const probe: *Probe = @ptrCast(@alignCast(q.inst));
    try testing.expect(probe._inited);
    try testing.expectEqual(q.owner, probe.base);
    probe_desc.notification(q.inst, 13, 0);
    try testing.expectEqual(@as(i32, 13), probe._last_what);
    probe_desc.notification(q.inst, -4, 1);
    try testing.expectEqual(@as(i32, -4), probe._last_what);
    // A script without `_notification` ignores it.
    const pl = try Instance(Node).init(d);
    d.notification(pl.inst, 13, 0);
    pl.deinit(d);
    q.deinit(&probe_desc);
    try testing.expectEqual(start, live_bytes);
}

test "wrap create fails cleanly" {
    setup();
    const start = live_bytes;
    const owner = Node.init();
    defer godot.raw.objectDestroy(@ptrCast(owner));
    refuse_alloc = true;
    defer refuse_alloc = false;
    try testing.expect(probe_desc.create(@ptrCast(owner), test_gen) == null);
    try testing.expectEqual(@as(usize, 1), log_count);
    refuse_alloc = false;
    // A generation other than moduleInit's is refused, with one log line.
    try testing.expect(probe_desc.create(@ptrCast(owner), test_gen + 1) == null);
    try testing.expectEqual(@as(usize, 2), log_count);
    try testing.expectEqual(start, live_bytes);
}

test "wrap call" {
    setup();
    const d = &player_desc;
    const pl = try Instance(Node).init(d);
    defer pl.deinit(d);

    // take_damage(amount, critical): two arguments, void return.
    var amount = makeInt(10);
    defer destroy(&amount);
    var critical = makeBool(true);
    defer destroy(&critical);
    var c = callMethod(d, pl.inst, try methodIndex(d, "take_damage"), &.{ &amount, &critical });
    try expectCallOk(&c);
    try testing.expectEqual(t_nil, typeOf(&c.ret));
    destroy(&c.ret);
    var health = try getProp(d, pl.inst, "health");
    defer destroy(&health);
    try testing.expectEqual(@as(i64, 80), try readAs(i64, &health));

    // leap(height) on a `*const` self returns height * speed.
    var height = makeFloat(2);
    defer destroy(&height);
    var j = callMethod(d, pl.inst, try methodIndex(d, "leap"), &.{&height});
    defer destroy(&j.ret);
    try expectCallOk(&j);
    try testing.expectEqual(@as(f64, 600), try readAs(f64, &j.ret));

    // Probe: two arguments with a return value, a String argument, a
    // String return.
    const q = try Instance(Node).init(&probe_desc);
    defer q.deinit(&probe_desc);
    var a = makeInt(4);
    defer destroy(&a);
    var a2 = makeFloat(5);
    defer destroy(&a2);
    var sum = callMethod(&probe_desc, q.inst, try methodIndex(&probe_desc, "add"), &.{ &a, &a2 });
    defer destroy(&sum.ret);
    try expectCallOk(&sum);
    try testing.expectEqual(@as(i64, 10), try readAs(i64, &sum.ret));

    var text = try makeString("na\u{ef}ve");
    defer destroy(&text);
    var len = callMethod(&probe_desc, q.inst, try methodIndex(&probe_desc, "name_length"), &.{ &text, &a });
    defer destroy(&len.ret);
    try expectCallOk(&len);
    try testing.expectEqual(@as(i64, 9), try readAs(i64, &len.ret));

    var lab = callMethod(&probe_desc, q.inst, try methodIndex(&probe_desc, "label"), &.{});
    defer destroy(&lab.ret);
    try expectCallOk(&lab);
    try expectUtf8("probe", &lab.ret);
}

test "wrap call rejects bad args" {
    setup();
    const d = &player_desc;
    const pl = try Instance(Node).init(d);
    defer pl.deinit(d);
    const take = try methodIndex(d, "take_damage");
    var amount = makeInt(10);
    defer destroy(&amount);
    var flag = makeBool(false);
    defer destroy(&flag);
    var text = try makeString("no");
    defer destroy(&text);

    // An unknown method index.
    var c = callMethod(d, pl.inst, d.method_count, &.{});
    try testing.expectEqual(abi.call_invalid_method, c.err.@"error");
    try testing.expectEqual(t_nil, typeOf(&c.ret));
    destroy(&c.ret);
    c = callMethod(d, pl.inst, std.math.maxInt(u32), &.{});
    try testing.expectEqual(abi.call_invalid_method, c.err.@"error");
    destroy(&c.ret);

    // Too few, too many.
    c = callMethod(d, pl.inst, take, &.{&amount});
    try testing.expectEqual(abi.CallError{ .@"error" = abi.call_too_few_arguments, .argument = 0, .expected = 2 }, c.err);
    try testing.expectEqual(t_nil, typeOf(&c.ret));
    destroy(&c.ret);
    c = callMethod(d, pl.inst, take, &.{ &amount, &flag, &flag });
    try testing.expectEqual(abi.CallError{ .@"error" = abi.call_too_many_arguments, .argument = 0, .expected = 2 }, c.err);
    destroy(&c.ret);
    // A negative count from a confused host is too few, not a crash.
    var neg_err: abi.CallError = undefined;
    var neg_ret: Variant = undefined;
    d.call(pl.inst, take, @ptrCast(&[_]*const Variant{}), -1, &neg_ret, &neg_err);
    try testing.expectEqual(abi.call_too_few_arguments, neg_err.@"error");
    destroy(&neg_ret);

    // The wrong type at index 1: a String for `critical: bool`.
    c = callMethod(d, pl.inst, take, &.{ &amount, &text });
    try testing.expectEqual(abi.CallError{ .@"error" = abi.call_invalid_argument, .argument = 1, .expected = @intCast(t_bool) }, c.err);
    try testing.expectEqual(t_nil, typeOf(&c.ret));
    destroy(&c.ret);
    // Nothing ran: health is unchanged.
    var health = try getProp(d, pl.inst, "health");
    defer destroy(&health);
    try testing.expectEqual(@as(i64, 100), try readAs(i64, &health));

    // A String argument read before a failure at index 1 is released (the
    // leak checks of the clean-exit run would see it otherwise).
    const q = try Instance(Node).init(&probe_desc);
    defer q.deinit(&probe_desc);
    c = callMethod(&probe_desc, q.inst, try methodIndex(&probe_desc, "name_length"), &.{ &text, &text });
    try testing.expectEqual(abi.CallError{ .@"error" = abi.call_invalid_argument, .argument = 1, .expected = @intCast(t_int) }, c.err);
    destroy(&c.ret);
}

test "wrap get and set" {
    setup();
    const d = &player_desc;
    const pl = try Instance(Node).init(d);
    defer pl.deinit(d);
    const p: *player = @ptrCast(@alignCast(pl.inst));

    var speed = makeFloat(12.5);
    defer destroy(&speed);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "speed", &speed));
    var got = try getProp(d, pl.inst, "speed");
    try testing.expectEqual(@as(f64, 12.5), try readAs(f64, &got));
    destroy(&got);

    var health = makeInt(-7);
    defer destroy(&health);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "health", &health));
    got = try getProp(d, pl.inst, "health");
    try testing.expectEqual(@as(i64, -7), try readAs(i64, &got));
    destroy(&got);

    var mood = makeInt(1);
    defer destroy(&mood);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "mood", &mood));
    try testing.expectEqual(player.Mood.angry, p.mood);

    var spawn = make(5, b.Vector2{ .x = -3, .y = 4.5 });
    defer destroy(&spawn);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "spawn_point", &spawn));
    got = try getProp(d, pl.inst, "spawn_point");
    const sp = try readAs(b.Vector2, &got);
    try testing.expectEqual(@as(f32, -3), sp.x);
    try testing.expectEqual(@as(f32, 4.5), sp.y);
    destroy(&got);

    // A String set twice: the first value is released by the second set.
    var t1 = try makeString("first");
    defer destroy(&t1);
    var t2 = try makeString("second \u{2728}");
    defer destroy(&t2);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "title", &t1));
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "title", &t2));
    got = try getProp(d, pl.inst, "title");
    try expectUtf8("second \u{2728}", &got);
    destroy(&got);

    const node = Node.init();
    defer godot.raw.objectDestroy(@ptrCast(node));
    var nv = makeObject(node);
    defer destroy(&nv);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "target", &nv));
    try testing.expectEqual(node, p.target.get().?);
    got = try getProp(d, pl.inst, "target");
    try testing.expectEqual(idOf(node), godot.raw.variantGetObjectInstanceId.?(&got));
    destroy(&got);

    // A failed read leaves the field as it was.
    try testing.expectEqual(@as(u8, 0), try setProp(d, pl.inst, "speed", &t1));
    try testing.expectEqual(@as(f32, 12.5), p.speed);
    try testing.expectEqual(@as(u8, 0), try setProp(d, pl.inst, "title", &speed));
    got = try getProp(d, pl.inst, "title");
    try expectUtf8("second \u{2728}", &got);
    destroy(&got);
    // A group entry and an out-of-range index take nothing.
    try testing.expectEqual(@as(u8, 0), d.set(pl.inst, 0, &speed));
    try testing.expectEqual(@as(u8, 0), d.set(pl.inst, d.property_count, &speed));
    try testing.expectEqual(@as(f32, 12.5), p.speed);

    // `get_level` / `set_level` replace direct access.
    const q = try Instance(Node).init(&probe_desc);
    defer q.deinit(&probe_desc);
    const probe: *Probe = @ptrCast(@alignCast(q.inst));
    var three = makeInt(3);
    defer destroy(&three);
    try testing.expectEqual(@as(u8, 1), try setProp(&probe_desc, q.inst, "level", &three));
    try testing.expectEqual(@as(i32, 30), probe.level);
    got = try getProp(&probe_desc, q.inst, "level");
    try testing.expectEqual(@as(i64, 31), try readAs(i64, &got));
    destroy(&got);
    // The setter does not run on a failed read.
    try testing.expectEqual(@as(u8, 0), try setProp(&probe_desc, q.inst, "level", &t1));
    try testing.expectEqual(@as(i32, 30), probe.level);

    // A Ref field: a failed read (a Node for a Resource) keeps the old
    // Resource and its reference count.
    const res = Resource.init();
    defer dropCreation(res);
    var rv = makeObject(res);
    defer destroy(&rv);
    try testing.expectEqual(@as(u8, 1), try setProp(&probe_desc, q.inst, "item", &rv));
    const held = refCount(res);
    try testing.expectEqual(@as(u8, 0), try setProp(&probe_desc, q.inst, "item", &nv));
    try testing.expectEqual(res, probe.item.get().?);
    try testing.expectEqual(held, refCount(res));
    // Setting the same Resource again keeps one reference for the field.
    try testing.expectEqual(@as(u8, 1), try setProp(&probe_desc, q.inst, "item", &rv));
    try testing.expectEqual(held, refCount(res));
    // NIL clears it and drops the field's reference.
    var nil: Variant = undefined;
    godot.raw.variantNewNil(&nil);
    try testing.expectEqual(@as(u8, 1), try setProp(&probe_desc, q.inst, "item", &nil));
    try testing.expect(probe.item.get() == null);
    try testing.expectEqual(held - 1, refCount(res));
}

test "wrap destroy releases" {
    setup();
    const start = live_bytes;
    const q = try Instance(Node).init(&probe_desc);
    const probe: *Probe = @ptrCast(@alignCast(q.inst));

    // After this block only the instance holds the Resource.
    const res = Resource.init();
    const res_id = idOf(res);
    {
        var rv = makeObject(res);
        defer destroy(&rv);
        try testing.expectEqual(@as(u8, 1), try setProp(&probe_desc, q.inst, "item", &rv));
        dropCreation(res);
    }
    try testing.expect(alive(res_id));
    var text = try makeString("kept by the instance");
    try testing.expectEqual(@as(u8, 1), try setProp(&probe_desc, q.inst, "name", &text));
    destroy(&text);
    // A private StringName field is released too.
    probe._tag = b.StringName.fromUtf8("ziggurat_wrap_probe_tag");

    deinit_saw_item = false;
    q.deinit(&probe_desc);
    try testing.expect(deinit_saw_item);
    try testing.expect(!alive(res_id));
    try testing.expectEqual(start, live_bytes);
}

test "wrap get_default" {
    setup();
    const d = &player_desc;
    var v: Variant = undefined;
    try testing.expectEqual(@as(u8, 1), d.get_default(try propertyIndex(d, "speed"), &v));
    try testing.expectEqual(@as(f64, 300), try readAs(f64, &v));
    destroy(&v);
    try testing.expectEqual(@as(u8, 1), d.get_default(try propertyIndex(d, "mood"), &v));
    try testing.expectEqual(@as(i64, 0), try readAs(i64, &v));
    destroy(&v);
    try testing.expectEqual(@as(u8, 1), d.get_default(try propertyIndex(d, "title"), &v));
    try expectUtf8("", &v);
    destroy(&v);
    try testing.expectEqual(@as(u8, 1), d.get_default(try propertyIndex(d, "target"), &v));
    try testing.expectEqual(t_nil, typeOf(&v));
    destroy(&v);

    // A changed instance does not change the default.
    const pl = try Instance(Node).init(d);
    defer pl.deinit(d);
    var speed = makeFloat(1);
    defer destroy(&speed);
    try testing.expectEqual(@as(u8, 1), try setProp(d, pl.inst, "speed", &speed));
    try testing.expectEqual(@as(u8, 1), d.get_default(try propertyIndex(d, "speed"), &v));
    try testing.expectEqual(@as(f64, 300), try readAs(f64, &v));
    destroy(&v);

    // Group entries and indexes past the end have no default.
    try testing.expectEqual(@as(u8, 0), d.get_default(0, &v));
    try testing.expectEqual(@as(u8, 0), d.get_default(d.property_count, &v));
    // A setter override does not affect the default either.
    try testing.expectEqual(@as(u8, 1), probe_desc.get_default(try propertyIndex(&probe_desc, "level"), &v));
    try testing.expectEqual(@as(i64, 1), try readAs(i64, &v));
    destroy(&v);
}
