//! "Download Zig 0.17.0" in the editor (spec section 9). Only on the
//! user's request (Tools menu); never in an export build.
//!
//! Steps, all started on the main thread:
//!
//! 1. The community mirror list. A copy younger than 24 hours in
//!    `<user data>/ziggurat/mirrors.txt` is used without a request;
//!    otherwise it is fetched from `mirrors.list_url` (at most 64 KiB,
//!    status 200) and, when it parses, saved there. A list that cannot be
//!    fetched or parsed falls back to an older saved copy that parses, else
//!    to ziglang.org only.
//! 2. The order: the mirrors shuffled with a ChaCha CSPRNG seeded from the
//!    process Io's random source, then ziglang.org (`mirrors.urls`).
//! 3. Per mirror: the `.minisig` into memory (at most 4096 bytes, status
//!    200), checked at once for all but the file signature (format `ED`,
//!    key id, global signature, `file:` name; `minisign.verifyBeforeFile`),
//!    so a bad one moves to the next mirror without the archive transfer;
//!    then the archive into `<toolchains>/.download-<random>` (at most
//!    the pinned size, status 200). Godot's HTTPRequest does the transfers,
//!    polled each frame on the main thread, and reports there
//!    (`request_completed`, received by the editor plugin's bound method).
//!    A non-200 status still comes as RESULT_SUCCESS, so the status is
//!    checked; redirects (also https to http) are followed, which is safe
//!    because nothing is trusted before the checks below.
//! 4. The check and install (`toolchain_install.install`: size, SHA-256,
//!    minisign signature with the pinned key and file name, unpack into a
//!    temporary folder, `zig version`, rename to `<toolchains>/zig-0.17.0`)
//!    runs on a worker thread, under the toolchain lock
//!    `<toolchains>/.install.lock` so two editors cannot install at once.
//!    It needs about 800 MB of memory for a few seconds. The worker deletes
//!    the downloaded file afterwards and hands the result back through the
//!    main-thread queue; the next frame (`tick`) takes it.
//!
//! Before the first request, under the toolchain lock (skipped while
//! another editor holds it), leftovers of a crashed run older than an hour
//! are deleted (`toolchain_install.sweepLeftovers`).
//!
//! Any failure of a mirror deletes its temporary file, logs the mirror and
//! the reason and tries the next one; no unchecked file is ever used. When
//! every place failed the state is `failed`. After `done` the editor plugin
//! asks for a build (`requestBuild(.manual)`), so the locator finds the new
//! Zig. `cancel` stops a transfer (Godot deletes the partial file; it is
//! deleted here too); the check cannot be stopped and ends by itself.
//! At editor exit (`detach`) a transfer is cancelled and a running check
//! is waited for, so no thread outlives the library and no temporary file
//! stays (the install deletes its temporary folder on every path).
//!
//! Test overrides (probe builds only, `configureForTest`): the mirror list
//! URL, the ziglang.org stand-in, the key and the archive pin (or neither,
//! for the pinned ones), plain http for the local fixture server, and the
//! toolchains folder. Product builds use the pinned values.
const std = @import("std");
const builtin = @import("builtin");
const godot = @import("gdzig");
const host_options = @import("host_options");
const platform = @import("ziggurat_platform");
const editor_build = @import("editor_build.zig");
const host_io = @import("host_io.zig");
const host_callable = @import("host_callable.zig");
const main_queue = @import("main_queue.zig");
const props = @import("props.zig");

const pins = platform.pins;
const mirrors = platform.mirrors;
const minisign = platform.minisign;
const toolchain_install = platform.toolchain_install;
const OsPath = platform.path.OsPath;

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedByteArray = godot.builtin.PackedByteArray;
const Object = godot.class.Object;
const Node = godot.class.Node;
const HttpRequest = godot.class.HttpRequest;

pub const State = union(enum) {
    idle,
    fetching_mirrors,
    downloading: struct { mirror: []const u8, bytes: u64, total: u64 },
    checking,
    done,
    failed: struct { reason: []const u8 },
};

/// The panel line while the worker checks and unpacks.
pub const checking_text = "Checking and unpacking Zig (needs about 800 MB of memory)";
pub const installed_text = "Zig " ++ pins.zig_version ++ " installed";

/// The bound method of the editor plugin that receives `request_completed`.
pub const completed_method = "on_download_completed";

/// The time limits of a run. Probe builds may override them
/// (`configureForTest`); product builds use `default_timings`.
const Timings = struct {
    /// How long a mirror list or signature request may take.
    request_timeout_ms: u32 = 30_000,
    /// An archive transfer that gets no new byte for this long fails the
    /// mirror.
    stall_ms: u32 = 60_000,
    /// An archive transfer slower than this on average fails the mirror
    /// once its deadline (the pinned size at this speed, at least
    /// `min_deadline_ms`) has passed, so a mirror that trickles cannot hold
    /// the run.
    min_bytes_per_s: u64 = 32 * 1024,
    min_deadline_ms: u64 = 5 * 60_000,
    /// Replaces the computed deadline (tests).
    archive_deadline_ms: ?u64 = null,
};
const default_timings: Timings = .{};

