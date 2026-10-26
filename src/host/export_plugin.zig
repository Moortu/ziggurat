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
//! file and removes its permissions, so Godot cannot copy it and the
//! export fails; when that fails too, the error says what the export
//! ships). A full export also deletes the game library in its output
//! folder, so a failed export does not leave the previous one's library
//! next to the new game files. Then:
//!   - with Zig scripts (the build service's scan, which leaves out
//!     `addons/`), it runs the export build (`export_build.run`, blocking,
//!     with progress lines). The build uses the Zig and SDK editor builds
//!     use (`editor_build.exportInputs`), the export host archive next to
//!     the editor library (`archive_file`), and the editor's per-user cache
//!     folder, so it takes turns with editor builds on the project's
//!     `build.lock`; it writes the library only when the build and the
//!     library's checks pass. A release export builds it without debug
//!     information (deterministic); a debug export (Godot's `is_debug`,
//!     `--export-debug`) keeps it (`export_build.Options.strip` false)
//!     and logs `debug_export_line`.
//!   - without Zig scripts, it copies the add-on's empty game library
//!     (`empty_lib_file`, next to the editor library: the export host
//!     linked with no scripts), so such a project exports without Zig.
//!     When the scan reported problems (a `.zig` file it cannot read), it
//!     sends them as errors and copies nothing: such a file may be a
//!     script.
//! Any failure goes to the export platform's message list as an error
//! (`add_message`, which also prints it) that ends with
//! `incomplete_note`. An error message alone does not stop Godot's
//! export, but the library stays missing, and Godot's GDExtension export
//! then fails to copy it ("Failed to copy shared object"), so the export
//! fails (a headless export exits with status 1).
//! Other presets get the error message `platform_message`.
//!
//! A pack export (PCK or ZIP, also as a patch) never contains shared
//! libraries, so it never contains the Zig scripts, and Godot gives an
//! export plugin no way to stop it. For a project with Zig scripts the
//! plugin still builds (so errors show) and then sends the error
//! `pack_message`. A path ending in `zip` is either a pack or a full Linux
//! export that Godot zips, so `_export_end` decides from the written zip
//! (`export_build.zipHoldsLibrary`).
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
const sdk_options = @import("sdk_options");

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
/// The log line of a debug export with Zig scripts.
pub const debug_export_line = "Ziggurat: debug export keeps debug information; this library is not reproducible.";
/// Where the export writes the game library; the `.gdextension`'s template
/// keys name this path.
pub const lib_rel = ".godot/ziggurat/export/linux.x86_64/" ++ export_build.lib_file;
pub const lib_res_path = "res://" ++ lib_rel;
/// The add-on's export inputs, next to the editor library.
pub const archive_file = export_build.host_archive_file;
pub const empty_lib_file = "libziggurat_game_empty.so";
/// The end of every error after which the export fails: Godot has
/// already written the game executable and its pack.
pub const incomplete_note = "This export fails: the files in the export's output folder are incomplete.";
/// The start of the error for a pack export of a project with Zig scripts.
pub const pack_message = "Ziggurat exports Zig scripts only with a full export: this PCK/ZIP export does not contain them.";
const pack_text = pack_message ++ " They are compiled into the game library " ++ export_build.lib_file ++ ", and only a full export (Export Project, --export-release or --export-debug) copies it next to the game executable. A game that runs this pack with the game library of an earlier export runs that export's Zig code, and scripts added since do not load. Godot finishes a pack export despite this error. Export the project instead.";
/// How long an export waits for an editor build of the same project.
const lock_timeout_ms = 120_000;
/// Compile errors listed as messages; the rest are counted.
const max_listed = 50;

const gpa = std.heap.c_allocator;

