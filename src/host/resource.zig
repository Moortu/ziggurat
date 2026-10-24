//! The `.zig` resource format loader and saver (spec section 7, "Resource
//! loader and saver"). They let Godot open, list, load and save Zig scripts
//! like any script file: the file system dock, the script editor, scenes
//! that name a `.zig` script and the Create Script dialog all go through
//! `ResourceLoader` and `ResourceSaver`.
//!
//! The loader reads the file text and returns a new `ZigScript` that holds
//! it. It has no side effects: no build, no module call, no global state, no
//! cache write. Godot sets the script's path after a load that uses the
//! resource cache; for `CACHE_MODE_IGNORE` and `IGNORE_DEEP` the loader sets
//! it with `set_path_cache` (no cache registration). The script is returned
//! even when the text does not compile. Godot may call the loader from
//! worker threads (threaded loads, the scan); it only uses `FileAccess`
//! and creates one object.
//!
//! In an export build the `.zig` files are not in the game (spec section
//! 10): the scripts are linked into the host's library, and the loader
//! answers from the linked table instead of the file system. `_exists` is
//! true exactly for the table's script paths, and `_load` returns a
//! `ZigScript` with no source text for such a path without reading any
//! file. Any other `.zig` path fails with `ERR_FILE_NOT_FOUND` and one
//! error line.
//!
//! The saver writes the script's source text to a temporary file in the
//! target's folder, flushes it, renames it over the target and flushes the
//! folder, so a reader sees the old file or the new one, never half of
//! either. It then calls `on_saved` (set by the build trigger) with the
//! project-relative path.
//!
//! Indentation: the script editor rewrites leading spaces to tabs when it
//! saves (`text_editor/behavior/files/convert_indent_on_save`). The Zig 0.17
//! compiler accepts tab indentation (host test "tabs compile or are
//! converted" builds a tab-indented script with the real SDK), so the saver
//! writes the text exactly as the script holds it.
const std = @import("std");
const godot = @import("gdzig");
const platform = @import("ziggurat_platform");
const host_options = @import("host_options");
const host_io = @import("host_io.zig");
const props = @import("props.zig");
const runtime = @import("runtime.zig");
const script = @import("script.zig");

const Allocator = std.mem.Allocator;
const Error = godot.global.Error;
const FileAccess = godot.class.FileAccess;
const Object = godot.class.Object;
const PackedStringArray = godot.builtin.PackedStringArray;
const ProjectSettings = godot.class.ProjectSettings;
const RefCounted = godot.class.RefCounted;
const Resource = godot.class.Resource;
const ResourceFormatLoader = godot.class.ResourceFormatLoader;
const ResourceFormatSaver = godot.class.ResourceFormatSaver;
const ResourceLoader = godot.class.ResourceLoader;
const ResourceSaver = godot.class.ResourceSaver;
const Script = godot.class.Script;
const ScriptExtension = godot.class.ScriptExtension;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const ZigScript = script.ZigScript;

/// `ResourceFormatLoader.CacheMode` values that skip the resource cache.
const cache_mode_ignore = 0;
const cache_mode_ignore_deep = 3;

/// Longest path handled; a longer one is refused as a bad path.
const max_path_bytes = 4096;

/// Called after every successful save of a script under `res://`, with the
/// project-relative path (`player.zig`, `sub/folder/enemy.zig`). Null until
/// the build trigger sets it, on the main thread, before any script is
/// saved (`editor_build.start`; `editor_build.stop` clears it again). It runs
/// on the thread that saved, usually the main thread, so it may only queue
/// work.
pub const SavedHook = *const fn (path: []const u8) void;
pub var on_saved: std.atomic.Value(?SavedHook) = .init(null);

/// True when `path` names a `.zig` file. Godot compares extensions without
/// regard to case.
fn isZigPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".zig");
}

fn extensionList() PackedStringArray {
    var list: PackedStringArray = .init();
    var ext: String = .fromLatin1("zig");
    defer ext.deinit();
    _ = list.pushBack(ext);
    return list;
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    logErrorIn("ZigSaver", fmt, args);
}

