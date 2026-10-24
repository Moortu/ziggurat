//! Compile-time checks on gdzig's class model, and the upcast that follows it.
//!
//! Ziggurat patch 4 (`PATCHES.md`): this file replaces the package that
//! upstream gdzig imports for the same names. It is part of gdzig and under
//! gdzig's MIT licence (`LICENSE`).
//!
//! The class model:
//!
//! - An *engine class* (opaque class) is an `opaque` type that declares
//!   `Base`: its parent engine class, or `void` for the root class
//!   (`Object`). Every class in the `Base` chain must be an engine class.
//!   gdzig generates these, for example
//!   `pub const Node = opaque { pub const Base = Object; ... }`.
//! - A *user class* (struct class) is a `struct` with a field named `base`.
//!   The field is either a mutable single-item pointer to a class
//!   (`base: *Node`; gdzig's singleton lookup also walks `base: *MyClass`),
//!   or an embedded user class (`base: ClassA`, so that a pointer to the
//!   child is also a pointer into its parent's storage). Other shapes of
//!   `base` (const, optional or many-item pointers, a non-class) do not make
//!   a class.
//!
//! The parent of a class is `BaseOf`; its ancestors are the parents up to
//! the root. A class "is a" class `Base` when `Base` is the class itself or
//! one of its ancestors.
//!
//! Every function here is evaluated at compile time. Classification
//! functions (`is...`) take any type and return false for types that are not
//! classes; the others need a class and fail compilation otherwise.

/// True when `T` is an engine class: an `opaque` type that declares a type
/// `Base` that is `void` or another engine class.
pub fn isOpaqueClass(comptime T: type) bool {
    return comptime isOpaqueClassImpl(T);
}

fn isOpaqueClassImpl(comptime T: type) bool {
    @setEvalBranchQuota(quota);
    if (@typeInfo(T) != .@"opaque") return false;
    if (!@hasDecl(T, "Base")) return false;
    if (@TypeOf(T.Base) != type) return false;
    return T.Base == void or isOpaqueClass(T.Base);
}

/// True when `T` is a user class: a `struct` whose field `base` is a
/// mutable single-item pointer to a class or an embedded user class.
pub fn isStructClass(comptime T: type) bool {
    return comptime isStructClassImpl(T);
}

fn isStructClassImpl(comptime T: type) bool {
    @setEvalBranchQuota(quota);
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasField(T, "base")) return false;
    return structParent(@FieldType(T, "base")) != null;
}

/// True when `T` is an engine class or a user class.
pub fn isClass(comptime T: type) bool {
    return comptime isOpaqueClass(T) or isStructClass(T);
}

/// True when `T` is a single-item pointer (const or not) to a class, such as
/// `*Node` or `*const MyClass`. Optionals (`?*Node`) and many-item pointers
/// are not class pointers.
pub fn isClassPtr(comptime T: type) bool {
    return comptime if (pointee(T)) |C| isClass(C) else false;
}

/// True when `T` is a single-item pointer (const or not) to an engine class.
pub fn isOpaqueClassPtr(comptime T: type) bool {
    return comptime if (pointee(T)) |C| isOpaqueClass(C) else false;
}

/// True when `T` is a single-item pointer (const or not) to a user class.
pub fn isStructClassPtr(comptime T: type) bool {
    return comptime if (pointee(T)) |C| isStructClass(C) else false;
}

/// The parent of class `T`: `T.Base` for an engine class (`void` for the
/// root), and for a user class the class its `base` points to or the user
/// class it embeds. A compile error when `T` is not a class.
pub fn BaseOf(comptime T: type) type {
    comptime {
        @setEvalBranchQuota(quota);
        if (isOpaqueClass(T)) return T.Base;
        if (isStructClass(T)) return structParent(@FieldType(T, "base")).?;
        @compileError("expected a class type, found '" ++ @typeName(T) ++ "'");
    }
}

/// The ancestors of class `T`, nearest first: its parent, the parent's
/// parent, and so on up to the root engine class. Empty for the root. A
/// compile error when `T` is not a class.
pub fn ancestorsOf(comptime T: type) []const type {
    comptime {
        @setEvalBranchQuota(quota);
        const n = depthOf(T);
        var list: [n]type = undefined;
        var C = T;
        for (&list) |*slot| {
            C = BaseOf(C);
            slot.* = C;
        }
        const final = list;
        return &final;
    }
}

