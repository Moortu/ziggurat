//! `ZigExportPlugin`: builds an exported game's Zig scripts (spec section
//! 10). It is an `EditorExportPlugin` (a RefCounted), registered at the
//! EDITOR level like the editor plugin and never exposed. `ZigEditorPlugin`
//! creates one in `_enterTree` and hands it to the editor with
//! `add_export_plugin` (`attach`); `_exitTree` takes it back (`detach`).
//! An export build has none of this.
//!
//! Godot calls every export plugin's `_export_begin` before it writes
//! anything (the `ExportNotifier` of every export: binary, pack or zip).
//! For a preset whose features include `linux` and `x86_64` the plugin
//! first deletes the game library `lib_res_path`, so a library of an
//! earlier export can never ship (when the delete fails it empties the
//! file, so the exported game fails at load; when that fails too, the
//! error says the export would ship the old library), then:
//!   - with Zig scripts (the build service's scan, which leaves out
//!     `addons/`), it runs the export build (`export_build.run`, blocking,
//!     with progress lines). The build uses the Zig and SDK editor builds
//!     use (`editor_build.exportInputs`), the export host archive next to
//!     the editor library (`archive_file`), and the editor's per-user cache
//!     folder, so it takes turns with editor builds on the project's
//!     `build.lock`; it writes the library only when the build and the
//!     library's checks pass.
//!   - without Zig scripts, it copies the add-on's empty game library
//!     (`empty_lib_file`, next to the editor library: the export host
//!     linked with no scripts), so such a project exports without Zig.
//! Any failure goes to the export platform's message list as an error
//! (`add_message`, which also prints it) that ends with `incomplete_note`. An error message alone does not
//! stop Godot's export, but the library stays missing, and Godot's
//! GDExtension export then fails to copy it ("Failed to copy shared
//! object"), so the export fails (a headless export exits with status 1).
//! Other presets get the error message `platform_message`.
//!
//! The `.gdextension` names the game library for the `template_debug` and
//! `template_release` features, so Godot's own GDExtension export plugin
//! copies it next to the exported binary. `_export_file` skips every
//! `.zig` file: no source reaches the pack; the game's loader answers the
//! script paths from the linked table.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const editor_build = @import("editor_build.zig");
const entry = @import("entry.zig");
const host_io = @import("host_io.zig");
const props = @import("props.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const PackedStringArray = godot.builtin.PackedStringArray;
const ProjectSettings = godot.class.ProjectSettings;
const EditorPlugin = godot.class.EditorPlugin;
const EditorExportPlugin = godot.class.EditorExportPlugin;
const EditorExportPlatform = godot.class.EditorExportPlatform;
const RefCounted = godot.class.RefCounted;
const MessageType = EditorExportPlatform.ExportMessageType;
const export_build = zbuild.export_build;

/// The plugin's name (`_get_name`) and its messages' category.
pub const plugin_name = "Ziggurat";
/// The error message for a preset that is not Linux x86_64.
pub const platform_message = "Ziggurat exports Linux x86_64 only in this version";
/// Where the export writes the game library; the `.gdextension`'s template
/// keys name this path.
pub const lib_rel = ".godot/ziggurat/export/linux.x86_64/" ++ export_build.lib_file;
pub const lib_res_path = "res://" ++ lib_rel;
/// The add-on's export inputs, next to the editor library.
pub const archive_file = "libziggurat_host_export.a";
pub const empty_lib_file = "libziggurat_game_empty.so";
/// The end of every error after which the export fails: Godot has
/// already written the game executable and its pack.
pub const incomplete_note = "This export fails: the files in the export's output folder are incomplete.";
/// How long an export waits for an editor build of the same project.
const lock_timeout_ms = 120_000;
/// Compile errors listed as messages; the rest are counted.
const max_listed = 50;

const gpa = std.heap.c_allocator;

pub const ZigExportPlugin = struct {
    base: *EditorExportPlugin,

    pub fn create(allocator: *Allocator) !*ZigExportPlugin {
        const self = try allocator.create(ZigExportPlugin);
        self.* = .{ .base = EditorExportPlugin.init() };
        self.base.setInstance(ZigExportPlugin, self);
        return self;
    }

    /// Called by gdzig's free callback when Godot frees the object (the
    /// last reference dropped, see `detach`).
    pub fn destroy(self: *ZigExportPlugin, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    pub fn _getName(_: *ZigExportPlugin) String {
        return .fromLatin1(plugin_name);
    }

    /// Every platform: the plugin reports the unsupported ones itself
    /// (`_export_begin`), and false would add Godot's "not supported"
    /// warning on top.
    pub fn _supportsPlatform(_: *ZigExportPlugin, _: ?*EditorExportPlatform) bool {
        return true;
    }

    pub fn _exportBegin(self: *ZigExportPlugin, features: PackedStringArray, _: bool, _: String, _: u32) void {
        exportBegin(self, &features);
    }

    /// Leaves every `.zig` file out of the export.
    pub fn _exportFile(self: *ZigExportPlugin, path: String, _: String, _: PackedStringArray) void {
        const text = props.utf8Alloc(gpa, &path) catch {
            // Without the text the extension is read through Godot.
            var ext = path.getExtension();
            defer ext.deinit();
            var buf: [8]u8 = undefined;
            const e = props.stringText(&ext, &buf) orelse return;
            if (std.ascii.eqlIgnoreCase(e, "zig")) self.base.skip();
            return;
        };
        defer gpa.free(text);
        if (isZigPath(text)) self.base.skip();
    }
};

/// True for a path ending in `.zig` (any case).
pub fn isZigPath(p: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(p, ".zig");
}

/// True when `features` holds `name`.
fn hasFeature(features: *const PackedStringArray, comptime name: []const u8) bool {
    var i: i64 = 0;
    while (i < features.size()) : (i += 1) {
        var f = features.get(i);
        defer f.deinit();
        var buf: [name.len + 1]u8 = undefined;
        const text = props.stringText(&f, &buf) orelse continue;
        if (std.mem.eql(u8, text, name)) return true;
    }
    return false;
}

fn exportBegin(self: *ZigExportPlugin, features: *const PackedStringArray) void {
    // A `Ref` return: the reference is the caller's.
    const plat = self.base.getExportPlatform();
    defer if (plat) |x| editor_build.releaseRef(x);
    const r: Reporter = .{ .platform = plat };
    if (!hasFeature(features, "linux") or !hasFeature(features, "x86_64")) {
        r.err("{s}", .{platform_message});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    buildGameLibrary(arena_state.allocator(), r) catch r.fail("Ziggurat cannot build the game library for the export: out of memory.", .{});
}

fn buildGameLibrary(a: Allocator, r: Reporter) Allocator.Error!void {
    const io = host_io.get();
    const cwd = std.Io.Dir.cwd();
    var msg: std.ArrayList(u8) = .empty;
    const project = editor_build.projectRoot(a, &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => return r.fail("Ziggurat cannot build the game library for the export: {s}", .{msg.items}),
    };
    const out: platform.path.OsPath = .fromTrusted(try std.fs.path.join(a, &.{ project, lib_rel }));

    // Never ship an old library: from here on it exists only when this
    // export wrote it.
    cwd.deleteFile(io, out.bytes) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return oldLibraryStays(r, out.bytes, err),
    };

    const sc = zbuild.scan.scan(a, io, .fromTrusted(project), zbuild.scan.default_script_dirs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return r.fail("Ziggurat cannot build the game library for the export: scanning the project folder {s} failed ({t}).", .{ project, err }),
    };
    const bin = addonBinDir(a) orelse
        return r.fail("Ziggurat cannot build the game library for the export: the path of its own library is unknown.", .{});

    if (sc.scripts.len == 0) {
        const empty = try std.fs.path.join(a, &.{ bin, empty_lib_file });
        cwd.copyFile(empty, cwd, out.bytes, io, .{ .make_path = true, .replace = true }) catch |err|
            return r.fail("Ziggurat cannot copy the game library for a project without Zig scripts from {s} to {s} ({t}); reinstall the add-on.", .{ empty, out.bytes, err });
        log("Ziggurat: the project has no Zig scripts; the export uses the add-on's game library without scripts.", .{});
        return;
    }

    const archive: platform.path.OsPath = .fromTrusted(try std.fs.path.join(a, &.{ bin, archive_file }));
    cwd.access(io, archive.bytes, .{}) catch |err|
        return r.fail("Ziggurat cannot build the game library for the export: the export host archive {s} is missing ({t}); reinstall the add-on.", .{ archive.bytes, err });
    const in = editor_build.exportInputs(a, project, &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => return r.fail("Ziggurat cannot build the game library for the export: {s}", .{msg.items}),
    };

    log("Ziggurat: building the game library for the export ({d} Zig scripts, Zig {s} at {s})...", .{ sc.scripts.len, in.zig.version, in.zig.exe.bytes });
    const t0 = std.Io.Clock.awake.now(io);
    var diag: [256]u8 = undefined;
    const res = export_build.run(gpa, io, .{
        .zig = in.zig,
        .project_root = .fromTrusted(project),
        .sdk = in.sdk,
        .host_archive = archive,
        .out_path = out,
        .cache_dir = in.cache_dir,
        .lock_timeout_ms = lock_timeout_ms,
    }, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return r.fail("The Zig build for the export failed: {s}", .{platform.elf.diagText(&diag)}),
    };
    defer res.deinit(gpa);
    const ms = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    if (res.ok) {
        // Only the scan's problems remain: they did not fail the build.
        for (res.diagnostics) |d| r.diagnostic(.export_message_warning, d);
        log("Ziggurat: export library built in {d} ms: {s}", .{ ms, out.bytes });
        return;
    }
    for (res.diagnostics[0..@min(res.diagnostics.len, max_listed)]) |d| r.diagnostic(.export_message_error, d);
    if (res.diagnostics.len > max_listed) r.err("{d} more errors are not listed.", .{res.diagnostics.len - max_listed});
    if (res.message) |m| {
        r.fail("The Zig build for the export failed: {s} The game library was not written.", .{m});
    } else {
        r.fail("The Zig build for the export failed with the errors above. The game library was not written.", .{});
    }
}

/// An old game library that could not be deleted must not ship: it is
/// emptied, so the exported game fails at load instead of running scripts
/// of an earlier export. When even that fails, the message says the export
/// would ship the old library.
fn oldLibraryStays(r: Reporter, path: []const u8, err: anyerror) void {
    const io = host_io.get();
    if (std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true })) |f| {
        f.close(io);
        return r.fail("Ziggurat cannot delete the game library of an earlier export {s} ({t}), so it emptied it: the exported game cannot load its Zig scripts. Delete the file and export again.", .{ path, err });
    } else |trunc_err| {
        return r.fail("Ziggurat cannot delete or empty the game library of an earlier export {s} ({t}, {t}): this export would ship that old library with the scripts of an earlier export. Delete the file and export again.", .{ path, err, trunc_err });
    }
}

