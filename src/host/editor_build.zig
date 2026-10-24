//! Builds in the editor (spec sections 5 and 6): the host runs the build
//! service (L2) inside Godot's editor and turns each build into what the
//! editor and a game started from it need.
//!
//! - `start` (SCENE init, editor only) registers the project settings
//!   `ziggurat/zig_path` (the project's override of the Zig path) and
//!   `ziggurat/dev/sdk_manifest` (absolute path of an SDK module manifest;
//!   a developer override: when it is empty, the shipped SDK's manifest
//!   `res://addons/ziggurat/sdk/sdk-manifest.json` is used, `sdkManifest`),
//!   starts a `BuildService` for the project and requests the build at
//!   project open: at once when the project setting `ziggurat/zig_path` is
//!   set (it wins over the editor setting), otherwise when the editor
//!   plugin enters the tree (`editorReady`; the editor setting can be read
//!   only once the editor exists), with the first frame as the fallback. A
//!   missing or unusable SDK manifest (neither the setting nor the shipped
//!   SDK) is one log sentence that names it; then nothing builds and
//!   scripts keep the descriptor cache.
//! - The editor plugin registers the editor settings (per user;
//!   `registerEditorSettings`): `ziggurat/zig_path` (the Zig path),
//!   `ziggurat/editor/indent_with_spaces` (`.zig` tabs indent with spaces)
//!   and `ziggurat/build/check_interval_seconds` (how often files changed
//!   outside the editor are looked for; 0 = only at focus-in).
//! - `requestIfChanged` (the plugin's `watcher` trigger: focus-in and the
//!   interval) builds only when a script or helper file changed since the
//!   last build (`BuildService.requestIfChanged`); without a change there
//!   is no outcome.
//! - Every build request (`requestBuild`: open, save, the plugin's
//!   triggers) reads both Zig path settings again and hands them to the
//!   service (`BuildService.setZigPaths`): the project setting wins when
//!   set, then the editor setting, the downloaded toolchain and `PATH`
//!   (the Zig locator's order). The editor setting is checked only while
//!   the project setting is empty (otherwise a relative one is left out).
//!   A relative path that is checked builds nothing: the
//!   request gives a failed outcome at once (`zig_problem` `missing`, its
//!   message names the setting), so `status` and the Zig panel show it.
//! - Every successful save of a `.zig` file (`resource.on_saved`, any
//!   thread) queues a save request for the main thread.
//! - The service calls `onOutcome` on its build thread. It copies the
//!   outcome and pushes it onto the main-thread queue (`main_queue`), which
//!   `ZigLanguage._frame` drains. `apply` then runs on the main thread.
//!   A staged build arrives pinned (`Outcome.pin`, taken when the service
//!   staged it), so no sweep deletes it while its outcome waits (spec risk
//!   20); `apply` moves that pin into the editor's own pins, and an outcome
//!   that is dropped or rejected releases it.
//!   A good build's load checks (`load_checks`) run on the table snapshot
//!   the service took (`Outcome.snapshot`), before anything is loaded; a
//!   finding fails the build and nothing is loaded. Then the editor
//!   generation policy (spec section 6): when the snapshot has a tool
//!   script, the build is loaded (`runtime.load`), pinned, and handed to
//!   the swap engine (`swap.request`), which moves the live instances to it
//!   at a later frame; it is never published here. Before that, the
//!   module's property defaults must equal the snapshot's
//!   (`staleDefaults`); a stale incremental build is not used and is
//!   requested again in full. Without a tool script
//!   nothing is loaded: the snapshot alone gives the scripts their
//!   descriptors (`script.installSnapshot`). Either way the descriptor
//!   cache and the generation manifest are written, and the generation the
//!   manifest names stays pinned until a newer manifest replaces it. A
//!   project that gains a tool script loads from that build on; one that
//!   loses its last tool script keeps loading while instances of the old
//!   tool scripts are alive (so open tool nodes get the newest code), then
//!   stops; nothing is ever unloaded. The loaded libraries' allocated bytes
//!   and the kept snapshot descriptors (the scripts' parsed ones and the
//!   service's, both counted exactly) are summed (`memory`, shown on the
//!   Zig panel by `memoryText`), and above `size_warning_bytes` one warning
//!   per session suggests a restart. A failed build keeps the last good
//!   one.
//!   Either way each diagnostic is printed as one line through Godot's error
//!   printing (`<file>:<line>:<column>: <message>`, or `<file>: <message>`
//!   without a line) and stored per file for `_validate` (`diag_cache`), and
//!   every live Zig script is updated: its build-failed flag from its own
//!   diagnostics, its placeholders (`_update_exports`), a tool script's
//!   placeholders become real instances, and a script whose file changed
//!   outside the editor gets the new text (checked on every outcome).
//! - The public build API for the editor plugin: `requestBuild`, `status`
//!   (whether a build runs, and a summary of the last applied outcome),
//!   `diagnosticsCopy` (that outcome's diagnostics per file) and
//!   `applyFinished` (runs queued outcomes now, only at a safe point). All
//!   main thread.
//! - For the export plugin (export_plugin.zig): `projectRoot` (the
//!   project folder as editor builds key their cache by it) and
//!   `exportInputs` (the Zig located as editor builds locate it, the SDK
//!   modules and the per-user cache folder). Both work without a service:
//!   an `--export-*` run starts none.
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
const swap = @import("swap.zig");
const registry = @import("registry.zig");
const abi = @import("ziggurat_abi");
const debugger_plugin = @import("debugger_plugin.zig");
const language = @import("language.zig");

const Allocator = std.mem.Allocator;
const OsPath = platform.path.OsPath;
const BuildService = zbuild.service.BuildService;
const Outcome = zbuild.service.Outcome;
const FileLock = platform.generation_store.FileLock;
pub const Trigger = zbuild.service.Trigger;
pub const BuildPath = zbuild.service.BuildPath;
pub const ZigProblem = zbuild.service.ZigProblem;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const Dictionary = godot.builtin.Dictionary;
const ProjectSettings = godot.class.ProjectSettings;
const EditorInterface = godot.class.EditorInterface;
const Engine = godot.class.Engine;
const Os = godot.class.Os;

pub const setting_zig_path = "ziggurat/zig_path";
pub const setting_sdk_manifest = "ziggurat/dev/sdk_manifest";
/// The shipped SDK's manifest, used when `setting_sdk_manifest` is empty.
pub const shipped_sdk_manifest = "res://addons/ziggurat/sdk/sdk-manifest.json";
/// Whether Play builds the Zig scripts first (the editor plugin's
/// `_build`); a bool, true by default.
pub const setting_build_on_play = "ziggurat/build/build_on_play";
/// How long Play waits for that build, in seconds; an int, 60 by default.
pub const setting_play_wait = "ziggurat/build/play_wait_seconds";
pub const default_play_wait_seconds: u32 = 60;
/// Editor setting (per user): `.zig` script tabs indent with spaces (the
/// editor plugin); a bool, true by default.
pub const setting_indent_with_spaces = "ziggurat/editor/indent_with_spaces";
/// Editor setting (per user): seconds between two looks for files changed
/// outside the editor; an int, 0 by default (only when the editor regains
/// focus).
pub const setting_check_interval = "ziggurat/build/check_interval_seconds";

/// Thread-safe, as the service requires.
const gpa = std.heap.c_allocator;

/// Longest path handled.
const max_path_bytes = 4096;

