//! Build tool: writes the SDK module manifest that `src/build/sdk_manifest.zig` loads.
//!
//! Usage: sdk_manifest <out.json> <sdk_version> (<name> <root> <deps>)...
//!
//! `<deps>` is a comma-separated list of module names (empty for none).
//! Each root is resolved to an absolute real path, so it must exist.
const std = @import("std");
const builtin = @import("builtin");

const Module = struct {
    name: []const u8,
    root: []const u8,
    deps: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or (args.len - 3) % 3 != 0) {
        std.debug.print("usage: sdk_manifest <out.json> <sdk_version> (<name> <root> <deps>)...\n", .{});
        std.process.exit(2);
    }
    var modules: std.ArrayList(Module) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 3) {
        var deps: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, args[i + 2], ',');
        while (it.next()) |d| if (d.len != 0) try deps.append(arena, d);
        const root = std.Io.Dir.cwd().realPathFileAlloc(io, args[i + 1], arena) catch |err| {
            std.debug.print("sdk_manifest: root of module \"{s}\" ({s}): {t}\n", .{ args[i], args[i + 1], err });
            std.process.exit(1);
        };
        try modules.append(arena, .{ .name = args[i], .root = root, .deps = deps.items });
    }
    const manifest = .{
        .zig_version = builtin.zig_version_string,
        .sdk_version = args[2],
        .modules = modules.items,
    };
    const json = try std.json.Stringify.valueAlloc(arena, manifest, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = json });
}