/// `T` followed by `ancestorsOf(T)`. A compile error when `T` is not a class.
pub fn selfAndAncestorsOf(comptime T: type) []const type {
    comptime {
        @setEvalBranchQuota(quota);
        const ancestors = ancestorsOf(T);
        const final = [_]type{T} ++ ancestors[0..ancestors.len].*;
        return &final;
    }
}

/// The number of ancestors of class `T`: 0 for the root engine class, 1 for
/// its direct children, and so on. A compile error when `T` is not a class.
pub fn depthOf(comptime T: type) usize {
    return comptime depthOfImpl(T);
}

fn depthOfImpl(comptime T: type) usize {
    @setEvalBranchQuota(quota);
    var n: usize = 0;
    var C = BaseOf(T);
    while (C != void) : (C = BaseOf(C)) n += 1;
    return n;
}

/// True when `T` is a class and `Base` is `T` itself or one of its
/// ancestors. False, not a compile error, when either type is not a class.
pub fn isA(comptime Base: type, comptime T: type) bool {
    return comptime isAImpl(Base, T);
}

fn isAImpl(comptime Base: type, comptime T: type) bool {
    @setEvalBranchQuota(quota);
    if (!isClass(T) or !isClass(Base)) return false;
    for (selfAndAncestorsOf(T)) |C| {
        if (C == Base) return true;
    }
    return false;
}

/// True when `isA(B, T)` holds for at least one type `B` in `Bases`, a tuple
/// or array of types. False for an empty `Bases`.
pub fn isAny(comptime Bases: anytype, comptime T: type) bool {
    return comptime isAnyImpl(Bases, T);
}

fn isAnyImpl(comptime Bases: anytype, comptime T: type) bool {
    @setEvalBranchQuota(quota);
    for (Bases) |B| {
        if (isA(B, T)) return true;
    }
    return false;
}

/// A compile error unless `isA(Base, T)`.
pub fn assertIsA(comptime Base: type, comptime T: type) void {
    comptime {
        if (!isA(Base, T))
            @compileError("expected '" ++ @typeName(T) ++ "' to be a class that inherits '" ++ @typeName(Base) ++ "'");
    }
}

/// A compile error unless `isAny(Bases, T)`.
pub fn assertIsAny(comptime Bases: anytype, comptime T: type) void {
    comptime {
        if (!isAny(Bases, T))
            @compileError("expected '" ++ @typeName(T) ++ "' to be a class that inherits one of " ++ std.fmt.comptimePrint("{any}", .{Bases}));
    }
}

/// Converts `value`, a single-item pointer to a class `Source`, into `P`, a
/// single-item pointer to `Source` itself or one of its ancestors. Free at
/// run time: an engine class pointer keeps its address, a user class gives
/// the address of its embedded parent, and a `base` pointer is read.
///
/// Compile errors: `P` is not a single-item class pointer; `value` is not
/// one (an optional must be unwrapped first); the target class is not
/// `Source` or an ancestor of it; or `value` is const and `P` is not.
pub fn upcast(comptime P: type, value: anytype) P {
    const V = @TypeOf(value);
    comptime {
        if (!isClassPtr(P))
            @compileError("upcast expects a class pointer type as the target type, found '" ++ @typeName(P) ++ "'");
        if (!isClassPtr(V))
            @compileError("upcast expects a class pointer as the value, found '" ++ @typeName(V) ++ "'");
        if (@typeInfo(V).pointer.attrs.@"const" and !@typeInfo(P).pointer.attrs.@"const")
            @compileError("upcast cannot drop const: '" ++ @typeName(V) ++ "' to '" ++ @typeName(P) ++ "'");
    }
    const Source = @typeInfo(V).pointer.child;
    const Target = @typeInfo(P).pointer.child;
    comptime assertIsA(Target, Source);

    if (Source == Target) return value;
    if (comptime isStructClass(Source)) {
        return switch (@typeInfo(@FieldType(Source, "base"))) {
            .pointer => upcast(P, value.base),
            else => upcast(P, &value.base),
        };
    }
    return @ptrCast(value);
}

