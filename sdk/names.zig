//! Names that live for the whole process.
const godot = @import("gdzig");

/// A StringName built once from a comptime string and never freed. The type
/// has no `deinit`: freeing a name that `fromComptimeLatin1` cached would
/// free it twice. `ptr()` points at the cached StringName for engine calls.
///
/// The cache is a plain `var` written without atomics. The first `ptr()` call
/// for a name must happen on the main thread, or the name must be warmed
/// there first: `moduleInit` is where later tasks register their names.
pub fn StaticName(comptime s: [:0]const u8) type {
    return struct {
        var value: godot.builtin.StringName = undefined;
        var ready: bool = false;

        pub fn ptr() *const anyopaque {
            if (!ready) {
                value = godot.builtin.StringName.fromComptimeLatin1(s);
                ready = true;
            }
            return @ptrCast(&value);
        }
    };
}
