//! Windows end to end under Wine (`zig build test-wine-e2e`). These tests
//! run on Linux and start the Windows editor, an exported Windows game and
//! the Windows Zig under Wine through tools/wine_run.zig (one Wine prefix
//! in the build cache, `WINEDEBUG=-all`). Godot runs through
//! test/host/runner.zig in its Wine mode. Each test makes a project the way
//! a user makes one: the export fixture of test/host/projects in a folder
//! whose path holds a space, with the release package unzipped into it.
//!
//! Inputs, never downloaded: `-Dwindows-godot`, `-Dwindows-zig`,
//! `-Dwindows-zig-zip` and `-Dexport-templates`. A test skips when one it
//! needs is missing. The download test serves the real Windows Zig zip and
//! its `.minisig` from the fixture server on 127.0.0.1.
//!
//! Known Wine gaps are listed in test/wine_gaps.zig (`e2e_gaps`): such a
//! test checks that the gap still holds, runs up to it, and then skips.
const std = @import("std");
const builtin = @import("builtin");
const opts = @import("wine_e2e_options");
const wine_gaps = @import("wine_gaps");
const fixture_server = @import("fixture_server.zig");
const testing = std.testing;
const Io = std.Io;
const io = testing.io;

/// One deadline for a Godot run that builds, exports or downloads.
const deadline_s = "900";
/// The Windows console editor in `-Dwindows-godot`.
const windows_godot_exe = "Godot_v4.7.2-stable_win64_console.exe";
const windows_lib_rel = ".godot/ziggurat/export/x86_64-windows/ziggurat_game.dll";
const export_building = "Ziggurat: building the game library for the export";
const export_incomplete = "the files in the export's output folder are incomplete";
/// What a game started from the export fixture's main scene prints.
const game_lines = [_][]const u8{
    "ziggurat: 2 scripts linked",
    "[ziggurat] hero ready speed=7.5",
    "[ziggurat] sidekick ready",
    "export check: main ready",
};
/// The same without Zig scripts.
const game_lines_no_scripts = [_][]const u8{ "ziggurat: 0 scripts linked", "export check: main ready" };

const Need = struct {
    godot: bool = false,
    zig: bool = false,
    zip: bool = false,
    templates: bool = false,
    linux_godot: bool = false,
};

/// Skips the test when an input it needs was not given.
fn require(need: Need) !void {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    if (need.godot and opts.windows_godot.len == 0) return error.SkipZigTest;
    if (need.zig and opts.windows_zig.len == 0) return error.SkipZigTest;
    if (need.zip and opts.windows_zig_zip.len == 0) return error.SkipZigTest;
    if (need.templates and opts.export_templates.len == 0) return error.SkipZigTest;
    if (need.linux_godot and opts.godot_exe.len == 0) return error.SkipZigTest;
}

/// `path` (absolute) as a Windows program under Wine sees it.
fn winPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try std.mem.concat(a, u8, &.{ "Z:", path });
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

/// The same with `/` separators, for Godot's text files.
fn winPathSlash(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ "Z:", path });
}

/// The Wine state folder (tools/wine_run.zig), absolute.
fn wineState(a: std.mem.Allocator) ![]const u8 {
    try Io.Dir.cwd().createDirPath(io, opts.wine_state);
    return Io.Dir.cwd().realPathFileAlloc(io, opts.wine_state, a);
}

const Editor = enum { linux, windows };

