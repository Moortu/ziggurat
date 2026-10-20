//! The global class scan behind `ZigLanguage._get_global_class_name` (spec
//! section 7, "Global classes").
//!
//! Godot calls `_get_global_class_name` on its file-scan thread for every
//! script file, so the scan only reads text: no compiler, no module, no
//! engine object. A script declares a global class only with an explicit
//! top-level `pub const class_name = "<Name>";` (the file name is never
//! used: duplicate global class names overwrite each other silently, spec
//! section 2). The same top-level scan reads `pub const extends = ...;` for
//! the base type and `pub const tool = true;` for the tool flag.
//!
//! "Top-level" means at brace depth 0: a declaration inside a nested
//! `struct { ... }` does not count. The text goes through Zig's own
//! tokenizer, so declarations inside comments, strings and multiline
//! strings are never seen as code.
//!
//! Imports only std, so the unit tests run without Godot.
const std = @import("std");

/// What a script declares at top level. The slices point into the scanned
/// text.
pub const Info = struct {
    /// The `class_name` value: an identifier.
    name: []const u8,
    /// The last identifier of the `extends` expression (`Node2D` for
    /// `z.godot.Node2D` or `g.Node2D`), or empty when there is none or it is
    /// not a dotted name.
    base_type: []const u8,
    /// `pub const tool = true;`.
    is_tool: bool,
};

/// Largest file scanned; a bigger file declares no global class.
pub const max_file_bytes = 4 << 20;

/// The global class `text` declares, or null when it has no top-level
/// `pub const class_name` whose value is a plain identifier string.
pub fn scan(text: [:0]const u8) ?Info {
    var name: ?[]const u8 = null;
    var base_type: []const u8 = "";
    var is_tool = false;
    var seen_extends = false;
    var seen_tool = false;

    var t: std.zig.Tokenizer = .init(text);
    var depth: usize = 0;
    while (true) {
        const tok = t.next();
        switch (tok.tag) {
            .eof => break,
            .l_brace => depth +|= 1,
            .r_brace => depth -|= 1,
            .keyword_pub => if (depth == 0) {
                // Looks ahead on a copy; the main loop still sees every
                // token, so braces inside the value are counted.
                var ahead = t;
                const decl = pubConst(&ahead, text) orelse continue;
                if (std.mem.eql(u8, decl.name, "class_name")) {
                    if (name == null) name = stringIdentifier(&ahead, text);
                } else if (std.mem.eql(u8, decl.name, "extends")) {
                    if (!seen_extends) base_type = dottedLast(&ahead, text);
                    seen_extends = true;
                } else if (std.mem.eql(u8, decl.name, "tool")) {
                    if (!seen_tool) is_tool = isTrue(&ahead, text);
                    seen_tool = true;
                }
            },
            else => {},
        }
    }
    return .{ .name = name orelse return null, .base_type = base_type, .is_tool = is_tool };
}

const Decl = struct { name: []const u8 };

/// After `pub`: `const <name> =`, or null.
fn pubConst(t: *std.zig.Tokenizer, text: []const u8) ?Decl {
    if (t.next().tag != .keyword_const) return null;
    const id = t.next();
    if (id.tag != .identifier) return null;
    if (t.next().tag != .equal) return null;
    return .{ .name = text[id.loc.start..id.loc.end] };
}

/// `"<identifier>" ;`: the identifier, or null for anything else (escapes,
/// other characters, a missing `;`).
fn stringIdentifier(t: *std.zig.Tokenizer, text: []const u8) ?[]const u8 {
    const s = t.next();
    if (s.tag != .string_literal) return null;
    if (t.next().tag != .semicolon) return null;
    const inner = text[s.loc.start + 1 .. s.loc.end - 1];
    if (!isIdentifier(inner)) return null;
    return inner;
}

/// `a.b.C ;`: `C`, or empty for anything else.
fn dottedLast(t: *std.zig.Tokenizer, text: []const u8) []const u8 {
    var last: []const u8 = "";
    while (true) {
        const id = t.next();
        if (id.tag != .identifier) return "";
        last = text[id.loc.start..id.loc.end];
        switch (t.next().tag) {
            .period => continue,
            .semicolon => return last,
            else => return "",
        }
    }
}

