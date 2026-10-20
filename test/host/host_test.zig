//! Host integration tests. Each test copies a fixture project from
//! test/host/projects into a temporary folder, puts the host library and its
//! `.gdextension` into the project's `addon/` folder, adds a check script
//! from test/host/checks as `res://check.gd`, and runs Godot through
//! test/host/runner.zig, which decides pass or fail. Tests that need a user
//! module build one from test/fixtures with the build service and the SDK
//! manifest before Godot starts (ruling R1).
const std = @import("std");
const builtin = @import("builtin");
const opts = @import("host_test_options");
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
        p.env = null;
        p.arena_state = .init(testing.allocator);
        errdefer p.arena_state.deinit();
        const a = p.arena_state.allocator();
        p.tmp = testing.tmpDir(.{});
        errdefer p.tmp.cleanup();
        const cwd = Io.Dir.cwd();

        var projects = try cwd.openDir(io, opts.projects_dir, .{});
        defer projects.close(io);
        var src = try projects.openDir(io, fixture, .{ .iterate = true });
        defer src.close(io);
        try p.tmp.dir.createDirPath(io, "project");
        var dst = try p.tmp.dir.openDir(io, "project", .{});
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

        try dst.createDirPath(io, "addon");
        try cwd.copyFile(host_lib, dst, "addon/libziggurat_host.so", io, .{});
        try cwd.copyFile(opts.gdextension, dst, "addon/ziggurat_host.gdextension", io, .{});
        p.path = try p.tmp.dir.realPathFileAlloc(io, "project", a);
    }

    fn deinit(p: *Project) void {
        if (p.env) |e| e.deinit();
        p.tmp.cleanup();
        p.arena_state.deinit();
    }

    /// Copies test/host/checks/<name> into the project as `res://check.gd`.
    fn addCheck(p: *Project, name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        var checks = try cwd.openDir(io, opts.checks_dir, .{});
        defer checks.close(io);
        var dst = try cwd.openDir(io, p.path, .{});
        defer dst.close(io);
        try checks.copyFile(name, dst, "check.gd", io, .{});
    }

    /// Adds test/host/checks/<name> as `res://check.gd` and makes it an
    /// autoload, so a `@tool` check runs inside the editor.
    fn addAutoloadCheck(p: *Project, name: []const u8) !void {
        try p.addCheck(name);
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
        /// Seconds for the whole Godot run.
        deadline: []const u8 = deadline_s,
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
        const result = try std.process.run(a, io, .{ .argv = argv.items, .environ_map = p.env });
        if (result.term.success()) return;
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

    var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
    defer dir.close(io);
    const list = try std.fmt.allocPrint(a, "good={s}\nother_sdk={s}\ntruncated={s}\n", .{ good, other_sdk, truncated });
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = list });

    try p.addCheck("runtime_load.gd");
    try p.runScript(&.{
        "ZTEST PASS load_good_module",
        "ZTEST PASS load_refuses_bad_module",
        "ZTEST PASS name_maps_use_interned_names",
        // HostApi.log and request_swap (runtime_load.gd, host_api).
        "[ziggurat] info from main\n",
        "[ziggurat] warning from main",
        "[ziggurat] error from main",
        "[ziggurat] info from thread 49\n",
        "[ziggurat] swap requested (swaps arrive in a later version)",
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
        "ZTEST PASS rejects_version_2",
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
        "version_2.json: the file has version 2, but this host reads version 1.",
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
            "ZTEST PASS load_check_node_field",
            "ZTEST PASS load_check_clean",
            "ZTEST PASS load_check_generation_not_used",
            "ZTEST PASS load_check_marks_build_failed",
            "ERROR: named.zig: Property 'name' of res://named.zig hides Node.name; rename it or give it a name override in meta.",
            "ERROR: holder.zig: res://holder.zig extends Resource, which is not a Node, so field 'target' cannot hold a Node.",
            "ziggurat: build 1 failed the load checks (open, ",
        },
        .reject = &.{"ziggurat: build 1 loaded"},
        .deadline = build_deadline_s,
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
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://addon/ziggurat_host.gdextension\n" });
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
