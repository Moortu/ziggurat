//! `ZigScript`: the `Script` of one `.zig` file (spec section 7).
//!
//! A ZigScript holds the file's text (for the script editor) and answers
//! every script-level question Godot and the editor ask from the script's
//! descriptor. The descriptor is found by the script's project-relative path
//! (its resource path without `res://`), in this order:
//! 1. once a module generation is loaded (`runtime.current`), that
//!    generation alone: a script it does not have has no descriptor (it was
//!    deleted or renamed), whatever the cache says;
//! 2. before the first load, the descriptor cache the language read at
//!    startup (`.godot/ziggurat/descriptors.json`, `loadStartupCache`), so
//!    the Inspector works before the first build of the session is done;
//! 3. none: the script is not valid, has empty lists and lets Godot keep
//!    scene values with placeholder fallback.
//! Nothing is copied: every answer is read from the descriptor in use, so a
//! new generation changes the answers at once. `_update_exports` compares
//! the descriptor generation (`DescKey`) with the one it saw last.
//!
//! The code that runs is the module generation, never the text this object
//! holds.
//!
//! Threads: Godot calls these virtuals on the main thread and, while loading
//! resources, on loader threads. Generations are never freed and the
//! startup cache is freed only at SCENE exit, so the descriptor data read
//! here stays valid.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const snake = @import("snake");
const runtime = @import("runtime.zig");
const props = @import("props.zig");
const desc_cache = @import("desc_cache.zig");
const default_value = @import("default_value.zig");
const host_io = @import("host_io.zig");
const language = @import("language.zig");

const Allocator = std.mem.Allocator;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const Object = godot.class.Object;
const Script = godot.class.Script;
const ScriptExtension = godot.class.ScriptExtension;
const ScriptLanguage = godot.class.ScriptLanguage;
const Error = godot.global.Error;

/// Godot's `PROPERTY_USAGE_GROUP`, `_CATEGORY` and `_SUBGROUP`
/// (core/object/property_info.h): entries that only label the Inspector.
const usage_label: u32 = 64 | 128 | 256;

/// Longest resource path and member name handled; longer ones have no
/// descriptor.
const max_path_bytes = 4096;
const max_name_bytes = 1024;

// ------------------------------------------------------------ module state

/// The descriptor cache read when the language started, or null. Written on
/// the main thread by `loadStartupCache` (language `_init`, before any
/// scene loads) and `dropStartupCache` (SCENE exit).
var startup_cache: ?desc_cache.Cache = null;

/// `Engine.is_editor_hint()`, read once at SCENE init (`setEditorHint`).
/// Godot sets the hint for the editor in `Main::setup` (main/main.cpp:2223),
/// before extensions reach SCENE init (main/main.cpp:3793). The project
/// manager and the doc tool set it later, but neither runs project scripts.
var editor_hint: std.atomic.Value(bool) = .init(false);

pub fn setEditorHint(on: bool) void {
    editor_hint.store(on, .release);
}

/// Reads the project's descriptor cache once. A missing file is silent; a
/// bad one was logged by `desc_cache.read`. Main thread.
pub fn loadStartupCache() void {
    if (startup_cache != null) return;
    var buf: [max_path_bytes]u8 = undefined;
    const path = desc_cache.projectPath(&buf) orelse return;
    startup_cache = desc_cache.read(std.heap.c_allocator, host_io.get(), .fromTrusted(path)) catch |err| switch (err) {
        error.FileNotFound, error.Rejected => null,
        error.OutOfMemory => blk: {
            log("Ziggurat could not read the descriptor cache: out of memory.", .{});
            break :blk null;
        },
    };
}

/// Frees the startup cache. Main thread, at SCENE exit.
pub fn dropStartupCache() void {
    if (startup_cache) |*c| c.deinit();
    startup_cache = null;
}

// ------------------------------------------------------------ descriptors

/// Which descriptors a script uses: their source and generation number.
/// Cache and module numbers are separate spaces (a cache written by
/// generation 1 of an earlier session is not generation 1 of this one).
pub const DescKey = struct {
    source: enum { none, cached, loaded } = .none,
    n: u32 = 0,

    pub fn eql(a: DescKey, b: DescKey) bool {
        return a.source == b.source and a.n == b.n;
    }
};