/// Godot's `Variant::BOOL`, `Variant::INT`, `Variant::STRING`,
/// `PROPERTY_HINT_RANGE` and `PROPERTY_HINT_GLOBAL_FILE`
/// (core/variant/variant.h, core/object/property_info.h).
const type_bool: i64 = 1;
const type_int: i64 = 2;
const type_string: i64 = 4;
const hint_range: i64 = 1;
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
    /// Set once the loaded-size warning was printed (`warnSize`).
    size_warned: bool = false,
    /// A shared lock on the generation the manifest names (`writeManifest`),
    /// so the store's sweep never deletes the build a game is told to load,
    /// also when the editor did not load it. Null when the editor loaded
    /// that generation: its load pin (`pins`) already holds it. Released
    /// when a newer manifest is written and at SCENE exit.
    manifest_pin: ?platform.generation_store.FileLock = null,
    /// Set once a build had a tool script (`applyGood`).
    had_tool: bool = false,
    /// Set once the loss of the last tool script was logged.
    tool_loss_logged: bool = false,
};

var state: ?State = null;

/// Above this many bytes of loaded generations (`runtime.loadedBytes`) the
/// editor warns once per session. The host tests lower it.
pub var size_warning_bytes: u64 = 2 << 30;

/// Outcomes `apply` has handled (for the host tests). Main thread writes.
pub var outcomes_applied: std.atomic.Value(u32) = .init(0);

/// Files that had diagnostics after the last outcome (owned keys), so the
/// next outcome can mark them clean again. Main thread.
var diag_files: std.StringHashMapUnmanaged(void) = .empty;

/// Outcomes copied off the build thread and not yet applied or dropped,
/// so `status` says `building` until the newest outcome is applied.
var queued_outcomes: std.atomic.Value(u32) = .init(0);

/// What `status` and `diagnosticsCopy` report: the last applied outcome
/// (C allocator). Main thread.
var last_applied: ?LastStore = null;

/// `Status.good_n`. Main thread.
var good_n: ?u32 = null;

// ------------------------------------------------------------ public API

/// A summary of one applied build outcome (`status`).
pub const Last = struct {
    /// The generation the build staged, or null when it staged none.
    n: ?u32,
    /// True when the editor took the build into use: it staged a
    /// generation, its load checks passed and its library and defaults
    /// were accepted. Also true, with `n` null, when the project has no Zig
    /// scripts (nothing to build).
    ok: bool,
    trigger: Trigger,
    path: BuildPath,
    /// Wall time of the whole build.
    ms: u64,
    /// The outcome's one sentence (`Outcome.message`), or null. Owned here:
    /// valid until the next outcome is applied (main thread).
    message: ?[]const u8,
    /// Compile errors plus load-check findings.
    error_count: u32,
    /// Scan problems (they do not fail a build by themselves).
    warning_count: u32,
    zig_problem: ZigProblem,
};

pub const Status = struct {
    /// A build runs, one is pending, or an outcome waits to be applied.
    building: bool,
    /// The last applied outcome, or null before the first.
    last: ?Last,
    /// The generation of the last build the editor took into use in this
    /// session (`Last.ok`), or null before the first.
    good_n: ?u32 = null,
};

/// The diagnostics of one file (`diagnosticsCopy`).
pub const FileDiagnostics = struct {
    /// Project-relative path with `/` separators (as in `res://<rel>`),
    /// or "" for diagnostics outside the project's files.
    rel: []const u8,
    /// 1-based line and column; both 0 without a place in the file.
    items: []diag_cache.Diagnostic,
};

/// Asks for a build. Reads the Zig path settings again first (the project
/// setting `ziggurat/zig_path`, then the editor setting of the same name),
/// so a changed path or a downloaded Zig is used without a restart. Does
/// nothing when the project has no build service (see `start`). Main
/// thread.
pub fn requestBuild(t: Trigger) void {
    const st = if (state) |*s| s else return;
    var buf: [max_path_bytes + 256]u8 = undefined;
    switch (passZigPaths(st, &buf)) {
        .ok => st.svc.request(t),
        .unusable => |text| failNow(t, text),
        .out_of_memory => {},
    }
}

/// As `requestBuild`, but the service builds only when a script or helper
/// file changed since the last build's scan (`BuildService.requestIfChanged`);
/// otherwise there is no outcome. An unusable Zig path setting builds
/// nothing and reports nothing here (the open build and every requested
/// build report it; a check at every focus-in would repeat it). Main
/// thread.
pub fn requestIfChanged(t: Trigger) void {
    const st = if (state) |*s| s else return;
    var buf: [max_path_bytes + 256]u8 = undefined;
    switch (passZigPaths(st, &buf)) {
        .ok => st.svc.requestIfChanged(t),
        .unusable, .out_of_memory => {},
    }
}

/// `requestIfChanged` checks the service finished, and how many of them
/// found no change (for the host tests). Main thread.
pub fn checkCounts() struct { checks: u32, skipped: u32 } {
    const st = state orelse return .{ .checks = 0, .skipped = 0 };
    const x = st.svc.stats();
    return .{ .checks = x.checks, .skipped = x.checks_skipped };
}

/// Whether a build runs and the last applied outcome. Main thread; the
/// `message` slice stays valid until the next outcome is applied.
pub fn status() Status {
    const st = state orelse return .{ .building = false, .last = null };
    const building = st.svc.busy() or queued_outcomes.load(.acquire) != 0;
    return .{ .building = building, .last = if (last_applied) |l| l.info else null, .good_n = good_n };
}

/// A copy of the last applied outcome's diagnostics, grouped per file in
/// the order the build reported them: compile errors, scan problems and
/// load-check findings. Empty before the first outcome. Free it with
/// `freeDiagnostics(a, list)`. Main thread.
pub fn diagnosticsCopy(a: Allocator) Allocator.Error![]FileDiagnostics {
    const l = last_applied orelse return a.alloc(FileDiagnostics, 0);
    return copyFileDiagnostics(a, l.files);
}

pub fn freeDiagnostics(a: Allocator, list: []FileDiagnostics) void {
    for (list) |f| freeFile(a, f);
    a.free(list);
}

fn freeFile(a: Allocator, f: FileDiagnostics) void {
    for (f.items) |d| a.free(d.message);
    a.free(f.items);
    a.free(f.rel);
}

/// Runs what waits in the main-thread queue now (one `main_queue.drain`),
/// so an outcome the service has published is applied before the caller
/// goes on, and returns how many callbacks ran. Null, with nothing run,
/// when the main thread is not at a safe point (`language.atSafePoint`:
/// module code on the stack, a `_frame` or a drain running). Main thread.
pub fn applyFinished() ?usize {
    if (!language.atSafePoint()) return null;
    return main_queue.drain();
}

/// True when the project has a build service (see `start`). Main thread.
pub fn hasService() bool {
    return state != null;
}

/// Waits until the service runs no build and has none pending, at most
/// `timeout_ms`. An outcome the service published by then waits in the
/// main-thread queue (`applyFinished` applies it). True when the service
/// is idle (also without a service), false after the timeout. Blocks the
/// calling thread. Main thread.
pub fn waitIdle(timeout_ms: u32) bool {
    const st = state orelse return true;
    st.svc.waitIdle(timeout_ms) catch return false;
    return true;
}

