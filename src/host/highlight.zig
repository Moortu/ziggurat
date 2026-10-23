//! Zig syntax colours for one line of the script editor (spec section 9).
//! Std only; `highlighter.zig` (the `ZigHighlighter` class) turns the
//! regions into Godot's format and colours.
//!
//! A line is cut into tokens by `std.zig.Tokenizer`. Zig has no token that
//! spans lines except `\\` string lines, and each of those ends at its own
//! line end, so one line is enough. Each token gets a `Kind`, which names
//! one of Godot's `text_editor/theme/highlighting/*` colours
//! (`settingName`):
//! - control flow (`if else switch while for return break continue try
//!   catch orelse defer errdefer unreachable`): `control_flow`; every other
//!   keyword, and `true false null undefined`: `keyword`;
//! - other primitive types (`u8`, `bool`, `void`, `type`, ...): `base_type`;
//! - an identifier that starts with an upper-case letter: `user_type`;
//! - an `@builtin`, or an identifier followed by `(`: `function`;
//! - numbers, strings and char literals (`\\` lines too);
//! - `//` comments, and `///` and `//!` doc comments;
//! - everything else (names, operators, punctuation): `symbol`.
//!
//! The tokenizer calls some text invalid and runs that token to the line
//! end: an unterminated string, a tab or other control byte inside a
//! comment or `\\` line, a NUL byte. Such a token gets the kind its first
//! characters name (a string, comment or doc comment), else `symbol`.
//!
//! Regions: a region starts where its kind starts and runs to the next
//! region (Godot's rule), so neighbours of one kind are merged. A column
//! counts code points, as Godot's `String` (char32_t) and `CodeEdit` do:
//! `ä` and an emoji are one column each. At most `max_regions` regions are
//! made, and no token that starts after the first `max_scan_bytes` bytes
//! is looked at (a 1 MB line stays quick to draw); the rest of a longer
//! line keeps the last kind. Any bytes work:
//! invalid UTF-8 cannot crash it (a stray byte is its own column, a
//! continuation byte none).
const std = @import("std");

const Tokenizer = std.zig.Tokenizer;
const Tag = std.zig.Token.Tag;

pub const Kind = enum { symbol, keyword, control_flow, function, base_type, user_type, number, string, comment, doc_comment };

pub const Region = struct { column: u32, kind: Kind };

pub const max_regions = 512;

/// Tokens that start this far into a line or further are not coloured.
pub const max_scan_bytes = 64 * 1024;

/// The editor setting that holds the colour of `kind`.
pub fn settingName(kind: Kind) []const u8 {
    const prefix = "text_editor/theme/highlighting/";
    return switch (kind) {
        .symbol => prefix ++ "symbol_color",
        .keyword => prefix ++ "keyword_color",
        .control_flow => prefix ++ "control_flow_keyword_color",
        .function => prefix ++ "function_color",
        .base_type => prefix ++ "base_type_color",
        .user_type => prefix ++ "user_type_color",
        .number => prefix ++ "number_color",
        .string => prefix ++ "string_color",
        .comment => prefix ++ "comment_color",
        .doc_comment => prefix ++ "doc_comment_color",
    };
}

/// The regions of one line of text (no line break expected), written to
/// `out`; the returned slice is part of `out`. The tokenizer needs a
/// NUL-terminated copy: a short line is copied on the stack, a long one
/// to the heap (when that fails, the line is one symbol region).
pub fn line(text: []const u8, out: *[max_regions]Region) []Region {
    var small: [stack_bytes + 1]u8 = undefined;
    if (text.len <= stack_bytes) {
        @memcpy(small[0..text.len], text);
        small[text.len] = 0;
        return lineZ(small[0..text.len :0], out);
    }
    const a = std.heap.page_allocator;
    const copy = a.allocSentinel(u8, text.len, 0) catch {
        out[0] = .{ .column = 0, .kind = .symbol };
        return out[0..1];
    };
    defer a.free(copy);
    @memcpy(copy, text);
    return lineZ(copy, out);
}

const stack_bytes = 4096;

/// As `line`, for text that is NUL-terminated already.
pub fn lineZ(text: [:0]const u8, out: *[max_regions]Region) []Region {
    var b: Builder = .{ .text = text, .out = out };
    var tok = Tokenizer.init(text);
    var gap_start = tok.index; // after a UTF-8 BOM, which the tokenizer skips
    var cur = tok.next();
    while (b.n < max_regions) {
        // Between tokens there is only white space and plain `//`
        // comments, which the tokenizer skips; a comment runs to the line
        // end (or to a line break, which Godot's lines do not have).
        if (std.mem.indexOfPos(u8, text[0..cur.loc.start], gap_start, "//")) |at| {
            b.add(at, .comment);
            if (b.n == max_regions) break;
        }
        if (cur.tag == .eof or cur.loc.start >= max_scan_bytes) break;
        const next = tok.next();
        b.add(cur.loc.start, kindOf(text[cur.loc.start..cur.loc.end], cur.tag, next.tag));
        gap_start = cur.loc.end;
        cur = next;
    }
    return out[0..b.n];
}

