//! Runs a Windows program under Wine for `zig build test-windows`.
//!
//!     wine_run <state dir> <program.exe> [args...]
//!
//! It finds `wine` on PATH and fails with a clear message when there is none.
//! It sets `WINEPREFIX=<state dir>/prefix` (never `~/.wine`),
//! `WINEDEBUG=-all` and `WINEDLLOVERRIDES=mscoree,mshtml=` (so a new prefix
//! never offers to download Mono or Gecko: the tests stay offline), and
//! creates the prefix once with `wineboot --init` under a lock, so parallel
//! test runs never boot one prefix twice. A boot that takes longer than
//! `boot_timeout_s` is killed and the run fails with a message. Then it
//! replaces itself with `wine <program.exe> [args...]`, so the test runner's
//! standard input and output stay the build runner's pipes.
//!
//! Zig 0.17 runs Windows programs with `wine` itself (not `wine64`), and
//! this runner calls `wine` directly, so no `wine64` shim is needed.

const std = @import("std");
const builtin = @import("builtin");

/// The longest the one-time `wineboot --init` may take.
const boot_timeout_s = 300;

const missing_wine =
    \\test-windows needs Wine: there is no `wine` on PATH.
    \\Install Wine (on NixOS: wineWow64Packages.stable), or leave out test-windows
    \\and the -Dwindows-* options.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: wine_run <state dir> <program.exe> [args...]\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();

    const wine = findWine(arena, io, init.environ_map) orelse {
        std.debug.print("{s}", .{missing_wine});
        std.process.exit(1);
    };

    try cwd.createDirPath(io, args[1]);
    const state = try cwd.realPathFileAlloc(io, args[1], arena);
    const prefix = try std.fs.path.join(arena, &.{ state, "prefix" });

    const env = init.environ_map;
    try env.put("WINEPREFIX", prefix);
    try env.put("WINEDEBUG", "-all");
    // Disabled, not "builtin": with mscoree and mshtml off, wineboot never
    // offers to install Wine Mono or Wine Gecko, which would need a download.
    try env.put("WINEDLLOVERRIDES", "mscoree,mshtml=");
    // Wine's first process probes the GPU through EGL, and Mesa's warnings
    // about it would make a passing run look failed. The tests draw
    // nothing, so libglvnd is given no EGL vendor to load.
    try env.put("__EGL_VENDOR_LIBRARY_FILENAMES", "/nonexistent");

    try bootPrefix(arena, io, cwd, state, wine, env);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, wine);
    try argv.appendSlice(arena, args[2..]);
    const err = std.process.replace(io, .{ .argv = argv.items, .environ_map = env });
    std.debug.print("wine_run: cannot run {s}: {t}\n", .{ wine, err });
    std.process.exit(1);
}

/// The absolute path of `wine` on PATH, or null.
fn findWine(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    const path = env.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (!std.fs.path.isAbsolute(dir)) continue;
        const full = std.fs.path.join(arena, &.{ dir, "wine" }) catch return null;
        std.Io.Dir.cwd().access(io, full, .{ .execute = true }) catch continue;
        return full;
    }
    return null;
}

/// Creates the Wine prefix once. The marker file is written only after
/// `wineboot --init` succeeds, so an interrupted boot is redone.
fn bootPrefix(
    arena: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    state: []const u8,
    wine: []const u8,
    env: *const std.process.Environ.Map,
) !void {
    const marker = try std.fs.path.join(arena, &.{ state, "prefix-ready" });
    if (cwd.access(io, marker, .{})) |_| return else |_| {}

    const lock_path = try std.fs.path.join(arena, &.{ state, "prefix.lock" });
    const lock = try cwd.createFile(io, lock_path, .{ .truncate = false });
    defer lock.close(io);
    try lock.lock(io, .exclusive);
    defer lock.unlock(io);

    if (cwd.access(io, marker, .{})) |_| return else |_| {}
    // Wine's background processes may keep inherited pipes open, so the
    // boot gets no pipes of ours.
    var child = try std.process.spawn(io, .{
        .argv = &.{ wine, "wineboot", "--init" },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var timed_out = std.atomic.Value(bool).init(false);
    if (comptime builtin.os.tag == .linux) {
        // The watchdog may only kill while the child is unreaped (its pid
        // stays reserved), so wait for the exit without reaping, stop the
        // watchdog, and only then reap with `child.wait`.
        var dog = try io.concurrent(watchdog, .{ io, child.id.?, &timed_out });
        waitExitNoReap(child.id.?);
        dog.cancel(io) catch {};
    }
    const term = try child.wait(io);
    if (timed_out.load(.acquire)) {
        stopWineserver(io, wine, env);
        std.debug.print(
            "wine_run: `wine wineboot --init` did not finish within {d} s, so it was stopped.\n" ++
                "The Wine prefix {s} is not ready; run test-windows again, or move that folder aside if it keeps failing.\n",
            .{ boot_timeout_s, state },
        );
        std.process.exit(1);
    }
    if (!term.success()) {
        std.debug.print("wine_run: `wine wineboot --init` in {s} {f}\n", .{ state, term });
        std.process.exit(1);
    }
    try cwd.writeFile(io, .{ .sub_path = marker, .data = "" });
}

fn watchdog(io: std.Io, pid: std.posix.pid_t, timed_out: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(boot_timeout_s), .awake);
    timed_out.store(true, .release);
    std.posix.kill(pid, .KILL) catch {};
}

/// Blocks until process `pid` has exited, without reaping it. Errors are
/// ignored: `child.wait` follows and reports the real status.
fn waitExitNoReap(pid: std.posix.pid_t) void {
    const linux = std.os.linux;
    var info: linux.siginfo_t = undefined;
    while (true) {
        const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOWAIT, null);
        if (linux.errno(rc) != .INTR) return;
    }
}

/// Stops the wineserver of this run's prefix (`env` holds its WINEPREFIX),
/// with the processes a killed boot left behind. Other prefixes' servers
/// are not touched.
fn stopWineserver(io: std.Io, wine: []const u8, env: *const std.process.Environ.Map) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.path.dirname(wine) orelse return;
    const server = std.fmt.bufPrint(&buf, "{s}/wineserver", .{dir}) catch return;
    var child = std.process.spawn(io, .{
        .argv = &.{ server, "-k" },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}
