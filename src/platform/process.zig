//! Child processes (L1): run to completion with a timeout, or keep one open
//! with pipes.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const win32 = @import("win32.zig");

pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

const is_posix = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

const is_windows = builtin.os.tag == .windows;

/// The process tree of one child. On POSIX that is the child's process
/// group (its pid); on Windows a Job Object with
/// `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so the child and every process it
/// starts die together when the job is terminated or its handle is closed.
const Tree = if (is_windows) ?win32.HANDLE else void;

/// A Job Object that kills its processes when its last handle closes.
fn createJob() !win32.HANDLE {
    const job = win32.CreateJobObjectW(null, null) orelse return error.JobObjectFailed;
    errdefer _ = win32.CloseHandle(job);
    var info: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    info.basic.limit_flags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (win32.SetInformationJobObject(job, win32.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info))) == 0)
        return error.JobObjectFailed;
    return job;
}

/// Spawns `opts` as a new process tree. On Windows the child is created
/// suspended (std's `start_suspended`), assigned to a new job, and only then
/// resumed, so no process it starts can escape the job.
fn spawnTree(io: std.Io, opts: std.process.SpawnOptions) !struct { std.process.Child, Tree } {
    if (comptime !is_windows) {
        var o = opts;
        o.pgid = if (is_posix) 0 else null;
        return .{ try std.process.spawn(io, o), {} };
    }
    const job = try createJob();
    errdefer _ = win32.CloseHandle(job);
    var o = opts;
    o.start_suspended = true;
    var child = try std.process.spawn(io, o);
    errdefer {
        _ = win32.TerminateProcess(child.id.?, 1);
        reapWindows(io, &child);
    }
    if (win32.AssignProcessToJobObject(job, child.id.?) == 0) return error.JobObjectFailed;
    if (win32.ResumeThread(child.thread_handle) == std.math.maxInt(u32)) return error.JobObjectFailed;
    return .{ child, job };
}

/// Kills the child's whole tree (POSIX: its process group; Windows: its
/// job), so grandchildren that hold the pipes cannot keep a read open. Does
/// not reap the child.
fn killTree(child: *const std.process.Child, tree: Tree) void {
    if (comptime is_windows) {
        if (tree) |job| _ = win32.TerminateJobObject(job, 1);
        return;
    }
    if (comptime !is_posix) return;
    if (child.id) |pid| std.posix.kill(-pid, .KILL) catch {};
}

/// Kills the child's tree, reaps the child and closes its pipes (and on
/// Windows the job). Safe after `wait`.
///
/// On Windows std's `Child.kill` is not used: it calls
/// `RtlReportSilentProcessExit`, which Wine does not implement (the process
/// aborts). The job is terminated instead and the child reaped with `wait`.
fn killReap(io: std.Io, child: *std.process.Child, tree: *Tree) void {
    if (comptime is_windows) {
        if (child.id) |h| {
            if (tree.*) |job| {
                _ = win32.TerminateJobObject(job, 1);
            } else {
                _ = win32.TerminateProcess(h, 1);
            }
            _ = waitHandle(h, win32.INFINITE);
            reapWindows(io, child);
        }
        closeTree(tree);
        return;
    }
    killTree(child, tree.*);
    child.kill(io);
}

/// Windows: reaps an ended `child` with `wait`, which closes its process,
/// thread and pipe handles. If `wait` fails (for example when cancelled),
/// the handles are closed here instead, so none leaks.
fn reapWindows(io: std.Io, child: *std.process.Child) void {
    if (child.id == null) return;
    _ = child.wait(io) catch {
        if (child.id) |h| _ = win32.CloseHandle(h);
        child.id = null;
        _ = win32.CloseHandle(child.thread_handle);
        child.thread_handle = undefined;
        inline for (.{ "stdin", "stdout", "stderr" }) |name| {
            if (@field(child, name)) |f| _ = win32.CloseHandle(f.handle);
            @field(child, name) = null;
        }
    };
}

/// Closes the job handle (Windows), which also kills what is left of the
/// tree. Idempotent.
fn closeTree(tree: *Tree) void {
    if (comptime !is_windows) return;
    if (tree.*) |job| _ = win32.CloseHandle(job);
    tree.* = null;
}

