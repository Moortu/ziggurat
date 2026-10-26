const std = @import("std");
const gdzig_build = @import("gdzig");
const pins = @import("src/platform/pins.zig");
const empty_root = @import("src/build/empty_root.zig");

const cross_targets = [_][]const u8{ "x86_64-windows-gnu", "aarch64-macos", "aarch64-linux-gnu" };

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
    const sdk_out = b.option([]const u8, "sdk-out", "Absolute path of the empty or missing folder the sdk-stage step writes the shipped SDK into");
    const host_test_filter = b.option([]const u8, "host-test-filter", "Run only the host tests whose name contains this text");
    const export_templates = b.option([]const u8, "export-templates", "Folder with Godot 4.7.2's export templates (linux_release.x86_64); the host export tests skip without it");

    const test_step = b.step("test", "Run unit and integration tests");
    const unit_step = b.step("test-unit", "Run unit tests only (spawns no compiler)");
    const cross_step = b.step("cross", "Compile test binaries for Windows, macOS and Linux arm64 (not run)");
    const manifest_step = b.step("sdk-manifest", "Write the SDK module manifest to -Dmanifest-out=<absolute path>");
    const stage_step = b.step("sdk-stage", "Write the shipped SDK (sources and a manifest with relative roots) into -Dsdk-out=<absolute path>");
    const godot_step = b.step("test-godot", "Run the SDK tests inside a headless Godot (needs Godot)");
    const host_step = b.step("host", "Install the host library and its .gdextension into <prefix>/addons/ziggurat (zig build host -p <project>)");
    const archive_step = b.step("host-archive", "Install the export host archive <prefix>/lib/libziggurat_host_export.a (ReleaseSafe, " ++ pins.export_target ++ ")");
    const host_test_step = b.step("test-host", "Run the host tests in a headless Godot (needs Godot)");
    const gui_test_step = b.step("test-gui", "Run the GUI editor test under Xvfb (needs Godot and xvfb-run); not part of test");
    const stress_step = b.step("test-stress", "Run the reload stress test with 300 edits in a headless editor (needs Godot); not part of test");
    const package_test_step = b.step("test-package", "Run the release package tests (part of test)");
    const package_step = b.step("package", "Write the release package <prefix>/ziggurat-" ++ sdk_version ++ ".zip (the release download and the Asset Store upload)");

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

    // The shipped SDK (spec section 1): every file a script build needs,
    // with a manifest whose roots are relative to it. `sdk-stage` writes it
    // to the folder the user gave; tests and `host` use the cached copy.
    const stage_tool = b.addExecutable(.{
        .name = "sdk_stage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sdk_stage.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const staged_sdk = blk: {
        const run = b.addRunArtifact(stage_tool);
        // The output folder is in the build cache and an interrupted run
        // may have left it half-filled: the tool replaces it.
        run.addArg("--replace");
        const out = run.addOutputDirectoryArg("sdk");
        addStageModules(b, run, sdk);
        break :blk out;
    };
    if (sdk_out) |out| {
        if (std.fs.path.isAbsolute(out)) {
            const run = b.addRunArtifact(stage_tool);
            run.addArg(out);
            run.has_side_effects = true;
            addStageModules(b, run, sdk);
            stage_step.dependOn(&run.step);
        } else {
            stage_step.dependOn(&b.addFail("-Dsdk-out must be an absolute path").step);
        }
    } else {
        stage_step.dependOn(&b.addFail("sdk-stage needs -Dsdk-out=<absolute path>").step);
    }
    // The tool's own main path in a Debug build (the unit tests do not
    // reach `main`; Debug builds trap on mistakes ReleaseSafe hides, such
    // as closing a folder twice): one tiny module staged with --replace.
    {
        const debug_tool = b.addExecutable(.{
            .name = "sdk_stage_debug",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/sdk_stage.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        const run = b.addRunArtifact(debug_tool);
        run.addArg("--replace");
        _ = run.addOutputDirectoryArg("sdk");
        run.addArgs(&.{ "0.0.0", "empty" });
        run.addFileArg2(b.path("src/build/empty_root.zig"), .{ .make_absolute = true });
        run.addArgs(&.{ "", "none" });
        unit_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
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
    const host = addHost(b, target, optimize, godot_path, zig_exe, sdk_options, .{});
    const gdextension_file = b.path("addons/ziggurat/ziggurat.gdextension");
    // `zig build host -p <project>` makes <project>/addons/ziggurat/ a
    // working add-on folder, with the library under bin/.
    const addon_dir: std.Build.InstallDir = .{ .custom = "addons/ziggurat" };
    const addon_bin_dir: std.Build.InstallDir = .{ .custom = "addons/ziggurat/bin" };
    host_step.dependOn(&b.addInstallFileWithDir(host.getEmittedBin(), addon_bin_dir, "libziggurat_host.so").step);
    host_step.dependOn(&b.addInstallFileWithDir(gdextension_file, addon_dir, "ziggurat.gdextension").step);
    // The shipped SDK, where the host looks for it when the project setting
    // `ziggurat/dev/sdk_manifest` is empty.
    host_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = staged_sdk,
        .install_dir = .{ .custom = "addons/ziggurat/sdk" },
        .install_subdir = "",
    }).step);

    // The export host (spec section 10): a static archive that the export
    // build links with the scripts into an exported game's library. Built
    // like that library: ReleaseSafe, LLVM, the pinned export target, no
    // debug information (it would carry this checkout's paths).
    const export_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = pins.export_target }) catch
        @panic("bad export target triple"));
    const export_sdk = addSdk(b, export_target, .ReleaseSafe, godot_path);
    const export_sdk_options = export_sdk.import_table.get("sdk_options").?;
    const export_host_archive = addHost(b, export_target, .ReleaseSafe, godot_path, zig_exe, export_sdk_options, .{
        .export_build = true,
        .linkage = .static,
        .use_llvm = true,
        .strip = true,
    });
    // Zig names the archive's member after its path in the build cache,
    // which holds the cache folder (absolute with an absolute --cache-dir)
    // and differs per checkout; the shipped archive names it by base name.
    const shipped_archive = blk: {
        const tool = b.addExecutable(.{
            .name = "ar_normalize",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/ar_normalize.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        });
        const run = b.addRunArtifact(tool);
        run.addArtifactArg(export_host_archive);
        break :blk run.addOutputFileArg("libziggurat_host_export.a");
    };
    archive_step.dependOn(&b.addInstallFileWithDir(shipped_archive, .lib, "libziggurat_host_export.a").step);
    // The game library of a project without Zig scripts (the export plugin
    // ships it instead of building one): the empty generated root linked
    // with the export host archive, built as an export build builds.
    const game_empty = linkedLibrary(b, emptyRootObject(b, export_target, export_sdk), export_host_archive, .{
        .name = "ziggurat_game_empty",
        .use_llvm = true,
        .strip = true,
    });
    // The add-on's export inputs go next to the editor library, where the
    // export plugin looks for them.
    host_step.dependOn(&b.addInstallFileWithDir(shipped_archive, addon_bin_dir, "libziggurat_host_export.a").step);
    host_step.dependOn(&b.addInstallFileWithDir(game_empty.getEmittedBin(), addon_bin_dir, "libziggurat_game_empty.so").step);

    // The release package (spec section 1): the add-on folder in one
    // deterministic zip. Its editor library is built like the export
    // host: ReleaseSafe, the pinned glibc, no debug information (it would
    // carry this checkout's paths).
    const release_host = addHost(b, export_target, .ReleaseSafe, godot_path, zig_exe, export_sdk_options, .{
        .use_llvm = true,
        .strip = true,
    });
    const package_tool = b.addExecutable(.{
        .name = "package",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/package.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const package_name = "ziggurat-" ++ sdk_version ++ ".zip";
    // Two runs on the same inputs (the output names differ, so the cache
    // keeps them apart); the tests compare them.
    var packages: [2]std.Build.LazyPath = undefined;
    for (&packages, [_][]const u8{ package_name, "again-" ++ package_name }) |*out, name| {
        const run = b.addRunArtifact(package_tool);
        out.* = run.addOutputFileArg(name);
        for ([_]struct { []const u8, std.Build.LazyPath }{
            .{ "LICENSE", b.path("LICENSE") },
            .{ "THIRD_PARTY_LICENSES.md", b.path("THIRD_PARTY_LICENSES.md") },
            .{ "gdzig-PATCHES.md", b.path("vendor/gdzig/PATCHES.md") },
            .{ "README.md", b.path("addons/ziggurat/README.md") },
            .{ "ziggurat.gdextension", gdextension_file },
            .{ "bin/libziggurat_host.so", release_host.getEmittedBin() },
            .{ "bin/libziggurat_host_export.a", shipped_archive },
            .{ "bin/libziggurat_game_empty.so", game_empty.getEmittedBin() },
        }) |f| {
            run.addArg(b.fmt("addons/ziggurat/{s}", .{f[0]}));
            run.addFileArg(f[1]);
        }
        run.addArg("addons/ziggurat/sdk");
        run.addDirectoryArg(staged_sdk);
    }
    package_step.dependOn(&b.addInstallFile(packages[0], package_name).step);

    if (godot_found == null) {
        host_test_step.dependOn(&b.addFail("test-host needs Godot on PATH or -Dgodot-path=<absolute path>").step);
        gui_test_step.dependOn(&b.addFail("test-gui needs Godot on PATH or -Dgodot-path=<absolute path>").step);
        stress_step.dependOn(&b.addFail("test-stress needs Godot on PATH or -Dgodot-path=<absolute path>").step);
    } else {
        const probe_host = addHost(b, target, optimize, godot_path, zig_exe, sdk_options, .{ .test_probe = true });
        const export_archive = addHost(b, target, optimize, godot_path, zig_exe, sdk_options, .{ .export_build = true, .linkage = .static });
        const linked_object = linkedFixtureObject(b, target, optimize, sdk);
        addHostTests(b, host_test_step, target, optimize, .{
            .host = host,
            .probe_host = probe_host,
            .linked_host = linkedLibrary(b, linked_object, export_archive, .{ .name = "ziggurat_linked" }),
            .export_host_archive = export_host_archive,
            .game_empty = game_empty,
            .export_templates = export_templates,
            // Built only for a run that can export (the install test).
            .package_zip = if (export_templates != null) packages[0] else null,
            .gdextension = gdextension_file,
            .godot_exe = godot_found.?,
            .zig_exe = zig_exe,
            .sdk_manifest = test_manifest,
            .staged_sdk = staged_sdk,
            .sdk_options = sdk_options,
            .filter = host_test_filter,
            .gui_step = gui_test_step,
            .stress_step = stress_step,
        });
    }
    test_step.dependOn(host_test_step);

    // Native: integration on for `test`, off for `test-unit`.
    addTestSet(b, test_step, target, optimize, zig_exe, true, true, test_manifest, .{ .debug = sdk, .safe = addSdk(b, target, .ReleaseSafe, godot_path) }, sdk_options, sdk, sdk.import_table.get("gdzig").?, export_host_archive, staged_sdk, .{ .zips = packages, .step = package_test_step });
    addTestSet(b, unit_step, target, optimize, zig_exe, false, true, null, null, sdk_options, sdk, sdk.import_table.get("gdzig").?, null, null, null);

    // Cross: compile only.
    for (cross_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("bad cross target triple");
        const resolved = b.resolveTargetQuery(query);
        addTestSet(b, cross_step, resolved, optimize, zig_exe, false, false, null, null, sdk_options, sdk, sdkGdzig(b, resolved, optimize, godot_path), null, null, null);
    }
}

/// The SDK's gdzig dependency. One set of arguments gives one dependency
/// instance, so every caller shares the SDK's bindings.
fn sdkGdzigDependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    godot_path: []const u8,
) *std.Build.Dependency {
    return b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
        // gdzig's name for single precision; `sdk_options.precision` says "single".
        .precision = "float",
        // Scripts must not use gdzig's Object helpers (setInstance,
        // asInstance, connect, disconnect, emit, emitAlloc); with false each
        // is a compile error (vendor/gdzig/PATCHES.md, patch 3). This makes
        // the SDK's gdzig a second dependency instance; the host keeps the
        // helpers.
        .object_helpers = false,
    });
}

