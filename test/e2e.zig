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
    /// answers `version` with `version` and otherwise runs the real compiler.
    /// With a gate on, a non-incremental (`gate_full`) or `-fincremental`
    /// (`gate_incremental`) start first creates `<name>.<kind>.waiting` and
    /// then waits, at most 120 s, until the test creates `<name>.<kind>.go`
    /// (`kind` is `full` or `incremental`). Returns the script's path.
    fn wrapper(fx: *Fx, name: []const u8, version: []const u8, gate_full: bool, gate_incremental: bool) ![]const u8 {
        const a = fx.arena();
        const text = try std.fmt.allocPrint(a,
            \\#!/bin/sh
            \\if [ "$1" = version ]; then echo '{s}'; exit 0; fi
            \\case " $* " in
            \\  *" -fincremental "*) kind=incremental; gate={} ;;
            \\  *) kind=full; gate={} ;;
            \\esac
            \\if [ "$gate" = 1 ]; then
            \\  touch '{s}/{s}.'$kind.waiting
            \\  n=0
            \\  while [ ! -e '{s}/{s}.'$kind.go ] && [ $n -lt 6000 ]; do sleep 0.02; n=$((n+1)); done
            \\fi
            \\exec '{s}' "$@"
            \\
        , .{
            version, @intFromBool(gate_incremental), @intFromBool(gate_full),
            fx.base, name,                           fx.base,
            name,    build_options.zig_exe,
        });
        try fx.tmp.dir.writeFile(io, .{ .sub_path = name, .data = text });
        const p = try std.fs.path.joinZ(a, &.{ fx.base, name });
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(p, 0o755));
        return p;
    }

    /// Lets every gated start of `kind` for wrapper `name` go on.
    fn openGate(fx: *Fx, name: []const u8, kind: []const u8) !void {
        const sub = try std.fmt.allocPrint(fx.arena(), "{s}.{s}.go", .{ name, kind });
        try fx.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "" });
    }

    /// Waits (bounded) until a gated start of `kind` for wrapper `name` waits at its gate.
    fn waitAtGate(fx: *Fx, name: []const u8, kind: []const u8) !void {
        const sub = try std.fmt.allocPrint(fx.arena(), "{s}.{s}.waiting", .{ name, kind });
        const t0 = std.Io.Clock.awake.now(io);
        while (true) {
            if (fx.tmp.dir.access(io, sub, .{})) |_| return else |_| {}
            if (t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > build_wait_ms) return error.Timeout;
            try io.sleep(.fromMilliseconds(5), .awake);
        }
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
    // The gate keeps the first build running while the requests arrive.
    const zig = try fx.wrapper("gatezig", "0.17.0", true, false);

    var counter: Counter = .{};
    var cfg = fx.config(zig);
    cfg.on_outcome = Counter.onOutcome;
    cfg.on_outcome_ctx = &counter;
    const svc = try BuildService.init(testing.allocator, io, cfg);
    defer svc.deinit();

    svc.request(.open);
    try fx.waitAtGate("gatezig", "full");
    for (0..10) |_| svc.request(.save);
    try fx.openGate("gatezig", "full");
    try svc.waitIdle(build_wait_ms);

    // Ten requests during one build gave exactly one follow-up build. (The
    // service has one build thread, so `updates_max == 1` holds by
    // construction; it is checked as a guard against a future second path.)
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
    // Only the incremental server waits at a gate, so warm-up lasts until the test says.
    const zig = try fx.wrapper("gatezig", "0.17.0", false, true);

    const svc = try BuildService.init(testing.allocator, io, fx.config(zig));
    defer svc.deinit();
    const o1 = try build(svc, .open);
    try expectOk(o1);

    // Warm-up is inside its update (holding the server) when the save comes.
    try fx.waitAtGate("gatezig", "incremental");
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);
    try fx.write("a.zig", try scriptSource(fx.arena(), 2));
    const o2 = try build(svc, .save);
    try expectOk(o2);
    // The save did not wait for warm-up: warm-up cannot end before the gate opens.
    try testing.expectEqual(service.BuildPath.full, o2.path);
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);
    try testing.expectEqual(@as(i32, 2), try callValue(o2));

    // Warm-up ends and the next save is incremental.
    try fx.openGate("gatezig", "incremental");
    try svc.waitWarm(build_wait_ms);
    try fx.write("a.zig", try scriptSource(fx.arena(), 3));
    const o3 = try build(svc, .save);
    try expectOk(o3);
    try testing.expectEqual(service.BuildPath.incremental, o3.path);
    try testing.expectEqual(@as(i32, 3), try callValue(o3));
}

