//! Script instances (spec sections 2 and 7): what Godot holds for an object
//! that has a Zig script attached.
//!
//! `create` makes the module-side instance through the descriptor's
//! `create` and wraps it in Godot's `ScriptInstanceExtension` with the
//! `GDExtensionScriptInstanceInfo3` table `info` below. Godot then reaches
//! the script through that table: properties by name, calls, notifications
//! and the rest. The host turns names into the descriptor's indexes with the
//! generation's name maps (`names.zig`) and follows the host contract of
//! `src/abi/abi.zig`.
//!
//! The record (`Instance`) holds the owner, a strong reference to the
//! script (taken in `create`, dropped in `free`), the generation and script
//! index whose descriptor made the module instance, and the module's
//! instance pointer. Generations are never freed, so the descriptor stays
//! valid for the record's lifetime.
//!
//! Godot facts the callbacks rely on (core/object/script_language_extension.h,
//! `ScriptInstanceExtension`, lines 701-934 in Godot 4.7.2):
//! - `get`, `property_get_revert` and `call` write into a Variant that the
//!   caller constructed (`Variant &r_ret`; `callp` makes `Variant ret;` at
//!   848). The host lets the module write into a nil Variant of its own and
//!   moves the result over the caller's after destroying what it held.
//! - `callp` copies the call error out of the struct it passed (851-854)
//!   and reads it whatever happened, so `call` always writes it.
//! - `to_string` reads `r_is_valid` uninitialised otherwise (871), so it is
//!   always written.
//! - `get_property_list` and `get_method_list` hand each list back to the
//!   matching free callback right after copying it (713-745, 811-826).
//! - With no class-category callback, Godot adds the script's own category
//!   (720-730), so `get_class_category_func` stays null.
//! - The fallback callbacks serve placeholder instances only and stay null.
//!
//! Threads: Godot calls these on the thread that uses the object. Every
//! callback that reads the record's generation, index or data, or runs
//! module code, holds the gate (`gate.zig`, which lists them), because a
//! swap rewrites `gen`, `index` and `data` under the gate's write side.
//! A callback into the instance being migrated is refused
//! (`gate.enterInstance`): a call returns INSTANCE_IS_NULL, `get`/`set`
//! fail, a notification is dropped; `free` is put off until the migration
//! ends (`endMigration`). The host contract asks that calls on one instance
//! do not overlap, but Godot does not guarantee it: a node in a thread
//! group can be called from its group's thread and from the main thread at
//! once. The gate does not serialise them (both hold the shared side).
//!
//! Live records are listed in `registry.zig` (added in `create`, removed
//! in `free`), so the swap engine can find them.
//!
//! Name maps: `runtime.shutdown` frees them at SCENE exit, after the entry
//! has unregistered the language, holding the gate's write side. Godot
//! deletes the main loop (and with it the scene tree) before it
//! deinitialises extensions at SCENE level (main/main.cpp, `Main::cleanup`),
//! so only objects that leaked can still hold an instance then; those look
//! names up by text.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");
const props = @import("props.zig");
const language = @import("language.zig");
const gate = @import("gate.zig");
const registry = @import("registry.zig");

const c = godot.c;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const Dictionary = godot.builtin.Dictionary;
const Signal = godot.builtin.Signal;
const Callable = godot.builtin.Callable;
const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const ScriptExtension = godot.class.ScriptExtension;
const ClassDb = godot.class.ClassDb;

/// Godot's `PROPERTY_USAGE_STORAGE`: saved with the scene.
const usage_storage: u32 = 2;

/// Longest property or method name compared by text.
const max_name_bytes = 1024;

/// Live instance records, for the host tests.
pub var live: std.atomic.Value(u32) = .init(0);