/// The SDK's `gdzig` module for `target`.
fn sdkGdzig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    godot_path: []const u8,
) *std.Build.Module {
    return sdkGdzigDependency(b, target, optimize, godot_path).module("gdzig");
}

/// The SDK module `ziggurat` and everything it imports.
fn addSdk(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    godot_path: []const u8,
) *std.Build.Module {
    const gdzig = sdkGdzigDependency(b, target, optimize, godot_path);

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

/// Which host library `addHost` builds.
const HostVariant = struct {
    /// Registers the `ZigguratTestProbe` class the host tests drive the
    /// runtime with; the installed library never has it.
    test_probe: bool = false,
    /// An exported game's host: the generation manifest reader and the
    /// editor's builds are compiled out (spec section 6), and the scripts'
    /// `ziggurat_describe` and `ziggurat_init` are extern symbols that the
    /// link with the scripts' object provides (spec section 10).
    export_build: bool = false,
    /// `.static` builds the archive `libziggurat_host_<variant>.a`, compiled
    /// as position-independent code so it can go into a shared library.
    linkage: std.builtin.LinkMode = .dynamic,
    /// Forces the LLVM backend (null: the compiler's default).
    use_llvm: ?bool = null,
    /// Omits debug information (null: the optimize mode's default).
    strip: ?bool = null,
};

/// The host library `ziggurat_host` (spec section 3). It imports gdzig, the
/// ABI module, the platform layer and the SDK's `sdk_options` (for the
/// layout stamp), never the SDK.
fn addHost(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    godot_path: []const u8,
    zig_exe: []const u8,
    sdk_options: *std.Build.Module,
    variant: HostVariant,
) *std.Build.Step.Compile {
    if (variant.test_probe and variant.export_build) @panic("an export build has no test probe");
    const gdzig = b.dependency("gdzig", .{
        .target = target,
        .optimize = optimize,
        .@"godot-path" = godot_path,
        .precision = "float",
    });
    const host_options = b.addOptions();
    host_options.addOption(bool, "test_probe", variant.test_probe);
    host_options.addOption(bool, "export_build", variant.export_build);
    // The platform layer's test settings: integration off, no test paths.
    const platform_options = b.addOptions();
    platform_options.addOption([]const u8, "zig_exe", zig_exe);
    platform_options.addOption(bool, "run_integration", false);
    platform_options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    platform_options.addOption([]const u8, "sdk_manifest_path", "");
    const platform_options_mod = platform_options.createModule();
    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_options", .module = platform_options_mod }},
    });
    const abi = addAbi(b, target, optimize);
    // The build service (L2): the host runs it inside the editor.
    const build_mod = b.createModule(.{
        .root_source_file = b.path("src/build/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = platform_options_mod },
            .{ .name = "ziggurat_platform", .module = platform },
            .{ .name = "ziggurat_abi", .module = abi },
        },
    });
    return b.addLibrary(.{
        .linkage = variant.linkage,
        .name = if (variant.test_probe) "ziggurat_host_probe" else if (variant.export_build) "ziggurat_host_export" else "ziggurat_host",
        .use_llvm = variant.use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/entry.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = variant.strip,
            .pic = if (variant.linkage == .static) true else null,
            .imports = &.{
                .{ .name = "gdzig", .module = gdzig.module("gdzig") },
                .{ .name = "ziggurat_abi", .module = abi },
                .{ .name = "ziggurat_platform", .module = platform },
                .{ .name = "ziggurat_build", .module = build_mod },
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
    /// The export host archive linked with the linked fixture's module
    /// object (`linkedLibrary`).
    linked_host: *std.Build.Step.Compile,
    /// The export host archive the export plugin links games with
    /// (`host-archive`), and the game library of a project without Zig
    /// scripts; the export tests put both into the add-on's bin/ folder.
    export_host_archive: *std.Build.Step.Compile,
    game_empty: *std.Build.Step.Compile,
    /// `-Dexport-templates`: the export tests skip when it is null.
    export_templates: ?[]const u8,
    /// The release package (`zig build package`) the install test unzips
    /// into a fresh project; null when the export tests skip.
    package_zip: ?std.Build.LazyPath,
    gdextension: std.Build.LazyPath,
    godot_exe: []const u8,
    zig_exe: []const u8,
    /// The SDK manifest the tests build fixture modules with.
    sdk_manifest: std.Build.LazyPath,
    /// The shipped SDK folder (`sdk-stage`).
    staged_sdk: std.Build.LazyPath,
    sdk_options: *std.Build.Module,
    /// Runs only the host tests whose name contains this text.
    filter: ?[]const u8 = null,
    /// The step that runs the GUI test (`test-gui`): the host tests named
    /// "gui: ..." with a GUI editor under Xvfb. It needs xvfb-run on PATH.
    gui_step: *std.Build.Step,
    /// The step that runs the long reload stress test (`test-stress`).
    stress_step: *std.Build.Step,
};

/// The reload stress test's size (test/host/stress/driver.gd): `short` runs
/// in `test` and `test-host`, `long` in `test-stress`.
const Stress = struct {
    edits: u32,
    broken_every: u32,
    nested_every: u32,
    /// Seconds for the whole editor run.
    deadline_s: []const u8,
    /// Print the run's timing line also when it passes.
    report_times: bool,

    const short: Stress = .{ .edits = 20, .broken_every = 10, .nested_every = 7, .deadline_s = "900", .report_times = false };
    const long: Stress = .{ .edits = 300, .broken_every = 25, .nested_every = 10, .deadline_s = "3600", .report_times = true };
};

/// The host tests (test/host): a Zig test that copies a fixture project,
/// puts the host into its `addons/ziggurat/` folder, builds fixture modules with the
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
    options.addOptionPath("linked_host_lib", in.linked_host.getEmittedBin());
    options.addOptionPath("export_host_archive", in.export_host_archive.getEmittedBin());
    options.addOptionPath("game_empty_lib", in.game_empty.getEmittedBin());
    options.addOption([]const u8, "export_templates", in.export_templates orelse "");
    if (in.package_zip) |zip| options.addOptionPath("package_zip", zip) else options.addOption([]const u8, "package_zip", "");
    // The export tests' build cache (the Zig cache of their export builds):
    // kept in this build's cache folder, so later runs start warm.
    options.addOptionPathUntracked("export_test_cache", std.Build.LazyPath.cache_root.path(b, "ziggurat-export-tests"));
    options.addOptionPath("gdextension", in.gdextension);
    options.addOption([]const u8, "projects_dir", b.root.joinString(b.allocator, "test/host/projects") catch @panic("OOM"));
    options.addOption([]const u8, "checks_dir", b.root.joinString(b.allocator, "test/host/checks") catch @panic("OOM"));
    options.addOption([]const u8, "fixtures_dir", b.root.joinString(b.allocator, "test/fixtures") catch @panic("OOM"));
    options.addOption([]const u8, "zig_exe", in.zig_exe);
    options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    options.addOptionPath("sdk_manifest_path", in.sdk_manifest);
    options.addOptionPath("staged_sdk_manifest", in.staged_sdk.path(b, "sdk-manifest.json"));
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
    // `test-host` skips the GUI test; `test-gui` runs only that test.
    const headless = hostTestRun(b, target, optimize, in, options_mod, platform, build_mod, abi, .{ .run_gui = false, .filter = in.filter }, .short, null);
    step.dependOn(&headless.step);
    // Without export templates the export tests skip. The notice is printed
    // here once, by a step that inherits stdio: a passing test that writes
    // to stderr is labelled "failed command" by the build runner.
    if (in.export_templates == null) {
        const notice_files = b.addWriteFiles();
        const notice_name = "export-tests-skipped.txt";
        _ = notice_files.add(notice_name, "host export tests skipped: pass -Dexport-templates=<folder with Godot 4.7.2's export templates>\n");
        const notice = b.addRunArtifact(runner);
        notice.addArg("--print");
        notice.addDirectoryArg(notice_files.getDirectory());
        notice.addArg(notice_name);
        notice.stdio = .inherit;
        notice.has_side_effects = true;
        notice.step.dependOn(&headless.step);
        step.dependOn(&notice.step);
    }
    // The long stress run writes its timing lines to a file, and a second
    // step that inherits stdio prints it: the build runner labels a passing
    // test that wrote to stderr with "failed command".
    const report_files = b.addWriteFiles();
    _ = report_files.add("README", "test-stress writes stress-report.txt here.\n");
    const report_dir = report_files.getDirectory();
    const report_name = "stress-report.txt";
    const stress = hostTestRun(b, target, optimize, in, options_mod, platform, build_mod, abi, .{ .run_gui = false, .filter = "reload stress" }, .long, report_dir.path(b, report_name));
    // Never cached: it reports run times.
    stress.has_side_effects = true;
    const show = b.addRunArtifact(runner);
    show.addArg("--print");
    show.addDirectoryArg(report_dir);
    show.addArg(report_name);
    show.stdio = .inherit;
    show.has_side_effects = true;
    show.step.dependOn(&stress.step);
    in.stress_step.dependOn(&show.step);
    if (b.findProgram(.{ .names = &.{"xvfb-run"} })) |xvfb| {
        const gui = hostTestRun(b, target, optimize, in, options_mod, platform, build_mod, abi, .{ .run_gui = true, .xvfb_run = xvfb, .filter = "gui: " }, .short, null);
        // Never cached: it drives a GUI and reports timing.
        gui.has_side_effects = true;
        in.gui_step.dependOn(&gui.step);
    } else {
        in.gui_step.dependOn(&b.addFail("test-gui needs xvfb-run on PATH (nix shell nixpkgs#xvfb-run)").step);
    }
}

const GuiChoice = struct {
    run_gui: bool,
    xvfb_run: []const u8 = "",
    filter: ?[]const u8,
};

/// One run of test/host/host_test.zig; `gui` decides whether the "gui: "
/// test runs (module `host_gui_options`).
fn hostTestRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    in: HostTestInputs,
    options_mod: *std.Build.Module,
    platform: *std.Build.Module,
    build_mod: *std.Build.Module,
    abi: *std.Build.Module,
    gui: GuiChoice,
    stress: Stress,
    /// Where the stress test writes its timing lines (`report_times`).
    report: ?std.Build.LazyPath,
) *std.Build.Step.Run {
    const stress_options = b.addOptions();
    stress_options.addOption(u32, "edits", stress.edits);
    stress_options.addOption(u32, "broken_every", stress.broken_every);
    stress_options.addOption(u32, "nested_every", stress.nested_every);
    stress_options.addOption([]const u8, "deadline_s", stress.deadline_s);
    stress_options.addOption(bool, "report_times", stress.report_times);
    if (report) |r| stress_options.addOptionPathUntracked("report_file", r) else stress_options.addOption([]const u8, "report_file", "");
    stress_options.addOption([]const u8, "stress_dir", b.root.joinString(b.allocator, "test/host/stress") catch @panic("OOM"));
    const gui_options = b.addOptions();
    gui_options.addOption(bool, "run_gui", gui.run_gui);
    gui_options.addOption([]const u8, "xvfb_run", gui.xvfb_run);
    gui_options.addOption([]const u8, "gui_dir", b.root.joinString(b.allocator, "test/host/gui") catch @panic("OOM"));
    const t = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/host/host_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "host_test_options", .module = options_mod },
            .{ .name = "host_gui_options", .module = gui_options.createModule() },
            .{ .name = "host_stress_options", .module = stress_options.createModule() },
            .{ .name = "ziggurat_platform", .module = platform },
            .{ .name = "ziggurat_build", .module = build_mod },
            .{ .name = "ziggurat_abi", .module = abi },
            .{ .name = "sdk_options", .module = in.sdk_options },
        },
    }), .filters = if (gui.filter) |f| b.dupeStrings(&.{f}) else &.{} });
    const run = b.addRunArtifact(t);
    // The fixtures and check scripts are read at run time, and the SDK is
    // compiled from source by a child compiler; Godot is an input too.
    addSourceInputs(b, run, &.{ "test/host", "test/fixtures", "sdk", "src/abi" });
    run.addFileInput(.{ .cwd_relative = in.godot_exe });
    return run;
}

