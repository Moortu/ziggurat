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
//! - An incremental server holds `<cache dir>/incremental.lock` (exclusive)
//!   for its whole life: two servers on one cache rewrite the same output
//!   file and crash each other. When another editor holds it, this service
//!   stays on the full path (not a death) and tries again after its next
//!   successful full build.
//! - When a build's compiler command line (for example the source root, which
//!   moves into the mirror when the project becomes read-only) differs from
//!   the warm server's, the server is ended (not a death) and warming starts
//!   again after the full build.
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
const FileLock = platform.lock.FileLock;

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

/// Threads of any `BuildService` that are running now.
var live_threads: std.atomic.Value(u32) = .init(0);

/// Number of service threads running in this process. `deinit` joins all
/// of a service's threads, so this is 0 once every service is gone.
pub fn liveThreads() u32 {
    return live_threads.load(.acquire);
}

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
    /// by `deinit`). The pointer is valid only during the call; copy what must
    /// live longer. During the call the build still counts as running, so:
    /// `last()` still returns the previous outcome, `waitIdle` returns
    /// `error.CalledFromCallback`, and calling `deinit` is illegal (a debug
    /// assertion catches it). `request` is fine.
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

/// What the warm thread needs. `argv` is borrowed from
/// `BuildService.warm_argv`; the paths are owned by the thread.
const WarmJob = struct {
    argv: []const []const u8,
    cwd: OsPath,
    lock_path: OsPath,

    fn deinit(job: WarmJob, a: std.mem.Allocator) void {
        a.free(job.cwd.bytes);
        a.free(job.lock_path.bytes);
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
    /// `incremental.lock`, held exactly while `warm_slot` is set.
    warm_lock: ?FileLock = null,

    /// Held while a thread uses the incremental server, so the warm and the
    /// build thread never use it at once. Lock order: `session_mu`, then `mu`.
    session_mu: std.Io.Mutex = .init,

    build_thread: ?std.Thread = null,
    /// Id of the build thread, set when it starts (0 before).
    build_tid: std.atomic.Value(std.Thread.Id) = .init(0),
    /// Spawned by the build thread only; joined by it or by `deinit`.
    warm_thread: ?std.Thread = null,
    /// Command line of the newest warm server. Written by the build thread
    /// only, after joining the previous warm thread; freed by `deinit`.
    warm_argv: ?[]const []const u8 = null,

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

    /// Waits until no build runs and none is pending. Warm-up is not waited
    /// for. From inside `on_outcome` it returns `error.CalledFromCallback`
    /// (the build that called it cannot end while it waits).
    pub fn waitIdle(self: *BuildService, timeout_ms: u32) !void {
        if (self.onBuildThread()) return error.CalledFromCallback;
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

    fn onBuildThread(self: *BuildService) bool {
        return std.Thread.getCurrentId() == self.build_tid.load(.acquire);
    }

    /// A shallow copy of the latest outcome. Its slices are freed when the
    /// next outcome is published, so use it only from the thread that owns
    /// the service and only between builds (after `waitIdle`, with no request
    /// in flight). Other threads use `lastCopy`.
    pub fn last(self: *BuildService) ?Outcome {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.last_outcome;
    }

    /// A deep copy of the latest outcome, made under the lock, so it is safe
    /// from any thread at any time. Free it with `freeOutcome(a, o)`.
    pub fn lastCopy(self: *BuildService, a: std.mem.Allocator) !?Outcome {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const o = self.last_outcome orelse return null;
        return try cloneOutcome(a, o);
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
    /// Illegal from inside `on_outcome` (a debug assertion catches it).
    pub fn deinit(self: *BuildService) void {
        std.debug.assert(!self.onBuildThread());
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
        if (self.warm_lock) |*l| l.release();
        if (self.warm_argv) |v| workspace.Workspace.freeArgv(self.a, v);
        if (self.full_slot) |*s| s.deinit();
        if (self.zig) |z| z.deinit(self.a);
        if (self.last_outcome) |o| freeOutcome(self.a, o);
        self.a.destroy(self);
    }

    // ------------------------------------------------------------ build thread

    fn buildMain(self: *BuildService) void {
        defer _ = live_threads.fetchSub(1, .release);
        self.build_tid.store(std.Thread.getCurrentId(), .release);
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

        if (try self.incrementalBuild(arena, &ws, zig, o)) {
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
    fn incrementalBuild(self: *BuildService, arena: std.mem.Allocator, ws: *const workspace.Workspace, zig: ZigInstall, o: *Outcome) !bool {
        const io = self.io;
        // Check before taking `session_mu`: the warm thread holds it for the
        // whole warm-up update, and a request must not wait for that.
        if (self.warmState() != .ready) return false;
        self.session_mu.lockUncancelable(io);
        defer self.session_mu.unlock(io);
        // The server compiles what its command line named at warm-up time.
        const mode = backend.policy(self.cfg.target, .warm, self.cfg.policy_override);
        const now_argv = try ws.argv(arena, zig, mode);
        if (self.warm_argv == null or !argvEql(self.warm_argv.?, now_argv)) {
            self.dropWarm(false);
            return false;
        }
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
                self.dropWarm(true);
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

    /// Ends the incremental server (if any) and releases `incremental.lock`
    /// after it. `death` counts a session death (the second one disables
    /// incremental builds for good); otherwise the state goes back to `cold`.
    /// The new state is published only after the server is reaped and the
    /// lock released, so another editor that sees `cold` can take the lock.
    /// Called with `session_mu` held, or by the warm thread before the
    /// server is ready. Until the state changes, `incrementalBuild` sees the
    /// empty slot and takes the full path.
    fn dropWarm(self: *BuildService, death: bool) void {
        const io = self.io;
        var s: ?Session = null;
        var l: ?FileLock = null;
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            s = self.warm_slot;
            l = self.warm_lock;
            self.warm_slot = null;
            self.warm_lock = null;
        }
        if (s) |*x| x.deinit();
        if (l) |*x| x.release();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (death) {
            self.deaths += 1;
            self.warm = if (self.deaths >= 2) .disabled else .cold;
        } else if (self.warm != .disabled) {
            self.warm = .cold;
        }
        self.cond.broadcast(io);
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
        // No thread reads `warm_argv` now.
        if (self.warm_argv) |v| workspace.Workspace.freeArgv(self.a, v);
        self.warm_argv = null;
        self.warm_thread = self.spawnWarm(ws, zig, mode) catch {
            self.setWarm(.cold);
            return;
        };
    }

    fn spawnWarm(self: *BuildService, ws: *const workspace.Workspace, zig: ZigInstall, mode: BuildMode) !std.Thread {
        const a = self.a;
        const argv = try ws.argv(a, zig, mode);
        self.warm_argv = argv;
        const cwd: OsPath = .{ .bytes = try a.dupe(u8, ws.build_dir.bytes) };
        errdefer a.free(cwd.bytes);
        const lock_path = try platform.path.joinFor(ws.os, a, ws.cache_dir, &.{incremental_lock_name});
        errdefer a.free(lock_path.bytes);
        return spawn(warmMain, .{ self, WarmJob{ .argv = argv, .cwd = cwd, .lock_path = lock_path } });
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
        // Never waited for: when another editor's server owns this cache,
        // stay on the full path (not a death).
        var lock = FileLock.acquire(io, job.lock_path, .exclusive, 0) catch {
            self.setWarm(.cold);
            return;
        };
        var s = Session.start(self.a, io, job.argv, job.cwd) catch {
            lock.release();
            self.session_mu.lockUncancelable(io);
            defer self.session_mu.unlock(io);
            self.dropWarm(true);
            return;
        };
        if (!self.registerWarm(s, lock)) {
            s.deinit();
            lock.release();
            self.setWarm(.cold);
            return;
        }
        self.session_mu.lockUncancelable(io);
        defer self.session_mu.unlock(io);
        var r = s.update(self.cfg.update_timeout_ms) catch {
            self.dropWarm(true);
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
        self.dropWarm(false);
    }

    /// Puts the warm server and its lock in place unless the service is stopping.
    fn registerWarm(self: *BuildService, s: Session, lock: FileLock) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping) return false;
        self.warm_slot = s;
        self.warm_lock = lock;
        return true;
    }
};

fn spawn(comptime f: anytype, args: anytype) !std.Thread {
    _ = live_threads.fetchAdd(1, .acq_rel);
    errdefer _ = live_threads.fetchSub(1, .acq_rel);
    return std.Thread.spawn(.{}, f, args);
}

/// Name of the lock file an incremental server holds in the cache folder.
pub const incremental_lock_name = "incremental.lock";

fn argvEql(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// Frees an outcome from `BuildService.lastCopy` (with the same allocator).
pub fn freeOutcome(a: std.mem.Allocator, o: Outcome) void {
    if (o.generation) |g| g.deinit(a);
    diagnostics.free(a, o.diagnostics);
    if (o.message) |m| a.free(m);
}

fn freeDiag(a: std.mem.Allocator, d: Diagnostic) void {
    if (d.rel) |r| a.free(r);
    a.free(d.message);
    for (d.notes) |n| a.free(n);
    a.free(d.notes);
}

fn cloneDiag(a: std.mem.Allocator, d: Diagnostic) !Diagnostic {
    const rel: ?[]const u8 = if (d.rel) |r| try a.dupe(u8, r) else null;
    errdefer if (rel) |r| a.free(r);
    const message = try a.dupe(u8, d.message);
    errdefer a.free(message);
    const notes = try a.alloc([]const u8, d.notes.len);
    var n: usize = 0;
    errdefer {
        for (notes[0..n]) |x| a.free(x);
        a.free(notes);
    }
    while (n < d.notes.len) : (n += 1) notes[n] = try a.dupe(u8, d.notes[n]);
    return .{ .rel = rel, .line = d.line, .column = d.column, .message = message, .notes = notes };
}

/// A deep copy of `o`, allocated from `a`; free it with `freeOutcome`.
fn cloneOutcome(a: std.mem.Allocator, o: Outcome) !Outcome {
    var c = o;
    c.generation = null;
    c.diagnostics = &.{};
    c.message = null;
    errdefer freeOutcome(a, c);
    if (o.message) |m| c.message = try a.dupe(u8, m);
    if (o.generation) |g| {
        const dir = try a.dupe(u8, g.dir.bytes);
        errdefer a.free(dir);
        const lib = try a.dupe(u8, g.lib.bytes);
        c.generation = .{ .n = g.n, .dir = .{ .bytes = dir }, .lib = .{ .bytes = lib } };
    }
    const list = try a.alloc(Diagnostic, o.diagnostics.len);
    var n: usize = 0;
    errdefer {
        for (list[0..n]) |d| freeDiag(a, d);
        a.free(list);
    }
    while (n < o.diagnostics.len) : (n += 1) list[n] = try cloneDiag(a, o.diagnostics[n]);
    c.diagnostics = list;
    return c;
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
    try testing.expectEqual(@as(u32, 0), liveThreads());
}

test "lastCopy deep copy is freed by freeOutcome" {
    const a = testing.allocator;
    var notes = [_][]const u8{ "note one", "note two" };
    var diags = [_]Diagnostic{
        .{ .rel = "a.zig", .line = 2, .column = 5, .message = "bad", .notes = &notes },
        .{ .rel = null, .line = 0, .column = 0, .message = "outside", .notes = &.{} },
    };
    const o: Outcome = .{
        .trigger = .play,
        .ok = true,
        .generation = .{ .n = 4, .dir = .fromTrusted("/s/gen/4"), .lib = .fromTrusted("/s/gen/4/libzmod.4.so") },
        .diagnostics = &diags,
        .message = "hello",
        .path = .incremental,
        .ms = 9,
    };
    const c = try cloneOutcome(a, o);
    defer freeOutcome(a, c);
    try testing.expectEqual(Trigger.play, c.trigger);
    try testing.expectEqual(@as(u32, 4), c.generation.?.n);
    try testing.expectEqualStrings("/s/gen/4/libzmod.4.so", c.generation.?.lib.bytes);
    try testing.expect(c.generation.?.lib.bytes.ptr != o.generation.?.lib.bytes.ptr);
    try testing.expectEqualStrings("hello", c.message.?);
    try testing.expectEqual(@as(usize, 2), c.diagnostics.len);
    try testing.expectEqualStrings("note two", c.diagnostics[0].notes[1]);
    try testing.expect(c.diagnostics[1].rel == null);
    // Every allocation failure point is cleaned up.
    try testing.checkAllAllocationFailures(a, cloneAndFree, .{o});
}

fn cloneAndFree(a: std.mem.Allocator, o: Outcome) !void {
    freeOutcome(a, try cloneOutcome(a, o));
}

const CallbackProbe = struct {
    svc: std.atomic.Value(?*BuildService) = .init(null),
    wait_result: std.atomic.Value(u8) = .init(0),

    fn onOutcome(ctx: ?*anyopaque, o: *const Outcome) void {
        _ = o;
        const self: *CallbackProbe = @ptrCast(@alignCast(ctx.?));
        const svc = self.svc.load(.acquire).?;
        const r: u8 = if (svc.waitIdle(1000)) |_| 1 else |err| if (err == error.CalledFromCallback) 2 else 3;
        self.wait_result.store(r, .release);
    }
};

test "waitIdle from the callback is refused" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(base);
    const env: platform.path.HostEnv = .{ .os = builtin.os.tag, .home = base, .xdg_cache_home = base, .local_app_data = base };
    var probe: CallbackProbe = .{};
    // No Zig exists anywhere in this configuration, so the build fails fast
    // in the locator without running a process.
    const svc = try BuildService.init(a, testing.io, .{
        .paths = .init(.{ .project = .fromTrusted(base) }, env),
        .locate = .{ .configured = null, .toolchain_dir = .fromTrusted(base), .env = env },
        .sdk = &.{},
        .store_root = .fromTrusted(base),
        .on_outcome = CallbackProbe.onOutcome,
        .on_outcome_ctx = &probe,
    });
    defer svc.deinit();
    probe.svc.store(svc, .release);
    svc.request(.manual);
    try svc.waitIdle(10_000);
    try testing.expectEqual(@as(u8, 2), probe.wait_result.load(.acquire));
    try testing.expect(!svc.last().?.ok);
}