/// One script instance, host side.
pub const Instance = struct {
    owner: *Object,
    /// Holds one counted reference, dropped in `free`.
    script: *ScriptExtension,
    gen: *runtime.Generation,
    index: u32,
    /// What the descriptor's `create` returned.
    data: *anyopaque,
    /// Position in the registry (`registry.zig`).
    slot: u32 = 0,
    /// Set when Godot freed the instance while it was being migrated:
    /// `endMigration` releases it.
    free_pending: bool = false,

    fn desc(self: *const Instance) *const abi.ScriptDesc {
        return &self.gen.scripts()[self.index];
    }

    /// The method index of `sn`. The name maps are gone after
    /// `runtime.shutdown` (SCENE exit); an object freed later is looked up
    /// by text.
    fn methodIndex(self: *const Instance, sn: *const StringName) ?u32 {
        if (self.index < self.gen.names.len) return self.gen.names[self.index].method(sn.*);
        var buf: [max_name_bytes]u8 = undefined;
        const name = props.nameText(sn.*, &buf) orelse return null;
        return findMethod(self.desc(), name);
    }

    /// The property entry index of `sn`; group entries are never found.
    fn propertyIndex(self: *const Instance, sn: *const StringName) ?u32 {
        if (self.index < self.gen.names.len) return self.gen.names[self.index].property(sn.*);
        var buf: [max_name_bytes]u8 = undefined;
        const name = props.nameText(sn.*, &buf) orelse return null;
        const d = self.desc();
        for (d.properties[0..d.property_count], 0..) |p, i| {
            if (p.field_index != abi.no_field and std.mem.eql(u8, props.text(p.name), name)) return @intCast(i);
        }
        return null;
    }

    /// The signal index of `sn`, looked up as `methodIndex` does.
    fn signalIndex(self: *const Instance, sn: *const StringName) ?u32 {
        if (self.index < self.gen.names.len) return self.gen.names[self.index].signal(sn.*);
        var buf: [max_name_bytes]u8 = undefined;
        const name = props.nameText(sn.*, &buf) orelse return null;
        const d = self.desc();
        for (d.signals[0..d.signal_count], 0..) |sig, i| {
            if (std.mem.eql(u8, props.text(sig.name), name)) return @intCast(i);
        }
        return null;
    }
};

/// The index of the method named `name` (Godot's name) in `d`.
fn findMethod(d: *const abi.ScriptDesc, name: []const u8) ?u32 {
    for (d.methods[0..d.method_count], 0..) |m, i| {
        if (std.mem.eql(u8, props.text(m.name), name)) return @intCast(i);
    }
    return null;
}

/// True when an object of class `owner` may carry a script that extends
/// `base_class`: the same class or one derived from it, as GDScript checks
/// (modules/gdscript/gdscript.cpp:415).
pub fn ownerFits(owner: *Object, base_class: []const u8) bool {
    var cls = owner.getClass();
    defer cls.deinit();
    var cls_sn = StringName.fromString(cls);
    defer cls_sn.deinit();
    var base_sn = StringName.fromUtf8(base_class);
    defer base_sn.deinit();
    return ClassDb.isParentClass(cls_sn, base_sn);
}

/// Makes the instance of script `index` of `gen` for `owner` and returns
/// Godot's script instance pointer (what `_instance_create` returns), or
/// null. The caller has checked the owner (`ownerFits`). A refusal by the
/// module's `create` was logged by the module. Holds the gate.
pub fn create(script: *ScriptExtension, owner: *Object, gen: *runtime.Generation, index: u32) ?*anyopaque {
    if (index >= gen.table.script_count) return null;
    const make = godot.raw.scriptInstanceCreate3 orelse return null;
    const rec = std.heap.c_allocator.create(Instance) catch return null;
    gate.enter();
    const d = &gen.scripts()[index];
    const data = d.create(@ptrCast(owner), gen.n) orelse {
        gate.leave();
        std.heap.c_allocator.destroy(rec);
        return null;
    };
    _ = RefCounted.upcast(script).reference();
    rec.* = .{ .owner = owner, .script = script, .gen = gen, .index = index, .data = data };
    _ = live.fetchAdd(1, .monotonic);
    registry.add(rec) catch {
        release(rec);
        gate.leave();
        return null;
    };
    gate.leave();
    // Godot's `script_instance_create3` only allocates; null is out of memory.
    return make(&info, rec) orelse {
        free(rec);
        return null;
    };
}

