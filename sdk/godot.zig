//! The curated Godot surface scripts see as `ziggurat.godot` (spec section 8):
//! `const g = @import("ziggurat").godot;` then `g.CharacterBody2D`,
//! `g.Vector2`, `g.Key`. Every name is the Godot name; each declaration is
//! the gdzig type itself, so values pass between the two freely, except
//! `Callable` and `ClassDB`, which are SDK types (below).
//!
//! This file is not imported as is. The build (tools/godot_surface.zig)
//! copies it and appends one declaration per engine class, and the SDK
//! imports that generated module as `ziggurat_godot`.
//!
//! Re-exported, and nothing else:
//!   - Engine classes: every class in Godot's extension_api.json, under its
//!     Godot name (`Node`, `Node2D`, `CharacterBody2D`, `AESContext`, ...),
//!     except `ClassDB` (gdzig's `ClassDb` carries the registration API),
//!     `GDExtension` and `GDExtensionManager`.
//!   - `ClassDB`: an SDK struct that forwards only the read-only calls
//!     (`classExists`, `getParentClass`, `isParentClass`, `classHasMethod`,
//!     `canInstantiate`, `instantiate`).
//!   - Builtin value types: String, StringName, NodePath, Vector2, Vector2i,
//!     Rect2, Rect2i, Vector3, Vector3i, Transform2D, Vector4, Vector4i,
//!     Plane, Quaternion, AABB, Basis, Transform3D, Projection, Color, RID,
//!     Signal, Dictionary, Array, PackedByteArray,
//!     PackedInt32Array, PackedInt64Array, PackedFloat32Array,
//!     PackedFloat64Array, PackedStringArray, PackedVector2Array,
//!     PackedVector3Array, PackedColorArray, PackedVector4Array.
//!   - `Callable`: an SDK struct that wraps the engine value and can only be
//!     built from an object and a method name (`Callable.init(node,
//!     "queue_free")`). gdzig's `Callable.fromClosure` binds a function
//!     pointer of the loaded library; after a reload unloads that library,
//!     calling such a Callable (for example through a signal connection)
//!     jumps into unmapped code. An (object, method name) Callable stays
//!     valid across reloads.
//!   - Global enums and flag sets: Side, Corner, Orientation,
//!     ClockDirection, HorizontalAlignment, VerticalAlignment,
//!     InlineAlignment, EulerOrder, Key, KeyModifierMask, KeyLocation,
//!     MouseButton, MouseButtonMask, JoyButton, JoyAxis, MIDIMessage, Error,
//!     PropertyHint, PropertyUsageFlags, MethodFlags.
//!
//! Withheld: gdzig's `Registry`, `extension` (registration), `Variant` and
//! its helpers, `raw`, `c`, `class` as a namespace (with its cast helpers),
//! `heap`, `testing`. Scripts pass values through the SDK's checked
//! conversions instead.
//!
//! Limit: this curates names, it is not a sandbox. Methods of the
//! re-exported types take and return gdzig types, and `@TypeOf` reaches
//! any of them, the withheld ones included (`Callable.engine()` returns the
//! gdzig Callable, whose type has `fromClosure`). Every re-exported class
//! also inherits gdzig's Object helpers, which Stage 3 must rule on:
//! `setInstance` and `asInstance` (the instance binding belongs to the
//! host), `connect(comptime S, Callable)` (takes a gdzig Callable) and
//! `emit`/`emitAlloc` (they convert through gdzig's Variant helpers; scripts
//! use `z.emit`).
const gdzig = @import("gdzig");
const builtin = gdzig.builtin;
const global = gdzig.global;

// ---- SDK types ----

/// A Godot Callable that calls `method` on an object: the only kind scripts
/// can build (see the file comment). Godot's own constructor makes it, so it
/// holds the object's id and the method name. Release it with `deinit`.
pub const Callable = struct {
    value: builtin.Callable,

    /// A Callable for `obj.method(...)`; `obj` is a pointer to an engine
    /// class instance. The method name is checked by Godot when it is called.
    pub fn init(obj: anytype, comptime method: [:0]const u8) Callable {
        const P = @TypeOf(obj);
        if (comptime @typeInfo(P) != .pointer or !gdzig.class.isClassPtr(P))
            @compileError("ziggurat: Callable.init needs a pointer to an engine class instance, found " ++ @typeName(P));
        // A comptime name is cached by gdzig and never freed.
        return .{ .value = builtin.Callable.initObjectMethod(@ptrCast(obj), builtin.StringName.fromComptimeLatin1(method)) };
    }

    pub fn deinit(self: *Callable) void {
        self.value.deinit();
    }

    /// The engine value, for engine methods that take a Callable.
    pub fn engine(self: *const Callable) *const builtin.Callable {
        return &self.value;
    }
};

