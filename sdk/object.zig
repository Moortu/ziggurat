//! Object handles: `Obj(T)`, `Ref(T)` and the engine class check.
//!
//! `Obj(T)` stores an ObjectID and looks the object up on every use, so a
//! freed object reads as null instead of a dangling pointer. `Ref(T)` owns
//! one counted reference to a RefCounted object.
//!
//! Class check: the ObjectID is resolved with `objectGetInstanceFromId`
//! (null for a freed object), then Object's `is_class` is asked with the
//! engine class name of `T`. `objectCastTo` and `classdbGetClassTag` are
//! deprecated in Godot 4.7 and not used.
//!
//! Only engine (opaque) classes are supported. A class defined in Zig has no
//! engine class name for `is_class` to test, so it is rejected at compile time.
const std = @import("std");
const godot = @import("gdzig");
const sdk_options = @import("sdk_options");
const names = @import("names.zig");

const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const StringName = godot.builtin.StringName;

// Thread note: the `StaticName` behind the class check and gdzig's lazy
// method-bind cache for `is_class` are plain variables written without
// atomics. Their first use must happen on the main thread (warm them in
// `moduleInit`) before any other thread resolves a handle.

/// Marks a struct as an object handle for `convert`. Value: `.obj` or `.ref`.
pub const handle_decl = "ziggurat_handle";

/// True for an engine class type such as `Node`.
pub fn isEngineClass(comptime T: type) bool {
    // The class check walks the whole base chain, which exceeds the default
    // branch quota for deep classes.
    @setEvalBranchQuota(100_000);
    return comptime godot.class.isOpaqueClass(T);
}

/// The engine class name of the gdzig class type `T` ("Node3D" for
/// `class.Node3d`), a compile error when `T` is not an engine class type.
///
/// gdzig's own `class.downcast` rebuilds the name from the type's name
/// (`StringName.fromType`), which is wrong for about a quarter of the classes
/// (`AesContext` for AESContext, `CpuParticles2d` for CPUParticles2D). Here
/// the type's short name is matched, ignoring case, against the exact names
/// of `extension_api.json` (`sdk_options.class_names`); no two engine class
/// names differ only in case.
pub fn engineClassName(comptime T: type) [:0]const u8 {
    if (comptime !isEngineClass(T))
        @compileError("ziggurat: " ++ @typeName(T) ++ " is not an engine class type");
    return comptime blk: {
        @setEvalBranchQuota(200_000);
        const full = @typeName(T);
        const short = if (std.mem.lastIndexOfScalar(u8, full, '.')) |pos| full[pos + 1 ..] else full;
        for (sdk_options.class_names) |name| {
            if (std.ascii.eqlIgnoreCase(name, short)) break :blk name;
        }
        @compileError("ziggurat: no engine class named like " ++ short ++ " in the API description");
    };
}

fn requireClass(comptime T: type) void {
    if (comptime !isEngineClass(T))
        @compileError("ziggurat: " ++ @typeName(T) ++ " is not an engine class type");
}

/// The Object at `id`, or null when no live object has that id (0 included).
fn instanceFromId(id: u64) ?*Object {
    if (id == 0) return null;
    return @ptrCast(@alignCast(godot.raw.objectGetInstanceFromId(id)));
}

/// True when the live object `o` is a `T` or inherits from it.
fn isClassOf(comptime T: type, o: *Object) bool {
    const name: *const StringName = @ptrCast(@alignCast(names.StaticName(engineClassName(T)).ptr()));
    return o.isClass(name.*);
}

/// The live object with ObjectID `id` as a `*T`, or null when the id is not
/// alive or the object is not a `T`. This is the one place a raw id becomes a
/// typed pointer; `Obj.get` and `convert` both use it.
pub fn resolve(comptime T: type, id: u64) ?*T {
    comptime requireClass(T);
    const o = instanceFromId(id) orelse return null;
    if (!isClassOf(T, o)) return null;
    return @ptrCast(o);
}

/// The ObjectID of a live engine object.
pub fn idOf(o: anytype) u64 {
    return godot.raw.objectGetInstanceId(@ptrCast(o));
}

/// An ObjectID that resolves on every use. 0 is the null handle.
pub fn Obj(comptime T: type) type {
    comptime requireClass(T);
    return struct {
        pub const ziggurat_handle = .obj;
        pub const Class = T;

        id: u64 = 0,

        /// The object, or null when it was freed, never existed or is not a `T`.
        pub fn get(self: @This()) ?*T {
            return resolve(T, self.id);
        }

        pub fn set(self: *@This(), o: ?*T) void {
            self.id = if (o) |p| idOf(p) else 0;
        }
    };
}

/// An owning handle to a RefCounted object: holds one counted reference.
/// The holder must call `release` (or `set(null)`) when done.
pub fn Ref(comptime T: type) type {
    comptime {
        requireClass(T);
        if (!godot.class.isA(RefCounted, T))
            @compileError("ziggurat: Ref needs a RefCounted class, found " ++ @typeName(T));
    }
    return struct {
        pub const ziggurat_handle = .ref;
        pub const Class = T;

        ptr: ?*T = null,

        pub fn get(self: @This()) ?*T {
            return self.ptr;
        }

        /// Takes a reference on `o`, then drops the one held on the old
        /// object, freeing it when that was the last. Setting the object
        /// already held changes nothing. If Godot refuses the new reference
        /// (the object is already being destroyed) the handle becomes null.
        pub fn set(self: *@This(), o: ?*T) void {
            if (o == self.ptr) return;
            const old = self.ptr;
            self.ptr = null;
            if (o) |p| {
                if (rc(p).reference()) self.ptr = p;
            }
            if (old) |p| dropRef(p);
        }

        /// Drops the held reference (freeing the object when it was the last)
        /// and makes the handle null. Safe to call twice.
        pub fn release(self: *@This()) void {
            self.set(null);
        }
    };
}

fn rc(p: anytype) *RefCounted {
    return @ptrCast(p);
}

/// Drops one reference; frees the object with `objectDestroy` when it was
/// the last one.
fn dropRef(p: anytype) void {
    if (rc(p).unreference()) godot.raw.objectDestroy(@ptrCast(p));
}
