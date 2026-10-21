//! Generated wrappers: the C-ABI functions of a script descriptor that the
//! host calls to create and destroy instances, call methods, read and write
//! properties and pass notifications.
//!
//! The host's side of these rules is the host contract in `src/abi/abi.zig`
//! (what a host imports); keep the two in step.
//!
//! Host guarantees: `inst` is always a pointer that this descriptor's
//! `create` or `create_blank` returned and `destroy` has not freed;
//! `create` and `create_blank` get the generation number the host gave
//! `moduleInit`; calls on one instance do not overlap. Everything else
//! from the host (indexes, argument counts, Variant contents) is checked,
//! and a wrapper never panics on it.
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
//! `args` may be null when `argc` is 0. A null `args` with a matching
//! non-zero `argc` is INVALID_ARGUMENT at argument 0.
//!
//! Ownership (helpers in `own.zig`):
//! - Text fields have the owning types `z.String`, `z.StringName` and
//!   `z.NodePath`; a field of the engine's own String, StringName or
//!   NodePath type fails in `describe`. The wrappers read and write such a
//!   field as the text it holds.
//! - Arguments are borrowed for the length of the call. A String,
//!   StringName, NodePath or `Ref` argument is a temporary that is released
//!   after the method returns; a method or setter that keeps one stores it
//!   with `self.field.set(value)` (text) or `z.assign(&self.field, value)`
//!   (`Ref`), which take their own copy or reference and release the old
//!   value. `self.field = value` does not compile for a text field.
//! - Plain return values are borrowed too: Godot's from-type constructor
//!   copies a String, StringName or NodePath and takes the Variant's own
//!   reference to an object, so the wrapper writes `ret` and leaves the
//!   returned value alone (`return self.title.get();`, a `*const String`,
//!   is correct). A method that
//!   returns a value it made itself returns `z.Owned(T)`; the wrapper
//!   releases `value` after the write. A new value returned without
//!   `Owned` leaks, which the in-Godot leak checks report; it never dangles.
//! - `set` reads into a temporary first. Only when the read succeeds is the
//!   old field value released and the new one stored, so a failed `set`
//!   leaves the field as it was.
//! - `get_<field>` and `set_<field>` (`pub fn`, exact Zig names) replace
//!   direct field access; they follow the same rules as methods (the
//!   getter's plain return value is borrowed, `Owned` is released; the
//!   setter's argument is borrowed). For a `z.String` field they return
//!   and take `String` (likewise StringName and NodePath).
//! - `destroy` calls `deinit` first, while every field is still intact, then
//!   releases each top-level `z.String`, `z.StringName`, `z.NodePath` and
//!   `Ref` field (an `Obj` holds no reference), then frees the memory. `deinit` need not
//!   release those fields itself; a second release is harmless.
//!   `deinit` runs while Godot is destroying the owner (from the script
//!   instance's free, inside `~Object`), so it must not use `base`; cleanup
//!   that needs the owner belongs in `_notification` on NOTIFICATION_PREDELETE.
//!
//! `notification` ignores `reversed`: a script is one class, so there is
//! no chain of classes whose order could be reversed.
const std = @import("std");
const abi = @import("ziggurat_abi");
const godot = @import("gdzig");
const convert = @import("convert.zig");
const runtime = @import("runtime.zig");
const own = @import("own.zig");
const ownsEngineValue = own.ownsEngineValue;
const release = own.release;
const fieldOwns = own.fieldOwns;
const releaseField = own.releaseField;

