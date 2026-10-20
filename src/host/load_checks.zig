//! Load checks the SDK cannot make, because they need the engine's class
//! data (Stage 3 plan, "Host-side load checks"). They run on the main thread
//! after a generation is loaded and report, per script:
//! - a property or method whose Godot name already exists in the script's
//!   `extends` class or an ancestor: the script's member would hide the
//!   engine's (Godot looks a name up in the script first);
//! - an object field whose class is a Node, in a script whose `extends` is
//!   not a Node: such an object owns no scene tree, so the field could only
//!   hold a node nothing frees with the tree.
//! Each finding is one sentence (`propertyHides`, `methodHides`,
//! `nodeField`) for the script's diagnostics, without a line. Virtual
//! methods (`_ready`, `_process`, ...) override the engine on purpose and
//! are not checked. Only exported fields are described with their type, so
//! only those are checked for Node types.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const ClassDb = godot.class.ClassDb;

/// Godot's `Variant::OBJECT`.
const variant_object: u32 = 24;
/// `PROPERTY_HINT_NODE_TYPE`, which the SDK gives `z.Obj(T)` of a Node class.
const hint_node_type: u32 = 34;
/// `PROPERTY_USAGE_GROUP`, `_CATEGORY` and `_SUBGROUP`: label entries.
const usage_label: u32 = 64 | 128 | 256;

/// One finding: the script's index in the table and the sentence (owned).
pub const Finding = struct {
    script: u32,
    message: []u8,
};

pub fn freeFindings(a: Allocator, list: []Finding) void {
    for (list) |f| a.free(f.message);
    a.free(list);
}

/// `Property '<p>' of <script> hides <Class>.<p>; ...`. `script` is the
/// script's `res://` path.
pub fn propertyHides(a: Allocator, script: []const u8, name: []const u8, class: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "Property '{s}' of {s} hides {s}.{s}; rename it or give it a name override in meta.", .{ name, script, class, name });
}

/// `Method '<m>' of <script> hides <Class>.<m>; ...`.
pub fn methodHides(a: Allocator, script: []const u8, name: []const u8, class: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "Method '{s}' of {s} hides {s}.{s}; rename it or give it a name override in meta.", .{ name, script, class, name });
}

/// `<script> extends <Class>, which is not a Node, so field '<f>' ...`.
pub fn nodeField(a: Allocator, script: []const u8, extends: []const u8, field: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, "{s} extends {s}, which is not a Node, so field '{s}' cannot hold a Node.", .{ script, extends, field });
}

/// Runs every check on every script of `gen`. Main thread (ClassDB).
/// The findings are allocated with `a`; free them with `freeFindings`.
pub fn run(a: Allocator, gen: *const runtime.Generation) Allocator.Error![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |f| a.free(f.message);
        out.deinit(a);
    }
    for (gen.scripts(), 0..) |*desc, i| try checkScript(a, @intCast(i), desc, &out);
    return out.toOwnedSlice(a);
}

fn str(s: abi.Str) []const u8 {
    if (s.len == 0) return "";
    return (s.ptr orelse return "")[0..s.len];
}

fn checkScript(a: Allocator, index: u32, desc: *const abi.ScriptDesc, out: *std.ArrayList(Finding)) Allocator.Error!void {
    const base = str(desc.base_class);
    var base_sn = StringName.fromUtf8(base);
    defer base_sn.deinit();
    // An unknown class was refused by the module; nothing to compare with.
    if (base.len == 0 or !ClassDb.classExists(base_sn)) return;

    const script = try std.fmt.allocPrint(a, "res://{s}", .{str(desc.path)});
    defer a.free(script);

    var chain = try Chain.init(a, base);
    defer chain.deinit();

    const base_is_node = isNode(base);
    for (desc.properties[0..desc.property_count]) |p| {
        if (p.field_index == abi.no_field) continue;
        const name = str(p.name);
        if (chain.propertyOwner(name)) |class| {
            try out.append(a, .{ .script = index, .message = try propertyHides(a, script, name, class) });
        }
        if (!base_is_node and p.variant_type == variant_object and holdsNode(p)) {
            try out.append(a, .{ .script = index, .message = try nodeField(a, script, base, name) });
        }
    }
    for (desc.methods[0..desc.method_count]) |m| {
        if (m.flags & abi.method_flag_virtual != 0) continue;
        const name = str(m.name);
        if (chain.methodOwner(name)) |class| {
            try out.append(a, .{ .script = index, .message = try methodHides(a, script, name, class) });
        }
    }
}

/// True when the object property `p` is typed with a Node class: the SDK's
/// node hint, or a class name that is Node or derives from it.
fn holdsNode(p: abi.PropertyDesc) bool {
    if (p.hint == hint_node_type) return true;
    const class = str(p.class_name);
    return class.len != 0 and isNode(class);
}

