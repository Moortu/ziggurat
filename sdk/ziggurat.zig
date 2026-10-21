//! The Ziggurat SDK: the module user scripts import as `@import("ziggurat")`.
//!
//! It satisfies the root contract documented in `src/build/rootgen.zig`,
//! and gives scripts the curated Godot surface as `godot`.
//!
//! A script's `pub fn deinit(self: *@This()) void` runs while Godot is
//! destroying the owner object, so it must not use `base`; cleanup that
//! needs the owner belongs in `_notification` on NOTIFICATION_PREDELETE.
//!
//! State migration (spec sections 6 and 8): when a script's code changes,
//! each live instance moves into the new code. Before anything of the
//! script runs, the host copies into the new instance every field whose
//! name and exact type are unchanged (text and `Ref` fields included: their
//! values move, they are not copied) and leaves every other field at its
//! default; `init` does not run. Then it calls the script's optional
//! `pub fn migrate(self: *@This(), old: z.Previous(@This())) void`, so
//! `migrate` is only for renames and conversions:
//!
//!     pub fn migrate(self: *@This(), old: z.Previous(@This())) void {
//!         if (old.get(i32, "hp")) |hp| self.health = hp; // renamed
//!         if (old.get(i32, "count")) |c| self.count = @intCast(@max(c, 0)); // i32 -> u32
//!         _ = old.takeInto(z.String, &self.memo, "note"); // renamed text
//!     }
//!
//! `old.get(T, "name")` copies a plain value (bool, numbers, enums, packed
//! flags, vectors, `z.Obj`, and structs or arrays of those);
//! `old.take(T, "name")` moves a `z.String`, `z.StringName`, `z.NodePath`
//! or `z.Ref` out of the old instance. Both give null unless the old field
//! exists with exactly the type `T` (same name, same layout inside), and
//! `take` gives null for a value already moved (by the host or an earlier
//! `take`). `old.takeInto(T, &self.field, "name")` moves the value straight
//! into a field and releases what the field held first: use it whenever
//! the field may already hold a value (the host fills a field whose name
//! and type the old instance shared). A value from `take` belongs to
//! `migrate`: store it in a field known to be empty, or release it;
//! `self.f.set(v.get())` copies it, so `v` must still be released.
//! Owned values (`z.String`, `z.StringName`, `z.NodePath`, `z.Ref`) may
//! only be top-level fields, never inside a struct, array, optional or
//! union field. The host resets every moved old field before the old
//! instance's `deinit`, so each value is released once. When the
//! script's layout did not change, the data stays in place and `migrate`
//! does not run. Calls from `migrate` back into script instances are not
//! supported (spec section 6).
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
/// The old instance during a migration, as `migrate` gets it; see the top
/// of this file and `previous.zig`.
pub const Previous = @import("previous.zig").Previous;

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

/// The longest build id `tableOf` accepts. The build service writes 16
/// hex characters; `scriptList` counts this many bytes for it in the
/// table's string budget, so `tableOf` needs no check over the scripts.
pub const max_build_id_len = 16;

/// The descriptors `descs`, which the generated root passes sorted by
/// path, checked against the validator's whole-table limits and copied
/// into one static array, as `Table.scripts` needs. It does not take the
/// build id, so its result (and its check) stays the same from one build to
/// the next until a descriptor changes; see the root contract in
/// `src/build/rootgen.zig`.
pub fn scriptList(comptime descs: []const *const ScriptDescriptor) []const ScriptDescriptor {
    comptime describe_mod.checkTable(descs, version, max_build_id_len);
    return &Scripts(descs).list;
}

/// The table over `scripts` (from `scriptList`) with the build id the
/// build service wrote into the root. After a fast (incremental) rebuild
/// the service reads the id back from the staged library: a different id
/// means the compiler kept stale code. No loops, so the per-build id costs
/// almost nothing to analyse.
pub fn tableOf(comptime scripts: []const ScriptDescriptor, comptime build_id: []const u8) Table {
    if (build_id.len > max_build_id_len)
        @compileError(std.fmt.comptimePrint("ziggurat: the build id has {d} bytes; the limit is {d}.", .{ build_id.len, max_build_id_len }));
    return .{
        .magic = abi.magic,
        .abi_version = abi.abi_version,
        .size = @sizeOf(Table),
        .layout_stamp = layout_stamp,
        .sdk_version = .{ .ptr = version.ptr, .len = version.len },
        .build_id = .{ .ptr = build_id.ptr, .len = build_id.len },
        .scripts = scripts.ptr,
        .script_count = scripts.len,
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
