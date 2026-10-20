//! Builds in the editor (spec sections 5 and 6): the host runs the build
//! service (L2) inside Godot's editor and turns each build into what the
//! editor and a game started from it need.
//!
//! - `start` (SCENE init, editor only) registers the project settings
//!   `ziggurat/zig_path` (empty: the Zig locator searches) and
//!   `ziggurat/dev/sdk_manifest` (absolute path of an SDK module manifest),
//!   starts a `BuildService` for the project and requests the build at
//!   project open. A missing or unusable setting is one log sentence that
//!   names it; then nothing builds and scripts keep the descriptor cache.
//! - Every successful save of a `.zig` file (`resource.on_saved`, any
//!   thread) queues a save request for the main thread.
//! - The service calls `onOutcome` on its build thread. It copies the
//!   outcome and pushes it onto the main-thread queue (`main_queue`), which
//!   `ZigLanguage._frame` drains. `apply` then runs on the main thread:
//!   a good build is loaded as the new generation (`runtime.load`), the load
//!   checks run (`load_checks`), the descriptor cache and the generation
//!   manifest are written; a failed build keeps the last good generation.
//!   Either way each diagnostic is printed as one line through Godot's error
//!   printing (`<file>:<line>:<column>: <message>`, or `<file>: <message>`
//!   without a line) and stored per file for `_validate` (`diag_cache`), and
//!   every live Zig script is updated: its build-failed flag from its own
//!   diagnostics, its placeholders (`_update_exports`), a tool script's
//!   placeholders become real instances, and a script whose file changed
//!   outside the editor gets the new text (checked on every outcome).
//! - `stop` (SCENE exit, before the main-thread queue closes and the
//!   language is destroyed) clears the save hook and stops the service,
//!   which kills a running compiler and joins the service's threads.
//!
//! None of this runs in a game process.
const std = @import("std");
const godot = @import("gdzig");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const runtime = @import("runtime.zig");
const host_io = @import("host_io.zig");
const main_queue = @import("main_queue.zig");
const diag_cache = @import("diag_cache.zig");
const desc_cache = @import("desc_cache.zig");
const script = @import("script.zig");
const resource = @import("resource.zig");
const manifest = @import("manifest.zig");
const load_checks = @import("load_checks.zig");
const props = @import("props.zig");

const Allocator = std.mem.Allocator;
const OsPath = platform.path.OsPath;
const BuildService = zbuild.service.BuildService;
const Outcome = zbuild.service.Outcome;
const Trigger = zbuild.service.Trigger;
const BuildPath = zbuild.service.BuildPath;
const String = godot.builtin.String;
const Variant = godot.builtin.Variant;
const Dictionary = godot.builtin.Dictionary;
const ProjectSettings = godot.class.ProjectSettings;
const Os = godot.class.Os;

pub const setting_zig_path = "ziggurat/zig_path";
pub const setting_sdk_manifest = "ziggurat/dev/sdk_manifest";

/// Thread-safe, as the service requires.
const gpa = std.heap.c_allocator;

/// Longest path handled.
const max_path_bytes = 4096;

/// Godot's `Variant::STRING` and `PROPERTY_HINT_GLOBAL_FILE`
/// (core/object/property_info.h).
const type_string: i64 = 4;
const hint_global_file: i64 = 15;

/// The running service and what its configuration borrows. Main thread.
const State = struct {
    /// Holds every string and slice the service's `Config` borrows.
    arena: std.heap.ArenaAllocator,
    sdk: zbuild.sdk_manifest.Manifest,
    /// The generation store's folder (`<project>/.godot/ziggurat`).
    store_root: []const u8,
    svc: *BuildService,
    /// The service's store folder, opened again here for `pin`.
    store: platform.generation_store.GenerationStore,
    /// A shared lock on every generation this editor loaded, so the store's
    /// sweep never deletes one (released at SCENE exit).
    pins: std.ArrayList(platform.generation_store.FileLock) = .empty,
    /// Generations loaded in this editor session (`notePinned`).
    loaded_count: u32 = 0,
};

var state: ?State = null;

/// Outcomes `apply` has handled (for the host tests). Main thread writes.
pub var outcomes_applied: std.atomic.Value(u32) = .init(0);

/// Files that had diagnostics after the last outcome (owned keys), so the
/// next outcome can mark them clean again. Main thread.
var diag_files: std.StringHashMapUnmanaged(void) = .empty;

