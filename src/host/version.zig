//! The engine check of spec section 3: the host starts only in Godot 4.7.2
//! with single precision. Imports only std, so it tests without Godot.
const std = @import("std");

/// The one engine the host and its pinned bindings are built for.
pub const required_major = 4;
pub const required_minor = 7;
pub const required_patch = 2;

/// Holds the last refusal sentence. The host calls `checkEngine` only on the
/// main thread: from its entry point and again at SCENE init.
var refusal_buf: [128]u8 = undefined;

/// The engine's float precision. `unknown` (it could not be read) is refused:
/// the host fails closed.
pub const Precision = enum { single, double, unknown };

/// Returns null when the engine is Godot 4.7.2 with single precision, else
/// the sentence that tells the user why the host does not start. The text
/// stays valid until the next call.
pub fn checkEngine(major: u32, minor: u32, patch: u32, precision: Precision) ?[]const u8 {
    if (major == required_major and minor == required_minor and patch == required_patch and precision == .single) return null;
    return std.fmt.bufPrint(
        &refusal_buf,
        "Ziggurat needs Godot {d}.{d}.{d} (single precision), but this is Godot {d}.{d}.{d} ({t} precision).",
        .{ required_major, required_minor, required_patch, major, minor, patch, precision },
    ) catch unreachable; // the longest text (three 10-digit numbers) fits in 128 bytes
}

test "host refuses wrong engine" {
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.7.1 (single precision).",
        checkEngine(4, 7, 1, .single).?,
    );
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.8.0 (single precision).",
        checkEngine(4, 8, 0, .single).?,
    );
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.7.2 (double precision).",
        checkEngine(4, 7, 2, .double).?,
    );
    try std.testing.expectEqualStrings(
        "Ziggurat needs Godot 4.7.2 (single precision), but this is Godot 4.7.2 (unknown precision).",
        checkEngine(4, 7, 2, .unknown).?,
    );
    try std.testing.expect(checkEngine(4, 7, 2, .single) == null);
    // The longest numbers still fit the buffer.
    const max = std.math.maxInt(u32);
    try std.testing.expect(checkEngine(max, max, max, .unknown) != null);
}
