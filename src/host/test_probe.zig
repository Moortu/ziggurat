//! `ZigguratTestProbe`: a class the host registers only when it is built
//! with `-Dtest_probe` (`host_options.test_probe`), for the host tests. It
//! lets a GDScript check drive the runtime directly (load a staged module,
//! read the name maps) before the editor and game paths that call it exist.
//! The product library has no such class: it would let any script load a
//! library.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");
const props = @import("props.zig");
const desc_cache = @import("desc_cache.zig");
const default_value = @import("default_value.zig");
const host_io = @import("host_io.zig");
const script_mod = @import("script.zig");
const instance = @import("instance.zig");
const language = @import("language.zig");
const game = @import("game.zig");
const diag_cache = @import("diag_cache.zig");
const main_queue = @import("main_queue.zig");
const resource = @import("resource.zig");
const editor_build = @import("editor_build.zig");
const gate = @import("gate.zig");
const registry = @import("registry.zig");
const swap = @import("swap.zig");
const editor_plugin = @import("editor_plugin.zig");
const editor_panel = @import("editor_panel.zig");
const debugger_plugin = @import("debugger_plugin.zig");
const host_callable = @import("host_callable.zig");
const Callable = godot.builtin.Callable;
const PackedStringArray = godot.builtin.PackedStringArray;

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const RefCounted = godot.class.RefCounted;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const ZigScript = script_mod.ZigScript;
const Object = godot.class.Object;
const Variant = godot.builtin.Variant;