/// The script instance record of `owner`'s Zig script, or null.
pub fn recordOf(owner: *Object) ?*Instance {
    const lang = language.registered orelse return null;
    const get_inst = godot.raw.objectGetScriptInstance orelse return null;
    return record(get_inst(@ptrCast(owner), @ptrCast(lang.base)));
}

/// The project-relative path of the script `rec` runs (as in the table).
/// Read under the gate.
pub fn scriptPath(rec: *const Instance) []const u8 {
    return props.text(rec.desc().path);
}

/// Ends the migration of `rec` (`gate.setMigrating(null)`) and releases it
/// when Godot freed it meanwhile. The swapper, under the gate's write side;
/// `rec` is not used afterwards when this returns true.
pub fn endMigration(rec: *Instance) bool {
    gate.setMigrating(null);
    if (!rec.free_pending) return false;
    registry.remove(rec);
    release(rec);
    return true;
}

/// The table every instance shares.
pub const info: c.GDExtensionScriptInstanceInfo3 = .{
    .set_func = &set,
    .get_func = &get,
    .get_property_list_func = &getPropertyList,
    .free_property_list_func = &freePropertyList,
    .get_class_category_func = null,
    .property_can_revert_func = &propertyCanRevert,
    .property_get_revert_func = &propertyGetRevert,
    .get_owner_func = &getOwner,
    .get_property_state_func = &getPropertyState,
    .get_method_list_func = &getMethodList,
    .free_method_list_func = &freeMethodList,
    .get_property_type_func = &getPropertyType,
    .validate_property_func = &validateProperty,
    .has_method_func = &hasMethod,
    .get_method_argument_count_func = &getMethodArgumentCount,
    .call_func = &call,
    .notification_func = &notification,
    .to_string_func = &toString,
    .refcount_incremented_func = &refcountIncremented,
    .refcount_decremented_func = &refcountDecremented,
    .get_script_func = &getScript,
    .is_placeholder_func = &isPlaceholder,
    .set_fallback_func = null,
    .get_fallback_func = null,
    .get_language_func = &getLanguage,
    .free_func = &free,
};

fn record(p: c.GDExtensionScriptInstanceDataPtr) ?*Instance {
    return @ptrCast(@alignCast(p orelse return null));
}

fn nameOf(p: c.GDExtensionConstStringNamePtr) ?*const StringName {
    return @ptrCast(@alignCast(p orelse return null));
}

/// Moves `v` into the caller's Variant at `out`, destroying what it held.
fn moveInto(out: c.GDExtensionVariantPtr, v: *Variant) void {
    godot.raw.variantDestroy(out);
    const dst: *Variant = @ptrCast(@alignCast(out));
    dst.* = v.*;
    v.* = .nil;
}

// ------------------------------------------------------------ properties

fn set(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr, value: c.GDExtensionConstVariantPtr) callconv(.c) c.GDExtensionBool {
    const rec = record(p) orelse return 0;
    const v = value orelse return 0;
    if (!gate.enterInstance(rec)) return 0;
    defer gate.leave();
    const i = rec.propertyIndex(nameOf(name) orelse return 0) orelse return 0;
    return @intFromBool(rec.desc().set(rec.data, i, v) != 0);
}

