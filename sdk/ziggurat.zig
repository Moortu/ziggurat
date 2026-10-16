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
const describe_mod = @import("describe.zig");
const builtin = @import("builtin");

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
/// Object handles: `Obj(T)`, `Ref(T)` and the engine class check.
pub const object = @import("object.zig");
pub const Obj = object.Obj;
pub const Ref = object.Ref;

/// One script's descriptor (C ABI), built at compile time by `describe`.
pub const ScriptDescriptor = abi.ScriptDesc;

/// The module's table of scripts (C ABI), returned by `ziggurat_describe`.
pub const Table = abi.Table;

/// Builds the descriptor of the script `S` at the project-relative path
/// `rel`. A mistake in the script is a compile error that the build service
/// reports at the script's line; see `describe.zig`.
pub const describe = describe_mod.describe;

/// The target part of the layout stamp: `<arch>-<os>-<abi>` as Zig names them.
pub const stamp_target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);

/// The layout stamp this module's table carries. A host computes the same
/// value from its own build facts with `ziggurat_abi.layoutStamp`.
pub const layout_stamp: u64 = abi.layoutStamp(.{
    .api_json_sha256 = &sdk_options.api_json_sha256,
    .interface_h_sha256 = &sdk_options.interface_h_sha256,
    .zig_version = builtin.zig_version_string,
    .target = stamp_target,
    .precision = sdk_options.precision,
    .sdk_version = version,
});

/// The table over `descs`, which the generated root passes sorted by path.
/// The build id stays empty for now.
pub fn makeTable(comptime descs: []const *const ScriptDescriptor) Table {
    const scripts = &Scripts(descs).list;
    return .{
        .magic = abi.magic,
        .abi_version = abi.abi_version,
        .size = @sizeOf(Table),
        .layout_stamp = layout_stamp,
        .sdk_version = .{ .ptr = version.ptr, .len = version.len },
        .build_id = .{ .ptr = null, .len = 0 },
        .scripts = scripts,
        .script_count = descs.len,
    };
}

/// The descriptors copied into one static array, as `Table.scripts` needs.
fn Scripts(comptime descs: []const *const ScriptDescriptor) type {
    return struct {
        const list: [descs.len]ScriptDescriptor = blk: {
            var out: [descs.len]ScriptDescriptor = undefined;
            for (descs, 0..) |d, i| out[i] = d.*;
            break :blk out;
        };
    };
}