pub const ZigguratTestProbe = struct {
    base: *RefCounted,

    pub fn create(allocator: *Allocator) !*ZigguratTestProbe {
        const self = try allocator.create(ZigguratTestProbe);
        self.* = .{ .base = RefCounted.init() };
        self.base.setInstance(ZigguratTestProbe, self);
        return self;
    }

    pub fn destroy(self: *ZigguratTestProbe, allocator: *Allocator) void {
        cacheClose();
        allocator.destroy(self);
    }

    /// Loads the library at `path` as generation `gen` and publishes it: ""
    /// on success, the refusal sentence otherwise.
    pub fn loadModule(_: *ZigguratTestProbe, path: String, gen: i64) String {
        var buf: [4096]u8 = undefined;
        const p = path.toUtf8Buf(&buf);
        var diag: [256]u8 = undefined;
        const n = std.math.cast(u32, gen) orelse return .fromLatin1("generation out of range");
        const g = runtime.load(std.heap.c_allocator, .fromTrusted(p), n, &diag) catch |err| switch (err) {
            error.Refused, error.NotMainThread => return String.fromUtf8(std.mem.sliceTo(&diag, 0)) catch .fromLatin1("refused"),
            error.OutOfMemory => return .fromLatin1("out of memory"),
        };
        runtime.publish(g);
        return .fromLatin1("");
    }

    /// Calls `HostApi.log` as a module would, from the calling thread.
    pub fn apiLog(_: *ZigguratTestProbe, level: i64, line: String) void {
        var buf: [1024]u8 = undefined;
        const t = line.toUtf8Buf(&buf);
        const lv = std.math.cast(u32, level) orelse return;
        runtime.hostApi().log(lv, t.ptr, t.len);
    }

    /// Calls `HostApi.request_swap` as a module would.
    pub fn apiRequestSwap(_: *ZigguratTestProbe) void {
        runtime.hostApi().request_swap();
    }

    /// The current generation's number, or 0.
    pub fn currentGeneration(_: *ZigguratTestProbe) i64 {
        const g = runtime.current() orelse return 0;
        return g.n;
    }

    /// Times `ziggurat_init` ran for generation `gen` (0 when not loaded).
    pub fn initCalls(_: *ZigguratTestProbe, gen: i64) i64 {
        const n = std.math.cast(u32, gen) orelse return 0;
        const g = runtime.find(n) orelse return 0;
        return g.init_calls;
    }

    /// True when generation `gen` was ever current, even for a moment.
    pub fn wasEverCurrent(_: *ZigguratTestProbe, gen: i64) bool {
        const n = std.math.cast(u32, gen) orelse return false;
        return runtime.wasEverCurrent(n);
    }

    /// Script index of `rel` in the current generation, or -1.
    pub fn findScript(_: *ZigguratTestProbe, rel: String) i64 {
        const g = runtime.current() orelse return -1;
        var buf: [1024]u8 = undefined;
        return runtime.findScript(g, rel.toUtf8Buf(&buf)) orelse -1;
    }

    pub fn methodIndex(_: *ZigguratTestProbe, script: i64, name: StringName) i64 {
        const s = scriptNames(script) orelse return -1;
        return s.method(name) orelse -1;
    }

    pub fn propertyIndex(_: *ZigguratTestProbe, script: i64, name: StringName) i64 {
        const s = scriptNames(script) orelse return -1;
        return s.property(name) orelse -1;
    }

    pub fn methodCount(_: *ZigguratTestProbe, script: i64) i64 {
        const d = scriptDesc(script) orelse return 0;
        return d.method_count;
    }

    pub fn methodName(_: *ZigguratTestProbe, script: i64, index: i64) String {
        const d = scriptDesc(script) orelse return .fromLatin1("");
        const i = std.math.cast(u32, index) orelse return .fromLatin1("");
        if (i >= d.method_count) return .fromLatin1("");
        return text(d.methods[i].name);
    }

    pub fn propertyCount(_: *ZigguratTestProbe, script: i64) i64 {
        const d = scriptDesc(script) orelse return 0;
        return d.property_count;
    }

    pub fn propertyName(_: *ZigguratTestProbe, script: i64, index: i64) String {
        const d = scriptDesc(script) orelse return .fromLatin1("");
        const i = std.math.cast(u32, index) orelse return .fromLatin1("");
        if (i >= d.property_count) return .fromLatin1("");
        return text(d.properties[i].name);
    }

    /// The Godot property, method and signal lists of the current
    /// generation's script `script` (`props`).
    pub fn propertyList(_: *ZigguratTestProbe, script: i64) Array {
        const d = scriptDesc(script) orelse return Array.init();
        return props.propertyList(d);
    }

    pub fn methodList(_: *ZigguratTestProbe, script: i64) Array {
        const d = scriptDesc(script) orelse return Array.init();
        return props.methodList(d);
    }

    pub fn signalList(_: *ZigguratTestProbe, script: i64) Array {
        const d = scriptDesc(script) orelse return Array.init();
        return props.signalList(d);
    }

    /// `var_to_str` of the default of property `index`, or "<none>".
    pub fn defaultText(_: *ZigguratTestProbe, script: i64, index: i64) String {
        const d = scriptDesc(script) orelse return .fromLatin1("<none>");
        const i = std.math.cast(u32, index) orelse return .fromLatin1("<none>");
        const v = props.defaultValue(d, i) orelse return .fromLatin1("<none>");
        defer v.deinit();
        return godot.general.varToStr(v);
    }

    /// Writes the descriptor cache of the current generation to `path`:
    /// "" on success, the error name otherwise.
    pub fn cacheWrite(_: *ZigguratTestProbe, path: String) String {
        const g = runtime.current() orelse return .fromLatin1("no module loaded");
        var buf: [4096]u8 = undefined;
        const p = path.toUtf8Buf(&buf);
        desc_cache.write(std.heap.c_allocator, host_io.get(), .fromTrusted(p), g) catch |err| return String.fromLatin1(@errorName(err));
        return .fromLatin1("");
    }

    /// Writes the descriptor cache of the current generation to `path` from
    /// a snapshot of its table (no module call): "" on success, the error
    /// name otherwise.
    pub fn cacheWriteSnapshot(_: *ZigguratTestProbe, path: String) String {
        const g = runtime.current() orelse return .fromLatin1("no module loaded");
        var buf: [4096]u8 = undefined;
        const p = path.toUtf8Buf(&buf);
        const a = std.heap.c_allocator;
        const snap = abi.snapshot.take(a, g.table) catch |err| return String.fromLatin1(@errorName(err));
        defer snap.deinit(a);
        desc_cache.writeSnapshot(a, host_io.get(), .fromTrusted(p), g.n, &snap) catch |err| return String.fromLatin1(@errorName(err));
        return .fromLatin1("");
    }

    /// Reads the descriptor cache at `path`: the number of scripts in it,
    /// or -1 when it is missing, -2 when it was rejected (and logged).
    pub fn cacheRead(_: *ZigguratTestProbe, path: String) i64 {
        cacheClose();
        var buf: [4096]u8 = undefined;
        const p = path.toUtf8Buf(&buf);
        const c = desc_cache.read(std.heap.c_allocator, host_io.get(), .fromTrusted(p)) catch |err| return switch (err) {
            error.FileNotFound => -1,
            else => -2,
        };
        cache = c;
        return @intCast(c.scripts().len);
    }

    /// How many rejected cache files have been logged.
    pub fn cacheRejections(_: *ZigguratTestProbe) i64 {
        return desc_cache.rejections_logged.load(.acquire);
    }

    pub fn cachedPropertyList(_: *ZigguratTestProbe, rel: String) Array {
        const s = cachedScript(rel) orelse return Array.init();
        return s.propertyList();
    }

    pub fn cachedMethodList(_: *ZigguratTestProbe, rel: String) Array {
        const s = cachedScript(rel) orelse return Array.init();
        return s.methodList();
    }

    pub fn cachedSignalList(_: *ZigguratTestProbe, rel: String) Array {
        const s = cachedScript(rel) orelse return Array.init();
        return s.signalList();
    }

    /// As `default_text`, from the cache.
    pub fn cachedDefaultText(_: *ZigguratTestProbe, rel: String, index: i64) String {
        const s = cachedScript(rel) orelse return .fromLatin1("<none>");
        const i = std.math.cast(u32, index) orelse return .fromLatin1("<none>");
        const v = s.defaultValue(i) orelse return .fromLatin1("<none>");
        defer v.deinit();
        return godot.general.varToStr(v);
    }

    /// The layout hash the cache holds for `rel`, as decimal text.
    pub fn cachedLayoutHash(_: *ZigguratTestProbe, rel: String) String {
        const s = cachedScript(rel) orelse return .fromLatin1("");
        var buf: [32]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{s.layoutHash()}) catch return .fromLatin1("");
        return .fromLatin1(t);
    }

    /// The same, for the loaded script.
    pub fn layoutHash(_: *ZigguratTestProbe, script: i64) String {
        const d = scriptDesc(script) orelse return .fromLatin1("");
        var buf: [32]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{abi.layoutHash(d)}) catch return .fromLatin1("");
        return .fromLatin1(t);
    }

    /// A default of declared type `type_id` through the cache's typed JSON
    /// and back. `value` is an array holding the one value (gdzig methods
    /// cannot take a bare Variant); the result is an array holding the
    /// restored value, or empty when it has no stored form.
    pub fn roundtripDefault(_: *ZigguratTestProbe, type_id: i64, value: Array) Array {
        var out = Array.init();
        const t = std.math.cast(u32, type_id) orelse return out;
        if (value.size() != 1) return out;
        const v = value.get(0);
        defer v.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const d = default_value.fromVariant(a, t, v) catch return out;
        const json = std.json.Stringify.valueAlloc(a, d, .{}) catch return out;
        const back = std.json.parseFromSlice(default_value.Default, a, json, .{}) catch return out;
        const r = default_value.toVariant(t, back.value) orelse return out;
        defer r.deinit();
        out.pushBack(r);
        return out;
    }

    /// The JSON text `roundtrip_default` stores for the value in `value`
    /// (an array of one), or "".
    pub fn storedDefault(_: *ZigguratTestProbe, type_id: i64, value: Array) String {
        const t = std.math.cast(u32, type_id) orelse return .fromLatin1("");
        if (value.size() != 1) return .fromLatin1("");
        const v = value.get(0);
        defer v.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const d = default_value.fromVariant(a, t, v) catch return .fromLatin1("");
        if (d == .absent) return .fromLatin1("");
        const json = std.json.Stringify.valueAlloc(a, d, .{}) catch return .fromLatin1("");
        return String.fromUtf8(json) catch .fromLatin1("");
    }

    /// How many "dropped defaults" lines have been logged.
    pub fn cacheDrops(_: *ZigguratTestProbe) i64 {
        return desc_cache.drops_logged.load(.acquire);
    }

    pub fn cachedGeneration(_: *ZigguratTestProbe) i64 {
        const c = cache orelse return -1;
        return c.generation();
    }

    // ZigScript virtuals that `Script` does not expose to GDScript.

    pub fn scriptIsValid(_: *ZigguratTestProbe, s: ?*ZigScript) bool {
        return (s orelse return false)._isValid();
    }

    pub fn scriptFallbackEnabled(_: *ZigguratTestProbe, s: ?*ZigScript) bool {
        return (s orelse return false)._isPlaceholderFallbackEnabled();
    }

    pub fn scriptMembers(_: *ZigguratTestProbe, s: ?*ZigScript) Array {
        return (s orelse return Array.init())._getMembers();
    }

    pub fn scriptMemberLine(_: *ZigguratTestProbe, s: ?*ZigScript, name: StringName) i64 {
        return (s orelse return -1)._getMemberLine(name);
    }

    pub fn scriptMethodInfo(_: *ZigguratTestProbe, s: ?*ZigScript, name: StringName) Dictionary {
        return (s orelse return Dictionary.init())._getMethodInfo(name);
    }

    pub fn scriptHasDefault(_: *ZigguratTestProbe, s: ?*ZigScript, name: StringName) bool {
        return (s orelse return false)._hasPropertyDefaultValue(name);
    }

    /// `_get_script_method_argument_count` as an int; -1 when it is nil.
    pub fn scriptMethodArgCount(_: *ZigguratTestProbe, s: ?*ZigScript, name: StringName) i64 {
        const v = (s orelse return -1)._getScriptMethodArgumentCount(name);
        defer v.deinit();
        if (v.tag != .int) return -1;
        return v.as(i64) orelse -1;
    }

    /// Calls `_update_exports` `times` times; returns how many refreshes the
    /// script has made in all.
    pub fn scriptUpdateExports(_: *ZigguratTestProbe, s: ?*ZigScript, times: i64) i64 {
        const zs = s orelse return -1;
        var i: i64 = 0;
        while (i < times) : (i += 1) zs._updateExports();
        return zs.placeholders.refreshCount();
    }

    /// The script's live placeholder instances.
    pub fn scriptPlaceholderCount(_: *ZigguratTestProbe, s: ?*ZigScript) i64 {
        return @intCast((s orelse return -1).placeholders.count());
    }

    pub fn scriptSetBuildFailed(_: *ZigguratTestProbe, s: ?*ZigScript, failed: bool) void {
        (s orelse return).setBuildFailed(failed);
    }

    /// Script instance records alive now.
    pub fn liveInstances(_: *ZigguratTestProbe) i64 {
        return instance.live.load(.monotonic);
    }

    /// Bytes held through `HostApi.alloc` with tag `gen`; -1 for a
    /// generation that is not loaded.
    pub fn liveBytes(_: *ZigguratTestProbe, gen: i64) i64 {
        const n = std.math.cast(u32, gen) orelse return -1;
        const b = runtime.liveBytes(n) orelse return -1;
        return std.math.cast(i64, b) orelse -1;
    }

    /// Calls `method` on `obj` with no arguments through Godot's Variant
    /// call and returns the call error code (0 is OK). A RefCounted `obj`
    /// keeps its reference count (`callErrorOf`); null gives Godot's error
    /// for a call on nil.
    pub fn callError(_: *ZigguratTestProbe, obj: ?*Object, method: StringName) i64 {
        if (obj) |o| return callErrorOf(o, &method);
        var self_v: Variant = .nil;
        var ret: Variant = .nil;
        var err: godot.c.GDExtensionCallError = .{ .@"error" = 0, .argument = 0, .expected = 0 };
        godot.raw.variantCall(@ptrCast(&self_v), @ptrCast(&method), null, 0, @ptrCast(&ret), &err);
        ret.deinit();
        return err.@"error";
    }

    /// What the script instance of `obj` reports from `get_property_state`.
    pub fn propertyState(_: *ZigguratTestProbe, obj: ?*Object) Dictionary {
        return instance.propertyStateOf(obj orelse return Dictionary.init());
    }

    // ZigLanguage virtuals that `ScriptLanguage` does not expose to GDScript.

    /// `_validate` of the registered language for `path`.
    pub fn languageValidate(_: *ZigguratTestProbe, path: String) Dictionary {
        const lang = language.registered orelse return Dictionary.init();
        var empty = String.init();
        defer empty.deinit();
        return lang._validate(empty, path, false, true, false, false);
    }

    /// `_get_global_class_name` of the registered language for `path`.
    pub fn languageGlobalClass(_: *ZigguratTestProbe, path: String) Dictionary {
        const lang = language.registered orelse return Dictionary.init();
        return lang._getGlobalClassName(path);
    }

    pub fn languageCompleteCode(_: *ZigguratTestProbe) Dictionary {
        const lang = language.registered orelse return Dictionary.init();
        var empty = String.init();
        defer empty.deinit();
        return lang._completeCode(empty, empty, null);
    }

    pub fn languageLookupCode(_: *ZigguratTestProbe) Dictionary {
        const lang = language.registered orelse return Dictionary.init();
        var empty = String.init();
        defer empty.deinit();
        return lang._lookupCode(empty, empty, empty, null);
    }

    /// Records the diagnostics of `rel` as a build would: one error at
    /// `line`/`column`, or a clean build when `line` is negative.
    pub fn setDiagnostics(_: *ZigguratTestProbe, rel: String, line: i64, column: i64, message: String) bool {
        var rel_buf: [1024]u8 = undefined;
        var msg_buf: [1024]u8 = undefined;
        const r = props.stringText(&rel, &rel_buf) orelse return false;
        if (line < 0) {
            diag_cache.set(r, &.{}) catch return false;
            return true;
        }
        const m = props.stringText(&message, &msg_buf) orelse return false;
        const d: diag_cache.Diagnostic = .{
            .line = std.math.cast(u32, line) orelse return false,
            .column = std.math.cast(u32, column) orelse return false,
            .message = m,
        };
        diag_cache.set(r, &.{d}) catch return false;
        return true;
    }

    pub fn hasGlobalConstant(_: *ZigguratTestProbe, name: String) bool {
        const lang = language.registered orelse return false;
        var buf: [1024]u8 = undefined;
        return lang.hasGlobal(props.stringText(&name, &buf) orelse return false);
    }

    /// Pushes `n` callbacks onto the main-thread queue; returns how many
    /// were queued. Each one adds 1 to `queue_runs`.
    pub fn queuePush(_: *ZigguratTestProbe, n: i64) i64 {
        var pushed: i64 = 0;
        while (pushed < n) : (pushed += 1) main_queue.push(countRun, null, null) catch break;
        return pushed;
    }

    /// Callbacks waiting in the main queue.
    pub fn queuePending(_: *ZigguratTestProbe) i64 {
        return @intCast(main_queue.pending());
    }

    /// The language's `_frame`, as Godot calls it.
    pub fn languageFrame(_: *ZigguratTestProbe) void {
        const lang = language.registered orelse return;
        lang._frame();
    }

    /// Nested `_frame` calls so far (`language.nestedFrames`): calls Godot
    /// made from a nested `Main::iteration()` while module code was on the
    /// main thread's stack, or from inside another `_frame`.
    pub fn languageNestedFrames(_: *ZigguratTestProbe) i64 {
        return @intCast(language.nestedFrames());
    }

    /// Enters the gate as a script call does, calls `callable` with no
    /// arguments and leaves: while the callable runs, this thread holds the
    /// gate like a script method on its stack, so a swap waits
    /// (`deferred_lock`). Any thread.
    pub fn gateHold(_: *ZigguratTestProbe, callable: Callable) void {
        gate.enter();
        defer gate.leave();
        var c = callable;
        var args = Array.init();
        defer args.deinit();
        const r = c.callv(args);
        r.deinit();
    }

    /// The number of entries `_debug_get_current_stack_info` returns. Any
    /// thread.
    pub fn languageStackInfo(_: *ZigguratTestProbe) i64 {
        const lang = language.registered orelse return -1;
        var stack = lang._debugGetCurrentStackInfo();
        defer stack.deinit();
        return @intCast(stack.size());
    }

    /// Runs the language's `_frame` (outside any script call) with a queued
    /// callback that requests a swap to generation 2, calls `_frame` again
    /// and records what that nested call did. Returns [queued callbacks the
    /// nested call ran, swap outcome after it, swaps it did]; a nested call
    /// runs nothing, so [0, 1 (deferred_depth), 0].
    pub fn queueNestedFrameCheck(_: *ZigguratTestProbe) Array {
        var out = Array.init();
        const lang = language.registered orelse return out;
        nested_result = .{ -1, -1, -1 };
        main_queue.push(nestedFrameCallback, null, null) catch return out;
        lang._frame();
        for (nested_result) |v| out.pushBack(Variant.init(i64, v));
        return out;
    }

    pub fn queueRuns(_: *ZigguratTestProbe) i64 {
        return queue_runs.load(.monotonic);
    }

    /// Calls the language's `reload_scripts` hook as Godot does when the
    /// editor discards a script's edits.
    pub fn languageReloadScripts(_: *ZigguratTestProbe, scripts: Array) void {
        const lang = language.registered orelse return;
        lang._reloadScripts(scripts, true);
    }

    /// The editor's next defaults check (`editor_build.staleDefaults`)
    /// finds a mismatch, as a stale incremental build would give.
    pub fn defaultMismatchOnce(_: *ZigguratTestProbe) void {
        editor_build.test_default_mismatch = true;
    }

    /// Hands the game the editor's `ziggurat:reload` message for
    /// generation `n` (`game.onReloadMessage`).
    pub fn gameReloadMessage(_: *ZigguratTestProbe, n: i64) void {
        game.onReloadMessage(std.math.cast(u32, n) orelse return);
    }

    /// Runs the game's `ziggurat` capture as the debugger does with
    /// `ziggurat:<message>` and `data`; returns what the capture returns.
    pub fn gameCapture(_: *ZigguratTestProbe, message: String, data: Array) bool {
        return game.handleCapture(message, data);
    }

    /// True while the game's `ziggurat` debugger capture is registered.
    pub fn gameCaptureRegistered(_: *ZigguratTestProbe) bool {
        return game.captureRegistered();
    }

    /// The generation of the editor's last `sendReload` call (-1: none).
    pub fn debuggerReloadLast(_: *ZigguratTestProbe) i64 {
        return debugger_plugin.test_last_n;
    }

    /// The debugger plugin's sessions (EditorDebuggerSession objects).
    pub fn debuggerSessions(_: *ZigguratTestProbe) Array {
        return debugger_plugin.testSessions();
    }

    /// Calls of the plugin's `session_started` and the generation it sent
    /// last (-1: none): keys `calls`, `resent`.
    pub fn debuggerStarted(_: *ZigguratTestProbe) Dictionary {
        var d: Dictionary = .init();
        dictSet(&d, "calls", .init(i64, debugger_plugin.test_started));
        dictSet(&d, "resent", .init(i64, debugger_plugin.test_resent_n));
        return d;
    }

    /// The `ziggurat:reload` messages the editor sent to active sessions.
    pub fn debuggerReloadSends(_: *ZigguratTestProbe) i64 {
        return debugger_plugin.test_sends;
    }

    /// Calls the language's `reload_tool_script` hook.
    pub fn languageReloadToolScript(_: *ZigguratTestProbe, s: ?*ZigScript) void {
        const lang = language.registered orelse return;
        lang._reloadToolScript(if (s) |z| .upcast(z.base) else null, true);
    }

    /// Sets `resource.on_saved` to a recorder of the paths it is called with.
    pub fn savedHookInstall(_: *ZigguratTestProbe) void {
        resource.on_saved.store(&recordSaved, .release);
    }

    /// Forgets the recorded paths.
    pub fn savedHookClear(_: *ZigguratTestProbe) void {
        saved_mu.lockUncancelable(host_io.get());
        defer saved_mu.unlock(host_io.get());
        for (saved_paths.items) |p| std.heap.c_allocator.free(p);
        saved_paths.clearRetainingCapacity();
    }

    /// The paths `resource.on_saved` was called with, in order.
    pub fn savedHookPaths(_: *ZigguratTestProbe) PackedStringArray {
        var list: PackedStringArray = .init();
        saved_mu.lockUncancelable(host_io.get());
        defer saved_mu.unlock(host_io.get());
        for (saved_paths.items) |p| {
            var s = String.fromUtf8(p) catch continue;
            defer s.deinit();
            _ = list.pushBack(s);
        }
        return list;
    }

    /// Build outcomes the editor handled so far (`editor_build.apply`).
    pub fn editorBuildOutcomes(_: *ZigguratTestProbe) i64 {
        return editor_build.outcomes_applied.load(.acquire);
    }

    /// `editor_build.checkCounts` as a Dictionary: `checks` (finished
    /// `requestIfChanged` checks) and `skipped` (those that found no change).
    pub fn editorBuildChecks(_: *ZigguratTestProbe) Dictionary {
        var d: Dictionary = .init();
        const c = editor_build.checkCounts();
        dictSet(&d, "checks", .init(i64, c.checks));
        dictSet(&d, "skipped", .init(i64, c.skipped));
        return d;
    }

    /// True while the editor's build service runs a requested build.
    pub fn editorBuildBusy(_: *ZigguratTestProbe) bool {
        return editor_build.busy();
    }

    /// `editor_build.requestBuild` with the trigger named `trigger`
    /// (`open`, `save`, `play`, `manual`, `watcher`); false for another
    /// name.
    pub fn editorBuildRequest(_: *ZigguratTestProbe, trigger: String) bool {
        var buf: [32]u8 = undefined;
        const t = std.meta.stringToEnum(editor_build.Trigger, trigger.toUtf8Buf(&buf)) orelse return false;
        editor_build.requestBuild(t);
        return true;
    }

    /// `editor_build.status` as a Dictionary: `building`, `has_last`, and
    /// the last outcome's `n` (-1 for none), `ok`, `trigger`, `path`, `ms`,
    /// `message` ("" for none), `error_count`, `warning_count` and
    /// `zig_problem` (enum tags as text).
    pub fn editorBuildStatus(_: *ZigguratTestProbe) Dictionary {
        var d: Dictionary = .init();
        const st = editor_build.status();
        dictSet(&d, "building", .init(bool, st.building));
        dictSet(&d, "has_last", .init(bool, st.last != null));
        const l = st.last orelse return d;
        dictSet(&d, "n", .init(i64, if (l.n) |n| n else -1));
        dictSet(&d, "ok", .init(bool, l.ok));
        dictSetText(&d, "trigger", @tagName(l.trigger));
        dictSetText(&d, "path", @tagName(l.path));
        dictSet(&d, "ms", .init(i64, @intCast(@min(l.ms, std.math.maxInt(i64)))));
        dictSetText(&d, "message", l.message orelse "");
        dictSet(&d, "error_count", .init(i64, l.error_count));
        dictSet(&d, "warning_count", .init(i64, l.warning_count));
        dictSetText(&d, "zig_problem", @tagName(l.zig_problem));
        return d;
    }

    /// `editor_build.diagnosticsCopy` flattened: one Dictionary per
    /// diagnostic with `rel`, `line`, `column` and `message`.
    pub fn editorBuildDiagnostics(_: *ZigguratTestProbe) Array {
        var out = Array.init();
        const a = std.heap.c_allocator;
        const list = editor_build.diagnosticsCopy(a) catch return out;
        defer editor_build.freeDiagnostics(a, list);
        for (list) |f| for (f.items) |dg| {
            var d: Dictionary = .init();
            dictSetText(&d, "rel", f.rel);
            dictSet(&d, "line", .init(i64, dg.line));
            dictSet(&d, "column", .init(i64, dg.column));
            dictSetText(&d, "message", dg.message);
            const v = Variant.init(Dictionary, d);
            out.pushBack(v);
            v.deinit();
            d.deinit();
        };
        return out;
    }

    /// Connects `signal` of `source` to the bound test method of the editor
    /// plugin `plugin` through a Callable made in Zig
    /// (`host_callable.callable`). False when an argument is missing or
    /// the connection fails.
    pub fn editorPluginConnect(_: *ZigguratTestProbe, plugin: ?*Object, source: ?*Object, signal: StringName) bool {
        const p = plugin orelse return false;
        const src = source orelse return false;
        var c = host_callable.callable(p, "test_ping");
        defer c.deinit();
        return src.connectRaw(signal, c, .{}) == .ok;
    }

    /// The toasts the Zig panel pushed so far, as `<severity>: <text>`
    /// (`editor_panel.toast_log`).
    pub fn editorPanelToasts(_: *ZigguratTestProbe) Array {
        var out = Array.init();
        for (0..editor_panel.toast_count) |i| {
            var s = String.fromUtf8(editor_panel.toast_log[i][0..editor_panel.toast_log_len[i]]) catch continue;
            defer s.deinit();
            const v = Variant.init(String, s);
            out.pushBack(v);
            v.deinit();
        }
        return out;
    }

    /// The editor plugin's `_build` (Build on Play) so far: `calls`, the
    /// last call's `result`, and `requested` (the calls that asked for a
    /// build).
    pub fn editorPluginPlay(_: *ZigguratTestProbe) Dictionary {
        var d: Dictionary = .init();
        dictSet(&d, "calls", .init(i64, editor_plugin.play_calls));
        dictSet(&d, "result", .init(bool, editor_plugin.play_result));
        dictSet(&d, "requested", .init(i64, editor_plugin.play_requests));
        return d;
    }

    /// Calls of the editor plugin's test method so far.
    pub fn editorPluginPings(_: *ZigguratTestProbe) i64 {
        return editor_plugin.test_pings;
    }

    /// The gate depth of the calling thread.
    pub fn gateDepth(_: *ZigguratTestProbe) i64 {
        return gate.depth();
    }

    /// Takes the swap lock and releases it at once: false when a thread is
    /// inside the gate.
    pub fn gateTrySwap(_: *ZigguratTestProbe) bool {
        if (!gate.trySwap()) return false;
        return gate.endSwap();
    }

    /// Loads the library at `path` as generation `gen` without publishing
    /// it: "" on success, the refusal sentence otherwise.
    pub fn stageModule(_: *ZigguratTestProbe, path: String, gen: i64) String {
        var buf: [4096]u8 = undefined;
        const p = path.toUtf8Buf(&buf);
        var diag: [256]u8 = undefined;
        const n = std.math.cast(u32, gen) orelse return .fromLatin1("generation out of range");
        _ = runtime.load(std.heap.c_allocator, .fromTrusted(p), n, &diag) catch |err| switch (err) {
            error.Refused, error.NotMainThread => return String.fromUtf8(std.mem.sliceTo(&diag, 0)) catch .fromLatin1("refused"),
            error.OutOfMemory => return .fromLatin1("out of memory"),
        };
        return .fromLatin1("");
    }

    /// Takes the swap lock and keeps it (the main thread is the swapper
    /// until `gate_swap_end`).
    pub fn gateSwapBegin(_: *ZigguratTestProbe) bool {
        return gate.trySwap();
    }

    /// Publishes generation `gen` (when it is loaded and not 0) under the
    /// swap lock `gate_swap_begin` took, then releases the lock.
    pub fn gateSwapEnd(_: *ZigguratTestProbe, gen: i64) bool {
        if (!gate.isSwapper()) return false;
        if (std.math.cast(u32, gen)) |n| {
            if (n != 0) {
                if (runtime.find(n)) |g| runtime.publish(g);
            }
        }
        return gate.endSwap();
    }

    /// The generation number of `obj`'s Zig script instance, or -1.
    pub fn instanceGeneration(_: *ZigguratTestProbe, obj: ?*Object) i64 {
        const rec = instance.recordOf(obj orelse return -1) orelse return -1;
        gate.enter();
        defer gate.leave();
        return rec.gen.n;
    }

    /// A test-only swap within one generation, standing in for the swap
    /// engine: under the swap lock, every live instance is marked as
    /// migrating in turn and its record rewritten. `mode` 0 keeps each
    /// data block (the record is rewritten to itself and the block
    /// retagged to its own generation, as a same-layout swap does); 1 moves
    /// the bytes to a new block of the same generation and frees the old
    /// one, as a changed layout does (no module code runs: the bytes
    /// move, ownership with them). False when the swap lock was not free.
    pub fn gateTestSwap(_: *ZigguratTestProbe, mode: i64) bool {
        if (!gate.trySwap()) return false;
        defer _ = gate.endSwap();
        const entries = registry.all(std.heap.c_allocator) catch return true;
        defer std.heap.c_allocator.free(entries);
        const api = runtime.hostApi();
        for (entries) |e| {
            // As the swap engine does after module code ran: skip a record
            // freed meanwhile, or a new one at a freed record's address.
            if (!registry.contains(e)) continue;
            const rec = e.rec;
            gate.setMigrating(rec);
            const d = &rec.gen.scripts()[rec.index];
            const size: usize = @max(d.instance_size, 1);
            const old = rec.data;
            if (mode == 0) {
                _ = runtime.retag(old, size, rec.gen.n, rec.gen.n);
                rec.* = .{ .owner = rec.owner, .script = rec.script, .gen = rec.gen, .index = rec.index, .data = old, .slot = rec.slot, .serial = rec.serial };
            } else if (api.alloc(rec.gen.n, size, d.instance_align)) |new| {
                @memcpy(@as([*]u8, @ptrCast(new))[0..size], @as([*]const u8, @ptrCast(old))[0..size]);
                rec.data = new;
                api.free(rec.gen.n, old, size, d.instance_align);
            }
            _ = instance.endMigration(rec);
        }
        return true;
    }

    /// Under the swap lock, marks `obj`'s instance as migrating, calls
    /// `method` on it through the instance's call callback and through
    /// Godot's Variant call, gets and sets its `value` property, and frees
    /// `obj` when `free_during`. Returns [callback call error, Variant call
    /// error, whether the get found nothing], or [-1] when the swap lock or
    /// the instance was not there.
    pub fn gateMigrateProbe(_: *ZigguratTestProbe, obj: ?*Object, method: StringName, free_during: bool) Array {
        var out = Array.init();
        const o = obj orelse return fail(&out);
        const rec = instance.recordOf(o) orelse return fail(&out);
        if (!gate.trySwap()) return fail(&out);
        defer _ = gate.endSwap();
        gate.setMigrating(rec);
        // What the script instance answers (Godot's
        // `ScriptInstanceExtension::callp` calls this callback) ...
        var ret: Variant = .nil;
        var err: godot.c.GDExtensionCallError = .{ .@"error" = 0, .argument = 0, .expected = 0 };
        instance.info.call_func.?(@ptrCast(rec), @ptrCast(&method), null, 0, @ptrCast(&ret), &err);
        ret.deinit();
        const e1: i64 = err.@"error";
        // ... and what a caller through `Object::callp` sees: Godot treats
        // INSTANCE_IS_NULL from a script instance like a missing method and
        // tries the engine class (core/object/object.cpp:800-826).
        const e2 = callErrorOf(o, &method);
        var sn = StringName.fromUtf8("value");
        defer sn.deinit();
        const got = o.get(sn);
        const nothing = got.tag == .nil;
        got.deinit();
        const v = Variant.init(i64, 99);
        o.set(sn, v);
        v.deinit();
        if (free_during) godot.raw.objectDestroy(@ptrCast(o));
        _ = instance.endMigration(rec);
        out.pushBack(Variant.init(i64, e1));
        out.pushBack(Variant.init(i64, e2));
        out.pushBack(Variant.init(bool, nothing));
        return out;
    }

    /// Instance records in the registry.
    pub fn registryCount(_: *ZigguratTestProbe) i64 {
        return @intCast(registry.count());
    }

    /// Runs the runtime's shutdown now, as SCENE exit does.
    pub fn runtimeShutdown(_: *ZigguratTestProbe) void {
        runtime.shutdown();
    }

    /// Requests a swap to the loaded generation `gen` (`swap.requestExact`:
    /// it replaces any waiting request and may name an older generation);
    /// it runs at a later frame. False when `gen` is not loaded.
    pub fn swapRequest(_: *ZigguratTestProbe, gen: i64) bool {
        const n = std.math.cast(u32, gen) orelse return false;
        const g = runtime.find(n) orelse return false;
        swap.requestExact(g);
        return true;
    }

    /// The last swap outcome (`swap.Outcome` as a number).
    pub fn swapOutcome(_: *ZigguratTestProbe) i64 {
        return @backingInt(swap.lastOutcome());
    }

    /// Swaps done in this process.
    pub fn swapsDone(_: *ZigguratTestProbe) i64 {
        return swap.swapCount();
    }

    /// Makes the `nth` `HostApi.alloc` call from now fail (0: none).
    pub fn failAllocation(_: *ZigguratTestProbe, nth: i64) void {
        runtime.failAllocation(std.math.cast(u32, nth) orelse 0);
    }

    /// The address of `obj`'s Zig instance data, or -1.
    pub fn instanceData(_: *ZigguratTestProbe, obj: ?*Object) i64 {
        const rec = instance.recordOf(obj orelse return -1) orelse return -1;
        gate.enter();
        defer gate.leave();
        return @bitCast(@as(u64, @intFromPtr(rec.data)));
    }

    /// Calls `callable` once during the next swap, on the swapping thread,
    /// after the first instance with a changed layout moved (`swap.test_hook`).
    pub fn swapHook(_: *ZigguratTestProbe, callable: Callable) void {
        if (hook_callable) |*c| c.deinit();
        hook_callable = Callable.copy(callable);
        swap.test_hook = .{ .run = &runHook };
    }

    pub fn propertyIsGroup(_: *ZigguratTestProbe, script: i64, index: i64) bool {
        const d = scriptDesc(script) orelse return false;
        const i = std.math.cast(u32, index) orelse return false;
        if (i >= d.property_count) return false;
        return d.properties[i].field_index == abi.no_field;
    }

    /// Lowers the threshold of the editor's loaded-size warning to `bytes`
    /// (`editor_build.size_warning_bytes`).
    pub fn setSizeWarningBytes(_: *ZigguratTestProbe, bytes: i64) void {
        editor_build.size_warning_bytes = std.math.cast(u64, bytes) orelse return;
    }

    /// Generations loaded in this process (`runtime.loadedCount`).
    pub fn loadedGenerations(_: *ZigguratTestProbe) i64 {
        return runtime.loadedCount();
    }

    /// True when generation `gen` is loaded.
    pub fn generationLoaded(_: *ZigguratTestProbe, gen: i64) bool {
        const n = std.math.cast(u32, gen) orelse return false;
        return runtime.find(n) != null;
    }
};