/// The deadline of an archive transfer of `size` bytes.
fn archiveDeadlineMs(t: Timings, size: u64) u64 {
    if (t.archive_deadline_ms) |d| return d;
    const at_floor = size / @max(t.min_bytes_per_s, 1) *| 1000;
    return @max(at_floor, t.min_deadline_ms);
}
/// Bytes one frame reads at most (Godot's range is 256 B to 16 MiB).
const download_chunk = 1 << 20;
/// How long `start` lets an installed `zig version` take (main thread).
const installed_check_ms = 5_000;
/// How long the worker waits for another editor's install.
const lock_timeout_ms = 300_000;
const lock_name = ".install.lock";
const download_prefix = toolchain_install.download_prefix;
const cache_name = "mirrors.txt";

const gpa = std.heap.c_allocator;
const max_path_bytes = 4096;

const Phase = enum { idle, list, signature, archive, checking, done, failed };

/// Everything below is main-thread state.
var target: ?*Object = null;
var parent: ?*Node = null;
var phase: Phase = .idle;
var http: ?*HttpRequest = null;
var conf: Config = undefined;
/// `<toolchains>` and `<user data>/ziggurat`, for one run.
var tc_dir: ?[]u8 = null;
var data_dir: ?[]u8 = null;
/// A saved list older than 24 hours that parses (the fallback).
var stale_list: ?[][]const u8 = null;
var url_list: []mirrors.Url = &.{};
var next_url: usize = 0;
var current: usize = 0;
var sig_text: ?[]u8 = null;
var download_path: ?[]u8 = null;
var bytes: u64 = 0;
var last_bytes_ms: i64 = 0;
/// When the archive transfer started and how long it may take.
var archive_start_ms: i64 = 0;
var archive_deadline_ms: u64 = 0;
var reason_buf: [256]u8 = undefined;
var reason_len: usize = 0;
var worker: ?std.Thread = null;
/// Bumped when a run ends early, so a late worker result is dropped.
var serial: u32 = 0;
/// A worker result taken from the main-thread queue, for the next `tick`.
var finished: ?*Job = null;
/// Set at editor exit: a worker still waiting for the toolchain lock gives
/// up at once (any thread reads it).
var quitting: std.atomic.Value(bool) = .init(false);

/// Bumped on every change the panel shows. Main thread.
pub var changes: u32 = 0;
/// Bumped each time a download reaches `done` / `failed`. Main thread.
pub var completions: u32 = 0;
pub var failures: u32 = 0;
/// HTTP requests started (for the host tests). Main thread.
pub var requests: u32 = 0;

const Config = struct {
    list_url: []const u8,
    /// Null: ziglang.org (`mirrors.urls`).
    official_base: ?[]const u8,
    key: minisign.PublicKey,
    archive: pins.Archive,
    plain_http: bool,
    timings: Timings,
};

/// Where the HTTPRequest nodes live and who receives their completion
/// (the editor plugin). Called when the plugin enters the tree.
pub fn attach(receiver: *Object, node: *Node) void {
    comptime std.debug.assert(!host_options.export_build);
    target = receiver;
    parent = node;
}

/// Ends any run: cancels a transfer, waits for a running check, deletes
/// temporary files. Called when the plugin leaves the tree.
pub fn detach() void {
    quitting.store(true, .release);
    dropHttp(.now);
    endRun();
    joinWorker();
    quitting.store(false, .release);
    if (finished) |j| freeJob(j);
    finished = null;
    if (phase != .idle) {
        phase = .idle;
        changes +%= 1;
    }
    target = null;
    parent = null;
}

/// Last chance at SCENE exit: a worker still running is waited for.
pub fn stop() void {
    comptime std.debug.assert(!host_options.export_build);
    quitting.store(true, .release);
    joinWorker();
}

pub fn state() State {
    return switch (phase) {
        .idle => .idle,
        .list => .fetching_mirrors,
        .signature, .archive => .{ .downloading = .{ .mirror = currentBase(), .bytes = bytes, .total = conf.archive.size } },
        .checking => .checking,
        .done => .done,
        .failed => .{ .failed = .{ .reason = reason_buf[0..reason_len] } },
    };
}

/// The panel's text for `st`.
pub fn stateText(buf: []u8, st: State) []const u8 {
    return switch (st) {
        .idle => "Zig download cancelled",
        .fetching_mirrors => "Downloading Zig " ++ pins.zig_version ++ ": reading the mirror list",
        .downloading => |d| std.fmt.bufPrint(buf, "Downloading Zig " ++ pins.zig_version ++ " from {s}: {d}.{d} of {d}.{d} MB", .{
            d.mirror, d.bytes / 1_000_000, d.bytes % 1_000_000 / 100_000, d.total / 1_000_000, d.total % 1_000_000 / 100_000,
        }) catch "Downloading Zig " ++ pins.zig_version,
        .checking => checking_text,
        .done => installed_text,
        .failed => |f| std.fmt.bufPrint(buf, "Zig download failed: {s}", .{f.reason}) catch "Zig download failed",
    };
}