/// The comptime branch quota of the class walks: an engine class chain is
/// about ten classes deep, and every step is a few calls.
const quota = 100_000;

/// The type a single-item pointer `T` points to, or null for any other type.
fn pointee(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .one) p.child else null,
        else => null,
    };
}

/// The parent class named by a `base` field of type `F`, or null when `F`
/// does not make a user class.
fn structParent(comptime F: type) ?type {
    return switch (@typeInfo(F)) {
        .pointer => |p| if (p.size == .one and !p.attrs.@"const" and isClass(p.child)) p.child else null,
        .@"struct" => if (isStructClass(F)) F else null,
        else => null,
    };
}

// Test fixtures: a small engine (opaque) hierarchy Root <- Mid <- Leaf,
// a sibling Other, a user (struct) chain UserA <- UserB <- UserC on top of
// Mid, and shapes that are not classes.
const Root = opaque {
    pub const Base = void;
};
const Mid = opaque {
    pub const Base = Root;
};
const Leaf = opaque {
    pub const Base = Mid;
};
const Other = opaque {
    pub const Base = Root;
};
const NoBase = opaque {};
const IntBase = opaque {
    pub const Base = u32;
};
const ValueBase = opaque {
    pub const Base = 3;
};
const BrokenChain = opaque {
    pub const Base = NoBase;
};
const UserA = struct {
    base: *Mid,
    a: u32 = 1,
};
const UserB = struct {
    base: UserA,
    b: u32 = 2,
};
const UserC = struct {
    c: u32 = 3,
    base: UserB,
};
const ConstPtrBase = struct { base: *const Mid };
const OptionalBase = struct { base: ?*Mid };
const ManyPtrBase = struct { base: [*]UserA };
const PtrToUserBase = struct { base: *UserA, p: u32 = 4 };
const IntField = struct { base: u32 };
const NoBaseField = struct { x: u32 };
const NotAClassBase = struct { base: NoBaseField };
const Tuple = struct { u32, u32 };

const testing = std.testing;

fn typesEql(comptime a: []const type, comptime b: []const type) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

test isOpaqueClass {
    try testing.expect(comptime isOpaqueClass(Root));
    try testing.expect(comptime isOpaqueClass(Mid));
    try testing.expect(comptime isOpaqueClass(Leaf));
    try testing.expect(!comptime isOpaqueClass(NoBase));
    try testing.expect(!comptime isOpaqueClass(IntBase));
    try testing.expect(!comptime isOpaqueClass(ValueBase));
    try testing.expect(!comptime isOpaqueClass(BrokenChain));
    try testing.expect(!comptime isOpaqueClass(anyopaque));
    try testing.expect(!comptime isOpaqueClass(UserA));
    try testing.expect(!comptime isOpaqueClass(*Mid));
    try testing.expect(!comptime isOpaqueClass(u32));
    try testing.expect(!comptime isOpaqueClass(void));
}

test isStructClass {
    try testing.expect(comptime isStructClass(UserA));
    try testing.expect(comptime isStructClass(UserB));
    try testing.expect(comptime isStructClass(UserC));
    try testing.expect(!comptime isStructClass(Mid));
    try testing.expect(!comptime isStructClass(ConstPtrBase));
    try testing.expect(!comptime isStructClass(OptionalBase));
    try testing.expect(!comptime isStructClass(ManyPtrBase));
    try testing.expect(comptime isStructClass(PtrToUserBase));
    try testing.expect(!comptime isStructClass(IntField));
    try testing.expect(!comptime isStructClass(NoBaseField));
    try testing.expect(!comptime isStructClass(NotAClassBase));
    try testing.expect(!comptime isStructClass(Tuple));
    try testing.expect(!comptime isStructClass(*UserA));
    try testing.expect(!comptime isStructClass(u8));
}

test isClass {
    try testing.expect(comptime isClass(Root));
    try testing.expect(comptime isClass(Leaf));
    try testing.expect(comptime isClass(UserA));
    try testing.expect(comptime isClass(UserC));
    try testing.expect(!comptime isClass(NoBase));
    try testing.expect(!comptime isClass(NoBaseField));
    try testing.expect(!comptime isClass(*Mid));
    try testing.expect(!comptime isClass(?*Mid));
    try testing.expect(!comptime isClass(void));
    try testing.expect(!comptime isClass(i64));
}