// ------------------------------------------------------------ start, stop

/// Registers the settings, installs the save hook and starts the service
/// with a build for project open. Main thread, SCENE init, in the editor,
/// after the language and the loader and saver are registered.
pub fn start() void {
    registerSettings();
    if (nonInteractiveArg()) |arg| {
        log("Ziggurat does not build Zig scripts in this run ({s}).", .{arg});
        return;
    }
    resource.on_saved.store(&onSaved, .release);
    startService() catch |err| switch (err) {
        error.OutOfMemory => logError("Ziggurat cannot build Zig scripts: out of memory.", .{}),
    };
}

/// Stops the service (kills a running compiler, joins every thread of the
/// service) and frees its state. Main thread, SCENE exit, before the
/// main-thread queue closes and the language is destroyed. Outcomes still
/// queued are dropped by the queue.
pub fn stop() void {
    _ = resource.on_saved.cmpxchgStrong(&onSaved, null, .acq_rel, .acquire);
    if (state) |*st| {
        st.svc.deinit();
        log("ziggurat: build service stopped ({d} threads left)", .{zbuild.service.liveThreads()});
        for (st.pins.items) |*l| l.release();
        st.pins.deinit(gpa);
        st.sdk.deinit(gpa);
        st.arena.deinit();
        state = null;
    }
    var it = diag_files.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    diag_files.deinit(gpa);
    diag_files = .empty;
}

/// True while a requested build runs a compiler (for the host tests).
/// Main thread.
pub fn busy() bool {
    const st = state orelse return false;
    return st.svc.stats().updates_active > 0;
}

/// Command-line arguments of editor runs that are not interactive: an
/// import, an export, the doc tool, API dumps, and `--quit`/`-q` (which
/// quits after the first frame). `--quit-after <n>` keeps an interactive
/// editor (the host tests use it).
const non_interactive = [_][]const u8{
    "--import",                 "--doctool",                      "--gdextension-docs",
    "--dump-extension-api",     "--dump-extension-api-with-docs", "--dump-gdextension-interface",
    "--validate-extension-api", "--check-only",                   "--quit",
    "-q",
};

/// The first argument of this run that makes it non-interactive
/// (`non_interactive`, or any `--export-*`), or null. Godot consumes
/// `--import` and `--quit` without keeping them in `OS.get_cmdline_args()`
/// (main/main.cpp, the argument loop before `set_cmdline`), so on Linux the
/// process's own command line (`/proc/self/cmdline`) is read too. Main
/// thread.
fn nonInteractiveArg() ?[]const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    if (@import("builtin").os.tag == .linux) {
        var raw_buf: [64 * 1024]u8 = undefined;
        if (readCmdline(&raw_buf)) |raw| {
            var it = std.mem.splitScalar(u8, raw, 0);
            while (it.next()) |arg| {
                if (nonInteractive(arg)) {
                    const n = @min(arg.len, S.buf.len);
                    @memcpy(S.buf[0..n], arg[0..n]);
                    return S.buf[0..n];
                }
            }
        }
    }
    var args = Os.getCmdlineArgs();
    defer args.deinit();
    var i: i64 = 0;
    while (i < args.size()) : (i += 1) {
        var arg = args.get(i);
        defer arg.deinit();
        const text = props.stringText(&arg, &S.buf) orelse continue;
        if (nonInteractive(text)) return text;
    }
    return null;
}

fn nonInteractive(arg: []const u8) bool {
    if (std.mem.startsWith(u8, arg, "--export-")) return true;
    for (non_interactive) |want| if (std.mem.eql(u8, arg, want)) return true;
    return false;
}

/// The process's NUL-separated arguments, or null.
fn readCmdline(buf: []u8) ?[]const u8 {
    const io = host_io.get();
    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/cmdline", .{}) catch return null;
    defer file.close(io);
    var bufs = [_][]u8{buf};
    var n: usize = 0;
    while (n < buf.len) {
        bufs[0] = buf[n..];
        n += file.readStreaming(io, &bufs) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return null,
        };
    }
    return buf[0..n];
}