/// The read-only part of Godot's ClassDB singleton. Class and method names
/// are StringNames; returned StringNames are owned by the caller.
pub const ClassDB = struct {
    const Db = gdzig.class.ClassDb;

    pub fn classExists(class: StringName) bool {
        return Db.classExists(class);
    }

    pub fn getParentClass(class: StringName) StringName {
        return Db.getParentClass(class);
    }

    pub fn isParentClass(class: StringName, inherits: StringName) bool {
        return Db.isParentClass(class, inherits);
    }

    pub fn classHasMethod(class: StringName, method: StringName, no_inheritance: bool) bool {
        return Db.classHasMethod(class, method, .{ .no_inheritance = no_inheritance });
    }

    pub fn canInstantiate(class: StringName) bool {
        return Db.canInstantiate(class);
    }

    /// A new instance of `class`, owned by the caller (free a Node with
    /// `queueFree` or `free`). Null when Godot cannot instantiate it, and for
    /// RefCounted classes: their only reference would be the temporary
    /// Variant, so build those with `T.init()` and keep them in `z.Ref`.
    pub fn instantiate(class: StringName) ?*gdzig.class.Object {
        const ref_counted = builtin.StringName.fromComptimeLatin1("RefCounted");
        if (class.eql(ref_counted) or Db.isParentClass(class, ref_counted)) return null;
        if (!Db.canInstantiate(class)) return null;
        var v = Db.instantiate(class);
        defer gdzig.raw.variantDestroy(&v);
        const t_object = 24;
        if (gdzig.raw.variantGetType(&v) != t_object) return null;
        var o: ?*gdzig.class.Object = null;
        const to_object = gdzig.raw.getVariantToTypeConstructor(t_object) orelse return null;
        to_object(@ptrCast(&o), @ptrCast(&v));
        return o;
    }
};

// ---- Builtin value types ----

pub const String = builtin.String;
pub const StringName = builtin.StringName;
pub const NodePath = builtin.NodePath;
pub const Vector2 = builtin.Vector2;
pub const Vector2i = builtin.Vector2i;
pub const Rect2 = builtin.Rect2;
pub const Rect2i = builtin.Rect2i;
pub const Vector3 = builtin.Vector3;
pub const Vector3i = builtin.Vector3i;
pub const Transform2D = builtin.Transform2d;
pub const Vector4 = builtin.Vector4;
pub const Vector4i = builtin.Vector4i;
pub const Plane = builtin.Plane;
pub const Quaternion = builtin.Quaternion;
pub const AABB = builtin.Aabb;
pub const Basis = builtin.Basis;
pub const Transform3D = builtin.Transform3d;
pub const Projection = builtin.Projection;
pub const Color = builtin.Color;
pub const RID = builtin.Rid;
pub const Signal = builtin.Signal;
pub const Dictionary = builtin.Dictionary;
pub const Array = builtin.Array;
pub const PackedByteArray = builtin.PackedByteArray;
pub const PackedInt32Array = builtin.PackedInt32Array;
pub const PackedInt64Array = builtin.PackedInt64Array;
pub const PackedFloat32Array = builtin.PackedFloat32Array;
pub const PackedFloat64Array = builtin.PackedFloat64Array;
pub const PackedStringArray = builtin.PackedStringArray;
pub const PackedVector2Array = builtin.PackedVector2Array;
pub const PackedVector3Array = builtin.PackedVector3Array;
pub const PackedColorArray = builtin.PackedColorArray;
pub const PackedVector4Array = builtin.PackedVector4Array;

// ---- Global enums and flag sets ----

pub const Side = global.Side;
pub const Corner = global.Corner;
pub const Orientation = global.Orientation;
pub const ClockDirection = global.ClockDirection;
pub const HorizontalAlignment = global.HorizontalAlignment;
pub const VerticalAlignment = global.VerticalAlignment;
pub const InlineAlignment = global.InlineAlignment;
pub const EulerOrder = global.EulerOrder;
pub const Key = global.Key;
pub const KeyModifierMask = global.KeyModifierMask;
pub const KeyLocation = global.KeyLocation;
pub const MouseButton = global.MouseButton;
pub const MouseButtonMask = global.MouseButtonMask;
pub const JoyButton = global.JoyButton;
pub const JoyAxis = global.JoyAxis;
pub const MIDIMessage = global.MidiMessage;
pub const Error = global.Error;
pub const PropertyHint = global.PropertyHint;
pub const PropertyUsageFlags = global.PropertyUsageFlags;
pub const MethodFlags = global.MethodFlags;
