//! The running game (spec section 6): a game process never builds. At SCENE
//! init, after the language and the `.zig` loader are registered, it loads
//! the one generation the editor's last good build left in
//! `.godot/ziggurat`, as the trusted reader in manifest.zig allows, and that
//! generation becomes current, so scripts create real instances (a game has
//! no placeholders). Anything the reader refuses is one log line, and the
//! game runs on without Zig scripts. The game pins its generation (a shared
//! lock on `gen/<n>/.lock`) from the first check until SCENE exit, so an
//! editor's sweep never deletes the folder of the generation it runs.
//!
//! A game reloads when the editor says so: right after the editor writes a
//! new manifest it sends the debugger message `ziggurat:reload` with the
//! generation number (debugger_plugin.zig), which the `ziggurat` capture
//! registered here at start turns into a reload request; the next frame
//! loads that generation and the swap engine moves the scripts to it. A
//! game does not watch the manifest file. Godot's own reload messages (on
//! a save, before the build is staged) read the manifest quietly.
//!
//! An export build (`host_options.export_build`) compiles all of this out:
//! no reader, no file name and no symbol of it remain in the library. Its
//! scripts are linked into the same library as the host (spec section 10):
//! the host's extern `ziggurat_describe` and `ziggurat_init` are the
//! module's, and `start` takes that module as generation 1
//! (`runtime.loadLinked`) for the whole process, with no swap and no
//! reload.
const std = @import("std");
const builtin = @import("builtin");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const host_options = @import("host_options");
const runtime = @import("runtime.zig");
const host_io = @import("host_io.zig");
const desc_cache = @import("desc_cache.zig");
const platform = @import("ziggurat_platform");
const swap = @import("swap.zig");
const props = @import("props.zig");
const host_callable = @import("host_callable.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Array = godot.builtin.Array;
const Object = godot.class.Object;

/// Thread-safe and never destroyed, as `runtime.load` requires.
const gpa = std.heap.c_allocator;

/// The pin on the loaded generation, held until `stop`. Main thread.
var pin: ?platform.generation_store.FileLock = null;

/// The pins of generations loaded by a reload, held until `stop`: an old
/// generation is never unloaded, so its folder stays too: one lock file is
/// held per loaded generation until the game exits. Main thread.
var reload_pins: std.ArrayList(platform.generation_store.FileLock) = .empty;

/// Set by `requestReload` (any thread), taken by `frame`: a check that
/// says nothing when no newer generation is named.
var reload_wanted: std.atomic.Value(bool) = .init(false);
/// The highest generation number a request named (0: none), taken with
/// `reload_wanted` by `frame`.
var reload_min_gen: std.atomic.Value(u32) = .init(0);

/// The debugger message capture this game registered (`ziggurat`), and the
/// object its Callable calls. Main thread, between `start` and `stop`.
var capture_obj: ?*ZigReloadCapture = null;
/// The capture's name: messages `ziggurat:<msg>` from the editor reach it.
const capture_name = "ziggurat";

/// Main thread, SCENE init, in a game process, after the language and the
/// loader are registered. The message capture is registered before the
/// load below, so no message that arrives later is dropped. A manifest the
/// editor writes after the load but before it accepted this game's
/// debugger connection reaches the game too: when the session starts, the
/// editor sends the generation of its last manifest write again
/// (debugger_plugin.zig, `sessionStarted`).
pub fn start() void {
    if (comptime host_options.export_build) {
        startLinked();
        return;
    }
    registerCapture();
    loadFromStore();
}

/// The module's entry points, provided by the scripts' object that is
/// linked with the export host into one library. Only an export build
/// refers to them.
const linked = struct {
    extern fn ziggurat_describe() callconv(.c) *const abi.Table;
    extern fn ziggurat_init(api: *const abi.HostApi, gen: u32) callconv(.c) void;
};

/// An export build's start: the linked module becomes the current
/// generation; a table the validator refuses is one error line, and the
/// game runs on without Zig scripts.
fn startLinked() void {
    comptime std.debug.assert(host_options.export_build);
    var diag: [256]u8 = undefined;
    const gen = runtime.loadLinked(gpa, &linked.ziggurat_describe, &linked.ziggurat_init, &diag) catch |err| {
        switch (err) {
            error.OutOfMemory => logError("Ziggurat cannot load Zig scripts in this game: out of memory.", .{}),
            // `loadLinked` logged it already.
            error.NotMainThread => {},
            error.Refused => logError("{s} This game runs without Zig scripts.", .{std.mem.sliceTo(&diag, 0)}),
        }
        return;
    };
    runtime.publish(gen);
    log("ziggurat: {d} scripts linked", .{gen.table.script_count});
}

/// Releases the pins and the message capture. Main thread, SCENE exit.
pub fn stop() void {
    if (comptime host_options.export_build) return;
    unregisterCapture();
    releasePins();
    reload_wanted.store(false, .release);
    reload_min_gen.store(0, .release);
}

fn releasePins() void {
    if (pin) |*l| l.release();
    pin = null;
    for (reload_pins.items) |*l| l.release();
    reload_pins.clearAndFree(gpa);
}

/// Something asked this game to reload its scripts: Godot's
/// `_reload_scripts` and `_reload_all_scripts` (`min_gen` 0: they come on a
/// save, before the editor staged the build, and from other extensions) or
/// the editor's `ziggurat:reload` message (the generation it just wrote
/// into the manifest). Any thread; it only sets
/// flags, `frame` does the work. An export build has no reload path.
pub fn requestReload(min_gen: u32) void {
    if (comptime host_options.export_build) return;
    _ = reload_min_gen.fetchMax(min_gen, .acq_rel);
    reload_wanted.store(true, .release);
}

/// The editor wrote generation `n` into the manifest (`ziggurat:reload`).
/// A number not newer than the current generation does nothing: a game
/// started by Play already loaded the generation the message names.
pub fn onReloadMessage(n: u32) void {
    requestReload(n);
}

/// The generation a `ziggurat:<message>` capture call names: `reload` with
/// data `[n]`, n from 1 to the largest u32. Anything else is null.
pub fn reloadMessageGen(message: []const u8, first: ?i64, len: i64) ?u32 {
    if (!std.mem.eql(u8, message, "reload") or len != 1) return null;
    const n = std.math.cast(u32, first orelse return null) orelse return null;
    return if (n == 0) null else n;
}

/// The object the `ziggurat` capture's Callable calls (`capture`, bound
/// below): Godot's debugger calls it on the main thread from its message
/// poll with the message without the prefix and its data. Registered only
/// in builds with a reload path (not in export builds); never exposed.
pub const ZigReloadCapture = struct {
    base: *Object,

    pub fn create(allocator: *Allocator) !*ZigReloadCapture {
        const self = try allocator.create(ZigReloadCapture);
        self.* = .{ .base = Object.init() };
        self.base.setInstance(ZigReloadCapture, self);
        return self;
    }

    pub fn destroy(self: *ZigReloadCapture, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    /// Bound as `capture`. True when the message was this game's.
    pub fn capture(_: *ZigReloadCapture, message: String, data: Array) bool {
        return handleCapture(message, data);
    }
};

/// What the `ziggurat` capture does with a message: `reload [n]` asks for a
/// reload; anything else is not this game's message.
pub fn handleCapture(message: String, data: Array) bool {
    var buf: [32]u8 = undefined;
    const text = props.stringText(&message, &buf) orelse return false;
    var first: ?i64 = null;
    if (data.size() >= 1) {
        var v = data.get(0);
        defer v.deinit();
        first = v.as(i64);
    }
    const n = reloadMessageGen(text, first, data.size()) orelse return false;
    onReloadMessage(n);
    return true;
}

/// Adds the capture's class (SCENE level, not exposed). Not in export
/// builds.
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    const cls = registry.createClass(ZigReloadCapture, registry.allocator, .{ .is_exposed = false });
    cls.addMethod("capture", .auto);
}

fn registerCapture() void {
    if (capture_obj != null) return;
    var alloc = godot.engine_allocator;
    const obj = ZigReloadCapture.create(&alloc) catch {
        logError("Ziggurat cannot listen for the editor's reload messages: out of memory.", .{});
        return;
    };
    const name: StringName = .fromComptimeLatin1(capture_name);
    if (godot.class.EngineDebugger.hasCapture(name)) {
        logError("Ziggurat cannot listen for the editor's reload messages: the debugger capture '" ++ capture_name ++ "' is taken.", .{});
        obj.destroy(&alloc);
        return;
    }
    var c = host_callable.callable(Object.upcast(obj.base), "capture");
    defer c.deinit();
    godot.class.EngineDebugger.registerMessageCapture(name, c);
    capture_obj = obj;
}

fn unregisterCapture() void {
    const obj = capture_obj orelse return;
    const name: StringName = .fromComptimeLatin1(capture_name);
    if (godot.class.EngineDebugger.hasCapture(name)) godot.class.EngineDebugger.unregisterMessageCapture(name);
    var alloc = godot.engine_allocator;
    obj.destroy(&alloc);
    capture_obj = null;
}

/// True while this game's capture is registered (for the host tests).
pub fn captureRegistered() bool {
    return capture_obj != null and godot.class.EngineDebugger.hasCapture(.fromComptimeLatin1(capture_name));
}

/// Handles a reload request: from `ZigLanguage._frame`, main thread, before
/// the swap engine runs, so a generation requested here swaps in this same
/// frame when no script call is on the stack.
///
/// The game trusts only the manifest and the module's own validation
/// (`runtime.load`). It skips the editor's load checks (`load_checks.zig`):
/// the editor refuses to write a manifest for a build those checks reject,
/// so a manifest that names a generation already passed them. Every trust
/// rule on the manifest and the library file is the one the start-up load
/// uses (`manifest.readTrusted`, `recheck`).
pub fn frame() void {
    if (comptime host_options.export_build) return;
    if (!reload_wanted.swap(false, .acq_rel)) return;
    const min_gen = reload_min_gen.swap(0, .acq_rel);
    // The message names a generation this game runs already (or an older
    // one): nothing to read.
    if (min_gen != 0) {
        if (runtime.current()) |c| if (min_gen <= c.n) return;
    }
    // Here `min_gen` is 0 (Godot's reload) or newer than the current
    // generation (the editor announced a build this game does not run).
    reloadFromManifest(min_gen);
}

fn keepingText(buf: *[48]u8) []const u8 {
    if (runtime.current()) |c| return std.fmt.bufPrint(buf, "keeping gen {d}", .{c.n}) catch "keeping the current gen";
    return "no generation is loaded";
}

/// `announced` is the generation the editor's message named when it is
/// newer than the current one, else 0. A refusal is then a fault, not the
/// expected state before staging, and is logged.
fn reloadFromManifest(announced: u32) void {
    const manifest = @import("manifest.zig");
    const zbuild = @import("ziggurat_build");
    const stem = zbuild.service.lib_stem;
    const os = builtin.os.tag;
    var keep_buf: [48]u8 = undefined;

    var store_buf: [4096]u8 = undefined;
    const store = desc_cache.dataPath(&store_buf, "ziggurat") orelse {
        logError("{s}", .{manifest.Refusal.store_unresolvable.sentence()});
        return;
    };
    const io = host_io.get();
    var result = manifest.readTrusted(gpa, io, store, os, stem) catch {
        logError("Ziggurat cannot reload Zig scripts: out of memory.", .{});
        return;
    };
    defer result.deinit(gpa);
    const trusted = switch (result) {
        .ok => |*t| t,
        .refused => |r| {
            switch (r) {
                // Godot's reload comes on a save, before the editor staged
                // the build; the editor's message follows the staging.
                .missing, .library_missing => if (announced != 0)
                    logError("Ziggurat cannot load build {d}, which the editor announced, because {s}; {s}.", .{ announced, r.because(), keepingText(&keep_buf) }),
                else => logError("Ziggurat ignores the generation manifest for this reload because {s}; {s}.", .{ r.because(), keepingText(&keep_buf) }),
            }
            return;
        },
    };
    const cur = runtime.current();
    if (cur) |c| {
        if (trusted.n <= c.n) {
            if (announced != 0)
                logError("Ziggurat cannot load build {d}, which the editor announced, because the manifest names build {d}; {s}.", .{ announced, trusted.n, keepingText(&keep_buf) });
            return;
        }
    }
    // Loaded before (a swap that was refused): ask for it again.
    if (runtime.find(trusted.n)) |g| {
        swap.request(g);
        return;
    }

    var store_obj = platform.generation_store.GenerationStore.init(gpa, io, .fromTrusted(store), os, stem, .{});
    // The pin is kept for the life of the game, so the generation the game
    // swaps to is never swept. Without one, or without room to list it, the
    // generation is not loaded: the game keeps running the current one.
    reload_pins.ensureUnusedCapacity(gpa, 1) catch {
        logError("Ziggurat cannot reload Zig scripts: out of memory.", .{});
        return;
    };
    var new_pin: platform.generation_store.FileLock = store_obj.pin(trusted.n) catch |err| {
        logError("Ziggurat could not pin generation {d} ({s}), so it is not loaded; {s}.", .{ trusted.n, @errorName(err), keepingText(&keep_buf) });
        return;
    };
    var keep_pin = false;
    defer if (!keep_pin) new_pin.release();
    const changed = manifest.recheck(gpa, io, store, trusted, os, stem) catch {
        logError("Ziggurat cannot reload Zig scripts: out of memory.", .{});
        return;
    };
    if (changed) |r| {
        logError("Ziggurat ignores generation {d} for this reload because {s}; {s}.", .{ trusted.n, r.because(), keepingText(&keep_buf) });
        return;
    }
    var diag: [256]u8 = undefined;
    const gen = runtime.load(gpa, .fromTrusted(trusted.lib), trusted.n, &diag) catch |err| {
        switch (err) {
            error.OutOfMemory => logError("Ziggurat cannot reload Zig scripts: out of memory.", .{}),
            // `load` logged it already.
            error.NotMainThread => {},
            error.Refused => logError("Ziggurat refused generation {d}: {s} {s}.", .{ trusted.n, std.mem.sliceTo(&diag, 0), keepingText(&keep_buf) }),
        }
        return;
    };
    reload_pins.appendAssumeCapacity(new_pin);
    keep_pin = true;
    finishLoad(gen, cur);
}

fn finishLoad(gen: *runtime.Generation, cur: ?*runtime.Generation) void {
    runtime.noteGood(gen);
    log("ziggurat: generation {d} loaded", .{gen.n});
    if (cur == null) {
        // No script has run yet, so there is nothing to move.
        runtime.publish(gen);
        return;
    }
    swap.request(gen);
}

fn loadFromStore() void {
    const manifest = @import("manifest.zig");
    const zbuild = @import("ziggurat_build");
    const stem = zbuild.service.lib_stem;
    const os = builtin.os.tag;

    var store_buf: [4096]u8 = undefined;
    const store = desc_cache.dataPath(&store_buf, "ziggurat") orelse {
        logError("{s}", .{manifest.Refusal.store_unresolvable.sentence()});
        return;
    };
    const io = host_io.get();
    var result = manifest.readTrusted(gpa, io, store, os, stem) catch {
        logError("Ziggurat cannot load Zig scripts in this game: out of memory.", .{});
        return;
    };
    defer result.deinit(gpa);
    const trusted = switch (result) {
        .ok => |*t| t,
        .refused => |r| {
            if (r == .missing) log("{s}", .{r.sentence()}) else logError("{s}", .{r.sentence()});
            return;
        },
    };
    // Pinned after the first check and before the re-check, so the
    // generation the re-check confirms cannot be swept before the load. A
    // pin that fails is a warning: the game still runs that generation.
    var store_obj = platform.generation_store.GenerationStore.init(gpa, io, .fromTrusted(store), os, stem, .{});
    pin = store_obj.pin(trusted.n) catch |err| blk: {
        logWarning("Ziggurat could not pin generation {d} ({s}); an editor's cleanup may delete its files while this game runs.", .{ trusted.n, @errorName(err) });
        break :blk null;
    };
    // The re-check right before the load narrows the window in which the
    // files can change; loading through an open descriptor would close it.
    const changed = manifest.recheck(gpa, io, store, trusted, os, stem) catch {
        logError("Ziggurat cannot load Zig scripts in this game: out of memory.", .{});
        return;
    };
    if (changed) |r| {
        logError("{s}", .{r.sentence()});
        releasePins();
        return;
    }
    var diag: [256]u8 = undefined;
    const gen = runtime.load(gpa, .fromTrusted(trusted.lib), trusted.n, &diag) catch |err| {
        switch (err) {
            error.OutOfMemory => logError("Ziggurat cannot load Zig scripts in this game: out of memory.", .{}),
            // `load` logged it already.
            error.NotMainThread => {},
            error.Refused => logError("{s}", .{std.mem.sliceTo(&diag, 0)}),
        }
        releasePins();
        return;
    };
    // New instances use it from now on.
    runtime.publish(gen);
    log("ziggurat: generation {d} loaded", .{gen.n});
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printError(msg.ptr, "Zig scripts", "src/host/game.zig", @src().line, 1);
}

fn logWarning(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printWarning(msg.ptr, "Zig scripts", "src/host/game.zig", @src().line, 1);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

test "reload message: only reload with one generation from 1 up" {
    try std.testing.expectEqual(@as(?u32, 5), reloadMessageGen("reload", 5, 1));
    try std.testing.expectEqual(@as(?u32, std.math.maxInt(u32)), reloadMessageGen("reload", std.math.maxInt(u32), 1));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reload", 0, 1));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reload", -1, 1));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reload", 1 << 32, 1));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reload", null, 1));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reload", 5, 2));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reload", null, 0));
    try std.testing.expectEqual(@as(?u32, null), reloadMessageGen("reloads", 5, 1));
}
