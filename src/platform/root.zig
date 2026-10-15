//! L1 platform services: public surface.
const std = @import("std");
const build_options = @import("build_options");

pub const pins = @import("pins.zig");
pub const path = @import("path.zig");
pub const elf = @import("elf.zig");
pub const loader = @import("loader.zig");
pub const testing_support = @import("testing_support.zig");

test {
    std.testing.refAllDecls(path);
    std.testing.refAllDecls(elf);
    std.testing.refAllDecls(loader);
}

test "pins" {
    try std.testing.expectEqualStrings("0.17.0", pins.zig_version);
}

test "integration: zig_exe exists" {
    try testing_support.requireIntegration();
    try std.testing.expect(build_options.zig_exe.len != 0);
    try std.Io.Dir.cwd().access(std.testing.io, build_options.zig_exe, .{});
}
