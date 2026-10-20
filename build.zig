const std = @import("std");
const gdzig_build = @import("gdzig");

const cross_targets = [_][]const u8{ "x86_64-windows-gnu", "aarch64-macos" };

/// The SDK version written into `sdk_options` and the SDK manifest.
const sdk_version = "0.1.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zig_exe = b.option(
        []const u8,
        "zig_exe",
        "Zig compiler used by integration tests [default: the one running this build]",
    ) orelse b.graph.zig_exe;
    // Always passed to gdzig, so configuring never fails for want of Godot;
    // only steps that run Godot need a real one. gdzig's test coordinator
    // hashes the executable, so the default is the absolute path of `godot`
    // on PATH (a PATH search makes configuration uncacheable; pass
    // -Dgodot-path to avoid it).
    const godot_opt = b.option([]const u8, "godot-path", "Godot executable for steps that run Godot [default: godot on PATH]");
    const godot_found = godot_opt orelse b.findProgram(.{ .names = &.{"godot"} });
    const godot_path = godot_found orelse "godot";
    const manifest_out = b.option([]const u8, "manifest-out", "Absolute path the sdk-manifest step writes the SDK module manifest to");

    const test_step = b.step("test", "Run unit and integration tests");
    const unit_step = b.step("test-unit", "Run unit tests only (spawns no compiler)");
    const cross_step = b.step("cross", "Compile test binaries for Windows and macOS (not run)");
    const manifest_step = b.step("sdk-manifest", "Write the SDK module manifest to -Dmanifest-out=<absolute path>");
    const godot_step = b.step("test-godot", "Run the SDK tests inside a headless Godot (needs Godot)");
    const host_step = b.step("host", "Install the host library and its .gdextension into <prefix>/addon (zig build host -p <project>)");
    const host_test_step = b.step("test-host", "Run the host tests in a headless Godot (needs Godot)");

    const sdk = addSdk(b, target, optimize, godot_path);
    const manifest_tool = b.addExecutable(.{
        .name = "sdk_manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sdk_manifest.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // The manifest for `sdk-manifest`: written to the path the user gave.
    if (manifest_out) |out| {
        if (std.fs.path.isAbsolute(out)) {
            const run = b.addRunArtifact(manifest_tool);
            run.addArg(out);
            run.has_side_effects = true;
            addManifestModules(b, run, sdk);
            manifest_step.dependOn(&run.step);
        } else {
            manifest_step.dependOn(&b.addFail("-Dmanifest-out must be an absolute path").step);
        }
    } else {
        manifest_step.dependOn(&b.addFail("sdk-manifest needs -Dmanifest-out=<absolute path>").step);
    }

    // The manifest for `test`: written into the cache.
    const test_manifest = blk: {
        const run = b.addRunArtifact(manifest_tool);
        const out = run.addOutputFileArg("sdk-manifest.json");
        addManifestModules(b, run, sdk);
        break :blk out;
    };

    if (godot_found == null) {
        godot_step.dependOn(&b.addFail("test-godot needs Godot on PATH or -Dgodot-path=<absolute path>").step);
    } else {
        addGodotTests(b, godot_step, target, optimize, sdk, godot_found.?);
    }
    test_step.dependOn(godot_step);

    // The host library and its addon folder. The host computes the layout
    // stamp it accepts from the SDK's own `sdk_options`.
    const sdk_options = sdk.import_table.get("sdk_options").?;
    const host = addHost(b, target, optimize, godot_path, zig_exe, sdk_options, false);
    const gdextension_file = b.path("addon/ziggurat_host.gdextension");
    // `zig build host -p <project>` makes <project>/addon/ a working addon folder.
    const addon_dir: std.Build.InstallDir = .{ .custom = "addon" };
    host_step.dependOn(&b.addInstallFileWithDir(host.getEmittedBin(), addon_dir, "libziggurat_host.so").step);
    host_step.dependOn(&b.addInstallFileWithDir(gdextension_file, addon_dir, "ziggurat_host.gdextension").step);
    if (godot_found == null) {
        host_test_step.dependOn(&b.addFail("test-host needs Godot on PATH or -Dgodot-path=<absolute path>").step);
    } else {
        const probe_host = addHost(b, target, optimize, godot_path, zig_exe, sdk_options, true);
        addHostTests(b, host_test_step, target, optimize, .{
            .host = host,
            .probe_host = probe_host,
            .gdextension = gdextension_file,
            .godot_exe = godot_found.?,
            .zig_exe = zig_exe,
            .sdk_manifest = test_manifest,
            .sdk_options = sdk_options,
        });
    }
    test_step.dependOn(host_test_step);

    // Native: integration on for `test`, off for `test-unit`.
    addTestSet(b, test_step, target, optimize, zig_exe, true, true, test_manifest, .{ .debug = sdk, .safe = addSdk(b, target, .ReleaseSafe, godot_path) }, sdk_options, sdk);
    addTestSet(b, unit_step, target, optimize, zig_exe, false, true, null, null, sdk_options, sdk);

    // Cross: compile only.
    for (cross_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("bad cross target triple");
        const resolved = b.resolveTargetQuery(query);
        addTestSet(b, cross_step, resolved, optimize, zig_exe, false, false, null, null, sdk_options, sdk);
    }
}

/// The SDK module `ziggurat` and everything it imports.
fn addSdk(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    godot_path: []const u8,
) *std.Build.Module {
    const gdzig = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
        // gdzig's name for single precision; `sdk_options.precision` says "single".
        .precision = "float",
    });

    const options_tool = b.addExecutable(.{
        .name = "sdk_options",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sdk_options.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const options_run = b.addRunArtifact(options_tool);
    const options_file = options_run.addOutputFileArg("sdk_options.zig");
    options_run.addArgs(&.{ sdk_version, "single" });
    options_run.addFileArg(gdzig.path("vendor/extension_api.json"));
    options_run.addFileArg(gdzig.path("vendor/gdextension_interface.h"));

    const sdk_options = b.createModule(.{
        .root_source_file = options_file,
        .target = target,
        .optimize = optimize,
    });

    // `ziggurat.godot`: sdk/godot.zig plus one declaration per engine class,
    // matched against gdzig's generated class.zig (next to its root file).
    const gdzig_mod = gdzig.module("gdzig");
    const surface_tool = b.addExecutable(.{
        .name = "godot_surface",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/godot_surface.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const surface_run = b.addRunArtifact(surface_tool);
    const surface_file = surface_run.addOutputFileArg("ziggurat_godot.zig");
    surface_run.addFileArg(b.path("sdk/godot.zig"));
    surface_run.addFileArg(gdzig.path("vendor/extension_api.json"));
    const gdzig_root = gdzig_mod.root_source_file orelse @panic("the gdzig module has no root source file");
    surface_run.addFileArg(gdzig_root.dirname().path(b, "class.zig"));
    const surface = b.createModule(.{
        .root_source_file = surface_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gdzig", .module = gdzig_mod }},
    });

    return b.createModule(.{
        .root_source_file = b.path("sdk/ziggurat.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gdzig", .module = gdzig_mod },
            .{ .name = "ziggurat_godot", .module = surface },
            .{ .name = "sdk_options", .module = sdk_options },
            .{ .name = "ziggurat_abi", .module = addAbi(b, target, optimize) },
        },
    });
}

/// The host library `ziggurat_host` (spec section 3). It imports gdzig, the
/// ABI module, the platform layer and the SDK's `sdk_options` (for the
/// layout stamp), never the SDK. `test_probe` registers the
/// `ZigguratTestProbe` class the host tests drive the runtime with; the
/// installed library never has it.
fn addHost(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    godot_path: []const u8,
    zig_exe: []const u8,
    sdk_options: *std.Build.Module,
    test_probe: bool,
) *std.Build.Step.Compile {
    const gdzig = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
        .precision = "float",
    });
    const host_options = b.addOptions();
    host_options.addOption(bool, "test_probe", test_probe);
    // The platform layer's test settings: integration off, no test paths.
    const platform_options = b.addOptions();
    platform_options.addOption([]const u8, "zig_exe", zig_exe);
    platform_options.addOption(bool, "run_integration", false);
    platform_options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    platform_options.addOption([]const u8, "sdk_manifest_path", "");
    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_options", .module = platform_options.createModule() }},
    });
    return b.addLibrary(.{
        .linkage = .dynamic,
        .name = if (test_probe) "ziggurat_host_probe" else "ziggurat_host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/entry.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "gdzig", .module = gdzig.module("gdzig") },
                .{ .name = "ziggurat_abi", .module = addAbi(b, target, optimize) },
                .{ .name = "ziggurat_platform", .module = platform },
                .{ .name = "sdk_options", .module = sdk_options },
                .{ .name = "host_options", .module = host_options.createModule() },
                // Godot's snake_case rule, shared with the SDK (imports only std).
                .{ .name = "snake", .module = b.createModule(.{
                    .root_source_file = b.path("sdk/snake.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
}

const HostTestInputs = struct {
    host: *std.Build.Step.Compile,
    /// The host built with `test_probe`.
    probe_host: *std.Build.Step.Compile,
    gdextension: std.Build.LazyPath,
    godot_exe: []const u8,
    zig_exe: []const u8,
    /// The SDK manifest the tests build fixture modules with.
    sdk_manifest: std.Build.LazyPath,
    sdk_options: *std.Build.Module,
};

/// The host tests (test/host): a Zig test that copies a fixture project,
/// puts the host into its `addon/` folder, builds fixture modules with the
/// build service when a test needs them, and runs Godot through
/// test/host/runner.zig.
fn addHostTests(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    in: HostTestInputs,
) void {
    const runner = b.addExecutable(.{
        .name = "host_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/host/runner.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "godot_output_scan", .module = b.createModule(.{
                .root_source_file = b.path("test/godot/output_scan.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }) }},
        }),
    });
    // The runner's own unit tests, and the host's (no Godot needed).
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = runner.root_module })).step);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = in.host.root_module })).step);

    // One options module serves as `host_test_options` and as the
    // `build_options` of the platform and build modules the test uses.
    const options = b.addOptions();
    options.addOption(bool, "run_integration", true);
    options.addOption([]const u8, "godot_exe", in.godot_exe);
    options.addOptionPath("runner_exe", runner.getEmittedBin());
    options.addOptionPath("host_lib", in.host.getEmittedBin());
    options.addOptionPath("probe_host_lib", in.probe_host.getEmittedBin());
    options.addOptionPath("gdextension", in.gdextension);
    options.addOption([]const u8, "projects_dir", b.root.joinString(b.allocator, "test/host/projects") catch @panic("OOM"));
    options.addOption([]const u8, "checks_dir", b.root.joinString(b.allocator, "test/host/checks") catch @panic("OOM"));
    options.addOption([]const u8, "fixtures_dir", b.root.joinString(b.allocator, "test/fixtures") catch @panic("OOM"));
    options.addOption([]const u8, "zig_exe", in.zig_exe);
    options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    options.addOptionPath("sdk_manifest_path", in.sdk_manifest);
    const options_mod = options.createModule();

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_options", .module = options_mod }},
    });
    const abi = addAbi(b, target, optimize);
    const build_mod = b.createModule(.{
        .root_source_file = b.path("src/build/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
            .{ .name = "ziggurat_platform", .module = platform },
            .{ .name = "ziggurat_abi", .module = abi },
        },
    });
    const t = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/host/host_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "host_test_options", .module = options_mod },
            .{ .name = "ziggurat_platform", .module = platform },
            .{ .name = "ziggurat_build", .module = build_mod },
            .{ .name = "ziggurat_abi", .module = abi },
            .{ .name = "sdk_options", .module = in.sdk_options },
        },
    }) });
    const run = b.addRunArtifact(t);
    // The fixtures and check scripts are read at run time, and the SDK is
    // compiled from source by a child compiler; Godot is an input too.
    addSourceInputs(b, run, &.{ "test/host", "test/fixtures", "sdk", "src/abi" });
    run.addFileInput(.{ .cwd_relative = in.godot_exe });
    step.dependOn(&run.step);
}

