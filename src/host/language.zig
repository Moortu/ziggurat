//! `ZigLanguage`: the Zig script language (spec section 7).
//!
//! Every `ScriptLanguageExtension` virtual is implemented, so the engine
//! never reports a missing required method and gdzig's virtual lookup is
//! measured at its full size (`vendor/gdzig/PATCHES.md`).
//!
//! - Templates: one built-in template, "Default", offered for every class
//!   (`template.zig`). `_make_template` never returns null (a null result
//!   crashed the Create Script dialog in Stage 0) and refuses a quoted
//!   script path as parent class with a script that is only a comment.
//! - `_validate` never compiles: it reads the diagnostics the last build
//!   recorded for the file (`diag_cache.zig`). A file with no recorded
//!   error is valid, so after a good build the editor's save path goes on
//!   to live-reload a running game (editor/script/script_editor_plugin.cpp:
//!   777-783).
//! - `_get_global_class_name` runs on the editor's file-scan thread: it
//!   reads the file with std and scans the text (`global_class.zig`); the
//!   only engine values it makes are the returned Strings and Dictionary.
//! - `_frame` drains the main-thread queue (`main_queue.zig`).
//! - Reload requests only log (once per kind) and count; global constants
//!   (autoloads) are remembered by name. Neither reports an error.
//! - `_debug_get_current_stack_info` takes no lock and creates no
//!   StringName (spec section 2); `_init` calls it once.
//! - `_auto_indent_code` returns its input unchanged; completion and lookup
//!   answer with empty results and print nothing.
const std = @import("std");
const godot = @import("gdzig");
const script = @import("script.zig");
const props = @import("props.zig");
const host_io = @import("host_io.zig");
const diag_cache = @import("diag_cache.zig");
const main_queue = @import("main_queue.zig");
const global_class = @import("global_class.zig");
const template = @import("template.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedStringArray = godot.builtin.PackedStringArray;
const Dictionary = godot.builtin.Dictionary;
const Array = godot.builtin.Array;
const Variant = godot.builtin.Variant;
const Object = godot.class.Object;
const Script = godot.class.Script;
const ScriptExtension = godot.class.ScriptExtension;
const ScriptLanguage = godot.class.ScriptLanguage;
const ScriptLanguageExtension = godot.class.ScriptLanguageExtension;
const ClassDb = godot.class.ClassDb;
const ProjectSettings = godot.class.ProjectSettings;
const Error = godot.global.Error;

const gpa = std.heap.c_allocator;

/// Longest resource path and name handled.
const max_path_bytes = 4096;
const max_name_bytes = 1024;

/// The registered language, between SCENE init and SCENE exit (set by the
/// entry). Scripts return it from `_get_language`.
pub var registered: ?*ZigLanguage = null;

/// The project folder (`res://` globalized, no trailing `/`), set once by
/// `_init` on the main thread before the editor's file scan starts; read by
/// `_get_global_class_name` on the scan thread. Empty when unknown.
var project_root_buf: [max_path_bytes]u8 = undefined;
var project_root: std.atomic.Value(usize) = .init(0);

/// The reload requests Godot can make; each is logged once and counted.
pub const Reload = enum { all, scripts, tool };

pub const ZigLanguage = struct {
    base: *ScriptLanguageExtension,
    /// Reload requests per kind, for the later stages that act on them.
    reloads: std.EnumArray(Reload, std.atomic.Value(u32)) = .initFill(.init(0)),
    /// Set once the first request of a kind is logged.
    reload_logged: std.EnumArray(Reload, std.atomic.Value(bool)) = .initFill(.init(false)),
    /// Names of the global constants Godot added (autoloads), owned.
    globals_mu: std.Io.Mutex = .init,
    globals: std.StringHashMapUnmanaged(void) = .empty,

    pub fn create(allocator: *Allocator) !*ZigLanguage {
        const self = try allocator.create(ZigLanguage);
        self.* = .{ .base = ScriptLanguageExtension.init() };
        self.base.setInstance(ZigLanguage, self);
        main_queue.open();
        return self;
    }

    /// At SCENE exit (or when Godot refused the language): closes the
    /// main-thread queue (waiting work is dropped through its drop hooks; a
    /// later push frees its context at once), drops cached diagnostics and
    /// frees the names.
    pub fn destroy(self: *ZigLanguage, allocator: *Allocator) void {
        _ = main_queue.close();
        diag_cache.reset();
        var it = self.globals.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.globals.deinit(gpa);
        self.base.destroy();
        allocator.destroy(self);
    }

    /// How many reload requests of `kind` arrived.
    pub fn reloadCount(self: *const ZigLanguage, kind: Reload) u32 {
        return self.reloads.getPtrConst(kind).load(.acquire);
    }

    /// True when Godot added a global constant `name` and did not remove it.
    pub fn hasGlobal(self: *ZigLanguage, name: []const u8) bool {
        self.globals_mu.lockUncancelable(host_io.get());
        defer self.globals_mu.unlock(host_io.get());
        return self.globals.contains(name);
    }

    // ------------------------------------------------------------ identity

    pub fn _getName(_: *ZigLanguage) String {
        return .fromLatin1("Zig");
    }
    pub fn _getType(_: *ZigLanguage) String {
        return .fromLatin1("ZigScript");
    }
    pub fn _getExtension(_: *ZigLanguage) String {
        return .fromLatin1("zig");
    }
    pub fn _getRecognizedExtensions(_: *ZigLanguage) PackedStringArray {
        var a: PackedStringArray = .init();
        var s: String = .fromLatin1("zig");
        defer s.deinit();
        _ = a.pushBack(s);
        return a;
    }
    pub fn _preferredFileNameCasing(_: *ZigLanguage) ScriptLanguage.ScriptNameCasing {
        return .script_name_casing_snake_case;
    }

    // ------------------------------------------------------------ lifecycle

    /// Reads the project's descriptor cache, so scripts have descriptors
    /// before the first build of the session (Godot calls this once, from
    /// `ScriptServer::init_languages`, main/main.cpp:3867).
    /// Also records the project folder for the global class scan and calls
    /// `_debug_get_current_stack_info` once (spec section 7).
    pub fn _init(self: *ZigLanguage) void {
        script.loadStartupCache();
        setProjectRoot();
        var stack = self._debugGetCurrentStackInfo();
        stack.deinit();
        warmScanPath();
    }
    pub fn _finish(_: *ZigLanguage) void {}
    /// Runs queued main-thread work, at most `main_queue.per_frame` items.
    /// Godot calls `_frame` also from nested `Main::iteration()` calls; a
    /// nested call runs nothing (`main_queue.drain`).
    pub fn _frame(_: *ZigLanguage) void {
        _ = main_queue.drain();
    }
    pub fn _threadEnter(_: *ZigLanguage) void {}
    pub fn _threadExit(_: *ZigLanguage) void {}

    // ------------------------------------------------------------ syntax

    pub fn _getReservedWords(_: *ZigLanguage) PackedStringArray {
        return .init();
    }
    pub fn _isControlFlowKeyword(_: *ZigLanguage, _: String) bool {
        return false;
    }
    pub fn _getCommentDelimiters(_: *ZigLanguage) PackedStringArray {
        return .init();
    }
    pub fn _getDocCommentDelimiters(_: *ZigLanguage) PackedStringArray {
        return .init();
    }
    pub fn _getStringDelimiters(_: *ZigLanguage) PackedStringArray {
        return .init();
    }

    // ------------------------------------------------------------ scripts and templates

    /// A new empty `ZigScript`; its one counted reference goes to the caller.
    pub fn _createScript(_: *ZigLanguage) ?*Object {
        var empty: String = .init();
        defer empty.deinit();
        const s = script.ZigScript.withSource(empty) orelse return null;
        return .upcast(s.base);
    }
    pub fn _isUsingTemplates(_: *ZigLanguage) bool {
        return true;
    }
    /// The "Default" template, for `Object` only: the Create Script dialog
    /// asks for each class from the parent class up to `Object`
    /// (script_create_dialog.cpp:556-575), so it is offered for every
    /// class once. Keys as `get_built_in_templates` reads them
    /// (core/object/script_language_extension.h:276-299).
    pub fn _getBuiltInTemplates(_: *ZigLanguage, object: StringName) Array {
        var a: Array = .init();
        var buf: [16]u8 = undefined;
        const name = props.nameText(object, &buf) orelse return a;
        if (!std.mem.eql(u8, name, "Object")) return a;
        var d: Dictionary = .init();
        defer d.deinit();
        dictSetString(&d, "inherit", "Object");
        dictSetString(&d, "name", template.default_name);
        dictSetString(&d, "description", template.default_description);
        dictSetString(&d, "content", template.default_content);
        dictSetInt(&d, "id", 0);
        dictSetInt(&d, "origin", 0); // TEMPLATE_BUILT_IN
        props.pushDict(&a, d);
        return a;
    }
    /// A `ZigScript` holding the template text for file name `class_name`
    /// and parent class `base_class_name` (`template.make`). Never null: the
    /// Create Script dialog dereferences the result, so when the script
    /// cannot be made a bare `ScriptExtension` stands in. The one counted
    /// reference goes to the `Ref<Script>` Godot reads the pointer into.
    pub fn _makeTemplate(_: *ZigLanguage, content: String, class_name: String, base_class_name: String) ?*Script {
        var text: String = templateText(content, class_name, base_class_name) catch .init();
        defer text.deinit();
        const s = script.ZigScript.withSource(text) orelse return .upcast(ScriptExtension.init());
        return .upcast(s.base);
    }
    /// From the diagnostics the last build recorded for `path`: `valid` is
    /// false while the file has errors, which go in `errors` with `line`,
    /// `column`, `message` and `path` (the keys `validate` reads,
    /// core/object/script_language_extension.h:304-363). `path` is the
    /// script's own, or the editor files the errors under another script
    /// (script_text_editor.cpp:856-863). A file the cache knows nothing
    /// about (no build yet, unsaved, outside the project) is valid. The
    /// text in `_script` is not compiled.
    pub fn _validate(_: *ZigLanguage, _: String, path: String, _: bool, _: bool, _: bool, _: bool) Dictionary {
        var d: Dictionary = .init();
        const list = cachedDiagnostics(&path) orelse {
            dictSetBool(&d, "valid", true);
            return d;
        };
        defer diag_cache.freeList(gpa, list);
        dictSetBool(&d, "valid", list.len == 0);
        var errors: Array = .init();
        defer errors.deinit();
        for (list) |diag| {
            var e: Dictionary = .init();
            defer e.deinit();
            // Godot's lines and columns are 1-based; a scan problem has 0.
            dictSetInt(&e, "line", @max(1, diag.line));
            dictSetInt(&e, "column", @max(1, diag.column));
            dictSetString(&e, "message", diag.message);
            dictSetVariant(&e, "path", .init(String, path));
            props.pushDict(&errors, e);
        }
        dictSetVariant(&d, "errors", .init(Array, errors));
        return d;
    }
    pub fn _validatePath(_: *ZigLanguage, _: String) String {
        return .init();
    }
    pub fn _hasNamedClasses(_: *ZigLanguage) bool {
        return false;
    }
    pub fn _supportsBuiltinMode(_: *ZigLanguage) bool {
        return false;
    }
    pub fn _supportsDocumentation(_: *ZigLanguage) bool {
        return false;
    }
    pub fn _canInheritFromFile(_: *ZigLanguage) bool {
        return false;
    }
    /// Global classes of type `ZigScript` are ours, as GDScript claims
    /// `GDScript` (modules/gdscript/gdscript.cpp, `handles_global_class_type`).
    pub fn _handlesGlobalClassType(_: *ZigLanguage, class_type: String) bool {
        var buf: [16]u8 = undefined;
        const t = props.stringText(&class_type, &buf) orelse return false;
        return std.mem.eql(u8, t, "ZigScript");
    }
    /// The global class the file at `path` declares: `name`, `base_type`,
    /// `icon_path`, `is_abstract` and `is_tool`, the keys
    /// `get_global_class_name` reads (core/object/script_language_extension.h:
    /// 655-676). No `name` key when it declares none. Runs on the editor's
    /// file-scan thread: reads the file with std, scans the text
    /// (`global_class.scan`) and makes no engine value besides the returned
    /// Strings and Dictionary.
    pub fn _getGlobalClassName(_: *ZigLanguage, path: String) Dictionary {
        const text = readScript(&path) orelse return .init();
        defer gpa.free(text);
        const info = global_class.scan(text) orelse return .init();
        return classDict(info);
    }

    // ------------------------------------------------------------ editor

    pub fn _findFunction(_: *ZigLanguage, _: String, _: String) i64 {
        return -1;
    }
    pub fn _makeFunction(_: *ZigLanguage, _: String, _: String, _: PackedStringArray) String {
        return .init();
    }
    pub fn _canMakeFunction(_: *ZigLanguage) bool {
        return false;
    }
    pub fn _openInExternalEditor(_: *ZigLanguage, _: ?*Script, _: i64, _: i64) Error {
        return .err_unavailable;
    }
    pub fn _overridesExternalEditor(_: *ZigLanguage) bool {
        return false;
    }
    /// No suggestions: `result` OK with empty `options`, `force` false and
    /// an empty `call_hint`, every key `complete_code` checks
    /// (core/object/script_language_extension.h:391-439), so nothing is
    /// printed while the user types.
    pub fn _completeCode(_: *ZigLanguage, _: String, _: String, _: ?*Object) Dictionary {
        var d: Dictionary = .init();
        dictSetInt(&d, "result", @backingInt(Error.ok));
        var options: Array = .init();
        defer options.deinit();
        dictSetVariant(&d, "options", .init(Array, options));
        dictSetBool(&d, "force", false);
        dictSetString(&d, "call_hint", "");
        return d;
    }
    /// Nothing found: `result` ERR_UNAVAILABLE with a `type`, the keys
    /// `lookup_code` checks (script_language_extension.h:441-460), so
    /// nothing is printed. Not OK: the script editor takes OK as a found
    /// symbol, jumps to a line and marks the word as a link
    /// (script_text_editor.cpp:1208, 1319-1320).
    pub fn _lookupCode(_: *ZigLanguage, _: String, _: String, _: String, _: ?*Object) Dictionary {
        var d: Dictionary = .init();
        dictSetInt(&d, "result", @backingInt(Error.err_unavailable));
        dictSetInt(&d, "type", 0);
        return d;
    }
    /// Returns the input unchanged (a copy: the argument is borrowed).
    pub fn _autoIndentCode(_: *ZigLanguage, code: String, _: i64, _: i64) String {
        return .copy(code);
    }

    // ------------------------------------------------------------ globals and reload

    /// An autoload in a running game (main/main.cpp:4509, 4557): remembered
    /// by name. Required in 4.7.2, or the game logs an error per autoload.
    pub fn _addGlobalConstant(self: *ZigLanguage, name: StringName, _: Variant) void {
        self.addGlobal(name);
    }
    /// An autoload in the editor (editor_autoload_settings.cpp:385, 579,
    /// 869): remembered by name.
    pub fn _addNamedGlobalConstant(self: *ZigLanguage, name: StringName, _: Variant) void {
        self.addGlobal(name);
    }
    /// An autoload removed in the editor (editor_autoload_settings.cpp:547).
    pub fn _removeNamedGlobalConstant(self: *ZigLanguage, name: StringName) void {
        var buf: [max_name_bytes]u8 = undefined;
        const n = props.nameText(name, &buf) orelse return;
        self.globals_mu.lockUncancelable(host_io.get());
        defer self.globals_mu.unlock(host_io.get());
        const kv = self.globals.fetchRemove(n) orelse return;
        gpa.free(kv.key);
    }
    /// Also fires when any other extension reloads (spec section 7).
    pub fn _reloadAllScripts(self: *ZigLanguage) void {
        self.noteReload(.all);
    }
    /// Godot calls this with this language's own scripts only (for
    /// example `Script::reload_from_file` when the editor discards edits),
    /// so each listed script gets its text back from its file.
    pub fn _reloadScripts(self: *ZigLanguage, scripts: Array, _: bool) void {
        self.noteReload(.scripts);
        var i: i64 = 0;
        while (i < scripts.size()) : (i += 1) {
            var v = scripts.get(i);
            defer v.deinit();
            script.ZigScript.reloadObjectFromDisk(v.as(*Object) orelse continue);
        }
    }
    pub fn _reloadToolScript(self: *ZigLanguage, s: ?*Script, _: bool) void {
        self.noteReload(.tool);
        if (s) |sc| script.ZigScript.reloadObjectFromDisk(Object.upcast(sc));
    }
    pub fn _getPublicFunctions(_: *ZigLanguage) Array {
        return .init();
    }
    pub fn _getPublicConstants(_: *ZigLanguage) Dictionary {
        return .init();
    }
    pub fn _getPublicAnnotations(_: *ZigLanguage) Array {
        return .init();
    }

    // ------------------------------------------------------------ debugger

    pub fn _debugGetError(_: *ZigLanguage) String {
        return .init();
    }
    pub fn _debugGetStackLevelCount(_: *ZigLanguage) i64 {
        return 0;
    }
    pub fn _debugGetStackLevelLine(_: *ZigLanguage, _: i64) i64 {
        return -1;
    }
    pub fn _debugGetStackLevelFunction(_: *ZigLanguage, _: i64) String {
        return .init();
    }
    pub fn _debugGetStackLevelSource(_: *ZigLanguage, _: i64) String {
        return .init();
    }
    pub fn _debugGetStackLevelLocals(_: *ZigLanguage, _: i64, _: i64, _: i64) Dictionary {
        return .init();
    }
    pub fn _debugGetStackLevelMembers(_: *ZigLanguage, _: i64, _: i64, _: i64) Dictionary {
        return .init();
    }
    pub fn _debugGetStackLevelInstance(_: *ZigLanguage, _: i64) ?*anyopaque {
        return null;
    }
    pub fn _debugGetGlobals(_: *ZigLanguage, _: i64, _: i64) Dictionary {
        return .init();
    }
    pub fn _debugParseStackLevelExpression(_: *ZigLanguage, _: i64, _: String, _: i64, _: i64) String {
        return .init();
    }
    /// Lock-free and creates no StringName (spec section 2: Godot calls it
    /// from any thread while holding its own locks).
    pub fn _debugGetCurrentStackInfo(_: *ZigLanguage) Array {
        return .init();
    }

    // ------------------------------------------------------------ profiler

    pub fn _profilingStart(_: *ZigLanguage) void {}
    pub fn _profilingStop(_: *ZigLanguage) void {}
    pub fn _profilingSetSaveNativeCalls(_: *ZigLanguage, _: bool) void {}
    pub fn _profilingGetAccumulatedData(_: *ZigLanguage, _: ?*anyopaque, _: i64) i64 {
        return 0;
    }
    pub fn _profilingGetFrameData(_: *ZigLanguage, _: ?*anyopaque, _: i64) i64 {
        return 0;
    }

    // ------------------------------------------------------------ helpers

    fn addGlobal(self: *ZigLanguage, name: StringName) void {
        var buf: [max_name_bytes]u8 = undefined;
        const n = props.nameText(name, &buf) orelse return;
        self.globals_mu.lockUncancelable(host_io.get());
        defer self.globals_mu.unlock(host_io.get());
        if (self.globals.contains(n)) return;
        const key = gpa.dupe(u8, n) catch return;
        self.globals.put(gpa, key, {}) catch gpa.free(key);
    }

    /// Counts a reload request and logs the first of its kind. Zig scripts
    /// run the last build's module; the build, not this request, makes a
    /// new one, so nothing else happens here (spec section 6: reload
    /// requests only queue).
    fn noteReload(self: *ZigLanguage, kind: Reload) void {
        _ = self.reloads.getPtr(kind).fetchAdd(1, .acq_rel);
        if (self.reload_logged.getPtr(kind).swap(true, .acq_rel)) return;
        const what = switch (kind) {
            .all => "reload all scripts",
            .scripts => "reload scripts",
            .tool => "reload a tool script",
        };
        log("Ziggurat: Godot asked to {s}; Zig scripts change when a build finishes, not on this request (logged once).", .{what});
    }
};

// ------------------------------------------------------------ module helpers

/// The dictionary `_get_global_class_name` returns for `info`. Any thread,
/// once `warmScanPath` has run.
fn classDict(info: global_class.Info) Dictionary {
    var d: Dictionary = .init();
    dictSetString(&d, "name", info.name);
    dictSetString(&d, "base_type", info.base_type);
    dictSetString(&d, "icon_path", "");
    dictSetBool(&d, "is_abstract", false);
    dictSetBool(&d, "is_tool", info.is_tool);
    return d;
}

/// Resolves, on the main thread, every lazy gdzig function pointer the
/// `_get_global_class_name` path uses, so the file-scan thread never
/// resolves one first. `Dictionary.set` looks its method up by a
/// StringName ("set") on first use, which the scan thread must not create
/// (spec section 2). The others need no StringName but are warmed too:
/// the Dictionary constructor and destructor, the Variant-from-type
/// constructors for String, bool and int, and the Variant and String
/// destructors. `props.stringText` and `String.fromUtf8`/`fromLatin1` call
/// interface functions directly and need no warming. Called from `_init`.
fn warmScanPath() void {
    var d = classDict(.{ .name = "Warm", .base_type = "Object", .is_tool = true });
    d.deinit();
}

/// Records the project folder (`res://` globalized). Main thread, in
/// `_init`, before the editor's file scan starts.
fn setProjectRoot() void {
    var res: String = .fromLatin1("res://");
    defer res.deinit();
    var abs = ProjectSettings.globalizePath(res);
    defer abs.deinit();
    const root = props.stringText(&abs, &project_root_buf) orelse return;
    const trimmed = std.mem.trimEnd(u8, root, "/");
    if (trimmed.len == 0 or !std.fs.path.isAbsolute(trimmed)) return;
    project_root.store(trimmed.len, .release);
}

/// The text of the script at resource path `path`, read with std (C
/// allocator, caller frees), or null: not a `res://` path inside the
/// project, unreadable, or bigger than `global_class.max_file_bytes`. Any
/// thread.
fn readScript(path: *const String) ?[:0]u8 {
    const root_len = project_root.load(.acquire);
    if (root_len == 0) return null;
    var res_buf: [max_path_bytes]u8 = undefined;
    const res = props.stringText(path, &res_buf) orelse return null;
    var rel_buf: [max_path_bytes]u8 = undefined;
    const rel = script.relPath(res, &rel_buf) orelse return null;
    var abs_buf: [2 * max_path_bytes + 1]u8 = undefined;
    const abs = std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ project_root_buf[0..root_len], rel }) catch return null;
    const io = host_io.get();
    return std.Io.Dir.cwd().readFileAllocOptions(io, abs, gpa, .limited(global_class.max_file_bytes), .of(u8), 0) catch null;
}

