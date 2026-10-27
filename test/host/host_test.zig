//! Host integration tests. Each test copies a fixture project from
//! test/host/projects into a temporary folder, puts the host library and its
//! `.gdextension` into the project's `addons/ziggurat/` folder (the library
//! under `bin/`), adds a check script
//! from test/host/checks as `res://check.gd`, and runs Godot through
//! test/host/runner.zig, which decides pass or fail. Tests that need a user
//! module build one from test/fixtures with the build service and the SDK
//! manifest before Godot starts (ruling R1).
const std = @import("std");
const builtin = @import("builtin");
const opts = @import("host_test_options");
const gui_opts = @import("host_gui_options");
const stress_opts = @import("host_stress_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const abi = @import("ziggurat_abi");
const sdk_options = @import("sdk_options");
const testing = std.testing;
const Io = std.Io;
const io = testing.io;

/// One deadline for a whole Godot run, in seconds.
const deadline_s = "120";

fn requireIntegration() error{SkipZigTest}!void {
    if (!opts.run_integration) return error.SkipZigTest;
}

/// A temporary copy of a fixture project with the host installed.
const Project = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    path: []const u8,
    /// The environment Godot runs with; null inherits the test's.
    env: ?*std.process.Environ.Map = null,

    fn init(p: *Project, fixture: []const u8) !void {
        return p.initWith(fixture, opts.host_lib);
    }

    /// As `init`, with the host built with `test_probe` (`ZigguratTestProbe`).
    fn initProbe(p: *Project, fixture: []const u8) !void {
        return p.initWith(fixture, opts.probe_host_lib);
    }

    fn initWith(p: *Project, fixture: []const u8, host_lib: []const u8) !void {
        return p.initFrom(opts.projects_dir, fixture, host_lib);
    }

    /// As `init`, with the project `fixture` of folder `root`.
    fn initFrom(p: *Project, root: []const u8, fixture: []const u8, host_lib: []const u8) !void {
        p.env = null;
        p.arena_state = .init(testing.allocator);
        errdefer p.arena_state.deinit();
        const a = p.arena_state.allocator();
        p.tmp = testing.tmpDir(.{});
        errdefer p.tmp.cleanup();
        const cwd = Io.Dir.cwd();

        var projects = try cwd.openDir(io, root, .{});
        defer projects.close(io);
        var src = try projects.openDir(io, fixture, .{ .iterate = true });
        defer src.close(io);
        try p.tmp.dir.createDirPath(io, "project");
        var dst = try p.tmp.dir.openDir(io, "project", .{});
        defer dst.close(io);
        try copyTree(a, src, dst);

        try dst.createDirPath(io, "addons/ziggurat/bin");
        try cwd.copyFile(host_lib, dst, "addons/ziggurat/bin/libziggurat_host.so", io, .{});
        try cwd.copyFile(opts.gdextension, dst, "addons/ziggurat/ziggurat.gdextension", io, .{});
        p.path = try p.tmp.dir.realPathFileAlloc(io, "project", a);
    }

    fn deinit(p: *Project) void {
        if (p.env) |e| e.deinit();
        p.tmp.cleanup();
        p.arena_state.deinit();
    }

    /// Copies test/host/checks/<name> into the project as `res://check.gd`.
    fn addCheck(p: *Project, name: []const u8) !void {
        return p.addCheckFrom(opts.checks_dir, name);
    }

    /// As `addCheck`, with the file `name` of folder `dir`.
    fn addCheckFrom(p: *Project, dir: []const u8, name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        var checks = try cwd.openDir(io, dir, .{});
        defer checks.close(io);
        var dst = try cwd.openDir(io, p.path, .{});
        defer dst.close(io);
        try checks.copyFile(name, dst, "check.gd", io, .{});
    }

    /// Adds test/host/checks/<name> as `res://check.gd` and makes it an
    /// autoload, so a `@tool` check runs inside the editor.
    fn addAutoloadCheck(p: *Project, name: []const u8) !void {
        return p.addAutoloadCheckFrom(opts.checks_dir, name);
    }

    /// As `addAutoloadCheck`, with the file `name` of folder `from`.
    fn addAutoloadCheckFrom(p: *Project, from: []const u8, name: []const u8) !void {
        try p.addCheckFrom(from, name);
        var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
        defer dir.close(io);
        const a = p.arena_state.allocator();
        const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
        const new = try std.mem.concat(a, u8, &.{ old, "\n[autoload]\n\ncheck=\"*res://check.gd\"\n" });
        try dir.writeFile(io, .{ .sub_path = "project.godot", .data = new });
    }

    /// Runs `res://check.gd` headless; every `expect` text must appear in
    /// Godot's output. Fails the test with the runner's report otherwise.
    fn runScript(p: *Project, expect: []const []const u8) !void {
        return p.run(&.{ "script", "res://check.gd" }, .{ .expect = expect });
    }

    /// As `runScript`; each `once` text must appear exactly once.
    fn runScriptOnce(p: *Project, expect: []const []const u8, once: []const []const u8) !void {
        return p.run(&.{ "script", "res://check.gd" }, .{ .expect = expect, .once = once });
    }

    /// Opens the project in the headless editor for `frames` frames.
    fn runEditor(p: *Project, frames: []const u8, expect: []const []const u8) !void {
        return p.run(&.{ "editor", frames }, .{ .expect = expect });
    }

    /// As `runEditor`, with every text check of the runner.
    fn runEditorChecked(p: *Project, frames: []const u8, texts: Texts) !void {
        return p.run(&.{ "editor", frames }, texts);
    }

    /// Output checks: each `expect` text must appear, each `once` text
    /// exactly once, and no `reject` text at all.
    const Texts = struct {
        expect: []const []const u8 = &.{},
        once: []const []const u8 = &.{},
        reject: []const []const u8 = &.{},
        /// Exact output lines the runner leaves out of its leak scan.
        allow_report: []const []const u8 = &.{},
        /// Godot output lines starting with one of these are printed also
        /// when the run passes.
        echo: []const []const u8 = &.{},
        /// When set, a passing run writes the `echo` lines to this file
        /// instead of stderr (the build runner labels a passing test that
        /// wrote to stderr with "failed command"; build.zig prints the file).
        echo_file: []const u8 = "",
        /// Seconds for the whole Godot run.
        deadline: []const u8 = deadline_s,
        /// The exit status Godot must end with.
        exit_code: []const u8 = "0",
    };

    fn run(p: *Project, mode: []const []const u8, texts: Texts) !void {
        const a = p.arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ opts.runner_exe, opts.godot_exe, p.path });
        try argv.appendSlice(a, mode);
        try argv.append(a, texts.deadline);
        for (texts.expect) |text| try argv.appendSlice(a, &.{ "--expect", text });
        for (texts.once) |text| try argv.appendSlice(a, &.{ "--expect-once", text });
        for (texts.reject) |text| try argv.appendSlice(a, &.{ "--reject", text });
        for (texts.allow_report) |text| try argv.appendSlice(a, &.{ "--allow-report", text });
        for (texts.echo) |text| try argv.appendSlice(a, &.{ "--echo", text });
        try argv.appendSlice(a, &.{ "--exit-code", texts.exit_code });
        const result = try std.process.run(a, io, .{ .argv = argv.items, .environ_map = p.env });
        if (result.term.success()) {
            if (texts.echo.len == 0) return;
            if (texts.echo_file.len == 0) {
                std.debug.print("{s}", .{result.stderr});
            } else {
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = texts.echo_file, .data = result.stderr });
            }
            return;
        }
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.GodotRunFailed;
    }
};

test "host loads" {
    try requireIntegration();
    var p: Project = undefined;
    try p.init("empty");
    defer p.deinit();
    try p.addCheck("host_loads.gd");
    try p.runScript(&.{"ziggurat_host 0.1.0 ready"});
}

test "host loads in editor" {
    try requireIntegration();
    var p: Project = undefined;
    try p.init("empty");
    defer p.deinit();
    // An autoload makes the editor call _add_named_global_constant, one of
    // the virtuals gdzig's unpatched branch quota could not compile.
    try p.addAutoloadCheck("host_loads_editor.gd");
    try p.runEditor("30", &.{"ziggurat_host 0.1.0 ready"});
}

// ------------------------------------------------------------ user modules

/// gdzig is large: a cold build of a module that imports it takes tens of seconds.
const build_wait_ms = 600_000;

/// The layout stamp the host expects, computed as the host computes it.
const host_stamp: u64 = abi.expectedStamp(sdk_options);

/// Builds the scripts of test/fixtures/<fixture> with the build service and
/// the SDK modules `sdk`, under `<work>/<name>/`, and returns the path of the
/// staged library (allocated with `a`). `check_tables` makes the service
/// check the table against the host's stamp, as the editor will.
fn buildModule(
    a: std.mem.Allocator,
    work: []const u8,
    name: []const u8,
    fixture: []const u8,
    sdk: []const zbuild.workspace.ModuleDep,
    check_tables: bool,
) ![]const u8 {
    const dir = try std.fs.path.join(a, &.{ opts.fixtures_dir, fixture });
    switch (try buildModuleFrom(a, work, name, dir, sdk, check_tables)) {
        .ok => |lib| return lib,
        .failed => |message| {
            std.debug.print("build of {s} failed: {s}\n", .{ name, message });
            return error.BuildFailed;
        },
    }
}

const BuildResult = union(enum) {
    /// The staged library.
    ok: []const u8,
    /// The service's message and diagnostics, as text.
    failed: []const u8,
};

/// As `buildModule`, from the scripts in the folder `src_dir`. A build that
/// fails is a result, not an error.
fn buildModuleFrom(
    a: std.mem.Allocator,
    work: []const u8,
    name: []const u8,
    src_dir: []const u8,
    sdk: []const zbuild.workspace.ModuleDep,
    check_tables: bool,
) !BuildResult {
    const cwd = Io.Dir.cwd();
    const root = try std.fs.path.join(a, &.{ work, name });
    const src_path = try std.fs.path.join(a, &.{ root, "src" });
    const cache = try std.fs.path.join(a, &.{ work, "cache" });
    const store = try std.fs.path.join(a, &.{ root, "store" });
    try cwd.createDirPath(io, src_path);
    try cwd.createDirPath(io, cache);

    var src = try cwd.openDir(io, src_dir, .{ .iterate = true });
    defer src.close(io);
    var dst = try cwd.openDir(io, src_path, .{});
    defer dst.close(io);
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dst.createDirPath(io, entry.path),
            .file => try src.copyFile(entry.path, dst, entry.path, io, .{}),
            else => {},
        }
    }

    const env: platform.path.HostEnv = .{ .os = builtin.os.tag, .home = cache, .xdg_cache_home = cache, .local_app_data = cache };
    const svc = try zbuild.service.BuildService.init(testing.allocator, io, .{
        .paths = .init(.{ .project = .fromTrusted(src_path) }, env),
        .locate = .{
            .configured = .fromTrusted(opts.zig_exe),
            .toolchain_dir = .fromTrusted(work),
            .env = env,
        },
        .sdk = sdk,
        .store_root = .fromTrusted(store),
        .check_tables = check_tables,
        .expected_stamp = host_stamp,
        // One full build is all a test needs: no incremental server.
        .policy_override = .{ .incremental = false, .use_llvm = false, .optimize = .Debug },
    });
    defer svc.deinit();
    svc.request(.open);
    try svc.waitIdle(build_wait_ms);
    const o = svc.last() orelse return error.NoOutcome;
    if (!o.ok) {
        var text: std.ArrayList(u8) = .empty;
        try text.print(a, "{?s}", .{o.message});
        for (o.diagnostics) |d| try text.print(a, "\n  {?s}:{d}:{d}: {s}", .{ d.rel, d.line, d.column, d.message });
        return .{ .failed = text.items };
    }
    const gen = o.generation orelse return error.NoGeneration;
    return .{ .ok = try a.dupe(u8, gen.lib.bytes) };
}

/// The SDK manifest the build wrote (`opts.sdk_manifest_path`).
fn loadManifest(a: std.mem.Allocator) !zbuild.sdk_manifest.Manifest {
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    const path = try Io.Dir.cwd().realPathFileAlloc(io, opts.sdk_manifest_path, a);
    defer a.free(path);
    return zbuild.sdk_manifest.load(a, io, .fromTrusted(path), &msg) catch |err| {
        std.debug.print("manifest: {s}\n", .{msg.items});
        return err;
    };
}

/// `modules` with the `sdk_options` module replaced by a copy whose
/// `sdk_version` is `version`, written under `work`.
fn withSdkVersion(a: std.mem.Allocator, work: []const u8, modules: []const zbuild.workspace.ModuleDep, version: []const u8) ![]zbuild.workspace.ModuleDep {
    const out = try a.dupe(zbuild.workspace.ModuleDep, modules);
    for (out) |*m| {
        if (!std.mem.eql(u8, m.name, "sdk_options")) continue;
        const cwd = Io.Dir.cwd();
        const old = try cwd.readFileAlloc(io, m.root.bytes, a, .limited(16 << 20));
        const needle = try std.fmt.allocPrint(a, "pub const sdk_version = \"{s}\";", .{sdk_options.sdk_version});
        if (std.mem.indexOf(u8, old, needle) == null) return error.NoSdkVersionLine;
        const line = try std.fmt.allocPrint(a, "pub const sdk_version = \"{s}\";", .{version});
        const new = try std.mem.replaceOwned(u8, a, old, needle, line);
        const path = try std.fs.path.join(a, &.{ work, "other_sdk_options.zig" });
        try cwd.writeFile(io, .{ .sub_path = path, .data = new });
        m.root = .fromTrusted(path);
        return out;
    }
    return error.NoSdkOptionsModule;
}

/// Writes the first half of the file at `from` to `to`.
fn writeTruncated(a: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, from, a, .limited(1 << 30));
    try cwd.writeFile(io, .{ .sub_path = to, .data = bytes[0 .. bytes.len / 2] });
}

test "runtime: load good module, load refuses bad module, name maps use interned names" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    const a = p.arena_state.allocator();

    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);

    // The fixture project, built and table-checked as the editor will.
    const good = try buildModule(a, work, "good", "sdk_project", manifest.modules, true);
    // The same scripts against an SDK with another version: another stamp.
    // The service cannot check the table against the host's stamp here.
    const other = try withSdkVersion(a, work, manifest.modules, "0.0.0-other");
    const other_staged = try buildModule(a, work, "other_sdk", "sdk_project", other, false);
    // A file name of its own, so the refusal sentence tells it from `good`.
    const other_sdk = try std.fs.path.join(a, &.{ work, "libother_sdk.so" });
    try Io.Dir.cwd().copyFile(other_staged, Io.Dir.cwd(), other_sdk, io, .{});
    const truncated = try std.fs.path.join(a, &.{ work, "libtruncated.so" });
    try writeTruncated(a, good, truncated);
    // A hard link and a symbolic link to the good library: one file under
    // other names, which must never run as a second generation.
    const hard = try std.fs.path.join(a, &.{ work, "libhard.so" });
    try Io.Dir.cwd().hardLink(good, Io.Dir.cwd(), hard, io, .{});
    const soft = try std.fs.path.join(a, &.{ work, "libsoft.so" });
    try Io.Dir.cwd().symLink(io, good, soft, .{});

    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const list = try std.fmt.allocPrint(a, "good={s}\nother_sdk={s}\ntruncated={s}\nhard={s}\nsoft={s}\n", .{ good, other_sdk, truncated, hard, soft });
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = list });

    try p.addCheck("runtime_load.gd");
    try p.runScript(&.{
        "ZTEST PASS load_good_module",
        "ZTEST PASS load_refuses_bad_module",
        "ZTEST PASS load_refuses_same_file_hard_link",
        "ZTEST PASS load_refuses_same_file_symbolic_link",
        "ZTEST PASS name_maps_use_interned_names",
        // HostApi.log and request_swap (runtime_load.gd, host_api).
        "[ziggurat] info from main\n",
        "[ziggurat] warning from main",
        "[ziggurat] error from main",
        "[ziggurat] info from thread 49\n",
        "[ziggurat] swap requested, but no newer build is loaded (logged once)",
        "ERROR: [ziggurat] Ziggurat cannot load the module libzmod.1.so from a thread other than the main thread.",
    });
}

// ------------------------------------------------------------ descriptors

/// Builds the `sdk_project` fixture as the editor would and lists the staged
/// library in `res://modules.txt` of `p` as `good=<path>`.
fn buildGoodModule(p: *Project) !void {
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const good = try buildModule(a, work, "good", "sdk_project", manifest.modules, true);
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const list = try std.fmt.allocPrint(a, "good={s}\n", .{good});
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = list });
}

test "property list matches descriptors" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildGoodModule(&p);
    try p.addCheck("descriptor_props.gd");
    try p.runScript(&.{
        "ZTEST PASS property_list_player\n",
        "ZTEST PASS property_list_player_matches_descriptor_indexes",
        "ZTEST PASS method_list_player",
        "ZTEST PASS signal_list_player",
        "ZTEST PASS defaults_player",
        "ZTEST PASS default_out_of_range",
        "ZTEST PASS property_list_coin",
        "ZTEST PASS signal_list_coin",
        "ZTEST PASS method_list_coin_return_type",
        "ZTEST PASS method_list_hud_virtual",
        "ZTEST PASS empty_lists",
    });
}

test "cache round trip" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildGoodModule(&p);
    // Run 1 loads the module and writes the cache; run 2 is a fresh Godot
    // process that only reads it.
    try p.addCheck("descriptor_cache.gd");
    try p.runScript(&.{
        "ZTEST PASS cache_write_load",
        "ZTEST PASS cache_write\n",
        "ZTEST PASS cache_write_twice_no_temporary_file",
        "ZTEST PASS snapshot_cache_equals_live",
        "ZTEST PASS cache_is_json",
        "ZTEST PASS cache_fields",
    });
    try p.runScript(&.{
        "ZTEST PASS fresh_process_has_no_module",
        "ZTEST PASS cache_read\n",
        "ZTEST PASS cache_lists_and_defaults_equal_loaded",
        "ZTEST PASS cache_unknown_script",
        "ZTEST PASS cache_missing_file",
    });
}

test "snapshot defaults equal the module's for every vector type" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const good = try buildModule(a, work, "vectors", "vector_project", manifest.modules, true);
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = try std.fmt.allocPrint(a, "good={s}\n", .{good}) });
    try p.addCheck("snapshot_vectors.gd");
    try p.runScript(&.{
        "ZTEST PASS vectors_load",
        "ZTEST PASS vectors_files_written",
        "ZTEST PASS vectors_snapshot_equals_live",
        "ZTEST PASS vectors_all_have_defaults",
        "ZTEST PASS vectors_component_order",
    });
}

test "defaults round trip as typed JSON" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try p.addCheck("descriptor_defaults.gd");
    try p.runScript(&.{
        "ZTEST PASS roundtrip_bool_true",
        "ZTEST PASS roundtrip_int_large",
        "ZTEST PASS roundtrip_int_min",
        "ZTEST PASS roundtrip_float_tiny",
        "ZTEST PASS roundtrip_string\n",
        "ZTEST PASS roundtrip_string_name",
        "ZTEST PASS roundtrip_node_path",
        "ZTEST PASS roundtrip_vector2\n",
        "ZTEST PASS roundtrip_vector2i",
        "ZTEST PASS roundtrip_rect2\n",
        "ZTEST PASS roundtrip_rect2i",
        "ZTEST PASS roundtrip_vector3\n",
        "ZTEST PASS roundtrip_vector3i",
        "ZTEST PASS roundtrip_transform2d",
        "ZTEST PASS roundtrip_vector4\n",
        "ZTEST PASS roundtrip_vector4i",
        "ZTEST PASS roundtrip_plane",
        "ZTEST PASS roundtrip_quaternion",
        "ZTEST PASS roundtrip_aabb",
        "ZTEST PASS roundtrip_basis",
        "ZTEST PASS roundtrip_transform3d",
        "ZTEST PASS roundtrip_projection",
        "ZTEST PASS roundtrip_color",
        "ZTEST PASS roundtrip_float_nan",
        "ZTEST PASS roundtrip_float_inf",
        "ZTEST PASS roundtrip_float_minus_inf",
        "ZTEST PASS roundtrip_object_null",
        "ZTEST PASS object_is_never_stored_as_data",
        "ZTEST PASS mismatched_type_has_no_stored_form",
        "ZTEST PASS non_finite_component_has_no_stored_form",
    });
}

test "cache rejects garbage" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildGoodModule(&p);
    try p.addCheck("descriptor_cache.gd");
    try p.runScript(&.{"ZTEST PASS cache_write\n"});
    try p.addCheck("descriptor_garbage.gd");
    try p.runScript(&.{
        "ZTEST PASS good_cache_reads",
        "ZTEST PASS rejects_truncated\n",
        "ZTEST PASS rejects_truncated_early",
        "ZTEST PASS rejects_version_1",
        "ZTEST PASS rejects_version_3",
        "ZTEST PASS rejects_version_word",
        "ZTEST PASS rejects_empty",
        "ZTEST PASS rejects_not_json",
        "ZTEST PASS rejects_binary",
        "ZTEST PASS rejects_wrong_type",
        "ZTEST PASS rejects_scripts_not_array",
        "ZTEST PASS rejects_bad_hash",
        "ZTEST PASS rejects_deep\n",
        "ZTEST PASS rejects_numeric_string_usage",
        "ZTEST PASS rejects_numeric_string_version",
        "ZTEST PASS rejects_deep_default\n",
        "ZTEST PASS rejects_deep_default_closed",
        "ZTEST PASS drops_drop_comment_attack",
        "ZTEST PASS drops_drop_object_text",
        "ZTEST PASS drops_drop_numeric_string",
        "ZTEST PASS drops_drop_float_for_int",
        "ZTEST PASS drops_drop_short_vector",
        "ZTEST PASS drops_drop_int_for_bool",
        "ZTEST PASS drops_drop_array_for_object",
        "ZTEST PASS string_default_is_plain_text",
        "ZTEST PASS good_cache_still_reads",
        "ZTEST PASS missing_file_is_silent",
        // One line per bad file, naming it and the reason.
        "truncated.json: the file is not valid JSON",
        "version_1.json: the file has version 1, but this host reads version 2.",
        "bad_hash.json: the file has a script with a bad layout hash.",
        "drop_comment_attack.json: 1 value(s) did not fit the type of their property.",
    });
}

// ------------------------------------------------------------ ZigScript

/// Copies the fixture's player.zig into `p` as `res://player_source.txt`
/// (not as a `.zig` file, which the editor would scan).
fn addPlayerSource(p: *Project) !void {
    const cwd = Io.Dir.cwd();
    var fixtures = try cwd.openDir(io, opts.fixtures_dir, .{});
    defer fixtures.close(io);
    var dst = try cwd.openDir(io, p.path, .{});
    defer dst.close(io);
    try fixtures.copyFile("sdk_project/player.zig", dst, "player_source.txt", io, .{});
}