/// The descriptor of one script, from a loaded generation or the cache.
const Desc = union(enum) {
    loaded: struct { gen: *runtime.Generation, index: u32 },
    cached: struct { script: *const desc_cache.Script, n: u32 },

    fn key(d: Desc) DescKey {
        return switch (d) {
            .loaded => |l| .{ .source = .loaded, .n = l.gen.n },
            .cached => |c| .{ .source = .cached, .n = c.n },
        };
    }

    fn abiDesc(d: Desc) ?*const abi.ScriptDesc {
        return switch (d) {
            .loaded => |l| &l.gen.scripts()[l.index],
            .cached => null,
        };
    }

    /// The name maps; null for the cache or after `runtime.shutdown`.
    fn names(d: Desc) ?*const runtime.ScriptNames {
        const l = switch (d) {
            .loaded => |l| l,
            .cached => return null,
        };
        if (l.index >= l.gen.names.len) return null;
        return &l.gen.names[l.index];
    }

    fn flags(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.flags,
            .cached => |c| c.script.flags.v,
        };
    }

    fn className(d: Desc) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.class_name),
            .cached => |c| c.script.class_name,
        };
    }

    fn baseClass(d: Desc) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.base_class),
            .cached => |c| c.script.base_class,
        };
    }

    fn propertyCount(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.property_count,
            .cached => |c| @intCast(c.script.properties.len),
        };
    }

    /// Name of property entry `i` and whether it is a label (a group).
    fn property(d: Desc, i: u32) struct { name: []const u8, label: bool } {
        return switch (d) {
            .loaded => blk: {
                const p = d.abiDesc().?.properties[i];
                break :blk .{ .name = props.text(p.name), .label = p.field_index == abi.no_field };
            },
            .cached => |c| .{ .name = c.script.properties[i].name, .label = c.script.properties[i].usage.v & usage_label != 0 },
        };
    }

    fn methodCount(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.method_count,
            .cached => |c| @intCast(c.script.methods.len),
        };
    }

    fn methodName(d: Desc, i: u32) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.methods[i].name),
            .cached => |c| c.script.methods[i].name,
        };
    }

    fn signalCount(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.signal_count,
            .cached => |c| @intCast(c.script.signals.len),
        };
    }

    fn signalName(d: Desc, i: u32) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.signals[i].name),
            .cached => |c| c.script.signals[i].name,
        };
    }

    /// The index of the method named `sn`.
    fn methodIndex(d: Desc, sn: StringName) ?u32 {
        if (d.names()) |m| return m.method(sn);
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(sn, &buf) orelse return null;
        for (0..d.methodCount()) |i| {
            if (std.mem.eql(u8, d.methodName(@intCast(i)), name)) return @intCast(i);
        }
        return null;
    }

    /// The property entry index of the exported property named `sn` (group
    /// entries are never found).
    fn propertyIndex(d: Desc, sn: StringName) ?u32 {
        if (d.names()) |m| return m.property(sn);
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(sn, &buf) orelse return null;
        for (0..d.propertyCount()) |i| {
            const p = d.property(@intCast(i));
            if (!p.label and std.mem.eql(u8, p.name, name)) return @intCast(i);
        }
        return null;
    }

    fn hasSignal(d: Desc, sn: StringName) bool {
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(sn, &buf) orelse return false;
        for (0..d.signalCount()) |i| {
            if (std.mem.eql(u8, d.signalName(@intCast(i)), name)) return true;
        }
        return false;
    }

    /// Whether property entry `i` has a default, by one rule for both
    /// sources: the default exists and has a stored form in the descriptor
    /// cache (`default_value`), so it survives the cache round trip. A
    /// module default the cache would drop (a string over
    /// `default_value.max_text_bytes`, a non-finite vector) has none, as it
    /// has none when read back from the cache. Calls the module's
    /// `get_default` for a loaded descriptor.
    fn hasDefault(d: Desc, i: u32) bool {
        switch (d) {
            .loaded => {
                const desc = d.abiDesc().?;
                const v = props.defaultValue(desc, i) orelse return false;
                defer v.deinit();
                var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
                defer arena.deinit();
                const stored = default_value.fromVariant(arena.allocator(), desc.properties[i].variant_type, v) catch return false;
                return stored != .absent and default_value.fits(desc.properties[i].variant_type, stored);
            },
            // `desc_cache.parse` already dropped defaults that do not fit.
            .cached => |c| return c.script.properties[i].default != .absent,
        }
    }

    /// The argument count of method `i`.
    fn methodArgCount(d: Desc, i: u32) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.methods[i].arg_count,
            .cached => |c| @intCast(c.script.methods[i].args.len),
        };
    }

    /// The default value of property entry `i`; the caller owns it.
    fn defaultValue(d: Desc, i: u32) ?Variant {
        return switch (d) {
            .loaded => props.defaultValue(d.abiDesc().?, i),
            .cached => |c| c.script.defaultValue(i),
        };
    }

    fn propertyList(d: Desc) Array {
        return switch (d) {
            .loaded => props.propertyList(d.abiDesc().?),
            .cached => |c| c.script.propertyList(),
        };
    }

    fn methodList(d: Desc) Array {
        return switch (d) {
            .loaded => props.methodList(d.abiDesc().?),
            .cached => |c| c.script.methodList(),
        };
    }

    fn signalList(d: Desc) Array {
        return switch (d) {
            .loaded => props.signalList(d.abiDesc().?),
            .cached => |c| c.script.signalList(),
        };
    }

    fn methodInfo(d: Desc, i: u32) Dictionary {
        return switch (d) {
            .loaded => props.methodInfo(d.abiDesc().?, i),
            .cached => |c| c.script.methodInfo(i),
        };
    }
};

