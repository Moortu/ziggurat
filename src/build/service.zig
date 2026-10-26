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
//! - `requestFull` asks for a build on the full path: the warm server is
//!   stopped first (a warm-up in progress too; not a death) and warms again
//!   after that full build.
//! - `requestIfChanged` asks for a build only when a `.zig` file changed (for
//!   an editor that has no file watcher: it checks when it regains focus).
//!   The build thread scans the project and compares the scan's id
//!   (`ScanResult.build_id`: path, size, modification time, status-change
//!   time and inode of every script and helper) with the id of the last
//!   build's scan. When they are equal nothing is built and no outcome is
//!   published (`Stats.checks_skipped` counts it). A request made before the
//!   check starts, or during it, is built as usual.
//! - Every build scans the project first. A project without Zig scripts
//!   gives a good outcome with no generation at once: nothing is generated
//!   or compiled, and no Zig is located (a GDScript-only project plays
//!   without Zig).
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
//! - When incremental builds are lost (the second death, or another editor
//!   holds `incremental.lock`), the next full-path outcome without a message
//!   of its own carries a one-time `message` that says why builds are slower.
//!   Each reason is told at most once per service. A build that fails with
//!   an error (also OutOfMemory) reports that error and leaves the notice
//!   pending.
//! - With `Config.check_tables`, every update (incremental and full) is
//!   checked before it is handed out: the staged library is loaded
//!   (`RTLD_LOCAL`), its `ziggurat_describe` table is validated
//!   (`ziggurat_abi.validate`, with `Config.expected_stamp`) and its build id
//!   must be the one this build wrote into the root (Stage 0 found that the
//!   incremental compiler can keep a stale export). `ziggurat_init` is never
//!   called. The check tells two faults apart:
//!   - invalid: the library does not load, has no table, or the table fails
//!     validation (for example two scripts with one class name, or a stamp
//!     mismatch). Rebuilding would give the same table, so the build fails
//!     with the validator's sentence as `message`, the generation is
//!     deleted, and nothing else happens: no death is counted and the warm
//!     server stays.
//!   - stale: the table validates, but after an incremental update its build
//!     id is not this build's. The generation is deleted, the server counts
//!     a death and the same request is built on the full path; that outcome
//!     carries `stale_note` (also when that full build fails). A full build
//!     whose build id does not match fails as invalid.
//!   `init` refuses `check_tables` without `expected_stamp`.
//!   A checked build that validated carries `Outcome.snapshot`, a copy of its
//!   table (`ziggurat_abi.snapshot`). After an incremental update the
//!   service compares each script's layout hash with the previous checked
//!   build's. A script whose layout changed although neither its own file
//!   nor any helper file did (scan fingerprints) means the incremental
//!   compiler kept stale layout data: the incremental output is deleted, the
//!   warm server is dropped (not counted as a death) and the request is
//!   built in full; the outcome's `message` then starts with `layout of
//!   <script> changed although its file did not; rebuilding in full`. If
//!   that full build fails, the outcome has no generation or snapshot and
//!   still carries the note.
//!   Loading each checked build into the editor process has side effects:
//!   the library's `.init_array` constructors run on every check (Zig code
//!   has none, but C code a project links in would run its constructors in
//!   the editor on every edit); the self-hosted backend emits an empty
//!   PT_TLS segment, so every load takes and every close frees a glibc
//!   dynamic TLS module id (measured bounded: about 20 kB once, flat over 50
//!   cycles, and `dlclose` unloads fully); and each check holds the dynamic
//!   loader lock for about 0.7 ms, which other threads loading libraries
//!   wait for.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("ziggurat_platform");
const scan_mod = @import("scan.zig");
const workspace = @import("workspace.zig");
const compiler = @import("compiler.zig");
const diagnostics = @import("diagnostics.zig");
const backend = @import("backend.zig");
const abi = @import("ziggurat_abi");

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

/// Why the Zig locator found no usable Zig (`Outcome.zig_problem`).
pub const ZigProblem = platform.zig_locator.ZigProblem;

/// Which compiler served a build.
pub const BuildPath = enum { full, incremental };

/// The result of one requested build. All slices and paths are owned by the
/// service; see `Config.on_outcome` and `BuildService.last` for how long.
pub const Outcome = struct {
    trigger: Trigger,
    /// True when a new generation was staged, or when the project has no
    /// Zig scripts (then `generation` is null: nothing was built, and no
    /// Zig was needed).
    ok: bool,
    generation: ?Generation,
    /// Compile errors, then scan problems (those have line 0 and do not by
    /// themselves make the build fail).
    diagnostics: []Diagnostic,
    /// One sentence for the user when the build failed for a reason other
    /// than compile errors: the Zig locator's message, the `build.lock`
    /// message, the compiler's last output when it died, a staging failure.
    /// On a full-path outcome that has none of these it may instead hold the
    /// one-time notice that fast (incremental) rebuilds were lost; then `ok`
    /// can be true.
    message: ?[]const u8,
    path: BuildPath,
    /// Wall time of the whole build, from start to staged output.
    ms: u64,
    /// A copy of the validated table of `generation`: set whenever
    /// `Config.check_tables` is on and the build's table validated (on the
    /// full and the incremental path). The outcome owns it; `freeOutcome`
    /// frees it.
    snapshot: ?abi.Snapshot = null,
    /// Why no usable Zig was found (the locator's kind of failure; `message`
    /// holds its sentence), or `.none`.
    zig_problem: ZigProblem = .none,
    /// How many of `diagnostics`, at the end of the list, are scan problems
    /// (the rest are compile errors).
    scan_problems: u32 = 0,
    /// A shared lock on `generation`, taken when it was staged
    /// (`GenerationStore.stage`), so no sweep deletes it before the host
    /// loads it (spec risk 20). The outcome owns it until someone takes it
    /// (`takePin`, from `Config.on_outcome`); `freeOutcome` releases it if
    /// not. A copy (`lastCopy`) has none.
    pin: ?FileLock = null,

    /// Moves the staging pin out of the outcome; the caller releases it.
    pub fn takePin(self: *Outcome) ?FileLock {
        const l = self.pin;
        self.pin = null;
        return l;
    }

    /// Same as `freeOutcome(a, self)`: frees what the outcome owns and
    /// releases its pin if nobody took it.
    pub fn deinit(self: Outcome, a: std.mem.Allocator) void {
        freeOutcome(a, self);
    }
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

/// Why incremental builds stopped; see `Outcome.message`.
const LostReason = enum { server_died_twice, lock_held };

pub const Stats = struct {
    /// Builds started.
    builds: u32,
    /// Requested-build compiler processes running now (warm-up not counted).
    updates_active: u32,
    /// Highest `updates_active` seen.
    updates_max: u32,
    warm: WarmState,
    session_deaths: u32,
    /// Microseconds the last table check took (load, validate, compare,
    /// close); 0 before the first one. See `Config.check_tables`.
    table_check_us: u64,
    /// `requestIfChanged` checks done.
    checks: u32 = 0,
    /// Checks that found no change and built nothing.
    checks_skipped: u32 = 0,
};

/// The note an outcome carries when an incremental update failed the table
/// check and the request was built on the full path instead.
pub const stale_note = "The fast rebuild returned stale code, so this build ran in full.";

/// File stem of the staged library (`--name zmod` in `Workspace.argv`).
pub const lib_stem = "zmod";

/// Threads of any `BuildService` that are running now.
var live_threads: std.atomic.Value(u32) = .init(0);

/// Number of service threads running in this process. `deinit` joins all
/// of a service's threads, so this is 0 once every service is gone.
pub fn liveThreads() u32 {
    return live_threads.load(.acquire);
}

/// The backend policy in use (`Config.policy_override`,
/// `Config.debugger_builds`, `BuildService.setPolicy`).
const Policy = struct {
    override: ?BuildMode,
    debugger: bool,

    fn eql(p: Policy, q: Policy) bool {
        if (p.debugger != q.debugger) return false;
        const x = p.override orelse return q.override == null;
        const y = q.override orelse return false;
        return x.incremental == y.incremental and x.use_llvm == y.use_llvm and x.optimize == y.optimize;
    }
};

/// Configured Zig paths (`BuildService.setZigPaths`), owned.
const ZigPaths = struct {
    project: ?[]const u8 = null,
    editor: ?[]const u8 = null,

    fn deinit(p: ZigPaths, a: std.mem.Allocator) void {
        if (p.project) |x| a.free(x);
        if (p.editor) |x| a.free(x);
    }

    fn eql(p: ZigPaths, q: ZigPaths) bool {
        return optEql(p.project, q.project) and optEql(p.editor, q.editor);
    }

    fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
        if (x == null or y == null) return x == null and y == null;
        return std.mem.eql(u8, x.?, y.?);
    }
};