/// `v` as a run-time value. A comptime-known value in a `runtime.log`
/// argument tuple is a comptime tuple field, which makes the tuple type, and
/// with it a formatter instance, unique per script (about 5 ms of analysis
/// each); run-time values share one instance across scripts.
fn rt(comptime T: type, v: T) T {
    return v;
}

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

        /// A `pub` declaration of `S` (`@hasDecl` from this file sees only
        /// those).
        fn hasPub(comptime name: []const u8) bool {
            return @hasDecl(S, name);
        }

        fn instance(inst: *anyopaque) *S {
            return @ptrCast(@alignCast(inst));
        }

        pub fn create(owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque {
            const raw = make(owner, gen, "create") orelse return null;
            if (comptime hasPub("init")) S.init(@ptrCast(@alignCast(raw)));
            return raw;
        }

        /// `create` without `init`: the host moves the fields of an older
        /// generation's instance in next.
        pub fn createBlank(owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque {
            return make(owner, gen, "create_blank");
        }

        /// A new instance at its defaults with `base` set, or null (logged;
        /// `what` names the entry point in the log line).
        fn make(owner: *anyopaque, gen: u32, what: []const u8) ?*anyopaque {
            // Without moduleInit there is no allocator and no log.
            const h = runtime.hostApi() orelse return null;
            if (gen != runtime.generation()) {
                runtime.log(.err, "ziggurat: {s}: {s} got generation {d}, but this module is generation {d}.", .{ rt([]const u8, rel), what, gen, runtime.generation() });
                return null;
            }
            const raw = h.alloc(gen, alloc_size, alloc_align) orelse {
                runtime.log(.err, "ziggurat: {s}: could not allocate {d} bytes for a new instance.", .{ rt([]const u8, rel), rt(usize, alloc_size) });
                return null;
            };
            if (@intFromPtr(raw) % alloc_align != 0) {
                runtime.log(.err, "ziggurat: {s}: the host returned instance memory that is not aligned to {d} bytes.", .{ rt([]const u8, rel), rt(u32, alloc_align) });
                h.free(gen, raw, alloc_size, alloc_align);
                return null;
            }
            const self: *S = @ptrCast(@alignCast(raw));
            // A shallow copy. Safe because every String, StringName,
            // NodePath and Ref default is empty or null (describe asserts
            // it), so the image holds no engine reference to share.
            self.* = defaults.*;
            // `base` in the image is undefined; it is always set here.
            if (@hasField(S, "base")) self.base = @ptrCast(owner);
            return raw;
        }

        pub fn destroy(inst: *anyopaque) callconv(.c) void {
            const self = instance(inst);
            if (comptime hasPub("deinit")) S.deinit(self);
            inline for (info.field_names) |name| {
                const FT = @FieldType(S, name);
                if (comptime fieldOwns(FT)) releaseField(FT, &@field(self, name));
            }
            // Without a host the memory cannot be returned; moduleInit
            // always runs before any create, so this does not happen.
            const h = runtime.hostApi() orelse return;
            h.free(runtime.generation(), inst, alloc_size, alloc_align);
        }

        pub fn call(
            inst: *anyopaque,
            method: u32,
            args: ?[*]const *const anyopaque,
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
            args: ?[*]const *const anyopaque,
            argc: i64,
            ret: *anyopaque,
            err: *abi.CallError,
        ) void {
            // Up to 64 arguments (the validator's limit) unrolled below.
            @setEvalBranchQuota(100_000);
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
            if (params.len > 0 and args == null) {
                err.* = .{ .@"error" = abi.call_invalid_argument, .argument = 0, .expected = comptime convert.variantType(params[0].?) };
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
                if (convert.read(P.?, args.?[i], &tuple[i + 1])) |e| {
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
                writeReturned(R, &r, ret);
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
                const G = @typeInfo(@TypeOf(@field(S, "get_" ++ name))).@"fn".return_type.?;
                var v: G = @field(S, "get_" ++ name)(self);
                writeReturned(G, &v, ret);
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
                @field(S, "set_" ++ name)(self, own.access(FT, &tmp));
                if (comptime fieldOwns(FT)) releaseField(FT, &tmp);
            } else {
                if (comptime fieldOwns(FT)) releaseField(FT, &@field(self, name));
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

/// Writes a method's or getter's return value into `ret`. A plain value
/// or a `*const` String, StringName or NodePath is borrowed and left alone; an `Owned(T)` value is released after the
/// write, so the Variant becomes its only owner.
fn writeReturned(comptime R: type, v: *R, ret: *anyopaque) void {
    if (comptime own.BorrowedText(R)) |T| {
        // A pointer into a field: copied into `ret`, never released.
        convert.write(T, v.*, ret);
    } else if (comptime own.isOwned(R)) {
        const T = R.ziggurat_owned;
        convert.write(T, &v.value, ret);
        release(T, &v.value);
    } else {
        convert.write(R, v, ret);
    }
}