/// The descriptor of the script at project-relative path `rel`. Once a
/// generation is loaded the cache is never asked (no stale validity for a
/// script the module no longer has).
fn findDesc(rel: []const u8) ?Desc {
    if (runtime.current()) |gen| {
        const i = runtime.findScript(gen, rel) orelse return null;
        return .{ .loaded = .{ .gen = gen, .index = i } };
    }
    if (startup_cache) |*c| {
        if (c.find(rel)) |s| return .{ .cached = .{ .script = s, .n = c.generation() } };
    }
    return null;
}

/// The UTF-8 text of `s` in `buf`, or null when it does not fit.
fn stringText(s: *const String, buf: []u8) ?[]const u8 {
    const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(s.constPtr(), null, 0)));
    if (n > buf.len) return null;
    if (n != 0) _ = godot.raw.stringToUtf8Chars(s.constPtr(), buf.ptr, @intCast(n));
    return buf[0..n];
}

/// The UTF-8 text of `sn` in `buf`, or null when it does not fit.
fn nameText(sn: StringName, buf: []u8) ?[]const u8 {
    var s = String.fromStringName(sn);
    defer s.deinit();
    return stringText(&s, buf);
}

/// The project-relative path of a `res://` resource path, normalised into
/// `buf` like Godot's `String::simplify_path` (core/string/ustring.cpp:4149):
/// a backslash becomes `/`, empty and `.` segments are dropped and `..` removes the
/// segment before it. Null for any other path (an unsaved script has none),
/// for a `..` that would leave the project, for an empty result and when
/// `buf` is too small. Paths set by the resource loader are already
/// simplified; paths set directly (`resource_path`, `take_over_path`) may
/// not be. The result is compared byte for byte with the table's paths:
/// Godot resource paths are case-sensitive, so `res://Player.zig` is not
/// `res://player.zig`.
pub fn relPath(res_path: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "res://";
    if (!std.mem.startsWith(u8, res_path, prefix)) return null;
    var len: usize = 0;
    var it = std.mem.tokenizeAny(u8, res_path[prefix.len..], "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (len == 0) return null;
            len = if (std.mem.lastIndexOfScalar(u8, buf[0..len], '/')) |slash| slash else 0;
            continue;
        }
        const sep: usize = if (len == 0) 0 else 1;
        if (len + sep + seg.len > buf.len) return null;
        if (sep == 1) buf[len] = '/';
        @memcpy(buf[len + sep ..][0..seg.len], seg);
        len += sep + seg.len;
    }
    if (len == 0) return null;
    return buf[0..len];
}