/// A temporary project: the export fixture and the release package.
const Project = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    /// The test's folder (absolute).
    root: []const u8,
    /// The project folder (absolute), `<root>/my game`.
    path: []const u8,
    env: *std.process.Environ.Map,
    editor: Editor,

    /// `scripts` false turns the fixture into a project without Zig
    /// scripts. The project setting `ziggurat/zig_path` names the Windows
    /// Zig (`-Dwindows-zig`) for the Windows editor, else the test's Zig;
    /// the presets name `-Dexport-templates` as that editor sees it.
    fn init(p: *Project, editor: Editor, scripts: bool) !void {
        p.editor = editor;
        p.arena_state = .init(testing.allocator);
        errdefer p.arena_state.deinit();
        const a = p.arena_state.allocator();
        p.tmp = testing.tmpDir(.{});
        errdefer p.tmp.cleanup();
        const cwd = Io.Dir.cwd();
        const folder = "my game";
        try p.tmp.dir.createDirPath(io, folder);
        var dst = try p.tmp.dir.openDir(io, folder, .{});
        defer dst.close(io);
        {
            var projects = try cwd.openDir(io, opts.projects_dir, .{});
            defer projects.close(io);
            var src = try projects.openDir(io, "export", .{ .iterate = true });
            defer src.close(io);
            try copyTree(a, src, dst);
        }
        {
            var zip = try cwd.openFile(io, opts.package_zip, .{});
            defer zip.close(io);
            var buf: [64 * 1024]u8 = undefined;
            var reader = zip.reader(io, &buf);
            try std.zip.extract(dst, &reader, .{});
        }
        p.root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
        p.path = try p.tmp.dir.realPathFileAlloc(io, folder, a);
        if (!scripts) try removeScripts(dst);

        const zig = switch (editor) {
            .linux => opts.zig_exe,
            .windows => try winPathSlash(a, try std.fs.path.join(a, &.{ opts.windows_zig, "zig.exe" })),
        };
        const templates = switch (editor) {
            .linux => opts.export_templates,
            .windows => try winPathSlash(a, opts.export_templates),
        };
        const old = try dst.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
        try dst.writeFile(io, .{ .sub_path = "project.godot", .data = try std.fmt.allocPrint(a, "{s}\n[ziggurat]\n\nzig_path=\"{s}\"\n", .{ old, zig }) });
        const presets = try dst.readFileAlloc(io, "export_presets.cfg", a, .limited(64 * 1024));
        try dst.writeFile(io, .{ .sub_path = "export_presets.cfg", .data = try std.mem.replaceOwned(u8, a, presets, "@TEMPLATES@", templates) });
        try dst.createDirPath(io, "out");

        // The Linux editor's per-user folders are the test's own; its build
        // cache is the export tests' shared one, so it starts warm. (Wine
        // sets the Windows per-user folders from its prefix.)
        const env = try a.create(std.process.Environ.Map);
        env.* = try testing.environ.createMap(testing.allocator);
        p.env = env;
        inline for (.{ "config", "data" }) |sub| try p.tmp.dir.createDirPath(io, sub);
        try env.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ p.root, "config" }));
        try env.put("XDG_DATA_HOME", try std.fs.path.join(a, &.{ p.root, "data" }));
        try cwd.createDirPath(io, opts.export_test_cache);
        try env.put("XDG_CACHE_HOME", try cwd.realPathFileAlloc(io, opts.export_test_cache, a));
    }

    fn deinit(p: *Project) void {
        p.env.deinit();
        p.tmp.cleanup();
        p.arena_state.deinit();
    }

    /// The absolute path of the project file `rel`.
    fn file(p: *Project, rel: []const u8) ![]const u8 {
        return std.fs.path.join(p.arena_state.allocator(), &.{ p.path, rel });
    }

    fn exists(p: *Project, rel: []const u8) !bool {
        _ = Io.Dir.cwd().statFile(io, try p.file(rel), .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn write(p: *Project, rel: []const u8, data: []const u8) !void {
        var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
        defer dir.close(io);
        if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
        try dir.writeFile(io, .{ .sub_path = rel, .data = data });
    }

    fn read(p: *Project, rel: []const u8) ![]u8 {
        return Io.Dir.cwd().readFileAlloc(io, try p.file(rel), p.arena_state.allocator(), .limited(1 << 30));
    }

    /// Adds test/host/checks/<name> as the tool autoload `res://check.gd`.
    fn addAutoloadCheck(p: *Project, name: []const u8) !void {
        const a = p.arena_state.allocator();
        var checks = try Io.Dir.cwd().openDir(io, opts.checks_dir, .{});
        defer checks.close(io);
        var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
        defer dir.close(io);
        try checks.copyFile(name, dir, "check.gd", io, .{});
        const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
        try dir.writeFile(io, .{ .sub_path = "project.godot", .data = try std.mem.concat(a, u8, &.{ old, "\n[autoload]\n\ncheck=\"*res://check.gd\"\n" }) });
    }

    const Texts = struct {
        expect: []const []const u8 = &.{},
        once: []const []const u8 = &.{},
        reject: []const []const u8 = &.{},
        exit_code: []const u8 = "0",
    };

    /// Runs Godot through the runner: the project's editor (`mode` is a
    /// runner mode), or for `run` the exported game `mode[1]` (Windows
    /// under Wine when `windows`).
    fn run(p: *Project, windows: bool, mode: []const []const u8, texts: Texts) !void {
        const a = p.arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        const godot = if (windows)
            try std.fs.path.join(a, &.{ opts.windows_godot, windows_godot_exe })
        else
            opts.godot_exe;
        try argv.appendSlice(a, &.{ opts.runner_exe, godot, p.path });
        try argv.appendSlice(a, mode);
        try argv.append(a, deadline_s);
        for (texts.expect) |t| try argv.appendSlice(a, &.{ "--expect", t });
        for (texts.once) |t| try argv.appendSlice(a, &.{ "--expect-once", t });
        for (texts.reject) |t| try argv.appendSlice(a, &.{ "--reject", t });
        try argv.appendSlice(a, &.{ "--exit-code", texts.exit_code });
        if (windows) try argv.appendSlice(a, &.{ "--wine-run", opts.wine_run_exe, "--wine-state", try wineState(a) });
        const result = try std.process.run(a, io, .{ .argv = argv.items, .environ_map = p.env });
        if (result.term.success()) return;
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.GodotRunFailed;
    }

    /// The Windows editor (under Wine) exports `preset` to `out/<name>`.
    fn exportWindowsEditor(p: *Project, preset: []const u8, name: []const u8, texts: Texts) !void {
        return p.run(true, &.{ "export", preset, try p.file(try std.fs.path.join(p.arena_state.allocator(), &.{ "out", name })) }, texts);
    }
};

fn copyTree(a: std.mem.Allocator, src: Io.Dir, dst: Io.Dir) !void {
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dst.createDirPath(io, entry.path),
            .file => try src.copyFile(entry.path, dst, entry.path, io, .{}),
            else => {},
        }
    }
}

