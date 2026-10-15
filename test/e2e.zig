//! End-to-end tests for Stage 1: the build service driving the real Zig
//! compiler on generated projects with the stub SDK. Every test here spawns
//! the compiler, so all are `integration:` tests.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const service = zbuild.service;
const BuildService = service.BuildService;
const Outcome = service.Outcome;
const OsPath = platform.path.OsPath;
const testing = std.testing;
const io = testing.io;

const is_windows = builtin.os.tag == .windows;

/// Long enough for a cold compile on a slow machine.
const build_wait_ms = 300_000;

/// A temporary project with its own cache and generation store.
const Fx = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    base: []const u8,
    project: []const u8,
    cache: []const u8,
    store: []const u8,
    sdk: []const zbuild.workspace.ModuleDep,
    env: platform.path.HostEnv,

    fn init(fx: *Fx, project_name: []const u8) !void {
        fx.arena_state = .init(testing.allocator);
        errdefer fx.arena_state.deinit();
        const a = fx.arena_state.allocator();
        fx.tmp = testing.tmpDir(.{});
        errdefer fx.tmp.cleanup();
        try fx.tmp.dir.createDirPath(io, project_name);
        try fx.tmp.dir.createDirPath(io, "cache");
        fx.base = try fx.tmp.dir.realPathFileAlloc(io, ".", a);
        fx.project = try fx.tmp.dir.realPathFileAlloc(io, project_name, a);
        fx.cache = try fx.tmp.dir.realPathFileAlloc(io, "cache", a);
        fx.store = try std.fs.path.join(a, &.{ fx.base, "store" });
        const stub = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.stub_sdk_path, a);
        fx.sdk = try a.dupe(zbuild.workspace.ModuleDep, &.{.{ .name = "ziggurat", .root = .fromTrusted(stub), .deps = &.{} }});
        fx.env = .{ .os = builtin.os.tag, .home = fx.cache, .xdg_cache_home = fx.cache, .local_app_data = fx.cache };
    }

    fn deinit(fx: *Fx) void {
        fx.tmp.cleanup();
        fx.arena_state.deinit();
    }

    fn arena(fx: *Fx) std.mem.Allocator {
        return fx.arena_state.allocator();
    }

    fn write(fx: *Fx, rel: []const u8, data: []const u8) !void {
        var d = try std.Io.Dir.cwd().openDir(io, fx.project, .{});
        defer d.close(io);
        if (std.fs.path.dirname(rel)) |sub| try d.createDirPath(io, sub);
        try d.writeFile(io, .{ .sub_path = rel, .data = data });
    }

    fn paths(fx: *Fx) platform.path.PathService {
        return .init(.{ .project = .fromTrusted(fx.project) }, fx.env);
    }

    fn config(fx: *Fx, zig: []const u8) service.Config {
        return .{
            .paths = fx.paths(),
            .locate = .{
                .configured = .fromTrusted(zig),
                .toolchain_dir = .fromTrusted(fx.base),
                .env = fx.env,
            },
            .script_dirs = zbuild.scan.default_script_dirs,
            .sdk = fx.sdk,
            .store_root = .fromTrusted(fx.store),
        };
    }

    /// Writes an executable shell script `name` in the temporary folder that
    /// answers `version` with `version` and otherwise sleeps `delay` seconds
    /// (`incremental_delay` for an `-fincremental` compiler) and then runs the
    /// real compiler. Returns its absolute path.
    fn wrapper(fx: *Fx, name: []const u8, version: []const u8, delay: []const u8, incremental_delay: []const u8) ![]const u8 {
        const a = fx.arena();
        const text = try std.fmt.allocPrint(a,
            \\#!/bin/sh
            \\if [ "$1" = version ]; then echo '{s}'; exit 0; fi
            \\case " $* " in
            \\  *" -fincremental "*) sleep {s} ;;
            \\  *) sleep {s} ;;
            \\esac
            \\exec '{s}' "$@"
            \\
        , .{ version, incremental_delay, delay, build_options.zig_exe });
        try fx.tmp.dir.writeFile(io, .{ .sub_path = name, .data = text });
        const p = try std.fs.path.joinZ(a, &.{ fx.base, name });
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(p, 0o755));
        return p;
    }
};