/// Appends regions, merging neighbours of one kind, and counts columns.
const Builder = struct {
    text: []const u8,
    out: *[max_regions]Region,
    n: usize = 0,
    /// The byte offset `column` counts up to.
    byte: usize = 0,
    column: u32 = 0,

    fn add(b: *Builder, start: usize, kind: Kind) void {
        if (b.n > 0 and b.out[b.n - 1].kind == kind) return;
        if (b.n == max_regions) return;
        // Starts only grow (tokens come in order), so each byte is counted
        // once. A code point has one byte that is not a continuation byte.
        for (b.text[b.byte..start]) |c| {
            if (c & 0xC0 != 0x80) b.column +|= 1;
        }
        b.byte = start;
        b.out[b.n] = .{ .column = b.column, .kind = kind };
        b.n += 1;
    }
};

fn kindOf(text: []const u8, tag: Tag, next: Tag) Kind {
    return switch (tag) {
        .keyword_if,
        .keyword_else,
        .keyword_switch,
        .keyword_while,
        .keyword_for,
        .keyword_return,
        .keyword_break,
        .keyword_continue,
        .keyword_try,
        .keyword_catch,
        .keyword_orelse,
        .keyword_defer,
        .keyword_errdefer,
        .keyword_unreachable,
        => .control_flow,
        .identifier => identifierKind(text, next),
        .builtin => .function,
        .number_literal => .number,
        .string_literal, .multiline_string_literal_line, .char_literal => .string,
        .doc_comment, .container_doc_comment => .doc_comment,
        .invalid => invalidKind(text),
        else => if (isKeyword(tag)) .keyword else .symbol,
    };
}

fn isKeyword(tag: Tag) bool {
    return switch (tag) {
        inline else => |t| comptime std.mem.startsWith(u8, @tagName(t), "keyword_"),
    };
}

fn identifierKind(name: []const u8, next: Tag) Kind {
    const values = std.StaticStringMap(void).initComptime(.{ .{"true"}, .{"false"}, .{"null"}, .{"undefined"} });
    if (values.has(name)) return .keyword;
    if (std.zig.primitives.isPrimitive(name)) return .base_type;
    // By Zig's naming rule a function that returns a type is TitleCase,
    // so `ArrayList(u8)` is a type too.
    if (name.len > 0 and std.ascii.isUpper(name[0])) return .user_type;
    if (next == .l_paren) return .function;
    return .symbol;
}

/// An invalid token runs to the line end; its first characters say what
/// it was meant to be.
fn invalidKind(text: []const u8) Kind {
    const startsWith = std.mem.startsWith;
    if (startsWith(u8, text, "//!")) return .doc_comment;
    if (startsWith(u8, text, "///") and !startsWith(u8, text, "////")) return .doc_comment;
    if (startsWith(u8, text, "//")) return .comment;
    if (startsWith(u8, text, "\\\\")) return .string;
    if (startsWith(u8, text, "\"") or startsWith(u8, text, "'")) return .string;
    return .symbol;
}

// ------------------------------------------------------------ tests

const testing = std.testing;

/// The kind that colours `column` (the last region that starts at or
/// before it), or null before the first region.
fn kindAt(regions: []const Region, column: u32) ?Kind {
    var k: ?Kind = null;
    for (regions) |r| {
        if (r.column > column) break;
        k = r.kind;
    }
    return k;
}

/// Checks that the regions of `text` are exactly `want`.
fn expectRegions(text: []const u8, want: []const Region) !void {
    var out: [max_regions]Region = undefined;
    const got = line(text, &out);
    try testing.expectEqualSlices(Region, want, got);
}

test "keywords and control flow" {
    try expectRegions("pub fn f() void { if (x) return; }", &.{
        .{ .column = 0, .kind = .keyword }, // pub fn
        .{ .column = 7, .kind = .function }, // f
        .{ .column = 8, .kind = .symbol }, // ()
        .{ .column = 11, .kind = .base_type }, // void
        .{ .column = 16, .kind = .symbol }, // {
        .{ .column = 18, .kind = .control_flow }, // if
        .{ .column = 21, .kind = .symbol }, // (x)
        .{ .column = 25, .kind = .control_flow }, // return
        .{ .column = 31, .kind = .symbol }, // ; }
    });
    var out: [max_regions]Region = undefined;
    const words = "else switch while for break continue try catch orelse defer errdefer unreachable";
    const r = line(words, &out);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqual(Kind.control_flow, r[0].kind);
    const kw = line("const var struct enum union comptime inline and or test", &out);
    try testing.expectEqual(@as(usize, 1), kw.len);
    try testing.expectEqual(Kind.keyword, kw[0].kind);
}