test isClassPtr {
    try testing.expect(comptime isClassPtr(*Mid));
    try testing.expect(comptime isClassPtr(*const Mid));
    try testing.expect(comptime isClassPtr(*UserB));
    try testing.expect(comptime isClassPtr(*const UserB));
    try testing.expect(!comptime isClassPtr(Mid));
    try testing.expect(!comptime isClassPtr(?*Mid));
    try testing.expect(!comptime isClassPtr([*]UserA));
    try testing.expect(!comptime isClassPtr([]UserA));
    try testing.expect(!comptime isClassPtr(**Mid));
    try testing.expect(!comptime isClassPtr(*anyopaque));
    try testing.expect(!comptime isClassPtr(*NoBaseField));
    try testing.expect(!comptime isClassPtr(*u32));
    try testing.expect(!comptime isClassPtr(u32));
}

test isOpaqueClassPtr {
    try testing.expect(comptime isOpaqueClassPtr(*Root));
    try testing.expect(comptime isOpaqueClassPtr(*const Leaf));
    try testing.expect(!comptime isOpaqueClassPtr(*UserA));
    try testing.expect(!comptime isOpaqueClassPtr(?*Leaf));
    try testing.expect(!comptime isOpaqueClassPtr(Leaf));
    try testing.expect(!comptime isOpaqueClassPtr(*anyopaque));
}

test isStructClassPtr {
    try testing.expect(comptime isStructClassPtr(*UserA));
    try testing.expect(comptime isStructClassPtr(*const UserC));
    try testing.expect(!comptime isStructClassPtr(*Mid));
    try testing.expect(!comptime isStructClassPtr(?*UserA));
    try testing.expect(!comptime isStructClassPtr(UserA));
    try testing.expect(!comptime isStructClassPtr(*NoBaseField));
}

test BaseOf {
    try testing.expect(BaseOf(Root) == void);
    try testing.expect(BaseOf(Mid) == Root);
    try testing.expect(BaseOf(Leaf) == Mid);
    try testing.expect(BaseOf(UserA) == Mid);
    try testing.expect(BaseOf(UserB) == UserA);
    try testing.expect(BaseOf(UserC) == UserB);
    try testing.expect(BaseOf(PtrToUserBase) == UserA);
}

test ancestorsOf {
    try testing.expect(comptime typesEql(ancestorsOf(Root), &.{}));
    try testing.expect(comptime typesEql(ancestorsOf(Leaf), &.{ Mid, Root }));
    try testing.expect(comptime typesEql(ancestorsOf(UserC), &.{ UserB, UserA, Mid, Root }));
}