/// The linked fixture's module (test/fixtures/linked_project): its root
/// file, written as a generated root, compiled on its own into an object
/// with the SDK, so the root is `@import("root")` for the SDK.
fn linkedFixtureObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addObject(.{
        .name = "linked_fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures/linked_project/linked_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            .imports = &.{.{ .name = "ziggurat", .module = sdk }},
        }),
    });
}

/// The empty generated root (src/build/empty_root.zig) compiled on its own
/// into an object with the SDK `sdk`, as an export build compiles a
/// project's root: ReleaseSafe, LLVM, no debug information.
fn emptyRootObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    sdk: *std.Build.Module,
) *std.Build.Step.Compile {
    const files = b.addWriteFiles();
    return b.addObject(.{
        .name = "empty_root",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = files.add(".ziggurat_root.zig", empty_root.text),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .pic = true,
            .strip = true,
            .imports = &.{.{ .name = "ziggurat", .module = sdk }},
        }),
    });
}

const LinkedOptions = struct {
    name: []const u8,
    /// Forces the LLVM backend (null: the compiler's default).
    use_llvm: ?bool = null,
    /// Omits debug information (null: the optimize mode's default).
    strip: ?bool = null,
};

/// One shared library of a module object (a generated root compiled with
/// the SDK) and the export host archive (`addHost` with `export_build` and
/// `.static`): the host's extern `ziggurat_describe` and `ziggurat_init`
/// resolve to the module's, so nothing is loaded at run time. Godot's
/// entry `ziggurat_host_init` is the only symbol the library exports.
fn linkedLibrary(
    b: *std.Build,
    module_object: *std.Build.Step.Compile,
    export_host_archive: *std.Build.Step.Compile,
    o: LinkedOptions,
) *std.Build.Step.Compile {
    const mod = module_object.root_module;
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = o.name,
        .use_llvm = o.use_llvm,
        .root_module = b.createModule(.{
            .target = mod.resolved_target,
            .optimize = mod.optimize,
            .link_libc = true,
            .strip = o.strip,
        }),
    });
    lib.root_module.addObject(module_object);
    lib.root_module.linkLibrary(export_host_archive);
    // Nothing in the module object refers to the entry point, so the
    // archive member that defines it is pulled in by name.
    lib.forceUndefinedSymbol("ziggurat_host_init");
    // The module's `ziggurat_describe` and `ziggurat_init` resolve inside
    // the library and are not exported.
    const files = b.addWriteFiles();
    lib.setVersionScript(files.add("exports.map", "{ global: ziggurat_host_init; local: *; };\n"));
    return lib;
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
    // Two versions of one script for the migration tests; both files are
    // named mover.zig, so their type names agree as two builds' do.
    const fixture_mover_v1 = fixtureModule(b, target, optimize, sdk, "test/fixtures/migrate_v1/mover.zig");
    const fixture_mover_v2 = fixtureModule(b, target, optimize, sdk, "test/fixtures/migrate_v2/mover.zig");
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
            .{ .name = "fixture_mover_v1", .module = fixture_mover_v1 },
            .{ .name = "fixture_mover_v2", .module = fixture_mover_v2 },
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
    addModuleArgs(b, run, sdk, false);
}