/// The project setting `ziggurat/build/build_on_play` (true when unset or
/// not a bool).
pub fn buildOnPlay() bool {
    var n = String.fromLatin1(setting_build_on_play);
    defer n.deinit();
    const v = ProjectSettings.getSetting(n, .{ .default_value = Variant.init(bool, true) });
    defer v.deinit();
    return v.as(bool) orelse true;
}

/// The project setting `ziggurat/build/play_wait_seconds`, at least 0
/// (60 when unset or not an int).
pub fn playWaitSeconds() u32 {
    var n = String.fromLatin1(setting_play_wait);
    defer n.deinit();
    const v = ProjectSettings.getSetting(n, .{ .default_value = Variant.init(i64, default_play_wait_seconds) });
    defer v.deinit();
    const s = v.as(i64) orelse return default_play_wait_seconds;
    return std.math.cast(u32, @max(s, 0)) orelse std.math.maxInt(u32);
}

/// The generation a game started now would load: the last build the
/// editor took into use in this session (`Status.good_n`), otherwise the
/// one the generation manifest names (a good build of an earlier session,
/// when the manifest and its library pass the game's own checks). Null
/// without either. Main thread.
pub fn startableGeneration() ?u32 {
    if (good_n) |n| return n;
    // The manifest reader is not in an export build (manifest.zig), and an
    // export build has no editor plugin to ask.
    if (comptime @import("host_options").export_build) return null;
    const st = state orelse return null;
    var r = manifest.readTrusted(gpa, host_io.get(), st.store_root, @import("builtin").os.tag, zbuild.service.lib_stem) catch return null;
    defer r.deinit(gpa);
    return switch (r) {
        .ok => |t| t.n,
        .refused => null,
    };
}

/// Registers the editor settings `ziggurat/zig_path` (the per-user Zig
/// path, empty by default, with a file picker),
/// `ziggurat/editor/indent_with_spaces` (true) and
/// `ziggurat/build/check_interval_seconds` (0; 0 to 3600 in the inspector,
/// more when typed). Main thread, once the editor exists (the editor
/// plugin's `_enter_tree`). A value equal to the default is not written to
/// the editor settings file.
pub fn registerEditorSettings() void {
    const es = editorSettings() orelse return;
    defer releaseRef(es);
    var empty = String.fromLatin1("");
    defer empty.deinit();
    addEditorSetting(es, setting_zig_path, Variant.init(String, empty), type_string, hint_global_file, "");
    addEditorSetting(es, setting_indent_with_spaces, Variant.init(bool, true), type_bool, 0, "");
    addEditorSetting(es, setting_check_interval, Variant.init(i64, 0), type_int, hint_range, "0,3600,1,or_greater,suffix:s");
}

/// Registers the editor setting `name` with default `value` (consumed)
/// and its property info.
fn addEditorSetting(es: *godot.class.EditorSettings, comptime name: [:0]const u8, value: Variant, type_id: i64, hint: i64, comptime hint_string: []const u8) void {
    defer value.deinit();
    var n = String.fromLatin1(name);
    defer n.deinit();
    if (!es.hasSetting(n)) es.setSetting(n, value);
    es.setInitialValue(.fromComptimeLatin1(name), value, false);
    var hs = String.fromLatin1(hint_string);
    defer hs.deinit();
    var info = Dictionary.init();
    defer info.deinit();
    putInfo(&info, "name", Variant.init(String, n));
    putInfo(&info, "type", Variant.init(i64, type_id));
    putInfo(&info, "hint", Variant.init(i64, hint));
    putInfo(&info, "hint_string", Variant.init(String, hs));
    es.addPropertyInfo(info);
}

/// The editor setting `ziggurat/editor/indent_with_spaces` (true when the
/// editor does not exist yet, or the setting is unset or not a bool).
/// Main thread.
pub fn indentWithSpaces() bool {
    const v = editorSetting(setting_indent_with_spaces) orelse return true;
    defer v.deinit();
    return v.as(bool) orelse true;
}

/// The editor setting `ziggurat/build/check_interval_seconds`, at least 0
/// (0 when the editor does not exist yet, or the setting is unset or not
/// an int). Main thread.
pub fn checkIntervalSeconds() u32 {
    const v = editorSetting(setting_check_interval) orelse return 0;
    defer v.deinit();
    const s = v.as(i64) orelse return 0;
    return std.math.cast(u32, @max(s, 0)) orelse std.math.maxInt(u32);
}

/// The value of the editor setting `name` (the caller deinits it), or null
/// while the editor does not exist or the setting is unset. Main thread.
pub fn editorSetting(comptime name: []const u8) ?Variant {
    const es = editorSettings() orelse return null;
    defer releaseRef(es);
    var n = String.fromLatin1(name);
    defer n.deinit();
    if (!es.hasSetting(n)) return null;
    return es.getSetting(n);
}

/// The editor's settings, or null while the editor does not exist yet.
/// Godot returns them with a reference for the caller (a `Ref` return):
/// release it with `releaseRef`.
fn editorSettings() ?*godot.class.EditorSettings {
    if (!Engine.hasSingleton(.fromComptimeLatin1("EditorInterface"))) return null;
    return EditorInterface.getEditorSettings();
}

/// Drops the reference a `Ref` return gave the caller.
pub fn releaseRef(obj: anytype) void {
    const rc = godot.class.RefCounted.upcast(obj);
    if (rc.unreference()) godot.raw.objectDestroy(@ptrCast(rc));
}

const PathCheck = union(enum) {
    ok,
    /// The sentence that names the unusable setting (in the caller's
    /// buffer).
    unusable: []const u8,
    out_of_memory,
};

/// Reads both Zig path settings and hands them to the service. A relative
/// project setting is `unusable`, with one sentence that names it written
/// to `buf`. The editor setting is checked only while the project setting
/// is empty: then a relative one is `unusable` too; while the project
/// setting is set (it wins), a relative editor setting is left out and an
/// absolute one stays the locator's next candidate.
fn passZigPaths(st: *State, buf: []u8) PathCheck {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const project = settingText(a, setting_zig_path) catch return oom();
    const editor = editorSettingText(a, setting_zig_path) catch return oom();
    if (project.len != 0 and !isAbsolute(project)) return unusable(buf, "project", project);
    if (project.len == 0 and editor.len != 0 and !isAbsolute(editor)) return unusable(buf, "editor", editor);
    const editor_path: ?[]const u8 = if (editor.len != 0 and isAbsolute(editor)) editor else null;
    st.svc.setZigPaths(if (project.len != 0) project else null, editor_path) catch return oom();
    return .ok;
}

fn unusable(buf: []u8, comptime kind: []const u8, value: []const u8) PathCheck {
    const fmt = "Ziggurat does not build Zig scripts: the " ++ kind ++ " setting " ++ setting_zig_path ++ " ({s}) is not usable, because it is not an absolute path.";
    return .{ .unusable = std.fmt.bufPrint(buf, fmt, .{value}) catch
        std.fmt.bufPrint(buf, fmt, .{"too long"}) catch unreachable };
}

fn oom() PathCheck {
    logError("Ziggurat cannot build Zig scripts: out of memory.", .{});
    return .out_of_memory;
}

/// A request that builds nothing because a Zig path setting is unusable:
/// a failed outcome with `message` is queued for the main thread, as the
/// service's outcomes are, so `status` and the panel show it.
fn failNow(t: Trigger, message: []const u8) void {
    const m = gpa.create(Msg) catch return logError("{s}", .{message});
    m.* = .{ .trigger = t, .ok = false, .path = .full, .ms = 0, .zig_problem = .missing };
    m.message = gpa.dupe(u8, message) catch {
        m.free();
        return logError("{s}", .{message});
    };
    _ = queued_outcomes.fetchAdd(1, .acq_rel);
    // On a failed push the queue has already run `drop`, which frees `m`
    // and takes the count back (`main_queue.push`).
    main_queue.push(apply, m, drop) catch {};
}