/// Everything is borrowed: the slices and paths must outlive the service.
pub const Config = struct {
    paths: PathService,
    locate: platform.zig_locator.LocateConfig,
    script_dirs: []const []const u8 = scan_mod.default_script_dirs,
    /// The SDK modules. One must be named `ziggurat` (the root imports it);
    /// `init` refuses the list otherwise.
    sdk: []const workspace.ModuleDep,
    store_root: OsPath,
    caps: platform.generation_store.Caps = .{},
    /// Must be the host target (os tag and cpu arch; `init` checks both).
    /// It exists so tests can check the backend policy; the compiler always
    /// builds for the host, and the staged file name and checks follow it.
    target: std.Target = builtin.target,
    /// Replaces the backend policy table in the `session_start` and `warm`
    /// phases (`backend.policy`). `BuildService.setPolicy` replaces it.
    policy_override: ?BuildMode = null,
    /// Debugger builds: every build takes the debug-build policy (LLVM,
    /// non-incremental, Debug, `backend.Phase.debug_build`) and no
    /// incremental server runs. Wins over `policy_override`.
    /// `BuildService.setPolicy` replaces it.
    debugger_builds: bool = false,
    /// How long a build waits for another editor's `build.lock` (ruling P3).
    lock_timeout_ms: u32 = 30000,
    /// Longest single compiler update before the compiler is killed.
    update_timeout_ms: u32 = 600000,
    /// Called on the build thread after each build (not for a build cut short
    /// by `deinit`). The pointer is valid only during the call; copy what must
    /// live longer. The callback may take the staging pin
    /// (`Outcome.takePin`); it must change nothing else. During the call the
    /// build still counts as running, so: `last()` still returns the
    /// previous outcome, `waitIdle` returns
    /// `error.CalledFromCallback`, and calling `deinit` is illegal (a debug
    /// assertion catches it). `request` is fine.
    on_outcome: ?*const fn (ctx: ?*anyopaque, o: *Outcome) void = null,
    on_outcome_ctx: ?*anyopaque = null,
    /// Check the table of every update before handing it out (see the file
    /// comment). Needs the real SDK: the stub SDK's table has
    /// no `Table` layout.
    check_tables: bool = false,
    /// The layout stamp the host expects in the table:
    /// `ziggurat_abi.expectedStamp(sdk_options)` of the SDK being built against.
    /// Required when `check_tables` is set (`init` refuses the config
    /// otherwise with `error.MissingExpectedStamp`).
    expected_stamp: ?u64 = null,
    /// TEST ONLY, and read only in test builds (`builtin.is_test`). The
    /// table check of an incremental update sees the build id of the
    /// previous build instead of the table's own, as it would when the
    /// compiler kept stale code.
    test_stale_build_id: bool = false,
    /// TEST ONLY, and read only in test builds. The layout comparison after
    /// an incremental update sees every script's previous layout hash
    /// changed, as it would when the compiler kept stale layout data.
    test_layout_drift: bool = false,
    /// TEST ONLY, and read only in test builds. The full build that follows
    /// a stale incremental update fails.
    test_fail_full_after_stale: bool = false,
    /// TEST ONLY, and read only in test builds. The full build that follows
    /// a layout drift fails.
    test_fail_full_after_drift: bool = false,
    /// TEST ONLY, and read only in test builds. See `WarmHold`.
    test_warm_hold: ?*WarmHold = null,
};