/// A property's value; else, as GDScript instances answer
/// (modules/gdscript/gdscript.cpp, `GDScriptInstance::get`), a script signal
/// as a `Signal` and a script method as a `Callable` on the owner, so that
/// `node.hit.connect(f)` and `node.score.call(1)` work from GDScript. Godot
/// asks the script instance first for every name it gets (core/object/
/// object.cpp, `Object::get`); names of neither kind fall through to the
/// engine class.
fn get(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr, r_ret: c.GDExtensionVariantPtr) callconv(.c) c.GDExtensionBool {
    const rec = record(p) orelse return 0;
    if (r_ret == null) return 0;
    const sn = nameOf(name) orelse return 0;
    if (!gate.enterInstance(rec)) return 0;
    defer gate.leave();
    if (rec.propertyIndex(sn)) |i| {
        var v: Variant = .nil;
        if (rec.desc().get(rec.data, i, @ptrCast(&v)) == 0) return 0;
        moveInto(r_ret, &v);
        return 1;
    }
    if (rec.signalIndex(sn) != null) {
        var sig = Signal.initObjectSignal(rec.owner, sn.*);
        defer sig.deinit();
        var v = Variant.init(Signal, sig);
        moveInto(r_ret, &v);
        return 1;
    }
    if (rec.methodIndex(sn) != null) {
        var call_ = Callable.initObjectMethod(rec.owner, sn.*);
        defer call_.deinit();
        var v = Variant.init(Callable, call_);
        moveInto(r_ret, &v);
        return 1;
    }
    return 0;
}

/// Resolves on the main thread the lazy gdzig pointers `get` uses for
/// signals and methods (the Signal and Callable constructors, destructors
/// and Variant conversions), so a first `get` on another thread never
/// resolves one. Called at SCENE init with any live object (the language).
pub fn warm(obj: *Object) void {
    var sn = StringName.fromUtf8("ziggurat_warm");
    defer sn.deinit();
    var sig = Signal.initObjectSignal(obj, sn);
    const sv = Variant.init(Signal, sig);
    sv.deinit();
    sig.deinit();
    var call_ = Callable.initObjectMethod(obj, sn);
    const cv = Variant.init(Callable, call_);
    cv.deinit();
    call_.deinit();
}

fn propertyCanRevert(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr) callconv(.c) c.GDExtensionBool {
    const rec = record(p) orelse return 0;
    gate.enter();
    defer gate.leave();
    const i = rec.propertyIndex(nameOf(name) orelse return 0) orelse return 0;
    const v = props.defaultValue(rec.desc(), i) orelse return 0;
    v.deinit();
    return 1;
}

fn propertyGetRevert(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr, r_ret: c.GDExtensionVariantPtr) callconv(.c) c.GDExtensionBool {
    const rec = record(p) orelse return 0;
    if (r_ret == null) return 0;
    gate.enter();
    defer gate.leave();
    const i = rec.propertyIndex(nameOf(name) orelse return 0) orelse return 0;
    var v = props.defaultValue(rec.desc(), i) orelse return 0;
    moveInto(r_ret, &v);
    return 1;
}

fn getPropertyType(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr, r_is_valid: [*c]c.GDExtensionBool) callconv(.c) c.GDExtensionVariantType {
    if (r_is_valid != null) r_is_valid.* = 0;
    const rec = record(p) orelse return 0;
    gate.enter();
    defer gate.leave();
    const i = rec.propertyIndex(nameOf(name) orelse return 0) orelse return 0;
    if (r_is_valid != null) r_is_valid.* = 1;
    return @intCast(rec.desc().properties[i].variant_type);
}

/// The descriptor's properties are final: nothing to change.
fn validateProperty(_: c.GDExtensionScriptInstanceDataPtr, _: [*c]c.GDExtensionPropertyInfo) callconv(.c) c.GDExtensionBool {
    return 0;
}

/// Every stored property (usage STORAGE) with its current value, in
/// descriptor order. Godot copies name and value in `p_add_func`.
fn getPropertyState(p: c.GDExtensionScriptInstanceDataPtr, add: c.GDExtensionScriptInstancePropertyStateAdd, userdata: ?*anyopaque) callconv(.c) void {
    const rec = record(p) orelse return;
    const add_fn = add orelse return;
    if (!gate.enterInstance(rec)) return;
    defer gate.leave();
    const d = rec.desc();
    for (d.properties[0..d.property_count], 0..) |prop, i| {
        if (prop.field_index == abi.no_field or prop.usage & usage_storage == 0) continue;
        var v: Variant = .nil;
        if (d.get(rec.data, @intCast(i), @ptrCast(&v)) == 0) continue;
        defer v.deinit();
        var sn = StringName.fromUtf8(props.text(prop.name));
        defer sn.deinit();
        add_fn(@ptrCast(&sn), @ptrCast(&v), userdata);
    }
}