/// Starts a download (Tools > Download Zig 0.17.0). Ignored while one runs.
pub fn start() void {
    comptime std.debug.assert(!host_options.export_build);
    switch (phase) {
        .idle, .done, .failed => {},
        else => {
            log("Ziggurat is already downloading Zig " ++ pins.zig_version ++ ".", .{});
            return;
        },
    }
    if (parent == null) return;
    endRun();
    reason_len = 0;
    conf = config() orelse return;
    folders() catch |err| return fail("the toolchains folder cannot be made ({t})", .{err});
    // A working Zig is already there: nothing to download. `zig version`
    // of a real Zig answers in milliseconds; the bound covers a broken one.
    if (toolchain_install.installedWorks(host_io.get(), gpa, tc_dir.?, installed_check_ms)) {
        log("Zig " ++ pins.zig_version ++ " is already installed in {s}/" ++ toolchain_install.target_name ++ "; Ziggurat does not download it again.", .{tc_dir.?});
        endRun();
        phase = .done;
        completions +%= 1;
        changes +%= 1;
        return;
    }
    sweepLeftovers();
    log("Ziggurat downloads Zig " ++ pins.zig_version ++ " into {s}.", .{tc_dir.?});
    if (readCache()) |list| return useList(list);
    phase = .list;
    changes +%= 1;
    if (!request(conf.list_url, mirrors.max_list_bytes, null, conf.timings.request_timeout_ms)) listDone(null);
}

/// Stops a transfer (the check cannot be stopped).
pub fn cancel() void {
    switch (phase) {
        .list, .signature, .archive => {
            dropHttp(.later);
            endRun();
            phase = .idle;
            changes +%= 1;
            log("Ziggurat cancelled the Zig download.", .{});
        },
        .checking => log("Ziggurat cannot stop the Zig check; it ends in a few seconds.", .{}),
        else => {},
    }
}

/// Each frame (the editor plugin's `_process`): takes a worker result,
/// follows the transfer's progress and fails a stalled mirror.
pub fn tick() void {
    if (finished) |job| {
        finished = null;
        installed(job);
    }
    if (phase != .archive) return;
    const node = http orelse return;
    const now = nowMs();
    const got: u64 = @intCast(@max(node.getDownloadedBytes(), 0));
    if (got != bytes) {
        bytes = got;
        last_bytes_ms = now;
        changes +%= 1;
    }
    const t = conf.timings;
    if (now - last_bytes_ms > t.stall_ms) {
        dropHttp(.later);
        deleteDownload();
        mirrorFailed("no data for {d} ms", .{t.stall_ms});
    } else if (now - archive_start_ms > archive_deadline_ms) {
        dropHttp(.later);
        deleteDownload();
        mirrorFailed("too slow: {d} of {d} bytes after {d} ms", .{ bytes, conf.archive.size, archive_deadline_ms });
    }
}

/// `request_completed` of the current HTTPRequest (through the editor
/// plugin). Main thread.
pub fn onCompleted(result: i64, code: i64, body: *const PackedByteArray) void {
    const node = http orelse return;
    const got: u64 = @intCast(@max(node.getDownloadedBytes(), 0));
    dropHttp(.later);
    const ok = result == 0 and code == 200;
    switch (phase) {
        .list => listDone(if (ok) bodyBytes(body) else blk: {
            var buf: [64]u8 = undefined;
            log("Ziggurat could not fetch the Zig mirror list: {s}.", .{httpReason(&buf, result, code)});
            break :blk null;
        }),
        .signature => {
            if (!ok) return httpFailed(result, code);
            const text = bodyBytes(body);
            if (text.len == 0 or text.len > minisign.max_signature_text) return mirrorFailed("the signature file has {d} bytes", .{text.len});
            // Everything but the file signature is checked now, so a bad
            // signature file costs no archive transfer.
            minisign.verifyBeforeFile(conf.key, text, conf.archive.name) catch |err|
                return mirrorFailed("{s}", .{toolchain_install.describe(err)});
            sig_text = gpa.dupe(u8, text) catch return fail("out of memory", .{});
            startArchive();
        },
        .archive => {
            if (!ok) {
                deleteDownload();
                // Godot reports a connection closed in the middle of the
                // body as "cannot connect"; say what happened.
                if (result != 0 and got > 0) {
                    var buf: [64]u8 = undefined;
                    return mirrorFailed("the transfer stopped after {d} of {d} bytes ({s})", .{ got, conf.archive.size, httpReason(&buf, result, code) });
                }
                return httpFailed(result, code);
            }
            startCheck();
        },
        else => {},
    }
}

// ------------------------------------------------------------ steps

