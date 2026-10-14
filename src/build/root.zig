//! L2 build services: public surface.
const std = @import("std");
const platform = @import("ziggurat_platform");

test "build module sees the platform module" {
    try std.testing.expectEqualStrings("0.17.0", platform.pins.zig_version);
}
