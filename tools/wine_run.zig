//! Runs a Windows program under Wine for `zig build test-windows`.
//!
//!     wine_run <state dir> <program.exe> [args...]
//!
//! It finds `wine` on PATH and fails with a clear message when there is none.
//! It sets `WINEPREFIX=<state dir>/prefix` (never `~/.wine`) and
//! `WINEDEBUG=-all`, and creates the prefix once with `wineboot --init`
//! under a lock, so parallel test runs never boot one prefix twice. Then it
//! replaces itself with `wine <program.exe> [args...]`, so the test runner's
//! standard input and output stay the build runner's pipes.
//!
//! Zig 0.17 runs Windows programs with `wine` itself (not `wine64`), and
//! this runner calls `wine` directly, so no `wine64` shim is needed.

const std = @import("std");

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
    const term = try child.wait(io);
    if (!term.success()) {
        std.debug.print("wine_run: `wine wineboot --init` in {s} {f}\n", .{ state, term });
        std.process.exit(1);
    }
    try cwd.writeFile(io, .{ .sub_path = marker, .data = "" });
}