fn genEntries(fx: *Fx) ![]const []const u8 {
    const a = fx.arena();
    var names: std.ArrayList([]const u8) = .empty;
    const gen_root = try std.fs.path.join(a, &.{ fx.store, "gen" });
    var d = std.Io.Dir.cwd().openDir(io, gen_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.items,
        else => return err,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| try names.append(a, try a.dupe(u8, e.name));
    return names.items;
}

test "integration: two_services_one_project" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // The gate keeps the first service inside its build (holding build.lock)
    // until the second one has given up.
    const zig = try fx.wrapper("gatezig", "0.17.0", true, false);

    const first = try BuildService.init(testing.allocator, io, fx.config(zig));
    defer first.deinit();
    var cfg2 = fx.config(zig);
    cfg2.lock_timeout_ms = 500;
    const second = try BuildService.init(testing.allocator, io, cfg2);
    defer second.deinit();

    first.request(.open);
    try fx.waitAtGate("gatezig", "full");
    const o2 = try build(second, .open);
    try testing.expectEqual(@as(u32, 1), first.stats().updates_active);

    try testing.expect(!o2.ok);
    try testing.expect(o2.generation == null);
    const a = fx.arena();
    const cache_root = try fx.paths().dir(.cache, a);
    const id = fx.paths().projectId();
    const lock_path = try std.fs.path.join(a, &.{ cache_root.bytes, "projects", &id, "build.lock" });
    const want = try std.fmt.allocPrint(a, "Another editor is building this project (lock: {s}).", .{lock_path});
    try testing.expectEqualStrings(want, o2.message.?);

    try fx.openGate("gatezig", "full");
    try first.waitIdle(build_wait_ms);
    const o1 = first.last().?;
    try expectOk(o1);
    try testing.expectEqual(@as(u32, 1), o1.generation.?.n);
    // Only the first service staged: exactly one generation, and the second
    // service ran one build that kept no generation.
    const gens = try genEntries(&fx);
    try testing.expectEqual(@as(usize, 1), gens.len);
    try testing.expectEqualStrings("1", gens[0]);
    try testing.expectEqual(@as(u32, 1), second.stats().builds);
    try testing.expect(second.last().?.generation == null);
}

test "integration: two_services_both_warm" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));

    const one = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer one.deinit();
    const two = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer two.deinit();
    const svcs = [_]*BuildService{ one, two };

    one.request(.open);
    two.request(.open);
    for (svcs) |svc| {
        try svc.waitIdle(build_wait_ms);
        try expectOk(svc.last().?);
    }
    // Exactly one service gets incremental.lock and warms; the other stays on
    // the full path without a crash or a counted death.
    var warm_count: u32 = 0;
    for (svcs) |svc| {
        if (svc.waitWarm(build_wait_ms)) |_| {
            warm_count += 1;
        } else |err| try testing.expectEqual(error.NotWarm, err);
    }
    try testing.expectEqual(@as(u32, 1), warm_count);

    var value: i32 = 1;
    for (0..2) |_| {
        for (svcs) |svc| {
            value += 1;
            try fx.write("a.zig", try scriptSource(fx.arena(), value));
            const o = try build(svc, .save);
            try expectOk(o);
            try testing.expectEqual(value, try callValue(o));
            const want_path: service.BuildPath = if (svc.stats().warm == .ready) .incremental else .full;
            try testing.expectEqual(want_path, o.path);
        }
    }
    var ready: u32 = 0;
    for (svcs) |svc| {
        const st = svc.stats();
        try testing.expectEqual(@as(u32, 0), st.session_deaths);
        if (st.warm == .ready) ready += 1;
    }
    try testing.expectEqual(@as(u32, 1), ready);
}

test "integration: e2e_bad_zig" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    const zig = try fx.wrapper("oldzig", "0.16.0", false, false);

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
    try testing.expectEqual(@as(u32, 0), service.liveThreads());
    try expectThreadGone(counter.tid.load(.acquire));
}