/// A fixture script as a module that imports the SDK.
fn fixtureModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: *std.Build.Module,
    path: []const u8,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ziggurat", .module = sdk }},
    });
}

/// SDK tests that run inside Godot through gdzig's test harness.
///
/// The harness replaces the test module's `gdzig` import with the gdzig
/// module of the first gdzig dependency this build created, and sets that
/// module's `raw` table. The SDK must import the very same module, or it
/// would see a second, unset `raw`; `sdk` is built from that dependency, and
/// this function checks it.
fn addGodotTests(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: *std.Build.Module,
    godot_exe: []const u8,
) void {
    if (harnessGdzig(b) != sdk.import_table.get("gdzig").?)
        @panic("the SDK under test does not import the gdzig module the test harness uses");
    // The descriptor tests read the fixture scripts, which import the SDK.
    const fixture_player = fixtureModule(b, target, optimize, sdk, "test/fixtures/sdk_project/player.zig");
    const fixture_coin = fixtureModule(b, target, optimize, sdk, "test/fixtures/sdk_project/items/coin.zig");
    const fixture_hud_label = fixtureModule(b, target, optimize, sdk, "test/fixtures/sdk_project/ui/hud_label.zig");
    const mod = b.createModule(.{
        .root_source_file = b.path("test/godot/convert.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ziggurat", .module = sdk },
            .{ .name = "ziggurat_abi", .module = sdk.import_table.get("ziggurat_abi").? },
            .{ .name = "fixture_player", .module = fixture_player },
            .{ .name = "fixture_coin", .module = fixture_coin },
            .{ .name = "fixture_hud_label", .module = fixture_hud_label },
        },
    });
    const name = "sdk_godot";
    const run = gdzig_build.addTest(b, .{ .name = name, .root_module = mod, .target = target, .optimize = optimize });
    // The coordinator loads the library from the install directory, which
    // gdzig does not make an input of this step, so an edited test would not
    // rerun. Make the library itself (and Godot) inputs.
    const lib = harnessLibrary(&run.step) orelse @panic("gdzig.addTest: no test library found under its run step");
    const godot_file: std.Build.LazyPath = .{ .cwd_relative = godot_exe };
    run.addFileInput(lib.getEmittedBin());
    run.addFileInput(godot_file);
    step.dependOn(&run.step);

    // The harness ends Godot with SIGKILL, so Godot's exit-time leak reports
    // never appear. Run every test once more through the library's
    // clean-exit entry in a Godot that quits normally, and scan its output.
    const runner = b.addExecutable(.{
        .name = "clean_exit_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/godot/clean_exit_runner.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const scan = b.addRunArtifact(runner);
    scan.addArg(godot_exe);
    // Where gdzig's harness installs the project and library.
    scan.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "test/" ++ name } }, .{ .make_absolute = true });
    _ = scan.addOutputDirectoryArg("project");
    // The runner copies the library and the project files from the install
    // directory; these inputs make it rerun exactly when one of them or
    // Godot changes.
    scan.addFileInput(lib.getEmittedBin());
    scan.addFileInput(godot_file);
    const project_dir = harnessProjectDir(&run.step) orelse @panic("gdzig.addTest: no project directory found under its run step");
    for ([_][]const u8{ "project.godot", "main.tscn", "test_extension.gdextension" }) |file| {
        scan.addFileInput(project_dir.path(b, file));
    }
    // After the harness run: it installs the project, and one Godot at a time.
    scan.step.dependOn(&run.step);
    step.dependOn(&scan.step);
}