/// TEST ONLY (`Config.test_warm_hold`). The first warm thread stops after
/// it registered its server and before it uses it, and goes on once the
/// build thread starts ending that server, or after 300 s. If the server
/// was dropped meanwhile, the warm thread would have used a freed server:
/// it sets `dropped` and returns instead.
pub const WarmHold = struct {
    /// Set when the warm thread is held.
    held: std.atomic.Value(bool) = .init(false),
    /// Set when the warm thread found its server dropped while it was held.
    dropped: std.atomic.Value(bool) = .init(false),
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
    /// The configured Zig paths the build thread locates with, once
    /// `setZigPaths` was called (before that, `Config.locate`'s). Build
    /// thread only.
    zig_paths: ?ZigPaths = null,

    /// Guards every field below up to `session_mu`. Held only briefly, so
    /// `request` never waits for a build.
    mu: std.Io.Mutex = .init,
    /// Broadcast on every change of the fields below.
    cond: std.Io.Condition = .init,
    pending: ?Trigger = null,
    /// The pending build must take the full path (`requestFull`).
    pending_full: bool = false,
    /// The pending request is a `requestIfChanged` check: built only when
    /// the scan differs from the last build's (`seen_id`).
    pending_if_changed: bool = false,
    /// The build thread runs a `requestIfChanged` scan. Not part of
    /// `busy` (a check is not a build), but `waitIdle` waits for it.
    checking: bool = false,
    checks: u32 = 0,
    checks_skipped: u32 = 0,
    building: bool = false,
    stopping: bool = false,
    warm: WarmState = .cold,
    deaths: u32 = 0,
    /// Why incremental builds were lost, until a full-path outcome tells the
    /// user (see `takeNotice`).
    notice: ?LostReason = null,
    /// Reasons already set once; each is told at most once per service.
    told_died: bool = false,
    told_lock: bool = false,
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
    /// Scan results from earlier builds. Used by the build thread only.
    scan_cache: scan_mod.Cache,
    /// Build id of the last build that staged a generation. Build thread only.
    last_build_id: ?[16]u8 = null,
    /// See `Stats.table_check_us`. Guarded by `mu`.
    table_check_us: u64 = 0,
    /// The newest `setZigPaths` paths, until the build thread takes them.
    /// Guarded by `mu`.
    new_zig_paths: ?ZigPaths = null,
    /// The newest `setPolicy` values, until the build thread takes them.
    /// Guarded by `mu`.
    new_policy: ?Policy = null,
    /// The policy builds use (from `Config`, then `setPolicy`). Build
    /// thread only.
    policy_now: Policy,
    /// Set while a policy change ends the incremental server: the warm
    /// thread then neither starts a server nor counts a killed warm-up as
    /// a death. Guarded by `mu`.
    warm_abandon: bool = false,
    /// The table snapshot and file fingerprints of the last build whose
    /// table was checked and validated. Build thread only.
    prev: ?Prev = null,
    /// The bytes `prev` holds (its snapshot copy and file list), counted
    /// when it is made (`remember`). Written on the build thread, read on
    /// any (`keptSnapshotBytes`).
    prev_bytes: std.atomic.Value(u64) = .init(0),
    /// `ScanResult.build_id` of the last build's scan (or of the check that
    /// started it), what `requestIfChanged` compares with. Build thread only.
    seen_id: ?[16]u8 = null,

    pub const InitError = error{ MissingSdkModule, TargetNotHost, MissingExpectedStamp, OutOfMemory } || std.Thread.SpawnError;

    /// Starts the build thread. `a` must be thread-safe. Nothing is built
    /// until the first `request`. See `initDiag` for the errors.
    pub fn init(a: std.mem.Allocator, io: std.Io, cfg: Config) InitError!*BuildService {
        var diag: [256]u8 = undefined;
        return initDiag(a, io, cfg, &diag);
    }

    /// Like `init`; on `error.MissingSdkModule` (no module in `cfg.sdk` is
    /// named `ziggurat`), `error.TargetNotHost` (`cfg.target` is not the
    /// host) or `error.MissingExpectedStamp` (`check_tables` without
    /// `expected_stamp`), `diag` holds one sentence for the user (read it with
    /// `platform.elf.diagText`), ready to show like `Outcome.message`.
    pub fn initDiag(a: std.mem.Allocator, io: std.Io, cfg: Config, diag: *[256]u8) InitError!*BuildService {
        try checkConfig(cfg, diag);
        const self = try a.create(BuildService);
        errdefer a.destroy(self);
        self.* = .{
            .a = a,
            .io = io,
            .cfg = cfg,
            .store = GenerationStore.init(a, io, cfg.store_root, cfg.target.os.tag, lib_stem, cfg.caps),
            .scan_cache = .init(a),
            .policy_now = .{ .override = cfg.policy_override, .debugger = cfg.debugger_builds },
        };
        errdefer self.scan_cache.deinit();
        self.build_thread = try spawn(buildMain, .{self});
        return self;
    }

    /// Asks for a build. Safe from any thread; never waits for a build.
    pub fn request(self: *BuildService, t: Trigger) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping) return;
        self.pending = t;
        self.pending_if_changed = false;
        self.cond.broadcast(self.io);
    }

    /// Asks for a build only if a script or helper file changed since the
    /// last build's scan (see the file comment): the build thread scans
    /// first, and when nothing changed it builds nothing and publishes no
    /// outcome. A request already pending is built as usual. Safe from any
    /// thread; never waits for a build or the scan.
    pub fn requestIfChanged(self: *BuildService, t: Trigger) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping or self.pending != null) return;
        self.pending = t;
        self.pending_if_changed = true;
        self.cond.broadcast(self.io);
    }

    /// Replaces the configured Zig paths of `Config.locate` (`configured`,
    /// the project's override, and `configured_editor`) with copies of
    /// these; null clears one. Safe from any thread; never waits for a
    /// build. The next build that starts uses them, and when they differ
    /// from the paths it located with, it locates Zig again. For a host
    /// that reads its settings at each request: call it before `request`.
    pub fn setZigPaths(self: *BuildService, project: ?[]const u8, editor: ?[]const u8) std.mem.Allocator.Error!void {
        var paths: ZigPaths = .{};
        errdefer paths.deinit(self.a);
        if (project) |p| paths.project = try self.a.dupe(u8, p);
        if (editor) |e| paths.editor = try self.a.dupe(u8, e);
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.new_zig_paths) |old| old.deinit(self.a);
        self.new_zig_paths = paths;
    }

    /// Replaces `Config.policy_override` and `Config.debugger_builds`.
    /// Safe from any thread; never waits for a build. The next build that
    /// starts uses them; when they differ from the ones in use, that build
    /// first stops the incremental server (a warm-up in progress too,
    /// which is not counted as a server death), and a server warms up
    /// again after the next successful full build when the new policy has
    /// an incremental mode. For a host that reads its settings at each
    /// request: call it before `request`.
    pub fn setPolicy(self: *BuildService, override: ?BuildMode, debugger: bool) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.new_policy = .{ .override = override, .debugger = debugger };
    }

    /// True while a build runs or one is pending. Any thread.
    pub fn busy(self: *BuildService) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.building or self.pending != null;
    }

    /// As `request`, and that build takes the full path: the incremental
    /// server is stopped first (a warm-up in progress is killed, not
    /// waited for) and warms again after the full build. For a
    /// caller that found the newest incremental build stale in a way the
    /// service cannot see (the editor host compares the module's defaults
    /// with its table). Requests made before the build starts join it.
    pub fn requestFull(self: *BuildService, t: Trigger) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping) return;
        self.pending = t;
        self.pending_full = true;
        self.pending_if_changed = false;
        self.cond.broadcast(self.io);
    }

    /// Waits until no build or `requestIfChanged` check runs and none is
    /// pending. Warm-up is not waited for. From inside `on_outcome` it
    /// returns `error.CalledFromCallback` (the build that called it cannot
    /// end while it waits).
    pub fn waitIdle(self: *BuildService, timeout_ms: u32) !void {
        if (self.onBuildThread()) return error.CalledFromCallback;
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const timer = Timer.start(self.io);
        while (self.building or self.checking or self.pending != null) try self.waitLocked(timer, timeout_ms);
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

    /// The bytes of the table snapshot (and file list) the service keeps
    /// from the last checked build to compare the next one with (0 when it
    /// keeps none). Exact: counted when it was allocated. Any thread.
    pub fn keptSnapshotBytes(self: *BuildService) u64 {
        return self.prev_bytes.load(.acquire);
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
            .table_check_us = self.table_check_us,
            .checks = self.checks,
            .checks_skipped = self.checks_skipped,
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
        if (self.zig_paths) |p| p.deinit(self.a);
        if (self.new_zig_paths) |p| p.deinit(self.a);
        if (self.last_outcome) |o| freeOutcome(self.a, o);
        if (self.prev) |p| p.deinit(self.a);
        self.scan_cache.deinit();
        self.a.destroy(self);
    }

    // ------------------------------------------------------------ build thread

    fn buildMain(self: *BuildService) void {
        defer _ = live_threads.fetchSub(1, .release);
        self.build_tid.store(std.Thread.getCurrentId(), .release);
        const io = self.io;
        while (true) {
            var full = false;
            var check = false;
            const t: Trigger = blk: {
                self.mu.lockUncancelable(io);
                defer self.mu.unlock(io);
                while (self.pending == null and !self.stopping) self.cond.waitUncancelable(io, &self.mu);
                if (self.stopping) return;
                const t = self.pending.?;
                self.pending = null;
                if (self.pending_if_changed) {
                    self.pending_if_changed = false;
                    self.checking = true;
                    check = true;
                    break :blk t;
                }
                full = self.pending_full;
                self.pending_full = false;
                self.building = true;
                self.builds += 1;
                break :blk t;
            };
            if (check) {
                const changed = self.treeChanged();
                self.mu.lockUncancelable(io);
                defer self.mu.unlock(io);
                self.checking = false;
                self.checks += 1;
                if (changed) {
                    // Built at the next turn, joined by any request made
                    // meanwhile. `checking` and `pending` change under one
                    // lock, so `waitIdle` never sees idle in between.
                    if (self.pending == null) self.pending = t;
                    self.pending_if_changed = false;
                } else self.checks_skipped += 1;
                self.cond.broadcast(io);
                continue;
            }
            const o = self.runBuild(t, full);
            self.publish(o);
        }
    }

    /// For a `requestIfChanged` check: scans the project and compares the
    /// scan's id with the last build's (`seen_id`). True when they differ,
    /// when no build scanned yet and when the scan fails (the build then
    /// reports why). Keeps the new id, so a build that fails after its scan
    /// (no Zig) is not repeated at every check. Build thread only.
    fn treeChanged(self: *BuildService) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.a);
        defer arena_state.deinit();
        const sc = scan_mod.scanCached(arena_state.allocator(), self.io, self.cfg.paths.roots.project, self.cfg.script_dirs, &self.scan_cache) catch return true;
        if (self.seen_id) |id| if (std.mem.eql(u8, &id, &sc.build_id)) return false;
        self.seen_id = sc.build_id;
        return true;
    }

    fn publish(self: *BuildService, outcome: Outcome) void {
        var o = outcome;
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

    fn runBuild(self: *BuildService, t: Trigger, full: bool) Outcome {
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
        var stale: Stale = .{};
        self.buildInner(&o, &stale, full) catch |err| {
            o.ok = false;
            if (o.message == null) o.message = std.fmt.allocPrint(self.a, "The build of {s} failed: {t}.", .{
                self.cfg.paths.roots.project.bytes, err,
            }) catch null;
            // The fast path was dropped even though the full build failed.
            if (stale.found and !stale.noted) addStaleNote(self.a, &o) catch {};
        };
        o.ms = timer.ms();
        return o;
    }

    /// Whether this build's incremental output failed the table check, and
    /// whether `stale_note` is already in the outcome.
    const Stale = struct { found: bool = false, noted: bool = false };

    fn buildInner(self: *BuildService, o: *Outcome, stale: *Stale, full: bool) !void {
        const a = self.a;
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        self.takePolicy();

        // The scan comes first: a project without Zig scripts has nothing
        // to build and needs no Zig (Play in a GDScript-only project).
        const project = self.cfg.paths.roots.project;
        const sc = scan_mod.scanCached(arena, self.io, project, self.cfg.script_dirs, &self.scan_cache) catch |err| {
            o.message = try std.fmt.allocPrint(a, "Scanning the project folder {s} failed: {t}.", .{ project.bytes, err });
            return err;
        };
        self.seen_id = sc.build_id;
        if (sc.scripts.len == 0) {
            // A good build with no generation: nothing is generated,
            // compiled or staged, and the last generation stays as it is.
            o.ok = true;
            try appendProblems(a, o, sc.problems);
            o.scan_problems = @intCast(sc.problems.len);
            return;
        }
        const zig = try self.locateZig(o);
        var ws = try self.prepareWorkspace(sc, o);
        defer ws.deinit(a);

        // `requestFull`: the incremental server's state is not trusted.
        if (full) self.stopWarm();
        if (!full and try self.incrementalBuild(arena, &ws, zig, &sc.build_id, o, &stale.found)) {
            // A script whose layout changed although its source (and every
            // helper) did not: the incremental compiler kept stale layout
            // data. Refresh the build in full.
            const drift = if (o.ok and o.snapshot != null) try self.layoutDrift(sc, &o.snapshot.?) else null;
            if (drift) |note| {
                defer a.free(note);
                self.discardGeneration(o);
                o.path = .full;
                self.stopWarm();
                const res: anyerror!void = if (builtin.is_test and self.cfg.test_fail_full_after_drift) blk: {
                    o.message = try a.dupe(u8, "The full build failed (test fault).");
                    break :blk error.TestFault;
                } else self.fullBuild(arena, &ws, zig, &sc.build_id, o);
                // The note stays when the full build fails, and then so does
                // nothing else of the incremental build.
                addNote(a, o, note) catch {};
                res catch |err| {
                    if (o.generation != null) self.discardGeneration(o);
                    return err;
                };
                if (o.ok) self.startWarm(&ws, zig);
            }
        } else {
            o.path = .full;
            if (builtin.is_test and stale.found and self.cfg.test_fail_full_after_stale) {
                o.message = try a.dupe(u8, "The full build failed (test fault).");
                return error.TestFault;
            }
            try self.fullBuild(arena, &ws, zig, &sc.build_id, o);
            if (o.ok) self.startWarm(&ws, zig);
        }
        if (o.ok) self.last_build_id = sc.build_id;
        if (o.ok) if (o.snapshot) |*snap| self.remember(sc, snap);
        try appendProblems(a, o, sc.problems);
        o.scan_problems = @intCast(sc.problems.len);
        if (stale.found) {
            try addStaleNote(a, o);
            stale.noted = true;
        }
        // Last, after every step that can fail: a failed build reports its
        // own error, and the notice stays pending for the next outcome.
        if (o.path == .full and o.message == null) o.message = try self.takeNotice();
    }

    /// What the next build compares with: the last checked table and the
    /// fingerprint of every scanned file.
    const Prev = struct {
        snap: abi.Snapshot,
        files: []FileFp,
        helpers: usize,

        const FileFp = struct { rel: []const u8, fingerprint: u64 };

        fn deinit(p: Prev, a: std.mem.Allocator) void {
            p.snap.deinit(a);
            for (p.files) |f| a.free(f.rel);
            a.free(p.files);
        }

        fn fingerprint(p: *const Prev, rel: []const u8) u64 {
            for (p.files) |f| {
                if (std.mem.eql(u8, f.rel, rel)) return f.fingerprint;
            }
            return 0;
        }
    };

    /// Keeps a copy of `snap` and the file fingerprints of `sc` for the next
    /// comparison. On out-of-memory the comparison is simply skipped once.
    fn remember(self: *BuildService, sc: scan_mod.ScanResult, snap: *const abi.Snapshot) void {
        if (self.prev) |p| p.deinit(self.a);
        self.prev = null;
        self.prev_bytes.store(0, .release);
        // Allocated through a counter so the editor's memory figures are
        // exact; `Prev.deinit` frees through the service's allocator, which
        // the counter passes every call to.
        var counter: platform.counting_allocator.CountingAllocator = .init(self.a);
        const a = counter.allocator();
        const copy = snap.clone(a) catch return;
        const files = a.alloc(Prev.FileFp, sc.scripts.len + sc.helper_paths.len) catch {
            copy.deinit(a);
            return;
        };
        var n: usize = 0;
        for ([_][]const scan_mod.Script{ sc.scripts, sc.helper_paths }) |list| {
            for (list) |f| {
                const rel = a.dupe(u8, f.rel) catch {
                    for (files[0..n]) |x| a.free(x.rel);
                    a.free(files);
                    copy.deinit(a);
                    return;
                };
                files[n] = .{ .rel = rel, .fingerprint = f.fingerprint };
                n += 1;
            }
        }
        self.prev = .{ .snap = copy, .files = files, .helpers = sc.helper_paths.len };
        self.prev_bytes.store(counter.live, .release);
    }

    /// After an incremental build: one sentence per script whose layout hash
    /// differs from the previous checked build although its own source file
    /// did not change. Null when there is none. Nothing is compared when a
    /// helper file changed, appeared or went (a helper can change the layout
    /// of a script that imports it), or when a fingerprint is unknown.
    fn layoutDrift(self: *BuildService, sc: scan_mod.ScanResult, snap: *const abi.Snapshot) !?[]u8 {
        const prev = &(self.prev orelse return null);
        if (prev.helpers != sc.helper_paths.len) return null;
        for (sc.helper_paths) |h| {
            const was = prev.fingerprint(h.rel);
            if (was == 0 or was != h.fingerprint) return null;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        for (snap.scripts) |s| {
            const before = prev.snap.find(s.path) orelse continue;
            const old_hash = if (builtin.is_test and self.cfg.test_layout_drift) before.layout_hash +% 1 else before.layout_hash;
            if (old_hash == s.layout_hash) continue;
            const fp = for (sc.scripts) |x| {
                if (std.mem.eql(u8, x.rel, s.path)) break x.fingerprint;
            } else 0;
            const was = prev.fingerprint(s.path);
            if (fp == 0 or was == 0 or fp != was) continue;
            if (out.items.len > 0) try out.append(self.a, ' ');
            try out.print(self.a, "layout of {s} changed although its file did not; rebuilding in full", .{s.path});
        }
        if (out.items.len == 0) {
            out.deinit(self.a);
            return null;
        }
        return try out.toOwnedSlice(self.a);
    }

    fn locateZig(self: *BuildService, o: *Outcome) !ZigInstall {
        self.takeZigPaths();
        if (self.zig) |z| return z;
        var cfg = self.cfg.locate;
        if (self.zig_paths) |p| {
            cfg.configured = if (p.project) |x| .fromTrusted(x) else null;
            cfg.configured_editor = if (p.editor) |x| .fromTrusted(x) else null;
        }
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.a);
        var problem: ZigProblem = .none;
        const z = platform.zig_locator.locateProblem(self.a, self.io, cfg, &msg, &problem) catch |err| {
            if (err == error.ZigNotUsable) {
                o.zig_problem = problem;
                o.message = try self.a.dupe(u8, msg.items);
            }
            return err;
        };
        self.zig = z;
        return z;
    }

    /// Takes the paths of the newest `setZigPaths`; when they differ from
    /// the ones in use, the located Zig is dropped, so it is located again.
    fn takeZigPaths(self: *BuildService) void {
        const new = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            const n = self.new_zig_paths orelse return;
            self.new_zig_paths = null;
            break :blk n;
        };
        const cur: ZigPaths = self.zig_paths orelse .{
            .project = if (self.cfg.locate.configured) |c| c.bytes else null,
            .editor = if (self.cfg.locate.configured_editor) |c| c.bytes else null,
        };
        const same = cur.eql(new);
        if (self.zig_paths) |old| old.deinit(self.a);
        self.zig_paths = new;
        if (same) return;
        if (self.zig) |z| z.deinit(self.a);
        self.zig = null;
    }

    /// The mode for `phase` under the policy in use: in debugger builds
    /// every phase is the debug build. Build thread only.
    fn modeFor(self: *const BuildService, phase: backend.Phase) BuildMode {
        const p = self.policy_now;
        if (p.debugger) return backend.policy(self.cfg.target, .debug_build, null);
        return backend.policy(self.cfg.target, phase, p.override);
    }

    /// Takes the values of the newest `setPolicy`. When they differ from
    /// the ones in use, the incremental server ends: a warm-up in
    /// progress is killed and its thread joined, a ready server is
    /// dropped (neither counts as a death), and a server that the old
    /// policy disabled may warm up again. Build thread only.
    fn takePolicy(self: *BuildService) void {
        const io = self.io;
        const new = blk: {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            const n = self.new_policy orelse return;
            self.new_policy = null;
            if (n.eql(self.policy_now)) return;
            break :blk n;
        };
        self.policy_now = new;
        self.stopWarm();
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        // `disabled` from a policy without an incremental mode; after two
        // deaths it stays.
        if (self.warm == .disabled and self.deaths < 2) self.warm = .cold;
        self.cond.broadcast(io);
    }

    /// Ends the incremental server without counting a death: a warm-up in
    /// progress is killed, the warm thread is joined, and only then is the
    /// server dropped, so no thread uses a server after it is freed. The
    /// join cannot deadlock: the warm thread never waits for the build
    /// thread (this thread holds neither `mu` nor `session_mu` while it
    /// joins), and a killed warm-up update ends at once. Build thread only.
    fn stopWarm(self: *BuildService) void {
        const io = self.io;
        {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            // The warm thread sees this before it registers a server or
            // after its warm-up update fails.
            self.warm_abandon = true;
            if (self.warm == .warming) if (self.warm_slot) |s| s.interrupt();
        }
        if (self.warm_thread) |t| {
            t.join();
            self.warm_thread = null;
        }
        {
            self.session_mu.lockUncancelable(io);
            defer self.session_mu.unlock(io);
            self.dropWarm(false);
        }
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.warm_abandon = false;
        self.cond.broadcast(io);
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
    fn fullBuild(self: *BuildService, arena: std.mem.Allocator, ws: *const workspace.Workspace, zig: ZigInstall, build_id: []const u8, o: *Outcome) !void {
        const a = self.a;
        const mode = self.modeFor(.session_start);
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
        if (o.ok and self.cfg.check_tables) {
            switch (self.checkTable(arena, o.generation.?, build_id, false)) {
                .ok => |snap| o.snapshot = snap,
                .stale => unreachable,
                .invalid => |sentence| {
                    self.discardGeneration(o);
                    o.message = try self.a.dupe(u8, sentence.text());
                },
            }
        }
    }

    /// Serves the request with the warm incremental server. False when there
    /// is none, it died, or its output was stale (then `stale` is set); the
    /// caller then takes the full path. An invalid table is served: the
    /// build fails with the validator's sentence.
    fn incrementalBuild(
        self: *BuildService,
        arena: std.mem.Allocator,
        ws: *const workspace.Workspace,
        zig: ZigInstall,
        build_id: []const u8,
        o: *Outcome,
        stale: *bool,
    ) !bool {
        const io = self.io;
        // Check before taking `session_mu`: the warm thread holds it for the
        // whole warm-up update, and a request must not wait for that.
        if (self.policy_now.debugger or self.warmState() != .ready) return false;
        self.session_mu.lockUncancelable(io);
        defer self.session_mu.unlock(io);
        // The server compiles what its command line named at warm-up time.
        const mode = self.modeFor(.warm);
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
        if (o.ok and self.cfg.check_tables) {
            switch (self.checkTable(arena, o.generation.?, build_id, true)) {
                .ok => |snap| o.snapshot = snap,
                .stale => {
                    // Never handed out: delete it, and treat the server as dead.
                    self.discardGeneration(o);
                    stale.* = true;
                    self.dropWarm(true);
                    return false;
                },
                .invalid => |sentence| {
                    // A fault in the module, not in the server: fail the
                    // build and keep the server.
                    self.discardGeneration(o);
                    o.message = try self.a.dupe(u8, sentence.text());
                },
            }
        }
        return true;
    }

    /// Deletes the staged generation of a build that must not be handed out
    /// and marks the build failed.
    fn discardGeneration(self: *BuildService, o: *Outcome) void {
        const gen = o.generation.?;
        // The staging pin would keep `remove` from deleting it.
        if (o.takePin()) |l| {
            var pin = l;
            pin.release();
        }
        self.store.remove(gen.n) catch {};
        gen.deinit(self.a);
        o.generation = null;
        o.ok = false;
        if (o.snapshot) |snap| snap.deinit(self.a);
        o.snapshot = null;
    }

    /// One sentence for the user, NUL-padded.
    const Sentence = struct {
        buf: [256]u8,

        fn text(s: *const Sentence) []const u8 {
            return std.mem.sliceTo(&s.buf, 0);
        }
    };

    const TableCheck = union(enum) {
        /// The table validates and carries this build's id; the snapshot is
        /// the caller's (allocated with the service's allocator).
        ok: abi.Snapshot,
        /// The table validates but carries another build's id.
        stale,
        /// The library or its table would be refused by the host.
        invalid: Sentence,
    };

    /// Loads the staged library of `gen`, validates the table that
    /// `ziggurat_describe` returns and compares its build id with
    /// `build_id`. Never calls `ziggurat_init`. `incremental` says which
    /// path built it: only an incremental build id mismatch is `stale`.
    fn checkTable(self: *BuildService, arena: std.mem.Allocator, gen: Generation, build_id: []const u8, incremental: bool) TableCheck {
        const t0 = std.Io.Clock.awake.now(self.io);
        defer {
            const us = t0.durationTo(std.Io.Clock.awake.now(self.io)).toMicroseconds();
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.table_check_us = @intCast(@max(us, 0));
        }
        var s: Sentence = undefined;
        var diag: [256]u8 = undefined;
        const lib = platform.loader.open(arena, self.io, gen.lib, &diag) catch {
            platform.elf.setDiag(&s.buf, "The built library {s} could not be loaded for its table check: {s}", .{ gen.lib.bytes, platform.elf.diagText(&diag) });
            return .{ .invalid = s };
        };
        defer platform.loader.close(lib);
        const describe = platform.loader.lookup(lib, abi.DescribeFn, abi.describe_symbol) orelse {
            platform.elf.setDiag(&s.buf, "The built library {s} has no ziggurat_describe export.", .{gen.lib.bytes});
            return .{ .invalid = s };
        };
        const table = describe();
        // `init` refuses `check_tables` without a stamp.
        const stamp = self.cfg.expected_stamp.?;
        abi.validate(arena, table, stamp, .{}, &s.buf) catch |err| {
            if (err == error.OutOfMemory) platform.elf.setDiag(&s.buf, "The table check ran out of memory.", .{});
            return .{ .invalid = s };
        };
        // Validated: the build id is a readable string.
        const own = if (table.build_id.len == 0) "" else table.build_id.ptr.?[0..table.build_id.len];
        const previous = self.last_build_id orelse @as([16]u8, @splat(0));
        const seen: []const u8 = if (builtin.is_test and incremental and self.cfg.test_stale_build_id) &previous else own;
        if (std.mem.eql(u8, seen, build_id)) {
            const snap = abi.snapshot.take(self.a, table) catch {
                platform.elf.setDiag(&s.buf, "The table check ran out of memory.", .{});
                return .{ .invalid = s };
            };
            return .{ .ok = snap };
        }
        if (incremental) return .stale;
        platform.elf.setDiag(&s.buf, "The full build's table has build id \"{f}\", but this build wrote \"{s}\" into the root.", .{ std.zig.fmtString(seen[0..@min(seen.len, 32)]), build_id });
        return .{ .invalid = s };
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
        const staged = self.store.stageDiag(out, &.{}, &diag) catch {
            o.message = try stagingMessage(a, out.bytes, platform.elf.diagText(&diag));
            return;
        };
        o.generation = staged.gen;
        o.pin = staged.pin;
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
    /// server is ready. The build thread calls it directly only for a
    /// `ready` server (the warm thread is done with it); otherwise through
    /// `stopWarm`, which joins the warm thread first. Until the state
    /// changes, `incrementalBuild` sees the empty slot and takes the full
    /// path.
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
            if (self.warm == .disabled) self.noteLostLocked(.server_died_twice);
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
        // In debugger builds the mode has no incremental mode.
        const mode = self.modeFor(.warm);
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

    /// Records why incremental builds were lost, unless this reason was
    /// already recorded once. Called with `mu` held.
    fn noteLostLocked(self: *BuildService, why: LostReason) void {
        const told = switch (why) {
            .server_died_twice => &self.told_died,
            .lock_held => &self.told_lock,
        };
        if (told.*) return;
        told.* = true;
        self.notice = why;
    }

    /// The pending one-time notice as an owned message, or null. The notice
    /// is cleared only once the message exists, so an allocation failure
    /// leaves it pending.
    fn takeNotice(self: *BuildService) !?[]const u8 {
        const why = blk: {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            break :blk self.notice orelse return null;
        };
        const text = try self.a.dupe(u8, switch (why) {
            .server_died_twice => "Fast rebuilds are off for this session: the Zig compiler server stopped twice. Builds still work but are slower.",
            // Not for the session: warm-up is tried again after every
            // successful full build, so fast rebuilds return when the other
            // editor lets go.
            .lock_held => "Fast rebuilds are paused: another editor is using them for this project. Builds still work but are slower.",
        });
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.notice == why) self.notice = null;
        return text;
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
        var lock = FileLock.acquire(io, job.lock_path, .exclusive, 0) catch |err| {
            self.mu.lockUncancelable(io);
            defer self.mu.unlock(io);
            // Only a lock held elsewhere is another editor; other errors
            // just leave the service on the full path.
            if (err == error.Timeout) self.noteLostLocked(.lock_held);
            self.warm = .cold;
            self.cond.broadcast(io);
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
        if (builtin.is_test) if (self.cfg.test_warm_hold) |h| {
            // The server, its lock and the state are the dropper's now.
            if (!self.holdWarm(h)) return;
        };
        self.session_mu.lockUncancelable(io);
        defer self.session_mu.unlock(io);
        var r = s.update(self.cfg.update_timeout_ms) catch {
            // Killed by a policy change (`takePolicy`): not a death.
            self.dropWarm(!self.warmAbandoned());
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

    /// `WarmHold`: false when the server was dropped while held.
    fn holdWarm(self: *BuildService, h: *WarmHold) bool {
        if (h.held.swap(true, .acq_rel)) return true;
        const timer = Timer.start(self.io);
        while (timer.ms() < 300_000) {
            {
                self.mu.lockUncancelable(self.io);
                defer self.mu.unlock(self.io);
                if (self.warm_slot == null) {
                    h.dropped.store(true, .release);
                    return false;
                }
                if (self.warm_abandon or self.stopping) return true;
            }
            self.io.sleep(.fromMilliseconds(2), .awake) catch {};
        }
        return true;
    }

    fn warmAbandoned(self: *BuildService) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.warm_abandon;
    }

    /// Puts the warm server and its lock in place unless the service is
    /// stopping or a policy change ends the server (`warm_abandon`).
    fn registerWarm(self: *BuildService, s: Session, lock: FileLock) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.stopping or self.warm_abandon) return false;
        self.warm_slot = s;
        self.warm_lock = lock;
        return true;
    }
};

