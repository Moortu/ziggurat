//! The script template text behind `ZigLanguage._get_built_in_templates` and
//! `_make_template` (spec section 7).
//!
//! The Create Script dialog passes the chosen template's content, the new
//! file's base name and the parent class (editor/script/
//! script_create_dialog.cpp:371-382). With templates switched off it passes
//! an empty content (`_get_current_template` finds no built-in "Empty"
//! template, :722-737), so an empty content means the default template.
//! Placeholders are GDScript's (modules/gdscript/gdscript_editor.cpp:
//! 112-115): `_BASE_`, `_CLASS_`, `_CLASS_SNAKE_CASE_` and `_TS_`.
//!
//! Zig scripts extend engine classes only. A parent class written as a
//! quoted script path (what the dialog passes for a script parent, :374-379)
//! or a name that is not an engine class gives a script whose whole text is
//! a comment that says so: never an error, because the dialog needs a
//! script back.
//!
//! Imports only std, so the unit tests run without Godot.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// The one built-in template, offered for every class (its `inherit` is
/// `Object`, the root of every class hierarchy the dialog walks).
pub const default_name = "Default";
pub const default_description = "A Zig script with a _ready method.";
pub const default_content =
    \\//! _CLASS_: a Zig script that extends _BASE_.
    \\const z = @import("ziggurat");
    \\
    \\pub const extends = z.godot._BASE_;
    \\
    \\base: *z.godot._BASE_,
    \\
    \\pub fn _ready(self: *@This()) void {
    \\_TS__ = self;
    \\}
    \\
;

/// One indentation level: four spaces, as `zig fmt` writes.
const indent = "    ";

/// Longest parent class text quoted in a refusal comment.
const max_quoted = 200;

/// The source of a new script made from `content` for file name
/// `class_name` and parent class `base`. `base_is_engine_class` is true when
/// Godot knows `base` as an engine class. Caller frees.
pub fn make(a: Allocator, content: []const u8, class_name: []const u8, base: []const u8, base_is_engine_class: bool) Allocator.Error![]u8 {
    if (isQuoted(base)) return refusal(a, base, "a script");
    if (!isIdentifier(base) or !base_is_engine_class) return refusal(a, base, "not an engine class");

    const text = if (content.len == 0) default_content else content;
    const pascal = try pascalCase(a, class_name);
    defer a.free(pascal);
    const snake = try snakeCase(a, class_name);
    defer a.free(snake);
    // `_CLASS_SNAKE_CASE_` before `_CLASS_`, which it contains.
    const pairs = [_][2][]const u8{
        .{ "_BASE_", base },
        .{ "_CLASS_SNAKE_CASE_", snake },
        .{ "_CLASS_", pascal },
        .{ "_TS_", indent },
    };
    var cur = try a.dupe(u8, text);
    errdefer a.free(cur);
    for (pairs) |p| {
        const next = try std.mem.replaceOwned(u8, a, cur, p[0], p[1]);
        a.free(cur);
        cur = next;
    }
    return cur;
}

/// A script that is only a comment saying why no Zig script extends `base`.
fn refusal(a: Allocator, base: []const u8, comptime why: []const u8) Allocator.Error![]u8 {
    var shown: [max_quoted]u8 = undefined;
    const n = @min(base.len, shown.len);
    for (base[0..n], shown[0..n]) |c, *o| o.* = if (c < 0x20 or c == 0x7f) ' ' else c;
    return std.fmt.allocPrint(a,
        \\// Zig scripts extend engine classes only, and the parent class
        \\// {s} is {s}.
        \\// Create the script again with an engine class (for example Node)
        \\// as the parent class.
        \\
    , .{ shown[0..n], why });
}

/// `"..."` or `'...'`, as Godot's `String::is_quoted`.
fn isQuoted(s: []const u8) bool {
    if (s.len < 2) return false;
    return (s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'');
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// `my_player` and `my-player` become `MyPlayer`; characters that are not
/// ASCII letters or digits separate words; a leading digit gets `_`.
fn pascalCase(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var start_word = true;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            start_word = true;
            continue;
        }
        if (out.items.len == 0 and std.ascii.isDigit(c)) try out.append(a, '_');
        try out.append(a, if (start_word) std.ascii.toUpper(c) else c);
        start_word = false;
    }
    return out.toOwnedSlice(a);
}

/// Lower case, with `_` for every character that is not an ASCII letter or
/// digit; a leading digit gets `_`.
fn snakeCase(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (out.items.len == 0 and std.ascii.isDigit(c)) try out.append(a, '_');
        try out.append(a, if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_');
    }
    return out.toOwnedSlice(a);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "default template for an engine class" {
    const s = try make(testing.allocator, default_content, "my_mover", "Node2D", true);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(
        \\//! MyMover: a Zig script that extends Node2D.
        \\const z = @import("ziggurat");
        \\
        \\pub const extends = z.godot.Node2D;
        \\
        \\base: *z.godot.Node2D,
        \\
        \\pub fn _ready(self: *@This()) void {
        \\    _ = self;
        \\}
        \\
    , s);
}

test "empty content uses the default template" {
    const s = try make(testing.allocator, "", "x", "Node", true);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "pub const extends = z.godot.Node;") != null);
}

test "user template placeholders" {
    const s = try make(testing.allocator, "_CLASS_ _CLASS_SNAKE_CASE_ _BASE_\n_TS_x", "3d-Thing", "Node3D", true);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("_3dThing _3d_thing Node3D\n    x", s);
}

test "a quoted script path as parent class is refused with a comment" {
    const s = try make(testing.allocator, default_content, "x", "\"res://base.gd\"", false);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "// Zig scripts extend engine classes only"));
    try testing.expect(std.mem.indexOf(u8, s, "\"res://base.gd\" is a script") != null);
    try testing.expect(std.mem.indexOf(u8, s, "pub const extends") == null);
    // Every line is a comment.
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, s, "\n"), '\n');
    while (it.next()) |line| try testing.expect(std.mem.startsWith(u8, line, "//"));
}

test "a name that is not an engine class is refused; control characters are blanked" {
    const a = try make(testing.allocator, default_content, "x", "Mover", false);
    defer testing.allocator.free(a);
    try testing.expect(std.mem.indexOf(u8, a, "Mover is not an engine class") != null);
    const b = try make(testing.allocator, default_content, "x", "Bad\nName", true);
    defer testing.allocator.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "Bad Name is not an engine class") != null);
    const c = try make(testing.allocator, default_content, "x", "", true);
    defer testing.allocator.free(c);
    try testing.expect(std.mem.startsWith(u8, c, "// Zig scripts extend engine classes only"));
}

test "make does not leak on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(a: Allocator) !void {
            a.free(try make(a, default_content, "my_x", "Node", true));
            a.free(try make(a, default_content, "my_x", "\"res://x.gd\"", false));
        }
    }.f, .{});
}
