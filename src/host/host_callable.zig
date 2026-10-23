//! Callables to host methods: a `Callable(object, method)` built in Zig for
//! a method the host bound on its own class with gdzig (`addMethod`), for
//! example to connect an engine signal (a button's `pressed`) to a method
//! of `ZigEditorPlugin`. Godot calls the method by name through ClassDB, so
//! `method` is the bound (snake_case) name.
const godot = @import("gdzig");

const Object = godot.class.Object;
const Callable = godot.builtin.Callable;
const StringName = godot.builtin.StringName;

/// A Callable to `method` of `obj`. The method name is a comptime
/// StringName, which is never freed; the caller owns the Callable and calls
/// `deinit` on it (a signal connection keeps its own copy).
pub fn callable(obj: *Object, comptime method: [:0]const u8) Callable {
    return .initObjectMethod(obj, .fromComptimeLatin1(method));
}
