//! Build service (L2): turns editor triggers into compiles on one background
//! build thread, and stages every clean output as a numbered generation.
//!
//! - Builds run one at a time. A request during a build sets one pending
//!   flag, so any number of requests gives one follow-up build.
//! - The first build of a session is a full one-shot build (a fresh
//!   non-incremental compiler that exits after one update).
//! - After a successful full build, an incremental compiler server starts
//!   warming on its own thread. Warm-up never holds `build.lock` and never
//!   delays a request: a request during warm-up takes the full path at once.
//! - Once the warm-up update finished with 0 errors, requests send `update`
//!   to that server instead. If the server dies, the request falls back to
//!   the full path and warming starts again after the next successful full
//!   build. After the second death, incremental builds stay off for the rest
//!   of the service's life.
//! - A requested build holds `build.lock` from `Workspace.prepare` until it
//!   has staged its output, never for the life of the service.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("ziggurat_platform");
const scan_mod = @import("scan.zig");
const workspace = @import("workspace.zig");
const compiler = @import("compiler.zig");
const diagnostics = @import("diagnostics.zig");
const backend = @import("backend.zig");

const OsPath = platform.path.OsPath;
const PathService = platform.path.PathService;
const ZigInstall = platform.zig_locator.ZigInstall;
const GenerationStore = platform.generation_store.GenerationStore;
pub const Generation = platform.generation_store.Generation;
pub const Diagnostic = diagnostics.Diagnostic;
pub const BuildMode = workspace.BuildMode;
const Session = compiler.Session;

pub const Trigger = enum { open, save, play, manual, watcher };

/// Which compiler served a build.
pub const BuildPath = enum { full, incremental };

/// The result of one requested build. All slices and paths are owned by the
/// service; see `Config.on_outcome` and `BuildService.last` for how long.
pub const Outcome = struct {
    trigger: Trigger,
    /// True when a new generation was staged.
    ok: bool,
    generation: ?Generation,
    /// Compile errors, then scan problems (those have line 0 and do not by
    /// themselves make the build fail).
    diagnostics: []Diagnostic,
    /// One sentence for the user when the build failed for a reason other
    /// than compile errors: the Zig locator's message, the `build.lock`
    /// message, the compiler's last output when it died, a staging failure.
    message: ?[]const u8,
    path: BuildPath,
    /// Wall time of the whole build, from start to staged output.
    ms: u64,
};

pub const WarmState = enum {
    /// No incremental server; the next successful full build starts one.
    cold,
    warming,
    /// The warm-up update finished with 0 errors; requests use the server.
    ready,
    /// The server died twice, or the policy has no incremental mode.
    disabled,
};

pub const Stats = struct {
    /// Builds started.
    builds: u32,
    /// Requested-build compiler processes running now (warm-up not counted).
    updates_active: u32,
    /// Highest `updates_active` seen.
    updates_max: u32,
    warm: WarmState,
    session_deaths: u32,
};

/// File stem of the staged library (`--name zmod` in `Workspace.argv`).
pub const lib_stem = "zmod";

/// Threads of any `BuildService` that are running now. `deinit` joins all of
/// them, so this is 0 once every service is gone (tests check it).
pub var live_threads: std.atomic.Value(u32) = .init(0);

/// Everything is borrowed: the slices and paths must outlive the service.
pub const Config = struct {
    paths: PathService,
    locate: platform.zig_locator.LocateConfig,
    script_dirs: []const []const u8 = scan_mod.default_script_dirs,
    sdk: []const workspace.ModuleDep,
    store_root: OsPath,
    caps: platform.generation_store.Caps = .{},
    target: std.Target = builtin.target,
    /// Replaces the backend policy table in every phase.
    policy_override: ?BuildMode = null,
    /// How long a build waits for another editor's `build.lock` (ruling P3).
    lock_timeout_ms: u32 = 30000,
    /// Longest single compiler update before the compiler is killed.
    update_timeout_ms: u32 = 600000,
    /// Called on the build thread after each build (not for a build cut short
    /// by `deinit`). The pointer is valid only during the call.
    on_outcome: ?*const fn (ctx: ?*anyopaque, o: *const Outcome) void = null,
    on_outcome_ctx: ?*anyopaque = null,
};

