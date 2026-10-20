//! From a script's C-ABI descriptor (`abi.ScriptDesc`) to the data Godot's
//! script API asks for: property, method and signal dictionaries, and
//! default values.
//!
//! The dictionary shapes are those of Godot's own `PropertyInfo` and
//! `MethodInfo` conversions to `Dictionary` (core/object/property_info.cpp,
//! core/object/method_info.cpp), so GDScript code and the editor read them
//! like any other script's:
//! - property: `name`, `class_name`, `type`, `hint`, `hint_string`, `usage`;
//! - method: `name`, `args` (property dictionaries), `default_args` (empty),
//!   `flags`, `id` (0), `return` (a property dictionary);
//! - signal: `name`, `args` (property dictionaries).
//!
//! A group entry of the descriptor becomes a property dictionary with usage
//! GROUP, type NIL and the group name as `name`. The index of a property in
//! the list is its index in the descriptor (group entries count).
//!
//! All functions call into Godot and run on the main thread. The returned
//! `Array`s and `Variant`s are owned by the caller.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");

const Allocator = std.mem.Allocator;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;

/// Godot's `METHOD_FLAG_NORMAL` and `METHOD_FLAG_VIRTUAL`
/// (core/object/method_info.h:38-46; the virtual flag is 8, not 32: 32 is
/// `METHOD_FLAG_STATIC`).
pub const godot_method_flag_normal: u32 = 1;
pub const godot_method_flag_virtual: u32 = 8;

/// Godot's `PROPERTY_USAGE_DEFAULT` (STORAGE | EDITOR), the usage of a
/// method argument or return value.
pub const usage_default: u32 = 2 | 4;

/// One Godot `PropertyInfo`, with borrowed text.
pub const PropInfo = struct {
    name: []const u8,
    class_name: []const u8 = "",
    type: u32,
    hint: u32 = 0,
    hint_string: []const u8 = "",
    usage: u32 = usage_default,
};

/// The bytes of `s`.
pub fn text(s: abi.Str) []const u8 {
    if (s.len == 0) return "";
    return (s.ptr orelse return "")[0..s.len];
}

/// A method argument or return value as a property.
pub fn argInfo(a: abi.ArgDesc) PropInfo {
    return .{ .name = text(a.name), .class_name = text(a.class_name), .type = a.variant_type };
}

/// An exported property, or a group entry, as a property.
pub fn propInfo(p: abi.PropertyDesc) PropInfo {
    return .{
        .name = text(p.name),
        .class_name = text(p.class_name),
        .type = p.variant_type,
        .hint = p.hint,
        .hint_string = text(p.hint_string),
        .usage = p.usage,
    };
}

/// The Godot method flags for the descriptor's `MethodDesc.flags`.
pub fn godotMethodFlags(flags: u32) u32 {
    return godot_method_flag_normal | if (flags & abi.method_flag_virtual != 0) godot_method_flag_virtual else 0;
}

/// A Godot `String` from UTF-8 text; the empty string when the text is not
/// valid UTF-8 (descriptors are checked, a cache file may not be).
pub fn gstring(s: []const u8) String {
    return String.fromUtf8(s) catch String.fromLatin1("");
}

/// The UTF-8 text of `s`, allocated with `a`.
pub fn utf8Alloc(a: Allocator, s: *const String) Allocator.Error![]u8 {
    const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(s.constPtr(), null, 0)));
    const buf = try a.alloc(u8, n);
    if (n != 0) _ = godot.raw.stringToUtf8Chars(s.constPtr(), buf.ptr, @intCast(n));
    return buf;
}

fn putVariant(d: *Dictionary, comptime key: []const u8, value: Variant) void {
    var k_string = String.fromLatin1(key);
    defer k_string.deinit();
    const k = Variant.init(String, k_string);
    defer k.deinit();
    defer value.deinit();
    _ = d.set(k, value);
}

fn putInt(d: *Dictionary, comptime key: []const u8, v: u32) void {
    putVariant(d, key, Variant.init(i64, v));
}

fn putString(d: *Dictionary, comptime key: []const u8, s: []const u8) void {
    var g = gstring(s);
    defer g.deinit();
    putVariant(d, key, Variant.init(String, g));
}