test "script reports descriptors, script without descriptors, update_exports is idempotent" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildGoodModule(&p);
    try addPlayerSource(&p);
    // Run 1 answers from the loaded module and writes the descriptor cache;
    // run 2 is a fresh Godot process whose language reads that cache.
    try p.addCheck("script_descriptors.gd");
    try p.runScriptOnce(&.{
        "ZTEST PASS script_without_descriptors\n",
        "ZTEST PASS script_without_descriptors_unknown_path",
        "ZTEST PASS script_reports_descriptors_lists",
        "ZTEST PASS script_reports_descriptors_queries",
        "ZTEST PASS script_path_normalised",
        "ZTEST PASS script_reports_descriptors_defaults_members",
        "ZTEST PASS script_reports_descriptors_member_lines",
        "ZTEST PASS script_source_code",
        "ZTEST PASS can_instantiate_game",
        "ZTEST PASS instance_create_refused",
        "ZTEST PASS reload_returns_ok",
        "ZTEST PASS script_cache_write",
        // A Node is not a CharacterBody2D: refused, one line per attempt.
        "ERROR: Script res://player.zig extends CharacterBody2D, so it cannot be attached to an object of class Node.",
    }, &.{
        // Two reloads, one line.
        "Script res://player.zig reloads when a new build is loaded",
    });
    try p.runScriptOnce(&.{
        "ZTEST PASS second_run_has_no_module",
        "ZTEST PASS script_reports_descriptors_from_cache\n",
        "ZTEST PASS script_reports_descriptors_from_cache_queries",
        "ZTEST PASS cache_only_instance_refused",
        "ZTEST PASS update_exports_is_idempotent",
        "ZTEST PASS has_default_same_from_cache_and_module",
        "ZTEST PASS cache_ignored_after_load",
        "ZTEST PASS script_reports_loaded_after_cache",
    }, &.{
        // Two refused attempts while only the cache describes the script.
        "ERROR: Script res://player.zig cannot create instances yet.",
    });
}

test "can_instantiate rule in the editor" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildGoodModule(&p);
    // A script run writes the descriptor cache; the editor reads it at
    // startup and loads no module.
    try p.addCheck("descriptor_cache.gd");
    try p.runScript(&.{"ZTEST PASS cache_write\n"});
    try p.addAutoloadCheck("script_editor.gd");
    try p.runEditor("30", &.{
        "ZTEST PASS editor_descriptors_from_cache",
        "ZTEST PASS can_instantiate_editor_non_tool",
        "ZTEST PASS can_instantiate_editor_tool",
        "ZTEST PASS can_instantiate_editor_no_descriptors",
        "ZTEST PASS editor_placeholder_created",
        "ZTEST PASS editor_load_module",
        "ZTEST PASS editor_rule_after_load",
    });
}

// ------------------------------------------------------------ instances

/// Builds the `instance_project` fixture and lists the staged library in
/// `res://modules.txt` of `p` as `good=<path>`.
fn buildInstanceModule(p: *Project) !void {
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const good = try buildModule(a, work, "good", "instance_project", manifest.modules, true);
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const list = try std.fmt.allocPrint(a, "good={s}\n", .{good});
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = list });
}

test "ready runs, properties through the object, call falls through, strong reference, wrong owner type" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildInstanceModule(&p);
    try p.addCheck("instances.gd");
    try p.runScriptOnce(&.{
        "ZTEST PASS attach\n",
        "ZTEST PASS strong_reference",
        "ZTEST PASS instance_count",
        "ZTEST PASS ready_runs",
        "ZTEST PASS notifications_forwarded",
        "ZTEST PASS properties_get_set",
        "ZTEST PASS property_list_through_object",
        "ZTEST PASS property_revert",
        "ZTEST PASS property_state",
        "ZTEST PASS to_string",
        "ZTEST PASS call_falls_through",
        "ZTEST PASS call_errors",
        "ZTEST PASS wrong_owner_refused",
        "ZTEST PASS derived_owner_accepted",
        "ZTEST PASS instance_freed",
        "ZTEST PASS attach_idle",
        "ZTEST PASS process_only_when_defined",
        "ZTEST PASS instances_released",
        "ZTEST PASS refcounted_owner_attached",
        "ZTEST PASS refcounted_owner_released",
    }, &.{
        // `_ready` ran once, through the instance (two instances of mover
        // were made, but only one entered the tree).
        "[ziggurat] mover ready speed=5\n",
        // One line naming the script and both classes.
        "ERROR: Script res://mover.zig extends Node2D, so it cannot be attached to an object of class Node.",
        // The RefCounted owner died with its last reference: deinit ran once.
        "[ziggurat] keeper deinit uses=7\n",
    });
}

// ------------------------------------------------------------ gate

test "gate: depth counts nested entries, try-lock fails while a reader holds, threads during swap, migrating instance refuses calls, create racing a swap, shutdown race closed" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const good = try buildModule(a, work, "good", "gate_project", manifest.modules, true);
    // A copy (another file) loads as a second generation of the same code.
    const good2 = try std.fs.path.join(a, &.{ work, "libgate2.so" });
    try Io.Dir.cwd().copyFile(good, Io.Dir.cwd(), good2, io, .{});
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = try std.fmt.allocPrint(a, "good={s}\ngood2={s}\n", .{ good, good2 }) });

    try p.addCheck("gate.gd");
    try p.runScriptOnce(&.{
        "ZTEST PASS load\n",
        "ZTEST PASS depth_counts_nested_entries",
        "ZTEST PASS try_lock_fails_while_reader_holds",
        "ZTEST PASS threads_during_swap",
        "ZTEST PASS migrating_instance_refuses_calls",
        "ZTEST PASS migrating_instance_freed_after_migration",
        "ZTEST PASS nested_frame_runs_no_queue_and_no_swap",
        "ZTEST PASS registry_matches_live",
        "ZTEST PASS instances_released",
        "ZTEST PASS bytes_released",
        "ZTEST PASS create_racing_swap_lands_on_current",
    }, &.{
        // Two refused calls (and a refused get and set) on one instance in
        // one migration: one line.
        "Ziggurat refused an entry into an instance of res://counter.zig while it is being migrated to new code.",
        "Ziggurat refused an entry into an instance of res://holder.zig while it is being migrated to new code.",
    });

    try p.addCheck("gate_shutdown.gd");
    try p.runScript(&.{
        "ZTEST PASS load\n",
        "ZTEST PASS shutdown_race_closed",
        "ZTEST PASS call_after_shutdown",
    });
}

// ------------------------------------------------------------ swaps

/// Builds test/fixtures/swap_v1 and swap_v2 (two builds of one project)
/// and lists them in the project's `modules.txt` as `v1=` and `v2=`.
fn buildSwapModules(p: *Project) !void {
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const v1 = try buildModule(a, work, "v1", "swap_v1", manifest.modules, true);
    const v2 = try buildModule(a, work, "v2", "swap_v2", manifest.modules, true);
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = try std.fmt.allocPrint(a, "v1={s}\nv2={s}\n", .{ v1, v2 }) });
}

test "swap: rollback on allocation failure, same layout keeps data, changed layout moves fields, migrate hook runs, freed instance gets one deinit, threads across two generations, placeholders refresh" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildSwapModules(&p);

    try p.addCheck("swap.gd");
    try p.run(&.{ "script", "res://check.gd" }, .{
        .expect = &.{
            "ZTEST PASS load\n",
            "ZTEST PASS stage\n",
            "ZTEST PASS rollback_on_allocation_failure",
            "ZTEST PASS swapped",
            "ZTEST PASS same_layout_keeps_data",
            "ZTEST PASS changed_layout_moves_fields",
            "ZTEST PASS migrate_hook_runs",
            "ZTEST PASS owned_fields_released_once",
            "ZTEST PASS owned_fields_released_with_instances",
            "ZTEST PASS instance_made_during_swap_on_new_generation",
            "ZTEST PASS script_missing_keeps_old_code",
            "ZTEST PASS old_generation_bytes_released",
            "ZTEST PASS registry_matches_live",
            "ZTEST PASS request_for_current_does_nothing",
            "ZTEST PASS instances_released",
        },
        .once = &.{
            // The old deinit ran exactly once per instance: on generation 1
            // for each migrated instance (after its moved `id` was reset),
            // for the one freed before the swap and for the one freed during
            // the swap before it was reached.
            "mover deinit gen=1 hp=1 id=0\n",
            "mover deinit gen=1 hp=2 id=0\n",
            "mover deinit gen=1 hp=5 id=0\n",
            "mover deinit gen=1 hp=6 id=6\n",
            "mover deinit gen=1 hp=9 id=9\n",
            // Freed during the swap after its migration: the new deinit.
            "mover deinit gen=2 id=5\n",
            // Freed at the end, on generation 2.
            "mover deinit gen=2 id=1\n",
            "mover deinit gen=2 id=2\n",
            "mover deinit gen=2 id=7\n",
            // Logged once per script per swap.
            "mover.zig: field 'hp' was dropped (removed)",
            "mover.zig: field 'count' was dropped (type changed)",
            "mover.zig: field 'tag' was dropped (removed)",
            "mover.zig: field 'junk' was dropped (removed)",
            "mover.zig: field 'kind' was dropped (type changed)",
            "mover.zig: field 'skin' was dropped (type changed)",
            "oldonly.zig is not in build 2; its instances keep the old code",
            "ziggurat: swapped to build 2",
        },
        .reject = &.{
            "mover deinit gen=2 id=6\n",
            "mover deinit gen=1 hp=7",
            "mover deinit gen=2 id=9\n",
            "keeper.zig: field",
            // Read with `old.get` or taken by `migrate`: not dropped.
            "migrator.zig: field",
        },
    });

    try p.addCheck("swap_threads.gd");
    try p.runScriptOnce(&.{
        "ZTEST PASS load\n",
        "ZTEST PASS stack_info_from_threads",
        "ZTEST PASS threads_across_two_generations",
        "ZTEST PASS registry_matches_live",
        "ZTEST PASS bytes_released",
    }, &.{
        // Twenty swaps, two directions: each dropped field is logged once
        // per (script, old layout, new layout).
        "ticker.zig: field 'pad' was dropped (removed)",
        "ticker.zig: field 'pad2' was dropped (removed)",
    });

    try p.addAutoloadCheck("swap_editor.gd");
    try p.runEditorChecked("300", .{ .expect = &.{
        "ZTEST PASS editor_load",
        "ZTEST PASS placeholder_before_swap",
        "ZTEST PASS placeholders_refresh_after_swap",
    } });
}

// ------------------------------------------------------------ placeholders

/// Copies test/host/checks/<name> into `p` as `res://<as>`.
fn addCheckFile(p: *Project, name: []const u8, as: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var checks = try cwd.openDir(io, opts.checks_dir, .{});
    defer checks.close(io);
    var dst = try cwd.openDir(io, p.path, .{});
    defer dst.close(io);
    try checks.copyFile(name, dst, as, io, .{});
}

test "placeholder shows properties, tool script runs in the editor" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try buildInstanceModule(&p);
    // A script run writes the descriptor cache; the editor reads it at
    // startup, so the placeholder has descriptors before the module loads.
    try p.addCheck("instance_cache.gd");
    try p.runScript(&.{"ZTEST PASS instance_cache_written"});
    try p.addAutoloadCheck("placeholders_editor.gd");
    try p.runEditorChecked("120", .{
        .expect = &.{
            "ZTEST PASS editor_has_cached_descriptors",
            "ZTEST PASS placeholder_created",
            "ZTEST PASS placeholder_shows_properties_from_cache",
            "ZTEST PASS placeholder_keeps_set_values",
            "ZTEST PASS placeholder_ready_not_run",
            "ZTEST PASS editor_load_module",
            "ZTEST PASS placeholder_refreshed_once_per_generation",
            "ZTEST PASS build_failed_enables_fallback",
            "ZTEST PASS tool_script_real_instance",
            "ZTEST PASS tool_script_ready_ran",
            "ZTEST PASS placeholder_erased",
        },
        // The tool script's `_ready` ran once, in the editor.
        .once = &.{"[ziggurat] gadget ready calls=1\n"},
        // The non-tool script's `_ready` never ran.
        .reject = &.{"mover ready"},
    });
}

test "scene save keeps values without descriptors" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    // No descriptor cache and no module: the script has no descriptors.
    try addCheckFile(&p, "placeholder_scene.tscn", "saved.tscn");
    try p.addAutoloadCheck("placeholder_save.gd");
    try p.runEditorChecked("120", .{ .expect = &.{
        "ZTEST PASS no_descriptors",
        "ZTEST PASS scene_opened_with_placeholder",
        "ZTEST PASS scene_save_keeps_values_without_descriptors",
    } });
}

// ------------------------------------------------------------ language

test "language: global class scan, validate from diagnostics, completion, frame queue" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("language");
    defer p.deinit();
    try p.addCheck("language.gd");
    try p.runScript(&.{
        "ZTEST PASS global_class_top_level",
        "ZTEST PASS global_class_subfolder",
        "ZTEST PASS global_class_none res://plain.zig",
        "ZTEST PASS global_class_none res://commented.zig",
        "ZTEST PASS global_class_none res://nested.zig",
        "ZTEST PASS global_class_none res://missing.zig",
        "ZTEST PASS global_class_none user://alpha.zig",
        "ZTEST PASS global_class_none res://../alpha.zig",
        "ZTEST PASS validate_unknown_file_valid",
        "ZTEST PASS validate_cached_error",
        "ZTEST PASS validate_other_file_unaffected",
        "ZTEST PASS validate_after_good_build",
        "ZTEST PASS validate_line_zero_clamped",
        "ZTEST PASS complete_code_empty_ok",
        "ZTEST PASS lookup_code_unavailable",
        "ZTEST PASS queue_pushed",
        "ZTEST PASS frame_drains_queue_bounded",
    });
}

test "language in the editor: templates through Create Script, autoload constant" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    // The check is an autoload, so the editor calls _add_named_global_constant.
    try p.addAutoloadCheck("language_editor.gd");
    try p.runEditorChecked("120", .{
        .expect = &.{
            "ZTEST PASS autoload_named_global_constant",
            "ZTEST PASS template_offered",
            "ZTEST PASS make_template_default",
            "ZTEST PASS make_template_templates_off",
            "ZTEST PASS make_template_non_node_init",
            "ZTEST PASS make_template_refuses_script_parent",
        },
        // Godot names a missing or failing virtual in its error line.
        .reject = &.{"_add_named_global_constant"},
    });
}

// ------------------------------------------------------------ loader and saver

test "loader and saver: extension, load, broken and missing files, side effects, atomic save, hook" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("resource_files");
    defer p.deinit();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "tab_in.txt", .data = tab_script });
    try p.addCheck("resource_files.gd");
    try p.runScript(&.{
        "ZTEST PASS extension_zig_recognized\n",
        "ZTEST PASS extension_zig_recognized_for_zigscript",
        "ZTEST PASS saver_extension_zig",
        "ZTEST PASS saver_ignores_other_resources",
        "ZTEST PASS loader_ignores_other_types",
        "ZTEST PASS exists_true",
        "ZTEST PASS exists_false",
        "ZTEST PASS load_returns_zigscript",
        "ZTEST PASS load_source_text",
        "ZTEST PASS load_sets_path",
        "ZTEST PASS load_reuses_cached",
        "ZTEST PASS load_ignore_cache_is_new_object",
        "ZTEST PASS load_ignore_sets_path",
        "ZTEST PASS load_ignore_not_in_cache",
        "ZTEST PASS load_type_hint",
        "ZTEST PASS invalid_utf8_fails_to_load",
        "ZTEST PASS reload_scripts_rereads_file",
        "ZTEST PASS reload_tool_script_rereads_file",
        "ZTEST PASS reload_unsaved_script_keeps_text",
        "ZTEST PASS reload_unreadable_file_keeps_text",
        "Cannot load res://bad_utf8.zig: the file is not valid UTF-8.",
        "ZTEST PASS broken_script_loads",
        "ZTEST PASS missing_file_is_null",
        "ZTEST PASS missing_folder_is_null",
        "ZTEST PASS loader_is_side_effect_free",
        "ZTEST PASS save_ok",
        "ZTEST PASS save_writes_text",
        "ZTEST PASS save_then_load_roundtrip",
        "ZTEST PASS save_replaces_whole_file",
        "ZTEST PASS save_to_own_path",
        "ZTEST PASS save_leaves_no_temporary_file",
        "ZTEST PASS save_missing_folder_fails",
        "ZTEST PASS save_other_resource_unrecognized",
        "ZTEST PASS save_wrong_extension_unrecognized",
        "ZTEST PASS save_is_atomic",
        "ZTEST PASS hook_called_with_project_relative_path",
        "ZTEST PASS hook_not_called_for_failures",
        "ZTEST PASS hook_not_called_outside_project",
        "ZTEST PASS tab_save_written",
    });
}

/// A script indented with tabs, as the script editor writes it on save
/// (`convert_indent_on_save`). Built here, not kept as a fixture file,
/// because `zig fmt` turns tabs into spaces.
const tab_script =
    "const z = @import(\"ziggurat\");\n" ++
    "const g = z.godot;\n\n" ++
    "pub const extends = g.Node;\n\n" ++
    "base: *g.Node,\n" ++
    "count: i32 = 0,\n\n" ++
    "pub fn ping(self: *@This(), x: i32) i32 {\n" ++
    "\tif (x > 0) {\n" ++
    "\t\tself.count += x;\n" ++
    "\t}\n" ++
    "\treturn self.count;\n" ++
    "}\n";

/// True when `text` has a tab in the white space that starts a line.
fn hasLeadingTab(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const rest = std.mem.trimStart(u8, line, " ");
        if (rest.len > 0 and rest[0] == '\t') return true;
    }
    return false;
}

/// Writes `text` as `<work>/<name>/tabby.zig` and builds that folder.
fn buildText(a: std.mem.Allocator, work: []const u8, name: []const u8, text: []const u8, sdk: []const zbuild.workspace.ModuleDep) !BuildResult {
    const src = try std.fs.path.join(a, &.{ work, try std.fmt.allocPrint(a, "{s}_src", .{name}) });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, src);
    const file = try std.fs.path.join(a, &.{ src, "tabby.zig" });
    try cwd.writeFile(io, .{ .sub_path = file, .data = text });
    return buildModuleFrom(a, work, name, src, sdk, true);
}

test "tabs compile or are converted" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("resource_files");
    defer p.deinit();
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);

    // The finding: does the real SDK build accept tab indentation?
    const accepted = switch (try buildText(a, work, "tabs_in", tab_script, manifest.modules)) {
        .ok => true,
        .failed => false,
    };
    // No stderr output on a pass: the build runner reports any as a failed command.

    // Save it through the saver, in Godot.
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "tab_in.txt", .data = tab_script });
    try p.addCheck("resource_files.gd");
    try p.runScript(&.{"ZTEST PASS tab_save_written"});
    const saved = try dir.readFileAlloc(io, "tab_out.zig", a, .limited(1 << 20));

    if (accepted) {
        // Nothing to convert: the saver writes the text as it is.
        try testing.expectEqualStrings(tab_script, saved);
    } else {
        // Converted: no tab starts a line, and the result builds.
        try testing.expect(!hasLeadingTab(saved));
        try testing.expect(saved.len > 0);
        switch (try buildText(a, work, "tabs_out", saved, manifest.modules)) {
            .ok => {},
            .failed => |message| {
                std.debug.print("converted script does not build: {s}\n", .{message});
                return error.ConvertedScriptDoesNotBuild;
            },
        }
    }
}

test "loader and saver in the editor: global class scan, file type, save from the script editor" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("language");
    defer p.deinit();
    try p.addAutoloadCheck("resource_editor.gd");
    try p.runEditorChecked("300", .{ .expect = &.{
        "ZTEST PASS scan_global_class_top_level",
        "ZTEST PASS scan_global_class_subfolder",
        "ZTEST PASS scan_no_class_without_class_name",
        "ZTEST PASS filesystem_file_type",
        "ZTEST PASS global_class_resolves_to_script",
        "ZTEST PASS editor_save_written",
        "ZTEST PASS editor_save_indentation",
        "ZTEST PASS editor_save_hook",
        "ZTEST PASS editor_save_loads_back",
    } });
}

// ------------------------------------------------------------ editor builds

/// Seconds for an editor run that builds the project (a cold build of a
/// module that imports gdzig takes tens of seconds, several of them more).
const build_deadline_s = "900";

/// Points the project settings `ziggurat/zig_path` and
/// `ziggurat/dev/sdk_manifest` at the test's Zig and SDK manifest, and gives
/// Godot a build cache inside the test's folder (`XDG_CACHE_HOME`), so the
/// editor builds the project at open and on save.
fn addBuildSettings(p: *Project) !void {
    return addBuildSettingsWith(p, opts.zig_exe);
}

/// As `addBuildSettings`, with `zig` as `ziggurat/zig_path`.
fn addBuildSettingsWith(p: *Project, zig: []const u8) !void {
    const a = p.arena_state.allocator();
    const manifest = try Io.Dir.cwd().realPathFileAlloc(io, opts.sdk_manifest_path, a);
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    const new = try std.fmt.allocPrint(a, "{s}\n[ziggurat]\n\nzig_path=\"{s}\"\ndev/sdk_manifest=\"{s}\"\n", .{ old, zig, manifest });
    try dir.writeFile(io, .{ .sub_path = "project.godot", .data = new });

    try p.tmp.dir.createDirPath(io, "cache");
    const cache = try p.tmp.dir.realPathFileAlloc(io, "cache", a);
    const env = try a.create(std.process.Environ.Map);
    env.* = try testing.environ.createMap(testing.allocator);
    p.env = env;
    try env.put("XDG_CACHE_HOME", cache);
}

/// A Zig for the editor that is a shell script around the real one, made
/// for tests that need a build to block or to fail (as Stage 1's e2e tests
/// did). `zig version` always runs. Otherwise it fails while the gate file
/// `fail` exists, waits while `block` exists, and refuses `-fincremental`
/// (no warm server, so every build runs the wrapper). The gate folder's path
/// is written to `res://gate.txt`. Returns the gate folder.
fn addZigWrapper(p: *Project) ![]const u8 {
    const a = p.arena_state.allocator();
    try p.tmp.dir.createDirPath(io, "gate");
    const gate = try p.tmp.dir.realPathFileAlloc(io, "gate", a);
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    const wrapper = try std.fs.path.join(a, &.{ root, "zig-wrapper.sh" });
    const script = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\gate='{s}'
        \\if [ "$1" != version ]; then
        \\  case " $* " in *" -fincremental "*) echo "wrapper: no incremental server here" >&2; exit 1;; esac
        \\  if [ -e "$gate/fail" ]; then echo "wrapper: failing on purpose" >&2; exit 1; fi
        \\  while [ -e "$gate/block" ]; do sleep 0.05; done
        \\fi
        \\exec '{s}' "$@"
        \\
    , .{ gate, opts.zig_exe });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = wrapper, .data = script });
    const chmod = try std.process.run(a, io, .{ .argv = &.{ "chmod", "755", wrapper } });
    if (!chmod.term.success()) return error.ChmodFailed;
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "gate.txt", .data = gate });
    try addBuildSettingsWith(p, wrapper);
    return gate;
}