/// The test library `gdzig.addTest` built: the artifact of the first
/// `InstallArtifact` step found under the harness run step (run ->
/// install project -> install library in gdzig's current layout).
fn harnessLibrary(step: *std.Build.Step) ?*std.Build.Step.Compile {
    for (step.dependencies.items) |dep| {
        if (dep.cast(std.Build.Step.InstallArtifact)) |ia| return ia.artifact;
        if (harnessLibrary(dep)) |found| return found;
    }
    return null;
}

/// The generated project folder `gdzig.addTest` installs next to the
/// library: the source of the first `InstallDir` step found under the
/// harness run step.
fn harnessProjectDir(step: *std.Build.Step) ?std.Build.LazyPath {
    for (step.dependencies.items) |dep| {
        if (dep.cast(std.Build.Step.InstallDir)) |id| return id.options.source_dir;
        if (harnessProjectDir(dep)) |found| return found;
    }
    return null;
}

/// The gdzig module `gdzig.addTest` links: that of the first gdzig
/// dependency in the build graph's dependency cache, which keeps insertion
/// order. No other package defines a module named `gdzig`.
fn harnessGdzig(b: *std.Build) *std.Build.Module {
    for (b.graph.dependency_cache.values()) |dep| {
        if (dep.builder.modules.get("gdzig")) |m| return m;
    }
    @panic("no gdzig dependency");
}

