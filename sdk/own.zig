//! Ownership helpers for engine values that hold a reference: String,
//! StringName, NodePath and `Ref(T)`, and the owning field types `String`,
//! `StringName` and `NodePath` of this file (`z.String`, ...).
//!
//! Rules at the script boundary (see `wrap.zig`):
//! - A script field that holds text has an owning type: `z.String`,
//!   `z.StringName` or `z.NodePath`, never the engine's own type (`describe`
//!   refuses that). `field.set(v)` stores its own copy of the borrowed `v`
//!   and releases the old text; `field.get()` gives the text, borrowed from
//!   the field. `self.name = v` with a borrowed `v` is then a type error, as
//!   is `Owned(String).init(self.name)`.
//! - Arguments are borrowed for the length of the call. A method or setter
//!   that keeps a String, StringName or NodePath stores it with the field's
//!   `set`; one that keeps a `Ref` stores it with `assign`, which takes its
//!   own reference. Both take their own copy or reference, so the value the
//!   wrapper releases when the call returns is never kept.
//! - Plain return values are borrowed: the wrapper writes a copy into the
//!   result Variant and leaves the returned value alone, so `return
//!   self.title.get();` is correct. A method that returns a value it made itself
//!   returns `Owned(T)`, and the wrapper releases that value after the
//!   write. A new value returned without `Owned` leaks (the in-Godot leak
//!   checks report it); it never dangles.
//! - A new RefCounted object comes from `T.init()` with one reference that
//!   the caller owns. Wrap it with `Ref(T).adopt`, which takes that
//!   reference over: `return .init(.adopt(T.init()));` for a method that
//!   returns `Owned(Ref(T))`. The same holds for a RefCounted that an
//!   engine method returns (`ResourceLoader.load`, `Resource.duplicate`):
//!   Godot gives the caller one reference. `Ref.set` adds a reference of
//!   its own, so `set(T.init())` or `set(loaded)` leaks one.
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
    if (isText(T))
        @compileError("ziggurat: " ++ textName(T) ++ " is a field type; use the engine value from .get(), and .set() to store one");
    if (!ownsEngineValue(T))
        @compileError("ziggurat: " ++ @typeName(T) ++ " holds no engine reference; only String, StringName, NodePath and Ref(T) do");
}

/// A return value that hands a new String, StringName, NodePath or `Ref`
/// to the caller: `return .init(s);`, or `return .init(.adopt(T.init()));`
/// for a new RefCounted object. The wrapper writes `value` into the result
/// and then releases it.
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
/// safe. A `z.String`, `z.StringName` or `z.NodePath` field stores text
/// with its own `set` instead.
pub fn assign(dst: anytype, src: anytype) void {
    const P = @TypeOf(dst);
    const info = @typeInfo(P);
    if (info != .pointer or info.pointer.size != .one or info.pointer.attrs.@"const")
        @compileError("ziggurat: assign needs a mutable pointer as its first argument, found " ++ @typeName(P));
    const T = info.pointer.child;
    if (comptime isText(T))
        @compileError("ziggurat: store text in a " ++ textName(T) ++ " field with field.set(value), not assign");
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

/// An owning String field: `name: z.String = .empty`. `set` stores its own
/// copy of a borrowed String and releases the old one; `get` returns the
/// text, borrowed from the field (valid until the next `set` or the
/// instance's destroy). The instance's destroy releases it.
pub const String = extern struct {
    pub const ziggurat_text = b.String;
    pub const empty: String = .{ .raw = std.mem.zeroes(b.String) };

    /// The engine value. Use `set` and `get`; storing into `raw` directly
    /// skips the copy and the release.
    raw: b.String,

    pub fn set(self: *String, value: b.String) void {
        setText(b.String, &self.raw, value);
    }

    pub fn get(self: *const String) b.String {
        return self.raw;
    }
};

/// An owning StringName field: `tag: z.StringName = .empty`. As `String`.
pub const StringName = extern struct {
    pub const ziggurat_text = b.StringName;
    pub const empty: StringName = .{ .raw = std.mem.zeroes(b.StringName) };

    /// The engine value. Use `set` and `get`.
    raw: b.StringName,

    pub fn set(self: *StringName, value: b.StringName) void {
        setText(b.StringName, &self.raw, value);
    }

    pub fn get(self: *const StringName) b.StringName {
        return self.raw;
    }
};

/// An owning NodePath field: `target: z.NodePath = .empty`. As `String`.
pub const NodePath = extern struct {
    pub const ziggurat_text = b.NodePath;
    pub const empty: NodePath = .{ .raw = std.mem.zeroes(b.NodePath) };

    /// The engine value. Use `set` and `get`.
    raw: b.NodePath,

    pub fn set(self: *NodePath, value: b.NodePath) void {
        setText(b.NodePath, &self.raw, value);
    }

    pub fn get(self: *const NodePath) b.NodePath {
        return self.raw;
    }
};

/// Copies first, so setting a field to its own text never reads a
/// released value.
fn setText(comptime T: type, dst: *T, value: T) void {
    const fresh = T.copy(value);
    var old = dst.*;
    dst.* = fresh;
    old.deinit();
}

/// True for the owning field types `String`, `StringName` and `NodePath`.
pub fn isText(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "ziggurat_text");
}

/// `z.String`, `z.StringName` or `z.NodePath`, for messages.
pub fn textName(comptime T: type) []const u8 {
    return if (T.ziggurat_text == b.String) "z.String" else if (T.ziggurat_text == b.StringName) "z.StringName" else "z.NodePath";
}

/// True for a field type whose value the instance's destroy releases: the
/// types of `ownsEngineValue` and the owning text fields.
pub fn fieldOwns(comptime T: type) bool {
    return isText(T) or ownsEngineValue(T);
}

/// Releases what a field of type `T` holds (see `fieldOwns`).
pub fn releaseField(comptime T: type, p: *T) void {
    if (comptime isText(T)) {
        p.raw.deinit();
    } else {
        release(T, p);
    }
}

/// The type a field's `get_<field>` override returns and its `set_<field>`
/// override takes: the borrowed engine type for a text field, else `T`.
pub fn Access(comptime T: type) type {
    return if (isText(T)) T.ziggurat_text else T;
}

/// The value of field `p` as `Access(T)`, borrowed from the field.
pub fn access(comptime T: type, p: *const T) Access(T) {
    return if (comptime isText(T)) p.raw else p.*;
}