/// Process ids whose command line mentions `needle` (Linux `/proc`).
fn processesMentioning(a: std.mem.Allocator, needle: []const u8) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var proc = Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return out.items;
    defer proc.close(io);
    var it = proc.iterate();
    while (try it.next(io)) |entry| {
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const path = try std.fmt.allocPrint(a, "{s}/cmdline", .{entry.name});
        const cmdline = proc.readFileAlloc(io, path, a, .limited(1 << 20)) catch continue;
        if (std.mem.indexOf(u8, cmdline, needle) != null) try out.append(a, pid);
    }
    return out.items;
}

test "editor builds at open, save triggers a build, broken build keeps the last good" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_build");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("editor_build.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS signal_names_without_descriptor",
            "ZTEST PASS tool_placeholder_before_build",
            "ZTEST PASS editor_builds_at_open",
            "ZTEST PASS manifest_written",
            "ZTEST PASS staged_library_exists",
            "ZTEST PASS descriptor_cache_written",
            "ZTEST PASS validate_after_good_build",
            "ZTEST PASS tool_placeholder_swapped",
            "ZTEST PASS save_triggers_a_build",
            "ZTEST PASS save_new_default",
            "ZTEST PASS external_edit_refreshed",
            "ZTEST PASS broken_build_keeps_last_good",
            "ZTEST PASS broken_build_diagnostics",
            "ZTEST PASS broken_build_other_file_valid",
            "ZTEST PASS broken_build_fallback",
            "ZTEST PASS repaired_build",
            // Each outcome: one line; the broken one prints each diagnostic.
            "ziggurat: build 1 loaded (open, ",
            "ziggurat: build 2 loaded (save, ",
            "ziggurat: build 3 loaded (save, ",
            "ERROR: walker.zig:9:",
            "build service stopped (0 threads left)",
        },
        .reject = &.{
            "is not set",
            "is not usable",
        },
        .deadline = build_deadline_s,
    });
}

test "load checks" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("load_checks");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("load_checks_editor.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS load_checks_build_done",
            "ZTEST PASS load_check_property_hides",
            "ZTEST PASS load_check_method_hides",
            "ZTEST PASS load_check_method_hides_signal",
            "ZTEST PASS load_check_signal_hides_method",
            "ZTEST PASS load_check_signal_hides_property",
            "ZTEST PASS load_check_kinds_count",
            "ZTEST PASS load_check_node_field",
            "ZTEST PASS load_check_clean",
            "ZTEST PASS load_check_generation_not_used",
            "ZTEST PASS load_check_generation_never_current",
            "ZTEST PASS load_check_marks_build_failed",
            "ERROR: named.zig: Property 'name' of res://named.zig hides Node.name; rename it or give it a name override in meta.",
            "ERROR: holder.zig: res://holder.zig extends Resource, which is not a Node, so field 'target' cannot hold a Node.",
            "ziggurat: build 1 failed the load checks (open, ",
        },
        .reject = &.{"ziggurat: build 1 loaded"},
        .deadline = build_deadline_s,
    });
}

test "editor reload: tool node gets new code, rejected build never loads, size warning once" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_reload");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("editor_reload_tool.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS tool_build_loaded",
            "ZTEST PASS tool_node_runs_build_1",
            "ZTEST PASS tool_node_gets_new_code",
            "ZTEST PASS tool_build_manifest",
            "ZTEST PASS rejected_build_never_loads",
            "ZTEST PASS hook_reload_tool_script_swaps",
            "ZTEST PASS hook_script_reload_swaps",
            "ZTEST PASS hook_request_swap_swaps",
            "ZTEST PASS tool_removed_live_node_gets_new_code",
            "ZTEST PASS tool_removed_loads_nothing",
            "ZTEST PASS tool_back_loads",
            "ziggurat: build 1 loaded (open, ",
            "ziggurat: build 2 loaded (save, ",
            "ziggurat: build 4 loaded (save, ",
            "ziggurat: build 5 ready (save, ",
            "ziggurat: build 6 loaded (save, ",
            "ziggurat: swapped to build 2 (1 instances kept their data, 0 migrated)",
            "ziggurat: build 3 failed the load checks (save, ",
            "Method 'get_name' of res://knob.zig hides Node.get_name",
        },
        .once = &.{
            "Ziggurat has loaded 1 builds (",
            "in this editor session; restart the editor to free them.",
            "ziggurat: build 4 has no tool scripts; the editor loads builds only while instances of earlier tool scripts are alive (logged once)",
        },
        .reject = &.{ "ziggurat: build 3 loaded", "ziggurat: build 5 loaded" },
        .deadline = build_deadline_s,
    });
}

test "editor reload: defaults after a layout change" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_defaults");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("editor_defaults.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS defaults_build_1",
            "ZTEST PASS defaults_after_layout_change",
            "ZTEST PASS new_instance_after_layout_change",
            "ZTEST PASS stale_defaults_rebuild_in_full",
            "ziggurat: build 2 loaded (save, incremental, ",
            "ziggurat: swapped to build 2 (0 instances kept their data, 1 migrated)",
            "ziggurat: build 3: the default of '(test)' in shift.zig differs from the build's table, so the fast rebuild kept old code; rebuilding in full",
            "ziggurat: build 4 loaded (save, full, ",
            "ziggurat: swapped to build 4 (2 instances kept their data, 0 migrated)",
        },
        .reject = &.{ "ziggurat: build 3 loaded", "swapped to build 3" },
        .deadline = build_deadline_s,
    });
}

test "editor reload: no tool scripts loads nothing" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_reload_plain");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("editor_reload_plain.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS plain_build_1",
            "ZTEST PASS plain_memory_exact",
            "ZTEST PASS plain_build_2",
            "ZTEST PASS plain_build_3",
            "ZTEST PASS snapshot_scene_opened",
            "ZTEST PASS snapshot_scene_save_keeps_values",
            "ZTEST PASS manifest_build_kept",
            "ziggurat: build 1 ready (open, ",
            "ziggurat: build 2 ready (save, ",
            "ziggurat: build 3 ready (save, ",
            "ziggurat: build 12 failed the load checks (save, ",
        },
        .once = &.{
            "Ziggurat has loaded 2 builds (",
            "in this editor session; restart the editor to free them.",
        },
        .reject = &.{ " loaded (", "generations loaded in this editor session", "swapped to build", "could not pin" },
        .deadline = build_deadline_s,
    });
    // A game from the manifest the editor wrote: build 3, which the editor
    // never loaded, runs the scene's Walker with its stored value.
    try p.run(&.{ "game", "res://saved.tscn" }, .{
        .once = &.{
            "ziggurat: generation 3 loaded",
            "[ziggurat] walker ready speed=9\n",
        },
        .reject = &.{ refused_prefix, "ziggurat: build" },
    });
}

test "staged builds stay pinned until the editor loads them; a dropped outcome releases its pin" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_reload");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("store_pins.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS pins_build_1",
            "ZTEST PASS pins_staged_kept",
            "ZTEST PASS pins_staged_builds_load",
            "ZTEST PASS pins_outcome_queued_at_quit",
            "ziggurat: build 2 loaded (manual, ",
            "ziggurat: build 3 loaded (manual, ",
            "ziggurat: build 4 loaded (manual, ",
        },
        .once = &.{"ziggurat: generation locks held after exit: 0\n"},
        .reject = &.{ "ziggurat: build 5", "could not pin" },
        .deadline = build_deadline_s,
    });
}

// ------------------------------------------------------------ stress

/// The ZTEST cases of test/host/stress/driver.gd.
const stress_cases = [_][]const u8{
    "ZTEST PASS stress_start",
    "ZTEST PASS stress_edits_applied",
    "ZTEST PASS saves",
    "ZTEST PASS moved_fields",
    "ZTEST PASS migrate_results",
    "ZTEST PASS type_change_default",
    "ZTEST PASS added_field_default",
    "ZTEST PASS owned_fields_kept",
    "ZTEST PASS new_code_no_invalid_method",
    "ZTEST PASS defaults_match_source",
    "ZTEST PASS new_instance_after_swap",
    "ZTEST PASS placeholder_default",
    "ZTEST PASS old_generations_released",
    "ZTEST PASS generation_count",
    "ZTEST PASS registry_matches_live",
    "ZTEST PASS broken_build_keeps_last_good",
    "ZTEST PASS nested_iteration_runs_frame",
    "ZTEST PASS nested_iteration_defers_the_swap",
    "ZTEST PASS threads_no_errors",
    "ZTEST PASS instances_released",
    // The nested frames deferred the swap: logged when the outcome changed
    // from waiting for the holding thread to waiting for the stack.
    "the swap to build ",
    "waits: a script call is on the main thread's stack",
    "waits for script calls on other threads to return",
    "mover.zig: field 'level' was dropped (type changed)",
    "mover.zig: field 'extra' was dropped (removed)",
};

// `zig build test` runs this with 20 edits (stress short), `zig build
// test-stress` with 300 (test/host/stress/driver.gd; edit counts in
// build.zig). One headless editor run.
test "reload stress: edits with swaps, threads and nested iteration" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initFrom(stress_opts.stress_dir, "project", opts.probe_host_lib);
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheckFrom(stress_opts.stress_dir, "driver.gd");
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    var buf: [160]u8 = undefined;
    // The driver's own watchdog ends the run a minute before the runner's
    // deadline, so a stuck run still shows its output.
    const deadline = try std.fmt.parseInt(u32, stress_opts.deadline_s, 10);
    const cfg = try std.fmt.bufPrint(&buf, "edits={d}\nbroken_every={d}\nnested_every={d}\nwatchdog_s={d}\n", .{
        stress_opts.edits, stress_opts.broken_every, stress_opts.nested_every, deadline -| 60,
    });
    try dir.writeFile(io, .{ .sub_path = "stress.cfg", .data = cfg });
    // Godot leaks one render instance per mesh preview in a headless run:
    // EditorInterface::make_mesh_previews (editor/editor_interface.cpp:220)
    // skips `free_rid(inst)` through ERR_CONTINUE when the dummy renderer
    // returns no image. Every edit that builds calls one preview; that
    // exact report, and no other, is allowed.
    const previews = stress_opts.edits - stress_opts.edits / stress_opts.broken_every;
    var leak_buf: [128]u8 = undefined;
    const leak = try std.fmt.bufPrint(&leak_buf, "ERROR: {d} RID allocations of type 'N17RendererSceneCull8InstanceE' were leaked at exit.", .{previews});
    try p.runEditorChecked("100000000", .{
        .expect = &stress_cases,
        .reject = &.{ "Program crashed", "Nonexistent function", "is not usable" },
        .allow_report = &.{leak},
        .echo = if (stress_opts.report_times) &.{"ZTEST INFO stress:"} else &.{},
        .echo_file = stress_opts.report_file,
        .deadline = stress_opts.deadline_s,
    });
}

test "a failure without file errors keeps the diagnostics" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_build");
    defer p.deinit();
    _ = try addZigWrapper(&p);
    try p.addAutoloadCheck("build_failures.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS failures_first_build",
            "ZTEST PASS failures_compile_error",
            "ZTEST PASS failure_without_file_errors_keeps_diagnostics",
            "build service stopped (0 threads left)",
        },
        // The outcome's message is printed once.
        .once = &.{"wrapper: failing on purpose"},
        .deadline = "300",
    });
}

test "shutdown during build" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_build");
    defer p.deinit();
    const gate = try addZigWrapper(&p);
    // The build at open waits at the gate until the editor has quit.
    var gate_dir = try Io.Dir.cwd().openDir(io, gate, .{});
    defer gate_dir.close(io);
    try gate_dir.writeFile(io, .{ .sub_path = "block", .data = "" });
    try p.addAutoloadCheck("build_shutdown.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS build_running_at_quit",
            "build service stopped (0 threads left)",
        },
        .reject = &.{"ziggurat: build 1"},
        .deadline = "120",
    });
    // The compiler wrapper ran with the project's paths on its command
    // line; none may outlive the editor.
    const left = try processesMentioning(p.arena_state.allocator(), p.path);
    if (left.len != 0) {
        std.debug.print("processes still running for {s}: {any}\n", .{ p.path, left });
        return error.CompilerOutlivedEditor;
    }
}

test "no builds in a non-interactive editor run" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_build");
    defer p.deinit();
    try addBuildSettings(&p);
    const a = p.arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://addons/ziggurat/ziggurat.gdextension\n" });
    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(120), .clock = .awake });
    const result = try std.process.run(a, io, .{
        .argv = &.{ opts.godot_exe, "--headless", "--path", p.path, "--import" },
        .environ_map = p.env,
        .timeout = .{ .deadline = deadline },
    });
    const out = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr });
    const skipped = std.mem.indexOf(u8, out, "Ziggurat does not build Zig scripts in this run (--import).") != null;
    const built = std.mem.indexOf(u8, out, "ziggurat: build") != null;
    var store_exists = true;
    dir.access(io, ".godot/ziggurat", .{}) catch {
        store_exists = false;
    };
    if (!result.term.success() or !skipped or built or store_exists) {
        std.debug.print("{s}\nexit {any}, skipped {any}, built {any}, store {any}\n", .{ out, result.term, skipped, built, store_exists });
        return error.ImportRunBuilt;
    }
}

// ------------------------------------------------------------ editor plugin

/// Gives Godot per-user folders inside the test's folder (editor settings,
/// data and the downloaded-Zig folder), so the user's own editor settings
/// and toolchains play no part and are not changed.
fn isolateUserFolders(p: *Project) !void {
    const a = p.arena_state.allocator();
    if (p.env == null) {
        const env = try a.create(std.process.Environ.Map);
        env.* = try testing.environ.createMap(testing.allocator);
        p.env = env;
    }
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    inline for (.{ "config", "data" }) |sub| try p.tmp.dir.createDirPath(io, sub);
    try p.env.?.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ root, "config" }));
    try p.env.?.put("XDG_DATA_HOME", try std.fs.path.join(a, &.{ root, "data" }));
}

test "editor plugin is present" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try isolateUserFolders(&p);
    try p.addAutoloadCheck("editor_plugin.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS editor_plugin_present",
            "ZTEST PASS editor_plugin_is_editor_plugin",
            "ZTEST PASS editor_plugin_callable",
            "ZTEST PASS editor_setting_zig_path",
        },
    });
}

test "zig tab uses the Zig highlighter" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.init("highlighter");
    defer p.deinit();
    try isolateUserFolders(&p);
    // No Zig: the build at open fails at once and builds nothing.
    try pathWithoutZig(&p);
    try p.addAutoloadCheck("highlighter.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS highlighter_current",
            "ZTEST PASS highlighter_name_zig",
            "ZTEST PASS highlighter_pub_keyword",
            "ZTEST PASS highlighter_doc_comment",
            "ZTEST PASS highlighter_code_point_columns",
            "ZTEST PASS highlighter_per_tab",
            "ZTEST DONE",
        },
        .reject = &.{"ZTEST FAIL"},
    });
}

test "zig tabs indent with spaces; setting off keeps godot's choice" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.init("highlighter");
    defer p.deinit();
    try isolateUserFolders(&p);
    // No Zig: the builds at open and on save fail at once.
    try pathWithoutZig(&p);
    try p.addAutoloadCheck("indent.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS indent_setting_default",
            "ZTEST PASS indent_spaces_on_open",
            "ZTEST PASS indent_spaces_after_settings_change",
            "ZTEST PASS indent_save_no_leading_tab",
            "ZTEST PASS indent_setting_off_godot_choice",
            "ZTEST PASS indent_setting_on_again",
            "ZTEST DONE",
        },
        .reject = &.{"ZTEST FAIL"},
    });
}

test "focus-in builds an external edit; interval check" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    try addBuildSettings(&p);
    try isolateUserFolders(&p);
    try p.addAutoloadCheck("external_edit.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS check_interval_default",
            "ZTEST PASS focus_in_builds_external_edit",
            "ZTEST PASS focus_in_unchanged_no_build",
            "ZTEST PASS interval_check_builds",
            "ZTEST DONE",
            "build service stopped (0 threads left)",
        },
        .reject = &.{"ZTEST FAIL"},
        .deadline = build_deadline_s,
    });
}

test "zig path: unusable path is logged once by the change check" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    try addBuildSettings(&p);
    try isolateUserFolders(&p);
    try p.addAutoloadCheck("zig_path_check.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS zig_path_unusable_not_checked",
            "ZTEST PASS zig_path_usable_checked",
            "ZTEST DONE",
            "build service stopped (0 threads left)",
        },
        // Three checks with the relative path: one line.
        .once = &.{"Ziggurat: the Zig path is not usable, so changed files are not checked: the project setting ziggurat/zig_path (relative/zig) is not usable, because it is not an absolute path."},
        .reject = &.{"ZTEST FAIL"},
        .deadline = build_deadline_s,
    });
}

test "no plugin in a game" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    try p.addCheck("no_plugin_game.gd");
    try p.run(&.{ "script", "res://check.gd" }, .{
        .expect = &.{ "ziggurat_host 0.1.0 ready", "ZTEST PASS no_plugin_in_game" },
        .reject = &.{ "ERROR:", "ZigEditorPlugin" },
    });
}

test "public build API" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_build");
    defer p.deinit();
    const a = p.arena_state.allocator();
    _ = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    // A Zig that reports another version.
    const old_zig = try std.fs.path.join(a, &.{ root, "old-zig.sh" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = old_zig, .data = "#!/bin/sh\necho 0.16.0\n" });
    const chmod = try std.process.run(a, io, .{ .argv = &.{ "chmod", "755", old_zig } });
    if (!chmod.term.success()) return error.ChmodFailed;
    const missing = try std.fs.path.join(a, &.{ root, "no-such-folder", "zig" });
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const wrapper = try std.fs.path.join(a, &.{ root, "zig-wrapper.sh" });
    try dir.writeFile(io, .{ .sub_path = "zigs.txt", .data = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ wrapper, old_zig, missing }) });
    try pathWithoutZig(&p);
    try p.addAutoloadCheck("editor_api.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS api_open_status",
            "ZTEST PASS api_request_known_trigger",
            "ZTEST PASS api_building",
            "ZTEST PASS api_manual_outcome",
            "ZTEST PASS api_reload_after_manifest",
            "ZTEST PASS api_session_start_resends",
            "ZTEST PASS api_zig_missing",
            "ZTEST PASS api_zig_wrong_version",
            "ZTEST PASS api_editor_setting_used",
            "ZTEST PASS api_project_setting_wins",
            "ZTEST PASS api_relative_path",
            "ZTEST PASS api_relative_editor_ignored",
            "ZTEST PASS api_diagnostics",
            "ZTEST PASS api_diagnostics_cleared",
            "ZTEST PASS api_unknown_trigger",
            "build service stopped (0 threads left)",
        },
        .deadline = build_deadline_s,
    });
}

/// Sets Godot's `PATH` to a folder that holds only `sleep` (the Zig
/// wrapper waits with it), so the locator finds no Zig there.
fn pathWithoutZig(p: *Project) !void {
    const a = p.arena_state.allocator();
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    try p.tmp.dir.createDirPath(io, "bin");
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const which = try std.process.run(a, io, .{ .argv = &.{ "sh", "-c", "command -v sleep" } });
    const sleep = std.mem.trim(u8, which.stdout, " \t\r\n");
    if (!which.term.success() or sleep.len == 0) return error.NoSleep;
    try Io.Dir.cwd().symLink(io, sleep, try std.fs.path.join(a, &.{ bin, "sleep" }), .{});
    try p.env.?.put("PATH", bin);
}

test "zig panel" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    const a = p.arena_state.allocator();
    _ = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    try pathWithoutZig(&p);
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    const wrapper = try std.fs.path.join(a, &.{ root, "zig-wrapper.sh" });
    const missing = try std.fs.path.join(a, &.{ root, "no-such-folder", "zig" });
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "zigs.txt", .data = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ wrapper, missing }) });
    try p.addAutoloadCheck("editor_panel.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS panel_dock",
            "ZTEST PASS panel_shows_build",
            "ZTEST PASS panel_download_menu_item",
            "ZTEST PASS panel_build_menu_item",
            "ZTEST PASS panel_build_button",
            "ZTEST PASS panel_failed_status",
            "ZTEST PASS panel_lists_errors",
            "ZTEST PASS panel_link_opens_script",
            "ZTEST PASS panel_failure_toast",
            "ZTEST PASS panel_missing_zig_toast",
            "ZTEST PASS panel_repaired",
            "build service stopped (0 threads left)",
        },
        .deadline = build_deadline_s,
    });
}

// ------------------------------------------------------------ zig download

const fixture_server = @import("fixture_server.zig");

const dl_archive = "zig-x86_64-linux-0.17.0.tar.xz";
const dl_mirror_prefix = "Ziggurat could not use the Zig mirror ";

/// A download test's world: the fixture server, its folder and the
/// per-user toolchains folder Godot uses.
const Download = struct {
    server: *fixture_server.Server,
    /// `https://127.0.0.1:<port>`: what the mirror list names (the probe
    /// maps it to plain http).
    base: []const u8,
    toolchains: []const u8,
    /// `<XDG_DATA_HOME>/ziggurat`, where the mirror list is cached.
    data: []const u8,
    www: []const u8,

    fn deinit(d: *Download) void {
        d.server.stop();
    }

    /// Writes the mirror list the server answers with.
    fn setList(d: *Download, p: *Project, mirrors: []const []const u8) !void {
        const a = p.arena_state.allocator();
        var text: std.ArrayList(u8) = .empty;
        for (mirrors) |m| try text.print(a, "{s}/{s}\n", .{ d.base, m });
        try writeIn(d.www, "community-mirrors.txt", text.items);
    }
};

fn writeIn(dir: []const u8, name: []const u8, data: []const u8) !void {
    var d = try Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    if (std.fs.path.dirname(name)) |sub| try d.createDirPath(io, sub);
    try d.writeFile(io, .{ .sub_path = name, .data = data });
}