/// The descriptor's property list (group entries too), in the shapes of
/// `props.propertyList`. Allocated per call; `freePropertyList` frees it.
fn getPropertyList(p: c.GDExtensionScriptInstanceDataPtr, r_count: [*c]u32) callconv(.c) [*c]const c.GDExtensionPropertyInfo {
    if (r_count != null) r_count.* = 0;
    const rec = record(p) orelse return null;
    if (r_count == null) return null;
    gate.enter();
    defer gate.leave();
    const d = rec.desc();
    const n = d.property_count;
    if (n == 0) return null;
    const list = Block.create(c.GDExtensionPropertyInfo, n, 0, 2 * n, n) orelse return null;
    for (d.properties[0..n], list.items) |prop, *out| list.block.fill(out, props.propInfo(prop));
    r_count.* = n;
    return list.items.ptr;
}

fn freePropertyList(_: c.GDExtensionScriptInstanceDataPtr, list: [*c]const c.GDExtensionPropertyInfo, _: u32) callconv(.c) void {
    if (list == null) return;
    Block.destroy(@ptrCast(list));
}

// ------------------------------------------------------------ methods

fn hasMethod(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr) callconv(.c) c.GDExtensionBool {
    const rec = record(p) orelse return 0;
    gate.enter();
    defer gate.leave();
    return @intFromBool(rec.methodIndex(nameOf(name) orelse return 0) != null);
}

fn getMethodArgumentCount(p: c.GDExtensionScriptInstanceDataPtr, name: c.GDExtensionConstStringNamePtr, r_is_valid: [*c]c.GDExtensionBool) callconv(.c) c.GDExtensionInt {
    if (r_is_valid != null) r_is_valid.* = 0;
    const rec = record(p) orelse return 0;
    gate.enter();
    defer gate.leave();
    const i = rec.methodIndex(nameOf(name) orelse return 0) orelse return 0;
    if (r_is_valid != null) r_is_valid.* = 1;
    return rec.desc().methods[i].arg_count;
}

/// The descriptor's methods as Godot method infos (no default arguments).
/// Allocated per call; `freeMethodList` frees it.
fn getMethodList(p: c.GDExtensionScriptInstanceDataPtr, r_count: [*c]u32) callconv(.c) [*c]const c.GDExtensionMethodInfo {
    if (r_count != null) r_count.* = 0;
    const rec = record(p) orelse return null;
    if (r_count == null) return null;
    gate.enter();
    defer gate.leave();
    const d = rec.desc();
    const n = d.method_count;
    if (n == 0) return null;
    var args: usize = 0;
    for (d.methods[0..n]) |m| args += m.arg_count;
    // Per method: its name, and a return value of 2 names and 1 string;
    // per argument: 2 names and 1 string.
    const list = Block.create(c.GDExtensionMethodInfo, n, args, 3 * n + 2 * args, n + args) orelse return null;
    var next: usize = 0;
    for (d.methods[0..n], list.items) |m, *out| {
        const margs = list.args[next..][0..m.arg_count];
        next += m.arg_count;
        for (m.args[0..m.arg_count], margs) |a, *ai| list.block.fill(ai, props.argInfo(a));
        out.* = .{
            .name = @ptrCast(list.block.name(props.text(m.name))),
            .return_value = undefined,
            .flags = props.godotMethodFlags(m.flags),
            .id = 0,
            .argument_count = m.arg_count,
            .arguments = if (m.arg_count == 0) null else margs.ptr,
            .default_argument_count = 0,
            .default_arguments = null,
        };
        list.block.fill(&out.return_value, props.argInfo(m.ret));
    }
    r_count.* = n;
    return list.items.ptr;
}