/// Sets d[key] = value and releases `value`.
fn dictSet(d: *Dictionary, comptime key: []const u8, value: Variant) void {
    var ks: String = .fromLatin1(key);
    defer ks.deinit();
    const k = Variant.init(String, ks);
    defer k.deinit();
    defer value.deinit();
    _ = d.set(k, value);
}

/// Sets d[key] = the String of UTF-8 `value`.
fn dictSetText(d: *Dictionary, comptime key: []const u8, value: []const u8) void {
    var s = String.fromUtf8(value) catch String.fromLatin1("");
    defer s.deinit();
    dictSet(d, key, .init(String, s));
}

var hook_callable: ?Callable = null;

fn runHook(_: ?*anyopaque) void {
    var c = hook_callable orelse return;
    hook_callable = null;
    defer c.deinit();
    var args = Array.init();
    defer args.deinit();
    const r = c.callv(args);
    r.deinit();
}

fn fail(out: *Array) Array {
    out.pushBack(Variant.init(i64, -1));
    return out.*;
}

/// Calls `method` on `obj` with no arguments through Godot's Variant call;
/// the call error code (0 is OK).
fn callErrorOf(obj: *Object, method: *const StringName) i64 {
    // A RefCounted owner goes in as RefCounted: gdzig counts the
    // reference the Variant drops only then.
    var self_v = if (obj.isClass(.fromComptimeLatin1("RefCounted")))
        Variant.init(*RefCounted, @ptrCast(obj))
    else
        Variant.init(?*Object, obj);
    defer self_v.deinit();
    var ret: Variant = .nil;
    var err: godot.c.GDExtensionCallError = .{ .@"error" = 0, .argument = 0, .expected = 0 };
    godot.raw.variantCall(@ptrCast(&self_v), @ptrCast(method), null, 0, @ptrCast(&ret), &err);
    ret.deinit();
    return err.@"error";
}

