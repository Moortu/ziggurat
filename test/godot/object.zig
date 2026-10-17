//! Object handle tests, run inside headless Godot (see `convert.zig`, which
//! pulls this file into the test root). Source Variants are built with
//! Godot's own constructors, not with the code under test.
const std = @import("std");
const testing = std.testing;
const ziggurat = @import("ziggurat");
const godot = @import("gdzig");
const convert = ziggurat.convert;
const object = ziggurat.object;
const Obj = ziggurat.Obj;
const Ref = ziggurat.Ref;
const Variant = godot.builtin.Variant;
const Node = godot.class.Node;
const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const Resource = godot.class.Resource;

const t_nil: u32 = 0;
const t_int: u32 = 2;
const t_object: u32 = 24;

const Ctor = *const fn (*anyopaque, *anyopaque) callconv(.c) void;

fn typeOf(v: *const Variant) u32 {
    return @intCast(godot.raw.variantGetType(v));
}

fn destroyVariant(v: *Variant) void {
    godot.raw.variantDestroy(v);
}

/// An OBJECT Variant for `o`, through Godot's own constructor (which adds
/// the Variant's reference to a RefCounted).
fn makeObject(o: anytype) Variant {
    var p: ?*anyopaque = @ptrCast(o);
    var v: Variant = undefined;
    const ctor: Ctor = @ptrCast(godot.raw.getVariantFromTypeConstructor(t_object).?);
    ctor(&v, @ptrCast(&p));
    return v;
}

fn makeInt(x: i64) Variant {
    var in = x;
    var v: Variant = undefined;
    const ctor: Ctor = @ptrCast(godot.raw.getVariantFromTypeConstructor(t_int).?);
    ctor(&v, @ptrCast(&in));
    return v;
}

fn makeNil() Variant {
    var v: Variant = undefined;
    godot.raw.variantNewNil(&v);
    return v;
}

fn idOf(o: anytype) u64 {
    return godot.raw.objectGetInstanceId(@ptrCast(o));
}

fn alive(id: u64) bool {
    return godot.raw.objectGetInstanceFromId(id) != null;
}

/// Frees a non-RefCounted object.
fn free(o: anytype) void {
    godot.raw.objectDestroy(@ptrCast(o));
}

fn refCount(rc: *RefCounted) i32 {
    return rc.getReferenceCount();
}

/// Drops a creation reference, freeing the object when it was the last.
fn dropCreation(rc: *RefCounted) void {
    if (rc.unreference()) godot.raw.objectDestroy(@ptrCast(rc));
}

fn expectRejected(comptime T: type, v: *const Variant) !void {
    var out: T = undefined;
    const err = convert.read(T, v, &out) orelse return error.ExpectedRejection;
    try testing.expectEqual(t_object, err.expected);
}

test "object supported types" {
    try testing.expect(convert.supported(?*Node));
    try testing.expect(convert.supported(Obj(Node)));
    try testing.expect(convert.supported(Ref(Resource)));
    try testing.expect(!convert.supported(*Node));
    try testing.expect(!convert.supported(?*const Node));
    try testing.expect(!convert.supported(?*u8));
    try testing.expectEqual(t_object, convert.variantType(?*Node));
    try testing.expectEqual(t_object, convert.variantType(Ref(Resource)));
}

test "engine class names" {
    try testing.expectEqualStrings("Node", object.engineClassName(Node));
    try testing.expectEqualStrings("RefCounted", object.engineClassName(RefCounted));
    try testing.expectEqualStrings("Node3D", object.engineClassName(godot.class.Node3d));
    try testing.expectEqualStrings("Object", object.engineClassName(Object));
    try testing.expect(!object.isEngineClass(u32));
    try testing.expect(!object.isEngineClass(godot.builtin.String));
}