/// The text of the editor setting `name`, allocated with `a`; empty when
/// the editor does not exist yet, or the setting is unset or not a string.
fn editorSettingText(a: Allocator, comptime name: []const u8) Allocator.Error![]const u8 {
    const es = editorSettings() orelse return "";
    defer releaseRef(es);
    var n = String.fromLatin1(name);
    defer n.deinit();
    if (!es.hasSetting(n)) return "";
    const v = es.getSetting(n);
    defer v.deinit();
    var s = v.as(String) orelse return "";
    defer s.deinit();
    const text = try props.utf8Alloc(a, &s);
    return std.mem.trim(u8, text, " \t\r\n");
}

/// The last applied outcome, owned (C allocator).
const LastStore = struct {
    info: Last,
    files: []FileDiagnostics,

    fn deinit(l: LastStore) void {
        if (l.info.message) |m| gpa.free(m);
        freeDiagnostics(gpa, l.files);
    }
};

fn copyFileDiagnostics(a: Allocator, from: []const FileDiagnostics) Allocator.Error![]FileDiagnostics {
    const list = try a.alloc(FileDiagnostics, from.len);
    var n: usize = 0;
    errdefer {
        for (list[0..n]) |f| freeFile(a, f);
        a.free(list);
    }
    while (n < from.len) : (n += 1) {
        const f = from[n];
        const rel = try a.dupe(u8, f.rel);
        errdefer a.free(rel);
        const items = try a.alloc(diag_cache.Diagnostic, f.items.len);
        var k: usize = 0;
        errdefer {
            for (items[0..k]) |d| a.free(d.message);
            a.free(items);
        }
        while (k < f.items.len) : (k += 1) {
            const d = f.items[k];
            items[k] = .{ .line = d.line, .column = d.column, .message = try a.dupe(u8, d.message) };
        }
        list[n] = .{ .rel = rel, .items = items };
    }
    return list;
}

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
        if (st.manifest_pin) |*l| l.release();
        if (comptime @import("host_options").test_probe) {
            if (st.store_root.len <= exit_root_buf.len) {
                @memcpy(exit_root_buf[0..st.store_root.len], st.store_root);
                exit_root_len = st.store_root.len;
            }
        }
        st.sdk.deinit(gpa);
        st.arena.deinit();
        state = null;
    }
    var it = diag_files.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    diag_files.deinit(gpa);
    diag_files = .empty;
    if (last_applied) |l| l.deinit();
    last_applied = null;
    good_n = null;
    open_pending = false;
}

/// True while a requested build runs a compiler (for the host tests).
/// `status().building` is the plugin's view.
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
            if (nonInteractiveIn(raw)) |arg| {
                const n = @min(arg.len, S.buf.len);
                @memcpy(S.buf[0..n], arg[0..n]);
                return S.buf[0..n];
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

/// The first non-interactive argument among the NUL-separated arguments
/// `raw` (as `/proc/self/cmdline` holds them), or null. The scan stops at
/// `--` or `++`: Godot hands what follows to the game as user arguments.
fn nonInteractiveIn(raw: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "++")) return null;
        if (nonInteractive(arg)) return arg;
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