/// Arguments of tools/sdk_stage.zig after its output folder: the SDK
/// version, then name, root, deps and what to strip of each module. The
/// generated gdzig tree loses its `///` doc comments (most of its size,
/// and Godot's documentation text); the translate-c output loses its line
/// comments (source locations that name this machine's headers).
fn addStageModules(b: *std.Build, run: *std.Build.Step.Run, sdk: *std.Build.Module) void {
    addModuleArgs(b, run, sdk, true);
}

/// `<sdk_version>`, then per SDK module `<name> <root> <deps>`, and with
/// `stage` also `<strip>`. With `stage` every file in the folder of each
/// source root becomes an input of `run`: the stage tool reads the files
/// the root imports, which the build system cannot see. That covers this
/// checkout's folders, the path dependency `vendor/gdzig` (its `common`
/// package) and fetched packages; generated roots come with the step that
/// makes them.
fn addModuleArgs(b: *std.Build, run: *std.Build.Step.Run, sdk: *std.Build.Module, stage: bool) void {
    run.addArg(sdk_version);
    const seen = sdkModules(b, sdk);
    for (seen.keys(), seen.values()) |name, mod| {
        run.addArg(name);
        const root = mod.root_source_file orelse std.debug.panic("SDK module \"{s}\" has no root source file", .{name});
        run.addFileArg2(root, .{ .make_absolute = true });
        run.addArg(std.mem.join(b.allocator, ",", mod.import_table.keys()) catch @panic("OOM"));
        if (!stage) continue;
        const strip = if (std.mem.eql(u8, name, "gdzig"))
            "docs"
        else if (std.mem.eql(u8, name, "gdextension"))
            "comments"
        else
            "none";
        run.addArg(strip);
        switch (root) {
            .src_path => |sp| addTreeInputs(b, run, sp.owner, std.fs.path.dirname(sp.sub_path) orelse ""),
            else => {},
        }
    }
}