/// Checks what `init` cannot work without; see `BuildService.initDiag`.
fn checkConfig(cfg: Config, diag: *[256]u8) error{ MissingSdkModule, TargetNotHost, MissingExpectedStamp }!void {
    const t = cfg.target;
    if (t.os.tag != builtin.os.tag or t.cpu.arch != builtin.cpu.arch) {
        platform.elf.setDiag(diag, "The build target {t}-{t} is not this machine's target {t}-{t}; Ziggurat builds only for the machine it runs on.", .{
            t.cpu.arch, t.os.tag, builtin.cpu.arch, builtin.os.tag,
        });
        return error.TargetNotHost;
    }
    if (cfg.check_tables and cfg.expected_stamp == null) {
        platform.elf.setDiag(diag, "The table check is on but no expected layout stamp is set; set Config.expected_stamp.", .{});
        return error.MissingExpectedStamp;
    }
    for (cfg.sdk) |m| {
        if (std.mem.eql(u8, m.name, "ziggurat")) return;
    }
    // Name the modules that are there, so a typo is easy to see.
    var names: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&names);
    for (cfg.sdk, 0..) |m, i| {
        w.print("{s}{s}", .{ if (i == 0) "" else ", ", m.name }) catch break;
    }
    const listed = w.buffered();
    platform.elf.setDiag(diag, "The SDK module list ({s}) has no module named \"ziggurat\"; add the Ziggurat SDK to it.", .{
        if (listed.len == 0) "empty" else listed,
    });
    return error.MissingSdkModule;
}

