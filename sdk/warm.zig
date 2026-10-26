//! Warm-up of the SDK's lazy caches (spec section 3).
//!
//! Every cache the SDK fills on first use (`StaticName` names, method binds,
//! gdzig's cached names and builtin functions behind the SDK's own calls) is
//! safe to fill from any thread: it is published with release ordering and
//! read with acquire ordering (`names.zig`; gdzig patch 5). Godot 4 may run
//! script code on other threads (thread groups), and threads that race to
//! fill one cache each keep one extra reference to a static name, so
//! `moduleInit` still fills these caches on the main thread, before any
//! script code runs:
//!
//! - `sdk()`: the `is_class` and `emit_signal` method binds and the names
//!   they need, gdzig's `RefCounted` name (used by `ClassDB.instantiate`),
//!   gdzig's copy and destroy functions of String, StringName and NodePath
//!   (used by `assign` and the wrappers), and the `init_ref`, `reference`
//!   and `unreference` binds behind `Ref` (it makes and frees one
//!   RefCounted, so it needs a running Godot that can construct objects;
//!   `moduleInit` calls it only with a real proc table).
//! - `fromRoot(@import("root"))`: for each script descriptor of the
//!   generated root, the class name of every property and method argument
//!   (the names of the class checks those values go through) and every
//!   signal name (used by `emit`).
//!
//! Still lazy, filled on first use on whichever thread comes first: class
//! checks on types that appear in no descriptor (private fields, local
//! handles), names given to `Callable.init`, and the method binds gdzig
//! caches inside other engine class methods scripts call.
const std = @import("std");
const abi = @import("ziggurat_abi");
const godot = @import("gdzig");
const names = @import("names.zig");
const object = @import("object.zig");
const signal = @import("signal.zig");
const runtime = @import("runtime.zig");

/// Fills every SDK cache, logging a missing method bind once. Called by
/// `moduleInit` once gdzig is initialised; needs a running Godot.
pub fn all() void {
    sdk();
    fromRoot(@import("root"));
}

/// The SDK's own caches (see the file comment).
pub fn sdk() void {
    if (object.IsClass.get() == null)
        runtime.log(.err, "ziggurat: Godot has no method bind for Object.is_class; every object argument will read as null.", .{});
    if (signal.EmitSignal.get() == null)
        runtime.log(.err, "ziggurat: Godot has no method bind for Object.emit_signal; every emit will be skipped.", .{});
    if (signal.HasSignal.get() == null)
        runtime.log(.err, "ziggurat: Godot has no method bind for Object.has_signal; an emit of a signal Godot does not know is not reported.", .{});
    _ = godot.builtin.StringName.fromComptimeLatin1("RefCounted");
    inline for (.{ godot.builtin.String, godot.builtin.StringName, godot.builtin.NodePath }) |T| {
        const empty = std.mem.zeroes(T);
        var copy = T.copy(empty);
        copy.deinit();
    }
    // `Ref`'s gdzig binds: `init_ref` (in `init`), `reference` (in `set`)
    // and `unreference` (in `release`), with one throwaway object.
    const RefCounted = godot.class.RefCounted;
    var first: object.Ref(RefCounted) = .adopt(RefCounted.init());
    var second: object.Ref(RefCounted) = .{};
    second.set(first.get());
    second.release();
    first.release();
}

/// True when the SDK's own method binds have been looked up.
pub fn sdkReady() bool {
    return object.IsClass.isReady() and signal.EmitSignal.isReady() and signal.HasSignal.isReady();
}

/// Warms the names of every script descriptor `R` declares as `pub const
/// s<i>`, as the generated root does. Any other root has none.
pub fn fromRoot(comptime R: type) void {
    if (@typeInfo(R) != .@"struct") return;
    const decls = @typeInfo(R).@"struct".decl_names;
    @setEvalBranchQuota(10_000 + 100 * decls.len);
    inline for (decls) |d| {
        if (comptime signal.isScriptDecl(d) and @TypeOf(@field(R, d)) == abi.ScriptDesc) script(&@field(R, d));
    }
}

/// Warms the class-check names and signal names of one descriptor.
pub fn script(comptime d: *const abi.ScriptDesc) void {
    @setEvalBranchQuota(10_000 + 1_000 * (d.property_count + d.method_count + d.signal_count));
    inline for (comptime d.properties[0..d.property_count]) |p| {
        if (comptime p.field_index != abi.no_field) warmName(p.class_name);
    }
    inline for (comptime d.methods[0..d.method_count]) |m| {
        inline for (comptime m.args[0..m.arg_count]) |a| warmName(a.class_name);
    }
    inline for (comptime d.signals[0..d.signal_count]) |g| warmName(g.name);
}

fn warmName(comptime s: abi.Str) void {
    if (s.len == 0) return;
    _ = names.StaticName(comptime s.ptr.?[0..s.len]).ptr();
}
