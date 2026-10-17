//! Names and method binds that live for the whole process.
//!
//! Both caches are plain variables written without atomics. Each must be
//! filled on the main thread before any other thread uses it: `moduleInit`
//! does that for every one the SDK itself uses (see `warm.zig`).
const godot = @import("gdzig");

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
        var ready: bool = false;

        pub fn ptr() *const anyopaque {
            if (!ready) {
                value = godot.builtin.StringName.fromComptimeLatin1(&key);
                ready = true;
            }
            return @ptrCast(&value);
        }

        /// True once `ptr()` has built the name.
        pub fn isReady() bool {
            return ready;
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
        var looked_up: bool = false;

        pub fn get() godot.c.GDExtensionMethodBindPtr {
            if (!looked_up) {
                bind = godot.raw.classdbGetMethodBind(
                    @ptrCast(StaticName(class).ptr()),
                    @ptrCast(StaticName(method).ptr()),
                    hash,
                );
                looked_up = true;
            }
            return bind;
        }

        /// True once `get()` has asked Godot.
        pub fn isReady() bool {
            return looked_up;
        }
    };
}