/// Adds the project settings: both paths with an empty default, so they
/// show in Project Settings with a file picker, and the Play settings
/// (`registerPlaySettings`).
fn registerSettings() void {
    registerPlaySettings();
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

/// `ziggurat/build/build_on_play` (default true) and
/// `ziggurat/build/play_wait_seconds` (default 60; 0 to 3600 in the
/// inspector, more when typed).
fn registerPlaySettings() void {
    addSetting(setting_build_on_play, Variant.init(bool, true), type_bool, 0, "");
    addSetting(setting_play_wait, Variant.init(i64, default_play_wait_seconds), type_int, hint_range, "0,3600,1,or_greater,suffix:s");
}

/// Registers the project setting `name` with default `value` (consumed)
/// and its property info.
fn addSetting(comptime name: []const u8, value: Variant, type_id: i64, hint: i64, comptime hint_string: []const u8) void {
    defer value.deinit();
    var n = String.fromLatin1(name);
    defer n.deinit();
    if (!ProjectSettings.hasSetting(n)) ProjectSettings.setSetting(n, value);
    ProjectSettings.setInitialValue(n, value);
    ProjectSettings.setAsBasic(n, true);
    var hs = String.fromLatin1(hint_string);
    defer hs.deinit();
    var info = Dictionary.init();
    defer info.deinit();
    putInfo(&info, "name", Variant.init(String, n));
    putInfo(&info, "type", Variant.init(i64, type_id));
    putInfo(&info, "hint", Variant.init(i64, hint));
    putInfo(&info, "hint_string", Variant.init(String, hs));
    ProjectSettings.addPropertyInfo(info);
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

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    var sdk = sdkManifest(gpa, a, &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => {
            log("Ziggurat does not build Zig scripts: {s}", .{msg.items});
            return;
        },
    };
    var sdk_kept = false;
    defer if (!sdk_kept) sdk.deinit(gpa);

    // The project folder as a realpath (the cache folder and `build.lock`
    // are keyed by it).
    var root_msg: std.ArrayList(u8) = .empty;
    defer root_msg.deinit(a);
    const project = projectRoot(a, &root_msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => {
            logError("Ziggurat cannot build Zig scripts: {s}", .{root_msg.items});
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
    const toolchain: ?OsPath = paths.dir(.toolchain, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // No per-user folder: no downloaded Zig to find, and no folder
        // inside the project stands in for it (the project must not name
        // a program that way).
        else => null,
    };

    var diag: [256]u8 = undefined;
    const svc = BuildService.initDiag(gpa, io, .{
        .paths = paths,
        // The configured paths come with each request (`passZigPaths`).
        .locate = .{
            .configured = null,
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
    // The build at open. The project setting wins over the editor setting,
    // so when it is set the build starts now. Otherwise the editor setting
    // is needed, which exists only once the editor does: the editor plugin
    // requests the build when it enters the tree (`editorReady`), and the
    // first frame does if the plugin never does.
    open_pending = true;
    if (projectZigSet()) {
        requestOpen(null);
    } else {
        main_queue.push(requestOpen, null, null) catch requestOpen(null);
    }
}

/// Loads the SDK manifest builds use: the one the project setting
/// `ziggurat/dev/sdk_manifest` names (absolute), else the shipped SDK's
/// (`shipped_sdk_manifest`, globalized) when that file exists. The
/// manifest is allocated with `ga`, scratch text with `a`. On
/// `error.Unusable` `msg` (allocated with `ga`) holds one sentence that
/// starts in lower case and names what is missing or wrong. Main thread.
fn sdkManifest(ga: Allocator, a: Allocator, msg: *std.ArrayList(u8)) error{ OutOfMemory, Unusable }!zbuild.sdk_manifest.Manifest {
    const io = host_io.get();
    msg.clearRetainingCapacity();
    const set = try settingText(a, setting_sdk_manifest);
    if (set.len != 0 and !isAbsolute(set)) {
        try msg.print(ga, "the project setting " ++ setting_sdk_manifest ++ " ({s}) is not usable, because it is not an absolute path.", .{set});
        return error.Unusable;
    }
    const path = if (set.len != 0) set else blk: {
        var res = String.fromLatin1(shipped_sdk_manifest);
        defer res.deinit();
        var abs = ProjectSettings.globalizePath(res);
        defer abs.deinit();
        const shipped = try props.utf8Alloc(a, &abs);
        if (!isAbsolute(shipped)) {
            try msg.print(ga, "the shipped SDK's manifest {s} has no absolute path ({s}), and the project setting " ++ setting_sdk_manifest ++ " is not set.", .{ shipped_sdk_manifest, shipped });
            return error.Unusable;
        }
        std.Io.Dir.cwd().access(io, shipped, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => try msg.appendSlice(ga, "there is no SDK at " ++ shipped_sdk_manifest ++ " (the add-on's sdk folder is missing), and the project setting " ++ setting_sdk_manifest ++ " is not set."),
                else => try msg.print(ga, "the shipped SDK's manifest {s} cannot be read ({t}), and the project setting " ++ setting_sdk_manifest ++ " is not set.", .{ shipped, err }),
            }
            return error.Unusable;
        };
        break :blk shipped;
    };
    var why: std.ArrayList(u8) = .empty;
    defer why.deinit(ga);
    return zbuild.sdk_manifest.load(ga, io, .fromTrusted(path), &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const what = if (set.len != 0) "the project setting " ++ setting_sdk_manifest else "the shipped SDK";
            try msg.print(ga, "{s} is not usable: {s}", .{ what, if (why.items.len != 0) why.items else @errorName(err) });
            return error.Unusable;
        },
    };
}

/// The project folder as a realpath (`res://` globalized, without a
/// trailing separator), allocated with `a`. Editor builds and export
/// builds key the per-user cache folder and `build.lock` by it, so both
/// must use this. On `error.Unusable` `msg` holds one sentence. Main thread.
pub fn projectRoot(a: Allocator, msg: *std.ArrayList(u8)) error{ OutOfMemory, Unusable }![]const u8 {
    var res = String.fromLatin1("res://");
    defer res.deinit();
    var abs = ProjectSettings.globalizePath(res);
    defer abs.deinit();
    const globalized = try props.utf8Alloc(a, &abs);
    const trimmed = if (globalized.len > 1) std.mem.trimEnd(u8, globalized, "/\\") else globalized;
    return std.Io.Dir.cwd().realPathFileAlloc(host_io.get(), trimmed, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            msg.clearRetainingCapacity();
            try msg.print(a, "the project folder {s} cannot be resolved ({t}).", .{ trimmed, err });
            return error.Unusable;
        },
    };
}

/// What an export build needs from the editor's build setup
/// (`exportInputs`); everything is allocated in the caller's allocator.
pub const ExportInputs = struct {
    /// Located as editor builds locate it: the project setting
    /// `ziggurat/zig_path`, the editor setting, the downloaded toolchain,
    /// then `PATH`.
    zig: platform.zig_locator.ZigInstall,
    /// The SDK modules: the running service's, else the manifest the
    /// project setting `ziggurat/dev/sdk_manifest` names, else the shipped
    /// SDK's (`sdkManifest`).
    sdk: []const zbuild.workspace.ModuleDep,
    /// The per-user cache folder (`PathService.dir(.cache)`), as editor
    /// builds use it, so both take turns on the project's `build.lock`.
    cache_dir: OsPath,
};

/// The located Zig, the SDK modules and the per-user cache folder for an
/// export build of the project `project` (`projectRoot`), allocated with
/// `a` (an arena: nothing is freed piecemeal). It works without a build
/// service (an `--export-*` run starts none). On `error.Unusable` `msg`
/// holds one sentence that names what is missing. Main thread.
pub fn exportInputs(a: Allocator, project: []const u8, msg: *std.ArrayList(u8)) error{ OutOfMemory, Unusable }!ExportInputs {
    const io = host_io.get();
    msg.clearRetainingCapacity();
    const sdk: []const zbuild.workspace.ModuleDep = if (state) |*st| st.sdk.modules else blk: {
        const m = try sdkManifest(a, a, msg);
        break :blk m.modules;
    };

    const env = try hostEnv(a);
    const paths: platform.path.PathService = .init(.{ .project = .fromTrusted(project) }, env);
    const cache_dir = paths.dir(.cache, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try msg.print(a, "there is no per-user cache folder for the build ({t}).", .{err});
            return error.Unusable;
        },
    };
    const toolchain: ?OsPath = paths.dir(.toolchain, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    // The Zig path settings as `passZigPaths` reads them.
    const project_zig = try settingText(a, setting_zig_path);
    const editor_zig = try editorSettingText(a, setting_zig_path);
    if (project_zig.len != 0 and !isAbsolute(project_zig)) {
        try msg.print(a, "the project setting " ++ setting_zig_path ++ " ({s}) is not an absolute path.", .{project_zig});
        return error.Unusable;
    }
    if (project_zig.len == 0 and editor_zig.len != 0 and !isAbsolute(editor_zig)) {
        try msg.print(a, "the editor setting " ++ setting_zig_path ++ " ({s}) is not an absolute path.", .{editor_zig});
        return error.Unusable;
    }
    const zig = platform.zig_locator.locate(a, io, .{
        .configured = if (project_zig.len != 0) .fromTrusted(project_zig) else null,
        .configured_editor = if (editor_zig.len != 0 and isAbsolute(editor_zig)) .fromTrusted(editor_zig) else null,
        .toolchain_dir = toolchain,
        .env = env,
    }, msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (msg.items.len == 0) try msg.print(a, "no usable Zig was found ({t}).", .{err});
            return error.Unusable;
        },
    };
    return .{ .zig = zig, .sdk = sdk, .cache_dir = cache_dir };
}

/// Set while the build at open is not requested yet. Main thread.
var open_pending = false;

/// True when the project setting `ziggurat/zig_path` is not empty.
fn projectZigSet() bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const text = settingText(arena_state.allocator(), setting_zig_path) catch return false;
    return text.len != 0;
}

fn requestOpen(_: ?*anyopaque) void {
    if (!open_pending) return;
    open_pending = false;
    requestBuild(.open);
}

/// The editor exists (the editor plugin entered the tree): registers the
/// editor setting and requests the build at open if it still waits for
/// the editor setting. Main thread.
pub fn editorReady() void {
    registerEditorSettings();
    requestOpen(null);
}

/// The per-user folders and `PATH` as the Zig locator and the path service
/// need them, read through Godot (`OS.get_environment`); copies in `a`.
/// Main thread.
pub fn hostEnv(a: Allocator) Allocator.Error!platform.path.HostEnv {
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
    requestBuild(.save);
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
    /// A copy of `Outcome.snapshot`.
    snap: ?abi.Snapshot = null,
    zig_problem: ZigProblem = .none,
    /// How many of `diags`, at the end, are scan problems.
    scan_problems: u32 = 0,
    /// The outcome's staging pin on `gen_n` (`Outcome.pin`), so no sweep
    /// deletes the build before `apply` loads it (spec risk 20).
    /// `applyGood` moves it into the editor's pins (`notePinned`, or
    /// `writeManifest` when the build is not loaded); `free` releases it
    /// when it is still here: the outcome was dropped (queue closed, out of
    /// memory, no service) or the build was rejected.
    pin: ?FileLock = null,

    const Diag = struct { rel: ?[]u8, line: u32, column: u32, message: []u8 };

    /// Takes the outcome's staging pin (the outcome is the service's, on the
    /// build thread); everything else is copied.
    fn copy(o: *Outcome) Allocator.Error!*Msg {
        const m = try gpa.create(Msg);
        m.* = .{
            .trigger = o.trigger,
            .ok = o.ok,
            .path = o.path,
            .ms = o.ms,
            .zig_problem = o.zig_problem,
            .scan_problems = @intCast(@min(o.scan_problems, o.diagnostics.len)),
        };
        errdefer m.free();
        if (o.generation) |g| {
            m.gen_n = g.n;
            m.lib = try gpa.dupe(u8, g.lib.bytes);
        }
        if (o.message) |text| m.message = try gpa.dupe(u8, text);
        if (o.snapshot) |*sn| m.snap = try sn.clone(gpa);
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
        // Last, after everything that can fail: out of memory, the outcome
        // keeps its pin and the service releases it.
        m.pin = o.takePin();
        return m;
    }

    fn freeDiag(d: Diag) void {
        if (d.rel) |r| gpa.free(r);
        gpa.free(d.message);
    }

    fn free(m: *Msg) void {
        if (m.pin) |*l| l.release();
        if (m.lib) |l| gpa.free(l);
        if (m.message) |t| gpa.free(t);
        if (m.snap) |sn| sn.deinit(gpa);
        for (m.diags) |d| freeDiag(d);
        gpa.free(m.diags);
        gpa.destroy(m);
    }
};

/// The service's `on_outcome`: build thread. Copies the outcome for the
/// main thread; out of memory, the outcome is lost (the next build reports
/// again).
fn onOutcome(_: ?*anyopaque, o: *Outcome) void {
    const m = Msg.copy(o) catch return;
    // Counted while the service still counts the build as running, so
    // `status` never shows a gap between the two.
    _ = queued_outcomes.fetchAdd(1, .acq_rel);
    // On a failed push the queue has already run `drop` (see `failNow`).
    main_queue.push(apply, m, drop) catch {};
}

fn drop(ctx: ?*anyopaque) void {
    const m: *Msg = @ptrCast(@alignCast(ctx.?));
    m.free();
    _ = queued_outcomes.fetchSub(1, .acq_rel);
}

/// Diagnostics per project-relative file, for one outcome.
const Files = std.StringArrayHashMapUnmanaged(std.ArrayList(diag_cache.Diagnostic));

/// Handles one outcome on the main thread (see the file comment).
fn apply(ctx: ?*anyopaque) void {
    const m: *Msg = @ptrCast(@alignCast(ctx.?));
    defer _ = queued_outcomes.fetchSub(1, .acq_rel);
    defer m.free();
    if (state == null) return;
    applyMsg(m) catch logError("Ziggurat could not record a build result: out of memory.", .{});
    _ = outcomes_applied.fetchAdd(1, .release);
}

fn applyMsg(m: *Msg) Allocator.Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const st = &state.?;

    if (m.message) |text| {
        if (m.ok) log("ziggurat: {s}", .{text}) else logError("{s}", .{text});
    }

    var files: Files = .empty;
    // Every diagnostic of this outcome, also those outside the project's
    // files (key ""), for `diagnosticsCopy`.
    var all: Files = .empty;
    var file_diags = false;
    for (m.diags) |d| {
        printDiagnostic(d.rel, d.line, d.column, d.message);
        const dg: diag_cache.Diagnostic = .{ .line = d.line, .column = d.column, .message = d.message };
        try addDiagnostic(a, &all, d.rel orelse "", dg);
        const rel = d.rel orelse continue;
        file_diags = true;
        try addDiagnostic(a, &files, rel, dg);
    }

    var use: Use = .not_used;
    if (m.ok and m.lib != null) {
        use = try applyGood(a, st, m, &files, &all);
    } else if (m.ok) {
        // No Zig scripts: nothing was built, and nothing changes.
        use = .no_scripts;
        log("ziggurat: no Zig scripts; nothing to build ({t}, {d} ms)", .{ m.trigger, m.ms });
    } else {
        log("ziggurat: build failed ({t}, {d} ms); the last good build stays in use", .{ m.trigger, m.ms });
    }
    const checked = use != .not_used;

    // Only a build that reached the compiler's verdict replaces what is
    // known about the files: a checked good build (with or without
    // load-check findings), or a failed build with errors in files. A
    // failure without file errors (Zig missing, `build.lock` timeout,
    // compiler death, invalid table, refused load) keeps the earlier
    // diagnostics and failed states; its message was printed above.
    const verdict = checked or (!m.ok and file_diags);
    if (verdict) try recordDiagnostics(&files);
    updateScripts(if (verdict) &files else null);
    try recordLast(m, use, &all);
}