// ------------------------------------------------------------ member lines

/// 1-based number of the first top-level (unindented) line of `text` that
/// declares the Godot member `name`, or null. The rule of the SDK marker
/// lookup (src/build/diagnostics.zig, `markerLine`), with Godot names: after
/// an optional `pub `, a field `<name>:`, a `const <name>` or `var <name>`,
/// or a `fn` whose `snake.toSnakeCaseBuf` name is `name` (the SDK names
/// methods that way). Members renamed with `meta` and signals (declared
/// inside `signals`) have no line of their own.
pub fn memberLine(text: []const u8, name: []const u8) ?u32 {
    if (name.len == 0) return null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 1;
    while (it.next()) |raw| : (n +|= 1) {
        var l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "pub ")) l = l["pub ".len..];
        if (std.mem.startsWith(u8, l, "fn ")) {
            const id = ident(l["fn ".len..]);
            if (std.mem.eql(u8, id, name)) return n;
            var buf: [2 * max_name_bytes]u8 = undefined;
            if (id.len <= max_name_bytes) {
                const snake_id = snake.toSnakeCaseBuf(&buf, id) catch continue;
                if (std.mem.eql(u8, snake_id, name)) return n;
            }
            continue;
        }
        const rest = if (std.mem.startsWith(u8, l, "const "))
            l["const ".len..]
        else if (std.mem.startsWith(u8, l, "var "))
            l["var ".len..]
        else blk: {
            // A field: the identifier is followed by `:`.
            const id = ident(l);
            if (id.len == 0 or !std.mem.startsWith(u8, std.mem.trimStart(u8, l[id.len..], " "), ":")) continue;
            break :blk l;
        };
        if (std.mem.eql(u8, ident(rest), name)) return n;
    }
    return null;
}

/// The identifier at the start of `s` (possibly empty).
fn ident(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) : (i += 1) {}
    if (i > 0 and std.ascii.isDigit(s[0])) return s[0..0];
    return s[0..i];
}

// ------------------------------------------------------------ the script