fn config() ?Config {
    if (comptime host_options.test_probe) {
        if (test_config) |t| if (!t.pinned) return .{
            .list_url = t.list_url,
            .official_base = t.official_base,
            .key = t.key,
            .archive = .{ .name = t.archive_name, .size = t.archive_size, .sha256 = t.archive_sha256 },
            .plain_http = t.plain_http,
            .timings = t.timings,
        };
    }
    const archive = pins.zig_archive(.of(builtin.target)) orelse {
        fail("Ziggurat offers no Zig download for {t}-{t} yet; install Zig " ++ pins.zig_version ++ " and set " ++ editor_build.setting_zig_path, .{ builtin.cpu.arch, builtin.os.tag });
        return null;
    };
    const key = minisign.PublicKey.parse(pins.zig_minisign_key) catch {
        fail("the pinned Zig key does not parse", .{});
        return null;
    };
    var c: Config = .{ .list_url = mirrors.list_url, .official_base = null, .key = key, .archive = archive, .plain_http = false, .timings = default_timings };
    if (comptime host_options.test_probe) {
        // The pinned key and archive, from the test's mirrors.
        if (test_config) |t| {
            c.list_url = t.list_url;
            c.official_base = t.official_base;
            c.plain_http = t.plain_http;
            c.timings = t.timings;
        }
    }
    return c;
}

/// Finds and makes `<toolchains>` and `<user data>/ziggurat`.
fn folders() !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const tc: platform.path.OsPath = override: {
        if (comptime host_options.test_probe) {
            if (test_config) |t| if (t.toolchains_dir) |d| break :override .{ .bytes = try gpa.dupe(u8, d) };
        }
        const env = try editor_build.hostEnv(arena_state.allocator());
        const paths: platform.path.PathService = .init(.{ .project = .fromTrusted("/") }, env);
        break :override try paths.dir(.toolchain, gpa);
    };
    tc_dir = @constCast(tc.bytes);
    data_dir = try gpa.dupe(u8, std.fs.path.dirname(tc.bytes) orelse return error.NoDataFolder);
    const io = host_io.get();
    try std.Io.Dir.cwd().createDirPath(io, tc.bytes);
}

/// Deletes what a crashed run left in `<toolchains>` (older than an hour;
/// `toolchain_install.sweepLeftovers`), under the toolchain lock. Skipped
/// while another editor holds the lock (it installs now).
fn sweepLeftovers() void {
    const io = host_io.get();
    var buf: [max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&buf, "{s}/" ++ lock_name, .{tc_dir.?}) catch return;
    var lock = platform.lock.FileLock.acquire(io, .fromTrusted(lock_path), .exclusive, 0) catch return;
    defer lock.release();
    const now = std.Io.Clock.real.now(io).nanoseconds;
    const n = toolchain_install.sweepLeftovers(io, tc_dir.?, now, toolchain_install.leftover_age_ns);
    if (n != 0) log("Ziggurat deleted {d} leftovers of an earlier Zig download in {s}.", .{ n, tc_dir.? });
}

/// The saved list when it is younger than 24 hours and parses. An older
/// one that parses is kept as the fallback (`stale_list`).
fn readCache() ?[][]const u8 {
    const io = host_io.get();
    var buf: [max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/" ++ cache_name, .{data_dir.?}) catch return null;
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(mirrors.max_list_bytes + 1)) catch return null;
    defer gpa.free(text);
    const list = mirrors.parse(gpa, text) catch {
        log("Ziggurat ignores the saved Zig mirror list {s}: it does not parse.", .{p});
        return null;
    };
    const now = std.Io.Clock.real.now(io).nanoseconds;
    if (mirrors.cacheFresh(st.mtime.nanoseconds, now)) return list;
    stale_list = list;
    return null;
}