/// Sets up a download test in project `p` (made with `initProbe`): the SDK
/// manifest but no Zig path, no Zig on `PATH`, per-user folders inside the
/// test folder, the fixture server with every mirror kind, the test
/// overrides in `res://download_cfg.txt`, the case in
/// `res://download_case.txt`, the mirror list `mirrors` and
/// test/host/checks/download.gd as the tool autoload. `official_ok` makes
/// the ziglang.org stand-in serve the good archive.
fn setupDownload(p: *Project, case: []const u8, mirrors: []const []const u8, official_ok: bool) !Download {
    const a = p.arena_state.allocator();
    // The SDK manifest without a Zig path, so the locator looks in the
    // toolchains folder.
    const manifest = try Io.Dir.cwd().realPathFileAlloc(io, opts.sdk_manifest_path, a);
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "project.godot", .data = try std.fmt.allocPrint(a, "{s}\n[ziggurat]\n\ndev/sdk_manifest=\"{s}\"\n", .{ old, manifest }) });
    try p.tmp.dir.createDirPath(io, "cache");
    const env = try a.create(std.process.Environ.Map);
    env.* = try testing.environ.createMap(testing.allocator);
    p.env = env;
    try env.put("XDG_CACHE_HOME", try p.tmp.dir.realPathFileAlloc(io, "cache", a));
    try isolateUserFolders(p);
    try pathWithoutZig(p);

    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    try p.tmp.dir.createDirPath(io, "www");
    const www = try std.fs.path.join(a, &.{ root, "www" });
    const server = try fixture_server.Server.start(testing.allocator, io, www);
    errdefer server.stop();
    const base = try std.fmt.allocPrint(a, "https://127.0.0.1:{d}", .{server.port});

    const archive_path = try std.fs.path.join(a, &.{ opts.fixtures_dir, "toolchain", dl_archive });
    const archive = try Io.Dir.cwd().readFileAlloc(io, archive_path, a, .limited(1 << 20));
    const signer = platform.minisign.TestSigner.init(7, .{ 9, 8, 7, 6, 5, 4, 3, 2 });
    const good_sig = try signer.signFile(a, archive, dl_archive);
    const old_sig = try signer.signFile(a, archive, "zig-x86_64-linux-0.16.0.tar.xz");
    const tampered = try a.dupe(u8, archive);
    tampered[tampered.len / 2] ^= 0x55;

    const sig_name = dl_archive ++ ".minisig";
    for ([_][]const u8{ "good", "redirect", "truncated", "slow", "trickle", "slowsig" }) |m| {
        try writeIn(www, try std.fs.path.join(a, &.{ m, sig_name }), good_sig);
    }
    try writeIn(www, "good/" ++ dl_archive, archive);
    if (official_ok) {
        try writeIn(www, "official/" ++ dl_archive, archive);
        try writeIn(www, "official/" ++ sig_name, good_sig);
    }
    try writeIn(www, "redirect/" ++ dl_archive ++ ".location", try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/tampered/{s}", .{ server.port, dl_archive }));
    try writeIn(www, "tampered/" ++ dl_archive, tampered);
    try writeIn(www, "truncated/" ++ dl_archive, archive);
    try writeIn(www, "truncated/" ++ dl_archive ++ ".truncate", "");
    try writeIn(www, "slow/" ++ dl_archive, archive);
    try writeIn(www, "slow/" ++ dl_archive ++ ".slow", "");
    try writeIn(www, "trickle/" ++ dl_archive, archive);
    try writeIn(www, "trickle/" ++ dl_archive ++ ".trickle", "");
    try writeIn(www, "slowsig/" ++ dl_archive, archive);
    try writeIn(www, "slowsig/" ++ sig_name ++ ".slow", "");
    try writeIn(www, "oldsig/" ++ dl_archive, archive);
    try writeIn(www, "oldsig/" ++ sig_name, old_sig);
    try writeIn(www, "garbagesig/" ++ dl_archive, archive);
    try writeIn(www, "garbagesig/" ++ sig_name, "untrusted comment: well-formed garbage\nnot a signature\n");

    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &sha, .{});
    var key_buf: [56]u8 = undefined;
    const cfg = try std.fmt.allocPrint(a,
        \\list_url={s}/community-mirrors.txt
        \\official_base={s}/official
        \\plain_http=1
        \\key={s}
        \\archive_name={s}
        \\archive_size={d}
        \\archive_sha256={s}
        \\
    , .{ base, base, signer.publicText(&key_buf), dl_archive, archive.len, &std.fmt.bytesToHex(sha, .lower) });
    try dir.writeFile(io, .{ .sub_path = "download_cfg.txt", .data = cfg });
    try dir.writeFile(io, .{ .sub_path = "download_case.txt", .data = case });
    try p.addAutoloadCheck("download.gd");

    var d: Download = .{
        .server = server,
        .base = base,
        .toolchains = try std.fs.path.join(a, &.{ root, "data", "ziggurat", "toolchains" }),
        .data = try std.fs.path.join(a, &.{ root, "data", "ziggurat" }),
        .www = www,
    };
    try d.setList(p, mirrors);
    return d;
}

/// Adds `key=value` lines to the test overrides of `setupDownload`.
fn appendCfg(p: *Project, lines: []const u8) !void {
    const a = p.arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const old = try dir.readFileAlloc(io, "download_cfg.txt", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "download_cfg.txt", .data = try std.mem.concat(a, u8, &.{ old, lines }) });
}

/// Fails when a download or install temporary is left in `toolchains`.
fn expectNoTemp(toolchains: []const u8) !void {
    var d = Io.Dir.cwd().openDir(io, toolchains, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, ".download-") or
            (std.mem.startsWith(u8, e.name, ".zig-") and std.mem.indexOf(u8, e.name, ".tmp-") != null))
        {
            std.debug.print("left in the toolchains folder: {s}\n", .{e.name});
            return error.TempLeft;
        }
    }
}

fn fileExists(p: []const u8) bool {
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}

const dl_installs_expect = [_][]const u8{
    "ZTEST PASS download_configured",
    "ZTEST PASS download_idle_at_start",
    "ZTEST PASS download_menu",
    "ZTEST PASS download_done",
    "ZTEST PASS download_installed",
    "ZTEST PASS download_panel_installed",
    "ZTEST PASS download_build_follows",
    "ZTEST PASS download_no_temp",
    "ZTEST DONE",
};

test "download installs and builds" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "installs", &.{"good"}, false);
    defer d.deinit();
    errdefer d.server.dump();
    try p.runEditorChecked("10000000", .{ .expect = &dl_installs_expect, .reject = &.{"ZTEST FAIL"} });
    const a = p.arena_state.allocator();
    try testing.expect(fileExists(try std.fs.path.join(a, &.{ d.toolchains, "zig-0.17.0", "zig" })));
    try expectNoTemp(d.toolchains);
    try testing.expectEqual(@as(usize, 1), d.server.count("/community-mirrors.txt"));
    try testing.expectEqual(@as(usize, 2), d.server.count("/good/"));
    // The list was cached.
    try testing.expect(fileExists(try std.fs.path.join(a, &.{ d.data, "mirrors.txt" })));
}

test "download falls through bad mirrors" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "installs", &.{ "notfound", "redirect", "truncated", "oldsig", "garbagesig" }, true);
    defer d.deinit();
    errdefer d.server.dump();
    const a = p.arena_state.allocator();
    const m = struct {
        fn line(al: std.mem.Allocator, base: []const u8, mirror: []const u8, reason: []const u8) ![]const u8 {
            return std.fmt.allocPrint(al, "{s}{s}/{s}: {s}", .{ dl_mirror_prefix, base, mirror, reason });
        }
    };
    var expect: std.ArrayList([]const u8) = .empty;
    try expect.appendSlice(a, &dl_installs_expect);
    try expect.append(a, try m.line(a, d.base, "notfound", "HTTP status 404"));
    try expect.append(a, try m.line(a, d.base, "redirect", "the download does not match the pinned SHA-256"));
    try expect.append(a, try m.line(a, d.base, "truncated", "the transfer stopped after "));
    try expect.append(a, try m.line(a, d.base, "oldsig", "the signature is for another file"));
    try expect.append(a, try m.line(a, d.base, "garbagesig", "the signature file is not a minisign signature"));
    try expect.append(a, try std.fmt.allocPrint(a, "Ziggurat installed Zig 0.17.0 from {s}/official", .{d.base}));
    try p.runEditorChecked("10000000", .{ .expect = expect.items, .reject = &.{"ZTEST FAIL"} });
    try testing.expect(fileExists(try std.fs.path.join(a, &.{ d.toolchains, "zig-0.17.0", "zig" })));
    try expectNoTemp(d.toolchains);
    // The redirect was followed to the tampered file.
    try testing.expectEqual(@as(usize, 1), d.server.count("/tampered/"));
    // A bad signature file ends a mirror before its archive is fetched.
    for ([_][]const u8{ "oldsig", "garbagesig" }) |mirror| {
        try testing.expectEqual(@as(usize, 1), d.server.countExact(try std.fmt.allocPrint(a, "/{s}/{s}.minisig", .{ mirror, dl_archive })));
        try testing.expectEqual(@as(usize, 0), d.server.countExact(try std.fmt.allocPrint(a, "/{s}/{s}", .{ mirror, dl_archive })));
    }
}

test "download: all mirrors fail" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "fails", &.{ "notfound", "oldsig" }, false);
    defer d.deinit();
    errdefer d.server.dump();
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS download_configured",
            "ZTEST PASS download_menu",
            "ZTEST PASS download_failed",
            "ZTEST PASS download_failed_toast",
            "ZTEST PASS download_panel_failed",
            "ZTEST PASS download_nothing_installed",
            "ZTEST PASS download_no_temp",
            "ZTEST DONE",
            try std.fmt.allocPrint(p.arena_state.allocator(), "{s}{s}/official: HTTP status 404", .{ dl_mirror_prefix, d.base }),
        },
        .reject = &.{"ZTEST FAIL"},
    });
    const a = p.arena_state.allocator();
    try testing.expect(!fileExists(try std.fs.path.join(a, &.{ d.toolchains, "zig-0.17.0" })));
    try expectNoTemp(d.toolchains);
}

test "download: cancel" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "cancel", &.{"slow"}, false);
    defer d.deinit();
    errdefer d.server.dump();
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS download_configured",
            "ZTEST PASS download_menu",
            "ZTEST PASS download_progress",
            "ZTEST PASS download_cancelled",
            "ZTEST PASS download_partial_gone",
            "ZTEST PASS download_nothing_installed",
            "ZTEST DONE",
            "Ziggurat cancelled the Zig download.",
        },
        .reject = &.{"ZTEST FAIL"},
    });
    try expectNoTemp(d.toolchains);
    // Nothing after the cancel: no other mirror, no ziglang.org.
    try testing.expectEqual(@as(usize, 0), d.server.count("/official/"));
}

test "download: second click while downloading is ignored" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "second", &.{"slow"}, false);
    defer d.deinit();
    errdefer d.server.dump();
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS download_configured",
            "ZTEST PASS download_menu",
            "ZTEST PASS download_second_click_ignored",
            "ZTEST PASS download_no_temp",
            "ZTEST DONE",
        },
        .reject = &.{"ZTEST FAIL"},
    });
    try expectNoTemp(d.toolchains);
    try testing.expectEqual(@as(usize, 1), d.server.count("/community-mirrors.txt"));
    try testing.expectEqual(@as(usize, 1), d.server.countExact("/slow/" ++ dl_archive ++ ".minisig"));
    try testing.expectEqual(@as(usize, 1), d.server.countExact("/slow/" ++ dl_archive));
}

/// One bad mirror whose failure needs a short time limit (`cfg`), then
/// the ziglang.org stand-in: the mirror is logged with `reason` and the
/// download installs from ziglang.org.
fn downloadLimitCase(mirror: []const u8, cfg: []const u8, reason: []const u8) !void {
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "installs", &.{mirror}, true);
    defer d.deinit();
    errdefer d.server.dump();
    try appendCfg(&p, cfg);
    const a = p.arena_state.allocator();
    var expect: std.ArrayList([]const u8) = .empty;
    try expect.appendSlice(a, &dl_installs_expect);
    try expect.append(a, try std.fmt.allocPrint(a, "{s}{s}/{s}: {s}", .{ dl_mirror_prefix, d.base, mirror, reason }));
    try expect.append(a, try std.fmt.allocPrint(a, "Ziggurat installed Zig 0.17.0 from {s}/official", .{d.base}));
    try p.runEditorChecked("10000000", .{ .expect = expect.items, .reject = &.{"ZTEST FAIL"} });
    try expectNoTemp(d.toolchains);
}

test "download: a trickling mirror misses its deadline" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // One byte every 100 ms: the 388-byte fixture would take 39 s.
    try downloadLimitCase("trickle", "archive_deadline_ms=2000\n", "too slow: ");
}

test "download: a signature request times out" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try downloadLimitCase("slowsig", "request_timeout_ms=2000\n", "the request timed out");
}

test "download: a stalled archive transfer" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try downloadLimitCase("slow", "stall_ms=1500\n", "no data for 1500 ms");
}

test "download: Zig already installed" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "installs", &.{"good"}, true);
    defer d.deinit();
    errdefer d.server.dump();
    const a = p.arena_state.allocator();
    // A working zig-0.17.0 (it answers `version`).
    const zig_dir = try std.fs.path.join(a, &.{ d.toolchains, "zig-0.17.0" });
    try Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ zig_dir, "lib" }));
    try writeIn(zig_dir, "zig", "#!/bin/sh\necho 0.17.0\n");
    const chmod = try std.process.run(a, io, .{ .argv = &.{ "chmod", "755", try std.fs.path.join(a, &.{ zig_dir, "zig" }) } });
    if (!chmod.term.success()) return error.ChmodFailed;
    var expect: std.ArrayList([]const u8) = .empty;
    try expect.appendSlice(a, &dl_installs_expect);
    try expect.append(a, "Zig 0.17.0 is already installed in ");
    try p.runEditorChecked("10000000", .{ .expect = expect.items, .reject = &.{"ZTEST FAIL"} });
    // Nothing was downloaded.
    try testing.expectEqual(@as(usize, 0), d.server.count("/"));
}

test "download: editor exit during a transfer" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "exit", &.{"slow"}, false);
    defer d.deinit();
    errdefer d.server.dump();
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS download_configured",
            "ZTEST PASS download_menu",
            "ZTEST PASS download_exit_transfer",
            "ZTEST DONE",
            "build service stopped (0 threads left)",
        },
        .reject = &.{"ZTEST FAIL"},
    });
    try expectNoTemp(d.toolchains);
    const a = p.arena_state.allocator();
    try testing.expect(!fileExists(try std.fs.path.join(a, &.{ d.toolchains, "zig-0.17.0" })));
}

test "download: editor exit while the check waits for the toolchain lock" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("highlighter");
    defer p.deinit();
    var d = try setupDownload(&p, "exit_lock", &.{"good"}, false);
    defer d.deinit();
    errdefer d.server.dump();
    const a = p.arena_state.allocator();
    // Another editor's install holds the lock for the whole run.
    try Io.Dir.cwd().createDirPath(io, d.toolchains);
    const lock_path = try std.fs.path.join(a, &.{ d.toolchains, ".install.lock" });
    var held = try platform.lock.FileLock.acquire(io, .fromTrusted(lock_path), .exclusive, 0);
    defer held.release();
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS download_configured",
            "ZTEST PASS download_menu",
            "ZTEST PASS download_exit_checking",
            "ZTEST DONE",
            "build service stopped (0 threads left)",
        },
        .reject = &.{"ZTEST FAIL"},
    });
    try expectNoTemp(d.toolchains);
    try testing.expect(!fileExists(try std.fs.path.join(a, &.{ d.toolchains, "zig-0.17.0" })));
}

test "download: mirror list cache" {
    try requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // A fresh cache is used without a request.
    {
        var p: Project = undefined;
        try p.initProbe("highlighter");
        defer p.deinit();
        // The server's list names a mirror that does not exist; the cache
        // names the good one.
        var d = try setupDownload(&p, "installs", &.{"notfound"}, false);
        defer d.deinit();
        errdefer d.server.dump();
        const a = p.arena_state.allocator();
        try Io.Dir.cwd().createDirPath(io, d.data);
        try writeIn(d.data, "mirrors.txt", try std.fmt.allocPrint(a, "{s}/good\n", .{d.base}));
        try p.runEditorChecked("10000000", .{ .expect = &dl_installs_expect, .reject = &.{"ZTEST FAIL"} });
        try testing.expectEqual(@as(usize, 0), d.server.count("/community-mirrors.txt"));
        try testing.expectEqual(@as(usize, 0), d.server.count("/notfound/"));
        try testing.expectEqual(@as(usize, 2), d.server.count("/good/"));
    }
    // A stale cache is fetched again and replaced.
    {
        var p: Project = undefined;
        try p.initProbe("highlighter");
        defer p.deinit();
        var d = try setupDownload(&p, "installs", &.{"good"}, false);
        defer d.deinit();
        errdefer d.server.dump();
        const a = p.arena_state.allocator();
        try Io.Dir.cwd().createDirPath(io, d.data);
        try writeIn(d.data, "mirrors.txt", try std.fmt.allocPrint(a, "{s}/notfound\n", .{d.base}));
        const cache = try std.fs.path.join(a, &.{ d.data, "mirrors.txt" });
        const touch = try std.process.run(a, io, .{ .argv = &.{ "touch", "-d", "@1000000000", cache } });
        if (!touch.term.success()) return error.TouchFailed;
        try p.runEditorChecked("10000000", .{ .expect = &dl_installs_expect, .reject = &.{"ZTEST FAIL"} });
        try testing.expectEqual(@as(usize, 1), d.server.count("/community-mirrors.txt"));
        try testing.expectEqual(@as(usize, 0), d.server.count("/notfound/"));
        const now = try Io.Dir.cwd().readFileAlloc(io, cache, a, .limited(64 * 1024));
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/good\n", .{d.base}), now);
    }
    // An unreadable list: only ziglang.org, and nothing is cached.
    {
        var p: Project = undefined;
        try p.initProbe("highlighter");
        defer p.deinit();
        var d = try setupDownload(&p, "installs", &.{}, true);
        defer d.deinit();
        errdefer d.server.dump();
        const a = p.arena_state.allocator();
        try writeIn(d.www, "community-mirrors.txt", try std.fmt.allocPrint(a, "{s}/good\nftp://not a mirror\n", .{d.base}));
        try p.runEditorChecked("10000000", .{ .expect = &dl_installs_expect, .reject = &.{"ZTEST FAIL"} });
        try testing.expectEqual(@as(usize, 1), d.server.count("/community-mirrors.txt"));
        try testing.expectEqual(@as(usize, 0), d.server.count("/good/"));
        try testing.expectEqual(@as(usize, 2), d.server.count("/official/"));
        try testing.expect(!fileExists(try std.fs.path.join(a, &.{ d.data, "mirrors.txt" })));
    }
}

// ------------------------------------------------------------ build on play

/// Adds play_build.gd as the tool autoload and names its case in
/// `res://play_case.txt`.
fn addPlayCheck(p: *Project, case: []const u8) !void {
    try setPlayCase(p, case);
    try p.addAutoloadCheck("play_build.gd");
}

/// Names the case play_build.gd runs.
fn setPlayCase(p: *Project, case: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "play_case.txt", .data = case });
}

/// Runs the editor with `--build-solutions`: it calls `_build` once,
/// before the first frame's `process_frame` signal (`E` section 2), and
/// exits with status 1 when it returns false.
fn runPlay(p: *Project, texts: Project.Texts) !void {
    return p.run(&.{ "build", "10000000" }, texts);
}

const play_cancelled = "An EditorPlugin build callback failed.";

test "play builds first, times out with a good build" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    const gate = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    try addPlayCheck(&p, "builds_first");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_settings_default",
            "ZTEST PASS play_edit_saved",
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_builds_first",
            "build service stopped (0 threads left)",
        },
        .reject = &.{play_cancelled},
        .deadline = build_deadline_s,
    });
    // The same project again, the build held at the gate: the build of the
    // first run is the good build the game starts with.
    var gate_dir = try Io.Dir.cwd().openDir(io, gate, .{});
    defer gate_dir.close(io);
    try gate_dir.writeFile(io, .{ .sub_path = "block", .data = "" });
    try setPlayCase(&p, "timeout_good");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_timeout_with_good_build",
            "build service stopped (0 threads left)",
        },
        .reject = &.{play_cancelled},
        .deadline = "300",
    });
    // Still held: `_build` from inside module code or a running drain
    // neither waits nor drains, and starts with the good build at once.
    try setPlayCase(&p, "nested");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_nested_gate",
            "ZTEST PASS play_nested_drain",
            "ZTEST PASS play_nested_toast",
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_nested_then_off",
            "build service stopped (0 threads left)",
        },
        .reject = &.{ play_cancelled, play_nested_cancelled },
        .deadline = "300",
    });
}

const play_nested_cancelled = "Ziggurat cancelled the run because Play was started while Zig code or a build update ran on the main thread, so it could not wait for the Zig build, and no good build exists yet; see the Zig panel.";

test "play from inside zig code decides at once" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    const gate = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    var gate_dir = try Io.Dir.cwd().openDir(io, gate, .{});
    defer gate_dir.close(io);
    try gate_dir.writeFile(io, .{ .sub_path = "block", .data = "" });
    try addPlayCheck(&p, "nested");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_nested_gate",
            "ZTEST PASS play_nested_drain",
            play_nested_cancelled,
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_nested_then_off",
            "build service stopped (0 threads left)",
        },
        .reject = &.{play_cancelled},
        .deadline = "300",
    });
}

test "play cancels on a failed build" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    const gate = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    var gate_dir = try Io.Dir.cwd().openDir(io, gate, .{});
    defer gate_dir.close(io);
    try gate_dir.writeFile(io, .{ .sub_path = "fail", .data = "" });
    try addPlayCheck(&p, "failed");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_cancel_shows_panel",
            "Ziggurat cancelled the run because the Zig build failed; see the Zig panel.",
            play_cancelled,
            "build service stopped (0 threads left)",
        },
        .exit_code = "1",
        .deadline = "300",
    });
}

test "play times out without a good build" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    const gate = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    var gate_dir = try Io.Dir.cwd().openDir(io, gate, .{});
    defer gate_dir.close(io);
    try gate_dir.writeFile(io, .{ .sub_path = "block", .data = "" });
    try addPlayCheck(&p, "timeout_none");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_cancel_shows_panel",
            "Ziggurat cancelled the run because the Zig build still runs after 1 s and no good build exists yet; see the Zig panel.",
            play_cancelled,
            "build service stopped (0 threads left)",
        },
        .exit_code = "1",
        .deadline = "300",
    });
}

test "play without a service" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    try isolateUserFolders(&p);
    try addPlayCheck(&p, "no_service");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_without_service",
        },
        .reject = &.{play_cancelled},
    });
}

test "play without scripts and without Zig" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    // The shipped SDK, so the editor runs a build service; no Zig setting,
    // no downloaded Zig (isolated per-user folders) and no Zig on PATH.
    try addStagedSdk(&p);
    try isolateUserFolders(&p);
    try p.env.?.put("PATH", "/nonexistent/ziggurat-test");
    try writeProjectFile(&p, "main.gd", "extends Node\n");
    try addPlayCheck(&p, "no_scripts");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_no_scripts",
            "build service stopped (0 threads left)",
        },
        .reject = &.{ play_cancelled, "found no usable Zig", "Ziggurat needs Zig" },
    });
}

