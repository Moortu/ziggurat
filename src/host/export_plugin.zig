//! `ZigExportPlugin`: builds an exported game's Zig scripts (spec section
//! 10). It is an `EditorExportPlugin` (a RefCounted), registered at the
//! EDITOR level like the editor plugin and never exposed. `ZigEditorPlugin`
//! creates one in `_enterTree` and hands it to the editor with
//! `add_export_plugin` (`attach`); `_exitTree` takes it back (`detach`).
//! An export build has none of this.
//!
//! Godot calls every export plugin's `_export_begin` before it writes
//! anything (the `ExportNotifier` of every export: binary, pack or zip).
//! For a preset whose features include `linux` and `x86_64`, or `windows`
//! and `x86_64` (target keys `x86_64-linux` and `x86_64-windows`,
//! `platform.target_key.fromFeatures`) the plugin first deletes the game
//! library `libRel(key)`, so a library of an earlier export can never ship.
//! When the delete fails, the rule depends on the editor's OS:
//!   - Linux: it empties the file and removes its permissions, so Godot
//!     cannot copy it and the export fails; when that fails too, the error
//!     says what the export ships;
//!   - Windows (a DLL another program has open or loaded): it renames the
//!     file aside to `<name>.old-<16 hex>`, which the next export deletes;
//!     when the rename fails too, the export fails with
//!     `export_build.removeOldLibrary`'s sentence and writes nothing.
//! A full export also deletes the game library in its output folder, so a
//! failed export does not leave the previous one's library next to the new
//! game files. Then:
//!   - with Zig scripts (the build service's scan, which leaves out
//!     `addons/`), it runs the export build (`export_build.run`, blocking,
//!     with progress lines). The build uses the Zig and SDK editor builds
//!     use for the export target (`editor_build.exportInputs`), the export
//!     host archive in `bin/<key>/` next to the editor library
//!     (`target_key.Files.host_archive`), and the editor's per-user cache
//!     folder, so it takes turns with editor builds on the project's
//!     `build.lock`; it writes the library only when the build and the
//!     library's checks pass. A release export builds it without debug
//!     information (deterministic); a debug export (Godot's `is_debug`,
//!     `--export-debug`) keeps it (`export_build.Options.strip` false)
//!     and logs `debugExportLine(key)`.
//!   - without Zig scripts, it copies the add-on's empty game library
//!     (`target_key.Files.game_empty` in `bin/<key>/`: the export host
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
//! `pack_message`. A path ending in `zip` is either a pack or a full export
//! that Godot zips, so `_export_end` decides from the written zip
//! (`export_build.zipHoldsLibrary`).
//!
//! The `.gdextension` names the game library for the `template_debug` and
//! `template_release` features, so Godot's own GDExtension export plugin
//! copies it next to the exported binary. `_export_file` skips every
//! `.zig` file: no source reaches the pack; the game's loader answers the
//! script paths from the linked table.
const std = @import("std");
const builtin = @import("builtin");
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
const target_key = platform.target_key;

/// The plugin's name (`_get_name`) and its messages' category.
pub const plugin_name = "Ziggurat";
/// The error message for a preset whose features name no target Ziggurat
/// exports to.
pub const platform_message = "Ziggurat exports Linux x86_64 and Windows x86_64 in this version";
/// The log line of a Linux debug export with Zig scripts.
pub const debug_export_line = "Ziggurat: debug export keeps debug information, with this computer's file paths, and is not reproducible. Turn off Export With Debug for a release.";
/// The log line of a Windows debug export with Zig scripts: the compiler
/// writes the debug information to a separate `.pdb` file in the build
/// cache, and the DLL keeps only that file's name.
pub const debug_export_line_windows = "Ziggurat: debug export writes the game library's debug information to a separate .pdb file in the build cache, which the export does not ship; the library keeps only that file's name. Turn off Export With Debug for a release.";

/// The log line of a debug export for target key `key`.
pub fn debugExportLine(key: []const u8) []const u8 {
    return if (export_build.formatOf(key) == .pe) debug_export_line_windows else debug_export_line;
}
/// The folder, relative to the project, that holds one folder per target
/// key with the game library an export writes.
pub const export_dir_rel = ".godot/ziggurat/export/";