fn scriptSource(a: std.mem.Allocator, value: i32) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\pub const extends = "Node";
        \\
        \\export fn e2e_value() i32 {{
        \\    return {d};
        \\}}
        \\
    , .{value});
}

/// Loads the staged library of `o` and calls its `e2e_value`.
fn callValue(o: Outcome) !i32 {
    const gen = o.generation orelse return error.NoGeneration;
    var diag: [256]u8 = undefined;
    const lib = platform.loader.open(testing.allocator, io, gen.lib, &diag) catch |err| {
        std.debug.print("load failed: {s}\n", .{platform.elf.diagText(&diag)});
        return err;
    };
    defer platform.loader.close(lib);
    const f = platform.loader.lookup(lib, *const fn () callconv(.c) i32, "e2e_value") orelse return error.SymbolNotFound;
    return f();
}

fn build(svc: *BuildService, t: service.Trigger) !Outcome {
    svc.request(t);
    try svc.waitIdle(build_wait_ms);
    return svc.last() orelse error.NoOutcome;
}

fn expectOk(o: Outcome) !void {
    if (!o.ok) {
        std.debug.print("build failed: {?s}\n", .{o.message});
        for (o.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        return error.BuildFailed;
    }
}

const Timing = struct { full_ms: u64, warm_ms: u64, edit_ms: u64, broken_ms: u64, fixed_ms: u64 };

/// The shared Stage 1 scenario: a full first build, an incremental body edit,
/// a broken script with its diagnostic, and the fix.
fn scenario(fx: *Fx, svc: *BuildService, rel: []const u8) !Timing {
    const a = fx.arena();
    var t: Timing = undefined;

    const o1 = try build(svc, .open);
    try expectOk(o1);
    try testing.expectEqual(service.BuildPath.full, o1.path);
    try testing.expectEqual(@as(u32, 1), o1.generation.?.n);
    try testing.expectEqual(@as(i32, 1), try callValue(o1));
    t.full_ms = o1.ms;

    const w0 = std.Io.Clock.awake.now(io);
    try svc.waitWarm(build_wait_ms);
    t.warm_ms = @intCast(w0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds());

    try fx.write(rel, try scriptSource(a, 2));
    const o2 = try build(svc, .save);
    try expectOk(o2);
    try testing.expectEqual(service.BuildPath.incremental, o2.path);
    try testing.expectEqual(@as(u32, 2), o2.generation.?.n);
    try testing.expectEqual(@as(i32, 2), try callValue(o2));
    t.edit_ms = o2.ms;

    const good = try scriptSource(a, 2);
    const broken_line: u32 = @intCast(std.mem.count(u8, good, "\n") + 1);
    try fx.write(rel, try std.mem.concat(a, u8, &.{ good, "fn broken( {\n" }));
    const o3 = try build(svc, .save);
    try testing.expect(!o3.ok);
    try testing.expect(o3.generation == null);
    try testing.expectEqual(service.BuildPath.incremental, o3.path);
    try testing.expect(o3.diagnostics.len >= 1);
    try testing.expectEqualStrings(rel, o3.diagnostics[0].rel.?);
    try testing.expectEqual(broken_line, o3.diagnostics[0].line);
    t.broken_ms = o3.ms;

    try fx.write(rel, try scriptSource(a, 3));
    const o4 = try build(svc, .save);
    try expectOk(o4);
    try testing.expectEqual(service.BuildPath.incremental, o4.path);
    try testing.expectEqual(@as(u32, 3), o4.generation.?.n);
    try testing.expectEqual(@as(i32, 3), try callValue(o4));
    t.fixed_ms = o4.ms;
    return t;
}

/// Prints the timings when `ZIGGURAT_E2E_TIMING` is set (any output on
/// stderr makes the build runner print the test command, so it is opt-in).
fn printTiming(name: []const u8, t: Timing) void {
    const on = testing.environ.containsUnempty(testing.allocator, "ZIGGURAT_E2E_TIMING") catch false;
    if (!on) return;
    std.debug.print("{s}: full {d} ms, warm-up wait {d} ms, incremental edit {d} ms, broken {d} ms, fixed {d} ms\n", .{
        name, t.full_ms, t.warm_ms, t.edit_ms, t.broken_ms, t.fixed_ms,
    });
}

test "integration: e2e_basic" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    try fx.write("lib/helper.zig", "pub fn twice(x: i32) i32 { return 2 * x; }\n");

    const svc = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer svc.deinit();
    printTiming("e2e_basic", try scenario(&fx, svc, "a.zig"));
}