test "build on play off" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("editor_panel");
    defer p.deinit();
    const gate = try addZigWrapper(&p);
    try isolateUserFolders(&p);
    var gate_dir = try Io.Dir.cwd().openDir(io, gate, .{});
    defer gate_dir.close(io);
    try gate_dir.writeFile(io, .{ .sub_path = "block", .data = "" });
    try addPlayCheck(&p, "off");
    try runPlay(&p, .{
        .expect = &.{
            "ZTEST PASS play_not_before_first_frame",
            "ZTEST PASS play_called_once",
            "ZTEST PASS play_off",
            "build service stopped (0 threads left)",
        },
        .reject = &.{play_cancelled},
        .deadline = "300",
    });
}

// ------------------------------------------------------------ game process

/// The library name the editor's store gives generation `n`.
fn genLibName(buf: []u8, n: u32) ![]const u8 {
    return platform.path.libName(buf, builtin.os.tag, zbuild.service.lib_stem, n);
}

/// A project whose store (`.godot/ziggurat`) holds the module built from
/// test/fixtures/instance_project as generation 1, as the editor stages it,
/// with the fixture's scripts in the project folder, `res://check.gd` set
/// to game_ready.gd and no manifest yet. Returns the store's path.
fn stageGameProject(p: *Project) ![]const u8 {
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const built = try buildModule(a, work, "game", "instance_project", manifest.modules, true);

    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    var name_buf: [64]u8 = undefined;
    const rel = try std.fmt.allocPrint(a, ".godot/ziggurat/gen/1/{s}", .{try genLibName(&name_buf, 1)});
    try dir.createDirPath(io, std.fs.path.dirname(rel).?);
    try cwd.copyFile(built, dir, rel, io, .{});
    const fixture = try std.fs.path.join(a, &.{ opts.fixtures_dir, "instance_project" });
    var src = try cwd.openDir(io, fixture, .{ .iterate = true });
    defer src.close(io);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) try src.copyFile(entry.name, dir, entry.name, io, .{});
    }
    try p.addCheck("game_ready.gd");
    return std.fs.path.join(a, &.{ p.path, ".godot", "ziggurat" });
}

/// Replaces the store's manifest with `text`.
fn writeGameManifest(store: *Io.Dir, text: []const u8) !void {
    store.deleteFile(io, "manifest") catch |err| switch (err) {
        error.FileNotFound => {},
        error.IsDir => try store.deleteDir(io, "manifest"),
        else => return err,
    };
    try store.writeFile(io, .{ .sub_path = "manifest", .data = text });
}

const refused_prefix = "Ziggurat ignores the generation manifest because ";
const refused_suffix = ", so this game runs without Zig scripts.";

/// Runs the game and checks that the manifest was refused for `reason`,
/// and that the game ran on without scripts.
fn expectGameRefused(p: *Project, case: []const u8, reason: []const u8) !void {
    const a = p.arena_state.allocator();
    const sentence = try std.mem.concat(a, u8, &.{ refused_prefix, reason, refused_suffix });
    p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ sentence, "game check: scripts absent" },
        .reject = &.{ "mover ready", "generation 1 loaded" },
    }) catch |err| {
        std.debug.print("trust case '{s}' failed\n", .{case});
        return err;
    };
}

test "manifest trust" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.init("empty");
    defer p.deinit();
    const a = p.arena_state.allocator();
    const store_path = try stageGameProject(&p);
    var store = try Io.Dir.cwd().openDir(io, store_path, .{});
    defer store.close(io);
    try p.tmp.dir.createDirPath(io, "outside");
    const outside = try p.tmp.dir.realPathFileAlloc(io, "outside", a);
    var lib1_buf: [64]u8 = undefined;
    const lib1 = try genLibName(&lib1_buf, 1);
    const good_rel = try std.fmt.allocPrint(a, "gen/1/{s}", .{lib1});
    var t: [1024]u8 = undefined;

    // No manifest at all: the game says so once and runs without scripts.
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ "Ziggurat found no generation manifest, so this game runs without Zig scripts", "game check: scripts absent" },
        .reject = &.{"mover ready"},
    });

    // Malformed text, one manifest per rule.
    const big: [300]u8 = @splat('a');
    const long_name: [210]u8 = @splat('a');
    const text_cases = [_]struct { name: []const u8, text: []const u8, reason: []const u8 }{
        .{ .name = "empty file", .text = "", .reason = "it is not exactly two lines that each end with a line break" },
        .{ .name = "over the size limit", .text = &big, .reason = "it is larger than 256 bytes" },
        .{ .name = "line over the length limit", .text = try std.fmt.allocPrint(a, "gen=1\npath=gen/1/{s}\n", .{&long_name}), .reason = "a line is longer than 200 bytes" },
        .{ .name = "NUL byte", .text = try std.fmt.allocPrint(a, "gen=1\npath={s}\x00\n", .{good_rel}), .reason = "it holds a NUL byte" },
        .{ .name = "extra line", .text = try std.fmt.allocPrint(a, "gen=1\npath={s}\nmore=1\n", .{good_rel}), .reason = "it is not exactly two lines that each end with a line break" },
        .{ .name = "leading zero", .text = try std.fmt.allocPrint(a, "gen=01\npath={s}\n", .{good_rel}), .reason = "the generation is not a decimal number without sign or leading zeros" },
        .{ .name = "sign", .text = try std.fmt.allocPrint(a, "gen=+1\npath={s}\n", .{good_rel}), .reason = "the generation is not a decimal number without sign or leading zeros" },
        .{ .name = "generation 0", .text = try std.fmt.allocPrint(a, "gen=0\npath={s}\n", .{good_rel}), .reason = "the generation is not between 1 and 4294967294" },
        .{ .name = "generation out of range", .text = try std.fmt.allocPrint(a, "gen=4294967295\npath={s}\n", .{good_rel}), .reason = "the generation is not between 1 and 4294967294" },
        .{ .name = "generation does not fit", .text = try std.fmt.allocPrint(a, "gen=99999999999\npath={s}\n", .{good_rel}), .reason = "the generation is not between 1 and 4294967294" },
        .{ .name = "absolute path", .text = try std.fmt.allocPrint(a, "gen=1\npath={s}/{s}\n", .{ store_path, good_rel }), .reason = "the library path is absolute" },
        .{ .name = "character set", .text = "gen=1\npath=gen/1/lib zmod.1.so\n", .reason = "the library path has a character other than A-Z, a-z, 0-9, '.', '_', '-' and '/'" },
        .{ .name = "'..' part", .text = try std.fmt.allocPrint(a, "gen=1\npath=gen/1/../1/{s}\n", .{lib1}), .reason = "the library path has an empty, '.' or '..' part" },
        .{ .name = "'.' part", .text = try std.fmt.allocPrint(a, "gen=1\npath=gen/1/./{s}\n", .{lib1}), .reason = "the library path has an empty, '.' or '..' part" },
        .{ .name = "empty part", .text = try std.fmt.allocPrint(a, "gen=1\npath=gen//1/{s}\n", .{lib1}), .reason = "the library path has an empty, '.' or '..' part" },
        // Stage 4's rule: gen=2 with generation 1's library would run
        // `ziggurat_init` again on a live module as generation 2.
        .{ .name = "path of another generation", .text = try std.fmt.allocPrint(a, "gen=2\npath={s}\n", .{good_rel}), .reason = "the library path does not start with gen/<generation>/" },
        .{ .name = "other library name", .text = "gen=1\npath=gen/1/other.so\n", .reason = "the library file name is not the one the editor writes for that generation" },
        .{ .name = "missing library", .text = try std.fmt.allocPrint(a, "gen=5\npath=gen/5/{s}\n", .{try genLibName(&t, 5)}), .reason = "the library does not exist or cannot be resolved" },
    };
    try store.copyFile(good_rel, store, "gen/1/other.so", io, .{});
    for (text_cases) |c| {
        try writeGameManifest(&store, c.text);
        try expectGameRefused(&p, c.name, c.reason);
    }

    // Links and file kinds.
    var name_buf: [64]u8 = undefined;
    // The library is a link to a copy outside the store.
    const outside_lib = try std.fs.path.join(a, &.{ outside, "lib.so" });
    try store.copyFile(good_rel, Io.Dir.cwd(), outside_lib, io, .{});
    try store.createDirPath(io, "gen/2");
    try store.symLink(io, outside_lib, try std.fmt.allocPrint(a, "gen/2/{s}", .{try genLibName(&name_buf, 2)}), .{});
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=2\npath=gen/2/{s}\n", .{try genLibName(&name_buf, 2)}));
    try expectGameRefused(&p, "linked library outside", "the library resolves to a file outside .godot/ziggurat");
    // The generation folder is a link to a folder outside the store.
    try store.copyFile(good_rel, Io.Dir.cwd(), try std.fs.path.join(a, &.{ outside, try genLibName(&name_buf, 3) }), io, .{});
    try store.symLink(io, outside, "gen/3", .{ .is_directory = true });
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=3\npath=gen/3/{s}\n", .{try genLibName(&name_buf, 3)}));
    try expectGameRefused(&p, "linked folder outside", "the library resolves to a file outside .godot/ziggurat");
    // A link inside the store that points generation 6's path at
    // generation 1's library: one file would run as two generations.
    try store.createDirPath(io, "gen/6");
    try store.symLink(io, try std.fmt.allocPrint(a, "../1/{s}", .{lib1}), try std.fmt.allocPrint(a, "gen/6/{s}", .{try genLibName(&name_buf, 6)}), .{});
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=6\npath=gen/6/{s}\n", .{try genLibName(&name_buf, 6)}));
    try expectGameRefused(&p, "linked library inside", "the library resolves to another file than gen/<generation>/<library name> in .godot/ziggurat");
    // The library is a folder.
    try store.createDirPath(io, try std.fmt.allocPrint(a, "gen/4/{s}", .{try genLibName(&name_buf, 4)}));
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=4\npath=gen/4/{s}\n", .{try genLibName(&name_buf, 4)}));
    try expectGameRefused(&p, "library is a folder", "the library is not a regular file");
    // The manifest is a link to a good manifest outside the store.
    const outside_manifest = try std.fs.path.join(a, &.{ outside, "manifest" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = outside_manifest, .data = try std.fmt.allocPrint(a, "gen=1\npath={s}\n", .{good_rel}) });
    try store.deleteFile(io, "manifest");
    try store.symLink(io, outside_manifest, "manifest", .{});
    try expectGameRefused(&p, "linked manifest", "it is a symbolic link");
    // The manifest is a FIFO: refused, and the game does not wait for a
    // writer.
    try store.deleteFile(io, "manifest");
    const fifo = try std.fs.path.join(a, &.{ store_path, "manifest" });
    const mk = try std.process.run(a, io, .{ .argv = &.{ "mkfifo", fifo } });
    if (!mk.term.success()) return error.MkfifoFailed;
    try expectGameRefused(&p, "manifest is a FIFO", "it is not a regular file");
    // The manifest is a folder.
    try store.deleteFile(io, "manifest");
    try store.createDirPath(io, "manifest");
    try expectGameRefused(&p, "manifest is a folder", "it is not a regular file");
    try store.deleteDir(io, "manifest");

    // The good manifest: generation 1 loads and its script runs.
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=1\npath={s}\n", .{good_rel}));
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ "ziggurat: generation 1 loaded", "[ziggurat] mover ready speed=5\n", "game check: scripts running" },
        .reject = &.{refused_prefix},
    });
}

test "game runs ready" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    const a = p.arena_state.allocator();
    const store_path = try stageGameProject(&p);
    var store = try Io.Dir.cwd().openDir(io, store_path, .{});
    defer store.close(io);
    var name_buf: [64]u8 = undefined;
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=1\npath=gen/1/{s}\n", .{try genLibName(&name_buf, 1)}));
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{
            "ziggurat: generation 1 loaded",
            "[ziggurat] mover ready speed=5\n",
            "game check: scripts running",
        },
        // The debugger's reload requests: the manifest names the build the
        // game runs, and Godot's reloads are quiet, so nothing is logged.
        .reject = &.{ refused_prefix, "placeholder", "swaps arrive in a later version", "nothing to do", "may not be staged yet" },
    });
}

test "game reload: reload message swaps the game, no polling, quiet godot reload, keeps old on bad build" {
    try requireIntegration();
    var p: Project = undefined;
    try p.initProbe("empty");
    defer p.deinit();
    const a = p.arena_state.allocator();
    var manifest = try loadManifest(testing.allocator);
    defer manifest.deinit(testing.allocator);
    try p.tmp.dir.createDirPath(io, "work");
    const work = try p.tmp.dir.realPathFileAlloc(io, "work", a);
    const v1 = try buildModule(a, work, "v1", "swap_v1", manifest.modules, true);
    const v2 = try buildModule(a, work, "v2", "swap_v2", manifest.modules, true);

    // The editor's store: generation 1 and 2 staged, generation 4 a cut
    // copy of 2 (it fails to load), generation 3 never staged.
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    var names: [9][64]u8 = undefined;
    var list: std.ArrayList(u8) = .empty;
    for ([_]u32{ 1, 2, 3, 4, 5, 7, 8 }) |n| {
        const name = try genLibName(&names[n], n);
        try list.print(a, "lib{d}={s}\n", .{ n, name });
    }
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = list.items });
    try dir.createDirPath(io, ".godot/ziggurat/gen/1");
    try dir.createDirPath(io, ".godot/ziggurat/gen/2");
    try dir.createDirPath(io, ".godot/ziggurat/gen/4");
    try cwd.copyFile(v1, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/1/{s}", .{try genLibName(&names[1], 1)}), io, .{});
    try cwd.copyFile(v2, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/2/{s}", .{try genLibName(&names[2], 2)}), io, .{});
    // Generation 5 is another file with generation 1's code: the reload
    // message swaps back to it.
    try dir.createDirPath(io, ".godot/ziggurat/gen/5");
    try cwd.copyFile(v1, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/5/{s}", .{try genLibName(&names[5], 5)}), io, .{});
    // Generations 7 (generation 2's code) and 8 (generation 1's): the
    // reload while a swap waits for a thread.
    try dir.createDirPath(io, ".godot/ziggurat/gen/7");
    try dir.createDirPath(io, ".godot/ziggurat/gen/8");
    try cwd.copyFile(v2, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/7/{s}", .{try genLibName(&names[7], 7)}), io, .{});
    try cwd.copyFile(v1, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/8/{s}", .{try genLibName(&names[8], 8)}), io, .{});
    const bytes = try cwd.readFileAlloc(io, v2, a, .limited(256 << 20));
    try dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, ".godot/ziggurat/gen/4/{s}", .{try genLibName(&names[4], 4)}), .data = bytes[0 .. bytes.len / 2] });
    var store = try dir.openDir(io, ".godot/ziggurat", .{});
    defer store.close(io);
    try writeGameManifest(&store, try std.fmt.allocPrint(a, "gen=1\npath=gen/1/{s}\n", .{try genLibName(&names[1], 1)}));
    // The scripts' sources, as the game's project has them.
    const fixture = try std.fs.path.join(a, &.{ opts.fixtures_dir, "swap_v1" });
    var src = try cwd.openDir(io, fixture, .{ .iterate = true });
    defer src.close(io);
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) try src.copyFile(entry.name, dir, entry.name, io, .{});
    }

    try p.addCheck("game_reload.gd");
    try p.run(&.{ "script", "res://check.gd" }, .{
        .expect = &.{
            "ZTEST PASS game_runs_gen_1",
            "ZTEST PASS reload_before_staging",
            "ZTEST PASS reload_same_gen_does_nothing",
            "ZTEST PASS bad_build_keeps_old",
            "ZTEST PASS game_swaps_on_reload",
            "ZTEST PASS method_returns_new_value",
            "ZTEST PASS field_values_kept",
            "ZTEST PASS new_instance_runs_gen_2",
            "ZTEST PASS repeat_does_nothing",
            "ZTEST PASS refused_manifest_keeps_gen",
            "ZTEST PASS no_polling",
            "ZTEST PASS reload_message_swaps",
            "ZTEST PASS old_message_does_nothing",
            "ZTEST PASS capture_registered",
            "ZTEST PASS capture_takes_reload_only",
            "ZTEST PASS newest_reload_wins_after_deferral",
            "ZTEST PASS announced_refusal_keeps_gen",
            "ZTEST DONE",
        },
        .once = &.{
            "Ziggurat refused generation 4: ",
            "ziggurat: generation 2 loaded",
            "ziggurat: swapped to build 2",
            "Ziggurat ignores the generation manifest for this reload because the library file name is not the one the editor writes for that generation; keeping gen 2.",
            "ziggurat: generation 5 loaded",
            "ziggurat: generation 7 loaded",
            "ziggurat: generation 8 loaded",
            "ziggurat: the swap to build 7 waits for script calls on other threads to return",
            "ziggurat: the swap to build 8 waits for script calls on other threads to return",
            "ziggurat: swapped to build 8",
            "Ziggurat cannot load build 9, which the editor announced, because the library does not exist or cannot be resolved; keeping gen 8.",
            "Ziggurat cannot load build 10, which the editor announced, because the manifest names build 2; keeping gen 8.",
        },
        // Godot's reloads with nothing newer and the message for gen 4 log
        // nothing (quiet godot reload).
        .reject = &.{ "ZTEST FAIL", "swaps arrive in a later version", "swapped to build 7", "may not be staged yet", "nothing to do", "keeping gen 5" },
    });
}

// ------------------------------------------------------------ end to end

/// The game pass's ZTEST cases (test/host/projects/e2e/listener.gd).
const e2e_game_cases = [_][]const u8{
    "ZTEST PASS game_scripts_attached",
    "ZTEST PASS ready_ran",
    "ZTEST PASS exported_values_from_scene",
    "ZTEST PASS property_list_hints",
    "ZTEST PASS signal_declared",
    "ZTEST PASS emit_reaches_connect",
    "ZTEST PASS emit_reaches_signal_property",
    "ZTEST PASS emit_reaches_scene_connection",
    "ZTEST PASS handler_reads_emitter",
    "ZTEST PASS metadata_not_swallowed",
    "ZTEST PASS method_call_returns",
    "ZTEST PASS method_callable_property",
};

test "e2e headless" {
    try requireIntegration();
    var p: Project = undefined;
    try p.init("e2e");
    defer p.deinit();
    try addBuildSettings(&p);
    try p.addAutoloadCheck("e2e_editor.gd");
    // Editor pass: the build at open stages generation 1 for the game.
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS editor_built_and_staged",
            "ZTEST PASS editor_tool_instance",
            "ZTEST PASS editor_placeholder_values",
            "ziggurat: build 1 loaded (open, ",
        },
        .deadline = build_deadline_s,
    });
    // Game pass: the main scene with the staged generation, no builds.
    try p.run(&.{ "game", "res://main.tscn" }, .{
        .expect = &e2e_game_cases,
        .once = &.{
            "ziggurat: generation 1 loaded",
            "[ziggurat] hero ready speed=12.5 spawn=3,4\n",
            "[ziggurat] beacon ready pulses=3\n",
            "e2e game: checks done",
        },
        .reject = &.{ refused_prefix, "emit of signal", "placeholder", "ziggurat: build" },
    });
}

// ------------------------------------------------------------ debugger builds

/// The project's Zig is a shell script around the real one that appends
/// the arguments of every compiler start (not `zig version`) to a file in
/// the test's folder; `res://argv_log.txt` names that file.
fn addArgvLogWrapper(p: *Project) !void {
    const a = p.arena_state.allocator();
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    const log = try std.fs.path.join(a, &.{ root, "argv.log" });
    const wrapper = try std.fs.path.join(a, &.{ root, "zig-argv.sh" });
    const script = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\if [ "$1" != version ]; then echo "$*" >> '{s}'; fi
        \\exec '{s}' "$@"
        \\
    , .{ log, opts.zig_exe });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = wrapper, .data = script });
    const chmod = try std.process.run(a, io, .{ .argv = &.{ "chmod", "755", wrapper } });
    if (!chmod.term.success()) return error.ChmodFailed;
    try writeIn(p.path, "argv_log.txt", log);
    try addBuildSettingsWith(p, wrapper);
}

// The editor (headless) plays the e2e project's main scene; the game runs
// headless too (`editor/run/main_run_args` set to `--headless` by the
// check) and keeps running (ZTEST_GUI). The check turns the editor setting
// ziggurat/build/debugger_builds on and off while the game runs and edits
// res://hero.zig each time (test/host/checks/debugger_builds.gd).
test "debugger builds: toggling during a session" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("e2e");
    defer p.deinit();
    const a = p.arena_state.allocator();
    try addArgvLogWrapper(&p);
    try isolateUserFolders(&p);
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    try p.env.?.put("ZTEST_GUI", "1");
    try p.env.?.put("ZTEST_GAME_LOG", try std.fs.path.join(a, &.{ root, "game.log" }));
    try p.addAutoloadCheck("debugger_builds.gd");
    try p.runEditorChecked("100000000", .{
        .expect = &.{
            "ZTEST PASS debugger_setting_registered",
            "ZTEST PASS debugger_session_warm",
            "ZTEST PASS debugger_game_running",
            "ZTEST PASS debugger_panel_line",
            "ZTEST PASS debugger_build_llvm",
            "ZTEST PASS debugger_no_warm_server",
            "ZTEST PASS debugger_game_new_code",
            "ZTEST PASS debugger_panel_line_hidden",
            "ZTEST PASS debugger_off_full",
            "ZTEST PASS debugger_off_warm_again",
            "ZTEST PASS debugger_off_game_new_code",
            "ZTEST PASS debugger_off_incremental",
            "ZTEST PASS debugger_off_game_incremental_code",
            "build service stopped (0 threads left)",
        },
        .reject = &.{ refused_prefix, "Program crashed" },
        .deadline = build_deadline_s,
    });
    // Opened again with the setting on (the first pass left it on): the
    // build at open, which starts before the editor exists, is followed
    // by one with debugger builds.
    // The autoload res://check.gd is now the second check.
    try p.addCheck("debugger_open.gd");
    try p.runEditorChecked("100000000", .{
        .expect = &.{
            "ZTEST PASS debugger_open_setting_on",
            "ZTEST PASS debugger_open_build_llvm",
            "build service stopped (0 threads left)",
        },
        .reject = &.{"Program crashed"},
        .deadline = build_deadline_s,
    });
}