fn freeMethodList(_: c.GDExtensionScriptInstanceDataPtr, list: [*c]const c.GDExtensionMethodInfo, _: u32) callconv(.c) void {
    if (list == null) return;
    Block.destroy(@ptrCast(list));
}

/// Calls the script method named `method`. A name the script does not have
/// is INVALID_METHOD, which makes Godot try the engine class's methods
/// (`Object::callp`). The error is always written; `r_return` keeps nil on
/// every error.
fn call(
    p: c.GDExtensionScriptInstanceDataPtr,
    method: c.GDExtensionConstStringNamePtr,
    args: [*c]const c.GDExtensionConstVariantPtr,
    argc: c.GDExtensionInt,
    r_return: c.GDExtensionVariantPtr,
    r_error: [*c]c.GDExtensionCallError,
) callconv(.c) void {
    if (r_error == null) return;
    r_error.* = .{ .@"error" = abi.call_invalid_method, .argument = 0, .expected = 0 };
    const rec = record(p) orelse return;
    if (r_return == null) return;
    if (!gate.enterInstance(rec)) {
        r_error.* = .{ .@"error" = abi.call_instance_is_null, .argument = 0, .expected = 0 };
        return;
    }
    defer gate.leave();
    const i = rec.methodIndex(nameOf(method) orelse return) orelse return;
    var err: abi.CallError = .{ .@"error" = abi.call_ok, .argument = 0, .expected = 0 };
    var v: Variant = .nil;
    rec.desc().call(rec.data, i, @ptrCast(args), argc, @ptrCast(&v), &err);
    moveInto(r_return, &v);
    r_error.* = .{ .@"error" = err.@"error", .argument = err.argument, .expected = err.expected };
}

/// Passes the notification on with `reversed`. A Zig script is one class,
/// so there is nothing to order; the module ignores the flag.
fn notification(p: c.GDExtensionScriptInstanceDataPtr, what: i32, reversed: c.GDExtensionBool) callconv(.c) void {
    const rec = record(p) orelse return;
    if (!gate.enterInstance(rec)) return;
    defer gate.leave();
    rec.desc().notification(rec.data, what, @intFromBool(reversed != 0));
}

/// The script's `_to_string()` when it has one that takes no arguments and
/// returns a String; otherwise not valid, and Godot uses its default text.
fn toString(p: c.GDExtensionScriptInstanceDataPtr, r_is_valid: [*c]c.GDExtensionBool, r_out: c.GDExtensionStringPtr) callconv(.c) void {
    if (r_is_valid != null) r_is_valid.* = 0;
    const rec = record(p) orelse return;
    if (r_is_valid == null or r_out == null) return;
    if (!gate.enterInstance(rec)) return;
    defer gate.leave();
    const d = rec.desc();
    const i = findMethod(d, "_to_string") orelse return;
    if (d.methods[i].arg_count != 0) return;
    var err: abi.CallError = .{ .@"error" = abi.call_ok, .argument = 0, .expected = 0 };
    var v: Variant = .nil;
    d.call(rec.data, i, null, 0, @ptrCast(&v), &err);
    defer v.deinit();
    if (err.@"error" != abi.call_ok or v.tag != .string) return;
    const text = v.as(String) orelse return;
    const out: *String = @ptrCast(@alignCast(r_out));
    out.deinit();
    out.* = text;
    r_is_valid.* = 1;
}

// ------------------------------------------------------------ identity

fn getOwner(p: c.GDExtensionScriptInstanceDataPtr) callconv(.c) c.GDExtensionObjectPtr {
    const rec = record(p) orelse return null;
    return @ptrCast(rec.owner);
}

fn getScript(p: c.GDExtensionScriptInstanceDataPtr) callconv(.c) c.GDExtensionObjectPtr {
    const rec = record(p) orelse return null;
    return @ptrCast(rec.script);
}

