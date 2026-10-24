pub const VTable = @import("class/vtable.zig").VTable;

// Class checks. Ziggurat patch 4 (vendor/gdzig/PATCHES.md): class_kind.zig
// replaces upstream's class check package, which has no licence.
const class_kind = @import("class_kind.zig");
pub const assertIsA = class_kind.assertIsA;
pub const assertIsAny = class_kind.assertIsAny;
pub const isClass = class_kind.isClass;
pub const isOpaqueClass = class_kind.isOpaqueClass;
pub const isStructClass = class_kind.isStructClass;
pub const isClassPtr = class_kind.isClassPtr;
pub const isOpaqueClassPtr = class_kind.isOpaqueClassPtr;
pub const isStructClassPtr = class_kind.isStructClassPtr;
pub const BaseOf = class_kind.BaseOf;
pub const depthOf = class_kind.depthOf;
pub const ancestorsOf = class_kind.ancestorsOf;
pub const selfAndAncestorsOf = class_kind.selfAndAncestorsOf;
pub const isA = class_kind.isA;
pub const isAny = class_kind.isAny;
pub const upcast = class_kind.upcast;

/// Returns true if a type is a reference counted type.
///
/// Expects a class type, e.g. `Node` or `MyClass`, not `*Node` or `*MyClass`.
pub fn isRefCounted(comptime T: type) bool {
    return isA(RefCounted, T);
}

/// Returns true if a type is a pointer to a reference counted type.
///
/// Expects a pointer type, e.g. `*Node` or `*MyClass`, not `Node` or `MyClass`.
pub fn isRefCountedPtr(comptime T: type) bool {
    const Pointer = switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
    if (@typeInfo(Pointer) != .pointer) return false;
    return isRefCounted(std.meta.Child(Pointer));
}

/// Returns true when `T` is an optional whose payload is a Godot class
/// pointer, such as `?*Node` or `?*MyResource`.
pub fn isNullableClassPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => |info| isClassPtr(info.child),
        else => false,
    };
}

/// Returns the non-optional class pointer carried by `T`.
pub fn ClassPtrOf(comptime T: type) type {
    if (isNullableClassPtr(T)) return @typeInfo(T).optional.child;
    if (isClassPtr(T)) return T;
    @compileError("expected a Godot class pointer, found '" ++ @typeName(T) ++ "'");
}

/// Downcast a value to a child type in the class hierarchy. Has some compile time checks, but returns null at runtime if the cast fails.
///
/// Expects pointer types, e.g `*Node` or `*MyClass`, not `Node` or `MyClass`.
pub fn downcast(comptime T: type, value: anytype) ?*std.meta.Child(T) {
    const Target = std.meta.Child(T);

    if (!isClassPtr(T)) {
        @compileError("downcast expects a class pointer type as the target type, found '" ++ @typeName(T) ++ "'");
    }

    const Source = switch (@typeInfo(@TypeOf(value))) {
        .optional => |info| std.meta.Child(info.child),
        .pointer => |info| info.child,
        else => @compileError("downcast expects a pointer type as the source value, found '" ++ @typeName(@TypeOf(value)) ++ "'"),
    };

    assertIsA(Source, Target);

    if (@typeInfo(@TypeOf(value)) == .optional and value == null) {
        return null;
    }

    const name: StringName = .fromType(Target);
    const tag = raw.classdbGetClassTag(@ptrCast(&name));
    const result = raw.objectCastTo(@ptrCast(value), tag);

    if (result) |ptr| {
        if (isOpaqueClassPtr(T)) {
            return @ptrCast(@alignCast(ptr));
        } else {
            const obj: *anyopaque = raw.objectGetInstanceBinding(ptr, raw.library, null) orelse return null;
            return @ptrCast(@alignCast(obj));
        }
    } else {
        return null;
    }
}

const std = @import("std");
const gdzig = @import("gdzig");
const raw = &gdzig.raw;
const StringName = gdzig.builtin.StringName;

// @mixin stop

const Object = gdzig.class.Object;
const RefCounted = gdzig.class.RefCounted;