/// Adds both settings with an empty default, so they show in Project
/// Settings with a file picker.
fn registerSettings() void {
    inline for (.{ setting_zig_path, setting_sdk_manifest }) |name| {
        var n = String.fromLatin1(name);
        defer n.deinit();
        var empty = String.fromLatin1("");
        defer empty.deinit();
        const v = Variant.init(String, empty);
        defer v.deinit();
        if (!ProjectSettings.hasSetting(n)) ProjectSettings.setSetting(n, v);
        ProjectSettings.setInitialValue(n, v);
        ProjectSettings.setAsBasic(n, true);
        var info = Dictionary.init();
        defer info.deinit();
        putInfo(&info, "name", Variant.init(String, n));
        putInfo(&info, "type", Variant.init(i64, type_string));
        putInfo(&info, "hint", Variant.init(i64, hint_global_file));
        putInfo(&info, "hint_string", Variant.init(String, empty));
        ProjectSettings.addPropertyInfo(info);
    }
}

fn putInfo(d: *Dictionary, comptime key: []const u8, value: Variant) void {
    defer value.deinit();
    var k = String.fromLatin1(key);
    defer k.deinit();
    const kv = Variant.init(String, k);
    defer kv.deinit();
    _ = d.set(kv, value);
}

/// The text of the string setting `name`, allocated with `a`; empty when
/// unset or not a string.
fn settingText(a: Allocator, comptime name: []const u8) Allocator.Error![]const u8 {
    var n = String.fromLatin1(name);
    defer n.deinit();
    var empty = String.fromLatin1("");
    defer empty.deinit();
    const v = ProjectSettings.getSetting(n, .{ .default_value = Variant.init(String, empty) });
    defer v.deinit();
    var s = v.as(String) orelse return "";
    defer s.deinit();
    const text = try props.utf8Alloc(a, &s);
    return std.mem.trim(u8, text, " \t\r\n");
}

fn isAbsolute(p: []const u8) bool {
    return std.fs.path.isAbsolute(p);
}

fn startService() Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    var keep = false;
    defer if (!keep) arena_state.deinit();
    const a = arena_state.allocator();
    const io = host_io.get();

    const sdk_path = try settingText(a, setting_sdk_manifest);
    if (sdk_path.len == 0) {
        log("Ziggurat does not build Zig scripts: the project setting " ++ setting_sdk_manifest ++ " is not set (it needs the absolute path of an SDK module manifest).", .{});
        return;
    }
    if (!isAbsolute(sdk_path)) {
        log("Ziggurat does not build Zig scripts: the project setting " ++ setting_sdk_manifest ++ " ({s}) is not usable, because it is not an absolute path.", .{sdk_path});
        return;
    }
    const zig_path = try settingText(a, setting_zig_path);
    if (zig_path.len != 0 and !isAbsolute(zig_path)) {
        log("Ziggurat does not build Zig scripts: the project setting " ++ setting_zig_path ++ " ({s}) is not usable, because it is not an absolute path.", .{zig_path});
        return;
    }
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var sdk = zbuild.sdk_manifest.load(gpa, io, .fromTrusted(sdk_path), &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log("Ziggurat does not build Zig scripts: the project setting " ++ setting_sdk_manifest ++ " is not usable: {s}", .{if (msg.items.len != 0) msg.items else @errorName(err)});
            return;
        },
    };
    var sdk_kept = false;
    defer if (!sdk_kept) sdk.deinit(gpa);

    // The project folder as a realpath (the cache folder and `build.lock`
    // are keyed by it).
    var res = String.fromLatin1("res://");
    defer res.deinit();
    var abs = ProjectSettings.globalizePath(res);
    defer abs.deinit();
    const globalized = try props.utf8Alloc(a, &abs);
    const trimmed = if (globalized.len > 1) std.mem.trimEnd(u8, globalized, "/\\") else globalized;
    const project = std.Io.Dir.cwd().realPathFileAlloc(io, trimmed, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logError("Ziggurat cannot build Zig scripts: the project folder {s} cannot be resolved ({s}).", .{ trimmed, @errorName(err) });
            return;
        },
    };
    var store_buf: [max_path_bytes]u8 = undefined;
    const store_root = try a.dupe(u8, desc_cache.dataPath(&store_buf, "ziggurat") orelse {
        logError("Ziggurat cannot build Zig scripts: the project's data folder path is too long.", .{});
        return;
    });

    const env = try hostEnv(a);
    const paths: platform.path.PathService = .init(.{ .project = .fromTrusted(project) }, env);
    const toolchain = paths.dir(.toolchain, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // No per-user folder: no downloaded Zig to find there.
        else => OsPath.fromTrusted(store_root),
    };

    var diag: [256]u8 = undefined;
    const svc = BuildService.initDiag(gpa, io, .{
        .paths = paths,
        .locate = .{
            .configured = if (zig_path.len != 0) .fromTrusted(zig_path) else null,
            .toolchain_dir = toolchain,
            .env = env,
        },
        .sdk = sdk.modules,
        .store_root = .fromTrusted(store_root),
        .on_outcome = &onOutcome,
        .check_tables = true,
        .expected_stamp = runtime.expected_stamp,
    }, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logError("Ziggurat cannot build Zig scripts: {s}", .{platform.elf.diagText(&diag)});
            return;
        },
    };
    keep = true;
    sdk_kept = true;
    state = .{
        .arena = arena_state,
        .sdk = sdk,
        .store_root = store_root,
        .svc = svc,
        .store = .init(gpa, io, .fromTrusted(store_root), @import("builtin").os.tag, zbuild.service.lib_stem, .{}),
    };
    svc.request(.open);
}

