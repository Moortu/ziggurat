//! Stub SDK for tests. It satisfies the root contract documented in
//! `src/build/rootgen.zig` with the smallest code that compiles, and imports
//! neither gdzig nor Godot.

pub const Panic = @import("std").debug.no_panic;

pub const HostApi = extern struct {};

pub const ScriptDescriptor = struct { name: []const u8 };

pub const Table = []const *const ScriptDescriptor;

pub fn describe(comptime S: type) ScriptDescriptor {
    return .{ .name = @typeName(S) };
}

pub fn makeTable(comptime descriptors: Table) Table {
    return descriptors;
}

pub fn moduleInit(api: *const HostApi, gen: u32) void {
    _ = api;
    _ = gen;
}
