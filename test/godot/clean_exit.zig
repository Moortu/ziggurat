//! A second GDExtension entry in the test library: runs every test once in
//! one Godot that then exits normally, so Godot's exit-time checks
//! (`ObjectDB instances leaked`, `Unreferenced static string`) can be seen.
//!
//! gdzig's harness entry ends Godot with SIGKILL after each test, so those
//! checks never run there. `test/godot/clean_exit_runner.zig` starts Godot on
//! this entry and scans its output.
//!
//! Output lines: `ZTEST PASS <name>`, `ZTEST SKIP <name>`,
//! `ZTEST FAIL <name>: <error>`, `ZTEST LEAK <name>: ...`, and last
//! `ZTEST DONE pass=<n> skip=<n> fail=<n> leak=<n>`.
const std = @import("std");
const builtin = @import("builtin");
const godot = @import("ziggurat").godot;
const c = godot.c;
const Os = godot.class.Os;

pub const entry_symbol = "ziggurat_clean_exit_entry";

/// Godot's get_proc_address and library, set only by this entry.
pub var real_get_proc_address: ?*const anyopaque = null;
pub var real_library: ?*anyopaque = null;

comptime {
    if (builtin.is_test) @export(&entry, .{ .name = entry_symbol, .linkage = .strong });
}

fn entry(
    get_proc_address: c.GDExtensionInterfaceGetProcAddress,
    library: c.GDExtensionClassLibraryPtr,
    r_initialization: *c.GDExtensionInitialization,
) callconv(.c) c.GDExtensionBool {
    const gp = get_proc_address orelse return 0;
    const lib = library orelse return 0;
    real_get_proc_address = @ptrCast(gp);
    real_library = @ptrCast(lib);
    godot.raw = .init(gp, lib);
    godot.raw.getGodotVersion(@ptrCast(&godot.version));
    r_initialization.* = .{
        .minimum_initialization_level = c.GDEXTENSION_INITIALIZATION_SCENE,
        .initialize = &enter,
        .deinitialize = &exit,
        .userdata = null,
    };
    return 1;
}

fn enter(_: ?*anyopaque, level: c.GDExtensionInitializationLevel) callconv(.c) void {
    if (level != c.GDEXTENSION_INITIALIZATION_SCENE) return;
    var pass: usize = 0;
    var skip: usize = 0;
    var fail: usize = 0;
    for (builtin.test_functions) |t| {
        if (t.func()) |_| {
            pass += 1;
            std.debug.print("ZTEST PASS {s}\n", .{t.name});
        } else |err| {
            if (err == error.SkipZigTest) {
                skip += 1;
                std.debug.print("ZTEST SKIP {s}\n", .{t.name});
            } else {
                fail += 1;
                std.debug.print("ZTEST FAIL {s}: {t}\n", .{ t.name, err });
            }
        }
    }
    // Godot reports no leaked String (and a leaked StringName only with
    // --verbose). Run each test a second time, once its lazy caches are
    // warm, and require Godot's tracked heap to end where it started.
    var leaks: usize = 0;
    for (builtin.test_functions) |t| {
        const before = Os.getStaticMemoryUsage();
        _ = t.func() catch {};
        const after = Os.getStaticMemoryUsage();
        if (after != before) {
            leaks += 1;
            std.debug.print("ZTEST LEAK {s}: Godot heap {d} -> {d} bytes\n", .{ t.name, before, after });
        }
    }
    std.debug.print("ZTEST DONE pass={d} skip={d} fail={d} leak={d}\n", .{ pass, skip, fail, leaks });
}

fn exit(_: ?*anyopaque, _: c.GDExtensionInitializationLevel) callconv(.c) void {}