/// The user message for a staging failure: `detail` (one sentence) with the
/// staged file named in front, unless `detail` already names it.
fn stagingMessage(a: std.mem.Allocator, staged: []const u8, detail: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, detail, staged) != null) return a.dupe(u8, detail);
    const m = try std.fmt.allocPrint(a, "Staging {s} failed: {s}", .{ staged, detail });
    // "The file ..." reads as "the file ..." after the colon; "ELF ..." stays.
    const at = m.len - detail.len;
    if (detail.len >= 2 and std.ascii.isUpper(detail[0]) and std.ascii.isLower(detail[1])) m[at] = std.ascii.toLower(detail[0]);
    return m;
}

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
/// Also frees an outcome the service made, and releases its staging pin
/// when nobody took it.
pub fn freeOutcome(a: std.mem.Allocator, o: Outcome) void {
    if (o.pin) |l| {
        var pin = l;
        pin.release();
    }
    if (o.generation) |g| g.deinit(a);
    diagnostics.free(a, o.diagnostics);
    if (o.message) |m| a.free(m);
    if (o.snapshot) |snap| snap.deinit(a);
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
    c.pin = null;
    c.generation = null;
    c.diagnostics = &.{};
    c.message = null;
    c.snapshot = null;
    errdefer freeOutcome(a, c);
    if (o.message) |m| c.message = try a.dupe(u8, m);
    if (o.snapshot) |*snap| c.snapshot = try snap.clone(a);
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

/// Puts `note` in front of `o.message` (alone when there is none).
fn addNote(a: std.mem.Allocator, o: *Outcome, note: []const u8) !void {
    const old = o.message orelse {
        o.message = try a.dupe(u8, note);
        return;
    };
    o.message = try std.mem.concat(a, u8, &.{ note, " ", old });
    a.free(old);
}

/// Puts `stale_note` in front of `o.message` (alone when there is none).
fn addStaleNote(a: std.mem.Allocator, o: *Outcome) !void {
    const old = o.message orelse {
        o.message = try a.dupe(u8, stale_note);
        return;
    };
    o.message = try std.mem.concat(a, u8, &.{ stale_note, " ", old });
    a.free(old);
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
        .sdk = &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }},
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

    fn onOutcome(ctx: ?*anyopaque, o: *Outcome) void {
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
        .sdk = &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }},
        .store_root = .fromTrusted(base),
        .on_outcome = CallbackProbe.onOutcome,
        .on_outcome_ctx = &probe,
    });
    defer svc.deinit();
    probe.svc.store(svc, .release);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "pub const extends = \"Node\";\n" });
    svc.request(.manual);
    try svc.waitIdle(10_000);
    try testing.expectEqual(@as(u8, 2), probe.wait_result.load(.acquire));
    try testing.expect(!svc.last().?.ok);
}