/// The export fixture without Zig scripts: the main scene holds only
/// main.gd.
fn removeScripts(dir: Io.Dir) !void {
    for ([_][]const u8{ "hero.zig", "hero.zig.uid", "sub/sidekick.zig", "uid_main.tscn" }) |f| try dir.deleteFile(io, f);
    try dir.writeFile(io, .{ .sub_path = "main.tscn", .data =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://main.gd" id="1_main"]
        \\
        \\[node name="Main" type="Node"]
        \\script = ExtResource("1_main")
        \\
    });
}

/// Runs the Windows program `exe` (a Linux path) with `args` under Wine and
/// returns its output.
fn wineRun(a: std.mem.Allocator, exe: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ opts.wine_run_exe, try wineState(a), exe });
    try argv.appendSlice(a, args);
    return std.process.run(a, io, .{
        .argv = argv.items,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(600), .clock = .awake } },
    });
}

/// Whether the Windows Zig fails to compile under this Wine (the gap
/// `zig_lock_gap` of test/wine_gaps.zig): a one-line file is compiled
/// without output, with caches in a temporary folder. Another failure is
/// an error.
var zig_gap: ?bool = null;
fn windowsZigGap() !bool {
    if (zig_gap) |g| return g;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "probe.zig", .data = "pub fn main() void {}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const zig = try std.fs.path.join(a, &.{ opts.windows_zig, "zig.exe" });
    const r = try wineRun(a, zig, &.{
        "build-obj",
        try winPath(a, try std.fs.path.join(a, &.{ root, "probe.zig" })),
        "-fno-emit-bin",
        "--cache-dir",
        try winPath(a, try std.fs.path.join(a, &.{ root, "cache" })),
        "--global-cache-dir",
        try winPath(a, try std.fs.path.join(a, &.{ root, "global" })),
    });
    const gap = if (r.term.success())
        false
    else if (std.mem.indexOf(u8, r.stderr, zig_gap_load) != null or std.mem.indexOf(u8, r.stderr, zig_gap_cache) != null)
        true
    else {
        std.debug.print("the Windows Zig under Wine failed in an unknown way ({any}):\n{s}{s}\n", .{ r.term, r.stdout, r.stderr });
        return error.WindowsZigFailed;
    };
    zig_gap = gap;
    return gap;
}

/// The Windows Zig's two messages for the gap.
const zig_gap_load = "unable to load \"std.zig\": Unexpected";
const zig_gap_cache = "checking cache failed: manifest_create Unexpected";