test "builtins and calls" {
    var out: [max_regions]Region = undefined;
    const text = "const std = @import(\"std\"); foo(1); bar.baz (2);";
    const r = line(text, &out);
    try testing.expectEqual(Kind.function, kindAt(r, 12).?); // @import
    try testing.expectEqual(Kind.string, kindAt(r, 20).?);
    try testing.expectEqual(Kind.function, kindAt(r, 28).?); // foo
    try testing.expectEqual(Kind.symbol, kindAt(r, 31).?); // (
    try testing.expectEqual(Kind.number, kindAt(r, 32).?);
    try testing.expectEqual(Kind.symbol, kindAt(r, 36).?); // bar
    try testing.expectEqual(Kind.function, kindAt(r, 40).?); // baz
    try testing.expectEqual(Kind.symbol, kindAt(r, 44).?); // (
}

test "types" {
    var out: [max_regions]Region = undefined;
    const text = "var x: u8 = undefined; const L = ArrayList(i32); _ = true;";
    const r = line(text, &out);
    try testing.expectEqual(Kind.symbol, kindAt(r, 4).?); // x
    try testing.expectEqual(Kind.base_type, kindAt(r, 7).?); // u8
    try testing.expectEqual(Kind.keyword, kindAt(r, 12).?); // undefined
    try testing.expectEqual(Kind.user_type, kindAt(r, 29).?); // L
    try testing.expectEqual(Kind.user_type, kindAt(r, 33).?); // ArrayList
    try testing.expectEqual(Kind.base_type, kindAt(r, 43).?); // i32
    try testing.expectEqual(Kind.keyword, kindAt(r, 53).?); // true
    // `comptime_int` is one identifier, not `comptime` and `_int`.
    try expectRegions("bool anyerror comptime_int type", &.{.{ .column = 0, .kind = .base_type }});
}

test "numbers" {
    try expectRegions("x = 0x1F + 1_000 - 1e-3;", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 4, .kind = .number },
        .{ .column = 9, .kind = .symbol },
        .{ .column = 11, .kind = .number },
        .{ .column = 17, .kind = .symbol },
        .{ .column = 19, .kind = .number },
        .{ .column = 23, .kind = .symbol },
    });
}

test "strings and escapes" {
    try expectRegions("s = \"a\\\"b\\\\\" ++ 'c' ++ '\\'';", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 4, .kind = .string },
        .{ .column = 13, .kind = .symbol },
        .{ .column = 16, .kind = .string },
        .{ .column = 20, .kind = .symbol },
        .{ .column = 23, .kind = .string },
        .{ .column = 27, .kind = .symbol },
    });
}

test "multiline string line" {
    try expectRegions("    \\\\ x \"y\" // z", &.{.{ .column = 4, .kind = .string }});
    try expectRegions("\\\\", &.{.{ .column = 0, .kind = .string }});
}

test "comments and doc comments" {
    try expectRegions("x = 1; // note", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 4, .kind = .number },
        .{ .column = 5, .kind = .symbol },
        .{ .column = 7, .kind = .comment },
    });
    try expectRegions("    // only", &.{.{ .column = 4, .kind = .comment }});
    try expectRegions("//// four slashes", &.{.{ .column = 0, .kind = .comment }});
    try expectRegions("/// doc", &.{.{ .column = 0, .kind = .doc_comment }});
    try expectRegions("///", &.{.{ .column = 0, .kind = .doc_comment }});
    try expectRegions("//! top", &.{.{ .column = 0, .kind = .doc_comment }});
    try expectRegions("//", &.{.{ .column = 0, .kind = .comment }});
    try expectRegions("", &.{});
    try expectRegions("   ", &.{});
}

// Godot's `String` holds code points (char32_t), and `CodeEdit` columns
// index it, so a column counts code points: `ä` (2 bytes) and an emoji
// (4 bytes, a surrogate pair in UTF-16) are one column each.
test "utf16 columns: Godot counts code points" {
    try expectRegions("s = \"ä😀\"; const x = 1; // ä", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 4, .kind = .string },
        .{ .column = 8, .kind = .symbol },
        .{ .column = 10, .kind = .keyword },
        .{ .column = 16, .kind = .symbol },
        .{ .column = 20, .kind = .number },
        .{ .column = 21, .kind = .symbol },
        .{ .column = 23, .kind = .comment },
    });
}