fn logErrorIn(comptime function: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [max_path_bytes + 256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printError(msg.ptr, function, "src/host/resource.zig", @src().line, 1);
}

/// What an export build's loader knows of a `.zig` path.
const Linked = enum {
    /// A script of the linked table.
    script,
    /// Not a script of the linked table (or not a project path).
    unknown,
    /// No linked generation is loaded: its table was refused.
    not_loaded,
};

/// The answer for the `res://` path `res_path` from the linked generation
/// `gen` (`runtime.current()`). The path is matched like a script's own
/// path (`script.relPath`), byte for byte with the table's paths.
fn linkedAnswer(gen: ?*const runtime.Generation, res_path: []const u8) Linked {
    const g = gen orelse return .not_loaded;
    var buf: [max_path_bytes]u8 = undefined;
    const rel = script.relPath(res_path, &buf) orelse return .unknown;
    return if (runtime.findScript(g, rel) != null) .script else .unknown;
}

// ------------------------------------------------------------ loader

/// `ResourceFormatLoader` for `.zig` files (core/io/resource_loader.h: the
/// extension class calls `_get_recognized_extensions`, `_handles_type`,
/// `_get_resource_type`, `_exists` and `_load`).
pub const ZigLoader = struct {
    base: *ResourceFormatLoader,

    pub fn create(allocator: *Allocator) !*ZigLoader {
        const self = try allocator.create(ZigLoader);
        self.* = .{ .base = ResourceFormatLoader.init() };
        self.base.setInstance(ZigLoader, self);
        return self;
    }

    pub fn destroy(self: *ZigLoader, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    pub fn _getRecognizedExtensions(_: *ZigLoader) PackedStringArray {
        return extensionList();
    }

    /// The script class and its base: `get_recognized_extensions_for_type`
    /// and a typed `load` ask for these.
    pub fn _handlesType(_: *ZigLoader, type_name: StringName) bool {
        var buf: [64]u8 = undefined;
        const t = props.nameText(type_name, &buf) orelse return false;
        return std.mem.eql(u8, t, "Script") or std.mem.eql(u8, t, "ZigScript");
    }

    pub fn _getResourceType(_: *ZigLoader, path: String) String {
        var buf: [max_path_bytes]u8 = undefined;
        const p = props.stringText(&path, &buf) orelse return .fromLatin1("");
        return .fromLatin1(if (isZigPath(p)) "ZigScript" else "");
    }

    /// True when the file can be opened; `FileAccess` also sees files in an
    /// exported project's pack. In an export build: true exactly for the
    /// linked table's script paths.
    pub fn _exists(_: *ZigLoader, path: String) bool {
        if (comptime host_options.export_build) {
            var buf: [max_path_bytes]u8 = undefined;
            const p = props.stringText(&path, &buf) orelse return false;
            return isZigPath(p) and linkedAnswer(runtime.current(), p) == .script;
        }
        return FileAccess.fileExists(path);
    }

    /// A new `ZigScript` holding the file's text, or an `Error` number as
    /// an int Variant (what Godot expects of a loader that fails).
    pub fn _load(_: *ZigLoader, path: String, original_path: String, _: bool, cache_mode: i64) Variant {
        var buf: [max_path_bytes]u8 = undefined;
        const p = props.stringText(&path, &buf) orelse return errorVariant(.err_file_bad_path);
        if (!isZigPath(p)) return errorVariant(.err_file_unrecognized);
        if (comptime host_options.export_build) return loadLinked(path, p, original_path, cache_mode);

        var text = switch (script.readFileText(path)) {
            .text => |t| t,
            .err => |e| return errorVariant(e),
        };

        var alloc = godot.engine_allocator;
        const s = ZigScript.create(&alloc) catch {
            text.deinit();
            return errorVariant(.err_out_of_memory);
        };
        s.source.deinit();
        s.source = text;
        // Lets a later build notice an edit made outside the editor.
        s.noteDisk(FileAccess.getModifiedTime(path));
        return scriptVariant(s, path, original_path, cache_mode);
    }

    /// An export build's `_load` of the `.zig` path `p` (the text of
    /// `path`): a `ZigScript` with no source text for a script of the
    /// linked table; no file is read.
    fn loadLinked(path: String, p: []const u8, original_path: String, cache_mode: i64) Variant {
        switch (linkedAnswer(runtime.current(), p)) {
            .script => {},
            .unknown => {
                logErrorIn("ZigLoader", "Ziggurat: {s} is not part of this export", .{p});
                return errorVariant(.err_file_not_found);
            },
            .not_loaded => {
                logErrorIn("ZigLoader", "Ziggurat: {s} cannot be loaded because this export's Zig scripts did not load", .{p});
                return errorVariant(.err_unavailable);
            },
        }
        var alloc = godot.engine_allocator;
        const s = ZigScript.create(&alloc) catch return errorVariant(.err_out_of_memory);
        return scriptVariant(s, path, original_path, cache_mode);
    }

    /// The Variant `_load` returns for the new script `s`.
    fn scriptVariant(s: *ZigScript, path: String, original_path: String, cache_mode: i64) Variant {
        // A load that skips the cache (IGNORE, IGNORE_DEEP) gets no path
        // from Godot, so give it one the way GDScript's loader does:
        // `set_path_cache` only remembers the path and never touches the
        // resource cache. In the other modes Godot's own `set_path` must run
        // first and register the resource, so nothing is set here.
        if (cache_mode == cache_mode_ignore or cache_mode == cache_mode_ignore_deep) {
            const keep = if (original_path.length() > 0) original_path else path;
            Resource.upcast(s.base).setPathCache(keep);
        }

        // The object starts with one counted reference. The Variant takes
        // its own; dropping the first leaves the Variant as the only owner,
        // which Godot's `Ref` then shares.
        const v = Variant.init(*ScriptExtension, s.base);
        _ = RefCounted.upcast(s.base).unreference();
        return v;
    }
};

fn errorVariant(err: Error) Variant {
    return Variant.init(i64, @backingInt(err));
}

// ------------------------------------------------------------ saver

/// `ResourceFormatSaver` for `ZigScript` (core/io/resource_saver.h:
/// `_recognize`, `_get_recognized_extensions`, `_save`).
pub const ZigSaver = struct {
    base: *ResourceFormatSaver,

    pub fn create(allocator: *Allocator) !*ZigSaver {
        const self = try allocator.create(ZigSaver);
        self.* = .{ .base = ResourceFormatSaver.init() };
        self.base.setInstance(ZigSaver, self);
        return self;
    }

    pub fn destroy(self: *ZigSaver, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    fn isZigScript(res: ?*Resource) bool {
        const r = res orelse return false;
        // A comptime StringName is never deinit'ed.
        return Object.upcast(r).isClass(.fromComptimeLatin1("ZigScript"));
    }

    pub fn _recognize(_: *ZigSaver, res: ?*Resource) bool {
        return isZigScript(res);
    }

    pub fn _getRecognizedExtensions(_: *ZigSaver, res: ?*Resource) PackedStringArray {
        return if (isZigScript(res)) extensionList() else .init();
    }

    pub fn _save(_: *ZigSaver, res: ?*Resource, path: String, _: u32) Error {
        if (!isZigScript(res)) return .err_invalid_parameter;
        const scr = Script.downcast(res.?) orelse return .err_invalid_parameter;

        var buf: [max_path_bytes]u8 = undefined;
        const res_path = props.stringText(&path, &buf) orelse return .err_file_bad_path;
        var abs = ProjectSettings.globalizePath(path);
        defer abs.deinit();
        var abs_buf: [max_path_bytes]u8 = undefined;
        const abs_path = props.stringText(&abs, &abs_buf) orelse return .err_file_bad_path;

        var src = scr.getSourceCode();
        defer src.deinit();
        const bytes = utf8Alloc(&src) catch return .err_out_of_memory;
        defer std.heap.c_allocator.free(bytes);

        platform.atomic_file.writeInFolder(host_io.get(), .fromTrusted(abs_path), bytes) catch |err| {
            logError("Cannot save {s}: {s}", .{ res_path, @errorName(err) });
            return switch (err) {
                error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .err_file_no_permission,
                else => .err_file_cant_write,
            };
        };

        // The file now holds this text (for `ZigScript.refreshFromDisk`),
        // unless the script was written to some other file.
        if (Object.upcast(res.?).asInstance(ZigScript)) |zs| {
            var own = zs.base.getPath();
            defer own.deinit();
            var own_buf: [max_path_bytes]u8 = undefined;
            const own_path = props.stringText(&own, &own_buf) orelse "";
            if (own_path.len == 0 or std.mem.eql(u8, own_path, res_path))
                zs.noteDiskText(FileAccess.getModifiedTime(path), bytes);
        }

        var rel_buf: [max_path_bytes]u8 = undefined;
        if (script.relPath(res_path, &rel_buf)) |rel| {
            if (on_saved.load(.acquire)) |hook| hook(rel);
        }
        return .ok;
    }
};

/// The bytes of `s` as UTF-8, owned by the caller (`c_allocator`).
fn utf8Alloc(s: *const String) ![]u8 {
    const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(s.constPtr(), null, 0)));
    const out = try std.heap.c_allocator.alloc(u8, n);
    if (n != 0) _ = godot.raw.stringToUtf8Chars(s.constPtr(), @ptrCast(out.ptr), @intCast(n));
    return out;
}

// ------------------------------------------------------------ registration

var loader: ?*ZigLoader = null;
var saver: ?*ZigSaver = null;

/// Adds the loader and the saver to Godot. Main thread, SCENE init, after
/// the language is registered. Godot keeps its own reference to each; ours
/// is dropped by `unregister`.
pub fn register() void {
    var alloc = godot.engine_allocator;
    const fl = ZigLoader.create(&alloc) catch {
        logError("Ziggurat: out of memory creating the .zig loader; Zig scripts cannot be loaded", .{});
        return;
    };
    ResourceLoader.addResourceFormatLoader(.upcast(fl.base), .{});
    loader = fl;
    const fs = ZigSaver.create(&alloc) catch {
        logError("Ziggurat: out of memory creating the .zig saver; Zig scripts cannot be saved", .{});
        return;
    };
    ResourceSaver.addResourceFormatSaver(.upcast(fs.base), .{});
    saver = fs;
}

/// Removes both from Godot and releases them. Main thread, SCENE exit,
/// before the language is destroyed.
pub fn unregister() void {
    if (saver) |fs| {
        ResourceSaver.removeResourceFormatSaver(.upcast(fs.base));
        release(.upcast(fs.base));
        saver = null;
    }
    if (loader) |fl| {
        ResourceLoader.removeResourceFormatLoader(.upcast(fl.base));
        release(.upcast(fl.base));
        loader = null;
    }
}

/// Drops our reference; frees the object when it was the last one. The raw
/// destroy runs gdzig's destroy callback, which frees the Zig struct.
fn release(rc: *RefCounted) void {
    if (rc.unreference()) godot.raw.objectDestroy(@ptrCast(rc));
}

test "an export build's loader answers from the linked table's paths" {
    const a = std.testing.allocator;
    var g: runtime.Generation = .{ .n = 1, .lib = null, .table = undefined, .names = &.{}, .by_path = .empty };
    defer g.by_path.deinit(a);
    try g.by_path.put(a, "alpha.zig", 0);
    try g.by_path.put(a, "sub/beta.zig", 1);
    for ([_][]const u8{ "res://alpha.zig", "res://sub/beta.zig", "res://./alpha.zig", "res://sub/../alpha.zig", "res://sub//beta.zig" }) |p| {
        try std.testing.expectEqual(Linked.script, linkedAnswer(&g, p));
    }
    // Paths are case-sensitive; only `res://` paths inside the project.
    for ([_][]const u8{ "res://nope.zig", "res://Alpha.zig", "res://beta.zig", "res://sub", "user://alpha.zig", "alpha.zig", "res://../alpha.zig", "res://" }) |p| {
        try std.testing.expectEqual(Linked.unknown, linkedAnswer(&g, p));
    }
    try std.testing.expectEqual(Linked.not_loaded, linkedAnswer(null, "res://alpha.zig"));
}
