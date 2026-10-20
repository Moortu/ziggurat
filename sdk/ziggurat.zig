//! The Ziggurat SDK: the module user scripts import as `@import("ziggurat")`.
//!
//! It satisfies the root contract documented in `src/build/rootgen.zig`,
//! and gives scripts the curated Godot surface as `godot`.
//!
//! A script's `pub fn deinit(self: *@This()) void` runs while Godot is
//! destroying the owner object, so it must not use `base`; cleanup that
//! needs the owner belongs in `_notification` on NOTIFICATION_PREDELETE.
const std = @import("std");
const sdk_options = @import("sdk_options");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");
const names = @import("names.zig");
const describe_mod = @import("describe.zig");

/// The curated Godot surface: engine classes, builtin value types and
/// global enums under their Godot names, for example `ziggurat.godot.Node2D`.
/// See `sdk/godot.zig` for exactly what it holds.
pub const godot = @import("ziggurat_godot");

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
pub const MethodBind = names.MethodBind;
/// Warm-up of the SDK's lazy caches; `moduleInit` runs it. See `warm.zig`.
pub const warm = @import("warm.zig");
/// Checked conversion between Godot Variants and Zig values.
pub const convert = @import("convert.zig");
/// Object handles: `Obj(T)`, `Ref(T)` and the engine class check.
pub const object = @import("object.zig");
pub const Obj = object.Obj;
/// An owning RefCounted handle. A RefCounted from `T.init()` or returned by
/// an engine method (`ResourceLoader.load`, ...) carries one reference for
/// the caller: keep it with `.adopt(p)`, not `.set(p)`, which adds another
/// and leaks. `set` is for objects the caller does not own a reference to.
pub const Ref = object.Ref;
/// A return value that hands a new String, StringName, NodePath or Ref to
/// Godot. Plain return values are borrowed (Godot copies them).
pub const Owned = @import("own.zig").Owned;
/// Stores a Ref with its own reference and releases the old value.
/// Arguments are borrowed for the length of the call, so a method that
/// keeps one stores it with `assign`. Text goes in a `String`,
/// `StringName` or `NodePath` field with that field's `set`.
pub const assign = @import("own.zig").assign;
/// The owning text field types. A script field holds text as `z.String`,
/// `z.StringName` or `z.NodePath` (default `.empty`), never as the engine's
/// own `godot.String`, ... (a compile error). `self.name.set(v)` stores a
/// copy of the borrowed `v` and releases the old text; `self.name.get()`
/// gives a `*const` pointer to the text, borrowed from the field; a method
/// may return it as it is. Method arguments and return
/// values keep the engine types.
pub const String = @import("own.zig").String;
pub const StringName = @import("own.zig").StringName;
pub const NodePath = @import("own.zig").NodePath;

/// Emits a signal the script declares, checked at compile time:
/// `z.emit(self, .hit, .{ .damage = 3 })`. See `signal.zig`.
pub const emit = @import("signal.zig").emit;
/// What `emit` is built on; scripts call `emit`.
pub const signal = @import("signal.zig");

/// One script's descriptor (C ABI), built at compile time by `describe`.
pub const ScriptDescriptor = abi.ScriptDesc;

/// The module's table of scripts (C ABI), returned by `ziggurat_describe`.
pub const Table = abi.Table;

/// Builds the descriptor of the script `S` at the project-relative path
/// `rel`. A mistake in the script is a compile error that the build service
/// reports at the script's line; see `describe.zig`.
pub const describe = describe_mod.describe;

/// The layout stamp this module's table carries. A host computes the same
/// value with `ziggurat_abi.expectedStamp(sdk_options)`.
pub const layout_stamp: u64 = abi.expectedStamp(sdk_options);

/// The table over `descs`, which the generated root passes sorted by path,
/// with the build id the build service wrote into the root. After a fast
/// (incremental) rebuild the service reads the id back from the staged
/// library: a different id means the compiler kept stale code.
pub fn makeTable(comptime descs: []const *const ScriptDescriptor, comptime build_id: []const u8) Table {
    comptime describe_mod.checkTable(descs, version, build_id);
    const scripts = &Scripts(descs).list;
    return .{
        .magic = abi.magic,
        .abi_version = abi.abi_version,
        .size = @sizeOf(Table),
        .layout_stamp = layout_stamp,
        .sdk_version = .{ .ptr = version.ptr, .len = version.len },
        .build_id = .{ .ptr = build_id.ptr, .len = build_id.len },
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
