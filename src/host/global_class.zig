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
    /// not a dotted name. A plain identifier that a top-level `const`
    /// declares (`const N = g.Node2D;`) is the last identifier of that
    /// declaration's value.
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
    var base: Dotted = .{};
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
                    if (!seen_extends) base = dottedName(&ahead, text);
                    seen_extends = true;
                } else if (std.mem.eql(u8, decl.name, "tool")) {
                    if (!seen_tool) is_tool = isTrue(&ahead, text);
                    seen_tool = true;
                }
            },
            else => {},
        }
    }
    const class_name = name orelse return null;
    // `extends = N` with `const N = g.Node2D;` at top level: the alias's
    // value names the class. Aliases of aliases are followed a few steps.
    var hops: usize = 0;
    while (!base.dotted and base.last.len != 0 and hops < max_alias_hops) : (hops += 1) {
        base = aliasValue(text, base.last) orelse break;
    }
    return .{ .name = class_name, .base_type = base.last, .is_tool = is_tool };
}

/// Most alias steps `scan` follows from `extends` (an alias cycle stops
/// there).
const max_alias_hops = 8;

/// The value of the top-level `const <alias> = a.b.C;` (with or without
/// `pub`) as a dotted name, or null when there is no such declaration.
fn aliasValue(text: [:0]const u8, alias: []const u8) ?Dotted {
    var t: std.zig.Tokenizer = .init(text);
    var depth: usize = 0;
    while (true) {
        const tok = t.next();
        switch (tok.tag) {
            .eof => return null,
            .l_brace => depth +|= 1,
            .r_brace => depth -|= 1,
            .keyword_const => if (depth == 0) {
                var ahead = t;
                const id = ahead.next();
                if (id.tag != .identifier or !std.mem.eql(u8, text[id.loc.start..id.loc.end], alias)) continue;
                if (ahead.next().tag != .equal) continue;
                return dottedName(&ahead, text);
            },
            else => {},
        }
    }
}

/// Most signal names `signalNames` returns.
pub const max_signals = 256;

