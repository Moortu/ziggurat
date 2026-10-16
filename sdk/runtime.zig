//! SDK runtime: the host's HostApi, gdzig initialisation, logging, the shared
//! user allocator and the SDK's own panic handler.
//!
//! The panic handler never uses `std.debug` printing, `debug_io` or any
//! `std.Io`: `std.debug.simple_panic` does not compile in a `-lc` dynamic
//! library in Zig 0.17.0. It formats into a fixed buffer instead.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("ziggurat_abi");
const godot = @import("gdzig");
const fmtlog = @import("fmtlog.zig");

pub const HostApi = abi.HostApi;

var host: ?*const HostApi = null;
var gen: u32 = 0;

/// Size of the stack buffer for one log line or panic message.
const line_max = 1024;

/// Stores `api` and `gen`, and points gdzig at the host's function table
/// (bindings-only mode). Runs once on the main thread, right after load.
///
/// If `api.size` is not `@sizeOf(HostApi)` the host and this module disagree
/// on the layout: the call logs an error if the log function is inside the
/// struct the host gave, and returns without setting anything.
///
/// Lazy-cache warming belongs here. The SDK itself caches nothing beyond
/// `StaticName` values yet; later tasks register their caches in this
/// function, so every cache is filled on the main thread before other threads
/// can race on it.
pub fn moduleInit(api: *const HostApi, generation_number: u32) void {
    if (api.size != @sizeOf(HostApi)) {
        const log_end = @offsetOf(HostApi, "log") + @sizeOf(@FieldType(HostApi, "log"));
        if (api.size >= log_end) {
            var buf: [128]u8 = undefined;
            const msg = fmtlog.formatTruncated(&buf, "ziggurat: HostApi size mismatch: host {d}, module {d}", .{ api.size, @sizeOf(HostApi) });
            api.log(@backingInt(abi.LogLevel.err), msg.ptr, msg.len);
        }
        return;
    }
    host = api;
    gen = generation_number;
    // A host without a proc table cannot back gdzig; only a test host does that.
    const get_proc = api.get_proc_address orelse return log(.warning, "no get_proc_address: gdzig left uninitialised", .{});
    const library = api.library orelse return log(.warning, "no library: gdzig left uninitialised", .{});
    godot.raw = .init(@ptrCast(@alignCast(get_proc)), @ptrCast(library));
    godot.raw.getGodotVersion(@ptrCast(&godot.version));
}

/// The generation number the host gave `moduleInit`.
pub fn generation() u32 {
    return gen;
}

/// Writes one line through the host's log. Longer text is cut to 1024 bytes
/// and ends with `...`. Does nothing before `moduleInit`.
pub fn log(level: abi.LogLevel, comptime fmt: []const u8, args: anytype) void {
    const h = host orelse return;
    var buf: [line_max]u8 = undefined;
    const msg = fmtlog.formatTruncated(&buf, fmt, args);
    h.log(@backingInt(level), msg.ptr, msg.len);
}

/// The shared user heap, over `HostApi.alloc` and `free` with generation tag
/// 0. The host counts it under `live_bytes(0)`, independent of generation.
/// `self` is unused in v1. Before `moduleInit`, allocation fails.
pub fn allocator(self: anytype) std.mem.Allocator {
    _ = self;
    return .{ .ptr = undefined, .vtable = &heap_vtable };
}

const user_heap_tag: u32 = 0;

const heap_vtable: std.mem.Allocator.VTable = .{
    .alloc = heapAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = heapFree,
};

fn heapAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const h = host orelse return null;
    const p = h.alloc(user_heap_tag, len, @intCast(alignment.toByteUnits())) orelse return null;
    return @ptrCast(p);
}

fn heapFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const h = host orelse return;
    h.free(user_heap_tag, memory.ptr, memory.len, @intCast(alignment.toByteUnits()));
}

/// Set once a panic starts, so a panic inside the handler traps at once.
var panicking = std.atomic.Value(bool).init(false);

fn panicHandler(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    if (panicking.swap(true, .acq_rel)) @trap();
    var buf: [line_max]u8 = undefined;
    const line = fmtlog.formatTruncated(&buf, "Zig panic: {s}", .{msg});
    if (host) |h| {
        h.log(@backingInt(abi.LogLevel.err), line.ptr, line.len);
    } else {
        writeStderr(line);
        writeStderr("\n");
    }
    @trap();
}

/// A raw write to fd 2, for a panic before a host is set. Where there is no
/// such call (Windows) it does nothing.
fn writeStderr(bytes: []const u8) void {
    switch (builtin.os.tag) {
        .windows, .wasi, .freestanding, .uefi => {},
        else => {
            var rest = bytes;
            while (rest.len > 0) {
                const rc = std.posix.system.write(2, rest.ptr, rest.len);
                if (rc <= 0) return;
                rest = rest[@intCast(rc)..];
            }
        },
    }
}

/// The panic namespace for a module root: `pub const panic = ziggurat.Panic;`.
pub const Panic = std.debug.FullPanic(panicHandler);
