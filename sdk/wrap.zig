//! Generated wrappers: the C-ABI functions of a script descriptor that the
//! host calls to create and destroy instances, call methods, read and write
//! properties and pass notifications.
//!
//! Host guarantees: `inst` is always a pointer that this descriptor's
//! `create` returned and `destroy` has not freed; `create` gets the
//! generation number the host gave `moduleInit`; calls on one instance do
//! not overlap. Everything else from the host (indexes, argument counts,
//! Variant contents) is checked, and a wrapper never panics on it.
//!
//! Variant storage: `call` always writes `ret` (NIL on every error), so
//! the host destroys it afterwards in every case. `get` and `get_default`
//! write `ret` only when they return 1. Every `ret` is uninitialised
//! storage on entry and an owned Variant after a write.
//!
//! Indexes: `method` indexes the descriptor's methods, `property` its
//! properties, group entries included (those have no value, so `get`,
//! `set` and `get_default` return 0 for them).
//!
//! Ownership:
//! - Arguments are borrowed for the call. A String, StringName, NodePath or
//!   `Ref` argument is a temporary that is released after the method
//!   returns; a method that keeps one must copy it (`String.copy`, or
//!   `Ref.set` on its own handle).
//! - A returned String, StringName, NodePath or `Ref` belongs to the
//!   wrapper, which writes it into `ret` and then releases it, so a method
//!   returns a new value, never a field's own value.
//! - `set` reads into a temporary first. Only when the read succeeds is the
//!   old field value released and the new one stored, so a failed `set`
//!   leaves the field as it was.
//! - `get_<field>` and `set_<field>` (`pub fn`, exact Zig names) replace
//!   direct field access; they follow the same rules as methods (the
//!   getter returns a new value; the setter's argument is borrowed).
//! - `destroy` calls `deinit` first, while every field is still intact, then
//!   releases each top-level String, StringName, NodePath and `Ref` field
//!   (an `Obj` holds no reference), then frees the memory.
//!
//! `notification` ignores `reversed`: a script is one class, so there is
//! no chain of classes whose order could be reversed.
const std = @import("std");
const abi = @import("ziggurat_abi");
const godot = @import("gdzig");
const convert = @import("convert.zig");
const object = @import("object.zig");
const runtime = @import("runtime.zig");

const b = godot.builtin;

