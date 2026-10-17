//! Ownership helpers for engine values that hold a reference: String,
//! StringName, NodePath and `Ref(T)`.
//!
//! Rules at the script boundary (see `wrap.zig`):
//! - Arguments are borrowed for the length of the call. A method or setter
//!   that keeps one stores it with `assign`, which takes its own copy or
//!   reference. `self.name = v` would keep a value the wrapper releases
//!   when the call returns.
//! - Plain return values are borrowed: the wrapper writes a copy into the
//!   result Variant and leaves the returned value alone, so `return
//!   self.title;` is correct. A method that returns a value it made itself
//!   returns `Owned(T)`, and the wrapper releases that value after the
//!   write. A new value returned without `Owned` leaks (the in-Godot leak
//!   checks report it); it never dangles.
const std = @import("std");
const godot = @import("gdzig");
const object = @import("object.zig");

const b = godot.builtin;

/// True for the types whose values own an engine reference: String,
/// StringName, NodePath and `Ref`.
pub fn ownsEngineValue(comptime T: type) bool {
    if (T == b.String or T == b.StringName or T == b.NodePath) return true;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, object.handle_decl) and T.ziggurat_handle == .ref;
}

/// Releases the engine reference `p` owns.
pub fn release(comptime T: type, p: *T) void {
    comptime requireOwning(T);
    if (T == b.String or T == b.StringName or T == b.NodePath) {
        p.deinit();
    } else {
        p.release();
    }
}

fn requireOwning(comptime T: type) void {
    if (!ownsEngineValue(T))
        @compileError("ziggurat: " ++ @typeName(T) ++ " holds no engine reference; only String, StringName, NodePath and Ref(T) do");
}

/// A return value that hands a new String, StringName, NodePath or `Ref`
/// to the caller: `return .init(s);`. The wrapper writes `value` into the
/// result and then releases it.
pub fn Owned(comptime T: type) type {
    comptime requireOwning(T);
    return struct {
        pub const ziggurat_owned = T;

        value: T,

        pub fn init(value: T) @This() {
            return .{ .value = value };
        }
    };
}

/// True when `R` is an `Owned(T)`.
pub fn isOwned(comptime R: type) bool {
    return @typeInfo(R) == .@"struct" and @hasDecl(R, "ziggurat_owned");
}

/// The type a return type `R` is written as: `T` for `Owned(T)`, else `R`.
pub fn ReturnValue(comptime R: type) type {
    return if (isOwned(R)) R.ziggurat_owned else R;
}

/// Stores `src` in `dst.*` with its own copy (String, StringName,
/// NodePath) or its own reference (`Ref`), then releases the value `dst`
/// held before. `src` stays the caller's. Assigning a value to itself is
/// safe.
pub fn assign(dst: anytype, src: anytype) void {
    const P = @TypeOf(dst);
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const")
        @compileError("ziggurat: assign needs a mutable pointer as its first argument, found " ++ @typeName(P));
    const T = info.pointer.child;
    comptime requireOwning(T);
    const src_value: T = src;
    if (T == b.String or T == b.StringName or T == b.NodePath) {
        // Copy first, so `assign(&x, x)` never reads a released value.
        const fresh = T.copy(src_value);
        var old = dst.*;
        dst.* = fresh;
        old.deinit();
    } else {
        // `Ref.set` takes the new reference before it drops the old one.
        dst.set(src_value.get());
    }
}