fn isPlaceholder(_: c.GDExtensionScriptInstanceDataPtr) callconv(.c) c.GDExtensionBool {
    return 0;
}

/// Null once the language is unregistered (SCENE exit): an object can
/// outlive it.
fn getLanguage(_: c.GDExtensionScriptInstanceDataPtr) callconv(.c) c.GDExtensionScriptLanguagePtr {
    const lang = language.registered orelse return null;
    return @ptrCast(lang.base);
}

fn refcountIncremented(_: c.GDExtensionScriptInstanceDataPtr) callconv(.c) void {}

/// True lets a RefCounted owner die: Godot ANDs this into its own answer
/// (core/object/ref_counted.cpp:99).
fn refcountDecremented(_: c.GDExtensionScriptInstanceDataPtr) callconv(.c) c.GDExtensionBool {
    return 1;
}

/// Runs the module's `destroy`, drops the script reference and frees the
/// record. Godot calls it from `~ScriptInstanceExtension` (934-936). For
/// the instance being migrated (code the swap runs freed its owner) it only
/// marks the record; `endMigration` releases it.
fn free(p: c.GDExtensionScriptInstanceDataPtr) callconv(.c) void {
    const rec = record(p) orelse return;
    gate.enter();
    defer gate.leave();
    if (gate.isMigrating(rec)) {
        rec.free_pending = true;
        return;
    }
    registry.remove(rec);
    release(rec);
}

/// `destroy` in the module, then the script reference and the record.
/// Inside the gate.
fn release(rec: *Instance) void {
    rec.desc().destroy(rec.data);
    const script = rec.script;
    std.heap.c_allocator.destroy(rec);
    _ = live.fetchSub(1, .monotonic);
    if (RefCounted.upcast(script).unreference()) godot.raw.objectDestroy(@ptrCast(script));
}

// ------------------------------------------------------------ lists

/// One allocation holding a list Godot borrows (property or method infos)
/// together with the engine names and strings its entries point to:
/// `[Block][items][argument infos][StringNames][Strings]`. The free
/// callbacks get the items pointer back and find the header in front of it.
const Block = struct {
    bytes: []align(16) u8,
    names: []StringName,
    strings: []String,
    names_used: usize = 0,
    strings_used: usize = 0,

    const header = std.mem.alignForward(usize, @sizeOf(Block), 16);
    const PropertyInfo = c.GDExtensionPropertyInfo;

    fn List(comptime Item: type) type {
        return struct { block: *Block, items: []Item, args: []PropertyInfo };
    }

    /// Room for `items` entries, `args` argument infos, `names` StringNames
    /// and `strings` Strings, or null when out of memory.
    fn create(comptime Item: type, items: usize, args: usize, names: usize, strings: usize) ?List(Item) {
        const o_items = header;
        const o_args = std.mem.alignForward(usize, o_items + items * @sizeOf(Item), @alignOf(PropertyInfo));
        const o_names = std.mem.alignForward(usize, o_args + args * @sizeOf(PropertyInfo), @alignOf(StringName));
        const o_strings = std.mem.alignForward(usize, o_names + names * @sizeOf(StringName), @alignOf(String));
        const total = o_strings + strings * @sizeOf(String);
        const bytes = std.heap.c_allocator.alignedAlloc(u8, .@"16", total) catch return null;
        const block: *Block = @ptrCast(bytes.ptr);
        block.* = .{
            .bytes = bytes,
            .names = @as([*]StringName, @ptrCast(@alignCast(bytes.ptr + o_names)))[0..names],
            .strings = @as([*]String, @ptrCast(@alignCast(bytes.ptr + o_strings)))[0..strings],
        };
        return .{
            .block = block,
            .items = @as([*]Item, @ptrCast(@alignCast(bytes.ptr + o_items)))[0..items],
            .args = @as([*]PropertyInfo, @ptrCast(@alignCast(bytes.ptr + o_args)))[0..args],
        };
    }

    /// Frees the block whose items start at `items`.
    fn destroy(items: *const anyopaque) void {
        const block: *Block = @ptrFromInt(@intFromPtr(items) - header);
        for (block.names[0..block.names_used]) |*n| n.deinit();
        for (block.strings[0..block.strings_used]) |*s| s.deinit();
        std.heap.c_allocator.free(block.bytes);
    }

    /// A new StringName in the block. Callers reserve enough in `create`.
    fn name(b: *Block, text: []const u8) *StringName {
        const n = &b.names[b.names_used];
        n.* = StringName.fromUtf8(text);
        b.names_used += 1;
        return n;
    }

    fn string(b: *Block, text: []const u8) *String {
        const s = &b.strings[b.strings_used];
        s.* = props.gstring(text);
        b.strings_used += 1;
        return s;
    }

    /// `out` as Godot's form of `pi`: 2 names and 1 string from the block.
    fn fill(b: *Block, out: *PropertyInfo, pi: props.PropInfo) void {
        out.* = .{
            .type = @intCast(pi.type),
            .name = @ptrCast(b.name(pi.name)),
            .class_name = @ptrCast(b.name(pi.class_name)),
            .hint = pi.hint,
            .hint_string = @ptrCast(b.string(pi.hint_string)),
            .usage = pi.usage,
        };
    }
};

