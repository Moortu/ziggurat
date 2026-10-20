//! The engine check of spec section 3: the host starts only in Godot 4.7.2
//! with single precision. Imports only std, so it tests without Godot.
const std = @import("std");

/// The one engine the host and its pinned bindings are built for.
pub const required_major = 4;
pub const required_minor = 7;
pub const required_patch = 2;

/// Holds the last refusal sentence. The host calls `checkEngine` once, from
/// its entry point on the main thread, before anything else runs.
var refusal_buf: [128]u8 = undefined;

/// Returns null when the engine is Godot 4.7.2 with single precision, else
/// the sentence that tells the user why the host does not start. The text
/// stays valid until the next call.
pub fn checkEngine(major: u32, minor: u32, patch: u32, is_double: bool) ?[]const u8 {
    if (major == required_major and minor == required_minor and patch == required_patch and !is_double) return null;
    return std.fmt.bufPrint(
        &refusal_buf,
        "Ziggurat needs Godot {d}.{d}.{d} (single precision), but this is Godot {d}.{d}.{d} ({s} precision).",
        .{ required_major, required_minor, required_patch, major, minor, patch, if (is_double) "double" else "single" },
    ) catch unreachable; // the longest text (three 10-digit numbers) fits in 128 bytes
}

test "host refuses wrong engine" {
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.7.1 (single precision).",
        checkEngine(4, 7, 1, false).?,
    );
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.8.0 (single precision).",
        checkEngine(4, 8, 0, false).?,
    );
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.7.2 (double precision).",
        checkEngine(4, 7, 2, true).?,
    );
    try std.testing.expect(checkEngine(4, 7, 2, false) == null);
    // The longest numbers still fit the buffer.
    const max = std.math.maxInt(u32);
    try std.testing.expect(checkEngine(max, max, max, true) != null);
}
