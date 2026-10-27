//! L2 build services: public surface.
const std = @import("std");
const platform = @import("ziggurat_platform");

pub const scan = @import("scan.zig");
pub const rootgen = @import("rootgen.zig");
pub const workspace = @import("workspace.zig");
pub const compiler = @import("compiler.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const backend = @import("backend.zig");
pub const service = @import("service.zig");
pub const sdk_manifest = @import("sdk_manifest.zig");
pub const export_build = @import("export_build.zig");

test {
    std.testing.refAllDecls(scan);
    std.testing.refAllDecls(rootgen);
    std.testing.refAllDecls(workspace);
    std.testing.refAllDecls(compiler);
    std.testing.refAllDecls(diagnostics);
    std.testing.refAllDecls(backend);
    std.testing.refAllDecls(service);
    std.testing.refAllDecls(sdk_manifest);
    std.testing.refAllDecls(export_build);
    _ = @import("windows_paths_test.zig");
}

test "build module sees the platform module" {
    try std.testing.expectEqualStrings("0.17.0", platform.pins.zig_version);
}