// ------------------------------------------------------------ the editor

test "wine editor builds and runs a script" {
    try require(.{ .godot = true, .zig = true });
    var p: Project = undefined;
    try p.init(.windows, true);
    defer p.deinit();
    if (try windowsZigGap()) {
        _ = wine_gaps.e2eGap("wine editor builds and runs a script");
        // Up to the gap: the Windows host loads, accepts the Windows Zig
        // (`zig version` runs), prepares the build and starts the
        // compiler, which stops at its cache lock.
        try p.addAutoloadCheck("wine_editor.gd");
        try p.run(true, &.{ "build", "30" }, .{
            .expect = &.{ "ziggurat_host 0.1.0 ready", "ziggurat: build failed (play, ", "Ziggurat cancelled the run because the Zig build failed" },
            .reject = &.{ "is not set", "is not usable", "no zig was found", "Preparing the build folder" },
            .exit_code = "1",
        });
        return error.SkipZigTest;
    }
    // Play's build in the headless editor (`--build-solutions`), then a
    // game run of the main scene with the staged generation.
    try p.addAutoloadCheck("export_editor.gd");
    try p.run(true, &.{ "build", "30" }, .{
        .expect = &.{ "ZTEST PASS export_editor_built", "ziggurat: build 1 " },
        .reject = &.{ "is not set", "is not usable", "build failed" },
    });
    try p.run(true, &.{ "game", "res://main.tscn" }, .{
        .once = &.{ "[ziggurat] hero ready speed=7.5", "[ziggurat] sidekick ready", "export check: main ready" },
        .reject = &.{"ziggurat: build"},
    });
}

// ------------------------------------------------------------ exports

test "windows export from linux runs under wine" {
    try require(.{ .templates = true, .linux_godot = true });
    var p: Project = undefined;
    try p.init(.linux, true);
    defer p.deinit();
    try p.run(false, &.{ "export", "Windows", try p.file("out/game.exe") }, .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", "is not set", "is not usable" },
    });
    for ([_][]const u8{ "out/game.exe", "out/game.pck", "out/ziggurat_game.dll" }) |f| try testing.expect(try p.exists(f));
    try p.run(true, &.{ "run", try p.file("out/game.exe") }, .{
        .once = &game_lines,
        .reject = &.{ "ERROR:", "WARNING:" },
    });
}

test "linux export from the windows editor" {
    try require(.{ .godot = true, .zig = true, .templates = true });
    var p: Project = undefined;
    try p.init(.windows, true);
    defer p.deinit();
    if (try windowsZigGap()) {
        _ = wine_gaps.e2eGap("linux export from the windows editor");
        // Up to the gap: the export finds the Windows Zig and the Linux SDK
        // and starts the export build, which stops at the compiler's cache
        // lock; the export fails cleanly.
        try p.exportWindowsEditor("Linux", "game.x86_64", .{
            .once = &.{export_building},
            .expect = &.{ "Ziggurat: The Zig build for the export failed", export_incomplete },
            .reject = &.{ "is not set", "is not usable" },
            .exit_code = "1",
        });
        try testing.expect(!try p.exists("out/libziggurat_game.so"));
        return error.SkipZigTest;
    }
    try p.exportWindowsEditor("Linux", "game.x86_64", .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", "is not set", "is not usable" },
    });
    try testing.expect(try p.exists("out/libziggurat_game.so"));
    try makeExecutable(&p, "out/game.x86_64");
    try p.run(false, &.{ "run", try p.file("out/game.x86_64") }, .{ .once = &game_lines, .reject = &.{ "ERROR:", "WARNING:" } });
}

/// Windows has no executable bit, so a Linux game exported there needs
/// one before it runs on Linux, as after a copy from Windows.
fn makeExecutable(p: *Project, rel: []const u8) !void {
    try Io.Dir.cwd().setFilePermissions(io, try p.file(rel), .fromMode(0o755), .{});
}

