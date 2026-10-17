//! The curated Godot surface scripts see as `ziggurat.godot` (spec section 8):
//! `const g = @import("ziggurat").godot;` then `g.CharacterBody2D`,
//! `g.Vector2`, `g.Key`. Every name is the Godot name; each declaration is
//! the gdzig type itself, so values pass between the two freely.
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
//!   - Builtin value types: String, StringName, NodePath, Vector2, Vector2i,
//!     Rect2, Rect2i, Vector3, Vector3i, Transform2D, Vector4, Vector4i,
//!     Plane, Quaternion, AABB, Basis, Transform3D, Projection, Color, RID,
//!     Callable, Signal, Dictionary, Array, PackedByteArray,
//!     PackedInt32Array, PackedInt64Array, PackedFloat32Array,
//!     PackedFloat64Array, PackedStringArray, PackedVector2Array,
//!     PackedVector3Array, PackedColorArray, PackedVector4Array.
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
//! any of them, the withheld ones included.
const gdzig = @import("gdzig");
const builtin = gdzig.builtin;
const global = gdzig.global;

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
pub const Callable = builtin.Callable;
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