test "integration: e2e_odd_paths" {
    try platform.testing_support.requireIntegration();
    // `"` is not allowed in Windows file names.
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj dir \u{fc}n\u{ef}");
    defer fx.deinit();
    try fx.write("a.zig", "pub const extends = \"Node\";\n");
    const rel = "q\"uote/s.zig";
    try fx.write(rel, try scriptSource(fx.arena(), 1));

    const svc = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer svc.deinit();
    printTiming("e2e_odd_paths", try scenario(&fx, svc, rel));
}

test "integration: e2e_read_only" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    // Root ignores file modes.
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    // The script sits in a sub folder that stays writable, so the test can edit it.
    const rel = "game/s.zig";
    try fx.write(rel, try scriptSource(fx.arena(), 1));
    const proj_z = try fx.arena().dupeSentinel(u8, fx.project, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(proj_z, 0o555));
    defer _ = std.c.chmod(proj_z, 0o755);

    const svc = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer svc.deinit();
    printTiming("e2e_read_only", try scenario(&fx, svc, rel));
    // The generated root went to the mirror, not into the project.
    var d = try std.Io.Dir.cwd().openDir(io, fx.project, .{});
    defer d.close(io);
    try testing.expectError(error.FileNotFound, d.access(io, zbuild.rootgen.root_file_name, .{}));
}

const Counter = struct {
    calls: std.atomic.Value(u32) = .init(0),
    tid: std.atomic.Value(u64) = .init(0),

    fn onOutcome(ctx: ?*anyopaque, o: *const Outcome) void {
        _ = o;
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        _ = self.calls.fetchAdd(1, .acq_rel);
        self.tid.store(@intCast(std.Thread.getCurrentId()), .release);
    }
};

/// Polls until a requested-build compiler update is running.
fn waitUpdating(svc: *BuildService) !void {
    const t0 = std.Io.Clock.awake.now(io);
    while (svc.stats().updates_active == 0) {
        if (t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > build_wait_ms) return error.Timeout;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "integration: triggers_merge" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // The delay keeps the first build running while the requests arrive.
    const zig = try fx.wrapper("slowzig", "0.17.0", "1", "1");

    var counter: Counter = .{};
    var cfg = fx.config(zig);
    cfg.on_outcome = Counter.onOutcome;
    cfg.on_outcome_ctx = &counter;
    const svc = try BuildService.init(testing.allocator, io, cfg);
    defer svc.deinit();

    svc.request(.open);
    try waitUpdating(svc);
    for (0..10) |_| svc.request(.save);
    try svc.waitIdle(build_wait_ms);

    try testing.expectEqual(@as(u32, 2), counter.calls.load(.acquire));
    const st = svc.stats();
    try testing.expectEqual(@as(u32, 2), st.builds);
    try testing.expectEqual(@as(u32, 1), st.updates_max);
    try testing.expectEqual(service.Trigger.save, svc.last().?.trigger);
    try expectOk(svc.last().?);
}

test "integration: save_during_warmup" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // Only the incremental server is slow, so warm-up outlasts a full build.
    const zig = try fx.wrapper("slowzig", "0.17.0", "0", "5");

    const svc = try BuildService.init(testing.allocator, io, fx.config(zig));
    defer svc.deinit();
    const o1 = try build(svc, .open);
    try expectOk(o1);
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);

    // Let warm-up get well into its 5 s update, then save. The save does not
    // wait for warm-up: it takes the full path at once.
    try io.sleep(.fromMilliseconds(1000), .awake);
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);
    try fx.write("a.zig", try scriptSource(fx.arena(), 2));
    const o2 = try build(svc, .save);
    try expectOk(o2);
    try testing.expectEqual(service.BuildPath.full, o2.path);
    try testing.expect(o2.ms < 3000);
    try testing.expectEqual(@as(i32, 2), try callValue(o2));
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);

    // Warm-up ends and the next save is incremental.
    try svc.waitWarm(build_wait_ms);
    try fx.write("a.zig", try scriptSource(fx.arena(), 3));
    const o3 = try build(svc, .save);
    try expectOk(o3);
    try testing.expectEqual(service.BuildPath.incremental, o3.path);
    try testing.expectEqual(@as(i32, 3), try callValue(o3));
}