pub const ZigScript = struct {
    base: *ScriptExtension,
    /// The file's text, as the script editor shows it.
    source: String,
    /// The descriptors `_update_exports` saw last.
    exports_seen: DescKey = .{},
    /// How many times `_update_exports` found new descriptors.
    export_refreshes: u32 = 0,
    /// Set once a reload request has been logged.
    reload_logged: bool = false,
    /// Set once a refused instance has been logged.
    instance_logged: bool = false,

    pub fn create(allocator: *Allocator) !*ZigScript {
        const self = try allocator.create(ZigScript);
        self.* = .{ .base = ScriptExtension.init(), .source = .init() };
        self.base.setInstance(ZigScript, self);
        return self;
    }

    pub fn destroy(self: *ZigScript, allocator: *Allocator) void {
        self.source.deinit();
        self.base.destroy();
        allocator.destroy(self);
    }

    /// A new script holding `text`. Its one counted reference belongs to the
    /// caller.
    pub fn withSource(text: String) ?*ZigScript {
        var alloc = godot.engine_allocator;
        const s = create(&alloc) catch return null;
        s.source.deinit();
        s.source = .copy(text);
        return s;
    }

    /// The descriptor for this script's resource path, or null.
    fn desc(self: *const ZigScript) ?Desc {
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const res_path = stringText(&path, &buf) orelse return null;
        var rel_buf: [max_path_bytes]u8 = undefined;
        return findDesc(relPath(res_path, &rel_buf) orelse return null);
    }

    /// Writes `Script <path> <what>` to Godot's output.
    fn logScript(self: *const ZigScript, comptime what: []const u8) void {
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const p = stringText(&path, &buf) orelse "(path too long)";
        log("Script {s} " ++ what, .{if (p.len == 0) "(unsaved)" else p});
    }

    // ---------------------------------------------------------- identity

    pub fn _getLanguage(_: *ZigScript) ?*ScriptLanguage {
        const lang = language.registered orelse return null;
        return .upcast(lang.base);
    }

    /// True when a descriptor describes the script. A script without one
    /// was never built (or its build failed before any good build).
    pub fn _isValid(self: *ZigScript) bool {
        return self.desc() != null;
    }

    /// The descriptor's tool flag (`pub const tool = true;`), per script.
    pub fn _isTool(self: *ZigScript) bool {
        const d = self.desc() orelse return false;
        return d.flags() & abi.script_flag_tool != 0;
    }

    pub fn _isAbstract(_: *ZigScript) bool {
        return false;
    }

    /// The engine class the script extends; empty without a descriptor.
    pub fn _getInstanceBaseType(self: *ZigScript) StringName {
        const d = self.desc() orelse return .init();
        return .fromUtf8(d.baseClass());
    }

    /// The script's `class_name`, or empty.
    pub fn _getGlobalName(self: *ZigScript) StringName {
        const d = self.desc() orelse return .init();
        return .fromUtf8(d.className());
    }

    /// Zig scripts do not inherit from scripts: only this script itself.
    pub fn _inheritsScript(self: *ZigScript, script: ?*Script) bool {
        const s = script orelse return false;
        return @intFromPtr(s) == @intFromPtr(self.base);
    }

    pub fn _getBaseScript(_: *ZigScript) ?*Script {
        return null;
    }

    /// GDScript's rule (modules/gdscript/gdscript.cpp:258): valid, and tool
    /// or scripting enabled, and not in recovery mode. A GDExtension cannot
    /// read `ScriptServer::is_scripting_enabled()`; the editor turns
    /// scripting off when it starts (editor/editor_node.cpp:8388) and is the
    /// only place that does, so the editor hint stands for "scripting
    /// disabled". Recovery mode needs no check: Godot loads no GDExtension
    /// in it (core/extension/gdextension_manager.cpp:116), so this code
    /// never runs there.
    pub fn _canInstantiate(self: *ZigScript) bool {
        const d = self.desc() orelse return false;
        const tool = d.flags() & abi.script_flag_tool != 0;
        return tool or !editor_hint.load(.acquire);
    }

    // ---------------------------------------------------------- instances

    /// Godot keeps the object without a script when this returns null.
    /// Logged once per script.
    pub fn _instanceCreate(self: *ZigScript, _: ?*Object) ?*anyopaque {
        self.logRefusedInstance();
        return null;
    }

    pub fn _placeholderInstanceCreate(self: *ZigScript, _: ?*Object) ?*anyopaque {
        self.logRefusedInstance();
        return null;
    }

    fn logRefusedInstance(self: *ZigScript) void {
        if (self.instance_logged) return;
        self.instance_logged = true;
        self.logScript("cannot create instances yet.");
    }

    /// The script keeps no list of placeholder instances, so there is
    /// nothing to remove.
    pub fn _placeholderErased(_: *ZigScript, _: ?*anyopaque) void {}

    /// Idempotent: Godot calls it once per property while saving a scene.
    /// Only when the descriptors differ from those seen last (another
    /// generation, or the cache replaced by a module) is a refresh counted;
    /// the script has no placeholder instances to update.
    pub fn _updateExports(self: *ZigScript) void {
        const key: DescKey = if (self.desc()) |d| d.key() else .{};
        if (key.eql(self.exports_seen)) return;
        self.exports_seen = key;
        self.export_refreshes += 1;
    }

    /// True while the script has no descriptors: Godot then keeps every
    /// scene value of a placeholder instead of dropping the ones the
    /// script does not list (spec section 2).
    pub fn _isPlaceholderFallbackEnabled(self: *ZigScript) bool {
        return self.desc() == null;
    }

    // ---------------------------------------------------------- source

    pub fn _hasSourceCode(_: *ZigScript) bool {
        return true;
    }

    pub fn _getSourceCode(self: *ZigScript) String {
        return .copy(self.source);
    }

    pub fn _setSourceCode(self: *ZigScript, code: String) void {
        self.source.deinit();
        self.source = .copy(code);
    }

    /// Returns OK: the code that runs changes only when a new build is
    /// loaded, so a reload request changes nothing. Logged once per script.
    pub fn _reload(self: *ZigScript, _: bool) Error {
        if (!self.reload_logged) {
            self.reload_logged = true;
            self.logScript("reloads when a new build is loaded; the reload request changed nothing.");
        }
        return .ok;
    }

    /// False: the script editor does not reload the text from disk.
    pub fn _editorCanReloadFromFile(_: *ZigScript) bool {
        return false;
    }

    // ---------------------------------------------------------- members

    pub fn _hasMethod(self: *ZigScript, method: StringName) bool {
        const d = self.desc() orelse return false;
        return d.methodIndex(method) != null;
    }

    /// The method's argument count as an int Variant; nil for an unknown
    /// method, so Godot falls back to its default (unknown count).
    pub fn _getScriptMethodArgumentCount(self: *ZigScript, method: StringName) Variant {
        const d = self.desc() orelse return .nil;
        const i = d.methodIndex(method) orelse return .nil;
        return Variant.init(i64, d.methodArgCount(i));
    }

    pub fn _hasStaticMethod(_: *ZigScript, _: StringName) bool {
        return false;
    }

    /// The method's dictionary, as in `_get_script_method_list`; empty for
    /// an unknown method.
    pub fn _getMethodInfo(self: *ZigScript, method: StringName) Dictionary {
        const d = self.desc() orelse return .init();
        const i = d.methodIndex(method) orelse return .init();
        return d.methodInfo(i);
    }

    pub fn _getScriptMethodList(self: *ZigScript) Array {
        const d = self.desc() orelse return .init();
        return d.methodList();
    }

    /// Exported properties with their group entries, in descriptor order.
    pub fn _getScriptPropertyList(self: *ZigScript) Array {
        const d = self.desc() orelse return .init();
        return d.propertyList();
    }

    pub fn _hasScriptSignal(self: *ZigScript, signal: StringName) bool {
        const d = self.desc() orelse return false;
        return d.hasSignal(signal);
    }

    pub fn _getScriptSignalList(self: *ZigScript) Array {
        const d = self.desc() orelse return .init();
        return d.signalList();
    }

    /// True for an exported property whose default round-trips through
    /// the descriptor cache (`Desc.hasDefault`), the same answer from a
    /// loaded module and from the cache. The SDK requires a default for
    /// every field, so this is false only for defaults with no stored form;
    /// Godot then saves that property's value in every scene.
    pub fn _hasPropertyDefaultValue(self: *ZigScript, property: StringName) bool {
        const d = self.desc() orelse return false;
        const i = d.propertyIndex(property) orelse return false;
        return d.hasDefault(i);
    }

    pub fn _getPropertyDefaultValue(self: *ZigScript, property: StringName) Variant {
        const d = self.desc() orelse return .nil;
        const i = d.propertyIndex(property) orelse return .nil;
        return d.defaultValue(i) orelse .nil;
    }

    /// The exported property names (group entries left out), like
    /// GDScript's member variables.
    pub fn _getMembers(self: *ZigScript) Array {
        var arr = Array.init();
        const d = self.desc() orelse return arr;
        for (0..d.propertyCount()) |i| {
            const p = d.property(@intCast(i));
            if (p.label) continue;
            var sn = StringName.fromUtf8(p.name);
            defer sn.deinit();
            const v = Variant.init(StringName, sn);
            defer v.deinit();
            arr.pushBack(v);
        }
        return arr;
    }

    /// The 1-based line declaring `member` in the source text (see
    /// `memberLine`), or -1.
    pub fn _getMemberLine(self: *ZigScript, member: StringName) i64 {
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(member, &buf) orelse return -1;
        const text = props.utf8Alloc(std.heap.c_allocator, &self.source) catch return -1;
        defer std.heap.c_allocator.free(text);
        return memberLine(text, name) orelse -1;
    }

    /// Zig scripts expose no constants to Godot.
    pub fn _getConstants(_: *ZigScript) Dictionary {
        return .init();
    }

    /// No RPC methods. Godot caches an object's RPC config once and never
    /// refreshes it, so RPCs that a reload would add are ignored.
    pub fn _getRpcConfig(_: *ZigScript) Variant {
        var d = Dictionary.init();
        defer d.deinit();
        return Variant.init(Dictionary, d);
    }

    // ---------------------------------------------------------- documentation

    pub fn _getDocClassName(_: *ZigScript) StringName {
        return .init();
    }

    pub fn _getDocumentation(_: *ZigScript) Array {
        return .init();
    }
};