/// What the editor did with a good build (`applyGood`).
const Use = enum {
    /// Loaded (or, without tool scripts, its snapshot installed) and the
    /// manifest written.
    used,
    /// Its load checks found problems; it is never used.
    failed_checks,
    /// Its library was refused or its defaults were stale; the checks
    /// gave no verdict on the files.
    not_used,
    /// The project has no Zig scripts: a good build with no generation.
    /// The build in use (if any) stays; Play proceeds.
    no_scripts,
};

/// Keeps a summary and the diagnostics of `m` for `status` and
/// `diagnosticsCopy`; replaces the previous one.
fn recordLast(m: *const Msg, use: Use, all: *const Files) Allocator.Error!void {
    var findings: u32 = 0;
    if (use == .failed_checks) {
        var total: usize = 0;
        for (all.values()) |list| total += list.items.len;
        findings = @intCast(total -| m.diags.len);
    }
    const compile_errors: u32 = @intCast(m.diags.len - m.scan_problems);
    var views = try gpa.alloc(FileDiagnostics, all.count());
    defer gpa.free(views);
    for (all.keys(), all.values(), 0..) |rel, list, i| views[i] = .{ .rel = rel, .items = list.items };
    const files = try copyFileDiagnostics(gpa, views);
    errdefer freeDiagnostics(gpa, files);
    const message: ?[]const u8 = if (m.message) |t| try gpa.dupe(u8, t) else null;
    if (use == .used) good_n = m.gen_n;
    if (last_applied) |old| old.deinit();
    last_applied = .{
        .info = .{
            .n = if (m.lib != null) m.gen_n else null,
            .ok = use == .used or use == .no_scripts,
            .trigger = m.trigger,
            .path = m.path,
            .ms = m.ms,
            .message = message,
            .error_count = compile_errors + findings,
            .warning_count = m.scan_problems,
            .zig_problem = m.zig_problem,
        },
        .files = files,
    };
}