/// The names of the signals `text` declares: each `pub const <name> = ...`
/// directly inside a top-level `pub const signals = struct { ... }`, in
/// source order, at most `max_signals`. Names only: a script with no
/// descriptors uses them so `get_signal_list` keeps scene connections to
/// its own signals (the SDK names a signal after its declaration). The
/// slices point into `text`; `out` receives them and the count is returned.
pub fn signalNames(text: [:0]const u8, out: *[max_signals][]const u8) usize {
    var n: usize = 0;
    var t: std.zig.Tokenizer = .init(text);
    var depth: usize = 0;
    // Depth of the body of `signals` while inside it (it is 1).
    var inside = false;
    while (true) {
        const tok = t.next();
        switch (tok.tag) {
            .eof => break,
            .l_brace => depth +|= 1,
            .r_brace => {
                depth -|= 1;
                if (inside and depth == 0) inside = false;
            },
            .keyword_pub => {
                var ahead = t;
                const decl = pubConst(&ahead, text) orelse continue;
                if (depth == 0 and !inside and std.mem.eql(u8, decl.name, "signals")) {
                    // `struct {`: the main loop counts the brace.
                    var look = ahead;
                    if (look.next().tag == .keyword_struct and look.next().tag == .l_brace) inside = true;
                } else if (inside and depth == 1 and n < max_signals) {
                    out[n] = decl.name;
                    n += 1;
                }
            },
            else => {},
        }
    }
    return n;
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

/// A dotted name's last identifier, and whether it had a dot.
const Dotted = struct { last: []const u8 = "", dotted: bool = false };

/// `a.b.C ;`: `C` (dotted), `C ;`: `C` (not dotted), or empty for
/// anything else.
fn dottedName(t: *std.zig.Tokenizer, text: []const u8) Dotted {
    var out: Dotted = .{};
    while (true) {
        const id = t.next();
        if (id.tag != .identifier) return .{};
        out.last = text[id.loc.start..id.loc.end];
        switch (t.next().tag) {
            .period => out.dotted = true,
            .semicolon => return out,
            else => return .{},
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

test "global class: alias base reports the engine class" {
    const info = scan(
        \\const z = @import("ziggurat");
        \\const g = z.godot;
        \\const N = g.Node2D;
        \\pub const class_name = "Aliased";
        \\pub const extends = N;
        \\
    ).?;
    try testing.expectEqualStrings("Node2D", info.base_type);
    // A public alias, and an alias of an alias.
    try testing.expectEqualStrings("Sprite2D", scan(
        \\pub const S = z.godot.Sprite2D;
        \\const T = S;
        \\pub const class_name = "A";
        \\pub const extends = T;
        \\
    ).?.base_type);
    // An alias declared after `extends`.
    try testing.expectEqualStrings("Node3D", scan(
        \\pub const class_name = "A";
        \\pub const extends = N;
        \\const N = g.Node3D;
        \\
    ).?.base_type);
    // A local `const` inside a function or struct is not an alias.
    try testing.expectEqualStrings("N", scan(
        \\pub const class_name = "A";
        \\pub const extends = N;
        \\fn f() void { const N = g.Node3D; _ = N; }
        \\const Inner = struct { const N = g.Node3D; };
        \\
    ).?.base_type);
    // An alias of something that is not a dotted name, and alias cycles.
    try testing.expectEqualStrings("", scan(
        \\const B = @import("base.zig");
        \\pub const class_name = "A";
        \\pub const extends = B;
        \\
    ).?.base_type);
    _ = scan("const A = B;\nconst B = A;\npub const class_name = \"A\";\npub const extends = A;\n").?;
    _ = scan("const A = A;\npub const class_name = \"A\";\npub const extends = A;\n").?;
}

test "garbage text is scanned without failing" {
    try testing.expectEqual(@as(?Info, null), scan("}}}} pub pub const = \"\x00\xff{{ \\\\ '"));
    try testing.expectEqual(@as(?Info, null), scan("pub const class_name = \"Unterminated\n"));
    try testing.expectEqualStrings("Bom", scan("\xEF\xBB\xBFpub const class_name = \"Bom\";").?.name);
}

fn expectSignals(text: [:0]const u8, want: []const []const u8) !void {
    var out: [max_signals][]const u8 = undefined;
    const n = signalNames(text, &out);
    try testing.expectEqual(want.len, n);
    for (want, out[0..n]) |w, got| try testing.expectEqualStrings(w, got);
}

test "signal names come from the top-level signals struct only" {
    try expectSignals(
        \\const z = @import("ziggurat");
        \\// pub const signals = struct { pub const commented = struct {}; };
        \\const s = "pub const signals = struct { pub const in_string = struct {}; };";
        \\pub const signals = struct {
        \\    pub const hit = struct {};
        \\    pub const moved = struct { x: i32, y: Inner };
        \\    const Inner = struct { pub const deep = 1; };
        \\    const private = struct {};
        \\    pub const last = struct {
        \\        pub const nested = struct {};
        \\    };
        \\};
        \\pub const Other = struct {
        \\    pub const signals = struct { pub const not_top = struct {}; };
        \\};
        \\const more = struct { pub const nope = struct {}; };
        \\
    , &.{ "hit", "moved", "last" });
}

test "no signals struct, a private one, or garbage gives no names" {
    try expectSignals("pub const extends = z.godot.Node;\n", &.{});
    try expectSignals("const signals = struct { pub const hidden = struct {}; };\n", &.{});
    try expectSignals("pub const signals = 3;\npub const after = struct {};\n", &.{});
    try expectSignals("pub const signals = struct { pub const open = struct {};", &.{"open"});
    try expectSignals("}}}} pub const signals = struct { { pub const deep = 1; } pub const ok = 1; }", &.{"ok"});
    try expectSignals("", &.{});
}

test "isIdentifier" {
    try testing.expect(isIdentifier("Player_2"));
    try testing.expect(isIdentifier("_x"));
    try testing.expect(!isIdentifier("2x"));
    try testing.expect(!isIdentifier("a-b"));
    try testing.expect(!isIdentifier(""));
}
