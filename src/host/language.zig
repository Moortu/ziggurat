//! `ZigLanguage`: the Zig script language (spec section 7).
//!
//! Skeleton: every `ScriptLanguageExtension` virtual is implemented, so the
//! engine never reports a missing required method and gdzig's virtual lookup
//! is measured at its full size (`vendor/gdzig/PATCHES.md`). Most bodies
//! return safe empty values; later tasks fill them in. Rules kept even here:
//! `_make_template` never returns null, `_auto_indent_code` returns its input
//! unchanged, and `_debug_get_current_stack_info` takes no lock and creates no
//! StringName.
const std = @import("std");
const godot = @import("gdzig");
const script = @import("script.zig");

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
const Error = godot.global.Error;

/// The registered language, between SCENE init and SCENE exit (set by the
/// entry). Scripts return it from `_get_language`.
pub var registered: ?*ZigLanguage = null;

pub const ZigLanguage = struct {
    base: *ScriptLanguageExtension,

    pub fn create(allocator: *Allocator) !*ZigLanguage {
        const self = try allocator.create(ZigLanguage);
        self.* = .{ .base = ScriptLanguageExtension.init() };
        self.base.setInstance(ZigLanguage, self);
        return self;
    }

    pub fn destroy(self: *ZigLanguage, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
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
    pub fn _init(_: *ZigLanguage) void {
        script.loadStartupCache();
    }
    pub fn _finish(_: *ZigLanguage) void {}
    pub fn _frame(_: *ZigLanguage) void {}
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
        return false;
    }
    pub fn _getBuiltInTemplates(_: *ZigLanguage, _: StringName) Array {
        return .init();
    }
    /// A `ZigScript` holding the template text. Never null: the Create
    /// Script dialog dereferences the result, so when the script cannot be
    /// made a bare `ScriptExtension` stands in. The one counted reference
    /// goes to the `Ref<Script>` Godot reads the pointer into.
    pub fn _makeTemplate(_: *ZigLanguage, template: String, _: String, _: String) ?*Script {
        const s = script.ZigScript.withSource(template) orelse return .upcast(ScriptExtension.init());
        return .upcast(s.base);
    }
    pub fn _validate(_: *ZigLanguage, _: String, _: String, _: bool, _: bool, _: bool, _: bool) Dictionary {
        var d: Dictionary = .init();
        dictSetBool(&d, "valid", true);
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
    pub fn _handlesGlobalClassType(_: *ZigLanguage, _: String) bool {
        return false;
    }
    /// No `name` key: the file declares no global class.
    pub fn _getGlobalClassName(_: *ZigLanguage, _: String) Dictionary {
        return .init();
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
    /// No `result` key: Godot treats completion as unavailable.
    pub fn _completeCode(_: *ZigLanguage, _: String, _: String, _: ?*Object) Dictionary {
        return .init();
    }
    /// `result` ERR_UNAVAILABLE with a `type`, so Godot reports nothing.
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

    pub fn _addGlobalConstant(_: *ZigLanguage, _: StringName, _: Variant) void {}
    pub fn _addNamedGlobalConstant(_: *ZigLanguage, _: StringName, _: Variant) void {}
    pub fn _removeNamedGlobalConstant(_: *ZigLanguage, _: StringName) void {}
    pub fn _reloadAllScripts(_: *ZigLanguage) void {}
    pub fn _reloadScripts(_: *ZigLanguage, _: Array, _: bool) void {}
    pub fn _reloadToolScript(_: *ZigLanguage, _: ?*Script, _: bool) void {}
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
};

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
