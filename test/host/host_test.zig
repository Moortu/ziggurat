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

    fn init(p: *Project, fixture: []const u8) !void {
        return p.initWith(fixture, opts.host_lib);
    }

    /// As `init`, with the host built with `test_probe` (`ZigguratTestProbe`).
    fn initProbe(p: *Project, fixture: []const u8) !void {
        return p.initWith(fixture, opts.probe_host_lib);
    }

    fn initWith(p: *Project, fixture: []const u8, host_lib: []const u8) !void {
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
        return p.run(&.{ "script", "res://check.gd" }, expect, &.{});
    }

    /// As `runScript`; each `once` text must appear exactly once.
    fn runScriptOnce(p: *Project, expect: []const []const u8, once: []const []const u8) !void {
        return p.run(&.{ "script", "res://check.gd" }, expect, once);
    }

    /// Opens the project in the headless editor for `frames` frames.
    fn runEditor(p: *Project, frames: []const u8, expect: []const []const u8) !void {
        return p.run(&.{ "editor", frames }, expect, &.{});
    }

    fn run(p: *Project, mode: []const []const u8, expect: []const []const u8, once: []const []const u8) !void {
        const a = p.arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ opts.runner_exe, opts.godot_exe, p.path });
        try argv.appendSlice(a, mode);
        try argv.append(a, deadline_s);
        for (expect) |text| try argv.appendSlice(a, &.{ "--expect", text });
        for (once) |text| try argv.appendSlice(a, &.{ "--expect-once", text });
        const result = try std.process.run(a, io, .{ .argv = argv.items });
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
    const cwd = Io.Dir.cwd();
    const root = try std.fs.path.join(a, &.{ work, name });
    const src_path = try std.fs.path.join(a, &.{ root, "src" });
    const cache = try std.fs.path.join(a, &.{ work, "cache" });
    const store = try std.fs.path.join(a, &.{ root, "store" });
    try cwd.createDirPath(io, src_path);
    try cwd.createDirPath(io, cache);

    var fixtures = try cwd.openDir(io, opts.fixtures_dir, .{});
    defer fixtures.close(io);
    var src = try fixtures.openDir(io, fixture, .{ .iterate = true });
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
        std.debug.print("build of {s} failed: {?s}\n", .{ name, o.message });
        for (o.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        return error.BuildFailed;
    }
    const gen = o.generation orelse return error.NoGeneration;
    return a.dupe(u8, gen.lib.bytes);
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
    }, &.{
        // Two refused instances of the same script, one line; two reloads, one line.
        "Script res://player.zig cannot create instances yet.",
        "Script res://player.zig reloads when a new build is loaded",
    });
    try p.runScript(&.{
        "ZTEST PASS second_run_has_no_module",
        "ZTEST PASS script_reports_descriptors_from_cache\n",
        "ZTEST PASS script_reports_descriptors_from_cache_queries",
        "ZTEST PASS update_exports_is_idempotent",
        "ZTEST PASS has_default_same_from_cache_and_module",
        "ZTEST PASS cache_ignored_after_load",
        "ZTEST PASS script_reports_loaded_after_cache",
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
        "ZTEST PASS editor_placeholder_refused",
        "ZTEST PASS editor_load_module",
        "ZTEST PASS editor_rule_after_load",
    });
}