/// Names of classes that exist only in an editor build or on another
/// platform (Android Java bridge, web bridge, the GDScript language server).
fn notInRuntime(name: []const u8) bool {
    const prefixes = [_][]const u8{
        "Editor",                   "ResourceImporter",          "OpenXRBindingModifierEditor", "OpenXRInteractionProfileEditor",
        "FileSystemDock",           "ScriptCreateDialog",        "ScriptEditor",                "GridMapEditorPlugin",
        "GDScriptLanguageProtocol", "GDScriptSyntaxHighlighter", "GDScriptTextDocument",        "GDScriptWorkspace",
        "Java",                     "JNISingleton",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// Every engine class type in `godot.class`.
fn engineClasses() []const type {
    comptime {
        @setEvalBranchQuota(50_000_000);
        var list: []const type = &.{};
        for (@typeInfo(godot.class).@"struct".decl_names) |name| {
            const decl = @field(godot.class, name);
            if (@TypeOf(decl) == type and object.isEngineClass(decl)) list = list ++ &[_]type{decl};
        }
        return list;
    }
}

// Every engine class gdzig has: the derived name must be a class Godot
// knows, or `Obj(T)` of that class could never match.
test "engine class names exist in Godot" {
    var checked: usize = 0;
    var bad: usize = 0;
    inline for (comptime engineClasses()) |T| {
        const name = comptime object.engineClassName(T);
        var sn = godot.builtin.StringName.fromLatin1(name, false);
        defer sn.deinit();
        // Editor-only and other-platform classes are not registered in the
        // headless game runtime these tests run in.
        if (comptime notInRuntime(name)) continue;
        checked += 1;
        if (!godot.class.ClassDb.classExists(sn)) {
            bad += 1;
            // A few lines only: a full pipe would stall Godot.
            if (bad <= 60) std.debug.print("engine class name not known to Godot: {s} (type {s})\n", .{ name, @typeName(T) });
        }
    }
    try testing.expect(checked > 800);
    if (bad != 0) std.debug.print("{d} of {d} engine class names are not known to Godot\n", .{ bad, checked });
    try testing.expectEqual(@as(usize, 0), bad);
}

// `ziggurat.godot`: every engine class under its Godot name (and nothing
// under a gdzig spelling), the builtin value types and global enums, and
// none of the withheld gdzig parts.
test "curated godot surface" {
    const g = ziggurat.godot;
    comptime {
        @setEvalBranchQuota(50_000_000);
        var classes: usize = 0;
        var others: usize = 0;
        for (@typeInfo(g).@"struct".decl_names) |name| {
            const T = @field(g, name);
            if (@TypeOf(T) != type) @compileError("ziggurat.godot." ++ name ++ " is not a type");
            if (object.isEngineClass(T)) {
                if (!std.mem.eql(u8, object.engineClassName(T), name))
                    @compileError("ziggurat.godot." ++ name ++ " is not named as Godot names it");
                classes += 1;
            } else others += 1;
        }
        // 1036 engine classes in 4.7.2, minus ClassDB, GDExtension and GDExtensionManager.
        if (classes != 1033) @compileError(std.fmt.comptimePrint("ziggurat.godot has {d} engine classes", .{classes}));
        // 34 builtin value types and 20 global enums.
        if (others != 54) @compileError(std.fmt.comptimePrint("ziggurat.godot has {d} other types", .{others}));
        for ([_][]const u8{ "ClassDB", "ClassDb", "GDExtension", "GDExtensionManager", "Variant", "Registry", "class", "builtin", "global", "extension", "raw", "c", "heap", "testing" }) |name| {
            if (@hasDecl(g, name)) @compileError("ziggurat.godot must not declare " ++ name);
        }
    }
    try testing.expect(g.CharacterBody2D == godot.class.CharacterBody2d);
    try testing.expect(g.AESContext == godot.class.AesContext);
    try testing.expect(g.Node == Node);
    try testing.expect(g.Transform2D == godot.builtin.Transform2d);
    try testing.expect(g.RID == godot.builtin.Rid);
    try testing.expect(g.MIDIMessage == godot.global.MidiMessage);
}

test "object round trips" {
    const node = Node.init();
    defer free(node);

    // Node into ?*Node and Obj(Node), also into a base class.
    var v = makeObject(node);
    defer destroyVariant(&v);
    var p: ?*Node = null;
    try testing.expect(convert.read(?*Node, &v, &p) == null);
    try testing.expectEqual(node, p.?);
    var o: ?*Object = null;
    try testing.expect(convert.read(?*Object, &v, &o) == null);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(node)), @as(*anyopaque, @ptrCast(o.?)));
    var h: Obj(Node) = .{};
    try testing.expect(convert.read(Obj(Node), &v, &h) == null);
    try testing.expectEqual(idOf(node), h.id);
    try testing.expectEqual(node, h.get().?);

    // Writing gives an OBJECT Variant for the same object.
    var w: Variant = undefined;
    convert.write(Obj(Node), &h, &w);
    defer destroyVariant(&w);
    try testing.expectEqual(t_object, typeOf(&w));
    try testing.expectEqual(idOf(node), godot.raw.variantGetObjectInstanceId.?(&w));
    var wp: Variant = undefined;
    const maybe: ?*Node = node;
    convert.write(?*Node, &maybe, &wp);
    defer destroyVariant(&wp);
    try testing.expectEqual(idOf(node), godot.raw.variantGetObjectInstanceId.?(&wp));

    // Null: NIL reads as null, null writes as NIL.
    var nil = makeNil();
    defer destroyVariant(&nil);
    var np: ?*Node = node;
    try testing.expect(convert.read(?*Node, &nil, &np) == null);
    try testing.expect(np == null);
    var nh: Obj(Node) = .{ .id = 7 };
    try testing.expect(convert.read(Obj(Node), &nil, &nh) == null);
    try testing.expectEqual(@as(u64, 0), nh.id);
    try testing.expect(nh.get() == null);
    var nw: Variant = undefined;
    const none: ?*Node = null;
    convert.write(?*Node, &none, &nw);
    defer destroyVariant(&nw);
    try testing.expectEqual(t_nil, typeOf(&nw));

    // A Resource into Ref(Resource); the Ref and the Variant each hold one.
    const res = Resource.init();
    defer dropCreation(RefCounted.upcast(res));
    const start = refCount(RefCounted.upcast(res));
    var rv = makeObject(res);
    try testing.expectEqual(start + 1, refCount(RefCounted.upcast(res)));
    var r: Ref(Resource) = .{};
    try testing.expect(convert.read(Ref(Resource), &rv, &r) == null);
    try testing.expectEqual(res, r.get().?);
    try testing.expectEqual(start + 2, refCount(RefCounted.upcast(res)));
    destroyVariant(&rv);
    try testing.expectEqual(start + 1, refCount(RefCounted.upcast(res)));
    r.release();
    try testing.expectEqual(start, refCount(RefCounted.upcast(res)));
    // A Resource is also a ?*Resource and a ?*RefCounted.
    var rv2 = makeObject(res);
    defer destroyVariant(&rv2);
    var rp: ?*RefCounted = null;
    try testing.expect(convert.read(?*RefCounted, &rv2, &rp) == null);
    try testing.expectEqual(@as(*anyopaque, @ptrCast(res)), @as(*anyopaque, @ptrCast(rp.?)));
}