test "linux export from the windows editor, project without scripts" {
    try require(.{ .godot = true, .templates = true });
    var p: Project = undefined;
    try p.init(.windows, false);
    defer p.deinit();
    // No Zig scripts: the export ships the add-on's empty Linux game
    // library without running Zig.
    try p.exportWindowsEditor("Linux", "game.x86_64", .{ .reject = &.{ "ERROR:", export_building } });
    try testing.expect(try p.exists("out/game.x86_64"));
    try testing.expect(try p.exists("out/libziggurat_game.so"));
    try makeExecutable(&p, "out/game.x86_64");
    try p.run(false, &.{ "run", try p.file("out/game.x86_64") }, .{ .once = &game_lines_no_scripts, .reject = &.{ "ERROR:", "WARNING:" } });
}

// ------------------------------------------------------------ old library

/// A Windows program (test/host/wine_holder.zig) that holds a file under
/// Wine until `stop`.
const Holder = struct {
    child: std.process.Child,
    stop_path: []const u8,
    stopped: bool = false,

    /// Starts the holder in `mode` on `file` (a Linux path) and waits until
    /// it holds it.
    fn start(a: std.mem.Allocator, root: []const u8, mode: []const u8, file: []const u8) !Holder {
        const ready = try std.fs.path.join(a, &.{ root, "holder-ready" });
        const stop_path = try std.fs.path.join(a, &.{ root, "holder-stop" });
        var child = try std.process.spawn(io, .{
            .argv = &.{ opts.wine_run_exe, try wineState(a), opts.holder_exe, mode, try winPath(a, file), try winPath(a, ready), try winPath(a, stop_path) },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        var waited: u32 = 0;
        while (waited < 120_000) : (waited += 100) {
            if (Io.Dir.cwd().statFile(io, ready, .{})) |_| return .{ .child = child, .stop_path = stop_path } else |_| {}
            try io.sleep(.fromMilliseconds(100), .awake);
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = stop_path, .data = "" });
        _ = child.wait(io) catch {};
        return error.HolderNotReady;
    }

    /// Lets the holder close the file and exit; waits for it.
    fn stop(h: *Holder) !void {
        if (h.stopped) return;
        h.stopped = true;
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = h.stop_path, .data = "" });
        const term = try h.child.wait(io);
        if (!term.success()) return error.HolderFailed;
    }
};

/// A project without Zig scripts for the Windows editor whose earlier
/// export left `windows_lib_rel`: the add-on's empty game DLL with a
/// few bytes appended, so it differs from the library an export copies.
fn initOldLibrary(p: *Project) ![]const u8 {
    try p.init(.windows, false);
    errdefer p.deinit();
    const a = p.arena_state.allocator();
    const empty = try p.read("addons/ziggurat/bin/x86_64-windows/ziggurat_game_empty.dll");
    try p.write(windows_lib_rel, try std.mem.concat(a, u8, &.{ empty, "an earlier export" }));
    return empty;
}

test "wine: an old library held without delete sharing is removed from the output" {
    try require(.{ .godot = true, .templates = true });
    var p: Project = undefined;
    _ = try initOldLibrary(&p);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // Another program opened the old library for reading and shares only
    // reading: it can be neither deleted nor renamed, but Godot can copy it.
    var holder = try Holder.start(a, p.root, "share-read", try p.file(windows_lib_rel));
    defer holder.stop() catch {};
    try p.exportWindowsEditor("Windows", "game.exe", .{
        .expect = &.{ "Ziggurat cannot replace the old game library ", "Close programs that use it and export again.", export_incomplete, "Ziggurat deleted ", "ziggurat_game.dll from the export's output folder" },
        .reject = &.{export_building},
    });
    try holder.stop();
    try testing.expect(try p.exists("out/game.exe"));
    try testing.expect(!try p.exists("out/ziggurat_game.dll"));
    try testing.expect(try p.exists(windows_lib_rel));
}

test "wine: a loaded old library is renamed aside and swept by the next export" {
    try require(.{ .godot = true, .templates = true });
    var p: Project = undefined;
    const empty = try initOldLibrary(&p);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // Another program loaded the old library: it cannot be deleted, but
    // it can be renamed.
    var holder = try Holder.start(a, p.root, "load", try p.file(windows_lib_rel));
    defer holder.stop() catch {};
    try p.exportWindowsEditor("Windows", "game.exe", .{
        .once = &.{"is in use, so it was renamed to "},
        .reject = &.{ "ERROR:", "Ziggurat cannot replace", export_building },
    });
    try testing.expectEqualSlices(u8, empty, try p.read("out/ziggurat_game.dll"));
    try testing.expectEqual(@as(usize, 1), try renamedLibraries(&p));
    try holder.stop();
    // The next export deletes the renamed library.
    try p.exportWindowsEditor("Windows", "game.exe", .{ .reject = &.{ "ERROR:", "is in use", export_building } });
    try testing.expectEqual(@as(usize, 0), try renamedLibraries(&p));
    try testing.expectEqualSlices(u8, empty, try p.read("out/ziggurat_game.dll"));
}

