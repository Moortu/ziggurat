//! Test program for the SDK panic handler. It installs a fake host whose log
//! writes to stderr, then panics. Run by the integration test in
//! `sdk_e2e.zig`, which checks stderr and that the process died by a signal.
const std = @import("std");
const z = @import("ziggurat");

pub const panic = z.Panic;

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

pub fn main() void {
    const api: z.HostApi = .{
        .size = @sizeOf(z.HostApi),
        .get_proc_address = null,
        .library = null,
        .alloc = hostAlloc,
        .free = hostFree,
        .log = hostLog,
        .request_swap = hostSwap,
    };
    z.moduleInit(&api, 7);
    @panic("probe");
}
