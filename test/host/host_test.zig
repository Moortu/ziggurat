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
const gui_opts = @import("host_gui_options");
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
            "Ziggurat has loaded 1 builds (",
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
            // The debugger's reload requests: the manifest names the build
            // the game runs, so one line says there is nothing to do.
            "ziggurat: reload: nothing to do (gen 1)",
        },
        .reject = &.{ refused_prefix, "placeholder", "swaps arrive in a later version" },
    });
}

test "game reload: swaps on reload, keeps old on bad build, reload before staging" {
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
    var names: [5][64]u8 = undefined;
    var list: std.ArrayList(u8) = .empty;
    for ([_]u32{ 1, 2, 3, 4 }) |n| {
        const name = try genLibName(&names[n], n);
        try list.print(a, "lib{d}={s}\n", .{ n, name });
    }
    try dir.writeFile(io, .{ .sub_path = "modules.txt", .data = list.items });
    try dir.createDirPath(io, ".godot/ziggurat/gen/1");
    try dir.createDirPath(io, ".godot/ziggurat/gen/2");
    try dir.createDirPath(io, ".godot/ziggurat/gen/4");
    try cwd.copyFile(v1, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/1/{s}", .{try genLibName(&names[1], 1)}), io, .{});
    try cwd.copyFile(v2, dir, try std.fmt.allocPrint(a, ".godot/ziggurat/gen/2/{s}", .{try genLibName(&names[2], 2)}), io, .{});
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
            "ZTEST DONE",
        },
        .once = &.{
            "ziggurat: reload: the build may not be staged yet; keeping gen 1",
            "ziggurat: reload: nothing to do (gen 1)",
            "Ziggurat refused generation 4: ",
            "ziggurat: generation 2 loaded",
            "ziggurat: swapped to build 2",
            "ziggurat: reload: nothing to do (gen 2)",
        },
        .reject = &.{ "ZTEST FAIL", "swaps arrive in a later version" },
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
    "ZTEST PASS gui_game_still_old_code",
    "ZTEST PASS gui_game_runs_new_code",
    "ZTEST PASS gui_game_swapped_line",
};

// Run by `zig build test-gui` only (spec section 12, check 6): the GUI
// editor under Xvfb plays the e2e project's main scene, a tool autoload
// edits res://hero.zig in the script editor and saves it with
// ScriptEditor.save_all_scripts(); a second save sends the game another
// reload, and the running game swaps to the new build and returns the new
// value of a changed method with its field values kept. The manual desktop run of the same
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
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://addon/ziggurat_host.gdextension\n" });

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
    for ([_][]const u8{ "ZTEST FAIL", "Program crashed", "emit of signal" }) |text| {
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

test "export build has no manifest path" {
    try requireIntegration();
    const a = testing.allocator;
    // The reader's names and the manifest's file name. Any text the
    // library holds counts, the way `strings` finds it: symbol names,
    // string literals and debug information alike.
    const needles = [_][]const u8{ "manifest", "readTrusted", "recheck", "loadFromStore" };
    const export_lib = try Io.Dir.cwd().readFileAlloc(io, opts.export_host_lib, a, .limited(1 << 30));
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

    // A game with the export host ignores a good manifest.
    var p: Project = undefined;
    try p.initWith("empty", opts.export_host_lib);
    defer p.deinit();
    const pa = p.arena_state.allocator();
    const store_path = try stageGameProject(&p);
    var store = try Io.Dir.cwd().openDir(io, store_path, .{});
    defer store.close(io);
    var name_buf: [64]u8 = undefined;
    try writeGameManifest(&store, try std.fmt.allocPrint(pa, "gen=1\npath=gen/1/{s}\n", .{try genLibName(&name_buf, 1)}));
    try p.run(&.{ "script", "res://check.gd" }, .{
        .once = &.{
            "This export build of Ziggurat has no module source yet, so this game runs without Zig scripts.",
            "game check: scripts absent",
        },
        .reject = &.{ "mover ready", "generation 1 loaded" },
    });
}
