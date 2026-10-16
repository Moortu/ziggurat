//! End-to-end tests for the Stage 2 SDK: the build service compiling user
//! scripts against the real SDK and gdzig, with the module list from the SDK
//! manifest (`build_options.sdk_manifest_path`, written by the build).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const service = zbuild.service;
const BuildService = service.BuildService;
const Outcome = service.Outcome;
const testing = std.testing;
const io = testing.io;

/// gdzig is large: a cold build of a module that imports it takes tens of seconds.
const build_wait_ms = 600_000;

fn expectOk(o: Outcome) !void {
    if (!o.ok) {
        std.debug.print("build failed: {?s}\n", .{o.message});
        for (o.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        return error.BuildFailed;
    }
}

test "integration: skeleton sdk builds with gdzig" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    const manifest_path = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.sdk_manifest_path, a);
    var manifest = zbuild.sdk_manifest.load(testing.allocator, io, .fromTrusted(manifest_path), &msg) catch |err| {
        std.debug.print("manifest: {s}\n", .{msg.items});
        return err;
    };
    defer manifest.deinit(testing.allocator);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj");
    try tmp.dir.createDirPath(io, "cache");
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const project = try tmp.dir.realPathFileAlloc(io, "proj", a);
    const cache = try tmp.dir.realPathFileAlloc(io, "cache", a);
    const store = try std.fs.path.join(a, &.{ base, "store" });
    // gdzig keeps engine classes in `class`; the SDK's `godot` is gdzig as is for now.
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj/a.zig",
        .data = "pub const extends = @import(\"ziggurat\").godot.class.Node;\n",
    });

    const env: platform.path.HostEnv = .{ .os = builtin.os.tag, .home = cache, .xdg_cache_home = cache, .local_app_data = cache };
    const svc = try BuildService.init(testing.allocator, io, .{
        .paths = .init(.{ .project = .fromTrusted(project) }, env),
        .locate = .{
            .configured = .fromTrusted(build_options.zig_exe),
            .toolchain_dir = .fromTrusted(base),
            .env = env,
        },
        .sdk = manifest.modules,
        .store_root = .fromTrusted(store),
    });
    defer svc.deinit();

    svc.request(.open);
    try svc.waitIdle(build_wait_ms);
    const o = svc.last() orelse return error.NoOutcome;
    try expectOk(o);
    try testing.expectEqual(service.BuildPath.full, o.path);
    const gen = o.generation orelse return error.NoGeneration;
    try testing.expectEqual(@as(u32, 1), gen.n);
    try std.Io.Dir.cwd().access(io, gen.lib.bytes, .{});

    const on = testing.environ.containsUnempty(testing.allocator, "ZIGGURAT_E2E_TIMING") catch false;
    if (on) std.debug.print("sdk_e2e: full build {d} ms\n", .{o.ms});
}

test "integration: panic probe" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const a = testing.allocator;
    const r = try platform.process.runCapture(a, io, &.{build_options.panic_probe_path}, null, 60_000, 1 << 20);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Zig panic: probe") != null);
    switch (r.term) {
        .signal => {},
        else => {
            std.debug.print("probe ended with {any}\nstderr: {s}\n", .{ r.term, r.stderr });
            return error.NotKilledBySignal;
        },
    }
}
