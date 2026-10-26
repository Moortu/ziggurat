//! End-to-end tests for Stage 1: the build service driving the real Zig
//! compiler on generated projects with the stub SDK, and (Stage 6) the
//! export build with the real SDK and the export host archive. Every test
//! here spawns the compiler, so all are `integration:` tests.
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

    fn onOutcome(ctx: ?*anyopaque, o: *Outcome) void {
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

test "integration: a helper three references deep is mapped to the script line" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    const a = fx.arena();
    // An SDK outside the project: the stub SDK and a withheld helper that
    // only code three calls deep in the SDK names, so the reference trace
    // reaches the script only at its fourth frame.
    const stub = try std.Io.Dir.cwd().readFileAlloc(io, build_options.stub_sdk_path, a, .limited(1 << 20));
    try fx.tmp.dir.createDirPath(io, "sdk");
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "sdk/ziggurat.zig", .data = try std.mem.concat(a, u8, &.{
        stub,
        \\
        \\pub const deep = struct {
        \\    pub const Bad = struct {
        \\        pub const helper = @compileError("ziggurat: helper is not available in scripts");
        \\    };
        \\    pub fn one(comptime T: type) void {
        \\        two(T);
        \\    }
        \\    fn two(comptime T: type) void {
        \\        three(T);
        \\    }
        \\    fn three(comptime T: type) void {
        \\        _ = T.helper;
        \\    }
        \\};
        \\
    }) });
    const sdk_root = try std.fs.path.join(a, &.{ fx.base, "sdk", "ziggurat.zig" });
    fx.sdk = try a.dupe(zbuild.workspace.ModuleDep, &.{.{ .name = "ziggurat", .root = .fromTrusted(sdk_root), .deps = &.{} }});
    try fx.write("a.zig",
        \\const z = @import("ziggurat");
        \\pub const extends = "Node";
        \\export fn e2e_value() i32 {
        \\    z.deep.one(z.deep.Bad);
        \\    return 1;
        \\}
        \\
    );

    const svc = try BuildService.init(testing.allocator, io, fx.config(build_options.zig_exe));
    defer svc.deinit();
    const o = try build(svc, .open);
    try testing.expect(!o.ok);
    for (o.diagnostics) |d| {
        if (std.mem.indexOf(u8, d.message, "helper is not available") == null) continue;
        errdefer std.debug.print("diagnostic: {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        try testing.expectEqualStrings("a.zig", d.rel orelse return error.HelperNotInScript);
        try testing.expectEqual(@as(u32, 4), d.line);
        break;
    } else {
        for (o.diagnostics) |d| std.debug.print("  {?s}:{d}: {s}\n", .{ d.rel, d.line, d.message });
        return error.HelperNotReported;
    }
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

test "integration: debugger builds: toggling drops the warm server and brings it back" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    var fx: Fx = undefined;
    try fx.init("proj");
    defer fx.deinit();
    try fx.write("a.zig", try scriptSource(fx.arena(), 1));
    // The incremental server waits at its gate until the test opens it.
    const zig = try fx.wrapper("gatezig", "0.17.0", false, true);
    const svc = try BuildService.init(testing.allocator, io, fx.config(zig));
    defer svc.deinit();

    const o1 = try build(svc, .open);
    try expectOk(o1);
    try fx.waitAtGate("gatezig", "incremental");
    try testing.expectEqual(service.WarmState.warming, svc.stats().warm);

    // On while the server warms up: the next build drops it (not a death)
    // and builds with LLVM; no server warms up again.
    svc.setPolicy(null, true);
    try fx.write("a.zig", try scriptSource(fx.arena(), 2));
    const o2 = try build(svc, .save);
    try expectOk(o2);
    try testing.expectEqual(service.BuildPath.full, o2.path);
    try testing.expectEqual(@as(i32, 2), try callValue(o2));
    try testing.expectEqual(service.WarmState.disabled, svc.stats().warm);
    try testing.expectEqual(@as(u32, 0), svc.stats().session_deaths);
    try expectIncrementalLockFree(&fx);

    // Off: the next build is a full self-hosted one and warms a server again.
    try fx.openGate("gatezig", "incremental");
    svc.setPolicy(null, false);
    try fx.write("a.zig", try scriptSource(fx.arena(), 3));
    const o3 = try build(svc, .save);
    try expectOk(o3);
    try testing.expectEqual(service.BuildPath.full, o3.path);
    try testing.expectEqual(@as(i32, 3), try callValue(o3));
    try svc.waitWarm(build_wait_ms);
    try fx.write("a.zig", try scriptSource(fx.arena(), 4));
    const o4 = try build(svc, .save);
    try expectOk(o4);
    try testing.expectEqual(service.BuildPath.incremental, o4.path);
    try testing.expectEqual(@as(i32, 4), try callValue(o4));

    // On again with a ready server: it is stopped at the next build.
    svc.setPolicy(null, true);
    try fx.write("a.zig", try scriptSource(fx.arena(), 5));
    const o5 = try build(svc, .save);
    try expectOk(o5);
    try testing.expectEqual(service.BuildPath.full, o5.path);
    try testing.expectEqual(@as(i32, 5), try callValue(o5));
    try testing.expectEqual(service.WarmState.disabled, svc.stats().warm);
    try testing.expectEqual(@as(u32, 0), svc.stats().session_deaths);
    try expectIncrementalLockFree(&fx);
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

const lost_lock_message = "Fast rebuilds are paused: another editor is using them for this project. Builds still work but are slower.";
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

// ------------------------------------------------ export build (Stage 6)
//
// `export_build.run` compiling a project against the real SDK (module list
// from the SDK manifest) and linking it with the export host archive
// (`zig build host-archive`), as an exported game's library.

const export_build = zbuild.export_build;

const alpha_source =
    \\const z = @import("ziggurat");
    \\const g = z.godot;
    \\
    \\pub const extends = g.Node2D;
    \\
    \\base: *g.Node2D,
    \\speed: f32 = 3,
    \\
    \\pub fn _ready(self: *@This()) void {
    \\    z.log(.info, "alpha ready speed={d}", .{self.speed});
    \\}
    \\
;

const beta_source =
    \\const z = @import("ziggurat");
    \\const g = z.godot;
    \\
    \\pub const extends = g.Node;
    \\
    \\base: *g.Node,
    \\
    \\pub fn _ready(_: *@This()) void {
    \\    z.log(.info, "beta ready", .{});
    \\}
    \\
;

/// Temporary projects, one cache and the SDK manifest for export builds.
const ExportFx = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    base: []const u8,
    cache: []const u8,
    manifest: zbuild.sdk_manifest.Manifest,
    archive: []const u8,

    fn init(fx: *ExportFx) !void {
        fx.arena_state = .init(testing.allocator);
        errdefer fx.arena_state.deinit();
        const a = fx.arena_state.allocator();
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(testing.allocator);
        const manifest_path = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.sdk_manifest_path, a);
        fx.manifest = zbuild.sdk_manifest.load(testing.allocator, io, .fromTrusted(manifest_path), &msg) catch |err| {
            std.debug.print("manifest: {s}\n", .{msg.items});
            return err;
        };
        errdefer fx.manifest.deinit(testing.allocator);
        fx.archive = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.export_host_archive, a);
        fx.tmp = testing.tmpDir(.{});
        errdefer fx.tmp.cleanup();
        try fx.tmp.dir.createDirPath(io, "cache");
        fx.base = try fx.tmp.dir.realPathFileAlloc(io, ".", a);
        fx.cache = try fx.tmp.dir.realPathFileAlloc(io, "cache", a);
    }

    fn deinit(fx: *ExportFx) void {
        fx.tmp.cleanup();
        fx.manifest.deinit(testing.allocator);
        fx.arena_state.deinit();
    }

    /// Creates project folder `sub` (relative to the temp folder) holding
    /// `files`; returns its absolute path.
    fn project(fx: *ExportFx, sub: []const u8, files: []const File) ![]const u8 {
        const a = fx.arena_state.allocator();
        try fx.tmp.dir.createDirPath(io, sub);
        var d = try fx.tmp.dir.openDir(io, sub, .{});
        defer d.close(io);
        for (files) |f| {
            if (std.fs.path.dirname(f.rel)) |p| try d.createDirPath(io, p);
            try d.writeFile(io, .{ .sub_path = f.rel, .data = f.data });
        }
        return fx.tmp.dir.realPathFileAlloc(io, sub, a);
    }

    fn options(fx: *ExportFx, project_root: []const u8, out_path: []const u8) export_build.Options {
        return .{
            .zig = .{ .exe = .fromTrusted(build_options.zig_exe), .version = platform.pins.zig_version },
            .project_root = .fromTrusted(project_root),
            .sdk = fx.manifest.modules,
            .host_archive = .fromTrusted(fx.archive),
            .out_path = .fromTrusted(out_path),
            .cache_dir = .fromTrusted(fx.cache),
        };
    }

    fn out(fx: *ExportFx, name: []const u8) ![]const u8 {
        return std.fs.path.join(fx.arena_state.allocator(), &.{ fx.base, name, export_build.lib_file });
    }

    /// Runs the export build; prints why it failed.
    fn build(fx: *ExportFx, project_root: []const u8, out_path: []const u8) !export_build.Result {
        var diag: [256]u8 = undefined;
        return export_build.run(testing.allocator, io, fx.options(project_root, out_path), &diag) catch |err| {
            std.debug.print("export build error {t}: {s}\n", .{ err, platform.elf.diagText(&diag) });
            return err;
        };
    }
};