test selfAndAncestorsOf {
    try testing.expect(comptime typesEql(selfAndAncestorsOf(Root), &.{Root}));
    try testing.expect(comptime typesEql(selfAndAncestorsOf(Leaf), &.{ Leaf, Mid, Root }));
    try testing.expect(comptime typesEql(selfAndAncestorsOf(UserA), &.{ UserA, Mid, Root }));
    // Usable with `inline for`, as gdzig's vtable lookup does.
    comptime var n: usize = 0;
    inline for (comptime selfAndAncestorsOf(UserC)) |C| {
        if (@hasDecl(C, "Base")) n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
}

test depthOf {
    try testing.expectEqual(@as(usize, 0), comptime depthOf(Root));
    try testing.expectEqual(@as(usize, 1), comptime depthOf(Other));
    try testing.expectEqual(@as(usize, 2), comptime depthOf(Leaf));
    try testing.expectEqual(@as(usize, 2), comptime depthOf(UserA));
    try testing.expectEqual(@as(usize, 4), comptime depthOf(UserC));
    try testing.expectEqual(@as(usize, 3), comptime depthOf(PtrToUserBase));
}

test isA {
    try testing.expect(comptime isA(Root, Root));
    try testing.expect(comptime isA(Root, Leaf));
    try testing.expect(comptime isA(Mid, Leaf));
    try testing.expect(comptime isA(Leaf, Leaf));
    try testing.expect(comptime isA(Root, UserC));
    try testing.expect(comptime isA(Mid, UserC));
    try testing.expect(comptime isA(UserA, UserC));
    try testing.expect(comptime isA(UserC, UserC));
    // Upward only, and never across siblings.
    try testing.expect(!comptime isA(Leaf, Mid));
    try testing.expect(!comptime isA(UserC, UserA));
    try testing.expect(!comptime isA(Other, Leaf));
    try testing.expect(!comptime isA(Leaf, UserC));
    // Non-classes on either side are false, not compile errors.
    try testing.expect(!comptime isA(Root, NoBase));
    try testing.expect(!comptime isA(Root, anyopaque));
    try testing.expect(!comptime isA(Root, u32));
    try testing.expect(!comptime isA(Root, *Leaf));
    try testing.expect(!comptime isA(void, Root));
    try testing.expect(!comptime isA(u32, u32));
}

test isAny {
    try testing.expect(comptime isAny(.{ Other, Mid }, Leaf));
    try testing.expect(comptime isAny(.{UserB}, UserC));
    try testing.expect(comptime isAny([_]type{ Leaf, Root }, Other));
    try testing.expect(!comptime isAny(.{ Other, Leaf }, Mid));
    try testing.expect(!comptime isAny(.{}, Leaf));
    try testing.expect(!comptime isAny(.{Root}, u32));
}

test assertIsA {
    // A failing assertion is a compile error, so only passing cases can run.
    comptime assertIsA(Root, Leaf);
    comptime assertIsA(Mid, UserC);
    comptime assertIsA(UserB, UserB);
    assertIsA(UserA, UserB);
}

test assertIsAny {
    comptime assertIsAny(.{ Other, Mid }, Leaf);
    assertIsAny(.{UserA}, UserC);
}

test upcast {
    var storage: u8 = 0;
    const mid: *Mid = @ptrCast(&storage);
    const leaf: *Leaf = @ptrCast(&storage);
    var c: UserC = .{ .base = .{ .base = .{ .base = mid } } };

    // Engine classes: the same address as the parent type.
    try testing.expect(upcast(*Mid, leaf) == mid);
    try testing.expect(@intFromPtr(upcast(*Root, leaf)) == @intFromPtr(&storage));
    try testing.expect(upcast(*Leaf, leaf) == leaf);
    try testing.expect(upcast(*const Root, leaf) == @as(*const Root, @ptrCast(&storage)));

    // User classes: the embedded parent, then the engine object it holds.
    try testing.expect(upcast(*UserC, &c) == &c);
    try testing.expect(upcast(*UserB, &c) == &c.base);
    try testing.expect(upcast(*UserA, &c) == &c.base.base);
    try testing.expect(upcast(*Mid, &c) == mid);
    try testing.expect(@intFromPtr(upcast(*Root, &c)) == @intFromPtr(&storage));
    try testing.expect(upcast(*Mid, &c.base.base) == mid);

    // A `base` pointer to a user class is followed.
    var p: PtrToUserBase = .{ .base = &c.base.base };
    try testing.expect(upcast(*UserA, &p) == &c.base.base);
    try testing.expect(upcast(*Mid, &p) == mid);

    // A const source gives a const target.
    const cc: *const UserC = &c;
    try testing.expect(upcast(*const UserA, cc) == &c.base.base);
    try testing.expect(upcast(*const Mid, cc) == mid);
}

test "the bool and count checks can be called outside a comptime scope" {
    // gdzig calls them in plain `if` conditions, such as
    // `if (class.isOpaqueClass(T))` in Object.downcast.
    var results = [_]bool{
        isOpaqueClass(Mid), isStructClass(UserA),         isClass(Leaf),
        isClassPtr(*UserB), isOpaqueClassPtr(*Leaf),      isStructClassPtr(*UserC),
        isA(Root, UserC),   isAny(.{ Other, Mid }, Leaf), depthOf(Leaf) == 2,
    };
    _ = &results;
    for (results) |r| try testing.expect(r);
}

test {
    // The singleton-owner lookup is built on `selfAndAncestorsOf`; its tests
    // run with these (gdzig's `test-singleton` step roots here).
    _ = @import("compat/singleton.zig");
}

const std = @import("std");