/// The per-user folders and `PATH` as the Zig locator and the path service
/// need them, read through Godot (`OS.get_environment`); copies in `a`.
fn hostEnv(a: Allocator) Allocator.Error!platform.path.HostEnv {
    const builtin = @import("builtin");
    return .{
        .os = builtin.os.tag,
        .home = try envVar(a, if (builtin.os.tag == .windows) "USERPROFILE" else "HOME"),
        .xdg_cache_home = try envVar(a, "XDG_CACHE_HOME"),
        .xdg_config_home = try envVar(a, "XDG_CONFIG_HOME"),
        .xdg_data_home = try envVar(a, "XDG_DATA_HOME"),
        .local_app_data = try envVar(a, "LOCALAPPDATA"),
        .app_data = try envVar(a, "APPDATA"),
        .path = try envVar(a, "PATH"),
    };
}

fn envVar(a: Allocator, comptime name: []const u8) Allocator.Error!?[]const u8 {
    var n = String.fromLatin1(name);
    defer n.deinit();
    var v = Os.getEnvironment(n);
    defer v.deinit();
    const text = try props.utf8Alloc(a, &v);
    return if (text.len == 0) null else text;
}

// ------------------------------------------------------------ triggers

/// `resource.on_saved`: any thread. Only queues; the main thread asks the
/// service for a build.
fn onSaved(_: []const u8) void {
    main_queue.push(requestSave, null, null) catch {};
}

fn requestSave(_: ?*anyopaque) void {
    if (state) |st| st.svc.request(.save);
}

// ------------------------------------------------------------ outcomes

/// One build outcome, copied off the build thread (all owned, C allocator).
const Msg = struct {
    trigger: Trigger,
    ok: bool,
    path: BuildPath,
    ms: u64,
    gen_n: u32 = 0,
    lib: ?[]u8 = null,
    message: ?[]u8 = null,
    diags: []Diag = &.{},

    const Diag = struct { rel: ?[]u8, line: u32, column: u32, message: []u8 };

    fn copy(o: *const Outcome) Allocator.Error!*Msg {
        const m = try gpa.create(Msg);
        m.* = .{ .trigger = o.trigger, .ok = o.ok, .path = o.path, .ms = o.ms };
        errdefer m.free();
        if (o.generation) |g| {
            m.gen_n = g.n;
            m.lib = try gpa.dupe(u8, g.lib.bytes);
        }
        if (o.message) |text| m.message = try gpa.dupe(u8, text);
        var list: std.ArrayList(Diag) = try .initCapacity(gpa, o.diagnostics.len);
        errdefer {
            for (list.items) |d| freeDiag(d);
            list.deinit(gpa);
        }
        for (o.diagnostics) |d| {
            const rel: ?[]u8 = if (d.rel) |r| try gpa.dupe(u8, r) else null;
            const text = gpa.dupe(u8, d.message) catch |err| {
                if (rel) |r| gpa.free(r);
                return err;
            };
            // Paths in the table and in `res://` use `/`.
            if (rel) |r| std.mem.replaceScalar(u8, r, '\\', '/');
            list.appendAssumeCapacity(.{ .rel = rel, .line = d.line, .column = d.column, .message = text });
        }
        m.diags = try list.toOwnedSlice(gpa);
        return m;
    }

    fn freeDiag(d: Diag) void {
        if (d.rel) |r| gpa.free(r);
        gpa.free(d.message);
    }

    fn free(m: *Msg) void {
        if (m.lib) |l| gpa.free(l);
        if (m.message) |t| gpa.free(t);
        for (m.diags) |d| freeDiag(d);
        gpa.free(m.diags);
        gpa.destroy(m);
    }
};

