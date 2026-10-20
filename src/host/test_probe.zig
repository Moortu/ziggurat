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
const diag_cache = @import("diag_cache.zig");
const main_queue = @import("main_queue.zig");
const resource = @import("resource.zig");
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

    /// Loads the library at `path` as generation `gen`: "" on success, the
    /// refusal sentence otherwise.
    pub fn loadModule(_: *ZigguratTestProbe, path: String, gen: i64) String {
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
        const t = std.fmt.bufPrint(&buf, "{d}", .{d.layout_hash}) catch return .fromLatin1("");
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
    /// call and returns the call error code (0 is OK).
    pub fn callError(_: *ZigguratTestProbe, obj: ?*Object, method: StringName) i64 {
        var self_v = Variant.init(?*Object, obj);
        defer self_v.deinit();
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

    pub fn queueRuns(_: *ZigguratTestProbe) i64 {
        return queue_runs.load(.monotonic);
    }

    /// Sets `resource.on_saved` to a recorder of the paths it is called with.
    pub fn savedHookInstall(_: *ZigguratTestProbe) void {
        resource.on_saved = &recordSaved;
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

    pub fn propertyIsGroup(_: *ZigguratTestProbe, script: i64, index: i64) bool {
        const d = scriptDesc(script) orelse return false;
        const i = std.math.cast(u32, index) orelse return false;
        if (i >= d.property_count) return false;
        return d.properties[i].field_index == abi.no_field;
    }
};

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
    "property_list",         "method_list",             "signal_list",              "default_text",
    "cache_write",           "cache_read",              "cache_rejections",         "cached_property_list",
    "cached_method_list",    "cached_signal_list",      "cached_default_text",      "cached_layout_hash",
    "layout_hash",           "cached_generation",       "roundtrip_default",        "stored_default",
    "cache_drops",           "load_module",             "current_generation",       "init_calls",
    "find_script",           "method_index",            "property_index",           "method_count",
    "method_name",           "property_count",          "property_name",            "property_is_group",
    "api_log",               "api_request_swap",        "script_is_valid",          "script_fallback_enabled",
    "script_members",        "script_member_line",      "script_method_info",       "script_has_default",
    "script_update_exports", "script_method_arg_count", "live_instances",           "live_bytes",
    "call_error",            "property_state",          "script_placeholder_count", "script_set_build_failed",
    "language_validate",     "language_global_class",   "language_complete_code",   "language_lookup_code",
    "set_diagnostics",       "has_global_constant",     "queue_push",               "queue_runs",
    "saved_hook_install",    "saved_hook_clear",        "saved_hook_paths",
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