/// Prints one line to Godot's output.
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_path_bytes + 256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "member line follows the SDK marker rule with Godot names" {
    const text =
        \\const z = @import("ziggurat");
        \\pub const class_name = "Player";
        \\
        \\base: *g.Node,
        \\speed: f32 = 300,
        \\    nested: i32 = 0,
        \\pub const signals = struct {
        \\    pub const hit = struct {};
        \\};
        \\pub fn takeDamage(self: *@This()) void {}
        \\fn _physicsProcess(self: *@This(), d: f64) void {}
        \\var counter: u32 = 0;
        \\speedy: f32 = 1,
        \\pub fn speed(self: *@This()) void {}
    ;
    try testing.expectEqual(@as(?u32, 5), memberLine(text, "speed"));
    try testing.expectEqual(@as(?u32, 13), memberLine(text, "speedy"));
    try testing.expectEqual(@as(?u32, 10), memberLine(text, "take_damage"));
    try testing.expectEqual(@as(?u32, 10), memberLine(text, "takeDamage"));
    try testing.expectEqual(@as(?u32, 11), memberLine(text, "_physics_process"));
    try testing.expectEqual(@as(?u32, 7), memberLine(text, "signals"));
    try testing.expectEqual(@as(?u32, 12), memberLine(text, "counter"));
    try testing.expectEqual(@as(?u32, 2), memberLine(text, "class_name"));
    // Indented declarations are not top-level.
    try testing.expectEqual(@as(?u32, null), memberLine(text, "nested"));
    try testing.expectEqual(@as(?u32, null), memberLine(text, "hit"));
    try testing.expectEqual(@as(?u32, null), memberLine(text, "spee"));
    try testing.expectEqual(@as(?u32, null), memberLine(text, ""));
    try testing.expectEqual(@as(?u32, 1), memberLine("x: i32 = 0,\r\n", "x"));
}