const File = struct { rel: []const u8, data: []const u8 };

const two_scripts = [_]File{ .{ .rel = "alpha.zig", .data = alpha_source }, .{ .rel = "sub/beta.zig", .data = beta_source } };

fn expectExportOk(r: export_build.Result) !void {
    if (!r.ok) {
        std.debug.print("export build failed: {?s}\n", .{r.message});
        for (r.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        return error.BuildFailed;
    }
}

fn readAll(p: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, p, testing.allocator, .limited(1 << 30));
}

test "integration: export build links one library" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var fx: ExportFx = undefined;
    try fx.init();
    defer fx.deinit();
    const proj = try fx.project("proj", &two_scripts);
    const out_path = try fx.out("out");
    const r = try fx.build(proj, out_path);
    defer r.deinit(testing.allocator);
    try expectExportOk(r);

    const lib = try readAll(out_path);
    defer testing.allocator.free(lib);
    const syms = try platform.elf.dynamicSymbols(testing.allocator, lib);
    defer testing.allocator.free(syms);
    // Exported (`nm -D --defined-only`): only Godot's entry point. Imported:
    // no dlopen, so nothing is loaded at run time.
    var exported: usize = 0;
    var has_entry = false;
    for (syms) |s| {
        if (s.name.len == 0) continue;
        if (s.defined) {
            exported += 1;
            if (std.mem.eql(u8, s.name, "ziggurat_host_init")) has_entry = true;
            try testing.expect(!std.mem.eql(u8, s.name, "ziggurat_describe"));
            try testing.expect(!std.mem.eql(u8, s.name, "ziggurat_init"));
        } else {
            try testing.expect(!std.mem.eql(u8, s.name, "dlopen"));
        }
    }
    try testing.expect(has_entry);
    try testing.expectEqual(@as(usize, 1), exported);
    // `readelf -V`: no GLIBC version above the pin, and the pin itself is
    // what the template needs, so a library needing it is still fine.
    const vers = try platform.elf.neededVersions(testing.allocator, lib);
    defer testing.allocator.free(vers);
    try testing.expect(vers.len > 0);
    if (export_build.glibcAbove(vers, platform.pins.export_glibc)) |v| {
        std.debug.print("the library needs {s}\n", .{v});
        return error.GlibcTooNew;
    }
}

