//! Message formatting for the SDK's logger and panic handler. Imports only
//! `std`, so it tests without gdzig. Nothing here allocates or touches
//! `std.debug` printing or any `std.Io`.
const std = @import("std");

pub const ellipsis = "...";

/// Formats `fmt` with `args` into `buf`. If the text does not fit, the result
/// fills `buf` and ends with `...`. Never fails.
pub fn formatTruncated(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {
        if (buf.len < ellipsis.len) return buf;
        // Cut at a code point boundary, so the result stays valid UTF-8 when
        // the text was: drop an incomplete sequence before the ellipsis.
        var end = buf.len - ellipsis.len;
        while (end > 0 and !utf8Complete(buf[0..end])) end -= 1;
        @memcpy(buf[end..][0..ellipsis.len], ellipsis);
        return buf[0 .. end + ellipsis.len];
    };
    return w.buffered();
}

/// True if `s` does not end inside a multi-byte sequence (or is not UTF-8 at
/// its end at all: then the cut is left where it is).
fn utf8Complete(s: []const u8) bool {
    if (s.len == 0) return true;
    // Find the last lead byte within 3 bytes of the end.
    var i = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        const b = s[i];
        if (b & 0xC0 == 0x80) continue; // continuation byte
        const need = std.unicode.utf8ByteSequenceLength(b) catch return true;
        return s.len - i >= need;
    }
    return true;
}

const testing = std.testing;

test "panic message format: short message keeps the prefix" {
    var buf: [1024]u8 = undefined;
    const s = formatTruncated(&buf, "Zig panic: {s}", .{"probe"});
    try testing.expectEqualStrings("Zig panic: probe", s);
}

test "panic message format: truncates at 1024 with an ellipsis" {
    var buf: [1024]u8 = undefined;
    const long: [2000]u8 = @splat('x');
    const s = formatTruncated(&buf, "Zig panic: {s}", .{long});
    try testing.expectEqual(@as(usize, 1024), s.len);
    try testing.expect(std.mem.startsWith(u8, s, "Zig panic: xxx"));
    try testing.expect(std.mem.endsWith(u8, s, "xx..."));
}

test "panic message format: exact fit is not truncated" {
    var buf: [16]u8 = undefined;
    const s = formatTruncated(&buf, "{s}", .{"0123456789abcdef"});
    try testing.expectEqualStrings("0123456789abcdef", s);
}

test "panic message format: a multi-byte character at the cut stays valid UTF-8" {
    // "é" is 2 bytes; with a 16-byte buffer the ellipsis would start inside it
    // for some prefix lengths. Try every prefix length around the cut.
    var pad: usize = 8;
    while (pad < 16) : (pad += 1) {
        var buf: [16]u8 = undefined;
        const s = formatTruncated(&buf, "{s}{s}", .{ "xxxxxxxxxxxxxxxx"[0..pad], "ééééééééé" });
        try testing.expect(std.unicode.utf8ValidateSlice(s));
        try testing.expect(std.mem.endsWith(u8, s, "..."));
        try testing.expect(s.len <= 16);
    }
    // 3- and 4-byte characters.
    var buf: [16]u8 = undefined;
    const s3 = formatTruncated(&buf, "{s}", .{"xxxxxxxxxxxx€€€€€€€€"});
    try testing.expect(std.unicode.utf8ValidateSlice(s3));
    const s4 = formatTruncated(&buf, "{s}", .{"xxxxxxxxxxx\u{1F600}\u{1F600}\u{1F600}"});
    try testing.expect(std.unicode.utf8ValidateSlice(s4));
}
