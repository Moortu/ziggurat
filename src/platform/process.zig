//! Child processes (L1): run to completion with a timeout, or keep one open
//! with pipes.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");

pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

const is_posix = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

/// Kills the child's whole process group, so grandchildren that hold the
/// pipes cannot keep a read open. POSIX only; elsewhere it does nothing.
fn killGroup(child: *const std.process.Child) void {
    if (comptime !is_posix) return;
    if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
}

fn watchdog(io: std.Io, deadline: std.Io.Timeout, pid: std.posix.pid_t, timed_out: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    try deadline.sleep(io);
    timed_out.store(true, .release);
    std.posix.kill(-pid, .KILL) catch {};
}

extern "c" fn waitid(idtype: c_uint, id: c_uint, infop: *anyopaque, options: c_int) c_int;

/// Blocks until process `pid` has exited, without reaping it. Errors are
/// ignored: `child.wait` follows and reports the real status.
fn waitExitNoReap(pid: std.posix.pid_t) void {
    const wexited = 4;
    const wnowait: c_int = if (builtin.os.tag == .linux) 0x01000000 else 0x20;
    var info: [128]u8 align(16) = undefined;
    while (true) {
        const rc = waitid(1, @intCast(pid), &info, wexited | wnowait);
        if (rc == 0) return;
        if (std.posix.errno(@as(isize, rc)) != .INTR) return;
    }
}

/// Runs `argv` to completion and returns its exit status and output.
/// The child gets no stdin and runs in its own process group (POSIX).
/// If it does not finish within `timeout_ms` (reads and exit together), it is
/// killed with its group and the result is `error.Timeout`. If stdout or
/// stderr passes `max_output` bytes, the child is always killed (POSIX) and
/// each stream is cut to its first `max_output` bytes; `term` then shows the
/// kill. On Windows the exit wait has no deadline and an over-cap child is
/// not killed. The caller frees `stdout` and `stderr`.
pub fn runCapture(
    a: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?path.OsPath,
    timeout_ms: u32,
    max_output: usize,
) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c.bytes } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (is_posix) 0 else null,
    });
    errdefer {
        killGroup(&child);
        child.kill(io);
    }

    var buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();

    const deadline = (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(timeout_ms),
        .clock = .awake,
    } }).toDeadline(io);

    var over_cap = false;
    while (true) {
        mr.fill(4096, deadline) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (mr.reader(0).buffered().len > max_output or mr.reader(1).buffered().len > max_output) {
            over_cap = true;
            break;
        }
    }
    if (mr.reader(0).buffered().len > max_output or mr.reader(1).buffered().len > max_output)
        over_cap = true;
    if (over_cap) killGroup(&child) else try mr.checkAnyError();

    // The pipes are closed or full, but the child may still run. Bound the
    // wait with the same deadline: a watchdog kills the group when it expires.
    var timed_out = std.atomic.Value(bool).init(false);
    if (comptime is_posix) {
        if (!over_cap) {
            // The watchdog may only kill while the child is unreaped. A zombie
            // keeps its pid and group id reserved, so no other process can
            // own them yet and a kill in this window is harmless. So: wait
            // for exit without reaping (WNOWAIT), stop and join the
            // watchdog, and only then reap with `child.wait`.
            var dog = try io.concurrent(watchdog, .{ io, deadline, child.id.?, &timed_out });
            waitExitNoReap(child.id.?);
            dog.cancel(io) catch {};
        }
    }
    const term = try child.wait(io);
    if (timed_out.load(.acquire)) return error.Timeout;

    const out = try mr.toOwnedSlice(0);
    errdefer a.free(out);
    const err_out = try mr.toOwnedSlice(1);
    errdefer a.free(err_out);
    return .{
        .term = term,
        .stdout = if (out.len > max_output) try a.realloc(out, max_output) else out,
        .stderr = if (err_out.len > max_output) try a.realloc(err_out, max_output) else err_out,
    };
}

/// A running child with piped stdin, stdout and stderr, in its own process
/// group on POSIX. Task 7 reads and writes the pipes through `inner`.
pub const Child = struct {
    inner: std.process.Child,

    pub fn spawn(io: std.Io, argv: []const []const u8, cwd: ?path.OsPath) !Child {
        return .{ .inner = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c.bytes } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (is_posix) 0 else null,
        }) };
    }

    /// Same as `kill`; call it (for example with `defer`) so the pipes and the
    /// process are always released.
    pub fn deinit(self: *Child, io: std.Io) void {
        self.kill(io);
    }

    /// Kills the child and its group, then reaps it. Safe after `wait`.
    pub fn kill(self: *Child, io: std.Io) void {
        killGroup(&self.inner);
        self.inner.kill(io);
    }

    /// Waits for the child to exit and closes its pipes.
    pub fn wait(self: *Child, io: std.Io) !std.process.Child.Term {
        return self.inner.wait(io);
    }
};

test "runCapture: captures output and exit code" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const r = try runCapture(a, std.testing.io, &.{ "/bin/sh", "-c", "echo out; echo err >&2; exit 2" }, null, 5000, 1024);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqualStrings("out\n", r.stdout);
    try std.testing.expectEqualStrings("err\n", r.stderr);
    try std.testing.expectEqual(@as(u8, 2), r.term.exited);
}

test "runCapture: timeout kills the whole group" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    try std.testing.expectError(error.Timeout, runCapture(a, std.testing.io, &.{ "/bin/sh", "-c", "sleep 30; echo x" }, null, 300, 1024));
}

test "runCapture: output over the cap is cut" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const r = try runCapture(a, std.testing.io, &.{ "/bin/sh", "-c", "head -c 300 /dev/zero | tr '\\0' x" }, null, 5000, 100);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqual(@as(usize, 100), r.stdout.len);
}

test "runCapture: cwd is honoured" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(abs);
    const r = try runCapture(a, io, &.{ "/bin/sh", "-c", "pwd" }, path.OsPath.fromTrusted(abs), 5000, 1024);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqualStrings(abs, std.mem.trimEnd(u8, r.stdout, "\n"));
}

test "runCapture: timeout covers a child that closed its pipes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Timeout, runCapture(a, io, &.{ "/bin/sh", "-c", "exec >&- 2>&-; sleep 30" }, null, 500, 1024));
    const ms = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(ms < 2000);
}

test "runCapture: 64 KiB+ on stderr while stdout is read does not deadlock" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const r = try runCapture(a, std.testing.io, &.{ "/bin/sh", "-c", "echo hi; head -c 300000 /dev/zero >&2" }, null, 5000, 1 << 20);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqualStrings("hi\n", r.stdout);
    try std.testing.expectEqual(@as(usize, 300000), r.stderr.len);
}

test "Child: cat echoes a line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var c = try Child.spawn(io, &.{ "/bin/sh", "-c", "cat" }, null);
    defer c.deinit(io);
    try c.inner.stdin.?.writeStreamingAll(io, "hello\n");
    var buf: [16]u8 = undefined;
    var bufs = [_][]u8{&buf};
    const n = try c.inner.stdout.?.readStreaming(io, &bufs);
    try std.testing.expectEqualStrings("hello\n", buf[0..n]);
    c.inner.stdin.?.close(io);
    c.inner.stdin = null;
    const term = try c.wait(io);
    try std.testing.expect(term.success());
}

test "runCapture: 300 bytes then exit 0 over cap 256 is cut and killed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const r = try runCapture(a, std.testing.io, &.{ "/bin/sh", "-c", "head -c 300 /dev/zero | tr '\\0' x" }, null, 5000, 256);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqual(@as(usize, 256), r.stdout.len);
}
