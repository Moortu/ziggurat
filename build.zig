const std = @import("std");

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
    // Always passed to gdzig, so configuring never searches for Godot; only
    // steps that run Godot need a real one.
    const godot_path = b.option([]const u8, "godot-path", "Godot executable for steps that run Godot [default: godot]") orelse "godot";
    const manifest_out = b.option([]const u8, "manifest-out", "Absolute path the sdk-manifest step writes the SDK module manifest to");

    const test_step = b.step("test", "Run unit and integration tests");
    const unit_step = b.step("test-unit", "Run unit tests only (spawns no compiler)");
    const cross_step = b.step("cross", "Compile test binaries for Windows and macOS (not run)");
    const manifest_step = b.step("sdk-manifest", "Write the SDK module manifest to -Dmanifest-out=<absolute path>");

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

    // Native: integration on for `test`, off for `test-unit`.
    addTestSet(b, test_step, target, optimize, zig_exe, true, true, test_manifest);
    addTestSet(b, unit_step, target, optimize, zig_exe, false, true, null);

    // Cross: compile only.
    for (cross_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch
            @panic("bad cross target triple");
        const resolved = b.resolveTargetQuery(query);
        addTestSet(b, cross_step, resolved, optimize, zig_exe, false, false, null);
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
    return b.createModule(.{
        .root_source_file = b.path("sdk/ziggurat.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gdzig", .module = gdzig.module("gdzig") },
            .{ .name = "sdk_options", .module = sdk_options },
            .{ .name = "ziggurat_abi", .module = addAbi(b, target, optimize) },
        },
    });
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

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options_mod = options.createModule();
    platform.addImport("build_options", options_mod);

    const build_mod = b.createModule(.{
        .root_source_file = b.path("src/build/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    build_mod.addImport("build_options", options_mod);
    build_mod.addImport("ziggurat_platform", platform);

    const abi = addAbi(b, target, optimize);

    for ([_]*std.Build.Module{ platform, build_mod, abi }) |mod| {
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
        const sdk_run = b.addRunArtifact(b.addTest(.{ .root_module = sdk_e2e }));
        // The test builds the SDK from source with a child compiler, which the
        // build system cannot see; track the sources so an edit reruns it.
        addSourceInputs(b, sdk_run, &.{ "sdk", "src/abi" });
        step.dependOn(&sdk_run.step);
    }
}