/// The service's `on_outcome`: build thread. Copies the outcome for the
/// main thread; out of memory, the outcome is lost (the next build reports
/// again).
fn onOutcome(_: ?*anyopaque, o: *const Outcome) void {
    const m = Msg.copy(o) catch return;
    main_queue.push(apply, m, drop) catch {};
}

fn drop(ctx: ?*anyopaque) void {
    const m: *Msg = @ptrCast(@alignCast(ctx.?));
    m.free();
}

/// Diagnostics per project-relative file, for one outcome.
const Files = std.StringArrayHashMapUnmanaged(std.ArrayList(diag_cache.Diagnostic));

/// Handles one outcome on the main thread (see the file comment).
fn apply(ctx: ?*anyopaque) void {
    const m: *Msg = @ptrCast(@alignCast(ctx.?));
    defer m.free();
    if (state == null) return;
    applyMsg(m) catch logError("Ziggurat could not record a build result: out of memory.", .{});
    _ = outcomes_applied.fetchAdd(1, .release);
}

fn applyMsg(m: *const Msg) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = host_io.get();
    const st = &state.?;

    if (m.message) |text| {
        if (m.ok) log("ziggurat: {s}", .{text}) else logError("{s}", .{text});
    }

    // A good build becomes the current generation.
    const previous = runtime.current();
    var loaded: ?*runtime.Generation = null;
    if (m.ok and m.lib != null) {
        const lib = m.lib.?;
        var diag: [256]u8 = undefined;
        if (runtime.load(gpa, .fromTrusted(lib), m.gen_n, &diag)) |g| {
            loaded = g;
            notePinned(st, g.n);
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // `load` logged it already.
            error.NotMainThread => {},
            error.Refused => logError("{s}", .{std.mem.sliceTo(&diag, 0)}),
        }
    }

    var files: Files = .empty;
    var file_diags = false;
    for (m.diags) |d| {
        printDiagnostic(d.rel, d.line, d.column, d.message);
        const rel = d.rel orelse continue;
        file_diags = true;
        try addDiagnostic(a, &files, rel, .{ .line = d.line, .column = d.column, .message = d.message });
    }

    if (loaded) |g| {
        const findings = try load_checks.run(a, g);
        for (findings) |f| {
            const rel = props.text(g.scripts()[f.script].path);
            printDiagnostic(rel, 0, 0, f.message);
            try addDiagnostic(a, &files, rel, .{ .line = 0, .column = 0, .message = f.message });
        }
        if (findings.len != 0) {
            // A load-check finding fails the build: new instances keep the
            // previous generation and the game keeps the previous manifest.
            runtime.setCurrent(previous);
            log("ziggurat: build {d} failed the load checks ({t}, {d} ms); the last good build stays in use", .{ g.n, m.trigger, m.ms });
        } else {
            var cache_buf: [max_path_bytes]u8 = undefined;
            if (desc_cache.projectPath(&cache_buf)) |path| {
                desc_cache.write(gpa, io, .fromTrusted(path), g) catch |err|
                    logError("Ziggurat could not write the descriptor cache {s} ({s}).", .{ path, @errorName(err) });
            }
            manifest.write(gpa, io, .fromTrusted(st.store_root), g.n, std.fs.path.basename(m.lib.?)) catch |err|
                logError("Ziggurat could not write the generation manifest in {s} ({s}).", .{ st.store_root, @errorName(err) });
            log("ziggurat: build {d} loaded ({t}, {t}, {d} ms)", .{ g.n, m.trigger, m.path, m.ms });
        }
    } else {
        log("ziggurat: build failed ({t}, {d} ms); the last good build stays in use", .{ m.trigger, m.ms });
    }

    // Only a build that reached the compiler's verdict replaces what is
    // known about the files: a loaded generation (with or without load-check
    // findings), or a failed build with errors in files. A failure without
    // file errors (Zig missing, `build.lock` timeout, compiler death,
    // invalid table, refused load) keeps the earlier diagnostics and
    // failed states; its message was printed above.
    const verdict = loaded != null or (!m.ok and file_diags);
    if (verdict) try recordDiagnostics(&files);
    updateScripts(if (verdict) &files else null);
}