test "object rejects" {
    // A Resource Variant into ?*Node, Obj(Node).
    const res = Resource.init();
    defer dropCreation(RefCounted.upcast(res));
    var rv = makeObject(res);
    defer destroyVariant(&rv);
    try expectRejected(?*Node, &rv);
    try expectRejected(Obj(Node), &rv);
    // A Node Variant into Ref(Resource) (a Node is not a Resource).
    const keep = Node.init();
    defer free(keep);
    var kv = makeObject(keep);
    defer destroyVariant(&kv);
    try expectRejected(Ref(Resource), &kv);
    // A failed read leaves the output alone.
    var p: ?*Node = keep;
    _ = convert.read(?*Node, &rv, &p);
    try testing.expectEqual(keep, p.?);
    var r: Ref(Resource) = .{};
    _ = convert.read(Ref(Resource), &kv, &r);
    try testing.expect(r.ptr == null);

    // A freed Node's Variant: the id no longer resolves.
    const gone = Node.init();
    const gone_id = idOf(gone);
    var gv = makeObject(gone);
    defer destroyVariant(&gv);
    var h: Obj(Node) = .{};
    h.set(gone);
    try testing.expectEqual(gone, h.get().?);
    free(gone);
    try testing.expect(!alive(gone_id));
    try testing.expect(h.get() == null);
    try expectRejected(Obj(Node), &gv);
    try expectRejected(?*Node, &gv);
    try expectRejected(?*Object, &gv);

    // An INT, a non-object.
    var iv = makeInt(5);
    defer destroyVariant(&iv);
    try expectRejected(?*Node, &iv);
    try expectRejected(Obj(Node), &iv);
    try expectRejected(Ref(Resource), &iv);
}