const Timer = struct {
    t0: std.Io.Timestamp,
    io: std.Io,

    fn start(io: std.Io) Timer {
        return .{ .t0 = std.Io.Clock.awake.now(io), .io = io };
    }

    fn ms(self: Timer) u64 {
        const d = self.t0.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
        return @intCast(@max(d, 0));
    }
};

/// What the warm thread needs; owned by the thread.
const WarmJob = struct {
    argv: []const []const u8,
    cwd: OsPath,

    fn deinit(job: WarmJob, a: std.mem.Allocator) void {
        workspace.Workspace.freeArgv(a, job.argv);
        a.free(job.cwd.bytes);
    }
};

pub const BuildService = struct {
    a: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    store: GenerationStore,
    /// Used by the build thread only.
    zig: ?ZigInstall = null,

    /// Guards every field below up to `session_mu`. Held only briefly, so
    /// `request` never waits for a build.
    mu: std.Io.Mutex = .init,
    /// Broadcast on every change of the fields below.
    cond: std.Io.Condition = .init,
    pending: ?Trigger = null,
    building: bool = false,
    stopping: bool = false,
    warm: WarmState = .cold,
    deaths: u32 = 0,
    builds: u32 = 0,
    updates_active: u32 = 0,
    updates_max: u32 = 0,
    last_outcome: ?Outcome = null,
    /// The running full one-shot compiler, so `deinit` can kill it.
    full_slot: ?Session = null,
    /// The incremental server, from the start of warm-up until it dies or
    /// the service ends.
    warm_slot: ?Session = null,

    /// Held while a thread uses the incremental server, so the warm and the
    /// build thread never use it at once. Lock order: `session_mu`, then `mu`.
    session_mu: std.Io.Mutex = .init,

    build_thread: ?std.Thread = null,
    /// Spawned by the build thread only; joined by it or by `deinit`.
    warm_thread: ?std.Thread = null,

    /// Starts the build thread. `a` must be thread-safe. Nothing is built
    /// until the first `request`.
    pub fn init(a: std.mem.Allocator, io: std.Io, cfg: Config) !*BuildService {
        const self = try a.create(BuildService);
        errdefer a.destroy(self);
        self.* = .{
            .a = a,
            .io = io,
            .cfg = cfg,
            .store = GenerationStore.init(a, io, cfg.store_root, cfg.target.os.tag, lib_stem, cfg.caps),
        };
        self.build_thread = try spawn(buildMain, .{self});
        return self;
    }

    /// Asks for a build. Safe from any thread; never waits for a build.
    pub fn request(self: *BuildService, t: Trigger) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping) return;
        self.pending = t;
        self.cond.broadcast(self.io);
    }

    /// Waits until no build runs and none is pending. Warm-up is not waited for.
    pub fn waitIdle(self: *BuildService, timeout_ms: u32) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const timer = Timer.start(self.io);
        while (self.building or self.pending != null) try self.waitLocked(timer, timeout_ms);
    }

    /// Waits while the incremental server warms up. `error.NotWarm` when it
    /// ends in any state other than `ready` (also when no warm-up was started).
    pub fn waitWarm(self: *BuildService, timeout_ms: u32) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const timer = Timer.start(self.io);
        while (self.warm == .warming) try self.waitLocked(timer, timeout_ms);
        if (self.warm != .ready) return error.NotWarm;
    }

    fn waitLocked(self: *BuildService, timer: Timer, timeout_ms: u32) !void {
        const spent = timer.ms();
        if (spent >= timeout_ms) return error.Timeout;
        const left: i64 = @intCast(timeout_ms - spent);
        self.cond.waitTimeout(self.io, &self.mu, .{ .duration = .{
            .raw = .fromMilliseconds(left),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }

    /// A copy of the latest outcome. Its slices stay valid until the next
    /// outcome is published or `deinit`; copy what must live longer.
    pub fn last(self: *BuildService) ?Outcome {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.last_outcome;
    }

    pub fn stats(self: *BuildService) Stats {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return .{
            .builds = self.builds,
            .updates_active = self.updates_active,
            .updates_max = self.updates_max,
            .warm = self.warm,
            .session_deaths = self.deaths,
        };
    }

    /// Stops both threads (a running compiler is killed, a build waiting for
    /// `build.lock` gives up within about 250 ms), joins them and frees
    /// everything. After it returns no thread of the service remains.
    pub fn deinit(self: *BuildService) void {
        const io = self.io;
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            self.stopping = true;
            if (self.full_slot) |s| s.interrupt();
            if (self.warm_slot) |s| s.interrupt();
            self.cond.broadcast(io);
        }
        if (self.build_thread) |t| t.join();
        if (self.warm_thread) |t| t.join();
        if (self.warm_slot) |*s| s.deinit();
        if (self.full_slot) |*s| s.deinit();
        if (self.zig) |z| z.deinit(self.a);
        if (self.last_outcome) |o| freeOutcome(self.a, o);
        self.a.destroy(self);
    }

    // ------------------------------------------------------------ build thread

    fn buildMain(self: *BuildService) void {
        defer _ = live_threads.fetchSub(1, .release);
        const io = self.io;
        while (true) {
            const t: Trigger = blk: {
                self.mu.lockUncancelable(io);
                defer self.mu.unlock(io);
                while (self.pending == null and !self.stopping) self.cond.waitUncancelable(io, &self.mu);
                if (self.stopping) return;
                const t = self.pending.?;
                self.pending = null;
                self.building = true;
                self.builds += 1;
                break :blk t;
            };
            const o = self.runBuild(t);
            self.publish(o);
        }
    }

    fn publish(self: *BuildService, o: Outcome) void {
        const io = self.io;
        const keep = blk: {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            break :blk !self.stopping;
        };
        if (keep) {
            if (self.cfg.on_outcome) |f| f(self.cfg.on_outcome_ctx, &o);
        }
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (keep) {
            if (self.last_outcome) |old| freeOutcome(self.a, old);
            self.last_outcome = o;
        } else {
            freeOutcome(self.a, o);
        }
        self.building = false;
        self.cond.broadcast(io);
    }

    fn runBuild(self: *BuildService, t: Trigger) Outcome {
        const timer = Timer.start(self.io);
        var o: Outcome = .{
            .trigger = t,
            .ok = false,
            .generation = null,
            .diagnostics = &.{},
            .message = null,
            .path = .full,
            .ms = 0,
        };
        self.buildInner(&o) catch |err| {
            o.ok = false;
            if (o.message == null) o.message = std.fmt.allocPrint(self.a, "The build of {s} failed: {t}.", .{
                self.cfg.paths.roots.project.bytes, err,
            }) catch null;
        };
        o.ms = timer.ms();
        return o;
    }

    fn buildInner(self: *BuildService, o: *Outcome) !void {
        const a = self.a;
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const zig = try self.locateZig(o);
        const project = self.cfg.paths.roots.project;
        const sc = scan_mod.scan(arena, self.io, project, self.cfg.script_dirs) catch |err| {
            o.message = try std.fmt.allocPrint(a, "Scanning the project folder {s} failed: {t}.", .{ project.bytes, err });
            return err;
        };
        var ws = try self.prepareWorkspace(sc, o);
        defer ws.deinit(a);

        if (try self.incrementalBuild(&ws, o)) {
            // TODO(Stage 2 and Stage 4): after an incremental update, compare each
            // script's layout hash in the output's tables with the sources (spec section 5).
        } else {
            o.path = .full;
            try self.fullBuild(arena, &ws, zig, o);
            if (o.ok) self.startWarm(&ws, zig);
        }
        try appendProblems(a, o, sc.problems);
    }

    fn locateZig(self: *BuildService, o: *Outcome) !ZigInstall {
        if (self.zig) |z| return z;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.a);
        const z = platform.zig_locator.locate(self.a, self.io, self.cfg.locate, &msg) catch |err| {
            if (err == error.ZigNotUsable) o.message = try self.a.dupe(u8, msg.items);
            return err;
        };
        self.zig = z;
        return z;
    }

    /// `Workspace.prepare`, waiting for `build.lock` in short slices so that
    /// `deinit` does not have to wait for the whole lock timeout.
    fn prepareWorkspace(self: *BuildService, sc: scan_mod.ScanResult, o: *Outcome) !workspace.Workspace {
        const a = self.a;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(a);
        const timer = Timer.start(self.io);
        while (true) {
            const left: u32 = @intCast(self.cfg.lock_timeout_ms -| @min(timer.ms(), self.cfg.lock_timeout_ms));
            const slice = @min(left, 250);
            if (workspace.prepare(a, self.io, self.cfg.paths, sc, self.cfg.sdk, .{ .lock_timeout_ms = slice }, &msg)) |ws| {
                return ws;
            } else |err| {
                if (err == error.Timeout) {
                    if (self.isStopping()) return error.Stopping;
                    if (left > slice) continue;
                    o.message = try a.dupe(u8, msg.items);
                } else {
                    o.message = try std.fmt.allocPrint(a, "Preparing the build folder for {s} failed: {t}.", .{
                        self.cfg.paths.roots.project.bytes, err,
                    });
                }
                return err;
            }
        }
    }

    fn isStopping(self: *BuildService) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.stopping;
    }

    fn beginUpdate(self: *BuildService) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.updates_active += 1;
        self.updates_max = @max(self.updates_max, self.updates_active);
    }

    fn endUpdate(self: *BuildService) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.updates_active -= 1;
    }

    /// Puts `s` in `slot` unless the service is stopping (then false).
    fn register(self: *BuildService, slot: *?Session, s: Session) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping) return false;
        slot.* = s;
        return true;
    }

    fn unregister(self: *BuildService, slot: *?Session) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        slot.* = null;
    }

    /// A fresh non-incremental compiler for one update; it exits afterwards.
    fn fullBuild(self: *BuildService, arena: std.mem.Allocator, ws: *const workspace.Workspace, zig: ZigInstall, o: *Outcome) !void {
        const a = self.a;
        const mode = backend.policy(self.cfg.target, .session_start, self.cfg.policy_override);
        const argv = try ws.argv(arena, zig, mode);
        self.beginUpdate();
        defer self.endUpdate();
        var s = Session.start(a, self.io, argv, ws.build_dir) catch |err| {
            o.message = try std.fmt.allocPrint(a, "Starting the Zig compiler {s} failed: {t}.", .{ zig.exe.bytes, err });
            return err;
        };
        if (!self.register(&self.full_slot, s)) {
            s.deinit();
            return error.Stopping;
        }
        defer {
            self.unregister(&self.full_slot);
            s.deinit();
        }
        self.runUpdate(&s, ws, o) catch |err| switch (err) {
            error.Timeout, error.CompilerDied => {
                o.message = try self.diedMessage(s, err);
                return err;
            },
            else => return err,
        };
    }

    /// Serves the request with the warm incremental server. False when there
    /// is none or it died (the caller then takes the full path).
    fn incrementalBuild(self: *BuildService, ws: *const workspace.Workspace, o: *Outcome) !bool {
        const io = self.io;
        // Check before taking `session_mu`: the warm thread holds it for the
        // whole warm-up update, and a request must not wait for that.
        if (self.warmState() != .ready) return false;
        self.session_mu.lockUncancelable(io);
        defer self.session_mu.unlock(io);
        const s0: Session = blk: {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (self.warm != .ready) return false;
            break :blk self.warm_slot orelse return false;
        };
        var s = s0;
        o.path = .incremental;
        self.beginUpdate();
        const res = self.runUpdate(&s, ws, o);
        self.endUpdate();
        res catch |err| switch (err) {
            error.Timeout, error.CompilerDied => {
                self.sessionDied();
                return false;
            },
            else => return err,
        };
        return true;
    }

    /// One update on `s`: decodes errors into `o.diagnostics`, or stages the
    /// clean output (before any next update can overwrite it) and sweeps.
    fn runUpdate(self: *BuildService, s: *Session, ws: *const workspace.Workspace, o: *Outcome) !void {
        const a = self.a;
        var r = try s.update(self.cfg.update_timeout_ms);
        defer r.deinit(a);
        if (r.bundle.errorMessageCount() > 0) {
            o.diagnostics = try diagnostics.decode(a, self.io, r.bundle, ws);
            return;
        }
        const out = r.output orelse {
            o.message = try std.fmt.allocPrint(a, "The compiler reported no errors but named no output file in {s}.", .{ws.cache_dir.bytes});
            return;
        };
        var diag: [256]u8 = undefined;
        const gen = self.store.stageDiag(out, &.{}, &diag) catch {
            o.message = try a.dupe(u8, platform.elf.diagText(&diag));
            return;
        };
        o.generation = gen;
        o.ok = true;
        // A failed sweep only leaves old generations on disk.
        _ = self.store.sweep() catch {};
    }

    fn diedMessage(self: *BuildService, s: Session, err: anyerror) ![]const u8 {
        const zig = self.zig.?.exe.bytes;
        if (err == error.Timeout) return std.fmt.allocPrint(self.a, "The Zig compiler {s} did not finish within {d} ms and was stopped.", .{
            zig, self.cfg.update_timeout_ms,
        });
        const tail = std.mem.trim(u8, s.stderrTail(), " \t\r\n");
        if (tail.len == 0) return std.fmt.allocPrint(self.a, "The Zig compiler {s} stopped during the build without output.", .{zig});
        return std.fmt.allocPrint(self.a, "The Zig compiler {s} stopped during the build; its last output was: {s}", .{ zig, tail });
    }

    /// Called with `session_mu` held after the incremental server died.
    fn sessionDied(self: *BuildService) void {
        const io = self.io;
        const dead: ?Session = blk: {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            const s = self.warm_slot;
            self.warm_slot = null;
            self.deaths += 1;
            self.warm = if (self.deaths >= 2) .disabled else .cold;
            self.cond.broadcast(io);
            break :blk s;
        };
        if (dead) |s0| {
            var s = s0;
            s.deinit();
        }
    }

    /// After a successful full build: starts warming when the policy has an
    /// incremental mode and no server is warm or warming. Failures leave the
    /// service on the full path.
    fn startWarm(self: *BuildService, ws: *const workspace.Workspace, zig: ZigInstall) void {
        const io = self.io;
        const mode = backend.policy(self.cfg.target, .warm, self.cfg.policy_override);
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            if (!mode.incremental) {
                if (self.warm == .cold) self.warm = .disabled;
                return;
            }
            if (self.warm != .cold or self.stopping) return;
            self.warm = .warming;
        }
        // The last warm thread has set its final state; let it finish.
        if (self.warm_thread) |t| {
            t.join();
            self.warm_thread = null;
        }
        self.warm_thread = self.spawnWarm(ws, zig, mode) catch {
            self.setWarm(.cold);
            return;
        };
    }

    fn spawnWarm(self: *BuildService, ws: *const workspace.Workspace, zig: ZigInstall, mode: BuildMode) !std.Thread {
        const a = self.a;
        const argv = try ws.argv(a, zig, mode);
        errdefer workspace.Workspace.freeArgv(a, argv);
        const cwd: OsPath = .{ .bytes = try a.dupe(u8, ws.build_dir.bytes) };
        errdefer a.free(cwd.bytes);
        return spawn(warmMain, .{ self, WarmJob{ .argv = argv, .cwd = cwd } });
    }

    fn warmState(self: *BuildService) WarmState {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.warm;
    }

    fn setWarm(self: *BuildService, state: WarmState) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.warm = state;
        self.cond.broadcast(self.io);
    }

    // ------------------------------------------------------------- warm thread

    fn warmMain(self: *BuildService, job: WarmJob) void {
        defer _ = live_threads.fetchSub(1, .release);
        defer job.deinit(self.a);
        const io = self.io;
        var s = Session.start(self.a, io, job.argv, job.cwd) catch {
            self.session_mu.lockUncancelable(io);
            defer self.session_mu.unlock(io);
            self.sessionDied();
            return;
        };
        if (!self.register(&self.warm_slot, s)) {
            s.deinit();
            self.setWarm(.cold);
            return;
        }
        self.session_mu.lockUncancelable(io);
        defer self.session_mu.unlock(io);
        var r = s.update(self.cfg.update_timeout_ms) catch {
            self.sessionDied();
            return;
        };
        const clean = r.bundle.errorMessageCount() == 0;
        r.deinit(self.a);
        if (clean) {
            self.setWarm(.ready);
            return;
        }
        // The sources have errors right now: drop this server without counting
        // a death; the next successful full build warms a new one.
        self.unregister(&self.warm_slot);
        s.deinit();
        self.setWarm(.cold);
    }
};

