//! L1 platform services: public surface.
const std = @import("std");
const build_options = @import("build_options");

pub const pins = @import("pins.zig");
pub const path = @import("path.zig");

test {
    std.testing.refAllDecls(path);
}

test "pins" {
    try std.testing.expectEqualStrings("0.17.0", pins.zig_version);
}

test "integration: zig_exe exists" {
    if (!build_options.run_integration) return error.SkipZigTest;
    try std.testing.expect(build_options.zig_exe.len != 0);
    try std.Io.Dir.cwd().access(std.testing.io, build_options.zig_exe, .{});
}