fn writeCache(text: []const u8) void {
    const io = host_io.get();
    var buf: [max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/" ++ cache_name, .{data_dir.?}) catch return;
    platform.atomic_file.write(io, .fromTrusted(p), text) catch |err|
        log("Ziggurat could not save the Zig mirror list to {s} ({t}).", .{ p, err });
}

/// The fetched list (null: the fetch failed, already logged).
fn listDone(fetched: ?[]const u8) void {
    if (fetched) |text| {
        if (mirrors.parse(gpa, text)) |list| {
            writeCache(text);
            return useList(list);
        } else |_| {
            log("Ziggurat could not read the Zig mirror list: it does not parse.", .{});
        }
    }
    if (stale_list) |list| {
        stale_list = null;
        log("Ziggurat uses the older saved Zig mirror list.", .{});
        return useList(list);
    }
    log("Ziggurat tries ziglang.org only.", .{});
    useList(&.{});
}

/// Makes the order of places from `list` (taken over) and tries the first.
fn useList(list: [][]const u8) void {
    defer mirrors.freeList(gpa, list);
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    host_io.get().random(&seed);
    var csprng: std.Random.DefaultCsprng = .init(seed);
    const rng = csprng.random();
    url_list = if (conf.official_base) |last|
        mirrors.urlsWith(gpa, list, conf.archive.name, rng, last) catch return fail("the mirror list cannot be used", .{})
    else
        mirrors.urls(gpa, list, conf.archive.name, rng) catch return fail("the mirror list cannot be used", .{});
    next_url = 0;
    tryNext();
}

/// The signature of the next place, or `failed` when none is left.
fn tryNext() void {
    deleteDownload();
    freeSig();
    if (next_url >= url_list.len) return fail("No mirror and not ziglang.org gave a valid Zig " ++ pins.zig_version ++ "; see the Output log for each reason.", .{});
    current = next_url;
    next_url += 1;
    bytes = 0;
    phase = .signature;
    changes +%= 1;
    if (!request(url_list[current].signature, minisign.max_signature_text, null, conf.timings.request_timeout_ms))
        mirrorFailed("the request could not start", .{});
}

fn startArchive() void {
    const size = std.math.cast(i32, conf.archive.size) orelse return fail("the pinned archive is too large for Godot's HTTPRequest", .{});
    var hex: [8]u8 = undefined;
    host_io.get().random(&hex);
    download_path = std.fmt.allocPrint(gpa, "{s}/" ++ download_prefix ++ "{s}", .{ tc_dir.?, &std.fmt.bytesToHex(hex, .lower) }) catch return fail("out of memory", .{});
    phase = .archive;
    bytes = 0;
    last_bytes_ms = nowMs();
    archive_start_ms = last_bytes_ms;
    archive_deadline_ms = archiveDeadlineMs(conf.timings, conf.archive.size);
    changes +%= 1;
    // No HTTPRequest timeout (a slow line may need minutes); `tick` fails a
    // transfer that stalls or misses its deadline.
    if (!request(url_list[current].archive, size, download_path, 0)) {
        deleteDownload();
        mirrorFailed("the request could not start", .{});
    }
}

/// Hands the downloaded file to a worker thread.
fn startCheck() void {
    const job = gpa.create(Job) catch return fail("out of memory", .{});
    job.* = .{
        .serial = serial,
        .mirror = gpa.dupe(u8, url_list[current].base) catch null,
        .archive_path = download_path.?,
        .sig_text = sig_text.?,
        .toolchains = gpa.dupe(u8, tc_dir.?) catch null,
        .archive_name = gpa.dupe(u8, conf.archive.name) catch null,
        .archive = conf.archive,
        .key = conf.key,
    };
    // The job owns the file's path and the signature now.
    download_path = null;
    sig_text = null;
    if (job.mirror == null or job.toolchains == null or job.archive_name == null) {
        deleteFile(job.archive_path);
        freeJob(job);
        return fail("out of memory", .{});
    }
    worker = std.Thread.spawn(.{}, work, .{job}) catch |err| {
        deleteFile(job.archive_path);
        freeJob(job);
        return fail("the check thread cannot start ({t})", .{err});
    };
    phase = .checking;
    changes +%= 1;
}

/// A worker result (from `tick`).
fn installed(job: *Job) void {
    defer freeJob(job);
    joinWorker();
    if (job.serial != serial or phase != .checking) return;
    if (job.lock_error) |err| return fail("the toolchain lock {s}/" ++ lock_name ++ " cannot be taken ({t})", .{ tc_dir.?, err });
    const r = job.result catch |err| return mirrorFailed("{s}", .{toolchain_install.describe(err)});
    switch (r) {
        .installed => log("Ziggurat installed Zig " ++ pins.zig_version ++ " from {s} in {s}/" ++ toolchain_install.target_name ++ ".", .{ job.mirror.?, tc_dir.? }),
        .already_present => log("Ziggurat found Zig " ++ pins.zig_version ++ " already installed in {s}/" ++ toolchain_install.target_name ++ ".", .{tc_dir.?}),
    }
    endRun();
    phase = .done;
    completions +%= 1;
    changes +%= 1;
}

fn httpFailed(result: i64, code: i64) void {
    var buf: [64]u8 = undefined;
    mirrorFailed("{s}", .{httpReason(&buf, result, code)});
}

fn mirrorFailed(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const why = std.fmt.bufPrint(&buf, fmt, args) catch "an unknown reason";
    log("Ziggurat could not use the Zig mirror {s}: {s}", .{ currentBase(), why });
    tryNext();
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    var tmp: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tmp);
    const cut = if (w.print(fmt, args)) |_| false else |_| true;
    const why = fitUtf8(&reason_buf, w.buffered(), cut);
    reason_len = why.len;
    endRun();
    phase = .failed;
    failures +%= 1;
    changes +%= 1;
    logError("Ziggurat could not download Zig " ++ pins.zig_version ++ ": {s}", .{why});
}

/// Frees what a run holds and deletes its temporary file. A worker still
/// running keeps its own copies; its result is dropped.
fn endRun() void {
    deleteDownload();
    freeSig();
    mirrors.freeUrls(gpa, url_list);
    url_list = &.{};
    next_url = 0;
    if (stale_list) |l| mirrors.freeList(gpa, l);
    stale_list = null;
    if (tc_dir) |d| gpa.free(d);
    tc_dir = null;
    if (data_dir) |d| gpa.free(d);
    data_dir = null;
    if (phase == .checking) serial +%= 1;
}