/// `info` as a Godot property dictionary.
pub fn propDict(info: PropInfo) Dictionary {
    var d = Dictionary.init();
    putString(&d, "name", info.name);
    var cn = StringName.fromUtf8(info.class_name);
    defer cn.deinit();
    putVariant(&d, "class_name", Variant.init(StringName, cn));
    putInt(&d, "type", info.type);
    putInt(&d, "hint", info.hint);
    putString(&d, "hint_string", info.hint_string);
    putInt(&d, "usage", info.usage);
    return d;
}

/// Appends `d` (copied) to `arr`.
pub fn pushDict(arr: *Array, d: Dictionary) void {
    const v = Variant.init(Dictionary, d);
    defer v.deinit();
    arr.pushBack(v);
}

/// Appends the property dictionary of `info` to `arr`.
pub fn pushProp(arr: *Array, info: PropInfo) void {
    var d = propDict(info);
    defer d.deinit();
    pushDict(arr, d);
}

/// A method dictionary. `args` holds property dictionaries.
pub fn methodDict(name: []const u8, args: Array, godot_flags: u32, ret: PropInfo) Dictionary {
    var d = Dictionary.init();
    putString(&d, "name", name);
    putVariant(&d, "args", Variant.init(Array, args));
    var no_defaults = Array.init();
    defer no_defaults.deinit();
    putVariant(&d, "default_args", Variant.init(Array, no_defaults));
    putInt(&d, "flags", godot_flags);
    putInt(&d, "id", 0);
    var r = propDict(ret);
    defer r.deinit();
    putVariant(&d, "return", Variant.init(Dictionary, r));
    return d;
}

/// A signal dictionary. `args` holds property dictionaries.
pub fn signalDict(name: []const u8, args: Array) Dictionary {
    var d = Dictionary.init();
    putString(&d, "name", name);
    putVariant(&d, "args", Variant.init(Array, args));
    return d;
}

fn argArray(args: []const abi.ArgDesc) Array {
    var arr = Array.init();
    for (args) |a| pushProp(&arr, argInfo(a));
    return arr;
}

fn argSlice(ptr: [*]const abi.ArgDesc, count: u32) []const abi.ArgDesc {
    if (count == 0) return &.{};
    return ptr[0..count];
}

/// The script's exported properties, group entries included, in descriptor
/// order.
pub fn propertyList(desc: *const abi.ScriptDesc) Array {
    var arr = Array.init();
    for (desc.properties[0..desc.property_count]) |p| pushProp(&arr, propInfo(p));
    return arr;
}

/// The script's methods, in descriptor order (the index is the call index).
pub fn methodList(desc: *const abi.ScriptDesc) Array {
    var arr = Array.init();
    for (desc.methods[0..desc.method_count]) |m| {
        var args = argArray(argSlice(m.args, m.arg_count));
        defer args.deinit();
        var d = methodDict(text(m.name), args, godotMethodFlags(m.flags), argInfo(m.ret));
        defer d.deinit();
        pushDict(&arr, d);
    }
    return arr;
}

/// The script's signals, in descriptor order.
pub fn signalList(desc: *const abi.ScriptDesc) Array {
    var arr = Array.init();
    for (desc.signals[0..desc.signal_count]) |s| {
        var args = argArray(argSlice(s.args, s.arg_count));
        defer args.deinit();
        var d = signalDict(text(s.name), args);
        defer d.deinit();
        pushDict(&arr, d);
    }
    return arr;
}

/// The default value of property `prop_index` (an index into the descriptor's
/// properties), or null for a group entry, an index past the end, or a
/// property without a default. The caller owns the Variant (`deinit`).
pub fn defaultValue(desc: *const abi.ScriptDesc, prop_index: u32) ?Variant {
    if (prop_index >= desc.property_count) return null;
    if (desc.properties[prop_index].field_index == abi.no_field) return null;
    var v: Variant = Variant.nil;
    if (desc.get_default(prop_index, @ptrCast(&v)) == 0) return null;
    return v;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "godot method flags" {
    try testing.expectEqual(@as(u32, 1), godotMethodFlags(0));
    try testing.expectEqual(@as(u32, 9), godotMethodFlags(abi.method_flag_virtual));
}

test "text of a Str" {
    try testing.expectEqualStrings("", text(.{ .ptr = null, .len = 0 }));
    try testing.expectEqualStrings("ab", text(.{ .ptr = "abc", .len = 2 }));
}