/// Requests a build and returns a deep copy of its outcome.
fn buildOnce(svc: *BuildService, a: std.mem.Allocator, t: Trigger) !Outcome {
    svc.request(t);
    try svc.waitIdle(30_000);
    return (try svc.lastCopy(a)).?;
}

test "outcomes carry the Zig problem, and new Zig paths are used at the next build" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    try tmp.dir.writeFile(io, .{ .sub_path = "old-zig", .data = "#!/bin/sh\necho 0.16.0\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "mute-zig", .data = "#!/bin/sh\nexit 3\n", .flags = .{ .permissions = .executable_file } });
    const old = try std.fs.path.join(a, &.{ base, "old-zig" });
    defer a.free(old);
    const mute = try std.fs.path.join(a, &.{ base, "mute-zig" });
    defer a.free(mute);
    // A script, so every build needs Zig.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const extends = \"Node\";\n" });
    // No Zig anywhere in this configuration.
    const svc = try BuildService.init(a, io, testConfig(base, &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }}));
    defer svc.deinit();

    const missing = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, missing);
    try testing.expect(!missing.ok);
    try testing.expectEqual(Trigger.manual, missing.trigger);
    try testing.expectEqual(ZigProblem.missing, missing.zig_problem);

    // The editor setting alone.
    try svc.setZigPaths(null, old);
    const wrong = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, wrong);
    try testing.expectEqual(ZigProblem.wrong_version, wrong.zig_problem);
    try testing.expect(std.mem.indexOf(u8, wrong.message.?, "is Zig 0.16.0") != null);

    // The project setting comes first.
    try svc.setZigPaths(mute, old);
    const silent = try buildOnce(svc, a, .save);
    defer freeOutcome(a, silent);
    try testing.expectEqual(ZigProblem.no_answer, silent.zig_problem);

    // Cleared again: nothing is found.
    try svc.setZigPaths(null, null);
    const gone = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, gone);
    try testing.expectEqual(ZigProblem.missing, gone.zig_problem);
    try testing.expect(!svc.busy());
}