// The editor (headless, so no focus-in ever reaches it) plays the e2e
// project's main scene with the check interval at 0; the check rewrites
// res://hero.zig without requesting a build and the running game must
// print the new score within 10 s (test/host/checks/change_check.gd).
test "change check: external edit reaches a running game without focus" {
    try requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("e2e");
    defer p.deinit();
    const a = p.arena_state.allocator();
    try addBuildSettings(&p);
    try isolateUserFolders(&p);
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    try p.env.?.put("ZTEST_GUI", "1");
    try p.env.?.put("ZTEST_GAME_LOG", try std.fs.path.join(a, &.{ root, "game.log" }));
    try p.addAutoloadCheck("change_check.gd");
    try p.runEditorChecked("100000000", .{
        .expect = &.{
            "ZTEST PASS change_interval_zero",
            "ZTEST PASS change_session_warm",
            "ZTEST PASS change_game_running",
            "ZTEST PASS change_game_new_code_without_focus",
            "build service stopped (0 threads left)",
        },
        .reject = &.{ refused_prefix, "Program crashed" },
        .deadline = build_deadline_s,
    });
}

/// The absolute path of `lldb` on `PATH`, or null.
fn findLldb(a: std.mem.Allocator) !?[]const u8 {
    const which = try std.process.run(a, io, .{ .argv = &.{ "sh", "-c", "command -v lldb" } });
    const path = std.mem.trim(u8, which.stdout, " \t\r\n");
    if (!which.term.success() or path.len == 0) return null;
    return path;
}

// The editor builds the e2e project in debugger mode; then the game runs
// headless under lldb in batch mode (lldb starts Godot, so the default
// `ptrace_scope` 1 allows it) with a breakpoint by file and line in
// res://hero.zig's `_ready`: the game stops there and `frame variable`
// shows the scene's value of `speed`. Skips when `lldb` is not on `PATH`.
test "lldb stops in a script" {
    try requireIntegration();
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a0 = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a0);
    defer arena_state.deinit();
    const lldb = try findLldb(arena_state.allocator()) orelse return error.SkipZigTest;
    var p: Project = undefined;
    try p.initProbe("e2e");
    defer p.deinit();
    const a = p.arena_state.allocator();
    try addBuildSettings(&p);
    try isolateUserFolders(&p);
    try p.addAutoloadCheck("debugger_lldb.gd");
    try p.runEditorChecked("100000000", .{
        .expect = &.{ "ZTEST PASS lldb_debugger_build", "build service stopped (0 threads left)" },
        .deadline = build_deadline_s,
    });

    // The line of `self.ready_calls += 1;` in hero.zig's `_ready`.
    const hero = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, "hero.zig" }), a, .limited(1 << 20));
    var line: usize = 0;
    var it = std.mem.splitScalar(u8, hero, '\n');
    var n: usize = 1;
    while (it.next()) |l| : (n += 1) {
        if (std.mem.indexOf(u8, l, "self.ready_calls += 1;") != null) line = n;
    }
    try testing.expect(line != 0);
    const bp = try std.fmt.allocPrint(a, "b hero.zig:{d}", .{line});
    const result = try std.process.run(a, io, .{
        .argv = &.{ "timeout", "300", lldb, "--batch", "-o", bp, "-o", "run", "-o", "frame variable", "-o", "frame variable *self", "-o", "process kill", "--", opts.godot_exe, "--headless", "--path", p.path, "--quit-after", "5" },
        .environ_map = p.env.?,
    });
    const out = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr });
    var problems: std.ArrayList([]const u8) = .empty;
    if (!result.term.success()) try problems.append(a, "lldb did not exit with status 0");
    for ([_][]const u8{ "stop reason = breakpoint", "hero._ready", "(hero *) self = 0x", "speed = 12.5" }) |text| {
        if (std.mem.indexOf(u8, out, text) == null)
            try problems.append(a, try std.fmt.allocPrint(a, "missing expected text: {s}", .{text}));
    }
    if (problems.items.len == 0) return;
    std.debug.print("--- lldb output ---\n{s}\n---\n", .{out});
    for (problems.items) |text| std.debug.print("lldb test: {s}\n", .{text});
    return error.LldbRunFailed;
}

// ------------------------------------------------------------ GUI editor

/// Seconds for the whole GUI run: the build at open, the game, the save
/// and the build it starts.
const gui_deadline_s = "900";

/// The GUI editor's steps (test/host/gui/save_path.gd).
const gui_cases = [_][]const u8{
    "ZTEST PASS gui_editor",
    "ZTEST PASS gui_build_at_open",
    "ZTEST PASS gui_script_open",
    "ZTEST PASS gui_game_running",
    "ZTEST PASS gui_game_runs_old_code",
    "ZTEST PASS gui_script_edited",
    "ZTEST PASS gui_script_saved",
    "ZTEST PASS gui_save_builds",
    "ZTEST PASS gui_game_loads_message_gen",
    "ZTEST PASS gui_game_runs_new_code",
    "ZTEST PASS gui_game_swapped_line",
};

// Run by `zig build test-gui` only (spec section 12, check 6): the GUI
// editor under Xvfb plays the e2e project's main scene, a tool autoload
// edits res://hero.zig in the script editor and saves it with
// ScriptEditor.save_all_scripts(); the running game finds the new build in
// the manifest, swaps to it and returns the new value of a changed method
// with its field values kept. The manual desktop run of the same
// steps is in test/host/gui/README.md.
test "gui: save in the script editor reaches the running game" {
    if (!gui_opts.run_gui) return error.SkipZigTest;
    try requireIntegration();
    var p: Project = undefined;
    try p.init("e2e");
    defer p.deinit();
    const a = p.arena_state.allocator();
    try addBuildSettings(&p);
    // The editor test as the autoload res://check.gd.
    const cwd = Io.Dir.cwd();
    var gui_dir = try cwd.openDir(io, gui_opts.gui_dir, .{});
    defer gui_dir.close(io);
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    try gui_dir.copyFile("save_path.gd", dir, "check.gd", io, .{});
    const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    // The game renders like the editor: OpenGL compatibility, which Xvfb
    // runs without a GPU.
    const new = try std.mem.concat(a, u8, &.{ old, "\n[autoload]\n\ncheck=\"*res://check.gd\"\n\n[rendering]\n\nrenderer/rendering_method=\"gl_compatibility\"\n" });
    try dir.writeFile(io, .{ .sub_path = "project.godot", .data = new });
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://addons/ziggurat/ziggurat.gdextension\n" });

    // Editor settings, data and the log stay in the test's folder: nothing
    // of the user's own Godot setup is read or changed.
    try p.tmp.dir.createDirPath(io, "config");
    try p.tmp.dir.createDirPath(io, "data");
    const root = try p.tmp.dir.realPathFileAlloc(io, ".", a);
    const log_path = try std.fs.path.join(a, &.{ root, "gui.log" });
    const env = p.env.?;
    try env.put("XDG_CONFIG_HOME", try std.fs.path.join(a, &.{ root, "config" }));
    try env.put("XDG_DATA_HOME", try std.fs.path.join(a, &.{ root, "data" }));
    try env.put("ZTEST_LOG", log_path);
    try env.put("ZTEST_GUI", "1");

    const script = try std.fs.path.join(a, &.{ gui_opts.gui_dir, "run-gui.sh" });
    const result = try std.process.run(a, io, .{
        .argv = &.{ "bash", script, gui_opts.xvfb_run, opts.godot_exe, p.path, log_path, gui_deadline_s },
        .environ_map = env,
    });
    const out = cwd.readFileAlloc(io, log_path, a, .limited(64 << 20)) catch "";

    var problems: std.ArrayList([]const u8) = .empty;
    if (!result.term.success()) try problems.append(a, "the editor did not exit with status 0 before the deadline");
    const needed = gui_cases ++ e2e_game_cases ++ [_][]const u8{
        "ZTEST DONE",
        "ziggurat: build 1 loaded (open, ",
        " loaded (save, ",
        // The game's line; Play may have built a newer generation first.
        "ziggurat: generation ",
    };
    for (needed) |text| {
        if (std.mem.indexOf(u8, out, text) == null)
            try problems.append(a, try std.fmt.allocPrint(a, "missing expected text: {s}", .{text}));
    }
    // Godot's reload on the save comes before staging; the game reads the
    // manifest quietly.
    for ([_][]const u8{ "ZTEST FAIL", "Program crashed", "emit of signal", "may not be staged yet" }) |text| {
        if (std.mem.indexOf(u8, out, text) != null)
            try problems.append(a, try std.fmt.allocPrint(a, "rejected text present: {s}", .{text}));
    }
    if (std.mem.indexOf(u8, out, "swaps arrive in a later version") != null)
        try problems.append(a, "the game still logs that swaps come later");
    if (problems.items.len == 0) {
        // The timing and what Play did go to the file named by
        // ZTEST_GUI_RECORD, when set. Nothing is printed: output on success
        // makes the build runner report the test command as failed.
        const record = env.get("ZTEST_GUI_RECORD") orelse return;
        var text: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "gui save path: ")) try text.print(a, "{s}\n", .{line});
        }
        try cwd.writeFile(io, .{ .sub_path = record, .data = text.items });
        return;
    }
    std.debug.print("--- GUI log ({s}) ---\n{s}\n---\n{s}{s}", .{ log_path, out, result.stdout, result.stderr });
    for (problems.items) |text| std.debug.print("gui test: {s}\n", .{text});
    return error.GuiRunFailed;
}

/// Case-insensitive search.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

/// The export host linked with test/fixtures/linked_project: the line its
/// game logs at start.
const linked_line = "ziggurat: 2 scripts linked";

/// A project with the linked library (export host archive and the linked
/// fixture's module object, build.zig `linkedLibrary`) as its host,
/// `res://check.gd` set to linked_game.gd for `case`, and no `.zig` file.
fn initLinked(p: *Project, case: []const u8) !void {
    try p.initWith("empty", opts.linked_host_lib);
    errdefer p.deinit();
    const a = p.arena_state.allocator();
    try p.addCheck("linked_game.gd");
    const env = try a.create(std.process.Environ.Map);
    env.* = try testing.environ.createMap(testing.allocator);
    p.env = env;
    try env.put("ZTEST_LINKED_CASE", case);
}

/// Fails when the project folder holds a `.zig` file: the linked game must
/// not need one.
fn expectNoZigFiles(p: *Project) !void {
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".zig")) {
            std.debug.print("the linked project holds {s}\n", .{entry.path});
            return error.ZigFileInProject;
        }
    }
}

test "linked game runs scripts" {
    try requireIntegration();
    var p: Project = undefined;
    try initLinked(&p, "ready");
    defer p.deinit();
    try expectNoZigFiles(&p);
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ linked_line, "[ziggurat] alpha ready speed=3", "[ziggurat] beta ready", "linked check: scripts running" },
        .reject = &.{ "no module source yet", "is not part of this export" },
    });
}

test "unknown path fails cleanly" {
    try requireIntegration();
    var p: Project = undefined;
    try initLinked(&p, "unknown");
    defer p.deinit();
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ linked_line, "Ziggurat: res://nope.zig is not part of this export", "linked check: nope is null" },
    });
}

test "exists answers from the table" {
    try requireIntegration();
    var p: Project = undefined;
    try initLinked(&p, "exists");
    defer p.deinit();
    try expectNoZigFiles(&p);
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ linked_line, "linked check: exists alpha=true beta=true nope=false file=false" },
        .reject = &.{"is not part of this export"},
    });
}

/// `uid://cgr8lnhtluchh` as Godot encodes the id (resource_uid.cpp).
const alpha_uid_text = "uid://cgr8lnhtluchh";
const alpha_uid: u64 = 0x4898933b48be1eed;

test "uid-only scene runs" {
    try requireIntegration();
    var p: Project = undefined;
    try initLinked(&p, "uid");
    defer p.deinit();
    const a = p.arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    // The scene names the script by uid; its text path is wrong, so only
    // the uid finds it.
    const scene = "[gd_scene load_steps=2 format=3]\n\n" ++
        "[ext_resource type=\"Script\" uid=\"" ++ alpha_uid_text ++ "\" path=\"res://wrong.zig\" id=\"1_alpha\"]\n\n" ++
        "[node name=\"Root\" type=\"Node2D\"]\nscript = ExtResource(\"1_alpha\")\n";
    try dir.writeFile(io, .{ .sub_path = "uid_scene.tscn", .data = scene });
    // `uid_cache.bin` as an export writes it (resource_uid.cpp
    // `encode_binary_cache`): u32 count, then per entry u64 id, u32 length
    // and the UTF-8 path, little-endian.
    const path = "res://alpha.zig";
    var cache: std.ArrayList(u8) = .empty;
    var word: [8]u8 = undefined;
    std.mem.writeInt(u32, word[0..4], 1, .little);
    try cache.appendSlice(a, word[0..4]);
    std.mem.writeInt(u64, &word, alpha_uid, .little);
    try cache.appendSlice(a, &word);
    std.mem.writeInt(u32, word[0..4], path.len, .little);
    try cache.appendSlice(a, word[0..4]);
    try cache.appendSlice(a, path);
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/uid_cache.bin", .data = cache.items });
    try expectNoZigFiles(&p);
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ linked_line, "[ziggurat] alpha ready speed=3", "linked check: uid scene script res://alpha.zig" },
        .reject = &.{ "is not part of this export", "invalid UID" },
    });
}

/// The bytes of the linked library (`linkedLibrary`), allocated with `a`.
fn readLinkedLib(a: std.mem.Allocator) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, opts.linked_host_lib, a, .limited(1 << 30));
}

test "export build has no editor plugin" {
    try requireIntegration();
    const a = testing.allocator;
    // The plugin's class name, the Zig download's mirror list URL, the
    // minisign check of the download and install (apart from the URL) and
    // the game's reload capture of editor messages.
    const needles = [_][]const u8{ "ZigEditorPlugin", "ZigExportPlugin", platform.mirrors.list_url, "minisig", "ZigReloadCapture" };
    const export_lib = try readLinkedLib(a);
    defer a.free(export_lib);
    const host_lib = try Io.Dir.cwd().readFileAlloc(io, opts.host_lib, a, .limited(1 << 30));
    defer a.free(host_lib);
    for (needles) |needle| {
        if (std.mem.indexOf(u8, export_lib, needle) != null) {
            std.debug.print("the export build holds '{s}'\n", .{needle});
            return error.ExportBuildHasEditorPlugin;
        }
        // The ordinary host holds it, so the search can find it.
        if (std.mem.indexOf(u8, host_lib, needle) == null) return error.SearchFindsNothing;
    }
}

test "linked library loads nothing at run time" {
    try requireIntegration();
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    const lib = try readLinkedLib(a);
    defer a.free(lib);
    // The dynamic symbol table's names: no dlopen import. The ordinary host
    // imports it (it loads each generation), so the search can find it.
    const linked_names = try dynamicSymbolNames(a, lib);
    defer a.free(linked_names);
    if (std.mem.indexOf(u8, linked_names, "\x00dlopen\x00") != null) return error.LinkedLibraryImportsDlopen;
    const host_lib = try Io.Dir.cwd().readFileAlloc(io, opts.host_lib, a, .limited(1 << 30));
    defer a.free(host_lib);
    const host_names = try dynamicSymbolNames(a, host_lib);
    defer a.free(host_names);
    if (std.mem.indexOf(u8, host_names, "\x00dlopen\x00") == null) return error.SearchFindsNothing;
    // Godot's entry point is exported; the module's two entry points
    // resolve inside the library and are not.
    if (std.mem.indexOf(u8, linked_names, "\x00ziggurat_host_init\x00") == null) return error.NoEntryPoint;
    for ([_][]const u8{ "\x00ziggurat_describe\x00", "\x00ziggurat_init\x00" }) |name| {
        if (std.mem.indexOf(u8, linked_names, name) != null) return error.ModuleEntryExported;
    }
}

/// The names of the ELF64 little-endian file's dynamic symbols (`.dynsym`),
/// each between NUL bytes, allocated with `a`. A malformed file fails with
/// the ELF reader's error (every offset and size is range-checked).
fn dynamicSymbolNames(a: std.mem.Allocator, elf: []const u8) ![]u8 {
    const syms = try platform.elf.dynamicSymbols(a, elf);
    defer a.free(syms);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, 0);
    for (syms) |s| {
        try out.appendSlice(a, s.name);
        try out.append(a, 0);
    }
    return out.toOwnedSlice(a);
}

test "export build has no manifest path" {
    try requireIntegration();
    const a = testing.allocator;
    // The reader's names and the manifest's file name. Any text the
    // library holds counts, the way `strings` finds it: symbol names,
    // string literals and debug information alike.
    const needles = [_][]const u8{ "manifest", "readTrusted", "recheck", "loadFromStore" };
    const export_lib = try readLinkedLib(a);
    defer a.free(export_lib);
    for (needles) |n| {
        if (containsIgnoreCase(export_lib, n)) {
            std.debug.print("the export build holds '{s}'\n", .{n});
            return error.ExportBuildHasManifestPath;
        }
    }
    // The ordinary host holds them, so the search can find them.
    const host_lib = try Io.Dir.cwd().readFileAlloc(io, opts.host_lib, a, .limited(1 << 30));
    defer a.free(host_lib);
    for (needles) |n| {
        if (!containsIgnoreCase(host_lib, n)) {
            std.debug.print("the ordinary host lacks '{s}'\n", .{n});
            return error.SearchFindsNothing;
        }
    }

    // A linked game ignores a good manifest and the generation it names:
    // it runs its linked scripts.
    var p: Project = undefined;
    try initLinked(&p, "ready");
    defer p.deinit();
    const pa = p.arena_state.allocator();
    const store_path = try stageGameProject(&p);
    // stageGameProject set its own check and copied the fixture's scripts.
    try p.addCheck("linked_game.gd");
    var store = try Io.Dir.cwd().openDir(io, store_path, .{});
    defer store.close(io);
    var name_buf: [64]u8 = undefined;
    try writeGameManifest(&store, try std.fmt.allocPrint(pa, "gen=1\npath=gen/1/{s}\n", .{try genLibName(&name_buf, 1)}));
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{ linked_line, "linked check: scripts running" },
        .reject = &.{ "mover ready", "generation 1 loaded", "no module source yet" },
    });
}

// ------------------------------------------------------------ export

/// Seconds for an export (an editor run with a cold release build of the
/// SDK and gdzig) or for an exported game's run.
const export_deadline_s = "900";
/// In every `.zig` file of test/host/projects/export; never in a game.
const export_marker = "ZIGG_EXPORT_SOURCE_MARKER_5c2e";
/// The Linux preset's output, relative to the project.
const export_out = "out/game.x86_64";
/// Where the export plugin writes the game library (the `.gdextension`'s
/// template keys name it).
const game_lib_rel = ".godot/ziggurat/export/x86_64-linux/libziggurat_game.so";
/// What the export plugin says for a preset without a supported target.
const export_platform_message = "Ziggurat exports Linux x86_64, Windows x86_64 and macOS (universal) in this version";
/// The plugin's progress line before an export build.
const export_building = "Ziggurat: building the game library for the export";
/// The end of every error after which the export fails.
const export_incomplete = "the files in the export's output folder are incomplete";

/// Copies the export host archive and the empty-project game library into
/// the project's `addons/ziggurat/bin/x86_64-linux/`, where the export
/// plugin looks for a Linux export's inputs.
fn copyExportInputs(dir: Io.Dir) !void {
    const cwd = Io.Dir.cwd();
    try dir.createDirPath(io, "addons/ziggurat/bin/x86_64-linux");
    try cwd.copyFile(opts.export_host_archive, dir, "addons/ziggurat/bin/x86_64-linux/libziggurat_host_export.a", io, .{});
    try cwd.copyFile(opts.game_empty_lib, dir, "addons/ziggurat/bin/x86_64-linux/libziggurat_game_empty.so", io, .{});
}

/// Skips the test when `-Dexport-templates` is unset (ruling R3). The test
/// prints nothing (a passing test that writes to stderr is labelled
/// "failed command"); build.zig prints one notice after the run.
fn requireTemplates() !void {
    try requireIntegration();
    if (opts.export_templates.len != 0) return;
    return error.SkipZigTest;
}

/// A copy of test/host/projects/export with the add-on, its export inputs
/// (the export host archive and the empty-project game library in
/// `addons/ziggurat/bin/x86_64-linux/`), the build settings (the test's Zig and SDK
/// manifest; `zig` instead when given), per-user folders inside the test's
/// folder, the presets pointing at `-Dexport-templates`, and the export
/// tests' shared build cache.
fn initExport(p: *Project, zig: ?[]const u8) !void {
    return initExportWith(p, zig, opts.host_lib);
}

/// As `initExport`, with the editor library `host_lib`.
fn initExportWith(p: *Project, zig: ?[]const u8, host_lib: []const u8) !void {
    try p.initWith("export", host_lib);
    errdefer p.deinit();
    const a = p.arena_state.allocator();
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    try copyExportInputs(dir);
    try addBuildSettingsWith(p, zig orelse opts.zig_exe);
    try isolateUserFolders(p);
    // One build cache for every export test, kept between runs: only the
    // first export builds the SDK and gdzig cold.
    try cwd.createDirPath(io, opts.export_test_cache);
    try p.env.?.put("XDG_CACHE_HOME", try cwd.realPathFileAlloc(io, opts.export_test_cache, a));
    const presets = try dir.readFileAlloc(io, "export_presets.cfg", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "export_presets.cfg", .data = try std.mem.replaceOwned(u8, a, presets, "@TEMPLATES@", opts.export_templates) });
    try dir.createDirPath(io, "out");
}

/// Exports the Linux preset headless (`--export-release`).
fn exportGame(p: *Project, texts: Project.Texts) !void {
    var t = texts;
    t.deadline = export_deadline_s;
    const a = p.arena_state.allocator();
    return p.run(&.{ "export", "Linux", try std.fs.path.join(a, &.{ p.path, export_out }) }, t);
}

/// Runs the exported game (`out/game.x86_64` with its `.pck`).
fn runExported(p: *Project, texts: Project.Texts) !void {
    var t = texts;
    t.deadline = export_deadline_s;
    const a = p.arena_state.allocator();
    return p.run(&.{ "run", try std.fs.path.join(a, &.{ p.path, export_out }) }, t);
}

/// The project file `rel` exists.
fn projectFileExists(p: *Project, rel: []const u8) !bool {
    return fileExists(try std.fs.path.join(p.arena_state.allocator(), &.{ p.path, rel }));
}

/// Writes `data` to the project file `rel`.
fn writeProjectFile(p: *Project, rel: []const u8, data: []const u8) !void {
    return writeIn(p.path, rel, data);
}

/// A script with a compile error.
const broken_script =
    \\const z = @import("ziggurat");
    \\pub const extends = z.godot.Node;
    \\base: *z.godot.Node,
    \\pub fn _ready(_: *@This()) void {
    \\    no_such_function();
    \\}
    \\
;

/// What a game started from the export fixture's main scene prints.
const export_game_lines = [_][]const u8{
    "ziggurat: 2 scripts linked",
    "[ziggurat] hero ready speed=7.5",
    "[ziggurat] sidekick ready",
    "export check: main ready",
};

test "export: exported game runs scripts" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    try exportGame(&p, .{ .once = &.{export_building}, .reject = &.{"ERROR:"} });
    try testing.expect(try projectFileExists(&p, "out/libziggurat_game.so"));
    try runExported(&p, .{ .once = &export_game_lines, .reject = &.{ "ERROR:", "WARNING:" } });
}

