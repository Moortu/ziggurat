//! `Previous(T)`: the old instance during a migration, as a script's
//! `pub fn migrate(self: *@This(), old: z.Previous(@This())) void` sees it
//! (spec sections 6 and 8).
//!
//! The new module is built without the old struct, so the old instance is
//! read through the old generation's field list (`abi.PrevView`): a field is
//! found by name, and it gives a value only when its exact type identity
//! (type name, shape, size and alignment, as `describe` writes them) equals
//! that of the type asked for. `describe`'s own functions compute the
//! identity on this side, so the two agree by construction. A field that
//! is missing or has another type gives null; nothing panics.
//!
//! - `get(FT, name)` copies a plain value: bool, integers, floats, enums,
//!   packed flags, vectors, `z.Obj` handles, and structs, arrays and
//!   optionals of those. The old field stays as it is.
//! - `take(FT, name)` moves an owning value (`z.String`, `z.StringName`,
//!   `z.NodePath`, `z.Ref(T)`) out and marks the old field moved, so the
//!   host resets it before the old instance's destroy and the value is
//!   released once, by whoever holds it now. A field already moved (by the
//!   host or by an earlier `take`) gives null.
//!
//! Using `get` on an owning type, or `take` on a plain one, is a compile
//! error with the SDK marker `[ziggurat:<rel>#migrate]` when the script's
//! path can be found (see `signal.zig`).
const std = @import("std");
const abi = @import("ziggurat_abi");
const describe = @import("describe.zig");
const own = @import("own.zig");
const object = @import("object.zig");
const signal = @import("signal.zig");

/// The old instance of script `T` during a migration. Built by the
/// `migrate` wrapper from the host's `PrevView`; valid only for the length
/// of the `migrate` call.
pub fn Previous(comptime T: type) type {
    return struct {
        /// The host's view of the old instance.
        view: *const abi.PrevView,

        pub const ziggurat_previous = T;

        /// A copy of the old field `name` when it exists with the exact type
        /// `FT`, else null. For plain values only; see `take`.
        pub fn get(self: @This(), comptime FT: type, comptime name: []const u8) ?FT {
            comptime if (containsOwning(FT))
                fail(T, "old.get cannot copy '" ++ name ++ "': its type owns an engine reference; use old.take for z.String, z.StringName, z.NodePath and z.Ref.");
            const i = self.find(FT, name) orelse return null;
            return self.read(FT, i);
        }

        /// The value of the old field `name` when it exists with the exact
        /// type `FT` and was not moved yet, else null. The field is marked
        /// moved: the value now belongs to the caller, who stores it in a
        /// field (an empty one, or one released first) or releases it.
        pub fn take(self: @This(), comptime FT: type, comptime name: []const u8) ?FT {
            comptime if (!isTakeable(FT))
                fail(T, "old.take of '" ++ name ++ "' as " ++ @typeName(FT) ++ ": take moves only z.String, z.StringName, z.NodePath and z.Ref; use old.get for a plain value.");
            const i = self.find(FT, name) orelse return null;
            if (self.view.moved[i] != 0) return null;
            const v = self.read(FT, i);
            self.view.moved[i] = 1;
            return v;
        }

        /// The index of the old field `name` when its type identity is that
        /// of `FT`.
        fn find(self: @This(), comptime FT: type, comptime name: []const u8) ?usize {
            const type_name = comptime describe.stableTypeName(FT);
            const shape = comptime describe.shapeOf(FT);
            const v = self.view;
            for (v.fields[0..v.field_count], 0..) |f, i| {
                if (!eqlStr(f.name, name)) continue;
                if (!eqlStr(f.type_name, type_name) or f.shape != shape or
                    f.size != @sizeOf(FT) or f.@"align" != @alignOf(FT)) return null;
                return i;
            }
            return null;
        }

        /// The bytes of old field `i`; its identity equals `FT`'s, so they
        /// are a value of `FT` the old instance held.
        fn read(self: @This(), comptime FT: type, i: usize) FT {
            const f = self.view.fields[i];
            const src: [*]const u8 = @ptrCast(self.view.data);
            var out: FT = undefined;
            @memcpy(std.mem.asBytes(&out), src[f.offset..][0..@sizeOf(FT)]);
            return out;
        }
    };
}

fn eqlStr(s: abi.Str, want: []const u8) bool {
    if (s.len != want.len) return false;
    const p = s.ptr orelse return want.len == 0;
    return std.mem.eql(u8, p[0..s.len], want);
}

/// The owning field types `take` moves: `z.String`, `z.StringName`,
/// `z.NodePath` and `z.Ref(T)` (a field never holds the engine's own
/// String, StringName or NodePath).
fn isTakeable(comptime FT: type) bool {
    return own.isText(FT) or (own.ownsEngineValue(FT) and @typeInfo(FT) == .@"struct" and @hasDecl(FT, object.handle_decl));
}

/// True when a value of `FT` holds an engine reference anywhere inside.
fn containsOwning(comptime FT: type) bool {
    if (own.fieldOwns(FT)) return true;
    return switch (@typeInfo(FT)) {
        .@"struct" => |s| for (s.field_types) |C| {
            if (containsOwning(C)) break true;
        } else false,
        .array => |a| containsOwning(a.child),
        .optional => |o| containsOwning(o.child),
        .@"union" => |u| for (u.field_types) |C| {
            if (containsOwning(C)) break true;
        } else false,
        else => false,
    };
}

fn fail(comptime T: type, comptime sentence: []const u8) noreturn {
    if (signal.scriptRel(T)) |rel| @compileError(sentence ++ " [ziggurat:" ++ describe.encodeRel(rel) ++ "#migrate]");
    @compileError("ziggurat: " ++ sentence);
}