/// Makes every file under folder `sub` of `owner`'s build root (any
/// package's builder) an input of `run`, and a new or removed file there
/// repeat configuration.
fn addTreeInputs(b: *std.Build, run: *std.Build.Step.Run, owner: *std.Build, sub: []const u8) void {
    const io = b.graph.io;
    const abs = owner.root.joinString(b.allocator, sub) catch @panic("OOM");
    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ abs, err });
    defer dir.close(io);
    const lazy = struct {
        fn at(o: *std.Build, base: []const u8, rel: []const u8) std.Build.LazyPath {
            const p = if (base.len == 0) rel else if (rel.len == 0) base else o.fmt("{s}/{s}", .{ base, rel });
            return .{ .src_path = .{ .owner = o, .sub_path = if (p.len == 0) "." else p } };
        }
    };
    b.dependOnDirectoryContents(lazy.at(owner, sub, ""));
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("cannot walk {s}: {t}", .{ abs, err })) |entry| {
        switch (entry.kind) {
            .directory => b.dependOnDirectoryContents(lazy.at(owner, sub, entry.path)),
            .file => run.addFileInput(lazy.at(owner, sub, entry.path)),
            else => {},
        }
    }
}

/// The SDK module `ziggurat` and every module it imports, by name, in the
/// order they are first reached.
fn sdkModules(b: *std.Build, sdk: *std.Build.Module) std.StringArrayHashMapUnmanaged(*std.Build.Module) {
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
    return seen;
}