/// The ABI module `ziggurat_abi`: imports only std and builtin, and is
/// shared by the SDK and the future host.
fn addAbi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/abi/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// Makes every file under `dirs` (relative to the build root) an input of
/// `run`, so editing any of them reruns it. Found at configure time.
fn addSourceInputs(b: *std.Build, run: *std.Build.Step.Run, dirs: []const []const u8) void {
    const io = b.graph.io;
    for (dirs) |sub| {
        var dir = b.root.root_dir.handle.openDir(io, sub, .{ .iterate = true }) catch |err|
            std.debug.panic("cannot open {s}: {t}", .{ sub, err });
        defer dir.close(io);
        // A new or removed file must repeat configuration, which is cached.
        b.dependOnDirectoryContents(b.path(sub));
        var walker = dir.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(io) catch |err| std.debug.panic("cannot walk {s}: {t}", .{ sub, err })) |entry| {
            if (entry.kind == .directory) {
                b.dependOnDirectoryContents(b.path(b.fmt("{s}/{s}", .{ sub, entry.path })));
                continue;
            }
            if (entry.kind != .file) continue;
            run.addFileInput(b.path(b.fmt("{s}/{s}", .{ sub, entry.path })));
        }
    }
}

/// Adds `<sdk_version>` and one `<name> <root> <deps>` triple per module
/// reachable from `sdk` (named `ziggurat`), in breadth-first order. The
/// compiler command line has one flat module namespace, so two different
/// modules with the same import name are a configuration error.
fn addManifestModules(b: *std.Build, run: *std.Build.Step.Run, sdk: *std.Build.Module) void {
    run.addArg(sdk_version);
    var seen: std.StringArrayHashMapUnmanaged(*std.Build.Module) = .empty;
    seen.put(b.allocator, "ziggurat", sdk) catch @panic("OOM");
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const mod = seen.values()[i];
        for (mod.import_table.keys(), mod.import_table.values()) |name, dep| {
            const gop = seen.getOrPut(b.allocator, name) catch @panic("OOM");
            if (gop.found_existing) {
                if (gop.value_ptr.* != dep) std.debug.panic("two different SDK modules are imported as \"{s}\"", .{name});
            } else {
                gop.value_ptr.* = dep;
            }
        }
    }
    for (seen.keys(), seen.values()) |name, mod| {
        run.addArg(name);
        const root = mod.root_source_file orelse std.debug.panic("SDK module \"{s}\" has no root source file", .{name});
        run.addFileArg2(root, .{ .make_absolute = true });
        run.addArg(std.mem.join(b.allocator, ",", mod.import_table.keys()) catch @panic("OOM"));
    }
}