/// `text` in `dst`, cut on a UTF-8 character boundary with "…" when it
/// does not fit or `cut` says it was cut already.
fn fitUtf8(dst: []u8, text: []const u8, cut: bool) []const u8 {
    const ellipsis = "\u{2026}";
    if (!cut and text.len <= dst.len) {
        @memcpy(dst[0..text.len], text);
        return dst[0..text.len];
    }
    var n = @min(text.len, dst.len - ellipsis.len);
    // Back off continuation bytes (10xxxxxx) to a character start.
    while (n > 0 and n < text.len and text[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(dst[0..n], text[0..n]);
    @memcpy(dst[n..][0..ellipsis.len], ellipsis);
    return dst[0 .. n + ellipsis.len];
}

fn currentBase() []const u8 {
    return if (current < url_list.len) url_list[current].base else "";
}

fn freeSig() void {
    if (sig_text) |s| gpa.free(s);
    sig_text = null;
}

fn deleteDownload() void {
    const p = download_path orelse return;
    deleteFile(p);
    gpa.free(p);
    download_path = null;
}

fn deleteFile(p: []const u8) void {
    std.Io.Dir.cwd().deleteFile(host_io.get(), p) catch {};
}

fn joinWorker() void {
    if (worker) |t| t.join();
    worker = null;
}

// ------------------------------------------------------------ HTTP

/// Starts one request on a new HTTPRequest node: the body goes to memory
/// (at most `limit` bytes) or to `file`. False when it cannot start.
fn request(url: []const u8, limit: i32, file: ?[]const u8, timeout_ms: u32) bool {
    const p = parent orelse return false;
    const t = target orelse return false;
    const node = HttpRequest.init();
    // Polled each frame, not on a Godot thread: `cancel_request` waits for
    // that thread, which blocks in a read while a mirror sends nothing, so
    // a cancel (or the editor's exit) would hang the editor.
    node.setUseThreads(false);
    node.setDownloadChunkSize(download_chunk);
    node.setAcceptGzip(false);
    node.setBodySizeLimit(limit);
    node.setTimeout(@as(f64, @floatFromInt(timeout_ms)) / 1000.0);
    if (file) |f| {
        var s = props.gstring(f);
        defer s.deinit();
        node.setDownloadFile(s);
    }
    p.addChild(.upcast(node), .{});
    var c = host_callable.callable(t, completed_method);
    defer c.deinit();
    _ = Object.upcast(node).connectRaw(.fromComptimeLatin1("request_completed"), c, .{});
    http = node;
    var buf: [2048]u8 = undefined;
    var u = props.gstring(requestUrl(&buf, url));
    defer u.deinit();
    requests +%= 1;
    if (node.request(u, .{}) != .ok) {
        dropHttp(.now);
        return false;
    }
    return true;
}

const When = enum { now, later };

/// Stops and frees the current HTTPRequest node. Inside its own signal
/// (and from a button) it is freed at the end of the frame; at exit at once.
fn dropHttp(when: When) void {
    const node = http orelse return;
    http = null;
    const obj = Object.upcast(node);
    if (target) |t| {
        var c = host_callable.callable(t, completed_method);
        defer c.deinit();
        const sig: StringName = .fromComptimeLatin1("request_completed");
        if (obj.isConnected(sig, c)) obj.disconnectRaw(sig, c);
    }
    node.cancelRequest();
    switch (when) {
        .later => node.queueFree(),
        .now => {
            if (parent) |p| p.removeChild(.upcast(node));
            node.destroy();
        },
    }
}

/// `url`, with `https://` changed to `http://` in a probe build whose test
/// configuration asks for it (the local fixture server).
fn requestUrl(buf: []u8, url: []const u8) []const u8 {
    if (comptime host_options.test_probe) {
        if (conf.plain_http and std.mem.startsWith(u8, url, "https://"))
            return std.fmt.bufPrint(buf, "http://{s}", .{url["https://".len..]}) catch url;
    }
    return url;
}

fn bodyBytes(body: *const PackedByteArray) []const u8 {
    const n: usize = @intCast(@max(body.size(), 0));
    if (n == 0) return "";
    const first: [*]const u8 = @ptrCast(body.indexConst(0));
    return first[0..n];
}

/// A short reason for a failed request.
pub fn httpReason(buf: []u8, result: i64, code: i64) []const u8 {
    return switch (result) {
        0 => std.fmt.bufPrint(buf, "HTTP status {d}", .{code}) catch "HTTP status",
        1 => "the response was cut off",
        2 => "could not connect",
        3 => "could not resolve the host name",
        4 => "the connection failed",
        5 => "the TLS handshake failed",
        6 => "no response",
        7 => "the response is larger than expected",
        8 => "the response could not be decompressed",
        9 => "the request failed",
        10 => "the download file cannot be created",
        11 => "the download file cannot be written",
        12 => "too many redirects",
        13 => "the request timed out",
        else => std.fmt.bufPrint(buf, "HTTPRequest result {d}", .{result}) catch "HTTPRequest failed",
    };
}

// ------------------------------------------------------------ worker

const Job = struct {
    serial: u32,
    mirror: ?[]u8,
    archive_path: []u8,
    sig_text: []u8,
    toolchains: ?[]u8,
    archive_name: ?[]u8,
    archive: pins.Archive,
    key: minisign.PublicKey,
    result: toolchain_install.Error!toolchain_install.Result = error.Canceled,
    lock_error: ?anyerror = null,
};

fn freeJob(job: *Job) void {
    if (job.mirror) |m| gpa.free(m);
    gpa.free(job.archive_path);
    gpa.free(job.sig_text);
    if (job.toolchains) |t| gpa.free(t);
    if (job.archive_name) |n| gpa.free(n);
    gpa.destroy(job);
}

/// The worker thread: lock, check and install, unlock, delete the file,
/// hand the job back. Blocking; never touches Godot.
fn work(job: *Job) void {
    const io = host_io.get();
    run: {
        var lock_buf: [max_path_bytes]u8 = undefined;
        const lock_path = std.fmt.bufPrint(&lock_buf, "{s}/" ++ lock_name, .{job.toolchains.?}) catch {
            job.lock_error = error.NameTooLong;
            break :run;
        };
        var lock = lockToolchains(io, lock_path) catch |err| {
            job.lock_error = err;
            break :run;
        };
        defer lock.release();
        var archive = job.archive;
        archive.name = job.archive_name.?;
        job.result = toolchain_install.install(io, gpa, .{
            .archive_path = job.archive_path,
            .sig_text = job.sig_text,
            .archive_name = archive.name,
            .expected_size = archive.size,
            .expected_sha256 = archive.sha256,
            .key = job.key,
            .toolchains_dir = job.toolchains.?,
        });
    }
    deleteFile(job.archive_path);
    // After `close` (editor exit) the queue drops the job itself.
    main_queue.push(takeResult, job, dropResult) catch {};
}

/// Main thread (queue drain): keeps the job for the next `tick`, or drops
/// it when its run has ended (`serial` moved on).
/// The toolchain lock, waited for in short steps so editor exit
/// (`quitting`) does not wait for another editor's install.
fn lockToolchains(io: std.Io, lock_path: []const u8) !platform.lock.FileLock {
    const step_ms = 200;
    var waited: u32 = 0;
    while (true) {
        if (platform.lock.FileLock.acquire(io, .fromTrusted(lock_path), .exclusive, step_ms)) |l| return l else |err| switch (err) {
            error.Timeout => {},
            else => return err,
        }
        waited += step_ms;
        if (quitting.load(.acquire)) return error.Canceled;
        if (waited >= lock_timeout_ms) return error.Timeout;
    }
}

fn takeResult(ctx: ?*anyopaque) void {
    const job: *Job = @ptrCast(@alignCast(ctx.?));
    if (job.serial != serial) return freeJob(job);
    if (finished) |old| freeJob(old);
    finished = job;
}

fn dropResult(ctx: ?*anyopaque) void {
    freeJob(@ptrCast(@alignCast(ctx.?)));
}

// ------------------------------------------------------------ test overrides

const TestConfig = struct {
    list_url: []const u8,
    official_base: []const u8,
    key: minisign.PublicKey,
    archive_name: []const u8,
    archive_size: u64,
    archive_sha256: [32]u8,
    plain_http: bool,
    timings: Timings,
    /// The overrides name no key and no archive: the pinned ones apply
    /// (`key` and the `archive_*` fields are unused).
    pinned: bool = false,
    /// The toolchains folder instead of the per-user one (its parent holds
    /// the mirror list cache).
    toolchains_dir: ?[]const u8 = null,
    /// Owns the strings above.
    text: []u8,
};

var test_config: if (host_options.test_probe) ?TestConfig else void = if (host_options.test_probe) null else {};

/// Frees the copied override text and refuses it (`configureForTest`).
fn rejectConfig(own: []u8) bool {
    gpa.free(own);
    return false;
}

/// TEST ONLY (probe builds): takes the overrides from `key=value` lines
/// (`list_url`, `official_base`, `key`, `archive_name`, `archive_size`,
/// `archive_sha256`, `plain_http`; optional `request_timeout_ms`,
/// `stall_ms`, `archive_deadline_ms`, `toolchains_dir`). `key` and the
/// three `archive_*` lines may all be left out together: the pinned key
/// and archive of this platform apply then. False when one is missing or
/// bad.
pub fn configureForTest(text: []const u8) bool {
    comptime std.debug.assert(host_options.test_probe);
    const own = gpa.dupe(u8, text) catch return false;
    var t: TestConfig = .{ .list_url = "", .official_base = "", .key = undefined, .archive_name = "", .archive_size = 0, .archive_sha256 = undefined, .plain_http = false, .timings = default_timings, .text = own };
    var have: u8 = 0;
    var lines = std.mem.tokenizeAny(u8, own, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "list_url")) {
            t.list_url = v;
            have |= 1;
        } else if (std.mem.eql(u8, k, "official_base")) {
            t.official_base = v;
            have |= 2;
        } else if (std.mem.eql(u8, k, "key")) {
            t.key = minisign.PublicKey.parse(v) catch return rejectConfig(own);
            have |= 4;
        } else if (std.mem.eql(u8, k, "archive_name")) {
            t.archive_name = v;
            have |= 8;
        } else if (std.mem.eql(u8, k, "archive_size")) {
            t.archive_size = std.fmt.parseInt(u64, v, 10) catch return rejectConfig(own);
            have |= 16;
        } else if (std.mem.eql(u8, k, "archive_sha256")) {
            if (v.len != 64) return rejectConfig(own);
            _ = std.fmt.hexToBytes(&t.archive_sha256, v) catch return rejectConfig(own);
            have |= 32;
        } else if (std.mem.eql(u8, k, "plain_http")) {
            t.plain_http = std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, k, "request_timeout_ms")) {
            t.timings.request_timeout_ms = std.fmt.parseInt(u32, v, 10) catch return rejectConfig(own);
        } else if (std.mem.eql(u8, k, "stall_ms")) {
            t.timings.stall_ms = std.fmt.parseInt(u32, v, 10) catch return rejectConfig(own);
        } else if (std.mem.eql(u8, k, "archive_deadline_ms")) {
            t.timings.archive_deadline_ms = std.fmt.parseInt(u64, v, 10) catch return rejectConfig(own);
        } else if (std.mem.eql(u8, k, "toolchains_dir")) {
            if (v.len == 0) return rejectConfig(own);
            t.toolchains_dir = v;
        }
    }
    // The mirror list and the ziglang.org stand-in, with the key and the
    // archive or without both.
    if (have == 3) t.pinned = true else if (have != 63) return rejectConfig(own);
    if (test_config) |old| gpa.free(old.text);
    test_config = t;
    return true;
}