/// On Linux, checks that the thread `tid` no longer exists.
fn expectThreadGone(tid: u64) !void {
    if (builtin.os.tag != .linux) return;
    try testing.expect(tid != 0);
    var buf: [64]u8 = undefined;
    const task = try std.fmt.bufPrint(&buf, "/proc/self/task/{d}", .{tid});
    // The kernel removes the task entry right after the thread exits.
    const t0 = std.Io.Clock.awake.now(io);
    while (true) {
        std.Io.Dir.cwd().access(io, task, .{}) catch |err| {
            try testing.expectEqual(error.FileNotFound, err);
            return;
        };
        if (t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() > 1000) return error.ThreadStillRunning;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "integration: deinit stops a running build" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // The gate is never opened.
    const zig = try fx.wrapper("gatezig", "0.17.0", true, true);

    var counter: Counter = .{};
    var cfg = fx.config(zig);
    cfg.on_outcome = Counter.onOutcome;
    cfg.on_outcome_ctx = &counter;
    const svc = try BuildService.init(testing.allocator, io, cfg);
    svc.request(.open);
    try fx.waitAtGate("gatezig", "full");
    const t0 = std.Io.Clock.awake.now(io);
    svc.deinit();
    // The compiler group was killed instead of waited for.
    try testing.expect(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 10_000);
    try testing.expectEqual(@as(u32, 0), service.liveThreads());
    // A build cut short by deinit reports nothing.
    try testing.expectEqual(@as(u32, 0), counter.calls.load(.acquire));
}

test "integration: deinit while warming" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // Full builds run; the incremental server's gate is never opened.
    const zig = try fx.wrapper("gatezig", "0.17.0", false, true);

    var counter: Counter = .{};
    var cfg = fx.config(zig);
    cfg.on_outcome = Counter.onOutcome;
    cfg.on_outcome_ctx = &counter;
    const svc = try BuildService.init(testing.allocator, io, cfg);
    const o = try build(svc, .open);
    try expectOk(o);
    try fx.waitAtGate("gatezig", "incremental");
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);

    const t0 = std.Io.Clock.awake.now(io);
    svc.deinit();
    try testing.expect(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 10_000);
    try testing.expectEqual(@as(u32, 0), service.liveThreads());
    try testing.expectEqual(@as(u32, 1), counter.calls.load(.acquire));
    try expectThreadGone(counter.tid.load(.acquire));
}

fn incrementalLockPath(fx: *Fx) ![]const u8 {
    const a = fx.arena();
    const cache_root = try fx.paths().dir(.cache, a);
    const id = fx.paths().projectId();
    return std.fs.path.join(a, &.{ cache_root.bytes, "projects", &id, service.incremental_lock_name });
}

fn expectIncrementalLockFree(fx: *Fx) !void {
    var l = try platform.lock.FileLock.acquire(io, .fromTrusted(try incrementalLockPath(fx)), .exclusive, 0);
    l.release();
}

fn expectIncrementalLockBusy(fx: *Fx) !void {
    try testing.expectError(error.Timeout, platform.lock.FileLock.acquire(io, .fromTrusted(try incrementalLockPath(fx)), .exclusive, 0));
}

test "integration: warm server restarts when the source root moves" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    // Root ignores file modes.
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    // The scripts sit in a sub folder that stays writable, so the test can edit them.
    const rel = "game/s.zig";
    try fx.write(rel, try scriptSource(fx.arena(), 1));
    const proj_z = try fx.arena().dupeSentinel(u8, fx.project, 0);
    defer _ = std.c.chmod(proj_z, 0o755);

    var live = true;
    const svc = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer if (live) svc.deinit();
    try expectOk(try build(svc, .open));
    try svc.waitWarm(build_wait_ms);
    try expectIncrementalLockBusy(&fx);

    var value: i32 = 1;
    for (0..4) |i| {
        // Switch between read-only (mirror) and writable (project folder).
        // A new script changes the generated root, so the read-only probe
        // runs; the folder mode alone does not move the source root.
        try testing.expectEqual(@as(c_int, 0), std.c.chmod(proj_z, if (i % 2 == 0) 0o555 else 0o755));
        try fx.write(try std.fmt.allocPrint(fx.arena(), "game/extra{d}.zig", .{i}), "pub const extends = \"Node\";\n");
        value += 1;
        try fx.write(rel, try scriptSource(fx.arena(), value));
        // The warm server compiles the old root: it is ended (not a death)
        // and the save takes the full path.
        const o1 = try build(svc, .save);
        try expectOk(o1);
        try testing.expectEqual(service.BuildPath.full, o1.path);
        try testing.expectEqual(value, try callValue(o1));
        // A new server warms for the new root, and the next saves use it.
        try svc.waitWarm(build_wait_ms);
        for (0..2) |_| {
            value += 1;
            try fx.write(rel, try scriptSource(fx.arena(), value));
            const o2 = try build(svc, .save);
            try expectOk(o2);
            try testing.expectEqual(service.BuildPath.incremental, o2.path);
            try testing.expectEqual(value, try callValue(o2));
        }
        try testing.expectEqual(@as(u32, 0), svc.stats().session_deaths);
    }
    try testing.expectEqual(@as(u32, 1 + 4 * 3), svc.stats().builds);
    live = false;
    svc.deinit();
    try expectIncrementalLockFree(&fx);
}