/// The paths `resource.on_saved` received (`saved_hook_install`).
var saved_paths: std.ArrayList([]u8) = .empty;
var saved_mu: std.Io.Mutex = .init;

fn recordSaved(path: []const u8) void {
    const copy = std.heap.c_allocator.dupe(u8, path) catch return;
    saved_mu.lockUncancelable(host_io.get());
    defer saved_mu.unlock(host_io.get());
    saved_paths.append(std.heap.c_allocator, copy) catch std.heap.c_allocator.free(copy);
}

/// Callbacks of `queue_push` that ran.
var queue_runs: std.atomic.Value(i64) = .init(0);

var nested_result: [3]i64 = .{ -1, -1, -1 };

fn nestedFrameCallback(_: ?*anyopaque) void {
    const lang = language.registered orelse return;
    const g = runtime.find(2) orelse return;
    swap.request(g);
    main_queue.push(countRun, null, null) catch return;
    const runs = queue_runs.load(.monotonic);
    const swaps: i64 = swap.swapCount();
    lang._frame();
    nested_result = .{ queue_runs.load(.monotonic) - runs, @as(i64, @backingInt(swap.lastOutcome())), @as(i64, swap.swapCount()) - swaps };
    // Back to the current generation, so the outer frame runs no swap.
    if (runtime.find(1)) |one| swap.requestExact(one);
}