/// `true ;`.
fn isTrue(t: *std.zig.Tokenizer, text: []const u8) bool {
    const id = t.next();
    if (id.tag != .identifier or !std.mem.eql(u8, text[id.loc.start..id.loc.end], "true")) return false;
    return t.next().tag == .semicolon;
}

/// A plain ASCII identifier, as the SDK requires of `class_name`
/// (sdk/describe.zig).
pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "a top-level class_name is found with base type and tool flag" {
    const info = scan(
        \\//! A player.
        \\const z = @import("ziggurat");
        \\const g = z.godot;
        \\
        \\pub const extends = g.CharacterBody2D;
        \\pub const class_name = "Player";
        \\pub const tool = true;
        \\
        \\base: *g.CharacterBody2D,
        \\
    ).?;
    try testing.expectEqualStrings("Player", info.name);
    try testing.expectEqualStrings("CharacterBody2D", info.base_type);
    try testing.expect(info.is_tool);
}

test "no class_name, no global class" {
    try testing.expectEqual(@as(?Info, null), scan(
        \\const z = @import("ziggurat");
        \\pub const extends = z.godot.Node;
        \\base: *z.godot.Node,
        \\
    ));
    try testing.expectEqual(@as(?Info, null), scan(""));
}

test "class_name in comments and strings does not count" {
    try testing.expectEqual(@as(?Info, null), scan(
        \\// pub const class_name = "InLineComment";
        \\/// pub const class_name = "InDocComment";
        \\//! pub const class_name = "InFileComment";
        \\const s = "pub const class_name = \"InString\";";
        \\const m =
        \\    \\pub const class_name = "InMultiline";
        \\;
        \\pub const extends = z.godot.Node;
        \\
    ));
}

test "a nested class_name does not count, the top-level one does" {
    try testing.expectEqual(@as(?Info, null), scan(
        \\pub const extends = z.godot.Node;
        \\pub const Inner = struct {
        \\    pub const class_name = "Nested";
        \\};
        \\
    ));
    // Nested even when unindented, and braces inside strings do not count.
    const info = scan(
        \\pub const Inner = struct {
        \\pub const class_name = "Nested";
        \\const brace = "}";
        \\};
        \\pub const meta = .{ .speed = .{ .group = "{" } };
        \\pub const class_name = "Outer";
        \\pub const extends = z.godot.Node3D;
        \\
    ).?;
    try testing.expectEqualStrings("Outer", info.name);
    try testing.expectEqualStrings("Node3D", info.base_type);
    try testing.expect(!info.is_tool);
}

test "only a plain identifier string is a class name" {
    try testing.expectEqual(@as(?Info, null), scan("pub const class_name = \"Not A Name\";\n"));
    try testing.expectEqual(@as(?Info, null), scan("pub const class_name = \"Esc\\x41\";\n"));
    try testing.expectEqual(@as(?Info, null), scan("pub const class_name = \"\";\n"));
    try testing.expectEqual(@as(?Info, null), scan("const class_name = \"Private\";\n"));
    try testing.expectEqual(@as(?Info, null), scan("pub const class_name = name;\n"));
    try testing.expectEqualStrings("Ok", scan("pub const class_name = \"Ok\";").?.name);
}

test "an extends that is not a dotted name gives an empty base type" {
    const info = scan(
        \\pub const class_name = "Odd";
        \\pub const extends = pick(z.godot.Node);
        \\pub const tool = false;
        \\
    ).?;
    try testing.expectEqualStrings("", info.base_type);
    try testing.expect(!info.is_tool);
    try testing.expectEqualStrings("Node", scan("pub const class_name = \"A\";\npub const extends = Node;\n").?.base_type);
}

test "garbage text is scanned without failing" {
    try testing.expectEqual(@as(?Info, null), scan("}}}} pub pub const = \"\x00\xff{{ \\\\ '"));
    try testing.expectEqual(@as(?Info, null), scan("pub const class_name = \"Unterminated\n"));
    try testing.expectEqualStrings("Bom", scan("\xEF\xBB\xBFpub const class_name = \"Bom\";").?.name);
}

test "isIdentifier" {
    try testing.expect(isIdentifier("Player_2"));
    try testing.expect(isIdentifier("_x"));
    try testing.expect(!isIdentifier("2x"));
    try testing.expect(!isIdentifier("a-b"));
    try testing.expect(!isIdentifier(""));
}