/// The export plugin's log line for a debug export.
const export_debug_line = "Ziggurat: debug export keeps debug information, with this computer's file paths, and is not reproducible. Turn off Export With Debug for a release.";

/// The export plugin's log line for a Windows debug export.
const export_debug_line_windows = "Ziggurat: debug export writes the game library's debug information to a separate .pdb file in the build cache, which the export does not ship; the library keeps only that file's name. Turn off Export With Debug for a release.";

/// Whether the exported game library `out/libziggurat_game.so` has a
/// `.debug_info` section.
fn exportedLibHasDebugInfo(p: *Project) !bool {
    const a = p.arena_state.allocator();
    const lib = try std.fs.path.join(a, &.{ p.path, "out", "libziggurat_game.so" });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, lib, a, .limited(1 << 30));
    return platform.elf.hasSection(bytes, ".debug_info");
}

test "export: a debug export keeps debug information" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    const a = p.arena_state.allocator();
    try p.run(&.{ "export-debug", "Linux", try std.fs.path.join(a, &.{ p.path, export_out }) }, .{
        .once = &.{ export_building, export_debug_line },
        .reject = &.{"ERROR:"},
        .deadline = export_deadline_s,
    });
    try testing.expect(try exportedLibHasDebugInfo(&p));
    // The debug game runs (the debug template).
    try runExported(&p, .{ .once = &export_game_lines, .reject = &.{"ERROR:"} });
    // A release export of the same project has none, and no such line.
    try exportGame(&p, .{ .once = &.{export_building}, .reject = &.{ "ERROR:", export_debug_line } });
    try testing.expect(!try exportedLibHasDebugInfo(&p));
}

test "export: no sources in the pack" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    try exportGame(&p, .{ .once = &.{export_building} });
    const a = p.arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{ .iterate = true });
    defer dir.close(io);
    // The marker is in the sources, so the search can find it.
    const source = try dir.readFileAlloc(io, "hero.zig", a, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, source, export_marker) != null);
    const pck = try dir.readFileAlloc(io, "out/game.pck", a, .limited(1 << 30));
    if (std.mem.indexOf(u8, pck, export_marker) != null) return error.SourceInPack;
    // The pack holds text files as they are: the `.gdextension` is found.
    if (std.mem.indexOf(u8, pck, "entry_symbol = \"ziggurat_host_init\"") == null) return error.SearchFindsNothing;
    var out = try dir.openDir(io, "out", .{ .iterate = true });
    defer out.close(io);
    var walker = try out.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (std.ascii.endsWithIgnoreCase(entry.basename, ".zig")) {
            std.debug.print("the export folder holds {s}\n", .{entry.path});
            return error.SourceInExportFolder;
        }
        const bytes = out.readFileAlloc(io, entry.path, a, .limited(1 << 30)) catch continue;
        if (std.mem.indexOf(u8, bytes, export_marker) != null) {
            std.debug.print("the export folder's {s} holds the source marker\n", .{entry.path});
            return error.SourceInExportFolder;
        }
    }
}

test "export: uid-only scene runs" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // The main scene names hero.zig only by its uid (hero.zig.uid); the
    // text path is wrong.
    const a = p.arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "project.godot", .data = try std.mem.replaceOwned(u8, a, old, "res://main.tscn", "res://uid_main.tscn") });
    try exportGame(&p, .{ .once = &.{export_building}, .reject = &.{"ERROR:"} });
    try runExported(&p, .{
        .once = &.{ "ziggurat: 2 scripts linked", "[ziggurat] hero ready speed=3", "export check: main ready" },
        .reject = &.{ "ERROR:", "WARNING:", "wrong.zig", "invalid UID" },
    });
}

test "export: script added before export runs" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // An editor build first (Play's build, through --build-solutions).
    try p.addAutoloadCheck("export_editor.gd");
    try p.run(&.{ "build", "30" }, .{ .expect = &.{"ZTEST PASS export_editor_built"}, .deadline = build_deadline_s });
    // Then a script the editor never built, in the main scene.
    try writeProjectFile(&p, "late.zig",
        \\const z = @import("ziggurat");
        \\pub const extends = z.godot.Node;
        \\base: *z.godot.Node,
        \\pub fn _ready(_: *@This()) void {
        \\    z.log(.info, "late ready", .{});
        \\}
        \\
    );
    const a = p.arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const scene = try dir.readFileAlloc(io, "main.tscn", a, .limited(64 * 1024));
    var new = try std.mem.replaceOwned(u8, a, scene, "[node name=\"Main\"", "[ext_resource type=\"Script\" path=\"res://late.zig\" id=\"9_late\"]\n\n[node name=\"Main\"");
    new = try std.mem.concat(a, u8, &.{ new, "\n[node name=\"Late\" type=\"Node\" parent=\".\"]\nscript = ExtResource(\"9_late\")\n" });
    try dir.writeFile(io, .{ .sub_path = "main.tscn", .data = new });
    try exportGame(&p, .{ .once = &.{export_building}, .reject = &.{"ERROR:"} });
    try runExported(&p, .{
        .once = &.{ "ziggurat: 3 scripts linked", "[ziggurat] late ready", "[ziggurat] hero ready speed=7.5" },
        .reject = &.{ "ERROR:", "WARNING:" },
    });
}

test "export: export fails on a broken build" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    try writeProjectFile(&p, "broken.zig", broken_script);
    try exportGame(&p, .{
        .once = &.{export_building},
        .expect = &.{ "Ziggurat: res://broken.zig:5:5: ", "Ziggurat: The Zig build for the export failed", export_incomplete },
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: stale library is never shipped" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    try writeProjectFile(&p, game_lib_rel, "an old game library");
    try writeProjectFile(&p, "broken.zig", broken_script);
    try exportGame(&p, .{ .once = &.{export_building}, .exit_code = "1" });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: export fails when Zig is missing" {
    try requireTemplates();
    var p: Project = undefined;
    // A Zig path that does not exist, no Zig on PATH and no downloaded Zig
    // (`initExport` gives the test its own per-user folders).
    try initExport(&p, "/nonexistent/ziggurat-test/zig");
    defer p.deinit();
    try p.env.?.put("PATH", "/nonexistent/ziggurat-test");
    try exportGame(&p, .{
        .expect = &.{ "Ziggurat: Ziggurat cannot build the game library for the export:", "no zig was found", export_incomplete },
        .reject = &.{export_building},
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: export fails without a usable Zig" {
    try requireTemplates();
    var p: Project = undefined;
    // An existing file that is not Zig 0.17.0: the locator stops at the
    // first candidate that exists, so no Zig on PATH is used instead.
    var dir_tmp = testing.tmpDir(.{});
    defer dir_tmp.cleanup();
    try dir_tmp.dir.writeFile(io, .{ .sub_path = "old-zig", .data = "#!/bin/sh\necho 0.16.0\n", .flags = .{ .permissions = .executable_file } });
    const bad = try dir_tmp.dir.realPathFileAlloc(io, "old-zig", testing.allocator);
    defer testing.allocator.free(bad);
    try initExport(&p, bad);
    defer p.deinit();
    try exportGame(&p, .{
        .expect = &.{ "Ziggurat: Ziggurat cannot build the game library for the export:", "is Zig 0.16.0", export_incomplete },
        .reject = &.{export_building},
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: an old library that cannot be deleted fails the export" {
    try requireTemplates();
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var p: Project = undefined;
    // No Zig scripts and no Zig: the export would copy the empty game
    // library, but the old one is in a folder where nothing can be
    // deleted or added.
    try initExport(&p, "/nonexistent/ziggurat-test/zig");
    defer p.deinit();
    try removeExportScripts(&p);
    const old = "an old game library";
    try writeProjectFile(&p, game_lib_rel, old);
    const a = p.arena_state.allocator();
    const lib_dir = try std.fs.path.join(a, &.{ p.path, std.fs.path.dirname(game_lib_rel).? });
    try setMode(lib_dir, 0o555);
    defer setMode(lib_dir, 0o755) catch {};
    // A user who may delete anyway (root) cannot run this test.
    var probe_dir = try Io.Dir.cwd().openDir(io, lib_dir, .{});
    defer probe_dir.close(io);
    if (probe_dir.createFile(io, "probe", .{})) |f| {
        f.close(io);
        return error.SkipZigTest;
    } else |_| {}
    try exportGame(&p, .{
        .expect = &.{ "Ziggurat: Ziggurat cannot delete the game library of an earlier export", "emptied it and removed its permissions", export_incomplete, "Failed to copy shared object" },
        .exit_code = "1",
    });
    const left = try Io.Dir.cwd().statFile(io, try std.fs.path.join(a, &.{ p.path, game_lib_rel }), .{});
    try testing.expectEqual(@as(u64, 0), left.size);
    try testing.expectEqual(@as(std.posix.mode_t, 0), left.permissions.toMode() & 0o777);
    // Nothing was shipped: neither the old library nor the emptied file.
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: an old library that stays is removed from the export's output" {
    try requireTemplates();
    var p: Project = undefined;
    // The probe host, which with ZIGGURAT_TEST_OLD_LIBRARY_STAYS=1 applies
    // the Windows rule with a failing delete and rename: the old library
    // stays readable, so Godot copies it next to the game (an error message
    // does not stop an export). No Zig scripts and no Zig: nothing else
    // writes a library.
    try initExportWith(&p, "/nonexistent/ziggurat-test/zig", opts.probe_host_lib);
    defer p.deinit();
    try removeExportScripts(&p);
    try writeProjectFile(&p, game_lib_rel, "an old game library");
    try p.env.?.put("ZIGGURAT_TEST_OLD_LIBRARY_STAYS", "1");
    const a = p.arena_state.allocator();
    const lib_abs = try std.fs.path.join(a, &.{ p.path, game_lib_rel });
    const sentence = try std.fmt.allocPrint(a, "Ziggurat cannot replace the old game library {s}: AccessDenied (renaming it aside failed: AccessDenied). Close programs that use it and export again.", .{lib_abs});
    // A full export: the copy next to the game is deleted at the end.
    try exportGame(&p, .{
        .expect = &.{ sentence, export_incomplete, "Ziggurat deleted ", "out/libziggurat_game.so from the export's output folder" },
        .reject = &.{export_building},
    });
    try testing.expect(try projectFileExists(&p, "out/game.x86_64"));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
    try testing.expect(try projectFileExists(&p, game_lib_rel));
    // A full ZIP export: the zip holds the old library, so it is deleted.
    try p.run(&.{ "export", "Linux", try std.fs.path.join(a, &.{ p.path, "out/game.zip" }) }, .{
        .expect = &.{ sentence, "Ziggurat deleted the ZIP export " },
        .reject = &.{export_building},
        .deadline = export_deadline_s,
    });
    try testing.expect(!try projectFileExists(&p, "out/game.zip"));
    // Without the probe's failure the next export replaces it as usual.
    _ = p.env.?.swapRemove("ZIGGURAT_TEST_OLD_LIBRARY_STAYS");
    try exportGame(&p, .{ .reject = &.{ "ERROR:", "Ziggurat deleted " } });
    try testing.expect(try projectFileExists(&p, "out/libziggurat_game.so"));
}

/// Sets the permission bits of the folder `path`.
fn setMode(path: []const u8, mode: std.posix.mode_t) !void {
    return Io.Dir.cwd().setFilePermissions(io, path, .fromMode(mode), .{});
}

/// Turns the export fixture into a project without Zig scripts: the
/// scripts go, and the main scene holds only main.gd.
fn removeExportScripts(p: *Project) !void {
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
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

test "export: features without a supported target give the platform message" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // `linux` + `arm64`: no target key. A pack export needs no template.
    try p.run(&.{ "export-pack", "Linux arm64", try std.fs.path.join(a, &.{ p.path, "out/game.pck" }) }, .{
        .once = &.{"Ziggurat: " ++ export_platform_message},
        .reject = &.{export_building},
        .deadline = export_deadline_s,
    });
}

test "export: custom features do not choose the platform" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // An earlier export's library: it must not ship. The preset is Linux
    // with the custom features `macos` and `windows`, which Godot adds to
    // the export's feature list.
    const old = "an old game library";
    try writeProjectFile(&p, game_lib_rel, old);
    try p.run(&.{ "export", "Linux custom features", try std.fs.path.join(a, &.{ p.path, export_out }) }, .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", export_platform_message },
        .deadline = export_deadline_s,
    });
    const lib = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, "out", "libziggurat_game.so" }), a, .limited(1 << 30));
    try testing.expect(std.mem.startsWith(u8, lib, "\x7fELF"));
    try testing.expect(!try projectFileExists(&p, ".godot/ziggurat/export/universal-macos"));
    try testing.expect(!try projectFileExists(&p, windows_game_lib_rel));
    try runExported(&p, .{ .once = &export_game_lines, .reject = &.{"ERROR:"} });
}

/// Where a Windows export writes the game library in the project.
const windows_game_lib_rel = ".godot/ziggurat/export/x86_64-windows/ziggurat_game.dll";

/// Reads the exported `out/ziggurat_game.dll` and checks it as an export
/// build checks its output: it exports only `ziggurat_host_init` and
/// imports no `LoadLibrary*` or `GetProcAddress`.
fn expectWindowsGameLibrary(p: *Project) !void {
    const a = p.arena_state.allocator();
    const bytes = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, "out", "ziggurat_game.dll" }), a, .limited(1 << 30));
    var why: [256]u8 = undefined;
    if (try zbuild.export_build.checkLibrary(a, .pe, bytes, &why)) |sentence| {
        std.debug.print("the exported game DLL: {s}\n", .{sentence});
        return error.WindowsGameLibraryRefused;
    }
    const ex = try platform.pe.exports(a, bytes);
    try testing.expectEqual(@as(usize, 1), ex.len);
    try testing.expectEqualStrings("ziggurat_host_init", ex[0]);
    // No build-machine path: a debug build's information is in a `.pdb`
    // in the build cache, and a release build has none.
    try testing.expect(std.mem.indexOf(u8, bytes, p.path) == null);
}

test "export: windows export from the linux editor" {
    try requireTemplates();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    // The release package holds the Windows export archive, the empty
    // game DLL and the Windows SDK (sdk/x86_64-windows/), which an export
    // for another target than the editor's always uses.
    try initInstalled(&p);
    defer p.deinit();
    const a = p.arena_state.allocator();
    const exe = try std.fs.path.join(a, &.{ p.path, "out/game.exe" });
    // A debug export first: its debug information goes to a `.pdb` in the
    // build cache, and the log line says so.
    try p.run(&.{ "export-debug", "Windows", exe }, .{
        .once = &.{ export_building, export_debug_line_windows },
        .reject = &.{ "ERROR:", "is not set", "is not usable" },
        .deadline = export_deadline_s,
    });
    for ([_][]const u8{ "out/game.exe", "out/game.pck", "out/ziggurat_game.dll", windows_game_lib_rel }) |f| try testing.expect(try projectFileExists(&p, f));
    try expectWindowsGameLibrary(&p);
    // Then a release export, without that line.
    try p.run(&.{ "export", "Windows", exe }, .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", export_debug_line, export_debug_line_windows, "is not set", "is not usable" },
        .deadline = export_deadline_s,
    });
    for ([_][]const u8{ "out/game.exe", "out/game.pck", "out/ziggurat_game.dll" }) |f| try testing.expect(try projectFileExists(&p, f));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
    try expectWindowsGameLibrary(&p);
}

/// The export plugin's log line for a macOS debug export.
const export_debug_line_macos = "Ziggurat: debug export leaves the game library's debug information in the build cache, which the export does not ship; the library keeps only the paths of those files, so it is not reproducible. Turn off Export With Debug for a release.";

/// Where a macOS export writes the universal game library in the project.
const macos_game_lib_rel = ".godot/ziggurat/export/universal-macos/libziggurat_game.dylib";
/// The app bundle Godot's macOS export writes: the project name
/// (`application/config/name`) and `.app`.
const macos_app_name = "ziggurat-host-test-export.app";
/// Where Godot's macOS export puts a GDExtension library in the app.
const macos_app_lib = "Contents/Frameworks/libziggurat_game.dylib";

/// Skips the test unless `-Dexport-templates` is set and the host is
/// x86_64 Linux (the macOS inputs are built only there).
fn requireMacosExport() !void {
    try requireTemplates();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    if (opts.macos_game_empty.len == 0) return error.SkipZigTest;
}

/// The export fixture (`initExport`) with the macOS export inputs where the
/// release package puts them: each arch's export host archive in
/// `addons/ziggurat/bin/<arch>-macos/`, the universal empty game library
/// in `addons/ziggurat/bin/universal-macos/`, and each arch's SDK in
/// `addons/ziggurat/sdk/<arch>-macos/`.
fn initMacosExport(p: *Project) !void {
    try initExport(p, null);
    errdefer p.deinit();
    const a = p.arena_state.allocator();
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    const inputs = [_]struct { key: []const u8, manifest: []const u8, archive: []const u8 }{
        .{ .key = "aarch64-macos", .manifest = opts.macos_sdk_manifest_aarch64, .archive = opts.macos_host_archive_aarch64 },
        .{ .key = "x86_64-macos", .manifest = opts.macos_sdk_manifest_x86_64, .archive = opts.macos_host_archive_x86_64 },
    };
    for (inputs) |in| {
        const bin = try std.fmt.allocPrint(a, "addons/ziggurat/bin/{s}", .{in.key});
        try dir.createDirPath(io, bin);
        try cwd.copyFile(in.archive, dir, try std.fmt.allocPrint(a, "{s}/libziggurat_host_export.a", .{bin}), io, .{});
        const sdk = try std.fmt.allocPrint(a, "addons/ziggurat/sdk/{s}", .{in.key});
        try dir.createDirPath(io, sdk);
        var dst = try dir.openDir(io, sdk, .{});
        defer dst.close(io);
        var src = try cwd.openDir(io, std.fs.path.dirname(in.manifest).?, .{ .iterate = true });
        defer src.close(io);
        try copyTree(a, src, dst);
    }
    try dir.createDirPath(io, "addons/ziggurat/bin/universal-macos");
    try cwd.copyFile(opts.macos_game_empty, dir, "addons/ziggurat/bin/universal-macos/libziggurat_game_empty.dylib", io, .{});
}

/// Checks a macOS game library as the export build checks its output: a
/// universal file (x86_64 and arm64) whose slices export only
/// `_ziggurat_host_init` (and the linker's two symbols), import symbols
/// but not `_dlopen`, and are built for macOS 11.0. Returns the slices
/// (allocated with `a`).
fn expectMacosGameLibrary(a: std.mem.Allocator, bytes: []const u8) ![]platform.macho.Slice {
    var why: [256]u8 = undefined;
    if (try zbuild.export_build.checkUniversal(a, bytes, &why)) |sentence| {
        std.debug.print("the macOS game library: {s}\n", .{sentence});
        return error.MacosGameLibraryRefused;
    }
    const sl = try platform.macho.slices(a, bytes);
    try testing.expectEqual(@as(usize, 2), sl.len);
    for (sl) |s| {
        const slice = bytes[@intCast(s.offset)..][0..@intCast(s.size)];
        const im = try platform.macho.imports(a, slice);
        // An empty list would make the `_dlopen` check below pass for nothing.
        try testing.expect(im.len > 0);
        for (im) |name| try testing.expect(!std.mem.eql(u8, name, "_dlopen"));
        try testing.expectEqual(std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 }, platform.macho.minOs(slice).?);
    }
    return sl;
}

/// Exports the macOS preset `preset` (release) to `out/<rel>` and checks
/// the game library in the zip it wrote: `<app>/Contents/Frameworks/`
/// holds the universal library, as Godot copied and signed it.
fn exportMacos(p: *Project, preset: []const u8, rel: []const u8) !void {
    const a = p.arena_state.allocator();
    const zip = try std.fs.path.join(a, &.{ p.path, "out", rel });
    try p.run(&.{ "export", preset, zip }, .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", export_pack_message, export_platform_message },
        .deadline = export_deadline_s,
    });
    // The library the export built: universal, whatever the preset's arch.
    const built = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, macos_game_lib_rel }), a, .limited(1 << 30));
    _ = try expectMacosGameLibrary(a, built);
    try testing.expect(try zbuild.export_build.zipHoldsLibrary(io, zip, macos_app_lib));
    // The copy in the app, unpacked from the zip.
    const unzipped = try std.fs.path.join(a, &.{ p.path, "out", "unzipped" });
    try Io.Dir.cwd().createDirPath(io, unzipped);
    {
        var dst = try Io.Dir.cwd().openDir(io, unzipped, .{});
        defer dst.close(io);
        var f = try Io.Dir.cwd().openFile(io, zip, .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var reader = f.reader(io, &buf);
        try std.zip.extract(dst, &reader, .{});
    }
    const shipped = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ unzipped, macos_app_name, macos_app_lib }), a, .limited(1 << 30));
    try expectShippedMacosLibrary(a, built, shipped);
}

/// The library Godot shipped in the app (`shipped`) against the one the
/// export built (`built`). Godot's built-in ad-hoc signing
/// (`codesign/codesign = 1`, `CodeSign::_codesign_file`) splits a universal
/// file, signs every slice again (it adds a signature to the unsigned
/// x86_64 slice and replaces the arm64 slice's linker signature) and joins
/// them again with its own alignment (`LipO::create_file`). So the shipped
/// file differs from the built one, and both its slices are signed; it
/// still passes the export checks.
fn expectShippedMacosLibrary(a: std.mem.Allocator, built: []const u8, shipped: []const u8) !void {
    const bsl = try platform.macho.slices(a, built);
    try testing.expectEqual(@as(usize, 2), bsl.len);
    for (bsl) |s| {
        const slice = built[@intCast(s.offset)..][0..@intCast(s.size)];
        // As Zig's linker wrote them: arm64 signed, x86_64 not.
        try testing.expectEqual(s.cpu == .arm64, platform.macho.codeSignature(slice) != null);
    }
    const sl = try expectMacosGameLibrary(a, shipped);
    try testing.expect(!std.mem.eql(u8, built, shipped));
    for (bsl, sl) |b, s| {
        try testing.expectEqual(b.cpu, s.cpu);
        const slice = shipped[@intCast(s.offset)..][0..@intCast(s.size)];
        try testing.expect(platform.macho.codeSignature(slice) != null);
    }
}