fn countRun(_: ?*anyopaque) void {
    _ = queue_runs.fetchAdd(1, .monotonic);
}

/// The cache `cache_read` loaded.
var cache: ?desc_cache.Cache = null;

fn cacheClose() void {
    if (cache) |*c| c.deinit();
    cache = null;
}

fn cachedScript(rel: String) ?*const desc_cache.Script {
    const c = &(cache orelse return null);
    var buf: [1024]u8 = undefined;
    return c.find(rel.toUtf8Buf(&buf));
}

pub const method_names = [_][:0]const u8{
    "property_list",            "method_list",                 "signal_list",              "default_text",
    "cache_write",              "cache_read",                  "cache_rejections",         "cached_property_list",
    "cached_method_list",       "cached_signal_list",          "cached_default_text",      "cached_layout_hash",
    "layout_hash",              "cached_generation",           "roundtrip_default",        "stored_default",
    "cache_drops",              "load_module",                 "current_generation",       "was_ever_current",
    "init_calls",               "find_script",                 "method_index",             "property_index",
    "method_count",             "method_name",                 "property_count",           "property_name",
    "property_is_group",        "api_log",                     "api_request_swap",         "script_is_valid",
    "script_fallback_enabled",  "script_members",              "script_member_line",       "script_method_info",
    "script_has_default",       "script_update_exports",       "script_method_arg_count",  "live_instances",
    "live_bytes",               "call_error",                  "property_state",           "script_placeholder_count",
    "script_set_build_failed",  "language_validate",           "language_global_class",    "language_complete_code",
    "language_lookup_code",     "set_diagnostics",             "has_global_constant",      "queue_push",
    "queue_runs",               "saved_hook_install",          "saved_hook_clear",         "saved_hook_paths",
    "language_reload_scripts",  "language_reload_tool_script", "editor_build_outcomes",    "editor_build_busy",
    "cache_write_snapshot",     "gate_depth",                  "gate_try_swap",            "gate_test_swap",
    "gate_migrate_probe",       "registry_count",              "runtime_shutdown",         "stage_module",
    "gate_swap_begin",          "gate_swap_end",               "instance_generation",      "swap_request",
    "swap_outcome",             "swaps_done",                  "fail_allocation",          "instance_data",
    "swap_hook",                "game_reload_message",         "set_size_warning_bytes",   "loaded_generations",
    "generation_loaded",        "language_frame",              "language_stack_info",      "queue_pending",
    "queue_nested_frame_check", "language_nested_frames",      "gate_hold",                "default_mismatch_once",
    "editor_build_request",     "editor_build_status",         "editor_build_diagnostics", "editor_plugin_connect",
    "editor_plugin_pings",      "editor_panel_toasts",         "editor_plugin_play",       "game_capture",
    "game_capture_registered",  "debugger_reload_last",        "debugger_reload_sends",    "debugger_sessions",
    "debugger_started",         "editor_build_checks",
};

fn scriptDesc(script: i64) ?*const abi.ScriptDesc {
    const g = runtime.current() orelse return null;
    const i = std.math.cast(u32, script) orelse return null;
    if (i >= g.table.script_count) return null;
    return &g.table.scripts[i];
}

fn scriptNames(script: i64) ?*const runtime.ScriptNames {
    const g = runtime.current() orelse return null;
    const i = std.math.cast(usize, script) orelse return null;
    if (i >= g.names.len) return null;
    return &g.names[i];
}

fn text(s: abi.Str) String {
    if (s.len == 0) return .fromLatin1("");
    return String.fromUtf8(s.ptr.?[0..s.len]) catch .fromLatin1("");
}