test "integration: export build two folders give identical bytes" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var fx: ExportFx = undefined;
    try fx.init();
    defer fx.deinit();
    const p1 = try fx.project("one/proj", &two_scripts);
    const p2 = try fx.project("two dir \u{e4}\u{f6}/\u{30d7}\u{30ed} ject", &two_scripts);
    const o1 = try fx.out("one");
    const o2 = try fx.out("two dir \u{e4}\u{f6}");
    const r1 = try fx.build(p1, o1);
    defer r1.deinit(testing.allocator);
    try expectExportOk(r1);
    const r2 = try fx.build(p2, o2);
    defer r2.deinit(testing.allocator);
    try expectExportOk(r2);
    const b1 = try readAll(o1);
    defer testing.allocator.free(b1);
    const b2 = try readAll(o2);
    defer testing.allocator.free(b2);
    try testing.expect(std.mem.eql(u8, b1, b2));
    // No absolute path: neither project's folder, nor the SDK's, nor the
    // compiler's library folder.
    const sdk_dir = std.fs.path.dirname(fx.manifest.modules[0].root.bytes).?;
    for ([_][]const u8{ fx.base, "\u{30d7}\u{30ed}", sdk_dir, "/nix/store/", "/lib/std/" }) |needle| {
        if (std.mem.indexOf(u8, b1, needle) != null) {
            std.debug.print("the library holds '{s}'\n", .{needle});
            return error.AbsolutePathInLibrary;
        }
    }
}

