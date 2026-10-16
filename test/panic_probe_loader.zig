//! Loads the panic probe library with the platform loader, gives it a fake
//! host whose log writes to stderr, and calls the function that panics.
const std = @import("std");
const platform = @import("ziggurat_platform");
const abi = @import("ziggurat_abi");

fn hostLog(level: u32, msg: [*]const u8, len: usize) callconv(.c) void {
    _ = level;
    _ = std.c.write(2, msg, len);
    _ = std.c.write(2, "\n", 1);
}

fn hostAlloc(gen: u32, size: usize, alignment: u32) callconv(.c) ?*anyopaque {
    _ = .{ gen, size, alignment };
    return null;
}

fn hostFree(gen: u32, ptr: ?*anyopaque, size: usize, alignment: u32) callconv(.c) void {
    _ = .{ gen, ptr, size, alignment };
}

fn hostSwap() callconv(.c) void {}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var diag: [256]u8 = undefined;
    const lib = platform.loader.open(init.gpa, init.io, .fromTrusted(args[1]), &diag) catch |err| {
        std.debug.print("loader: {t}: {s}\n", .{ err, std.mem.sliceTo(&diag, 0) });
        return err;
    };
    const Init = *const fn (*const abi.HostApi, u32) callconv(.c) void;
    const Boom = *const fn () callconv(.c) void;
    const probe_init = platform.loader.lookup(lib, Init, "probe_init") orelse return error.MissingInit;
    const probe_boom = platform.loader.lookup(lib, Boom, "probe_boom") orelse return error.MissingBoom;
    const api: abi.HostApi = .{
        .size = @sizeOf(abi.HostApi),
        .get_proc_address = null,
        .library = null,
        .alloc = hostAlloc,
        .free = hostFree,
        .log = hostLog,
        .request_swap = hostSwap,
    };
    probe_init(&api, 7);
    probe_boom();
}