test "export: macos universal preset" {
    try requireMacosExport();
    var p: Project = undefined;
    try initMacosExport(&p);
    defer p.deinit();
    try exportMacos(&p, "macOS", "game.zip");
    // A debug export (the official template has a universal debug binary):
    // its own log line, and the unstripped library passes the checks.
    {
        const a = p.arena_state.allocator();
        try p.run(&.{ "export-debug", "macOS", try std.fs.path.join(a, &.{ p.path, "out/debug.zip" }) }, .{
            .once = &.{ export_building, export_debug_line_macos },
            .reject = &.{ "ERROR:", export_pack_message, export_debug_line, export_debug_line_windows },
            .deadline = export_deadline_s,
        });
        try testing.expect(try zbuild.export_build.zipHoldsLibrary(io, try std.fs.path.join(a, &.{ p.path, "out/debug.zip" }), macos_app_lib));
        const built = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, macos_game_lib_rel }), a, .limited(1 << 30));
        _ = try expectMacosGameLibrary(a, built);
    }
    // An `.app` export: Godot writes the bundle folder itself.
    const a = p.arena_state.allocator();
    try p.run(&.{ "export", "macOS", try std.fs.path.join(a, &.{ p.path, "out/game.app" }) }, .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", export_pack_message },
        .deadline = export_deadline_s,
    });
    const built = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, macos_game_lib_rel }), a, .limited(1 << 30));
    const shipped = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ p.path, "out/game.app", macos_app_lib }), a, .limited(1 << 30));
    try expectShippedMacosLibrary(a, built, shipped);
}

/// Godot 4.7.2's official `macos.zip` holds only universal game binaries
/// (`godot_macos_{debug,release}.universal`), and a preset whose
/// `binary_format/architecture` is `arm64` asks for
/// `godot_macos_release.arm64` ("Requested template binary ... not
/// found"). Writes a custom template into the test's folder: `macos.zip`'s
/// files, with the arm64 slice of the universal release binary under that
/// name, and points the "macOS arm64" preset at it.
fn useArm64MacosTemplate(p: *Project) !void {
    const a = p.arena_state.allocator();
    const cwd = Io.Dir.cwd();
    try p.tmp.dir.createDirPath(io, "macos-template");
    var tpl = try p.tmp.dir.openDir(io, "macos-template", .{ .iterate = true });
    defer tpl.close(io);
    {
        var f = try cwd.openFile(io, try std.fs.path.join(a, &.{ opts.export_templates, "macos.zip" }), .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var reader = f.reader(io, &buf);
        try std.zip.extract(tpl, &reader, .{});
    }
    const bin_dir = "macos_template.app/Contents/MacOS/";
    const universal = try tpl.readFileAlloc(io, bin_dir ++ "godot_macos_release.universal", a, .limited(1 << 30));
    const sl = try platform.macho.slices(a, universal);
    const arm = for (sl) |s| {
        if (s.cpu == .arm64) break s;
    } else return error.NoArm64Slice;
    try tpl.writeFile(io, .{ .sub_path = bin_dir ++ "godot_macos_release.arm64", .data = universal[@intCast(arm.offset)..][0..@intCast(arm.size)] });
    try tpl.deleteFile(io, bin_dir ++ "godot_macos_release.universal");
    try tpl.deleteFile(io, bin_dir ++ "godot_macos_debug.universal");
    const zip_path = try std.fs.path.join(a, &.{ try p.tmp.dir.realPathFileAlloc(io, ".", a), "macos_arm64.zip" });
    try writeStoredZip(a, tpl, zip_path);
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    const presets = try dir.readFileAlloc(io, "export_presets.cfg", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "export_presets.cfg", .data = try std.mem.replaceOwned(u8, a, presets, "@MACOS_ARM64_TEMPLATE@", zip_path) });
}

/// Writes every file below `dir` into a new zip at `path`, stored
/// (uncompressed), in walk order.
fn writeStoredZip(a: std.mem.Allocator, dir: Io.Dir, path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    var central: std.ArrayList(u8) = .empty;
    var count: u16 = 0;
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try dir.readFileAlloc(io, entry.path, a, .limited(1 << 30));
        const crc = std.hash.Crc32.hash(data);
        const offset: u32 = @intCast(out.items.len);
        // Version 2.0, no flags, stored, 1980-01-01 00:00.
        const common = [_]u16{ 20, 0, 0, 0, 0x21 };
        try out.appendSlice(a, "PK\x03\x04");
        for (common) |v| try appendLe(a, &out, u16, v);
        for ([_]u32{ crc, @intCast(data.len), @intCast(data.len) }) |v| try appendLe(a, &out, u32, v);
        try appendLe(a, &out, u16, @intCast(entry.path.len));
        try appendLe(a, &out, u16, 0);
        try out.appendSlice(a, entry.path);
        try out.appendSlice(a, data);
        try central.appendSlice(a, "PK\x01\x02");
        try appendLe(a, &central, u16, (3 << 8) | 20);
        for (common) |v| try appendLe(a, &central, u16, v);
        for ([_]u32{ crc, @intCast(data.len), @intCast(data.len) }) |v| try appendLe(a, &central, u32, v);
        // Name, extra and comment lengths, disk, internal attributes.
        for ([_]u16{ @intCast(entry.path.len), 0, 0, 0, 0 }) |v| try appendLe(a, &central, u16, v);
        try appendLe(a, &central, u32, 0o100644 << 16);
        try appendLe(a, &central, u32, offset);
        try central.appendSlice(a, entry.path);
        count += 1;
    }
    const cd_start: u32 = @intCast(out.items.len);
    try out.appendSlice(a, central.items);
    try out.appendSlice(a, "PK\x05\x06");
    for ([_]u16{ 0, 0, count, count }) |v| try appendLe(a, &out, u16, v);
    try appendLe(a, &out, u32, @intCast(central.items.len));
    try appendLe(a, &out, u32, cd_start);
    try appendLe(a, &out, u16, 0);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn appendLe(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(a, &b);
}

test "export: macos arm64 preset" {
    try requireMacosExport();
    var p: Project = undefined;
    try initMacosExport(&p);
    defer p.deinit();
    try useArm64MacosTemplate(&p);
    // `binary_format/architecture = "arm64"`: still the universal library.
    try exportMacos(&p, "macOS arm64", "game.zip");
}

test "export: macos pack-only export fails with the full-export message" {
    try requireMacosExport();
    var p: Project = undefined;
    try initMacosExport(&p);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // A `.zip` pack: the build runs, then the zip has no app library.
    try p.run(&.{ "export-pack", "macOS", try std.fs.path.join(a, &.{ p.path, "out/game.zip" }) }, .{
        .once = &.{ export_building, export_pack_message },
        .reject = &.{export_platform_message},
        .deadline = export_deadline_s,
    });
    try testing.expect(try projectFileExists(&p, "out/game.zip"));
    try testing.expect(!try zbuild.export_build.zipHoldsLibrary(io, try std.fs.path.join(a, &.{ p.path, "out/game.zip" }), macos_app_lib));
    // A `.pck` pack says so at once.
    try p.run(&.{ "export-pack", "macOS", try std.fs.path.join(a, &.{ p.path, "out/game.pck" }) }, .{
        .once = &.{ export_building, export_pack_message },
        .reject = &.{ export_platform_message, export_incomplete },
        .deadline = export_deadline_s,
    });
}

/// The start of the error for a pack export of a project with Zig scripts.
const export_pack_message = "Ziggurat exports Zig scripts only with a full export: this PCK/ZIP export does not contain them.";

/// Exports the Linux preset as a pack only (`--export-pack`, `.pck` or
/// `.zip` by `rel`'s extension).
fn exportPack(p: *Project, rel: []const u8, texts: Project.Texts) !void {
    var t = texts;
    t.deadline = export_deadline_s;
    const a = p.arena_state.allocator();
    return p.run(&.{ "export-pack", "Linux", try std.fs.path.join(a, &.{ p.path, rel }) }, t);
}

test "export: pack export of Zig scripts gives the error" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // A good build: the pack is written (Godot does not let a plugin stop
    // it) and the error says the scripts are not in it.
    try exportPack(&p, "out/game.pck", .{ .once = &.{ export_building, export_pack_message } });
    try testing.expect(try projectFileExists(&p, "out/game.pck"));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
    // A broken build, as a `.zip` pack: the build errors (with the note
    // of a failing export: a `zip` path may be a full export until the
    // zip is written), then the same error at the end; still status 0.
    try writeProjectFile(&p, "broken.zig", broken_script);
    try exportPack(&p, "out/game.zip", .{
        .once = &.{ export_building, export_pack_message },
        .expect = &.{ "Ziggurat: res://broken.zig:5:5: ", "Ziggurat: The Zig build for the export failed" },
    });
    // A broken build as a `.pck` pack: no "This export fails" note.
    try exportPack(&p, "out/game2.pck", .{
        .once = &.{ export_building, export_pack_message },
        .expect = &.{"Ziggurat: The Zig build for the export failed"},
        .reject = &.{export_incomplete},
    });
    try testing.expect(try projectFileExists(&p, "out/game.zip"));
}

test "export: full ZIP export holds the game library" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // The Linux platform zips a full export whose path ends in `zip`.
    const a = p.arena_state.allocator();
    try p.run(&.{ "export", "Linux", try std.fs.path.join(a, &.{ p.path, "out/game.zip" }) }, .{
        .once = &.{export_building},
        .reject = &.{ "ERROR:", export_pack_message },
        .deadline = export_deadline_s,
    });
    try testing.expect(try zbuild.export_build.zipHoldsLibrary(io, try std.fs.path.join(a, &.{ p.path, "out/game.zip" }), "libziggurat_game.so"));
}

test "export: pack export without Zig scripts is unaffected" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, "/nonexistent/ziggurat-test/zig");
    defer p.deinit();
    try removeExportScripts(&p);
    try exportPack(&p, "out/game.pck", .{ .reject = &.{ "ERROR:", export_building, export_pack_message } });
    try testing.expect(try projectFileExists(&p, "out/game.pck"));
}

test "export: a failed export removes the old library from the output folder" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // An earlier export's library next to the game, then a broken build.
    try writeProjectFile(&p, "out/libziggurat_game.so", "an old game library");
    try writeProjectFile(&p, "broken.zig", broken_script);
    try exportGame(&p, .{ .once = &.{export_building}, .expect = &.{export_incomplete}, .exit_code = "1" });
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: an unreadable Zig file fails an export without scripts" {
    try requireTemplates();
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var p: Project = undefined;
    try initExport(&p, "/nonexistent/ziggurat-test/zig");
    defer p.deinit();
    try removeExportScripts(&p);
    // The only Zig file cannot be read, so the scan cannot tell whether it
    // is a script.
    try writeProjectFile(&p, "secret.zig", "pub const extends = @import(\"ziggurat\").godot.Node;\n");
    const a = p.arena_state.allocator();
    const secret = try std.fs.path.join(a, &.{ p.path, "secret.zig" });
    try setMode(secret, 0);
    defer setMode(secret, 0o644) catch {};
    // A user who may read anyway (root) cannot run this test.
    if (Io.Dir.cwd().openFile(io, secret, .{})) |f| {
        f.close(io);
        return error.SkipZigTest;
    } else |_| {}
    try exportGame(&p, .{
        .expect = &.{ "Ziggurat: res://secret.zig: Could not read", "the scan found the problems above", "add a `.gdignore` file", export_incomplete },
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: an unreadable Zig file fails an export with scripts" {
    try requireTemplates();
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // The fixture's two scripts stay; a third file cannot be read, so the
    // scan cannot tell whether it is a script.
    try writeProjectFile(&p, "secret.zig", "pub const extends = @import(\"ziggurat\").godot.Node;\n");
    const a = p.arena_state.allocator();
    const secret = try std.fs.path.join(a, &.{ p.path, "secret.zig" });
    try setMode(secret, 0);
    defer setMode(secret, 0o644) catch {};
    // A user who may read anyway (root) cannot run this test.
    if (Io.Dir.cwd().openFile(io, secret, .{})) |f| {
        f.close(io);
        return error.SkipZigTest;
    } else |_| {}
    try exportGame(&p, .{
        .expect = &.{ "Ziggurat: res://secret.zig: Could not read", "the scan found the problems above", export_incomplete },
        .reject = &.{export_building},
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

/// True when the project's file system finds a file under another case
/// of its name (as Windows' does).
fn caseInsensitive(p: *Project) !bool {
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "case-probe.txt", .data = "" });
    defer dir.deleteFile(io, "case-probe.txt") catch {};
    _ = dir.statFile(io, "CASE-PROBE.TXT", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "export: a case collision fails the export" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    // Ruling 4: where names that differ only by case are one file, the
    // project cannot hold both.
    if (try caseInsensitive(&p)) return error.SkipZigTest;
    const script = "pub const extends = @import(\"ziggurat\").godot.Node;\n";
    try writeProjectFile(&p, "a.zig", script);
    try writeProjectFile(&p, "A.zig", script);
    try exportGame(&p, .{
        .expect = &.{ "differ only by case", "the scan found the problems above", export_incomplete },
        .reject = &.{export_building},
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: a foreign SDK version fails the export" {
    try requireTemplates();
    var p: Project = undefined;
    try initExport(&p, null);
    defer p.deinit();
    const a = p.arena_state.allocator();
    // A copy of the build's manifest (its module roots are absolute) that
    // claims another SDK version, kept next to the project.
    const manifest = try Io.Dir.cwd().realPathFileAlloc(io, opts.sdk_manifest_path, a);
    const text = try Io.Dir.cwd().readFileAlloc(io, manifest, a, .limited(1 << 20));
    const old_field = try std.fmt.allocPrint(a, "\"sdk_version\": \"{s}\"", .{sdk_options.sdk_version});
    if (std.mem.indexOf(u8, text, old_field) == null) return error.NoSdkVersionField;
    const foreign = try std.mem.replaceOwned(u8, a, text, old_field, "\"sdk_version\": \"9.9.9\"");
    try writeProjectFile(&p, "foreign-sdk-manifest.json", foreign);
    const copy = try std.fs.path.join(a, &.{ p.path, "foreign-sdk-manifest.json" });
    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const cfg = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    const swapped = try std.mem.replaceOwned(u8, a, cfg, manifest, copy);
    if (std.mem.eql(u8, swapped, cfg)) return error.SettingNotFound;
    try dir.writeFile(io, .{ .sub_path = "project.godot", .data = swapped });

    const sentence = try std.fmt.allocPrint(a, "Ziggurat cannot export: the SDK at {s} is version 9.9.9, but this add-on's export library (addons/ziggurat/bin/x86_64-linux/libziggurat_host_export.a) needs SDK version {s}. Clear the project setting ziggurat/dev/sdk_manifest, or install the add-on that matches the SDK.", .{ copy, sdk_options.sdk_version });
    try exportGame(&p, .{
        .expect = &.{ sentence, export_incomplete },
        .reject = &.{export_building},
        .exit_code = "1",
    });
    try testing.expect(!try projectFileExists(&p, game_lib_rel));
    try testing.expect(!try projectFileExists(&p, "out/libziggurat_game.so"));
}

test "export: project without Zig scripts exports" {
    try requireTemplates();
    var p: Project = undefined;
    // No Zig at the configured path: the export must not need one.
    try initExport(&p, "/nonexistent/ziggurat-test/zig");
    defer p.deinit();
    try removeExportScripts(&p);
    // The library it ships passes the checks of an export build's library.
    const a = p.arena_state.allocator();
    const empty = try Io.Dir.cwd().readFileAlloc(io, opts.game_empty_lib, a, .limited(1 << 30));
    var why: [256]u8 = undefined;
    if (try zbuild.export_build.checkLibrary(a, .elf, empty, &why)) |sentence| {
        std.debug.print("the empty game library: {s}\n", .{sentence});
        return error.EmptyGameLibraryRefused;
    }
    try exportGame(&p, .{ .reject = &.{ "ERROR:", export_building } });
    try testing.expect(try projectFileExists(&p, "out/libziggurat_game.so"));
    try runExported(&p, .{ .once = &.{ "ziggurat: 0 scripts linked", "export check: main ready" }, .reject = &.{ "ERROR:", "WARNING:" } });
}

// ------------------------------------------------------------ install

/// A fresh project made the way a user makes one: the export fixture's
/// own files (it has no add-on) in a folder whose path holds a space, and
/// the release package (`zig build package`) unzipped into it. Nothing
/// points at this checkout: no SDK manifest setting (the add-on's shipped
/// SDK is used), a new build cache and new per-user folders inside the
/// test's folder. Only the project setting `ziggurat/zig_path` is set.
fn initInstalled(p: *Project) !void {
    p.env = null;
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
    p.path = try p.tmp.dir.realPathFileAlloc(io, folder, a);

    const old = try dst.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    try dst.writeFile(io, .{ .sub_path = "project.godot", .data = try std.fmt.allocPrint(a, "{s}\n[ziggurat]\n\nzig_path=\"{s}\"\n", .{ old, opts.zig_exe }) });
    const presets = try dst.readFileAlloc(io, "export_presets.cfg", a, .limited(64 * 1024));
    try dst.writeFile(io, .{ .sub_path = "export_presets.cfg", .data = try std.mem.replaceOwned(u8, a, presets, "@TEMPLATES@", opts.export_templates) });
    try dst.createDirPath(io, "out");
    try isolateUserFolders(p);
    try p.tmp.dir.createDirPath(io, "cache");
    try p.env.?.put("XDG_CACHE_HOME", try p.tmp.dir.realPathFileAlloc(io, "cache", a));
}

/// Copies every folder and file below `src` into `dst`.
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

test "install from the zip" {
    try requireTemplates();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var p: Project = undefined;
    try initInstalled(&p);
    defer p.deinit();
    try testing.expect(std.mem.indexOfScalar(u8, p.path, ' ') != null);
    {
        // The add-on came from the zip, with its SDK and export inputs.
        var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
        defer dir.close(io);
        for ([_][]const u8{
            "addons/ziggurat/ziggurat.gdextension",
            "addons/ziggurat/bin/libziggurat_host.so",
            "addons/ziggurat/bin/x86_64-linux/libziggurat_host_export.a",
            "addons/ziggurat/bin/x86_64-linux/libziggurat_game_empty.so",
            "addons/ziggurat/sdk/.gdignore",
            "addons/ziggurat/sdk/x86_64-linux/sdk-manifest.json",
            "addons/ziggurat/bin/ziggurat_host.dll",
            "addons/ziggurat/bin/x86_64-windows/ziggurat_host_export.lib",
            "addons/ziggurat/bin/x86_64-windows/ziggurat_game_empty.dll",
            "addons/ziggurat/sdk/x86_64-windows/sdk-manifest.json",
        }) |f| _ = try dir.statFile(io, f, .{});
        const settings = try dir.readFileAlloc(io, "project.godot", p.arena_state.allocator(), .limited(64 * 1024));
        try testing.expect(std.mem.indexOf(u8, settings, "sdk_manifest") == null);
    }
    // Play's build in a headless editor (--build-solutions calls `_build`,
    // and the editor exits with status 1 when it returns false), with the
    // shipped SDK.
    try p.addAutoloadCheck("export_editor.gd");
    try p.run(&.{ "build", "30" }, .{
        .expect = &.{ "ZTEST PASS export_editor_built", "ziggurat: build 1 " },
        .reject = &.{ play_cancelled, "is not set", "is not usable" },
        .deadline = build_deadline_s,
    });
    // The export with the real template, then the exported game.
    try exportGame(&p, .{ .once = &.{export_building}, .reject = &.{ "ERROR:", "is not set", "is not usable" } });
    try testing.expect(try projectFileExists(&p, "out/libziggurat_game.so"));
    try runExported(&p, .{ .once = &export_game_lines, .reject = &.{ "ERROR:", "WARNING:" } });
}

// ------------------------------------------------------------ shipped SDK

/// The staged SDK folder: the one holding `opts.staged_sdk_manifest`.
fn stagedDir() []const u8 {
    return std.fs.path.dirname(opts.staged_sdk_manifest) orelse ".";
}

/// Copies the staged SDK (`stagedDir`) into the project as
/// res://addons/ziggurat/sdk/x86_64-linux/, the folder of the editor's own
/// target that the host uses when the project setting
/// `ziggurat/dev/sdk_manifest` is empty, with the `.gdignore` at sdk/.
fn addStagedSdk(p: *Project) !void {
    const a = p.arena_state.allocator();
    const cwd = Io.Dir.cwd();
    var src = try cwd.openDir(io, stagedDir(), .{ .iterate = true });
    defer src.close(io);
    var proj = try cwd.openDir(io, p.path, .{});
    defer proj.close(io);
    try proj.createDirPath(io, "addons/ziggurat/sdk/x86_64-linux");
    try proj.writeFile(io, .{ .sub_path = "addons/ziggurat/sdk/.gdignore", .data = "" });
    var dst = try proj.openDir(io, "addons/ziggurat/sdk/x86_64-linux", .{});
    defer dst.close(io);
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

test "staged SDK builds a project" {
    try requireIntegration();
    var p: Project = undefined;
    try p.init("export");
    defer p.deinit();
    const a = p.arena_state.allocator();
    const cwd = Io.Dir.cwd();
    var dir = try cwd.openDir(io, p.path, .{});
    defer dir.close(io);
    try copyExportInputs(dir);
    try addStagedSdk(&p);
    // Only the Zig path is set: the SDK is the one in the add-on folder.
    const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "project.godot", .data = try std.fmt.allocPrint(a, "{s}\n[ziggurat]\n\nzig_path=\"{s}\"\n", .{ old, opts.zig_exe }) });
    try isolateUserFolders(&p);
    try p.tmp.dir.createDirPath(io, "cache");
    try p.env.?.put("XDG_CACHE_HOME", try p.tmp.dir.realPathFileAlloc(io, "cache", a));
    try p.addAutoloadCheck("staged_sdk.gd");
    try p.runEditorChecked("10000000", .{
        .expect = &.{
            "ZTEST PASS staged_sdk_built",
            "ZTEST PASS staged_sdk_addon_scanned",
            "ZTEST PASS staged_sdk_not_scanned",
            "ZTEST PASS staged_sdk_on_disk",
            "ziggurat: build 1 ",
        },
        .reject = &.{ "is not set", "is not usable", "ZTEST FAIL" },
        .deadline = build_deadline_s,
    });
    // The export plugin takes the same SDK.
    if (opts.export_templates.len == 0) {
        try requireTemplates();
        return;
    }
    const presets = try dir.readFileAlloc(io, "export_presets.cfg", a, .limited(64 * 1024));
    try dir.writeFile(io, .{ .sub_path = "export_presets.cfg", .data = try std.mem.replaceOwned(u8, a, presets, "@TEMPLATES@", opts.export_templates) });
    try dir.createDirPath(io, "out");
    try exportGame(&p, .{ .once = &.{export_building}, .reject = &.{ "ERROR:", "is not set", "is not usable" } });
    // The SDK (over 100 MB) is not in the pack: the editor never scanned it.
    const pck = try dir.statFile(io, "out/game.pck", .{});
    if (pck.size > 4 * 1024 * 1024) {
        std.debug.print("out/game.pck is {d} bytes\n", .{pck.size});
        return error.TestUnexpectedResult;
    }
    try runExported(&p, .{ .once = &export_game_lines, .reject = &.{ "ERROR:", "WARNING:" } });
}
