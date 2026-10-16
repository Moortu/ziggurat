//! The Ziggurat SDK: the module user scripts import as `@import("ziggurat")`.
//!
//! This is the skeleton. It satisfies the root contract documented in
//! `src/build/rootgen.zig` with the smallest code that compiles, and
//! re-exports gdzig as `godot`. Later work replaces the stub parts.
const std = @import("std");
const sdk_options = @import("sdk_options");

/// gdzig. Scripts reach Godot types through this, for example `ziggurat.godot.class.Node`.
pub const godot = @import("gdzig");

pub const version = sdk_options.sdk_version;

pub const Panic = std.debug.no_panic;

pub const HostApi = extern struct {};

pub const ScriptDescriptor = struct { name: []const u8, rel: []const u8 };

/// A Zig slice for now. The final `Table` crosses `dlopen` and must have an
/// `extern` layout (see the root contract).
pub const Table = []const *const ScriptDescriptor;

pub fn describe(comptime S: type, comptime rel: []const u8) ScriptDescriptor {
    // Resolve `extends`, so a script whose base type does not exist fails to build.
    if (@hasDecl(S, "extends")) _ = S.extends;
    return .{ .name = @typeName(S), .rel = rel };
}

pub fn makeTable(comptime descriptors: Table) Table {
    return descriptors;
}

pub fn moduleInit(api: *const HostApi, gen: u32) void {
    _ = api;
    _ = gen;
}