test "integration: export build id is fixed" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var fx: ExportFx = undefined;
    try fx.init();
    defer fx.deinit();
    const proj = try fx.project("proj", &two_scripts);
    const r = try fx.build(proj, try fx.out("out"));
    defer r.deinit(testing.allocator);
    try expectExportOk(r);
    // The root the library was compiled from carries the fixed id, not the
    // scan's (which hashes modification times and inodes).
    const a = fx.arena_state.allocator();
    const root = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ proj, zbuild.rootgen.root_file_name }), a, .limited(1 << 20));
    try testing.expectEqualStrings("export", export_build.build_id);
    try testing.expect(std.mem.indexOf(u8, root, "ziggurat.tableOf(scripts, \"export\");") != null);
    const sc = try zbuild.scan.scan(a, io, .fromTrusted(proj), zbuild.scan.default_script_dirs);
    try testing.expectEqualStrings(try zbuild.rootgen.generateRoot(a, builtin.os.tag, sc.scripts, "export"), root);
}

test "integration: export build broken script fails" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var fx: ExportFx = undefined;
    try fx.init();
    defer fx.deinit();
    const broken =
        \\const z = @import("ziggurat");
        \\pub const extends = z.godot.Node;
        \\base: *z.godot.Node,
        \\pub fn _ready(_: *@This()) void {
        \\    const n: u32 = "not a number";
        \\    _ = n;
        \\}
        \\
    ;
    const proj = try fx.project("proj", &.{ .{ .rel = "alpha.zig", .data = alpha_source }, .{ .rel = "game/broken.zig", .data = broken } });
    const out_path = try fx.out("out");
    const r = try fx.build(proj, out_path);
    defer r.deinit(testing.allocator);
    try testing.expect(!r.ok);
    var found = false;
    for (r.diagnostics) |d| {
        const rel = d.rel orelse continue;
        if (std.mem.eql(u8, rel, "game/broken.zig") and d.line == 5) found = true;
    }
    if (!found) {
        for (r.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        return error.DiagnosticNotMapped;
    }
    // No library is written.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, out_path, .{}));
}

test "integration: export build of a read-only project goes through the mirror" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    // Root ignores file modes.
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    var fx: ExportFx = undefined;
    try fx.init();
    defer fx.deinit();
    const proj = try fx.project("proj", &two_scripts);
    const sub_z = try fx.arena_state.allocator().dupeSentinel(u8, try std.fs.path.join(fx.arena_state.allocator(), &.{ proj, "sub" }), 0);
    const proj_z = try fx.arena_state.allocator().dupeSentinel(u8, proj, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(sub_z, 0o555));
    defer _ = std.c.chmod(sub_z, 0o755);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(proj_z, 0o555));
    defer _ = std.c.chmod(proj_z, 0o755);
    const out_path = try fx.out("out");
    const r = try fx.build(proj, out_path);
    defer r.deinit(testing.allocator);
    try expectExportOk(r);
    try std.Io.Dir.cwd().access(io, out_path, .{});
    // The generated root went to the mirror, not into the project.
    var d = try std.Io.Dir.cwd().openDir(io, proj, .{});
    defer d.close(io);
    try testing.expectError(error.FileNotFound, d.access(io, zbuild.rootgen.root_file_name, .{}));
}

// ------------------------------------------------------------ shipped SDK

/// The staged SDK folder: the one holding `build_options.staged_sdk_manifest`.
fn stagedDir() []const u8 {
    return std.fs.path.dirname(build_options.staged_sdk_manifest) orelse ".";
}

