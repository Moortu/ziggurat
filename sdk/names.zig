//! Names and method binds that live for the whole process.
//!
//! Both caches are safe to use from several threads at once (spec risk 17).
//! A cache is published with release ordering and read with acquire
//! ordering, so a thread that sees it filled also sees its value, on weakly
//! ordered CPUs (arm64) too. Threads that race to fill one cache each ask
//! Godot; one thread stores its result and the others never free theirs (a
//! static StringName freed twice deadlocks Godot; the extra reference keeps
//! an interned name alive). `moduleInit` still fills every cache the SDK
//! itself uses on the main thread (see `warm.zig`).
const std = @import("std");
const godot = @import("gdzig");

/// The fill state of one cache. Only the thread that moves it from `empty`
/// to `filling` writes the value; `ready` is stored with release ordering
/// after the value.
const State = enum(u8) { empty, filling, ready };

/// True when this thread may store its value: it moved `state` from
/// `empty` to `filling`, and must then store `ready` with release ordering.
fn claim(state: *State) bool {
    return @cmpxchgStrong(State, state, .empty, .filling, .monotonic, .monotonic) == null;
}

/// A StringName built once from a comptime string and never freed. The type
/// has no `deinit`: freeing a name that `fromComptimeLatin1` cached would
/// free it twice. `ptr()` points at the cached StringName for engine calls.
///
/// The cache is keyed by the bytes of `s`, so one name always has one cache,
/// however it was spelled (`@tagName`, a declaration name, a literal).
pub fn StaticName(comptime s: []const u8) type {
    return StaticNameOf(s.len, s[0..s.len].*);
}

fn StaticNameOf(comptime n: usize, comptime bytes: [n]u8) type {
    return struct {
        const key: [n:0]u8 = blk: {
            var k: [n:0]u8 = undefined;
            for (bytes, 0..) |c, i| k[i] = c;
            k[n] = 0;
            break :blk k;
        };
        var value: godot.builtin.StringName = undefined;
        var state: State = .empty;

        pub fn ptr() *const anyopaque {
            if (@atomicLoad(State, &state, .acquire) != .ready) fill();
            return @ptrCast(&value);
        }

        fn fill() void {
            const made = godot.builtin.StringName.fromComptimeLatin1(&key);
            if (claim(&state)) {
                value = made;
                @atomicStore(State, &state, .ready, .release);
                return;
            }
            // Another thread is storing the same name; `ptr()` returns the
            // stored one, so wait for that store (a few instructions).
            // `made` is not freed.
            while (@atomicLoad(State, &state, .acquire) != .ready) std.atomic.spinLoopHint();
        }

        /// True once `ptr()` has built the name.
        pub fn isReady() bool {
            return @atomicLoad(State, &state, .acquire) == .ready;
        }
    };
}

/// The method bind of `class.method` with the hash from
/// `extension_api.json`, looked up once. `get()` is null when Godot has no
/// such bind (a hash mismatch); the miss is kept too, so a missing bind is
/// asked for only once.
pub fn MethodBind(comptime class: []const u8, comptime method: []const u8, comptime hash: i64) type {
    return struct {
        var bind: godot.c.GDExtensionMethodBindPtr = null;
        var state: State = .empty;

        pub fn get() godot.c.GDExtensionMethodBindPtr {
            if (@atomicLoad(State, &state, .acquire) == .ready) return bind;
            const found = godot.raw.classdbGetMethodBind(
                @ptrCast(StaticName(class).ptr()),
                @ptrCast(StaticName(method).ptr()),
                hash,
            );
            if (claim(&state)) {
                bind = found;
                @atomicStore(State, &state, .ready, .release);
            }
            // The lookup is pure: a thread that lost the claim found the
            // same bind.
            return found;
        }

        /// True once `get()` has asked Godot.
        pub fn isReady() bool {
            return @atomicLoad(State, &state, .acquire) == .ready;
        }
    };
}