fn spawn(comptime f: anytype, args: anytype) !std.Thread {
    _ = live_threads.fetchAdd(1, .acq_rel);
    errdefer _ = live_threads.fetchSub(1, .acq_rel);
    return std.Thread.spawn(.{}, f, args);
}

fn freeOutcome(a: std.mem.Allocator, o: Outcome) void {
    if (o.generation) |g| g.deinit(a);
    diagnostics.free(a, o.diagnostics);
    if (o.message) |m| a.free(m);
}

/// Adds scan problems to `o.diagnostics` as entries without a line.
fn appendProblems(a: std.mem.Allocator, o: *Outcome, problems: []const scan_mod.Problem) !void {
    if (problems.len == 0) return;
    const old = o.diagnostics;
    const list = try a.alloc(Diagnostic, old.len + problems.len);
    var filled: usize = old.len;
    errdefer {
        for (list[old.len..filled]) |d| {
            if (d.rel) |r| a.free(r);
            a.free(d.message);
        }
        a.free(list);
    }
    for (problems) |p| {
        const rel: ?[]const u8 = if (p.rel.len == 0) null else try a.dupe(u8, p.rel);
        errdefer if (rel) |r| a.free(r);
        const message = try a.dupe(u8, p.message);
        list[filled] = .{ .rel = rel, .line = 0, .column = 0, .message = message, .notes = &.{} };
        filled += 1;
    }
    @memcpy(list[0..old.len], old);
    a.free(old);
    o.diagnostics = list;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "appendProblems keeps compile errors first" {
    const a = testing.allocator;
    var o: Outcome = .{ .trigger = .save, .ok = false, .generation = null, .diagnostics = &.{}, .message = null, .path = .full, .ms = 0 };
    o.diagnostics = try a.alloc(Diagnostic, 1);
    o.diagnostics[0] = .{ .rel = try a.dupe(u8, "a.zig"), .line = 3, .column = 1, .message = try a.dupe(u8, "boom"), .notes = &.{} };
    try appendProblems(a, &o, &.{ .{ .rel = "", .message = "root problem" }, .{ .rel = "x", .message = "x problem" } });
    defer freeOutcome(a, o);
    try testing.expectEqual(@as(usize, 3), o.diagnostics.len);
    try testing.expectEqualStrings("a.zig", o.diagnostics[0].rel.?);
    try testing.expect(o.diagnostics[1].rel == null);
    try testing.expectEqualStrings("x", o.diagnostics[2].rel.?);
    try testing.expectEqual(@as(u32, 0), o.diagnostics[2].line);
}

test "request and deinit without a build" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(base);
    const env: platform.path.HostEnv = .{ .os = builtin.os.tag, .home = base, .xdg_cache_home = base, .local_app_data = base };
    const svc = try BuildService.init(a, testing.io, .{
        .paths = .init(.{ .project = .fromTrusted(base) }, env),
        .locate = .{ .configured = null, .toolchain_dir = .fromTrusted(base), .env = env },
        .sdk = &.{},
        .store_root = .fromTrusted(base),
    });
    try svc.waitIdle(1000);
    try testing.expect(svc.last() == null);
    try testing.expectError(error.NotWarm, svc.waitWarm(10));
    svc.deinit();
    try testing.expectEqual(@as(u32, 0), live_threads.load(.acquire));
}