test "hostile: a 1 MB line is quick" {
    const a = testing.allocator;
    const io = testing.io;
    const len = 1 << 20;
    const pieces = [_][]const u8{ "a + b ", "f(x) ", "\"s\" ", "0x1F ", "if ", "@b() " };
    for (pieces) |piece| {
        const text = try a.alloc(u8, len);
        defer a.free(text);
        for (text, 0..) |*c, i| c.* = piece[i % piece.len];
        var out: [max_regions]Region = undefined;
        const t0 = std.Io.Clock.awake.now(io);
        const r = line(text, &out);
        const ms = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        try testing.expect(r.len >= 1 and r.len <= max_regions);
        try testing.expect(ms < 50);
    }
    // One long string: one region.
    const text = try a.alloc(u8, len);
    defer a.free(text);
    @memset(text, 'x');
    text[0] = '"';
    text[len - 1] = '"';
    var out: [max_regions]Region = undefined;
    try testing.expectEqualSlices(Region, &.{.{ .column = 0, .kind = .string }}, line(text, &out));
}

test "hostile: tokens after max_scan_bytes keep the last kind" {
    const a = testing.allocator;
    const text = try a.alloc(u8, max_scan_bytes + 64);
    defer a.free(text);
    @memset(text, ' ');
    text[0] = 'x';
    @memcpy(text[max_scan_bytes - 4 ..][0..2], "if");
    @memcpy(text[max_scan_bytes + 4 ..][0..3], "for");
    var out: [max_regions]Region = undefined;
    try testing.expectEqualSlices(Region, &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = max_scan_bytes - 4, .kind = .control_flow },
    }, line(text, &out));
    // A token that starts before the limit is coloured to its end.
    @memset(text, 'x');
    text[0] = '"';
    text[text.len - 1] = '"';
    try testing.expectEqualSlices(Region, &.{.{ .column = 0, .kind = .string }}, line(text, &out));
    // A comment that starts before the limit is found.
    @memset(text, ' ');
    @memcpy(text[max_scan_bytes - 2 ..][0..2], "//");
    try testing.expectEqualSlices(Region, &.{.{ .column = max_scan_bytes - 2, .kind = .comment }}, line(text, &out));
}

test "hostile: regions stop at max_regions" {
    const a = testing.allocator;
    const text = try a.alloc(u8, 4 * 2000);
    defer a.free(text);
    for (0..2000) |i| @memcpy(text[i * 4 ..][0..4], "1 + ");
    var out: [max_regions]Region = undefined;
    const r = line(text, &out);
    try testing.expectEqual(@as(usize, max_regions), r.len);
    try testing.expectEqual(Region{ .column = 0, .kind = .number }, r[0]);
    try testing.expectEqual(Region{ .column = 2, .kind = .symbol }, r[1]);
    try testing.expectEqual(Region{ .column = 4, .kind = .number }, r[2]);
}

test "hostile: invalid UTF-8, NUL, unterminated string, tabs" {
    var out: [max_regions]Region = undefined;
    // Invalid UTF-8: no crash; stray bytes are symbols.
    _ = line("\xff\xfe const \xc3 x \x80\x80 \"\xff\" // \xc3", &out);
    _ = line("\xf0\x9f", &out);
    _ = line("\xef\xbb\xbfconst", &out);
    // A NUL inside the line ends the tokens; the rest is one symbol region.
    try expectRegions("const a\x00 = 1;", &.{
        .{ .column = 0, .kind = .keyword },
        .{ .column = 6, .kind = .symbol },
    });
    try expectRegions("\x00", &.{.{ .column = 0, .kind = .symbol }});
    // An unterminated string runs to the end of the line.
    try expectRegions("x = \"abc if 1", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 4, .kind = .string },
    });
    try expectRegions("x = 'a", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 4, .kind = .string },
    });
    try expectRegions("\"a\\", &.{.{ .column = 0, .kind = .string }});
    // Tabs inside `\\` lines and comments (the tokenizer calls them
    // invalid) keep the colour of the line.
    try expectRegions("\t\\\\ a\tb", &.{.{ .column = 1, .kind = .string }});
    try expectRegions("x // a\tb", &.{
        .{ .column = 0, .kind = .symbol },
        .{ .column = 2, .kind = .comment },
    });
    try expectRegions("/// a\tb", &.{.{ .column = 0, .kind = .doc_comment }});
    try expectRegions("//! a\tb", &.{.{ .column = 0, .kind = .doc_comment }});
    // A newline or carriage return inside the text (Godot's lines have
    // none) does not crash.
    _ = line("a // b\nif x\r\n\"c", &out);
    _ = line("\r", &out);
}
