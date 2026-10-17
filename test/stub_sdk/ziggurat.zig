//! Stub SDK for tests. It satisfies the root contract documented in
//! `src/build/rootgen.zig` with the smallest code that compiles, and imports
//! neither gdzig nor Godot.

pub const Panic = @import("std").debug.no_panic;

pub const HostApi = extern struct {};

pub const ScriptDescriptor = struct { name: []const u8, rel: []const u8 };

/// A Zig slice keeps the stub short. The real SDK's `Table` crosses `dlopen`
/// and must have an `extern` layout (see the root contract).
pub const Table = []const *const ScriptDescriptor;

pub fn describe(comptime S: type, comptime rel: []const u8) ScriptDescriptor {
    return .{ .name = @typeName(S), .rel = rel };
}

/// The build id is not kept: the stub table has no field for it.
pub fn makeTable(comptime descriptors: Table, comptime build_id: []const u8) Table {
    _ = build_id;
    return descriptors;
}

pub fn moduleInit(api: *const HostApi, gen: u32) void {
    _ = api;
    _ = gen;
}
