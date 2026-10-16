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
        if (buf.len >= ellipsis.len) {
            @memcpy(buf[buf.len - ellipsis.len ..], ellipsis);
        }
        return buf;
    };
    return w.buffered();
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
