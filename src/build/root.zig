//! L2 build services: public surface.
const std = @import("std");
const platform = @import("ziggurat_platform");

pub const scan = @import("scan.zig");
pub const rootgen = @import("rootgen.zig");

test {
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(rootgen);
}

test "build module sees the platform module" {
    try std.testing.expectEqualStrings("0.17.0", platform.pins.zig_version);
}