/// Pins generation `n` and counts it (spec section 6: the host counts the
/// generations it loaded; none is ever unloaded).
fn notePinned(st: *State, n: u32) void {
    st.loaded_count += 1;
    log("ziggurat: {d} generations loaded in this editor session", .{st.loaded_count});
    const lock = st.store.pin(n) catch |err| {
        logError("Ziggurat could not pin generation {d} in {s} ({s}); a later sweep may delete its files.", .{ n, st.store_root, @errorName(err) });
        return;
    };
    st.pins.append(gpa, lock) catch {
        var l = lock;
        l.release();
    };
}

fn addDiagnostic(a: Allocator, files: *Files, rel: []const u8, d: diag_cache.Diagnostic) Allocator.Error!void {
    const gop = try files.getOrPut(a, rel);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, d);
}

/// Stores each file's diagnostics for `_validate`; a file that had some
/// after the last outcome and has none now is recorded clean.
fn recordDiagnostics(files: *const Files) Allocator.Error!void {
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    var old = diag_files.keyIterator();
    while (old.next()) |k| {
        if (!files.contains(k.*)) try stale.append(gpa, k.*);
    }
    for (stale.items) |k| {
        try diag_cache.set(k, &.{});
        _ = diag_files.remove(k);
        gpa.free(k);
    }
    for (files.keys(), files.values()) |rel, list| {
        try diag_cache.set(rel, list.items);
        if (diag_files.contains(rel)) continue;
        const key = try gpa.dupe(u8, rel);
        diag_files.put(gpa, key, {}) catch |err| {
            gpa.free(key);
            return err;
        };
    }
}

/// Brings every live Zig script up to date with the outcome. Without
/// `files` (a failure that says nothing about files) build-failed states
/// stay as they are.
fn updateScripts(files: ?*const Files) void {
    const scripts = script.liveScripts(gpa) catch {
        logError("Ziggurat could not update the Zig scripts after a build: out of memory.", .{});
        return;
    };
    defer gpa.free(scripts);
    for (scripts) |s| {
        defer script.release(s);
        var buf: [max_path_bytes]u8 = undefined;
        const rel = s.rel(&buf) orelse continue;
        if (files) |f| s.setBuildFailed(f.contains(rel));
        _ = s.refreshFromDisk();
        s._updateExports();
        s.swapToolPlaceholders();
    }
}

/// One line through Godot's error printing, which the editor also lists
/// in its Errors tab.
fn printDiagnostic(rel: ?[]const u8, line: u32, column: u32, message: []const u8) void {
    var buf: [max_path_bytes + 2048]u8 = undefined;
    const text = if (rel) |r|
        (if (line == 0)
            std.fmt.bufPrintSentinel(&buf, "{s}: {s}", .{ r, message }, 0)
        else
            std.fmt.bufPrintSentinel(&buf, "{s}:{d}:{d}: {s}", .{ r, line, column, message }, 0))
    else
        std.fmt.bufPrintSentinel(&buf, "{s}", .{message}, 0);
    const z = text catch truncated(&buf, message);
    var file_buf: [max_path_bytes + 8]u8 = undefined;
    const file = if (rel) |r| std.fmt.bufPrintSentinel(&file_buf, "res://{s}", .{r}, 0) catch "" else "";
    godot.raw.printError(z.ptr, "Zig build", if (file.len == 0) "" else file.ptr, @intCast(@min(line, std.math.maxInt(i32))), 1);
}

/// The start of `message`, cut to fit `buf` with a terminating 0.
fn truncated(buf: []u8, message: []const u8) [:0]const u8 {
    const n = @min(message.len, buf.len - 1);
    @memcpy(buf[0..n], message[0..n]);
    buf[n] = 0;
    return buf[0..n :0];
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_path_bytes + 1024]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printError(msg.ptr, "Zig build", "src/host/editor_build.zig", @src().line, 1);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_path_bytes + 1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}