const ProbeSdks = struct { debug: *std.Build.Module, safe: *std.Build.Module };

const PackageTests = struct {
    /// The package from two packager runs on the same inputs.
    zips: [2]std.Build.LazyPath,
    /// `test-package`, which runs only these tests.
    step: *std.Build.Step,
};

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
    /// The SDK's `gdzig` module for `target` (the lazy cache test).
    sdk_gdzig: *std.Build.Module,
    /// The export host archive the export build tests link (native sets
    /// that run integration tests only).
    export_host_archive: ?*std.Build.Step.Compile,
    /// The staged SDK the shipped-SDK tests read (native sets that run
    /// integration tests only).
    staged: ?std.Build.LazyPath,
    /// The release package from two packager runs (native sets that run
    /// integration tests only).
    package: ?PackageTests,
) void {
    const options = b.addOptions();
    options.addOption([]const u8, "zig_exe", zig_exe);
    options.addOption(bool, "run_integration", run_integration);
    options.addOptionPath("stub_sdk_path", b.path("test/stub_sdk/ziggurat.zig"));
    // Toolchain install fixtures (test/fixtures/toolchain/make.sh).
    for ([_][2][]const u8{
        .{ "toolchain_good_tar", "zig-x86_64-linux-0.17.0.tar.xz" },
        .{ "toolchain_good_zip", "zig-x86_64-linux-0.17.0.zip" },
        .{ "toolchain_bad_version", "bad-version.tar.xz" },
        .{ "toolchain_two_top", "two-top.tar.xz" },
        .{ "toolchain_real_minisig", "zig-x86_64-linux-0.17.0.tar.xz.minisig" },
    }) |f| {
        options.addOptionPath(f[0], b.path(b.fmt("test/fixtures/toolchain/{s}", .{f[1]})));
    }
    if (sdk_manifest) |m| {
        options.addOptionPath("sdk_manifest_path", m);
    } else {
        options.addOption([]const u8, "sdk_manifest_path", "");
    }
    if (export_host_archive) |lib| {
        options.addOptionPath("export_host_archive", lib.getEmittedBin());
    } else {
        options.addOption([]const u8, "export_host_archive", "");
    }
    // The shipped-SDK tests look in the staged SDK for this checkout's
    // paths and its caches' (`build_machine_*`).
    if (staged) |dir| {
        options.addOptionPath("staged_sdk_manifest", dir.path(b, "sdk-manifest.json"));
    } else {
        options.addOption([]const u8, "staged_sdk_manifest", "");
    }
    options.addOption([]const u8, "build_machine_repo", b.root.joinString(b.allocator, "") catch @panic("OOM"));
    options.addOptionPathUntracked("build_machine_local_cache", .{ .relative = .{ .base = .local_cache } });
    options.addOptionPathUntracked("build_machine_global_cache", .{ .relative = .{ .base = .global_cache } });

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

    // The host's language helpers that import only std: the global class
    // scan, the template text, the diagnostics cache and the main-thread
    // queue (the last two lock with the C-allocated process Io), and the
    // Zig syntax colours of the script editor.
    var host_std: [5]*std.Build.Module = undefined;
    for (&host_std, [_][]const u8{ "global_class", "template", "diag_cache", "main_queue", "highlight" }) |*m, name| {
        m.* = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/host/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
    }

    // The package tool's archive rewrite imports only std.
    const ar_normalize = b.createModule(.{
        .root_source_file = b.path("tools/ar_normalize.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The SDK stage tool's folder handling imports only std.
    const sdk_stage_tool = b.createModule(.{
        .root_source_file = b.path("tools/sdk_stage.zig"),
        .target = target,
        .optimize = optimize,
    });

    // gdzig's class checks (vendor/gdzig/PATCHES.md, patch 4) import only
    // std; their tests also cover gdzig's singleton-owner lookup.
    const class_kind = b.createModule(.{
        .root_source_file = b.path("vendor/gdzig/src/class_kind.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The generation manifest's writer and reader import std and the
    // platform layer only.
    const host_manifest = b.createModule(.{
        .root_source_file = b.path("src/host/manifest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "ziggurat_platform", .module = platform }},
    });

    // The SDK's lazy caches (sdk/names_test.zig), with the engine calls
    // replaced by fakes. Where it runs on Linux it is built with
    // ThreadSanitizer, and `halt_on_error` makes a reported data race fail
    // the test (without it the test runner still exits 0).
    const tsan = run and target.result.os.tag == .linux and
        (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64);
    const names_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("sdk/names_test.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{.{ .name = "gdzig", .module = sdk_gdzig }},
    }) });
    if (run) {
        const names_run = b.addRunArtifact(names_test);
        names_run.setEnvironmentVariable("TSAN_OPTIONS", "halt_on_error=1");
        step.dependOn(&names_run.step);
    } else {
        step.dependOn(&names_test.step);
    }

    for ([_]*std.Build.Module{ platform, build_mod, abi, snake, fmtlog, host_version, output_scan, host_std[0], host_std[1], host_std[2], host_std[3], host_std[4], host_manifest, class_kind, ar_normalize, sdk_stage_tool }) |mod| {
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

        if (package) |pkg| {
            const zips = pkg.zips;
            const package_options = b.addOptions();
            package_options.addOptionPath("package_zip", zips[0]);
            package_options.addOptionPath("package_zip_again", zips[1]);
            package_options.addOptionPath("staged_sdk_manifest", staged.?.path(b, "sdk-manifest.json"));
            package_options.addOption([]const u8, "zig_exe", zig_exe);
            package_options.addOption([]const u8, "sdk_version", sdk_version);
            package_options.addOption([]const u8, "build_machine_repo", b.root.joinString(b.allocator, "") catch @panic("OOM"));
            package_options.addOptionPathUntracked("build_machine_local_cache", .{ .relative = .{ .base = .local_cache } });
            package_options.addOptionPathUntracked("build_machine_global_cache", .{ .relative = .{ .base = .global_cache } });
            const package_mod = b.createModule(.{
                .root_source_file = b.path("test/package.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            package_mod.addImport("package_options", package_options.createModule());
            package_mod.addImport("ziggurat_platform", platform);
            package_mod.addImport("ziggurat_build", build_mod);
            const package_run = b.addRunArtifact(b.addTest(.{ .root_module = package_mod }));
            step.dependOn(&package_run.step);
            pkg.step.dependOn(&package_run.step);
        }
    }
}
