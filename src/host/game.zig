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
//! An export build (`host_options.export_build`) compiles all of this out:
//! no reader, no file name and no symbol of it remain in the library. Until
//! scripts are linked into the export (Stage 6) such a game has no module
//! source and says so.
const std = @import("std");
const builtin = @import("builtin");
const godot = @import("gdzig");
const host_options = @import("host_options");
const runtime = @import("runtime.zig");
const host_io = @import("host_io.zig");
const desc_cache = @import("desc_cache.zig");
const platform = @import("ziggurat_platform");
const swap = @import("swap.zig");

const String = godot.builtin.String;

/// Thread-safe and never destroyed, as `runtime.load` requires.
const gpa = std.heap.c_allocator;

/// The pin on the loaded generation, held until `stop`. Main thread.
var pin: ?platform.generation_store.FileLock = null;

/// The pins of generations loaded by a reload, held until `stop`: an old
/// generation is never unloaded, so its folder stays too. Main thread.
var reload_pins: std.ArrayList(platform.generation_store.FileLock) = .empty;

/// Set by `requestReload` (any thread), taken by `frame`.
var reload_wanted: std.atomic.Value(bool) = .init(false);

/// Main thread, SCENE init, in a game process, after the language and the
/// loader are registered.
pub fn start() void {
    if (comptime host_options.export_build) {
        log("This export build of Ziggurat has no module source yet, so this game runs without Zig scripts.", .{});
        return;
    }
    loadFromStore();
}

/// Releases the pin. Main thread, SCENE exit.
pub fn stop() void {
    if (comptime host_options.export_build) return;
    if (pin) |*l| l.release();
    pin = null;
    for (reload_pins.items) |*l| l.release();
    reload_pins.clearAndFree(gpa);
    reload_wanted.store(false, .release);
}

/// The editor told this game to reload its scripts (`_reload_scripts` or
/// `_reload_all_scripts`). Any thread; it only sets a flag, `frame` does
/// the work. An export build has no reload path.
pub fn requestReload() void {
    if (comptime host_options.export_build) return;
    reload_wanted.store(true, .release);
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
    reloadFromManifest();
}

fn keepingText(buf: *[48]u8) []const u8 {
    if (runtime.current()) |c| return std.fmt.bufPrint(buf, "keeping gen {d}", .{c.n}) catch "keeping the current gen";
    return "no generation is loaded";
}

fn reloadFromManifest() void {
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
                // The editor sends another reload after it stages.
                .missing, .library_missing => log("ziggurat: reload: the build may not be staged yet; {s}", .{keepingText(&keep_buf)}),
                else => logError("Ziggurat ignores the generation manifest for this reload because {s}; {s}.", .{ r.because(), keepingText(&keep_buf) }),
            }
            return;
        },
    };
    const cur = runtime.current();
    if (cur) |c| {
        if (trusted.n <= c.n) {
            log("ziggurat: reload: nothing to do (gen {d})", .{c.n});
            return;
        }
    }
    // Loaded before (a swap that was refused): ask for it again.
    if (runtime.find(trusted.n)) |g| {
        swap.request(g);
        return;
    }

    var store_obj = platform.generation_store.GenerationStore.init(gpa, io, .fromTrusted(store), os, stem, .{});
    var new_pin: ?platform.generation_store.FileLock = store_obj.pin(trusted.n) catch |err| blk: {
        logWarning("Ziggurat could not pin generation {d} ({s}); an editor's cleanup may delete its files while this game runs.", .{ trusted.n, @errorName(err) });
        break :blk null;
    };
    var keep_pin = false;
    defer if (!keep_pin) {
        if (new_pin) |*l| l.release();
    };
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
    if (new_pin) |l| {
        reload_pins.append(gpa, l) catch {
            logWarning("Ziggurat could not keep the pin of generation {d}: out of memory.", .{trusted.n});
            return finishLoad(gen, cur);
        };
        keep_pin = true;
    }
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
        stop();
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
        stop();
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
