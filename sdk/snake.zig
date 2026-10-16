//! Zig camelCase names to Godot snake_case names. A copy of Godot 4.7.2
//! `String::to_snake_case` and `String::_separate_compound_words`
//! (core/string/ustring.cpp), limited to ASCII because Zig identifiers are
//! ASCII. Imports only std.

const std = @import("std");

pub const Error = error{ NotAscii, NoSpaceLeft };

/// Runtime twin of `toSnakeCase`. `buf` must hold the result, which is at
/// most `2 * name.len - 1` bytes. Both functions share `convert`.
pub fn toSnakeCaseBuf(buf: []u8, name: []const u8) Error![]const u8 {
    const n = try convert(buf, name);
    return buf[0..n];
}

/// Comptime conversion. A non-ASCII name is a compile error.
pub fn toSnakeCase(comptime name: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(1000 + 100 * name.len);
        var buf: [name.len * 2]u8 = undefined;
        const n = convert(&buf, name) catch |err| switch (err) {
            error.NotAscii => @compileError("name is not ASCII: " ++ name),
            error.NoSpaceLeft => unreachable, // 2n bytes always fit
        };
        const out: [n]u8 = buf[0..n].*;
        return &out;
    }
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Godot `is_whitespace`, ASCII part: space and 0x09 to 0x0d.
fn isSeparator(c: u8) bool {
    return c == ' ' or (c >= 0x09 and c <= 0x0d) or c == '_' or c == '-';
}

/// `_separate_compound_words()` then `replace_char(' ', '_')`, in one pass:
/// a word boundary inserts one `_`, whitespace, `_` and `-` become `_`, and
/// letters are lowercased. Nothing is stripped.
fn convert(out: []u8, name: []const u8) Error!usize {
    for (name) |c| if (c >= 0x80) return error.NotAscii;
    if (name.len == 0) return 0;

    var len: usize = 0;
    var prev_upper = isUpper(name[0]);
    var prev_lower = isLower(name[0]);
    var prev_digit = isDigit(name[0]);
    try put(out, &len, name[0]);

    for (1..name.len) |i| {
        const c = name[i];
        const curr_upper = isUpper(c);
        const curr_lower = isLower(c);
        const curr_digit = isDigit(c);
        const next_lower = i + 1 < name.len and isLower(name[i + 1]);

        const cond_a = prev_lower and curr_upper; // aA
        const cond_b = (prev_upper or prev_digit) and curr_upper and next_lower; // AAa, 2Aa
        const cond_c = prev_digit and curr_lower and next_lower; // 2aa
        const cond_d = (prev_upper or prev_lower) and curr_digit; // A2, a2
        if (cond_a or cond_b or cond_c or cond_d) try put(out, &len, '_');

        try put(out, &len, c);
        prev_upper = curr_upper;
        prev_lower = curr_lower;
        prev_digit = curr_digit;
    }
    return len;
}

fn put(out: []u8, len: *usize, c: u8) Error!void {
    if (len.* >= out.len) return error.NoSpaceLeft;
    out[len.*] = if (isSeparator(c)) '_' else if (isUpper(c)) c + ('a' - 'A') else c;
    len.* += 1;
}

const Case = struct { in: []const u8, out: []const u8 };

// Every ASCII row of Godot's "Checking case conversion methods" test, verbatim.
const godot_cases = [_]Case{
    .{ .in = "2D", .out = "2d" },
    .{ .in = "2d", .out = "2d" },
    .{ .in = "2db", .out = "2_db" },
    .{ .in = "Vector3", .out = "vector_3" },
    .{ .in = "sha256", .out = "sha_256" },
    .{ .in = "Node2D", .out = "node_2d" },
    .{ .in = "RichTextLabel", .out = "rich_text_label" },
    .{ .in = "HTML5", .out = "html_5" },
    .{ .in = "Node2DPosition", .out = "node_2d_position" },
    .{ .in = "Number2Digits", .out = "number_2_digits" },
    .{ .in = "get_property_list", .out = "get_property_list" },
    .{ .in = "get_camera_2d", .out = "get_camera_2d" },
    .{ .in = "_physics_process", .out = "_physics_process" },
    .{ .in = "bytes2var", .out = "bytes_2_var" },
    .{ .in = "linear2db", .out = "linear_2_db" },
    .{ .in = "sha256sum", .out = "sha_256_sum" },
    .{ .in = "camelCase", .out = "camel_case" },
    .{ .in = "PascalCase", .out = "pascal_case" },
    .{ .in = "snake_case", .out = "snake_case" },
    .{ .in = "kebab-case", .out = "kebab_case" },
    .{ .in = "Test TEST test", .out = "test_test_test" },
};

// Task vectors.
const task_cases = [_]Case{
    .{ .in = "HTTPUrl", .out = "http_url" },
    .{ .in = "vec2", .out = "vec_2" },
    .{ .in = "getHealthHUD", .out = "get_health_hud" },
    .{ .in = "_physicsProcess", .out = "_physics_process" },
    .{ .in = "takeDamage", .out = "take_damage" },
};

test "godot vectors, runtime" {
    var buf: [64]u8 = undefined;
    for (godot_cases ++ task_cases) |c| {
        try std.testing.expectEqualStrings(c.out, try toSnakeCaseBuf(&buf, c.in));
    }
}

test "godot vectors, comptime" {
    inline for (godot_cases ++ task_cases) |c| {
        try std.testing.expectEqualStrings(c.out, comptime toSnakeCase(c.in));
    }
}

test "empty name" {
    var buf: [1]u8 = undefined;
    try std.testing.expectEqualStrings("", try toSnakeCaseBuf(&buf, ""));
    try std.testing.expectEqualStrings("", comptime toSnakeCase(""));
}

test "non-ASCII is rejected, not panicked on" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.NotAscii, toSnakeCaseBuf(&buf, "словоСлово"));
    try std.testing.expectError(error.NotAscii, toSnakeCaseBuf(&buf, "a\x80"));
}

test "buffer too small is an error" {
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, toSnakeCaseBuf(&buf, "takeDamage"));
    // Exactly enough: "aB" -> "a_b" needs 3.
    try std.testing.expectEqualStrings("a_b", try toSnakeCaseBuf(&buf, "aB"));
}

test "worst case output is 2n - 1 bytes" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("a_a_1", try toSnakeCaseBuf(&buf, "aA1"));
}

test "separators and edges are kept, not stripped" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("__a__b_", try toSnakeCaseBuf(&buf, "__a- b\t"));
    try std.testing.expectEqualStrings("a\x01b", try toSnakeCaseBuf(&buf, "a\x01b"));
}