test "a located Zig is located again when the paths change" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    // Reports the pinned version, then fails every other command at once.
    try tmp.dir.writeFile(io, .{ .sub_path = "good-zig", .data = "#!/bin/sh\nif [ \"$1\" = version ]; then echo " ++ platform.pins.zig_version ++ "; exit 0; fi\nexit 1\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "old-zig", .data = "#!/bin/sh\necho 0.16.0\n", .flags = .{ .permissions = .executable_file } });
    const good = try std.fs.path.join(a, &.{ base, "good-zig" });
    defer a.free(good);
    const old = try std.fs.path.join(a, &.{ base, "old-zig" });
    defer a.free(old);
    // A script, so every build needs Zig.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const extends = \"Node\";\n" });
    const svc = try BuildService.init(a, io, testConfig(base, &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }}));
    defer svc.deinit();

    try svc.setZigPaths(good, null);
    const first = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, first);
    try testing.expectEqual(ZigProblem.none, first.zig_problem);
    // Same paths again: the located Zig stays.
    try svc.setZigPaths(good, null);
    const same = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, same);
    try testing.expectEqual(ZigProblem.none, same.zig_problem);
    try svc.setZigPaths(old, null);
    const changed = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, changed);
    try testing.expectEqual(ZigProblem.wrong_version, changed.zig_problem);
}

test "a project without scripts builds without Zig" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    // A helper is not a script; no Zig anywhere in this configuration.
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.zig", .data = "pub fn f() void {}\n" });
    const svc = try BuildService.init(a, io, testConfig(base, &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }}));
    defer svc.deinit();

    const empty = try buildOnce(svc, a, .play);
    defer freeOutcome(a, empty);
    try testing.expect(empty.ok);
    try testing.expect(empty.generation == null);
    try testing.expect(empty.snapshot == null);
    try testing.expectEqual(ZigProblem.none, empty.zig_problem);
    try testing.expectEqual(@as(usize, 0), empty.diagnostics.len);
    try testing.expect(empty.message == null);
    // Nothing was generated or staged in the project.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, @import("rootgen.zig").root_file_name, .{}));

    // With a script, the build needs Zig again.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const extends = \"Node\";\n" });
    const needs = try buildOnce(svc, a, .play);
    defer freeOutcome(a, needs);
    try testing.expect(!needs.ok);
    try testing.expectEqual(ZigProblem.missing, needs.zig_problem);
}

test "requestIfChanged skips an unchanged tree" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const extends = \"Node\";\n" });
    // No Zig anywhere in this configuration: every build of this project
    // (it has a script) fails fast in the locator, after the scan.
    const svc = try BuildService.init(a, io, testConfig(base, &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }}));
    defer svc.deinit();

    // No build has scanned yet: the check builds.
    svc.requestIfChanged(.watcher);
    try svc.waitIdle(30_000);
    try testing.expectEqual(Trigger.watcher, svc.last().?.trigger);
    var st = svc.stats();
    try testing.expectEqual(@as(u32, 1), st.builds);
    try testing.expectEqual(@as(u32, 1), st.checks);
    try testing.expectEqual(@as(u32, 0), st.checks_skipped);

    // Nothing changed: no build and no outcome.
    svc.requestIfChanged(.watcher);
    try svc.waitIdle(30_000);
    st = svc.stats();
    try testing.expectEqual(@as(u32, 1), st.builds);
    try testing.expectEqual(@as(u32, 2), st.checks);
    try testing.expectEqual(@as(u32, 1), st.checks_skipped);
    try testing.expect(!svc.busy());

    // A new helper file: built.
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.zig", .data = "pub fn f() void {}\n" });
    svc.requestIfChanged(.watcher);
    try svc.waitIdle(30_000);
    try testing.expectEqual(@as(u32, 2), svc.stats().builds);

    // An edit of the same size: built.
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.zig", .data = "pub fn g() void {}\n" });
    svc.requestIfChanged(.watcher);
    try svc.waitIdle(30_000);
    try testing.expectEqual(@as(u32, 3), svc.stats().builds);

    // A plain request builds without a change; the check after it does not.
    svc.request(.manual);
    try svc.waitIdle(30_000);
    try testing.expectEqual(Trigger.manual, svc.last().?.trigger);
    svc.requestIfChanged(.watcher);
    try svc.waitIdle(30_000);
    st = svc.stats();
    try testing.expectEqual(@as(u32, 4), st.builds);
    try testing.expectEqual(@as(u32, 5), st.checks);
    try testing.expectEqual(@as(u32, 2), st.checks_skipped);
    try testing.expectEqual(Trigger.manual, svc.last().?.trigger);
}