/// The folder of the host's own library (`addons/ziggurat/bin`), allocated
/// with `a`, or null when Godot does not know it.
fn addonBinDir(a: Allocator) ?[]const u8 {
    var s: String = undefined;
    godot.raw.getLibraryPath(entry.library, @ptrCast(&s));
    defer s.deinit();
    var abs = ProjectSettings.globalizePath(s);
    defer abs.deinit();
    const text = props.utf8Alloc(a, &abs) catch return null;
    const dir = std.fs.path.dirname(text) orelse return null;
    return if (dir.len == 0) null else dir;
}

/// Sends messages to the export platform's list (category `plugin_name`);
/// without a platform they are printed as errors.
const Reporter = struct {
    platform: ?*EditorExportPlatform,

    fn err(r: Reporter, comptime fmt: []const u8, args: anytype) void {
        r.send(.export_message_error, fmt, args);
    }

    /// An error after which the export fails (or ships no working game
    /// library); the message ends with `incomplete_note`.
    fn fail(r: Reporter, comptime fmt: []const u8, args: anytype) void {
        r.send(.export_message_error, fmt ++ " " ++ incomplete_note, args);
    }

    fn send(r: Reporter, kind: MessageType, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(gpa, fmt, args) catch return r.sendText(kind, "Ziggurat cannot report an export problem: out of memory.");
        defer gpa.free(text);
        r.sendText(kind, text);
    }

    fn sendText(r: Reporter, kind: MessageType, text: []const u8) void {
        var s = String.fromUtf8(text) catch String.fromLatin1(text);
        defer s.deinit();
        if (r.platform) |p| {
            var category = String.fromLatin1(plugin_name);
            defer category.deinit();
            p.addMessage(kind, category, s);
            return;
        }
        godot.general.pushError(.init(String, s), .{});
    }

    /// One diagnostic as `res://<file>:<line>:<column>: <message>`
    /// (`res://<file>: <message>` without a line).
    fn diagnostic(r: Reporter, kind: MessageType, d: export_build.Diagnostic) void {
        if (d.rel) |rel| {
            if (d.line == 0) return r.send(kind, "res://{s}: {s}", .{ rel, d.message });
            return r.send(kind, "res://{s}:{d}:{d}: {s}", .{ rel, d.line, d.column, d.message });
        }
        r.send(kind, "{s}", .{d.message});
    }
};

