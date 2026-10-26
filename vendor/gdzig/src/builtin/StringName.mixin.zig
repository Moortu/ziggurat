pub const empty: StringName = std.mem.zeroes(StringName);

/// Creates a StringName from a Latin-1 encoded C string.
///
/// If `is_static` is true, then:
/// - The StringName will reuse the `str` buffer instead of copying it.
///   You must guarantee that the buffer remains valid for the duration of the application (e.g. string literal).
/// - You must not call a destructor for this StringName. Incrementing the initial reference once should achieve this.
///
/// On Godot 4.1, falls back to creating via String (ignores `is_static`).
pub inline fn fromLatin1(str: [:0]const u8, is_static: bool) StringName {
    if (raw.stringNameNewWithLatin1Chars) |func| {
        var result: StringName = undefined;
        func(result.ptr(), @ptrCast(str.ptr), @intFromBool(is_static));
        return result;
    }
    return viaString(str);
}

/// Creates a StringName from a comptime Latin-1 encoded C string.
///
/// The string is treated as static and the result is cached per unique string.
///
/// Safe to call from several threads at once. Ziggurat patch 5
/// (vendor/gdzig/PATCHES.md): the cache is published with release and read
/// with acquire ordering. Threads that race to fill it each build a name;
/// one stores it and the others return their own copy. A copy is never
/// freed: freeing a static StringName twice deadlocks Godot, and the extra
/// reference only keeps an interned name alive.
pub fn fromComptimeLatin1(comptime str: [:0]const u8) StringName {
    const S = struct {
        const key = str;
        var value: StringName = undefined;
        var state: CacheState = .empty;
    };

    if (@atomicLoad(CacheState, &S.state, .acquire) == .ready) return S.value;

    var made: StringName = undefined;
    if (raw.stringNameNewWithLatin1Chars) |func| {
        func(@ptrCast(&made), @ptrCast(str.ptr), 1);
    } else {
        made = viaString(str);
    }

    // Only the thread that moves the state from `empty` writes `value`.
    if (@cmpxchgStrong(CacheState, &S.state, .empty, .filling, .monotonic, .monotonic) == null) {
        S.value = made;
        @atomicStore(CacheState, &S.state, .ready, .release);
    }
    return made;
}

/// The fill state of the `fromComptimeLatin1` cache (Ziggurat patch 5).
const CacheState = enum(u8) { empty, filling, ready };

/// Creates a StringName from a UTF-8 encoded string.
///
/// On Godot 4.1, falls back to creating via String.
pub inline fn fromUtf8(str: []const u8) StringName {
    if (raw.stringNameNewWithUtf8CharsAndLen) |func| {
        var result: StringName = undefined;
        func(result.ptr(), @ptrCast(str.ptr), @intCast(str.len));
        return result;
    }

    var gd_string: String = undefined;
    raw.stringNewWithUtf8CharsAndLen(gd_string.ptr(), @ptrCast(str.ptr), @intCast(str.len));
    defer gd_string.deinit();
    return StringName.fromString(gd_string);
}

/// Creates a StringName from a null-terminated UTF-8 C string.
///
/// On Godot 4.1, falls back to creating via String.
pub inline fn fromNullTerminatedUtf8(str: [:0]const u8) StringName {
    if (raw.stringNameNewWithUtf8Chars) |func| {
        var result: StringName = undefined;
        func(result.ptr(), @ptrCast(str.ptr));
        return result;
    }

    return viaString(str);
}

pub fn fromType(comptime T: type) StringName {
    return fromTypeName(typeShortName(T));
}

pub fn fromSignal(comptime S: type) StringName {
    return fromSignalName(typeShortName(S));
}

pub fn fromTypeName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.type, name);
    return fromComptimeLatin1(converted);
}

pub fn fromConstantName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.constant, name);
    return fromComptimeLatin1(converted);
}

pub fn fromFunctionName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.func, name);
    return fromComptimeLatin1(converted);
}

pub fn fromMethodName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.method, name);
    return fromComptimeLatin1(converted);
}

pub fn fromPropertyName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.field, name);
    return fromComptimeLatin1(converted);
}

pub fn fromSignalName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.signal, name);
    return fromComptimeLatin1(converted);
}

pub fn fromVirtualMethodName(comptime name: []const u8) StringName {
    const converted = comptime casez.comptimeConvert(godot_case.virtual_method, name);
    return fromComptimeLatin1(converted);
}

/// Creates a StringName via an intermediate String (4.1 fallback).
fn viaString(str: [:0]const u8) StringName {
    var gd_string: String = undefined;
    raw.stringNewWithUtf8Chars(gd_string.ptr(), @ptrCast(str.ptr));
    defer gd_string.deinit();
    return StringName.fromString(gd_string);
}

fn typeShortName(comptime T: type) [:0]const u8 {
    const full = @typeName(T);
    const pos = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[pos + 1 ..];
}

/// Returns a Variant that borrows this StringName.
///
/// No allocation and no ownership transfer: the Variant stores a copy of the
/// string handle, so the StringName must outlive the returned Variant and
/// calling `Variant.deinit` on the result is illegal behavior. Call `.clone()`
/// on the result to get an owned Variant instead.
pub fn asVariant(self: *const StringName) Variant {
    return Variant.wrap(StringName, self);
}

test "asVariant borrows without allocation" {
    const name: StringName = .empty;
    const variant = name.asVariant();
    try std.testing.expectEqual(Variant.Tag.string_name, variant.tag);
    try std.testing.expectEqual(name, variant.data.string_name);
}

const casez = @import("casez");
const common = @import("common");
const godot_case = common.godot_case;

// @mixin stop

const std = @import("std");
const DeclEnum = std.meta.DeclEnum;

const gdzig = @import("gdzig");
const raw = &gdzig.raw;
const String = gdzig.builtin.String;
const StringName = gdzig.builtin.StringName;