// ------------------------------------------------------------ test support

/// The property state of `owner`'s Zig script instance as a dictionary
/// (what `get_property_state` reports), or an empty one. For the host
/// tests: Godot has no script-facing call that reaches it.
pub fn propertyStateOf(owner: *Object) Dictionary {
    var d = Dictionary.init();
    const lang = language.registered orelse return d;
    const get_inst = godot.raw.objectGetScriptInstance orelse return d;
    const p = get_inst(@ptrCast(owner), @ptrCast(lang.base)) orelse return d;
    getPropertyState(p, &addToDictionary, &d);
    return d;
}

fn addToDictionary(name: c.GDExtensionConstStringNamePtr, value: c.GDExtensionConstVariantPtr, userdata: ?*anyopaque) callconv(.c) void {
    const d: *Dictionary = @ptrCast(@alignCast(userdata orelse return));
    const sn: *const StringName = @ptrCast(@alignCast(name orelse return));
    const v: *const Variant = @ptrCast(@alignCast(value orelse return));
    var s = String.fromStringName(sn.*);
    defer s.deinit();
    const k = Variant.init(String, s);
    defer k.deinit();
    _ = d.set(k, v.*);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "every callback of the instance table is set except the optional ones" {
    const T = c.GDExtensionScriptInstanceInfo3;
    inline for (@typeInfo(T).@"struct".field_names) |f| {
        const optional = comptime std.mem.eql(u8, f, "get_class_category_func") or
            std.mem.eql(u8, f, "set_fallback_func") or std.mem.eql(u8, f, "get_fallback_func");
        try testing.expectEqual(!optional, @field(info, f) != null);
    }
}

test "list blocks keep items, arguments, names and strings apart and find their header" {
    const list = Block.create(c.GDExtensionMethodInfo, 3, 5, 7, 2).?;
    const b = list.block;
    const start = @intFromPtr(b.bytes.ptr);
    try testing.expectEqual(start, @intFromPtr(list.items.ptr) - Block.header);
    try testing.expect(start + @sizeOf(Block) <= @intFromPtr(list.items.ptr));
    try testing.expect(@intFromPtr(list.items.ptr + 3) <= @intFromPtr(list.args.ptr));
    try testing.expect(@intFromPtr(list.args.ptr + 5) <= @intFromPtr(b.names.ptr));
    try testing.expect(@intFromPtr(b.names.ptr + 7) <= @intFromPtr(b.strings.ptr));
    try testing.expectEqual(start + b.bytes.len, @intFromPtr(b.strings.ptr + 2));
    // Nothing was filled, so destroying calls nothing in Godot.
    Block.destroy(list.items.ptr);
}
