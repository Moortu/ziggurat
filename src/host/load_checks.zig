//! Load checks the SDK cannot make, because they need the engine's class
//! data (Stage 3 plan, "Host-side load checks"). They run on the main thread
//! after a generation is loaded and report, per script:
//! - a property, method or signal whose Godot name already exists in the
//!   script's `extends` class or an ancestor as a property, method or
//!   signal: the script's member would hide the engine's (Godot looks a
//!   name up in the script first, and the script instance answers a signal
//!   or method name with a `Signal` or `Callable`, as GDScript does);
//! - an object field whose class is a Node, in a script whose `extends` is
//!   not a Node: such an object owns no scene tree, so the field could only
//!   hold a node nothing frees with the tree.
//! Each finding is one sentence (`hides`, `nodeField`) for the script's
//! diagnostics, without a line. Virtual
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

/// The kind of a script or engine member.
pub const Kind = enum {
    property,
    method,
    signal,

    fn title(k: Kind) []const u8 {
        return switch (k) {
            .property => "Property",
            .method => "Method",
            .signal => "Signal",
        };
    }
};

/// `<Kind> '<n>' of <script> hides <Class>.<n>; ...` when both members are
/// of one kind, else `... hides <engine kind> <Class>.<n>; ...` (for
/// example `Method 'draw' of res://a.zig hides signal Node2D.draw; ...`).
/// `script` is the script's `res://` path.
pub fn hides(a: Allocator, script: []const u8, kind: Kind, name: []const u8, engine_kind: Kind, class: []const u8) Allocator.Error![]u8 {
    const sep = if (kind == engine_kind) "" else " ";
    const word = if (kind == engine_kind) "" else @tagName(engine_kind);
    return std.fmt.allocPrint(a, "{s} '{s}' of {s} hides {s}{s}{s}.{s}; rename it or give it a name override in meta.", .{ kind.title(), name, script, word, sep, class, name });
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
        try checkName(a, index, script, &chain, .property, name, out);
        if (!base_is_node and p.variant_type == variant_object and holdsNode(p)) {
            try out.append(a, .{ .script = index, .message = try nodeField(a, script, base, name) });
        }
    }
    for (desc.methods[0..desc.method_count]) |m| {
        if (m.flags & abi.method_flag_virtual != 0) continue;
        try checkName(a, index, script, &chain, .method, str(m.name), out);
    }
    for (desc.signals[0..desc.signal_count]) |sig| {
        try checkName(a, index, script, &chain, .signal, str(sig.name), out);
    }
}

/// One finding per engine member kind that already has `name`.
fn checkName(a: Allocator, index: u32, script: []const u8, chain: *const Chain, kind: Kind, name: []const u8, out: *std.ArrayList(Finding)) Allocator.Error!void {
    inline for (.{ Kind.property, Kind.method, Kind.signal }) |engine_kind| {
        const owner = switch (engine_kind) {
            .property => chain.propertyOwner(name),
            .method => chain.methodOwner(name),
            .signal => chain.signalOwner(name),
        };
        if (owner) |class| {
            try out.append(a, .{ .script = index, .message = try hides(a, script, kind, name, engine_kind, class) });
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

/// A class and its ancestors, with each one's own property and signal
/// names, read once per script.
const Chain = struct {
    a: Allocator,
    /// Class names, the `extends` class first. Owned.
    classes: std.ArrayList([]u8) = .empty,
    /// Property name -> index into `classes` of the class that declares it
    /// (the nearest one). Keys owned.
    props: std.StringHashMapUnmanaged(u32) = .empty,
    /// Signal name -> index into `classes`, as `props`. Keys owned.
    signals: std.StringHashMapUnmanaged(u32) = .empty,

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
            {
                var list = ClassDb.classGetPropertyList(sn, .{ .no_inheritance = true });
                defer list.deinit();
                try c.addOwnNames(&c.props, &list, at);
            }
            {
                var list = ClassDb.classGetSignalList(sn, .{ .no_inheritance = true });
                defer list.deinit();
                try c.addOwnNames(&c.signals, &list, at);
            }
            var parent = ClassDb.getParentClass(sn);
            defer parent.deinit();
            class = try nameAlloc(a, parent);
        }
        // The last name read was never added (empty, or past the cap).
        a.free(class);
        return c;
    }

    fn deinit(c: *Chain) void {
        for ([_]*std.StringHashMapUnmanaged(u32){ &c.props, &c.signals }) |map| {
            var it = map.keyIterator();
            while (it.next()) |k| c.a.free(k.*);
            map.deinit(c.a);
        }
        for (c.classes.items) |s| c.a.free(s);
        c.classes.deinit(c.a);
    }

    /// Adds the `name` of every entry of `list` (property or signal
    /// dictionaries) to `map`, skipping label entries (group, category).
    fn addOwnNames(c: *Chain, map: *std.StringHashMapUnmanaged(u32), list: *const Array, at: u32) Allocator.Error!void {
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
            const gop = map.getOrPut(c.a, text) catch |err| {
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

    fn signalOwner(c: *const Chain, name: []const u8) ?[]const u8 {
        const at = c.signals.get(name) orelse return null;
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
    const p = try hides(a, "res://named.zig", .property, "name", .property, "Node");
    defer a.free(p);
    try testing.expectEqualStrings("Property 'name' of res://named.zig hides Node.name; rename it or give it a name override in meta.", p);
    const m = try hides(a, "res://named.zig", .method, "get_name", .method, "Node");
    defer a.free(m);
    try testing.expectEqualStrings("Method 'get_name' of res://named.zig hides Node.get_name; rename it or give it a name override in meta.", m);
    const ms = try hides(a, "res://a.zig", .method, "draw", .signal, "CanvasItem");
    defer a.free(ms);
    try testing.expectEqualStrings("Method 'draw' of res://a.zig hides signal CanvasItem.draw; rename it or give it a name override in meta.", ms);
    const sp = try hides(a, "res://a.zig", .signal, "visible", .property, "CanvasItem");
    defer a.free(sp);
    try testing.expectEqualStrings("Signal 'visible' of res://a.zig hides property CanvasItem.visible; rename it or give it a name override in meta.", sp);
    const sm = try hides(a, "res://a.zig", .signal, "hide", .method, "CanvasItem");
    defer a.free(sm);
    try testing.expectEqualStrings("Signal 'hide' of res://a.zig hides method CanvasItem.hide; rename it or give it a name override in meta.", sm);
    const f = try nodeField(a, "res://holder.zig", "Resource", "target");
    defer a.free(f);
    try testing.expectEqualStrings("res://holder.zig extends Resource, which is not a Node, so field 'target' cannot hold a Node.", f);
}