/// Windows: waits up to `ms` for `handle` to be signalled. True when it was.
fn waitHandle(handle: win32.HANDLE, ms: u32) bool {
    return win32.WaitForSingleObject(handle, ms) == win32.WAIT_OBJECT_0;
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
/// The child gets no stdin and runs in its own process tree: a process group
/// on POSIX, a Job Object on Windows (`spawnTree`).
/// If it does not finish within `timeout_ms` (reads and exit together), it is
/// killed with its tree and the result is `error.Timeout`. If stdout or
/// stderr passes `max_output` bytes, the child is always killed with its
/// tree and each stream is cut to its first `max_output` bytes; `term` then
/// shows the kill. On Windows the job is closed on return, so processes the
/// child left running end with it. The caller frees `stdout` and `stderr`.
pub fn runCapture(
    a: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: ?path.OsPath,
    timeout_ms: u32,
    max_output: usize,
) !RunResult {
    const t0 = std.Io.Clock.awake.now(io);
    var child, var tree = try spawnTree(io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c.bytes } else .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer closeTree(&tree);
    errdefer killReap(io, &child, &tree);

    var buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    // On an error the tree dies before `mr.deinit`, which may wait for its
    // reads to end: a grandchild holding the pipes must not keep it waiting.
    errdefer killTree(&child, tree);

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
    if (over_cap) killTree(&child, tree) else try mr.checkAnyError();

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
    } else if (comptime is_windows) {
        if (!over_cap) {
            // A Windows process handle stays valid until it is closed, so
            // the tree can be killed at the deadline without a race.
            const spent = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
            const left: u32 = @intCast(std.math.clamp(@as(i64, timeout_ms) - spent, 0, timeout_ms));
            if (!waitHandle(child.id.?, left)) {
                timed_out.store(true, .release);
                killTree(&child, tree);
            }
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
/// tree: a process group on POSIX, a Job Object on Windows. Task 7 reads and
/// writes the pipes through `inner`.
pub const Child = struct {
    inner: std.process.Child,
    tree: Tree,

    pub fn spawn(io: std.Io, argv: []const []const u8, cwd: ?path.OsPath) !Child {
        const inner, const tree = try spawnTree(io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c.bytes } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        return .{ .inner = inner, .tree = tree };
    }

    /// Same as `kill`; call it (for example with `defer`) so the pipes and the
    /// process are always released.
    pub fn deinit(self: *Child, io: std.Io) void {
        self.kill(io);
    }

    /// Kills the child and its tree, then reaps it. Safe after `wait`.
    pub fn kill(self: *Child, io: std.Io) void {
        killReap(io, &self.inner, &self.tree);
    }

    /// Waits for the child to exit and closes its pipes. On Windows the job
    /// is closed too, so processes the child left running end with it.
    pub fn wait(self: *Child, io: std.Io) !std.process.Child.Term {
        defer closeTree(&self.tree);
        return self.inner.wait(io);
    }

    /// Kills the child's tree (POSIX: SIGKILL to its process group; Windows:
    /// `TerminateJobObject`) without reaping it, so its pipes stay open
    /// until readers are done; `kill` or `wait` must follow.
    pub fn signalKill(self: *Child) void {
        killTree(&self.inner, self.tree);
    }

    /// Waits up to `timeout_ms` for the child to exit, without reaping it, so
    /// `kill` or `wait` must follow. Returns true when the child exited by
    /// itself. On timeout its tree is killed and the wait goes on until the
    /// child is gone, and the result is false.
    pub fn waitExit(self: *Child, io: std.Io, timeout_ms: u32) bool {
        if (comptime is_windows) {
            const handle = self.inner.id orelse return true;
            if (waitHandle(handle, timeout_ms)) return true;
            killTree(&self.inner, self.tree);
            _ = waitHandle(handle, win32.INFINITE);
            return false;
        }
        if (comptime !is_posix) return false;
        const pid = self.inner.id orelse return true;
        const deadline = (std.Io.Timeout{ .duration = .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        } }).toDeadline(io);
        var timed_out = std.atomic.Value(bool).init(false);
        // Same order as in `runCapture`: the watchdog may only kill while the
        // child is unreaped, so it is joined before anyone reaps.
        var dog = io.concurrent(watchdog, .{ io, deadline, pid, &timed_out }) catch {
            killTree(&self.inner, self.tree);
            waitExitNoReap(pid);
            return false;
        };
        waitExitNoReap(pid);
        dog.cancel(io) catch {};
        return !timed_out.load(.acquire);
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

test "Child.waitExit: a child that exits returns true" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var c = try Child.spawn(io, &.{ "/bin/sh", "-c", "exit 0" }, null);
    defer c.deinit(io);
    try std.testing.expect(c.waitExit(io, 5000));
    const term = try c.wait(io);
    try std.testing.expect(term.success());
}

test "Child.waitExit: a child that hangs is killed after the timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const start = std.Io.Clock.awake.now(io);
    var c = try Child.spawn(io, &.{ "/bin/sh", "-c", "sleep 30" }, null);
    defer c.deinit(io);
    try std.testing.expect(!c.waitExit(io, 200));
    const term = try c.wait(io);
    try std.testing.expect(!term.success());
    try std.testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 5000);
}

/// True when process `pid` has ended within `ms` (or no longer exists).
fn processGone(pid: u32, ms: u32) bool {
    const h = win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return true;
    defer _ = win32.CloseHandle(h);
    return win32.WaitForSingleObject(h, ms) == win32.WAIT_OBJECT_0;
}

test "process: timeout kills the job tree" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const pid_file = try std.fs.path.join(a, &.{ base, "pids" });
    defer a.free(pid_file);
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, @import("build_options").fake_compiler_exe, a);
    defer a.free(exe);

    // The fake compiler starts a sleeping child, which holds the output
    // pipes too, and sleeps itself (60 s each).
    const t0 = std.Io.Clock.awake.now(io);
    try std.testing.expectError(error.Timeout, runCapture(a, io, &.{ exe, "tree", pid_file }, null, 3000, 1024));
    // The deadline ended it, not the end of the sleeps.
    try std.testing.expect(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 20_000);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, pid_file, a, .limited(64));
    defer a.free(text);
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    const parent = try std.fmt.parseInt(u32, it.next() orelse return error.NoPid, 10);
    const child = try std.fmt.parseInt(u32, it.next() orelse return error.NoPid, 10);
    try std.testing.expect(processGone(parent, 5000));
    try std.testing.expect(processGone(child, 5000));
}