fn isNode(class: []const u8) bool {
    var sn = StringName.fromUtf8(class);
    defer sn.deinit();
    // True for Node itself too (`ClassDB::is_parent_class` starts with the
    // class it is given).
    return ClassDb.isParentClass(sn, .fromComptimeLatin1("Node"));
}

/// A class and its ancestors, with each one's own property names, read
/// once per script.
const Chain = struct {
    a: Allocator,
    /// Class names, the `extends` class first. Owned.
    classes: std.ArrayList([]u8) = .empty,
    /// Property name -> index into `classes` of the class that declares it
    /// (the nearest one). Keys owned.
    props: std.StringHashMapUnmanaged(u32) = .empty,

    fn init(a: Allocator, base: []const u8) Allocator.Error!Chain {
        var c: Chain = .{ .a = a };
        errdefer c.deinit();
        var class = try a.dupe(u8, base);
        // Godot's deepest classes are about ten levels; the cap only guards
        // against a cycle.
        var depth: usize = 0;
        while (class.len != 0 and depth < 64) : (depth += 1) {
            c.classes.append(a, class) catch |err| {
                a.free(class);
                return err;
            };
            const at: u32 = @intCast(c.classes.items.len - 1);
            var sn = StringName.fromUtf8(class);
            defer sn.deinit();
            try c.addOwnProperties(sn, at);
            var parent = ClassDb.getParentClass(sn);
            defer parent.deinit();
            class = try nameAlloc(a, parent);
        }
        // The last name read was never added (empty, or past the cap).
        a.free(class);
        return c;
    }

    fn deinit(c: *Chain) void {
        var it = c.props.keyIterator();
        while (it.next()) |k| c.a.free(k.*);
        c.props.deinit(c.a);
        for (c.classes.items) |s| c.a.free(s);
        c.classes.deinit(c.a);
    }

    fn addOwnProperties(c: *Chain, class: StringName, at: u32) Allocator.Error!void {
        var list = ClassDb.classGetPropertyList(class, .{ .no_inheritance = true });
        defer list.deinit();
        var name_key = String.fromLatin1("name");
        defer name_key.deinit();
        var usage_key = String.fromLatin1("usage");
        defer usage_key.deinit();
        const nk = Variant.init(String, name_key);
        defer nk.deinit();
        const uk = Variant.init(String, usage_key);
        defer uk.deinit();
        var i: i64 = 0;
        while (i < list.size()) : (i += 1) {
            const entry = list.get(i);
            defer entry.deinit();
            var d = entry.as(Dictionary) orelse continue;
            defer d.deinit();
            const usage = d.get(uk, .{});
            defer usage.deinit();
            if (@as(u32, @truncate(@as(u64, @bitCast(usage.as(i64) orelse 0)))) & usage_label != 0) continue;
            const name = d.get(nk, .{});
            defer name.deinit();
            var s = name.as(String) orelse continue;
            defer s.deinit();
            const text = try stringAlloc(c.a, &s);
            const gop = c.props.getOrPut(c.a, text) catch |err| {
                c.a.free(text);
                return err;
            };
            // The nearest class wins: classes are added base first.
            if (gop.found_existing) c.a.free(text) else gop.value_ptr.* = at;
        }
    }

    fn propertyOwner(c: *const Chain, name: []const u8) ?[]const u8 {
        const at = c.props.get(name) orelse return null;
        return c.classes.items[at];
    }

    fn methodOwner(c: *const Chain, name: []const u8) ?[]const u8 {
        var sn = StringName.fromUtf8(name);
        defer sn.deinit();
        for (c.classes.items) |class| {
            var csn = StringName.fromUtf8(class);
            defer csn.deinit();
            if (ClassDb.classHasMethod(csn, sn, .{ .no_inheritance = true })) return class;
        }
        return null;
    }
};

fn stringAlloc(a: Allocator, s: *const String) Allocator.Error![]u8 {
    const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(s.constPtr(), null, 0)));
    const buf = try a.alloc(u8, n);
    if (n != 0) _ = godot.raw.stringToUtf8Chars(s.constPtr(), buf.ptr, @intCast(n));
    return buf;
}

fn nameAlloc(a: Allocator, sn: StringName) Allocator.Error![]u8 {
    var s = String.fromStringName(sn);
    defer s.deinit();
    return stringAlloc(a, &s);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "finding sentences" {
    const a = testing.allocator;
    const p = try propertyHides(a, "res://named.zig", "name", "Node");
    defer a.free(p);
    try testing.expectEqualStrings("Property 'name' of res://named.zig hides Node.name; rename it or give it a name override in meta.", p);
    const m = try methodHides(a, "res://named.zig", "get_name", "Node");
    defer a.free(m);
    try testing.expectEqualStrings("Method 'get_name' of res://named.zig hides Node.get_name; rename it or give it a name override in meta.", m);
    const f = try nodeField(a, "res://holder.zig", "Resource", "target");
    defer a.free(f);
    try testing.expectEqualStrings("res://holder.zig extends Resource, which is not a Node, so field 'target' cannot hold a Node.", f);
}