test "obj class check" {
    const node = Node.init();
    defer free(node);
    const res = Resource.init();
    defer dropCreation(RefCounted.upcast(res));
    // Same id, different class: get() is null for the wrong class.
    const as_node: Obj(Node) = .{ .id = idOf(res) };
    try testing.expect(as_node.get() == null);
    const as_res: Obj(Resource) = .{ .id = idOf(res) };
    try testing.expectEqual(res, as_res.get().?);
    const as_obj: Obj(Object) = .{ .id = idOf(node) };
    try testing.expect(as_obj.get() != null);
    const none: Obj(Node) = .{};
    try testing.expect(none.get() == null);
    const bogus: Obj(Node) = .{ .id = 0xdead_beef_0000 };
    try testing.expect(bogus.get() == null);
}

test "ref counts" {
    const a = RefCounted.init();
    const a_id = idOf(a);
    const start = refCount(a);

    var h: Ref(RefCounted) = .{};
    h.set(a);
    try testing.expectEqual(start + 1, refCount(a));
    // Setting the same object again changes nothing.
    h.set(a);
    try testing.expectEqual(start + 1, refCount(a));

    // Writing adds the Variant's own reference; destroying it drops it.
    var v: Variant = undefined;
    convert.write(Ref(RefCounted), &h, &v);
    try testing.expectEqual(t_object, typeOf(&v));
    try testing.expectEqual(start + 2, refCount(a));
    destroyVariant(&v);
    try testing.expectEqual(start + 1, refCount(a));

    h.release();
    try testing.expect(h.get() == null);
    try testing.expectEqual(start, refCount(a));
    try testing.expect(alive(a_id));
    // A second release is harmless.
    h.release();
    try testing.expectEqual(start, refCount(a));

    // A second `set` drops the first object.
    const b = RefCounted.init();
    const b_id = idOf(b);
    h.set(a);
    h.set(b);
    try testing.expectEqual(start, refCount(a));
    try testing.expectEqual(start + 1, refCount(b));
    h.release();
    try testing.expectEqual(start, refCount(b));

    // The creator's reference goes last: each object is freed exactly once.
    dropCreation(a);
    try testing.expect(!alive(a_id));
    dropCreation(b);
    try testing.expect(!alive(b_id));
}

test "ref release frees the last reference" {
    const c = RefCounted.init();
    const c_id = idOf(c);
    var h: Ref(RefCounted) = .{};
    h.set(c);
    // The creator hands its reference over: the Ref now owns the object.
    try testing.expect(!c.unreference());
    try testing.expect(alive(c_id));
    h.release();
    try testing.expect(!alive(c_id));
    try testing.expect(h.get() == null);

    // The same through a second set.
    const d = RefCounted.init();
    const e = RefCounted.init();
    const d_id = idOf(d);
    const e_id = idOf(e);
    h.set(d);
    try testing.expect(!d.unreference());
    h.set(e);
    try testing.expect(!alive(d_id));
    try testing.expect(!e.unreference());
    try testing.expect(alive(e_id));
    h.set(null);
    try testing.expect(!alive(e_id));
}

test "typed null object Variant" {
    // An OBJECT Variant built from a null pointer: type OBJECT, id 0.
    var v = makeObject(@as(?*anyopaque, null));
    defer destroyVariant(&v);
    var p: ?*Node = null;
    const keep = Node.init();
    defer free(keep);
    p = keep;
    try testing.expect(convert.read(?*Node, &v, &p) == null);
    try testing.expect(p == null);
    var h: Obj(Node) = .{ .id = 9 };
    try testing.expect(convert.read(Obj(Node), &v, &h) == null);
    try testing.expectEqual(@as(u64, 0), h.id);
    var r: Ref(Resource) = .{};
    try testing.expect(convert.read(Ref(Resource), &v, &r) == null);
    try testing.expect(r.ptr == null);
}

test "ref read of a freed id" {
    const res = Resource.init();
    const id = idOf(res);
    var v = makeObject(res);
    // Free the object by hand while the Variant still holds its id (and a
    // reference). The Variant is never destroyed: its destructor would
    // unreference freed memory. An OBJECT Variant owns no other heap memory.
    godot.raw.objectDestroy(@ptrCast(res));
    try testing.expect(!alive(id));
    try expectRejected(Ref(Resource), &v);
    var r: Ref(Resource) = .{};
    _ = convert.read(Ref(Resource), &v, &r);
    try testing.expect(r.ptr == null);
}

test "write a null Ref" {
    const r: Ref(Resource) = .{};
    var v: Variant = undefined;
    convert.write(Ref(Resource), &r, &v);
    defer destroyVariant(&v);
    try testing.expectEqual(t_nil, typeOf(&v));
}
