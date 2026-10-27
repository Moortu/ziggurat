//! `macho_fat <out> <in-arm64> <in-x86_64>`: joins a thin arm64 dylib and
//! a thin x86_64 dylib into one universal (fat) file, x86_64 then arm64,
//! each slice aligned to 2^14, as `lipo -create` writes it. The output is
//! the same bytes for the same inputs. The join and its checks are
//! src/platform/macho_fat.zig; this is only the command line.
const std = @import("std");
const Io = std.Io;
const macho_fat = @import("macho_fat");

/// The largest input read (a thin host library is a few MB).
const max_input = 1 << 30;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: macho_fat <out> <in-arm64> <in-x86_64>\n", .{});
        std.process.exit(2);
    }
    const cwd = Io.Dir.cwd();
    var inputs: [2][]const u8 = undefined;
    for (&inputs, args[2..4]) |*in, p| {
        in.* = cwd.readFileAlloc(io, p, arena, .limited(max_input)) catch |err|
            fail("cannot read {s} ({t})", .{ p, err });
    }
    var diag: [256]u8 = @splat(0);
    const out = macho_fat.join(arena, inputs[0], inputs[1], &diag) catch |err|
        fail("{s} + {s}: {s} ({t})", .{ args[2], args[3], std.mem.sliceTo(&diag, 0), err });
    cwd.writeFile(io, .{ .sub_path = args[1], .data = out }) catch |err|
        fail("cannot write {s} ({t})", .{ args[1], err });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("macho_fat: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