const ProbeSdks = struct { debug: *std.Build.Module, safe: *std.Build.Module };

fn addTestSet(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zig_exe: []const u8,
    run_integration: bool,
    run: bool,
    /// The SDK manifest for integration tests; null where none run.
    sdk_manifest: ?std.Build.LazyPath,
    /// The SDK built in Debug and in ReleaseSafe, for the panic probes; null where none runs.
    probe_sdks: ?ProbeSdks,
    /// The SDK's `sdk_options`, from which the SDK e2e tests compute the
    /// layout stamp a host expects (native sets only).
    sdk_options: *std.Build.Module,
    /// The SDK the fixture scripts are compiled against in the SDK e2e tests
    /// (they read `@sizeOf` of the fixture types).
    fixture_sdk: *std.Build.Module,
) void {
    const options = b.addOptions();
    options.addOption([]const u8, "zig_exe", zig_exe);
    options.addOption(bool, "run_integration", run_integration);
    options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    if (sdk_manifest) |m| {
        options.addOptionPath("sdk_manifest_path", m);
    } else {
        options.addOption([]const u8, "sdk_manifest_path", "");
    }

    const abi_for_probe = addAbi(b, target, optimize);
    const probe_platform = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Own options: the real ones hold the probe paths, which depend on the loader.
    const probe_options = b.addOptions();
    probe_options.addOption([]const u8, "zig_exe", zig_exe);
    probe_options.addOption(bool, "run_integration", false);
    probe_options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    probe_options.addOption([]const u8, "sdk_manifest_path", "");
    probe_platform.addImport("build_options", probe_options.createModule());
    if (probe_sdks) |sdks| {
        // Panic probes: an executable, and a dynamic library with a loader that
        // dlopens it, each in Debug and ReleaseSafe.
        for ([_]struct { mode: std.builtin.OptimizeMode, sdk: *std.Build.Module, tag: []const u8 }{
            .{ .mode = .Debug, .sdk = sdks.debug, .tag = "debug" },
            .{ .mode = .ReleaseSafe, .sdk = sdks.safe, .tag = "safe" },
        }) |cfg| {
            const exe = b.addExecutable(.{
                .name = b.fmt("panic_probe_{s}", .{cfg.tag}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/panic_probe.zig"),
                    .target = target,
                    .optimize = cfg.mode,
                    .link_libc = true,
                    .imports = &.{.{ .name = "ziggurat", .module = cfg.sdk }},
                }),
            });
            options.addOptionPath(b.fmt("panic_exe_{s}", .{cfg.tag}), exe.getEmittedBin());
            const lib = b.addLibrary(.{
                .name = b.fmt("panic_probe_lib_{s}", .{cfg.tag}),
                .linkage = .dynamic,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("test/panic_probe_lib.zig"),
                    .target = target,
                    .optimize = cfg.mode,
                    .link_libc = true,
                    .imports = &.{.{ .name = "ziggurat", .module = cfg.sdk }},
                }),
            });
            options.addOptionPath(b.fmt("panic_lib_{s}", .{cfg.tag}), lib.getEmittedBin());
        }
        const loader = b.addExecutable(.{
            .name = "panic_probe_loader",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/panic_probe_loader.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "ziggurat_platform", .module = probe_platform },
                    .{ .name = "ziggurat_abi", .module = abi_for_probe },
                },
            }),
        });
        options.addOptionPath("panic_loader", loader.getEmittedBin());
    } else {
        for ([_][]const u8{ "panic_exe_debug", "panic_exe_safe", "panic_lib_debug", "panic_lib_safe", "panic_loader" }) |n| {
            options.addOption([]const u8, n, "");
        }
    }

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options_mod = options.createModule();
    platform.addImport("build_options", options_mod);

    // The SDK e2e tests compile the SDK (through the fixtures) and the build
    // service together, so both must use one `ziggurat_abi` module.
    const abi = if (run) fixture_sdk.import_table.get("ziggurat_abi").? else addAbi(b, target, optimize);

    const build_mod = b.createModule(.{
        .root_source_file = b.path("src/build/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    build_mod.addImport("build_options", options_mod);
    build_mod.addImport("ziggurat_platform", platform);
    build_mod.addImport("ziggurat_abi", abi);

    // The SDK's name conversion imports only std, so it tests without gdzig.
    const snake = b.createModule(.{
        .root_source_file = b.path("sdk/snake.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Likewise the SDK's message formatter.
    const fmtlog = b.createModule(.{
        .root_source_file = b.path("sdk/fmtlog.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The host's engine check and the Godot output rules import only std.
    const host_version = b.createModule(.{
        .root_source_file = b.path("src/host/version.zig"),
        .target = target,
        .optimize = optimize,
    });
    const output_scan = b.createModule(.{
        .root_source_file = b.path("test/godot/output_scan.zig"),
        .target = target,
        .optimize = optimize,
    });

    for ([_]*std.Build.Module{ platform, build_mod, abi, snake, fmtlog, host_version, output_scan }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        if (run) {
            step.dependOn(&b.addRunArtifact(t).step);
        } else {
            step.dependOn(&t.step);
        }
    }

    // End-to-end tests (native only; all integration-gated, so `test-unit` skips them).
    if (run) {
        const e2e = b.createModule(.{
            .root_source_file = b.path("test/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        e2e.addImport("build_options", options_mod);
        e2e.addImport("ziggurat_platform", platform);
        e2e.addImport("ziggurat_build", build_mod);
        const t = b.addTest(.{ .root_module = e2e });
        step.dependOn(&b.addRunArtifact(t).step);

        const sdk_e2e = b.createModule(.{
            .root_source_file = b.path("test/sdk_e2e.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        sdk_e2e.addImport("build_options", options_mod);
        sdk_e2e.addImport("ziggurat_platform", platform);
        sdk_e2e.addImport("ziggurat_build", build_mod);
        sdk_e2e.addImport("ziggurat_abi", abi);
        sdk_e2e.addImport("sdk_options", sdk_options);
        sdk_e2e.addImport("fixture_player", fixtureModule(b, target, optimize, fixture_sdk, "test/fixtures/sdk_project/player.zig"));
        sdk_e2e.addImport("fixture_coin", fixtureModule(b, target, optimize, fixture_sdk, "test/fixtures/sdk_project/items/coin.zig"));
        sdk_e2e.addImport("fixture_hud_label", fixtureModule(b, target, optimize, fixture_sdk, "test/fixtures/sdk_project/ui/hud_label.zig"));
        const sdk_run = b.addRunArtifact(b.addTest(.{ .root_module = sdk_e2e }));
        // The test builds the SDK from source with a child compiler, which the
        // build system cannot see; track the sources so an edit reruns it.
        addSourceInputs(b, sdk_run, &.{ "sdk", "src/abi" });
        step.dependOn(&sdk_run.step);
    }
}
