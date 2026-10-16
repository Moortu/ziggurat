//! The Ziggurat SDK: the module user scripts import as `@import("ziggurat")`.
//!
//! This is the skeleton. It satisfies the root contract documented in
//! `src/build/rootgen.zig` with the smallest code that compiles, and
//! re-exports gdzig as `godot`. Later work replaces the stub parts.
const std = @import("std");
const sdk_options = @import("sdk_options");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");
const names = @import("names.zig");

/// gdzig. Scripts reach Godot types through this, for example `ziggurat.godot.class.Node`.
pub const godot = @import("gdzig");

pub const version = sdk_options.sdk_version;

/// The SDK's panic handler: logs `Zig panic: <msg>` through the host, then traps.
pub const Panic = runtime.Panic;

pub const HostApi = abi.HostApi;
pub const LogLevel = abi.LogLevel;
pub const moduleInit = runtime.moduleInit;
pub const generation = runtime.generation;
pub const log = runtime.log;
pub const allocator = runtime.allocator;
pub const StaticName = names.StaticName;
/// Checked conversion between Godot Variants and Zig values.
pub const convert = @import("convert.zig");

pub const ScriptDescriptor = struct { name: []const u8, rel: []const u8 };

/// A Zig slice for now. The final `Table` crosses `dlopen` and must have an
/// `extern` layout (see the root contract).
pub const Table = []const *const ScriptDescriptor;

pub fn describe(comptime S: type, comptime rel: []const u8) ScriptDescriptor {
    // Resolve `extends`, so a script whose base type does not exist fails to build.
    if (@hasDecl(S, "extends")) _ = S.extends;
    // Analyse the generated options module, so a broken one fails every build.
    _ = version;
    _ = sdk_options.api_json_sha256;
    _ = sdk_options.interface_h_sha256;
    _ = sdk_options.precision;
    return .{ .name = @typeName(S), .rel = rel };
}

pub fn makeTable(comptime descriptors: Table) Table {
    return descriptors;
}