/// The number of `ziggurat_game.dll.old-*` files beside the export library.
fn renamedLibraries(p: *Project) !usize {
    var dir = try Io.Dir.cwd().openDir(io, try p.file(std.fs.path.dirname(windows_lib_rel).?), .{ .iterate = true });
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, "ziggurat_game.dll.old-")) n += 1;
    }
    return n;
}

// ------------------------------------------------------------ download

const zip_name = "zig-x86_64-windows-0.17.0.zip";

test "wine: zig download installs the real windows zip" {
    try require(.{ .godot = true, .zip = true });
    var p: Project = undefined;
    try p.init(.windows, false);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // The probe host, which takes the download's test overrides.
    {
        var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
        defer dir.close(io);
        try Io.Dir.cwd().copyFile(opts.probe_host_dll, dir, "addons/ziggurat/bin/ziggurat_host.dll", io, .{});
    }
    // The fixture server serves the real zip and its real signature (links
    // to the files in the test cache; nothing is copied).
    try p.tmp.dir.createDirPath(io, "www/good");
    const www = try std.fs.path.join(a, &.{ p.root, "www" });
    try p.tmp.dir.symLink(io, opts.windows_zig_zip, "www/good/" ++ zip_name, .{});
    try p.tmp.dir.symLink(io, try std.mem.concat(a, u8, &.{ opts.windows_zig_zip, ".minisig" }), "www/good/" ++ zip_name ++ ".minisig", .{});
    const server = try fixture_server.Server.start(testing.allocator, io, www);
    defer server.stop();
    errdefer server.dump();
    const base = try std.fmt.allocPrint(a, "https://127.0.0.1:{d}", .{server.port});
    try p.tmp.dir.writeFile(io, .{ .sub_path = "www/community-mirrors.txt", .data = try std.fmt.allocPrint(a, "{s}/good\n", .{base}) });
    // No key and no archive: the pinned Windows archive and Zig key apply.
    const toolchains = try std.fs.path.join(a, &.{ p.root, "data", "ziggurat", "toolchains" });
    try p.write("download_cfg.txt", try std.fmt.allocPrint(a,
        \\list_url={s}/community-mirrors.txt
        \\official_base={s}/official
        \\plain_http=1
        \\toolchains_dir={s}
        \\
    , .{ base, base, try winPath(a, toolchains) }));
    try p.addAutoloadCheck("wine_download.gd");
    try p.run(true, &.{ "editor", "10000000" }, .{
        .expect = &.{ "ZTEST PASS wine_download_configured", "ZTEST PASS wine_download_menu", "ZTEST PASS wine_download_done" },
    });
    try testing.expectEqual(@as(usize, 1), server.countExact("/community-mirrors.txt"));
    try testing.expectEqual(@as(usize, 1), server.countExact("/good/" ++ zip_name));
    try testing.expectEqual(@as(usize, 1), server.countExact("/good/" ++ zip_name ++ ".minisig"));
    // The installed Windows Zig runs.
    const zig = try std.fs.path.join(a, &.{ toolchains, "zig-0.17.0", "zig.exe" });
    const r = try wineRun(a, zig, &.{"version"});
    if (!r.term.success()) {
        std.debug.print("zig.exe version: {any}\n{s}{s}\n", .{ r.term, r.stdout, r.stderr });
        return error.InstalledZigFailed;
    }
    try testing.expectEqualStrings("0.17.0", std.mem.trim(u8, r.stdout, " \r\n"));
    // Nothing temporary is left.
    var tc = try Io.Dir.cwd().openDir(io, toolchains, .{ .iterate = true });
    defer tc.close(io);
    var it = tc.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, ".download-") or (std.mem.startsWith(u8, e.name, ".zig-") and std.mem.indexOf(u8, e.name, ".tmp-") != null)) {
            std.debug.print("left in the toolchains folder: {s}\n", .{e.name});
            return error.TempLeft;
        }
    }
}