/// The plugin while the editor plugin is in the tree; this module holds one
/// counted reference to it. Main thread.
var current: ?*ZigExportPlugin = null;

/// Creates the plugin and hands it to the editor (`ZigEditorPlugin`'s
/// `_enterTree`). Main thread.
pub fn attach(editor_plugin: *EditorPlugin) void {
    comptime std.debug.assert(!host_options.export_build);
    if (current != null) return;
    var alloc = godot.engine_allocator;
    const plugin = ZigExportPlugin.create(&alloc) catch {
        log("Ziggurat cannot export Zig scripts: out of memory.", .{});
        return;
    };
    // `init` gave this module one counted reference; the editor takes its
    // own.
    editor_plugin.addExportPlugin(plugin.base);
    current = plugin;
}

/// Takes the plugin back from the editor and drops this module's
/// reference (`ZigEditorPlugin`'s `_exitTree`). Main thread.
pub fn detach(editor_plugin: *EditorPlugin) void {
    comptime std.debug.assert(!host_options.export_build);
    const plugin = current orelse return;
    current = null;
    editor_plugin.removeExportPlugin(plugin.base);
    const rc = RefCounted.upcast(plugin.base);
    if (rc.unreference()) godot.raw.objectDestroy(@ptrCast(rc));
}

/// Adds the class registry entry: EDITOR level (its parent exists only
/// from there), not exposed.
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    _ = registry.createClass(ZigExportPlugin, registry.allocator, .{ .level = .editor, .is_exposed = false });
}

fn log(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(msg);
    var s = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

test "isZigPath" {
    try std.testing.expect(isZigPath("res://a/b.zig"));
    try std.testing.expect(isZigPath("res://B.ZIG"));
    try std.testing.expect(!isZigPath("res://a.zig.uid"));
    try std.testing.expect(!isZigPath("res://zig"));
    try std.testing.expect(!isZigPath("res://a.gdextension"));
}