fn testConfig(base: []const u8, sdk: []const workspace.ModuleDep) Config {
    const env: platform.path.HostEnv = .{ .os = builtin.os.tag, .home = base, .xdg_cache_home = base, .local_app_data = base };
    return .{
        .paths = .init(.{ .project = .fromTrusted(base) }, env),
        .locate = .{ .configured = null, .toolchain_dir = .fromTrusted(base), .env = env },
        .sdk = sdk,
        .store_root = .fromTrusted(base),
    };
}

test "init refuses an sdk list without a ziggurat module" {
    const a = testing.allocator;
    var diag: [256]u8 = undefined;
    const sdk = [_]workspace.ModuleDep{.{ .name = "gdzig", .root = .fromTrusted("/sdk/gdzig.zig"), .deps = &.{} }};
    try testing.expectError(error.MissingSdkModule, BuildService.initDiag(a, testing.io, testConfig("/p", &sdk), &diag));
    try testing.expectEqualStrings(
        "The SDK module list (gdzig) has no module named \"ziggurat\"; add the Ziggurat SDK to it.",
        platform.elf.diagText(&diag),
    );
    try testing.expectError(error.MissingSdkModule, BuildService.init(a, testing.io, testConfig("/p", &.{})));
    try testing.expectEqual(@as(u32, 0), liveThreads());
}

test "init refuses the table check without an expected stamp" {
    const a = testing.allocator;
    var diag: [256]u8 = undefined;
    const sdk = [_]workspace.ModuleDep{.{ .name = "ziggurat", .root = .fromTrusted("/sdk/z.zig"), .deps = &.{} }};
    var cfg = testConfig("/p", &sdk);
    cfg.check_tables = true;
    try testing.expectError(error.MissingExpectedStamp, BuildService.initDiag(a, testing.io, cfg, &diag));
    try testing.expectEqualStrings(
        "The table check is on but no expected layout stamp is set; set Config.expected_stamp.",
        platform.elf.diagText(&diag),
    );
    try testing.expectEqual(@as(u32, 0), liveThreads());
}

test "init refuses a target that is not the host" {
    const a = testing.allocator;
    var diag: [256]u8 = undefined;
    const sdk = [_]workspace.ModuleDep{.{ .name = "ziggurat", .root = .fromTrusted("/sdk/z.zig"), .deps = &.{} }};
    var cfg = testConfig("/p", &sdk);
    var t = builtin.target;
    t.os.tag = if (builtin.os.tag == .windows) .linux else .windows;
    cfg.target = t;
    try testing.expectError(error.TargetNotHost, BuildService.initDiag(a, testing.io, cfg, &diag));
    try testing.expect(std.mem.startsWith(u8, platform.elf.diagText(&diag), "The build target "));
    t = builtin.target;
    t.cpu.arch = if (builtin.cpu.arch == .aarch64) .x86_64 else .aarch64;
    cfg.target = t;
    try testing.expectError(error.TargetNotHost, BuildService.initDiag(a, testing.io, cfg, &diag));
}

test "stagingMessage names the staged file" {
    const a = testing.allocator;
    const m1 = try stagingMessage(a, "/c/build/libzmod.so", "The file is not a 64-bit little-endian ELF file (3 bytes).");
    defer a.free(m1);
    try testing.expectEqualStrings("Staging /c/build/libzmod.so failed: the file is not a 64-bit little-endian ELF file (3 bytes).", m1);
    // An ELF word stays as written.
    const m2 = try stagingMessage(a, "/c/x.so", "ELF data is short.");
    defer a.free(m2);
    try testing.expectEqualStrings("Staging /c/x.so failed: ELF data is short.", m2);
    // A message that already names the file is kept.
    const m3 = try stagingMessage(a, "/c/x.so", "Staging /c/x.so failed: AccessDenied.");
    defer a.free(m3);
    try testing.expectEqualStrings("Staging /c/x.so failed: AccessDenied.", m3);
}

/// The lines of `<base>/argv.log`: one line per compiler start, the
/// arguments the fake Zig of the debugger-builds test was given.
fn argvLines(a: std.mem.Allocator, dir: std.Io.Dir) ![]const []const u8 {
    const text = try dir.readFileAlloc(testing.io, "argv.log", a, .limited(1 << 20));
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, l);
    return lines.items;
}

fn hasArg(line: []const u8, arg: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    while (it.next()) |x| if (std.mem.eql(u8, x, arg)) return true;
    return false;
}

test "debugger builds: argv has -fllvm and no -fincremental, no warm server starts" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);
    // Reports the pinned version; every compiler start writes its
    // arguments to argv.log and fails at once (no compiler runs).
    const fake = try std.fmt.allocPrint(arena, "#!/bin/sh\nif [ \"$1\" = version ]; then echo " ++ platform.pins.zig_version ++ "; exit 0; fi\necho \"$*\" >> '{s}/argv.log'\nexit 1\n", .{base});
    try tmp.dir.writeFile(io, .{ .sub_path = "fake-zig", .data = fake, .flags = .{ .permissions = .executable_file } });
    const zig = try std.fs.path.join(arena, &.{ base, "fake-zig" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const extends = \"Node\";\n" });
    var cfg = testConfig(base, &.{.{ .name = "ziggurat", .root = .fromTrusted(base), .deps = &.{} }});
    cfg.locate.configured = .fromTrusted(zig);
    // Debugger builds win over the backend override.
    cfg.debugger_builds = true;
    cfg.policy_override = .{ .incremental = true, .use_llvm = false, .optimize = .Debug };
    const svc = try BuildService.init(a, io, cfg);
    defer svc.deinit();

    const first = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, first);
    var lines = try argvLines(arena, tmp.dir);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expect(hasArg(lines[0], "-fllvm"));
    try testing.expect(!hasArg(lines[0], "-fincremental"));
    try testing.expect(hasArg(lines[0], "-ODebug"));
    try testing.expect(svc.stats().warm != .warming and svc.stats().warm != .ready);

    // Off, with the override: applies at the next build.
    svc.setPolicy(.{ .incremental = false, .use_llvm = false, .optimize = .Debug }, false);
    const second = try buildOnce(svc, a, .manual);
    defer freeOutcome(a, second);
    lines = try argvLines(arena, tmp.dir);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expect(hasArg(lines[1], "-fno-llvm"));
    try testing.expect(!hasArg(lines[1], "-fincremental"));

    // On again, with an incremental override: debugger builds still win.
    svc.setPolicy(.{ .incremental = true, .use_llvm = false, .optimize = .Debug }, true);
    const third = try buildOnce(svc, a, .save);
    defer freeOutcome(a, third);
    lines = try argvLines(arena, tmp.dir);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expect(hasArg(lines[2], "-fllvm"));
    try testing.expect(!hasArg(lines[2], "-fincremental"));
    try testing.expect(svc.stats().warm != .warming and svc.stats().warm != .ready);
}