const lost_lock_message = "Fast rebuilds are off for this session: another editor is using fast rebuilds for this project. Builds still work but are slower.";
const lost_died_message = "Fast rebuilds are off for this session: the Zig compiler server stopped twice. Builds still work but are slower.";

test "integration: lost fast path is reported once when another editor holds the server lock" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));

    // Another editor's incremental server owns this project's cache.
    const lock_path = try incrementalLockPath(&fx);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(lock_path).?);
    var other = try platform.lock.FileLock.acquire(io, .fromTrusted(lock_path), .exclusive, 0);
    defer other.release();

    const svc = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer svc.deinit();
    const o1 = try build(svc, .open);
    try expectOk(o1);
    try testing.expect(o1.message == null);
    try testing.expectError(error.NotWarm, svc.waitWarm(build_wait_ms));

    try fx.write("a.zig", try scriptSource(fx.arena(), 2));
    const o2 = try build(svc, .save);
    try expectOk(o2);
    try testing.expectEqual(service.BuildPath.full, o2.path);
    try testing.expectEqualStrings(lost_lock_message, o2.message.?);
    try testing.expectEqual(@as(i32, 2), try callValue(o2));

    // Told once: the next full build (the lock is still taken) says nothing.
    try testing.expectError(error.NotWarm, svc.waitWarm(build_wait_ms));
    try fx.write("a.zig", try scriptSource(fx.arena(), 3));
    const o3 = try build(svc, .save);
    try expectOk(o3);
    try testing.expect(o3.message == null);
    try testing.expectEqual(@as(u32, 0), svc.stats().session_deaths);
}

test "integration: lost fast path is reported once after the second server death" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));

    // A compiler whose incremental server always dies at once.
    const a = fx.arena();
    const text = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\if [ "$1" = version ]; then echo '0.17.0'; exit 0; fi
        \\case " $* " in *" -fincremental "*) exit 3 ;; esac
        \\exec '{s}' "$@"
        \\
    , .{build_options.zig_exe});
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "diezig", .data = text });
    const zig = try std.fs.path.joinZ(a, &.{ fx.base, "diezig" });
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(zig, 0o755));

    const svc = try BuildService.init(testing.allocator, io, fx.config(zig));
    defer svc.deinit();
    const o1 = try build(svc, .open);
    try expectOk(o1);
    try testing.expectError(error.NotWarm, svc.waitWarm(build_wait_ms));
    try testing.expectEqual(@as(u32, 1), svc.stats().session_deaths);

    // The first death is not reported: the service warms again.
    const o2 = try build(svc, .save);
    try expectOk(o2);
    try testing.expect(o2.message == null);
    try testing.expectError(error.NotWarm, svc.waitWarm(build_wait_ms));
    try testing.expectEqual(@as(u32, 2), svc.stats().session_deaths);
    try testing.expectEqual(service.WarmState.disabled, svc.stats().warm);

    const o3 = try build(svc, .save);
    try expectOk(o3);
    try testing.expectEqual(service.BuildPath.full, o3.path);
    try testing.expectEqualStrings(lost_died_message, o3.message.?);

    const o4 = try build(svc, .save);
    try expectOk(o4);
    try testing.expect(o4.message == null);
}