/// Where an export for target key `key` writes the game library, relative
/// to the project (`.godot/ziggurat/export/<key>/<game library>`); the
/// `.gdextension`'s template keys name this path. Null for a key whose
/// files are not shipped (`target_key.files`).
pub fn libRel(key: []const u8) ?[]const u8 {
    inline for (target_key.packaged) |k| {
        if (std.mem.eql(u8, k, key)) return export_dir_rel ++ k ++ "/" ++ (comptime target_key.files(k).?.game_lib);
    }
    return null;
}
/// The end of every error after which the export fails: Godot has
/// already written the game executable and its pack.
pub const incomplete_note = "This export fails: the files in the export's output folder are incomplete.";
/// The start of the error for a pack export of a project with Zig scripts.
pub const pack_message = "Ziggurat exports Zig scripts only with a full export: this PCK/ZIP export does not contain them.";
/// The whole error, with the game library's file name as `{s}`.
const pack_text = pack_message ++ " They are compiled into the game library {s}, and only a full export (Export Project, --export-release or --export-debug) copies it next to the game executable. A game that runs this pack with the game library of an earlier export runs that export's Zig code, and scripts added since do not load. Godot finishes a pack export despite this error. Export the project instead.";
/// How long an export waits for an editor build of the same project.
const lock_timeout_ms = 120_000;
/// Compile errors listed as messages; the rest are counted.
const max_listed = 50;

const gpa = std.heap.c_allocator;