/// Calls `f(ctx, rel, bytes)` for every file of the staged SDK
/// (`stagedDir`), `rel` relative to its folder.
fn eachStagedFile(a: std.mem.Allocator, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, []const u8) anyerror!void) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, stagedDir(), .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try dir.readFileAlloc(io, entry.path, a, .unlimited);
        defer a.free(bytes);
        try f(ctx, entry.path, bytes);
        n += 1;
    }
    return n;
}

/// What the staged SDK must not contain: the real paths of this checkout,
/// its local cache and the global cache, the Nix store, and the names of the cache and package folders.
fn buildMachinePaths(a: std.mem.Allocator) ![]const []const u8 {
    const list = try a.alloc([]const u8, 6);
    const cwd = std.Io.Dir.cwd();
    list[0] = try cwd.realPathFileAlloc(io, build_options.build_machine_repo, a);
    list[1] = try cwd.realPathFileAlloc(io, build_options.build_machine_local_cache, a);
    list[2] = try cwd.realPathFileAlloc(io, build_options.build_machine_global_cache, a);
    list[3] = "/nix/store";
    list[4] = ".zig-cache";
    list[5] = "zig-pkg";
    return list;
}

test "integration: shipped SDK has no absolute paths" {
    try platform.testing_support.requireIntegration();
    const a = testing.allocator;
    const Ctx = struct {
        hits: usize = 0,
        needles: []const []const u8,
        fn check(c: *@This(), rel: []const u8, bytes: []const u8) anyerror!void {
            for (c.needles) |needle| {
                if (std.mem.indexOf(u8, bytes, needle)) |at| {
                    if (c.hits < 10) std.debug.print("{s}: byte {d} holds \"{s}\"\n", .{ rel, at, needle });
                    c.hits += 1;
                }
            }
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    var ctx: Ctx = .{ .needles = try buildMachinePaths(arena_state.allocator()) };
    const n = try eachStagedFile(a, &ctx, Ctx.check);
    try testing.expect(n > 12);
    try testing.expectEqual(@as(usize, 0), ctx.hits);

    // Every module root in the manifest is relative to its folder.
    var dir = try std.Io.Dir.cwd().openDir(io, stagedDir(), .{});
    defer dir.close(io);
    const json = try dir.readFileAlloc(io, "sdk-manifest.json", a, .limited(1 << 20));
    defer a.free(json);
    const Raw = struct { modules: []const struct { name: []const u8, root: []const u8 } };
    const parsed = try std.json.parseFromSlice(Raw, a, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 11), parsed.value.modules.len);
    for (parsed.value.modules) |m| {
        try testing.expect(!std.fs.path.isAbsolute(m.root));
        try testing.expect(std.mem.startsWith(u8, m.root, m.name));
        dir.access(io, m.root, .{}) catch |err| {
            std.debug.print("module {s}: root {s}: {t}\n", .{ m.name, m.root, err });
            return err;
        };
    }
}

test "integration: doc comments stripped" {
    try platform.testing_support.requireIntegration();
    const a = testing.allocator;
    const Ctx = struct {
        gdzig_files: usize = 0,
        doc_lines: usize = 0,
        fn check(c: *@This(), rel: []const u8, bytes: []const u8) anyerror!void {
            if (!std.mem.startsWith(u8, rel, "gdzig" ++ std.fs.path.sep_str)) return;
            c.gdzig_files += 1;
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const t = std.mem.trimStart(u8, line, " \t");
                if (std.mem.startsWith(u8, t, "///") and !std.mem.startsWith(u8, t, "////")) {
                    if (c.doc_lines < 5) std.debug.print("{s}: {s}\n", .{ rel, line });
                    c.doc_lines += 1;
                }
            }
        }
    };
    var ctx: Ctx = .{};
    _ = try eachStagedFile(a, &ctx, Ctx.check);
    try testing.expect(ctx.gdzig_files > 1000);
    try testing.expectEqual(@as(usize, 0), ctx.doc_lines);
    // The editor does not scan or import the SDK folder.
    var dir = try std.Io.Dir.cwd().openDir(io, stagedDir(), .{});
    defer dir.close(io);
    try dir.access(io, ".gdignore", .{});
}