pub const ZigExportPlugin = struct {
    base: *EditorExportPlugin,
    /// A `zip` export of a project with Zig scripts, for `_export_end`.
    zip_check: ?ZipCheck = null,

    pub fn create(allocator: *Allocator) !*ZigExportPlugin {
        const self = try allocator.create(ZigExportPlugin);
        self.* = .{ .base = EditorExportPlugin.init() };
        self.base.setInstance(ZigExportPlugin, self);
        return self;
    }

    /// Called by gdzig's free callback when Godot frees the object (the
    /// last reference dropped, see `detach`).
    pub fn destroy(self: *ZigExportPlugin, allocator: *Allocator) void {
        if (self.zip_check) |c| c.deinit();
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

    pub fn _exportBegin(self: *ZigExportPlugin, features: PackedStringArray, is_debug: bool, path: String, _: u32) void {
        exportBegin(self, &features, is_debug, &path);
    }

    pub fn _exportEnd(self: *ZigExportPlugin) void {
        const c = self.zip_check orelse return;
        self.zip_check = null;
        defer c.deinit();
        checkZip(self, c);
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

/// A `zip` export to check when it ends: the zip's path (absolute or
/// relative to the working folder) and its modification time before the
/// export, null when it did not exist.
const ZipCheck = struct {
    path: []u8,
    before: ?std.Io.Timestamp,

    fn deinit(c: ZipCheck) void {
        gpa.free(c.path);
    }
};

fn exportBegin(self: *ZigExportPlugin, features: *const PackedStringArray, is_debug: bool, path: *const String) void {
    if (self.zip_check) |c| c.deinit();
    self.zip_check = null;
    // A `Ref` return: the reference is the caller's.
    const plat = self.base.getExportPlatform();
    defer if (plat) |x| editor_build.releaseRef(x);
    if (!hasFeature(features, "linux") or !hasFeature(features, "x86_64")) {
        (Reporter{ .platform = plat }).err("{s}", .{platform_message});
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out_path = outputPath(a, path) catch {
        (Reporter{ .platform = plat }).fail("Ziggurat cannot build the game library for the export: out of memory.", .{});
        return;
    };
    const kind = export_build.outputKind(out_path);
    // A pack export does not fail on these errors, so they do not say so.
    const r: Reporter = .{ .platform = plat, .note = if (kind == .pack) "" else incomplete_note };
    const has_scripts = buildGameLibrary(a, r, kind, out_path, is_debug) catch blk: {
        r.fail("Ziggurat cannot build the game library for the export: out of memory.", .{});
        break :blk false;
    };
    if (!has_scripts) return;
    switch (kind) {
        .full => {},
        .pack => r.err("{s}", .{pack_text}),
        .zip => {
            const io = host_io.get();
            const before: ?std.Io.Timestamp = if (std.Io.Dir.cwd().statFile(io, out_path, .{})) |st| st.mtime else |_| null;
            const owned = gpa.dupe(u8, out_path) catch return r.err("{s}", .{pack_text});
            self.zip_check = .{ .path = owned, .before = before };
        },
    }
}

/// The export's output path as a file system path: `res://` and `user://`
/// paths globalized, other relative paths joined to the working folder
/// (Godot's working folder is the project folder).
fn outputPath(a: Allocator, path: *const String) Allocator.Error![]const u8 {
    var abs = ProjectSettings.globalizePath(path.*);
    defer abs.deinit();
    return props.utf8Alloc(a, &abs);
}

/// At the end of a `zip` export of a project with Zig scripts: a zip
/// without the game library is a pack.
fn checkZip(self: *ZigExportPlugin, c: ZipCheck) void {
    const plat = self.base.getExportPlatform();
    defer if (plat) |x| editor_build.releaseRef(x);
    const r: Reporter = .{ .platform = plat };
    const io = host_io.get();
    const st = std.Io.Dir.cwd().statFile(io, c.path, .{}) catch return; // nothing written: the export failed
    if (c.before) |b| if (st.mtime.nanoseconds == b.nanoseconds) return; // an earlier export's file
    const full = export_build.zipHoldsLibrary(io, c.path) catch |err|
        return r.err("Ziggurat cannot read the ZIP export {s} ({t}), so it cannot tell whether the zip holds the game library. " ++ pack_message ++ " Only a full export holds the Zig scripts.", .{ c.path, err });
    if (!full) r.err("{s}", .{pack_text});
}

/// Builds or copies the game library for a Linux x86_64 export to
/// `out_path`. True when the project has Zig scripts. A debug export
/// (`is_debug`) builds the library with its debug information
/// (`export_build.Options.strip` false) and logs `debug_export_line`.
fn buildGameLibrary(a: Allocator, r: Reporter, kind: export_build.OutputKind, out_path: []const u8, is_debug: bool) Allocator.Error!bool {
    const io = host_io.get();
    const cwd = std.Io.Dir.cwd();
    var msg: std.ArrayList(u8) = .empty;
    const project = editor_build.projectRoot(a, &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => {
            r.fail("Ziggurat cannot build the game library for the export: {s}", .{msg.items});
            return false;
        },
    };
    const out: platform.path.OsPath = .fromTrusted(try std.fs.path.join(a, &.{ project, lib_rel }));

    // Never ship an old library: from here on it exists only when this
    // export wrote it.
    cwd.deleteFile(io, out.bytes) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            oldLibraryStays(r, out.bytes, err);
            return false;
        },
    };
    // Nor leave one next to the new game files when this export fails.
    if (kind == .full and out_path.len != 0) {
        const dir = std.fs.path.dirname(out_path) orelse ".";
        const base = if (std.fs.path.isAbsolute(dir)) dir else try std.fs.path.join(a, &.{ project, dir });
        const old = try std.fs.path.join(a, &.{ base, export_build.lib_file });
        cwd.deleteFile(io, old) catch |err| switch (err) {
            error.FileNotFound => {},
            else => r.send(.export_message_error, "Ziggurat cannot delete {s}, the game library of an earlier export in the export's output folder ({t}). If this export fails, that old library stays next to the new game files: delete it.", .{ old, err }),
        };
    }

    const sc = zbuild.scan.scan(a, io, .fromTrusted(project), zbuild.scan.default_script_dirs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            r.fail("Ziggurat cannot build the game library for the export: scanning the project folder {s} failed ({t}).", .{ project, err });
            return false;
        },
    };
    // Every scan problem fails the export. A file the scan could not read
    // may be a script: the library would leave it out without a word, and a
    // scene that uses it would fail to load it in the game. Two scripts that
    // differ only by case fail too, so one rule holds.
    if (sc.problems.len != 0) {
        for (sc.problems) |pr| r.diagnostic(.export_message_error, .{ .rel = if (pr.rel.len == 0) null else pr.rel, .line = 0, .column = 0, .message = pr.message, .notes = &.{} });
        r.fail("Ziggurat cannot export the project's Zig files: the scan found the problems above, so it does not build the game library.", .{});
        return false;
    }
    const bin = addonBinDir(a) orelse {
        r.fail("Ziggurat cannot build the game library for the export: the path of its own library is unknown.", .{});
        return sc.scripts.len != 0;
    };

    if (sc.scripts.len == 0) {
        const empty = try std.fs.path.join(a, &.{ bin, empty_lib_file });
        cwd.copyFile(empty, cwd, out.bytes, io, .{ .make_path = true, .replace = true }) catch |err| {
            r.fail("Ziggurat cannot copy the game library for a project without Zig scripts from {s} to {s} ({t}); reinstall the add-on.", .{ empty, out.bytes, err });
            return false;
        };
        log("Ziggurat: the project has no Zig scripts; the export uses the add-on's game library without scripts.", .{});
        return false;
    }

    const archive: platform.path.OsPath = .fromTrusted(try std.fs.path.join(a, &.{ bin, archive_file }));
    cwd.access(io, archive.bytes, .{}) catch |err| {
        r.fail("Ziggurat cannot build the game library for the export: the export host archive {s} is missing ({t}); reinstall the add-on.", .{ archive.bytes, err });
        return true;
    };
    const in = editor_build.exportInputs(a, project, &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => {
            r.fail("Ziggurat cannot build the game library for the export: {s}", .{msg.items});
            return true;
        },
    };

    // A developer SDK of another version would build a library that the
    // game refuses at load. The archive is the add-on's own, so its version
    // is the running host's.
    if (!std.mem.eql(u8, in.sdk_version, sdk_options.sdk_version)) {
        const text = try export_build.sdkMismatchMessage(a, in.manifest_path, in.sdk_version, sdk_options.sdk_version, in.from_setting);
        r.fail("{s}", .{text});
        return true;
    }

    log("Ziggurat: building the game library for the export ({d} Zig scripts, Zig {s} at {s})...", .{ sc.scripts.len, in.zig.version, in.zig.exe.bytes });
    if (is_debug) log("{s}", .{debug_export_line});
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
        .strip = !is_debug,
    }, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            r.fail("The Zig build for the export failed: {s}", .{platform.elf.diagText(&diag)});
            return true;
        },
    };
    defer res.deinit(gpa);
    const ms = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    if (res.ok) {
        // The scan had no problems (they fail the export above), so a built
        // library has no diagnostics left.
        for (res.diagnostics) |d| r.diagnostic(.export_message_warning, d);
        log("Ziggurat: export library built in {d} ms: {s}", .{ ms, out.bytes });
        return true;
    }
    for (res.diagnostics[0..@min(res.diagnostics.len, max_listed)]) |d| r.diagnostic(.export_message_error, d);
    if (res.diagnostics.len > max_listed) r.err("{d} more errors are not listed.", .{res.diagnostics.len - max_listed});
    if (res.message) |m| {
        r.fail("The Zig build for the export failed: {s} The game library was not written.", .{m});
    } else {
        r.fail("The Zig build for the export failed with the errors above. The game library was not written.", .{});
    }
    return true;
}