test "integration: two_services_one_project" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // The delay keeps the first service inside its build (holding build.lock)
    // for longer than the second one waits.
    const zig = try fx.wrapper("slowzig", "0.17.0", "3", "3");

    const first = try BuildService.init(testing.allocator, io, fx.config(zig));
    defer first.deinit();
    var cfg2 = fx.config(zig);
    cfg2.lock_timeout_ms = 500;
    const second = try BuildService.init(testing.allocator, io, cfg2);
    defer second.deinit();

    first.request(.open);
    try waitUpdating(first);
    const o2 = try build(second, .open);
    // The first service was still building the whole time.
    try testing.expectEqual(@as(u32, 1), first.stats().updates_active);

    try testing.expect(!o2.ok);
    try testing.expect(o2.generation == null);
    const a = fx.arena();
    const cache_root = try fx.paths().dir(.cache, a);
    const id = fx.paths().projectId();
    const lock_path = try std.fs.path.join(a, &.{ cache_root.bytes, "projects", &id, "build.lock" });
    const want = try std.fmt.allocPrint(a, "Another editor is building this project (lock: {s}).", .{lock_path});
    try testing.expectEqualStrings(want, o2.message.?);
    // The second service staged nothing.
    const gen_root = try std.fs.path.join(a, &.{ fx.store, "gen" });
    if (std.Io.Dir.cwd().openDir(io, gen_root, .{ .iterate = true })) |d0| {
        var d = d0;
        defer d.close(io);
        var it = d.iterate();
        try testing.expect(try it.next(io) == null);
    } else |err| try testing.expectEqual(error.FileNotFound, err);

    try first.waitIdle(build_wait_ms);
    const o1 = first.last().?;
    try expectOk(o1);
    try testing.expectEqual(@as(u32, 1), o1.generation.?.n);
}

test "integration: e2e_bad_zig" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    const zig = try fx.wrapper("oldzig", "0.16.0", "0", "0");

    var counter: Counter = .{};
    var cfg = fx.config(zig);
    cfg.on_outcome = Counter.onOutcome;
    cfg.on_outcome_ctx = &counter;

    // The message the locator itself gives for this configuration.
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    try testing.expectError(error.ZigNotUsable, platform.zig_locator.locate(testing.allocator, io, cfg.locate, &want));

    const svc = try BuildService.init(testing.allocator, io, cfg);
    const o = try build(svc, .open);
    try testing.expect(!o.ok);
    try testing.expect(o.generation == null);
    try testing.expectEqualStrings(want.items, o.message.?);
    try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    svc.deinit();

    // No thread of the service is left.
    try testing.expectEqual(@as(u32, 0), service.live_threads.load(.acquire));
    if (builtin.os.tag == .linux) {
        const tid = counter.tid.load(.acquire);
        try testing.expect(tid != 0);
        var buf: [64]u8 = undefined;
        const task = try std.fmt.bufPrint(&buf, "/proc/self/task/{d}", .{tid});
        // The kernel removes the task entry right after the thread exits.
        const t0 = std.Io.Clock.awake.now(io);
        while (true) {
            std.Io.Dir.cwd().access(io, task, .{}) catch |err| {
                try testing.expectEqual(error.FileNotFound, err);
                break;
            };
            if (t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 1000) return error.ThreadStillRunning;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
    }
}

test "integration: deinit stops a running build" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    const zig = try fx.wrapper("stuckzig", "0.17.0", "60", "60");

    var counter: Counter = .{};
    var cfg = fx.config(zig);
    cfg.on_outcome = Counter.onOutcome;
    cfg.on_outcome_ctx = &counter;
    const svc = try BuildService.init(testing.allocator, io, cfg);
    svc.request(.open);
    try waitUpdating(svc);
    const t0 = std.Io.Clock.awake.now(io);
    svc.deinit();
    // The compiler group was killed instead of waited for.
    try testing.expect(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 10_000);
    try testing.expectEqual(@as(u32, 0), service.live_threads.load(.acquire));
    // A build cut short by deinit reports nothing.
    try testing.expectEqual(@as(u32, 0), counter.calls.load(.acquire));
}