/// A good build (see the file comment). `all` also gets the load-check
/// findings.
fn applyGood(a: Allocator, st: *State, m: *Msg, files: *Files, all: *Files) Allocator.Error!Use {
    const io = host_io.get();
    const lib = m.lib.?;
    const snap: ?*const abi.Snapshot = if (m.snap) |*sn| sn else null;

    // A build the load checks reject is never loaded.
    if (snap) |sn| {
        const findings = try load_checks.runSnapshot(a, sn);
        if (findings.len != 0) {
            for (findings) |f| try addFinding(a, files, all, sn.scripts[f.script].path, f.message);
            logFailedChecks(m);
            return .failed_checks;
        }
    }

    // The service takes a snapshot whenever it checks tables, which the
    // editor always asks for; without one the build is loaded and checked
    // as before snapshots existed.
    // A build is loaded while the project has a tool script, and also
    // while instances of an earlier tool script are alive (only tool
    // scripts get instances in the editor), so open tool nodes leave the
    // old code with the build that removed the tool flag.
    if (snap) |sn| {
        const tool = hasTool(sn);
        if (tool) st.had_tool = true;
        if (!tool and st.had_tool and !st.tool_loss_logged) {
            st.tool_loss_logged = true;
            log("ziggurat: build {d} has no tool scripts; the editor loads builds only while instances of earlier tool scripts are alive (logged once)", .{m.gen_n});
        }
        if (!tool and registry.count() == 0) {
            installSnapshot(m.gen_n, sn);
            var cache_buf: [max_path_bytes]u8 = undefined;
            if (desc_cache.projectPath(&cache_buf)) |path| {
                desc_cache.writeSnapshot(gpa, io, .fromTrusted(path), m.gen_n, sn) catch |err|
                    logError("Ziggurat could not write the descriptor cache {s} ({s}).", .{ path, @errorName(err) });
            }
            writeManifest(st, m.gen_n, lib, &m.pin, false);
            log("ziggurat: build {d} ready ({t}, {t}, {d} ms); the editor did not load it, because the project has no tool scripts", .{ m.gen_n, m.trigger, m.path, m.ms });
            warnSize(st);
            return .used;
        }
    }

    var diag: [256]u8 = undefined;
    const g = runtime.load(gpa, .fromTrusted(lib), m.gen_n, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // `load` logged it already.
        error.NotMainThread => return .not_used,
        error.Refused => {
            logError("{s}", .{std.mem.sliceTo(&diag, 0)});
            return .not_used;
        },
    };
    const load_pinned = notePinned(st, g.n, &m.pin);
    if (snap == null) {
        const findings = try load_checks.run(a, g);
        if (findings.len != 0) {
            for (findings) |f| try addFinding(a, files, all, props.text(g.scripts()[f.script].path), f.message);
            // Loaded but never handed to the swap engine: new instances
            // keep the previous generation, the game the previous manifest.
            logFailedChecks(m);
            return .failed_checks;
        }
    } else {
        if (try staleDefaults(a, st, m, g, snap.?)) return .not_used;
        installSnapshot(g.n, snap.?);
    }
    // The swap runs at a later frame; until then the snapshot describes
    // the scripts.
    runtime.noteGood(g);
    swap.request(g);
    var cache_buf: [max_path_bytes]u8 = undefined;
    if (desc_cache.projectPath(&cache_buf)) |path| {
        desc_cache.write(gpa, io, .fromTrusted(path), g) catch |err|
            logError("Ziggurat could not write the descriptor cache {s} ({s}).", .{ path, @errorName(err) });
    }
    writeManifest(st, g.n, lib, &m.pin, load_pinned);
    log("ziggurat: build {d} loaded ({t}, {t}, {d} ms)", .{ g.n, m.trigger, m.path, m.ms });
    warnSize(st);
    return .used;
}

/// TEST ONLY (probe `default_mismatch_once`): the next `staleDefaults`
/// check finds a mismatch. Main thread.
pub var test_default_mismatch: bool = false;

/// After a good build with a snapshot is loaded, before anything reads its
/// defaults: every property default from the module's `get_default` must
/// equal the snapshot's, which the host decoded from the defaults image by
/// field offsets (`desc_cache.defaultMismatch`). A difference means the
/// compiler kept old code although the table is right (Zig 0.17's
/// incremental mode did this to `get_default` after a layout change). The
/// build is then not used: it stays loaded, but it is never handed to the
/// swap engine, and no descriptor cache or manifest is written for it. An
/// incremental build is requested again in full; a full build is not (the
/// same sources would give the same result). True when that happened.
fn staleDefaults(a: Allocator, st: *State, m: *const Msg, g: *const runtime.Generation, sn: *const abi.Snapshot) Allocator.Error!bool {
    const found: ?desc_cache.DefaultMismatch = if (test_default_mismatch) blk: {
        test_default_mismatch = false;
        break :blk .{ .script = if (sn.scripts.len > 0) sn.scripts[0].path else "", .property = "(test)" };
    } else try desc_cache.defaultMismatch(a, g.scripts(), sn, desc_cache.GodotDefaults{});
    const bad = found orelse return false;
    if (m.path == .incremental) {
        log("ziggurat: build {d}: the default of '{s}' in {s} differs from the build's table, so the fast rebuild kept old code; rebuilding in full", .{ g.n, bad.property, bad.script });
        st.svc.requestFull(m.trigger);
    } else {
        logError("Ziggurat build {d}: the default of '{s}' in {s} differs from the build's table; the last good build stays in use.", .{ g.n, bad.property, bad.script });
    }
    return true;
}

fn addFinding(a: Allocator, files: *Files, all: *Files, rel: []const u8, message: []const u8) Allocator.Error!void {
    printDiagnostic(rel, 0, 0, message);
    try addDiagnostic(a, files, rel, .{ .line = 0, .column = 0, .message = message });
    try addDiagnostic(a, all, rel, .{ .line = 0, .column = 0, .message = message });
}

fn logFailedChecks(m: *const Msg) void {
    log("ziggurat: build {d} failed the load checks ({t}, {d} ms); the last good build stays in use", .{ m.gen_n, m.trigger, m.ms });
}

/// True when a script of `sn` is a tool script.
fn hasTool(sn: *const abi.Snapshot) bool {
    for (sn.scripts) |s| {
        if (s.flags & abi.script_flag_tool != 0) return true;
    }
    return false;
}

fn installSnapshot(n: u32, sn: *const abi.Snapshot) void {
    script.installSnapshot(n, sn) catch |err|
        logError("Ziggurat could not use the descriptors of build {d} ({s}); the scripts keep the earlier ones.", .{ n, @errorName(err) });
}

/// Pins generation `n` (taking `staged`, the outcome's staging pin, when it
/// is still there), writes the manifest naming it, then releases the pin of
/// the generation the previous manifest named (`State.manifest_pin`). With
/// `load_pinned` the editor loaded `n` and holds its pin until SCENE exit
/// (`notePinned`), so no second pin is taken: `store.pin` would wait for
/// `store.lock`, which a concurrent staging copy holds for seconds, and
/// Play would return late (spec section 9). A pin that fails is logged; the
/// manifest is still written. Then running games are told to reload
/// (`debugger_plugin.sendReload`).
fn writeManifest(st: *State, n: u32, lib: []const u8, staged: *?FileLock, load_pinned: bool) void {
    const taken = staged.*;
    staged.* = null;
    var lock: ?FileLock = taken orelse if (load_pinned) null else (st.store.pin(n) catch |err| blk: {
        logError("Ziggurat could not pin generation {d} in {s} ({s}); a later sweep may delete the build the manifest names.", .{ n, st.store_root, @errorName(err) });
        break :blk null;
    });
    manifest.write(gpa, host_io.get(), .fromTrusted(st.store_root), n, std.fs.path.basename(lib)) catch |err| {
        logError("Ziggurat could not write the generation manifest in {s} ({s}).", .{ st.store_root, @errorName(err) });
        if (lock) |*l| l.release();
        return;
    };
    if (st.manifest_pin) |*old| old.release();
    st.manifest_pin = lock;
    // Running games load it now (game.zig, the `ziggurat` capture).
    debugger_plugin.sendReload(n);
}

