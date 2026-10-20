//! The host's GDExtension entry point (`ziggurat_host_init`).
//!
//! The host owns its entry point because gdzig's does not keep
//! `get_proc_address`; the host hands it to script modules (the `HostApi`).
//! The entry checks the engine first (spec section 3): in anything but Godot
//! 4.7.2 with single precision it logs one sentence and registers nothing.
//! Otherwise `ZigLanguage` is created and registered at SCENE init and
//! unregistered and destroyed at SCENE exit, which is what keeps Godot's
//! ObjectDB leak check quiet at exit.
const std = @import("std");
const godot = @import("gdzig");
const version = @import("version.zig");
const language = @import("language.zig");

const c = godot.c;
const Registry = godot.extension.Registry;
const String = godot.builtin.String;
const Engine = godot.class.Engine;
const ZigLanguage = language.ZigLanguage;
const GetProcAddress = @typeInfo(c.GDExtensionInterfaceGetProcAddress).optional.child;

/// The host's version, in its ready line.
pub const host_version = "0.1.0";

/// What Godot passed to the entry point; kept for the `HostApi`. Set once,
/// before any other host code runs, and never changed.
pub var get_proc_address: c.GDExtensionInterfaceGetProcAddress = null;
pub var library: c.GDExtensionClassLibraryPtr = null;

var registry: Registry = .init(godot.engine_allocator);

/// The registered language, between SCENE init and SCENE exit.
var zig_language: ?*ZigLanguage = null;

export fn ziggurat_host_init(
    p_get_proc_address: c.GDExtensionInterfaceGetProcAddress,
    p_library: c.GDExtensionClassLibraryPtr,
    r_initialization: ?*c.GDExtensionInitialization,
) callconv(.c) c.GDExtensionBool {
    const gpa = p_get_proc_address orelse return 0;
    const lib = p_library orelse return 0;
    const init = r_initialization orelse return 0;
    // Until the engine passes the check, only interface functions that every
    // Godot 4 has are used: gdzig's table needs some that older ones lack.
    if (refusal(gpa)) |sentence| {
        printErrorEarly(gpa, sentence);
        init.* = .{
            .minimum_initialization_level = c.GDEXTENSION_INITIALIZATION_SCENE,
            .initialize = &ignoreLevel,
            .deinitialize = &ignoreLevel,
            .userdata = null,
        };
        return 1;
    }

    get_proc_address = p_get_proc_address;
    library = p_library;
    godot.raw = .init(gpa, lib);
    godot.raw.getGodotVersion(@ptrCast(&godot.version));

    registry.addClass(ZigLanguage, registry.allocator, .auto);
    registry.addCallbacks(Lifecycle, .{}, .auto);

    init.* = .{
        .minimum_initialization_level = c.GDEXTENSION_INITIALIZATION_SCENE,
        .initialize = &enter,
        .deinitialize = &exit,
        .userdata = null,
    };
    return 1;
}

// Godot 4.7 has four levels (CORE to EDITOR); an unknown one is ignored
// rather than converted into gdzig's enum.
fn enter(_: ?*anyopaque, level: c.GDExtensionInitializationLevel) callconv(.c) void {
    if (level > c.GDEXTENSION_INITIALIZATION_EDITOR) return;
    registry.enter(@fromBackingInt(@intCast(level)));
}

fn exit(_: ?*anyopaque, level: c.GDExtensionInitializationLevel) callconv(.c) void {
    if (level > c.GDEXTENSION_INITIALIZATION_EDITOR) return;
    registry.exit(@fromBackingInt(@intCast(level)));
}

fn ignoreLevel(_: ?*anyopaque, _: c.GDExtensionInitializationLevel) callconv(.c) void {}