// ------------------------------------------------------------ helpers

fn nowMs() i64 {
    return std.Io.Clock.awake.now(host_io.get()).toMilliseconds();
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s = props.gstring(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printError(msg.ptr, "Zig download", "src/host/zig_download.zig", @src().line, 1);
}

test "state text" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Checking and unpacking Zig (needs about 800 MB of memory)", stateText(&buf, .checking));
    try std.testing.expectEqualStrings("Zig 0.17.0 installed", stateText(&buf, .done));
    try std.testing.expectEqualStrings(
        "Downloading Zig 0.17.0 from https://m.example/zig: 12.3 of 57.3 MB",
        stateText(&buf, .{ .downloading = .{ .mirror = "https://m.example/zig", .bytes = 12_345_678, .total = 57_332_648 } }),
    );
    try std.testing.expectEqualStrings("Zig download failed: HTTP status 404", stateText(&buf, .{ .failed = .{ .reason = "HTTP status 404" } }));
}

test "http reasons" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("HTTP status 404", httpReason(&buf, 0, 404));
    try std.testing.expectEqualStrings("could not connect", httpReason(&buf, 2, 0));
    try std.testing.expectEqualStrings("the request timed out", httpReason(&buf, 13, 0));
    try std.testing.expectEqualStrings("HTTPRequest result 99", httpReason(&buf, 99, 0));
}