/// The wrapper functions of script `S` at `rel`. `method_decls` are the
/// Zig names of the descriptor's methods in order, `properties` the
/// descriptor's properties, `defaults` the defaults image. `describe`
/// checks every signature these functions rely on.
pub fn Wrappers(
    comptime S: type,
    comptime rel: []const u8,
    comptime method_decls: []const [:0]const u8,
    comptime properties: []const abi.PropertyDesc,
    comptime defaults: *const S,
) type {
    return struct {
        const info = @typeInfo(S).@"struct";
        /// A host allocator may refuse 0 bytes; a field-less script still
        /// gets one byte. `destroy` frees the same size.
        const alloc_size: usize = @max(@sizeOf(S), 1);
        const alloc_align: u32 = @alignOf(S);

        fn hasPub(comptime name: []const u8) bool {
            for (info.decl_names) |d| {
                if (std.mem.eql(u8, d, name)) return true;
            }
            return false;
        }

        fn instance(inst: *anyopaque) *S {
            return @ptrCast(@alignCast(inst));
        }

        pub fn create(owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque {
            // Without moduleInit there is no allocator and no log.
            const h = runtime.hostApi() orelse return null;
            if (gen != runtime.generation()) {
                runtime.log(.err, "ziggurat: {s}: create got generation {d}, but this module is generation {d}.", .{ rel, gen, runtime.generation() });
                return null;
            }
            const raw = h.alloc(gen, alloc_size, alloc_align) orelse {
                runtime.log(.err, "ziggurat: {s}: could not allocate {d} bytes for a new instance.", .{ rel, alloc_size });
                return null;
            };
            if (@intFromPtr(raw) % alloc_align != 0) {
                runtime.log(.err, "ziggurat: {s}: the host returned instance memory that is not aligned to {d} bytes.", .{ rel, alloc_align });
                h.free(gen, raw, alloc_size, alloc_align);
                return null;
            }
            const self: *S = @ptrCast(@alignCast(raw));
            self.* = defaults.*;
            // `base` in the image is undefined; it is always set here.
            if (@hasField(S, "base")) self.base = @ptrCast(owner);
            if (comptime hasPub("init")) S.init(self);
            return raw;
        }

        pub fn destroy(inst: *anyopaque) callconv(.c) void {
            const self = instance(inst);
            if (comptime hasPub("deinit")) S.deinit(self);
            inline for (info.field_names) |name| {
                const FT = @FieldType(S, name);
                if (comptime ownsEngineValue(FT)) release(FT, &@field(self, name));
            }
            // Without a host the memory cannot be returned; moduleInit
            // always runs before any create, so this does not happen.
            const h = runtime.hostApi() orelse return;
            h.free(runtime.generation(), inst, alloc_size, alloc_align);
        }

        pub fn call(
            inst: *anyopaque,
            method: u32,
            args: [*]const *const anyopaque,
            argc: i64,
            ret: *anyopaque,
            err: *abi.CallError,
        ) callconv(.c) void {
            err.* = .{ .@"error" = abi.call_ok, .argument = 0, .expected = 0 };
            inline for (method_decls, 0..) |d, i| {
                if (method == i) return callMethod(d, instance(inst), args, argc, ret, err);
            }
            err.@"error" = abi.call_invalid_method;
            godot.raw.variantNewNil(ret);
        }

        fn callMethod(
            comptime d: []const u8,
            self: *S,
            args: [*]const *const anyopaque,
            argc: i64,
            ret: *anyopaque,
            err: *abi.CallError,
        ) void {
            const func = @field(S, d);
            const F = @TypeOf(func);
            const params = @typeInfo(F).@"fn".param_types[1..];
            const n: i64 = params.len;
            if (argc != n) {
                err.* = .{
                    .@"error" = if (argc < n) abi.call_too_few_arguments else abi.call_too_many_arguments,
                    .argument = 0,
                    .expected = params.len,
                };
                return godot.raw.variantNewNil(ret);
            }
            var tuple: std.meta.ArgsTuple(F) = undefined;
            tuple[0] = self;
            // Arguments read so far; only those are released.
            var done: usize = 0;
            defer {
                inline for (params, 0..) |P, i| {
                    if (comptime ownsEngineValue(P.?)) {
                        if (i < done) release(P.?, &tuple[i + 1]);
                    }
                }
            }
            inline for (params, 0..) |P, i| {
                if (convert.read(P.?, args[i], &tuple[i + 1])) |e| {
                    err.* = .{ .@"error" = abi.call_invalid_argument, .argument = i, .expected = @intCast(e.expected) };
                    return godot.raw.variantNewNil(ret);
                }
                done += 1;
            }
            const R = @typeInfo(F).@"fn".return_type.?;
            if (R == void) {
                @call(.auto, func, tuple);
                godot.raw.variantNewNil(ret);
            } else {
                var r: R = @call(.auto, func, tuple);
                writeOwned(R, &r, ret);
            }
        }

        pub fn get(inst: *anyopaque, property: u32, ret: *anyopaque) callconv(.c) u8 {
            inline for (properties, 0..) |p, i| {
                if (comptime p.field_index != abi.no_field) {
                    if (property == i) return getField(info.field_names[p.field_index], instance(inst), ret);
                }
            }
            return 0;
        }

        fn getField(comptime name: []const u8, self: *S, ret: *anyopaque) u8 {
            const FT = @FieldType(S, name);
            if (comptime hasPub("get_" ++ name)) {
                var v: FT = @field(S, "get_" ++ name)(self);
                writeOwned(FT, &v, ret);
            } else {
                convert.write(FT, &@field(self, name), ret);
            }
            return 1;
        }

        pub fn set(inst: *anyopaque, property: u32, value: *const anyopaque) callconv(.c) u8 {
            inline for (properties, 0..) |p, i| {
                if (comptime p.field_index != abi.no_field) {
                    if (property == i) return setField(info.field_names[p.field_index], instance(inst), value);
                }
            }
            return 0;
        }

        fn setField(comptime name: []const u8, self: *S, value: *const anyopaque) u8 {
            const FT = @FieldType(S, name);
            var tmp: FT = undefined;
            if (convert.read(FT, value, &tmp) != null) return 0;
            if (comptime hasPub("set_" ++ name)) {
                @field(S, "set_" ++ name)(self, tmp);
                if (comptime ownsEngineValue(FT)) release(FT, &tmp);
            } else {
                if (comptime ownsEngineValue(FT)) release(FT, &@field(self, name));
                @field(self, name) = tmp;
            }
            return 1;
        }

        pub fn getDefault(property: u32, ret: *anyopaque) callconv(.c) u8 {
            inline for (properties, 0..) |p, i| {
                if (comptime p.field_index != abi.no_field) {
                    if (property == i) {
                        const name = info.field_names[p.field_index];
                        convert.write(@FieldType(S, name), &@field(defaults, name), ret);
                        return 1;
                    }
                }
            }
            return 0;
        }

        pub fn notification(inst: *anyopaque, what: i32, reversed: u8) callconv(.c) void {
            _ = reversed;
            if (comptime hasPub("_notification")) S._notification(instance(inst), what);
        }
    };
}

/// True for the types whose values own an engine reference: String,
/// StringName, NodePath and `Ref`.
fn ownsEngineValue(comptime T: type) bool {
    if (T == b.String or T == b.StringName or T == b.NodePath) return true;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, object.handle_decl) and T.ziggurat_handle == .ref;
}

/// Releases the engine reference `p` owns.
fn release(comptime T: type, p: *T) void {
    if (T == b.String or T == b.StringName or T == b.NodePath) {
        p.deinit();
    } else {
        p.release();
    }
}

/// Writes `v` into `ret`, then releases `v`: the value's ownership moves
/// into the Variant.
fn writeOwned(comptime T: type, v: *T, ret: *anyopaque) void {
    convert.write(T, v, ret);
    if (comptime ownsEngineValue(T)) release(T, v);
}