/// An old game library that could not be deleted must not ship. It is
/// emptied, then all its permissions are removed (that needs ownership,
/// not write access to the folder), so Godot's GDExtension export cannot
/// copy it ("Failed to copy shared object") and the export fails, as on
/// every other failure path. When the permissions stay, the message says
/// plainly what this export ships instead.
fn oldLibraryStays(r: Reporter, path: []const u8, err: anyerror) void {
    const io = host_io.get();
    const cwd = std.Io.Dir.cwd();
    const emptied: ?anyerror = if (cwd.createFile(io, path, .{ .truncate = true })) |f| blk: {
        f.close(io);
        break :blk null;
    } else |e| e;
    const locked: ?anyerror = if (cwd.setFilePermissions(io, path, .fromMode(0), .{})) |_| null else |e| e;
    const head = "Ziggurat cannot delete the game library of an earlier export {s} ({t})";
    if (locked == null) {
        if (emptied == null)
            return r.fail(head ++ ", so it emptied it and removed its permissions, so Godot cannot copy it. Delete the file and export again.", .{ path, err });
        return r.fail(head ++ " or empty it ({t}), so it removed its permissions, so Godot cannot copy it. Delete the file and export again.", .{ path, err, emptied.? });
    }
    if (emptied == null)
        return r.err(head ++ ", so it emptied it, but it cannot remove its permissions ({t}): this export ships an empty game library, and the exported game cannot load its Zig scripts. Delete the file and export again.", .{ path, err, locked.? });
    return r.err(head ++ ", empty it ({t}) or remove its permissions ({t}): this export ships that old library with the scripts of an earlier export. Delete the file and export again.", .{ path, err, emptied.?, locked.? });
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
    /// The end of `fail` messages: `incomplete_note`, or empty for a pack
    /// export, which does not fail.
    note: []const u8 = incomplete_note,

    fn err(r: Reporter, comptime fmt: []const u8, args: anytype) void {
        r.send(.export_message_error, fmt, args);
    }

    /// An error after which the export fails (or ships no working game
    /// library); the message ends with `note`.
    fn fail(r: Reporter, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(gpa, fmt, args) catch return r.sendText(.export_message_error, "Ziggurat cannot report an export problem: out of memory.");
        defer gpa.free(text);
        if (r.note.len == 0) return r.sendText(.export_message_error, text);
        r.send(.export_message_error, "{s} {s}", .{ text, r.note });
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