test "toolchain lock wait stops at editor exit" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const p = try std.fs.path.join(std.testing.allocator, &.{ dir, lock_name });
    defer std.testing.allocator.free(p);
    var other = try platform.lock.FileLock.acquire(io, .fromTrusted(p), .exclusive, 0);
    quitting.store(true, .release);
    try std.testing.expectError(error.Canceled, lockToolchains(io, p));
    quitting.store(false, .release);
    other.release();
    var mine = try lockToolchains(io, p);
    mine.release();
}

test "reasons are cut on a character boundary" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abc", fitUtf8(&buf, "abc", false));
    // "aé" + "€€": the cut falls inside the first euro sign.
    try std.testing.expectEqualStrings("a\u{e9}\u{2026}", fitUtf8(&buf, "a\u{e9}\u{20ac}\u{20ac}", false));
    // Already cut by the formatter: the ellipsis is added.
    try std.testing.expectEqualStrings("ab\u{2026}", fitUtf8(&buf, "ab", true));
    try std.testing.expect(std.unicode.utf8ValidateSlice(fitUtf8(&buf, "\u{20ac}\u{20ac}\u{20ac}\u{20ac}", false)));
}

test "archive deadline" {
    const t: Timings = .{};
    // The pinned x86_64-linux size at 32 KiB/s: about 29 minutes.
    try std.testing.expectEqual(@as(u64, 1749_000), archiveDeadlineMs(t, 57_332_648));
    // Small archives get the minimum.
    try std.testing.expectEqual(@as(u64, 300_000), archiveDeadlineMs(t, 1000));
    try std.testing.expectEqual(@as(u64, 1234), archiveDeadlineMs(.{ .archive_deadline_ms = 1234 }, 57_332_648));
}