const Lifecycle = struct {
    pub fn enter(_: *Lifecycle, level: godot.extension.InitializationLevel) void {
        if (level != .scene) return;
        var alloc = godot.engine_allocator;
        const lang = ZigLanguage.create(&alloc) catch {
            log("ziggurat_host: out of memory creating the Zig language; Zig scripts are unavailable", .{});
            return;
        };
        const err = Engine.registerScriptLanguage(.upcast(lang.base));
        if (err != .ok) {
            log("ziggurat_host: Godot refused the Zig language (error {d}); Zig scripts are unavailable", .{@backingInt(err)});
            lang.destroy(&alloc);
            return;
        }
        zig_language = lang;
        log("ziggurat_host {s} ready", .{host_version});
    }

    pub fn exit(_: *Lifecycle, level: godot.extension.InitializationLevel) void {
        if (level != .scene) return;
        const lang = zig_language orelse return;
        _ = Engine.unregisterScriptLanguage(.upcast(lang.base));
        var alloc = godot.engine_allocator;
        lang.destroy(&alloc);
        zig_language = null;
    }
};

/// Prints one line to Godot's output.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

// ---------------------------------------------------------------- engine check

/// The refusal sentence for this engine, or null when the host may start.
fn refusal(gpa: GetProcAddress) ?[]const u8 {
    // `get_godot_version` is deprecated since 4.5 but present in every Godot 4.
    var v: c.GDExtensionGodotVersion = undefined;
    const get_version: c.GDExtensionInterfaceGetGodotVersion = @ptrCast(gpa("get_godot_version"));
    const get = get_version orelse return "Ziggurat cannot read the Godot version.";
    get(&v);
    return version.checkEngine(v.major, v.minor, v.patch, isDoubleBuild(gpa));
}

/// True in a double-precision Godot. `OS.has_feature("double")` is not
/// reachable at entry time (engine singletons are registered later), so this
/// reads the precision from a value: it builds a Variant from a Vector2 laid
/// out as two f32s and reads `x` back. A single build reads 1.5; a double
/// build reads the 8 bytes as one f64, which is not 1.5. A missing interface
/// function counts as single precision; the version check still applies.
fn isDoubleBuild(gpa: GetProcAddress) bool {
    const from_type: c.GDExtensionInterfaceGetVariantFromTypeConstructor = @ptrCast(gpa("get_variant_from_type_constructor"));
    const to_type: c.GDExtensionInterfaceGetVariantToTypeConstructor = @ptrCast(gpa("get_variant_to_type_constructor"));
    const get_indexed: c.GDExtensionInterfaceVariantGetIndexed = @ptrCast(gpa("variant_get_indexed"));
    const destroy: c.GDExtensionInterfaceVariantDestroy = @ptrCast(gpa("variant_destroy"));
    if (from_type == null or to_type == null or get_indexed == null or destroy == null) return false;
    const from_vector2 = from_type.?(c.GDEXTENSION_VARIANT_TYPE_VECTOR2) orelse return false;
    const to_float = to_type.?(c.GDEXTENSION_VARIANT_TYPE_FLOAT) orelse return false;

    // Room for a double-precision Vector2 (16 bytes) and Variant (40 bytes).
    var vec: [16]u8 align(16) = @splat(0);
    std.mem.writeInt(u32, vec[0..4], @bitCast(@as(f32, 1.5)), .little);
    std.mem.writeInt(u32, vec[4..8], @bitCast(@as(f32, 1.5)), .little);
    var variant: [64]u8 align(16) = @splat(0);
    var x_variant: [64]u8 align(16) = @splat(0);
    from_vector2(@ptrCast(&variant), @ptrCast(&vec));
    defer destroy.?(@ptrCast(&variant));
    var valid: c.GDExtensionBool = 0;
    var oob: c.GDExtensionBool = 0;
    get_indexed.?(@ptrCast(&variant), 0, @ptrCast(&x_variant), &valid, &oob);
    defer destroy.?(@ptrCast(&x_variant));
    if (valid == 0 or oob != 0) return false;
    var x: f64 = 0;
    to_float(@ptrCast(&x), @ptrCast(&x_variant));
    return x != 1.5;
}

/// Prints an error through the bare interface (gdzig's table is not set up
/// when the engine is refused).
fn printErrorEarly(gpa: GetProcAddress, sentence: []const u8) void {
    const print_error: c.GDExtensionInterfacePrintError = @ptrCast(gpa("print_error"));
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{sentence}, 0) catch return;
    (print_error orelse return)(z.ptr, "ziggurat_host_init", "src/host/entry.zig", @src().line, 1);
}

test {
    _ = version;
}