pub const ZigExportPlugin = struct {
    base: *EditorExportPlugin,
    /// A `zip` export of a project with Zig scripts, for `_export_end`.
    zip_check: ?ZipCheck = null,
    /// Set when the game library of an earlier export could not be
    /// removed: what `_export_end` removes so it does not ship (allocated
    /// with `gpa`), with the library's file name (static).
    stale: ?Stale = null,

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
        if (self.stale) |st| st.output.deinit(gpa);
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

    /// Godot calls it after it copied the shared libraries next to the
    /// game (`EditorExportPlatformPC::export_project`) and after it wrote a
    /// zip (the Linux and Windows platforms' `export_project`).
    pub fn _exportEnd(self: *ZigExportPlugin) void {
        if (self.stale) |st| {
            self.stale = null;
            defer st.output.deinit(gpa);
            removeStale(self, st);
        }
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
/// relative to the working folder), its modification time before the
/// export (null when it did not exist), and the game library's file name
/// for the export's target (static).
const ZipCheck = struct {
    path: []u8,
    before: ?std.Io.Timestamp,
    lib: []const u8,

    fn deinit(c: ZipCheck) void {
        gpa.free(c.path);
    }
};

/// An export whose old game library stayed (`ZigExportPlugin.stale`).
const Stale = struct {
    output: export_build.StaleOutput,
    lib: []const u8,
};

fn exportBegin(self: *ZigExportPlugin, features: *const PackedStringArray, is_debug: bool, path: *const String) void {
    if (self.zip_check) |c| c.deinit();
    self.zip_check = null;
    if (self.stale) |st| st.output.deinit(gpa);
    self.stale = null;
    // A `Ref` return: the reference is the caller's.
    const plat = self.base.getExportPlatform();
    defer if (plat) |x| editor_build.releaseRef(x);
    // The preset's target key.
    var names: [3][]const u8 = undefined;
    var n: usize = 0;
    inline for (.{ "linux", "windows", "x86_64" }) |name| {
        if (hasFeature(features, name)) {
            names[n] = name;
            n += 1;
        }
    }
    const key = target_key.fromFeatures(names[0..n]) orelse "";
    const game_lib = export_build.libFile(key) orelse {
        (Reporter{ .platform = plat }).err("{s}", .{platform_message});
        return;
    };
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
    var stale: ?export_build.StaleOutput = null;
    const has_scripts = buildGameLibrary(a, r, key, kind, out_path, is_debug, &stale) catch blk: {
        r.fail("Ziggurat cannot build the game library for the export: out of memory.", .{});
        break :blk false;
    };
    if (stale) |so| self.stale = .{ .output = so, .lib = game_lib };
    if (!has_scripts) return;
    switch (kind) {
        .full => {},
        .pack => r.err(pack_text, .{game_lib}),
        .zip => {
            const io = host_io.get();
            const before: ?std.Io.Timestamp = if (std.Io.Dir.cwd().statFile(io, out_path, .{})) |st| st.mtime else |_| null;
            const owned = gpa.dupe(u8, out_path) catch return r.err(pack_text, .{game_lib});
            self.zip_check = .{ .path = owned, .before = before, .lib = game_lib };
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

/// At the end of an export whose old game library stayed: removes the copy
/// Godot shipped (`export_build.removeStaleOutput`) and says what it did.
fn removeStale(self: *ZigExportPlugin, st: Stale) void {
    const plat = self.base.getExportPlatform();
    defer if (plat) |x| editor_build.releaseRef(x);
    const r: Reporter = .{ .platform = plat };
    const text = export_build.removeStaleOutput(gpa, host_io.get(), st.output, st.lib, .{}) catch
        return r.err("Ziggurat cannot check whether this export ships the old game library: out of memory. Delete {s} from the export's output folder.", .{st.lib});
    const t = text orelse return;
    defer gpa.free(t);
    r.err("{s}", .{t});
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
    const full = export_build.zipHoldsLibrary(io, c.path, c.lib) catch |err|
        return r.err("Ziggurat cannot read the ZIP export {s} ({t}), so it cannot tell whether the zip holds the game library. " ++ pack_message ++ " Only a full export holds the Zig scripts.", .{ c.path, err });
    if (!full) r.err(pack_text, .{c.lib});
}

/// Builds or copies the game library for an export for target key `key`
/// (one `export_build.libFile` knows) to `out_path`. True when the project has
/// Zig scripts. A debug export
/// (`is_debug`) builds the library with its debug information
/// (`export_build.Options.strip` false) and logs `debugExportLine(key)`.
/// When the game library of an earlier export cannot be removed, `stale`
/// is set (allocated with `gpa`) to what the export's end must remove.
fn buildGameLibrary(a: Allocator, r: Reporter, key: []const u8, kind: export_build.OutputKind, out_path: []const u8, is_debug: bool, stale: *?export_build.StaleOutput) Allocator.Error!bool {
    const io = host_io.get();
    const cwd = std.Io.Dir.cwd();
    var msg: std.ArrayList(u8) = .empty;
    const files = target_key.files(key) orelse {
        r.fail("Ziggurat cannot build the game library for the export: the add-on has no files for the target {s}.", .{key});
        return false;
    };
    const lib_rel = libRel(key).?;
    const project = editor_build.projectRoot(a, &msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unusable => {
            r.fail("Ziggurat cannot build the game library for the export: {s}", .{msg.items});
            return false;
        },
    };
    const out: platform.path.OsPath = .fromTrusted(try std.fs.path.join(a, &.{ project, lib_rel }));

    // Libraries an earlier export renamed aside (Windows) and that are no
    // longer in use.
    if (std.fs.path.dirname(out.bytes)) |dir| export_build.sweepRenamedLibraries(io, dir, files.game_lib);
    // Never ship an old library: from here on it exists only when this
    // export wrote it. When it stays, Godot still copies it (an error
    // message does not stop an export), so the export's end removes the
    // copy (`stale`).
    const removed = if (comptime builtin.os.tag == .windows)
        try windowsOldLibrary(a, r, out.bytes, .{})
    else if (testOldLibraryStays(a))
        try windowsOldLibrary(a, r, out.bytes, .{ .delete = failForTest, .rename = failRenameForTest })
    else if (cwd.deleteFile(io, out.bytes)) |_| true else |err| switch (err) {
        error.FileNotFound => true,
        else => blk: {
            oldLibraryStays(r, out.bytes, err);
            break :blk false;
        },
    };
    if (!removed) {
        var zip_before: ?std.Io.Timestamp = null;
        if (kind == .zip) {
            const zip_abs = if (std.fs.path.isAbsolute(out_path)) out_path else try std.fs.path.join(a, &.{ project, out_path });
            if (cwd.statFile(io, zip_abs, .{})) |st| zip_before = st.mtime else |_| {}
        }
        stale.* = try export_build.staleOutput(gpa, kind, project, out_path, files.game_lib, zip_before);
        return false;
    }
    // Nor leave one next to the new game files when this export fails.
    if (kind == .full and out_path.len != 0) {
        const old = try export_build.outputLibraryPath(a, project, out_path, files.game_lib);
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
        r.fail("Ziggurat cannot export the project's Zig files: the scan found the problems above, so it does not build the game library. For a file or folder it could not read, fix its permissions, or add a `.gdignore` file to a folder that holds no scripts.", .{});
        return false;
    }
    const bin = addonBinDir(a) orelse {
        r.fail("Ziggurat cannot build the game library for the export: the path of its own library is unknown.", .{});
        return sc.scripts.len != 0;
    };

    if (sc.scripts.len == 0) {
        const empty = try std.fs.path.join(a, &.{ bin, key, files.game_empty });
        cwd.copyFile(empty, cwd, out.bytes, io, .{ .make_path = true, .replace = true }) catch |err| {
            r.fail("Ziggurat cannot copy the game library for a project without Zig scripts from {s} to {s} ({t}); reinstall the add-on.", .{ empty, out.bytes, err });
            return false;
        };
        log("Ziggurat: the project has no Zig scripts; the export uses the add-on's game library without scripts.", .{});
        return false;
    }

    const archive: platform.path.OsPath = .fromTrusted(try std.fs.path.join(a, &.{ bin, key, files.host_archive }));
    // `statFile`, not `access`: folder-relative `access` finds nothing
    // under Wine.
    _ = cwd.statFile(io, archive.bytes, .{}) catch |err| {
        r.fail("Ziggurat cannot build the game library for the export: the export host archive {s} is missing ({t}); reinstall the add-on.", .{ archive.bytes, err });
        return true;
    };
    const in = editor_build.exportInputs(a, project, key, &msg) catch |err| switch (err) {
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
        const text = try export_build.sdkMismatchMessage(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ key, files.host_archive }), in.manifest_path, in.sdk_version, sdk_options.sdk_version, in.from_setting);
        r.fail("{s}", .{text});
        return true;
    }

    log("Ziggurat: building the game library for the export ({d} Zig scripts, Zig {s} at {s})...", .{ sc.scripts.len, in.zig.version, in.zig.exe.bytes });
    if (is_debug) log("{s}", .{debugExportLine(key)});
    const t0 = std.Io.Clock.awake.now(io);
    var diag: [256]u8 = undefined;
    const res = export_build.run(gpa, io, .{
        .zig = in.zig,
        .project_root = .fromTrusted(project),
        .sdk = in.sdk,
        .target_key = key,
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

/// The Windows rule (`export_build.removeOldLibrary`): true when nothing
/// is left at `path`; false after the failure was reported.
fn windowsOldLibrary(a: Allocator, r: Reporter, path: []const u8, ops: export_build.FileOps) Allocator.Error!bool {
    switch (try export_build.removeOldLibrary(a, host_io.get(), path, ops)) {
        .gone => return true,
        .renamed => |aside| {
            log("Ziggurat: the game library of an earlier export {s} is in use, so it was renamed to {s}; the next export deletes it.", .{ path, aside });
            return true;
        },
        .stays => |sentence| {
            r.fail("{s}", .{sentence});
            return false;
        },
    }
}

/// Test probe hosts only: with the environment variable
/// `ZIGGURAT_TEST_OLD_LIBRARY_STAYS=1`, a Linux editor uses the Windows
/// old-library rule with a failing delete and rename, so the host tests
/// reach the branch where the old library stays and Godot copies it.
fn testOldLibraryStays(a: Allocator) bool {
    if (comptime !host_options.test_probe) return false;
    const v = editor_build.envVar(a, "ZIGGURAT_TEST_OLD_LIBRARY_STAYS") catch return false;
    return if (v) |t| std.mem.eql(u8, t, "1") else false;
}

fn failForTest(_: std.Io, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

fn failRenameForTest(_: std.Io, _: []const u8, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

/// POSIX: an old game library that could not be deleted must not ship. It
/// is emptied, then all its permissions are removed (that needs ownership,
/// not write access to the folder), so Godot's GDExtension export cannot
/// copy it ("Failed to copy shared object") and the export fails, as on
/// every other failure path. When the permissions stay, the message says
/// plainly what this export ships instead. Windows renames the library
/// aside instead (`export_build.removeOldLibrary`); this function is not
/// compiled there.
fn oldLibraryStays(r: Reporter, path: []const u8, err: anyerror) void {
    comptime std.debug.assert(builtin.os.tag != .windows);
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