/// Warns once per session when what the editor holds of its builds exceeds
/// `size_warning_bytes` (spec section 6): the loaded generations' bytes on
/// disk (none is ever unloaded, and on Linux a mapped file frees nothing
/// until the editor exits) plus the descriptor snapshots: the parsed ones
/// the scripts keep (`script.snapshotsHeld`) and the one the build service
/// keeps (`Memory`; all exact). `<n>` counts the builds held either way.
fn warnSize(st: *State) void {
    if (st.size_warned) return;
    const mem = memory();
    const bytes = mem.total();
    if (bytes <= size_warning_bytes) return;
    st.size_warned = true;
    var size_buf: [32]u8 = undefined;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "Ziggurat has loaded {d} builds ({s}) in this editor session; restart the editor to free them.", .{ st.loaded_count + mem.unloaded_builds, sizeText(&size_buf, bytes) }, 0) catch return;
    godot.raw.printWarning(msg.ptr, "Zig build", "src/host/editor_build.zig", @src().line, 1);
}

/// What the editor holds of its builds (spec section 6). Exact figures:
/// `loaded_bytes` sums the loaded libraries' allocated bytes on disk
/// (`runtime.loadedBytes`); `snapshot_bytes` is what the parsed snapshot
/// descriptors hold (`script.snapshotsHeld`), and `service_snapshot_bytes`
/// the table snapshot the build service keeps to compare the next build
/// with, both counted when allocated.
pub const Memory = struct {
    loaded_builds: u32,
    loaded_bytes: u64,
    snapshot_bytes: u64,
    service_snapshot_bytes: u64,
    /// Builds whose snapshot descriptors are kept but which are not loaded.
    unloaded_builds: u32,

    /// What the size warning compares with `size_warning_bytes`.
    pub fn total(m: Memory) u64 {
        return m.loaded_bytes +| m.snapshot_bytes +| m.service_snapshot_bytes;
    }

    /// The descriptor snapshots' bytes: the editor's and the service's.
    pub fn descriptorBytes(m: Memory) u64 {
        return m.snapshot_bytes +| m.service_snapshot_bytes;
    }
};

/// The editor's `Memory` now. Main thread.
pub fn memory() Memory {
    const held = script.snapshotsHeld();
    return .{
        .loaded_builds = runtime.loadedCount(),
        .loaded_bytes = runtime.loadedBytes(),
        .snapshot_bytes = held.bytes,
        .service_snapshot_bytes = if (state) |st| st.svc.keptSnapshotBytes() else 0,
        .unloaded_builds = held.unloaded_builds,
    };
}

/// The Zig panel's memory line,
/// `Loaded builds: <n> (<size>); descriptor snapshots: <size>`, in `buf`
/// (128 bytes are enough); empty without a build service. Main thread.
pub fn memoryText(buf: []u8) []const u8 {
    if (state == null) return "";
    const m = memory();
    var loaded_buf: [32]u8 = undefined;
    var snap_buf: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "Loaded builds: {d} ({s}); descriptor snapshots: {s}", .{
        m.loaded_builds, sizeText(&loaded_buf, m.loaded_bytes), sizeText(&snap_buf, m.descriptorBytes()),
    }) catch "";
}

/// TEST ONLY (probe `editor_build_set_store_caps`): waits until the
/// service is idle, then gives its generation store `caps`. Main thread.
pub fn setStoreCapsForTest(caps: platform.generation_store.Caps) bool {
    comptime std.debug.assert(@import("host_options").test_probe);
    const st = &(state orelse return false);
    st.svc.waitIdle(60_000) catch return false;
    // The build thread waits for a request; the next `request` takes the
    // service's lock, which orders this write before its next sweep.
    st.svc.store.caps = caps;
    return true;
}

/// TEST ONLY, probe builds: the store folder of the stopped service, kept
/// by `stop` for `reportExitLocks`.
var exit_root_buf: [max_path_bytes]u8 = undefined;
var exit_root_len: usize = 0;

/// TEST ONLY, probe builds, at SCENE exit after the main-thread queue
/// closed: logs how many generations of the project's store are still
/// pinned by anyone (`GenerationStore.heldPins`). Every pin of this editor
/// is released by then: loaded builds and the manifest's at `stop`, a
/// queued outcome's staging pin by the queue's drop hook.
pub fn reportExitLocks() void {
    if (exit_root_len == 0) return;
    const root: OsPath = .fromTrusted(exit_root_buf[0..exit_root_len]);
    exit_root_len = 0;
    var store = platform.generation_store.GenerationStore.init(gpa, host_io.get(), root, builtin_os, zbuild.service.lib_stem, .{});
    const held = store.heldPins() catch |err| return log("ziggurat: generation locks after exit unknown ({s})", .{@errorName(err)});
    log("ziggurat: generation locks held after exit: {d}", .{held});
}

const builtin_os = @import("builtin").os.tag;

/// `bytes` with one decimal in the largest binary unit it reaches
/// ("2.1 GiB", "340.0 MiB", "12 bytes").
fn sizeText(buf: []u8, bytes: u64) []const u8 {
    const units = [_]struct { name: []const u8, size: u64 }{
        .{ .name = "GiB", .size = 1 << 30 },
        .{ .name = "MiB", .size = 1 << 20 },
        .{ .name = "KiB", .size = 1 << 10 },
    };
    for (units) |u| {
        if (bytes < u.size) continue;
        const tenths = @as(u128, bytes) * 10 / u.size;
        return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ tenths / 10, tenths % 10, u.name }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "";
}

/// Pins generation `n` until SCENE exit and counts it (spec section 6: the
/// host counts the generations it loaded; none is ever unloaded). The pin
/// is `staged`, the outcome's staging pin, when it is still there. True
/// when the generation is pinned.
fn notePinned(st: *State, n: u32, staged: *?FileLock) bool {
    st.loaded_count += 1;
    log("ziggurat: {d} generations loaded in this editor session", .{st.loaded_count});
    const taken = staged.*;
    staged.* = null;
    const lock = taken orelse (st.store.pin(n) catch |err| {
        logError("Ziggurat could not pin generation {d} in {s} ({s}); a later sweep may delete its files.", .{ n, st.store_root, @errorName(err) });
        return false;
    });
    st.pins.append(gpa, lock) catch {
        var l = lock;
        l.release();
        return false;
    };
    return true;
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

test "size text" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12 bytes", sizeText(&buf, 12));
    try std.testing.expectEqualStrings("1.5 KiB", sizeText(&buf, 1536));
    try std.testing.expectEqualStrings("2.0 GiB", sizeText(&buf, 2 << 30));
    try std.testing.expectEqualStrings("2.1 GiB", sizeText(&buf, (2 << 30) + (150 << 20)));
}

test "nonInteractiveIn stops at the user arguments" {
    try std.testing.expectEqualStrings("--import", nonInteractiveIn("godot\x00--editor\x00--import\x00").?);
    try std.testing.expectEqualStrings("--export-release", nonInteractiveIn("godot\x00--export-release\x00x").?);
    try std.testing.expect(nonInteractiveIn("godot\x00--editor\x00--quit-after\x005") == null);
    // After `--` or `++` Godot passes the arguments to the game, not the
    // editor, so they do not make the editor non-interactive.
    try std.testing.expect(nonInteractiveIn("godot\x00--editor\x00--\x00--quit") == null);
    try std.testing.expect(nonInteractiveIn("godot\x00-e\x00++\x00-q\x00--import") == null);
}