/// A copy of the diagnostics recorded for the script at resource path
/// `path` (free with `diag_cache.freeList(gpa, ...)`), or null when none are
/// known or the copy cannot be made.
fn cachedDiagnostics(path: *const String) ?[]diag_cache.Diagnostic {
    var res_buf: [max_path_bytes]u8 = undefined;
    const res = props.stringText(path, &res_buf) orelse return null;
    var rel_buf: [max_path_bytes]u8 = undefined;
    const rel = script.relPath(res, &rel_buf) orelse return null;
    return diag_cache.get(gpa, rel) catch null;
}

/// The new script's text (`template.make`) as a Godot String.
fn templateText(content: String, class_name: String, base_class_name: String) Allocator.Error!String {
    const c = try props.utf8Alloc(gpa, &content);
    defer gpa.free(c);
    const n = try props.utf8Alloc(gpa, &class_name);
    defer gpa.free(n);
    const b = try props.utf8Alloc(gpa, &base_class_name);
    defer gpa.free(b);
    const kind: template.Base = if (!global_class.isIdentifier(b)) .unknown else blk: {
        var sn = StringName.fromUtf8(b);
        defer sn.deinit();
        if (!ClassDb.classExists(sn)) break :blk .unknown;
        var node = StringName.fromUtf8("Node");
        defer node.deinit();
        break :blk if (ClassDb.isParentClass(sn, node)) .node else .other;
    };
    const text = try template.make(gpa, c, n, b, kind);
    defer gpa.free(text);
    return String.fromUtf8(text) catch .fromLatin1("");
}

/// Prints one line to Godot's output.
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

/// Sets d[key] = value and releases `value`.
fn dictSetVariant(d: *Dictionary, comptime key: []const u8, value: Variant) void {
    const k = keyVariant(key);
    defer k.deinit();
    defer value.deinit();
    _ = d.set(k, value);
}

/// Sets d[key] = the String of UTF-8 `value`.
fn dictSetString(d: *Dictionary, comptime key: []const u8, value: []const u8) void {
    var s = props.gstring(value);
    defer s.deinit();
    dictSetVariant(d, key, .init(String, s));
}

/// Sets d[key] = value.
fn dictSetBool(d: *Dictionary, comptime key: []const u8, value: bool) void {
    const k = keyVariant(key);
    defer k.deinit();
    _ = d.set(k, .init(bool, value));
}

/// Sets d[key] = value.
fn dictSetInt(d: *Dictionary, comptime key: []const u8, value: i64) void {
    const k = keyVariant(key);
    defer k.deinit();
    _ = d.set(k, .init(i64, value));
}

/// An owned String Variant (the caller deinits it).
fn keyVariant(comptime key: []const u8) Variant {
    var s: String = .fromLatin1(key);
    defer s.deinit();
    return .init(String, s);
}