test "relative path of a resource path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("player.zig", relPath("res://player.zig", &buf).?);
    try testing.expectEqualStrings("ui/hud.zig", relPath("res://ui/hud.zig", &buf).?);
    try testing.expect(relPath("res://", &buf) == null);
    try testing.expect(relPath("", &buf) == null);
    try testing.expect(relPath("user://a.zig", &buf) == null);
}

test "relative path is normalised like simplify_path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a.zig", relPath("res://./a.zig", &buf).?);
    try testing.expectEqualStrings("a/b.zig", relPath("res://a//b.zig", &buf).?);
    try testing.expectEqualStrings("a/b.zig", relPath("res:///a/./b.zig", &buf).?);
    try testing.expectEqualStrings("a/b.zig", relPath("res://a\\b.zig", &buf).?);
    try testing.expectEqualStrings("b.zig", relPath("res://a/../b.zig", &buf).?);
    try testing.expectEqualStrings("x/b.zig", relPath("res://x/a/c/../../b.zig", &buf).?);
    try testing.expect(relPath("res://../a.zig", &buf) == null);
    try testing.expect(relPath("res://a/../..", &buf) == null);
    try testing.expect(relPath("res://./", &buf) == null);
    // Case-sensitive: kept as written.
    try testing.expectEqualStrings("Player.zig", relPath("res://Player.zig", &buf).?);
    var small: [4]u8 = undefined;
    try testing.expect(relPath("res://abcde.zig", &small) == null);
}

test "descriptor keys tell sources and generations apart" {
    const none: DescKey = .{};
    try testing.expect(none.eql(.{}));
    try testing.expect(!none.eql(.{ .source = .cached, .n = 0 }));
    try testing.expect(!(DescKey{ .source = .cached, .n = 1 }).eql(.{ .source = .loaded, .n = 1 }));
    try testing.expect(!(DescKey{ .source = .loaded, .n = 1 }).eql(.{ .source = .loaded, .n = 2 }));
}
