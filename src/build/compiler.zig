//! Compiler session (L2): drives `zig build-lib ... --listen=-` as a
//! long-lived server for incremental rebuilds.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const workspace = @import("workspace.zig");
const diagnostics = @import("diagnostics.zig");
const scan_mod = @import("scan.zig");
const OsPath = platform.path.OsPath;
const ErrorBundle = std.zig.ErrorBundle;

pub const UpdateResult = struct {
    /// Owned; checked with `diagnostics.validate`, so the `std.zig.ErrorBundle`
    /// accessors are safe on it.
    bundle: ErrorBundle,
    /// `<cache-dir>/o/<emit_digest hex>/<lib file name>` from the
    /// `emit_digest` of this update, or null when there are errors or this
    /// update sent no digest. In incremental mode the compiler rewrites the
    /// same file on the next update, so copy it out before updating again. Owned.
    output: ?OsPath,
    /// Wall time of the update round trip.
    ms: u64,

    pub fn deinit(self: *UpdateResult, a: std.mem.Allocator) void {
        self.bundle.deinit(a);
        if (self.output) |o| a.free(o.bytes);
        self.* = undefined;
    }
};

/// Any error from `update` leaves the session dead: the server is killed and
/// reaped, and later calls give `error.CompilerDied`.
pub const UpdateError = error{
    /// The update did not end in time. The server was killed (its state is
    /// unknown) and the session is dead.
    Timeout,
    /// The server exited, closed its output, refused input or broke the
    /// protocol. See `Session.stderrTail`.
    CompilerDied,
    OutOfMemory,
};

/// Bytes of the server's stderr kept for `stderrTail`.
pub const stderr_tail_len = 4096;
/// How long `exit` waits for the server to stop before it kills it.
pub const exit_grace_ms = 2000;
/// How long releasing a session waits for the stderr reader to reach end of
/// file before it cancels the reader.
pub const drain_grace_ms = 2000;
/// Largest server message accepted; a bigger one is a protocol violation.
const max_message_bytes: u32 = 256 * 1024 * 1024;

const ServerTag = std.zig.Server.Message.Tag;
const ClientTag = std.zig.Client.Message.Tag;
const digest_len = std.Build.Cache.bin_digest_len;

/// Heap-allocated so the stderr reader and the multi-reader can keep pointers
/// into it while `Session` values are copied around.
const State = struct {
    a: std.mem.Allocator,
    io: std.Io,
    child: platform.process.Child,
    mr_buf: std.Io.File.MultiReader.Buffer(1),
    mr: std.Io.File.MultiReader,
    drain: std.Io.Future(void),
    mutex: std.Io.Mutex = .init,
    ring: [stderr_tail_len]u8 = undefined,
    /// Bytes ever written into `ring`.
    ring_total: u64 = 0,
    tail: [stderr_tail_len]u8 = undefined,
    cache_dir: []const u8,
    lib_file: []const u8,
    /// From the `emit_digest` of the current update; cleared when an update starts.
    out_path: ?[]const u8 = null,
    /// Set by the stderr reader when it stops.
    drain_done: std.atomic.Value(bool) = .init(false),
    dead: bool = false,
    /// The process is reaped and the pipes are closed.
    released: bool = false,

    fn send(st: *State, tag: ClientTag) error{CompilerDied}!void {
        const stdin = st.child.inner.stdin orelse return error.CompilerDied;
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @backingInt(tag), .little);
        std.mem.writeInt(u32, buf[4..8], 0, .little);
        stdin.writeStreamingAll(st.io, &buf) catch return error.CompilerDied;
    }

    const Header = struct { tag: u32, len: u32 };

    /// Reads one message header and makes sure its whole body is buffered.
    fn receive(st: *State, deadline: std.Io.Timeout) error{ Timeout, CompilerDied }!Header {
        const r = st.mr.reader(0);
        while (r.bufferedLen() < 8) try st.fill(64, deadline);
        const tag = r.takeInt(u32, .little) catch unreachable;
        const len = r.takeInt(u32, .little) catch unreachable;
        if (len > max_message_bytes) return error.CompilerDied;
        while (r.bufferedLen() < len) try st.fill(len - r.bufferedLen(), deadline);
        return .{ .tag = tag, .len = len };
    }

    fn fill(st: *State, n: usize, deadline: std.Io.Timeout) error{ Timeout, CompilerDied }!void {
        st.mr.fill(n, deadline) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return error.CompilerDied,
        };
        // A read error is kept in the stream and ends it; treat it like EOF.
        st.mr.checkAnyError() catch return error.CompilerDied;
    }

    fn setOutput(st: *State, digest: *const [digest_len]u8) error{OutOfMemory}!void {
        const hex = std.fmt.bytesToHex(digest.*, .lower);
        // `start` checked that `lib_file` has no separator, so every part is valid.
        const p = platform.path.join(st.a, .fromTrusted(st.cache_dir), &.{ "o", &hex, st.lib_file }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPathPart => unreachable,
        };
        st.clearOutput();
        st.out_path = p.bytes;
    }

    fn clearOutput(st: *State) void {
        if (st.out_path) |old| st.a.free(old);
        st.out_path = null;
    }

    fn waitDrain(st: *State, timeout_ms: u32) void {
        const t0 = std.Io.Clock.awake.now(st.io);
        while (!st.drain_done.load(.acquire)) {
            if (t0.durationTo(std.Io.Clock.awake.now(st.io)).toMilliseconds() >= timeout_ms) return;
            st.io.sleep(.fromMilliseconds(5), .awake) catch return;
        }
    }

    fn pushTail(st: *State, bytes: []const u8) void {
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        const keep = bytes[bytes.len -| stderr_tail_len..];
        for (keep) |c| {
            st.ring[@intCast(st.ring_total % stderr_tail_len)] = c;
            st.ring_total += 1;
        }
    }

    /// Kills the server if it still runs, stops both readers, reaps the
    /// process and closes the pipes. Idempotent.
    fn release(st: *State) void {
        st.dead = true;
        {
            // Under the mutex, so `interrupt` never signals a reaped pid.
            st.mutex.lockUncancelable(st.io);
            defer st.mutex.unlock(st.io);
            if (st.released) return;
            st.released = true;
        }
        // Kill first, without reaping: the pid stays reserved, so the kill
        // cannot hit another process, and the pipes stay open while the
        // readers finish.
        st.child.signalKill();
        st.mr.deinit();
        // The whole tree is dead (process group or Job Object), so stderr
        // normally reaches end of file and the reader stops by itself after
        // keeping the last bytes. A process outside the tree could still
        // hold the pipe open, so the wait is bounded and the reader is
        // cancelled after it.
        st.waitDrain(drain_grace_ms);
        st.drain.cancel(st.io);
        st.child.kill(st.io);
    }
};

/// Reads the server's stderr until it closes, keeping the last
/// `stderr_tail_len` bytes. Running all the time, it stops a chatty compiler
/// from blocking on a full pipe.
fn drainStderr(st: *State) void {
    defer st.drain_done.store(true, .release);
    const file = st.child.inner.stderr.?;
    var buf: [1024]u8 = undefined;
    while (true) {
        var bufs = [_][]u8{&buf};
        const n = file.readStreaming(st.io, &bufs) catch return;
        st.pushTail(buf[0..n]);
    }
}

fn argAfter(argv: []const []const u8, flag: []const u8) ?[]const u8 {
    if (argv.len < 2) return null;
    for (argv[0 .. argv.len - 1], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, flag)) return argv[i];
    }
    return null;
}

/// The OS the library is built for: the first `-target` in `argv` (an
/// export build cross-compiles, for example a Windows DLL from a Linux
/// editor), else this host's. A `-target` that does not parse counts as
/// this host's; the compiler then refuses it itself.
fn outputOs(argv: []const []const u8) std.Target.Os.Tag {
    const triple = argAfter(argv, "-target") orelse return builtin.os.tag;
    const q = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch return builtin.os.tag;
    return q.os_tag orelse builtin.os.tag;
}

/// File name of the dynamic library `zig build-lib -dynamic --name <name>` writes.
fn libFileName(a: std.mem.Allocator, os: std.Target.Os.Tag, name: []const u8) ![]const u8 {
    return switch (os) {
        .windows => std.fmt.allocPrint(a, "{s}.dll", .{name}),
        .macos, .ios, .tvos, .watchos, .visionos => std.fmt.allocPrint(a, "lib{s}.dylib", .{name}),
        else => std.fmt.allocPrint(a, "lib{s}.so", .{name}),
    };
}

/// A running `zig build-lib ... --listen=-` server.
pub const Session = struct {
    st: *State,

    /// Starts the server with `argv` (from `Workspace.argv`) in `cwd`. The
    /// output folder comes from the `--cache-dir` value, which must be an
    /// absolute path, and the library name from `--name`; otherwise
    /// `error.InvalidArgv`. Call `deinit` when done.
    pub fn start(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: OsPath) !Session {
        const cache_dir = argAfter(argv, "--cache-dir") orelse return error.InvalidArgv;
        const name = argAfter(argv, "--name") orelse return error.InvalidArgv;
        if (name.len == 0 or !std.fs.path.isAbsolute(cache_dir)) return error.InvalidArgv;
        for (name) |c| if (c == '/' or c == '\\') return error.InvalidArgv;

        const st = try a.create(State);
        errdefer a.destroy(st);
        const cache_copy = try a.dupe(u8, cache_dir);
        errdefer a.free(cache_copy);
        const lib_file = try libFileName(a, outputOs(argv), name);
        errdefer a.free(lib_file);

        st.* = .{
            .a = a,
            .io = io,
            .child = try platform.process.Child.spawn(io, argv, cwd),
            .mr_buf = undefined,
            .mr = undefined,
            .drain = undefined,
            .cache_dir = cache_copy,
            .lib_file = lib_file,
        };
        errdefer st.child.kill(io);
        st.mr.init(a, io, st.mr_buf.toStreams(), &.{st.child.inner.stdout.?});
        errdefer st.mr.deinit();
        st.drain = try io.concurrent(drainStderr, .{st});
        return .{ .st = st };
    }

    /// Sends `update` and waits for the error bundle that ends it.
    pub fn update(self: *Session, timeout_ms: u32) UpdateError!UpdateResult {
        const st = self.st;
        if (st.dead) return error.CompilerDied;
        const t0 = std.Io.Clock.awake.now(st.io);
        const deadline = (std.Io.Timeout{ .duration = .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        } }).toDeadline(st.io);
        errdefer st.release();

        // Only a digest sent during this update names its output.
        st.clearOutput();
        try st.send(.update);
        const bundle: ErrorBundle = while (true) {
            const h = try st.receive(deadline);
            const body = st.mr.reader(0).take(h.len) catch unreachable;
            if (h.tag == @backingInt(ServerTag.error_bundle)) {
                break try parseBundle(st.a, body);
            } else if (h.tag == @backingInt(ServerTag.emit_digest)) {
                if (body.len < @sizeOf(std.zig.Server.Message.EmitDigest) + digest_len) return error.CompilerDied;
                try st.setOutput(body[@sizeOf(std.zig.Server.Message.EmitDigest)..][0..digest_len]);
            }
            // Other messages (zig_version, file_system_inputs, ...) are not needed.
        };
        var result: UpdateResult = .{ .bundle = bundle, .output = null, .ms = 0 };
        errdefer result.bundle.deinit(st.a);
        if (bundle.errorMessageCount() == 0) {
            if (st.out_path) |p| result.output = .{ .bytes = try st.a.dupe(u8, p) };
        }
        const elapsed = t0.durationTo(std.Io.Clock.awake.now(st.io)).toMilliseconds();
        result.ms = @intCast(@max(elapsed, 0));
        return result;
    }

    /// Asks the server to stop, waits up to `exit_grace_ms`, then kills it.
    /// Safe to call twice and after the server died.
    pub fn exit(self: *Session) void {
        const st = self.st;
        if (st.released) return;
        if (!st.dead) {
            st.send(.exit) catch {};
            // End of input also stops a server that ignored `exit`.
            if (st.child.inner.stdin) |f| {
                f.close(st.io);
                st.child.inner.stdin = null;
            }
            _ = st.child.waitExit(st.io, exit_grace_ms);
        }
        st.release();
    }

    /// `exit`, then frees the session.
    pub fn deinit(self: *Session) void {
        self.exit();
        const st = self.st;
        const a = st.a;
        a.free(st.cache_dir);
        a.free(st.lib_file);
        if (st.out_path) |p| a.free(p);
        a.destroy(st);
        self.* = undefined;
    }

    /// Kills the server's process tree (POSIX: its process group; Windows:
    /// its Job Object, which ends the server and every process it started).
    /// Safe from any thread, also while another thread is inside `update`
    /// (that update then ends with `error.CompilerDied`); the session must
    /// not be freed meanwhile. Does nothing once the session is released.
    pub fn interrupt(self: Session) void {
        // Under the mutex, so the tree is never killed after `release`
        // reaped the server and closed the job.
        const st = self.st;
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        if (st.released) return;
        st.child.signalKill();
    }

    /// False once the server died, timed out or was told to exit.
    pub fn alive(self: Session) bool {
        return !self.st.dead;
    }

    /// The last `stderr_tail_len` bytes the server wrote to stderr. Valid
    /// until the next call.
    pub fn stderrTail(self: Session) []const u8 {
        const st = self.st;
        st.mutex.lockUncancelable(st.io);
        defer st.mutex.unlock(st.io);
        const n: usize = @intCast(@min(st.ring_total, stderr_tail_len));
        const from: usize = @intCast((st.ring_total - n) % stderr_tail_len);
        const first = @min(n, stderr_tail_len - from);
        @memcpy(st.tail[0..first], st.ring[from..][0..first]);
        @memcpy(st.tail[first..n], st.ring[0 .. n - first]);
        return st.tail[0..n];
    }

    /// The server's process id while it is not reaped (tests use it).
    pub fn pid(self: Session) ?std.process.Child.Id {
        if (self.st.released) return null;
        return self.st.child.inner.id;
    }
};

/// Copies an `error_bundle` message body into an owned, validated bundle.
fn parseBundle(a: std.mem.Allocator, body: []const u8) error{ CompilerDied, OutOfMemory }!ErrorBundle {
    const hdr_len = @sizeOf(std.zig.Server.Message.ErrorBundle);
    if (body.len < hdr_len) return error.CompilerDied;
    const extra_len = std.mem.readInt(u32, body[0..4], .little);
    const strings_len = std.mem.readInt(u32, body[4..8], .little);
    if (hdr_len + @as(u64, extra_len) * 4 + strings_len != body.len) return error.CompilerDied;
    var bundle = std.zig.Server.allocErrorBundle(a, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EndOfStream => return error.CompilerDied,
    };
    errdefer bundle.deinit(a);
    diagnostics.validate(bundle) catch return error.CompilerDied;
    return bundle;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const is_windows = builtin.os.tag == .windows;

fn fakeArgv(script: []const u8) [8][]const u8 {
    return .{ "/bin/sh", "-c", script, "sh", "--cache-dir", "/nonexistent-ziggurat/cache", "--name", "zz" };
}

test "start rejects argv without --cache-dir or --name" {
    const a = testing.allocator;
    const cwd: OsPath = .fromTrusted(".");
    try testing.expectError(error.InvalidArgv, Session.start(a, testing.io, &.{ "/bin/sh", "--name", "zz" }, cwd));
    try testing.expectError(error.InvalidArgv, Session.start(a, testing.io, &.{ "/bin/sh", "--cache-dir", "/c" }, cwd));
    try testing.expectError(error.InvalidArgv, Session.start(a, testing.io, &.{ "/bin/sh", "--cache-dir", "/c", "--name" }, cwd));
}

test "update timeout kills a silent server" {
    if (is_windows) return error.SkipZigTest;
    const argv = fakeArgv("cat >/dev/null");
    var s = try Session.start(testing.allocator, testing.io, &argv, .fromTrusted("."));
    defer s.deinit();
    try testing.expect(s.alive());
    try testing.expectError(error.Timeout, s.update(300));
    try testing.expect(!s.alive());
    try testing.expectError(error.CompilerDied, s.update(300));
}

test "dead server gives CompilerDied and its stderr tail" {
    if (is_windows) return error.SkipZigTest;
    const argv = fakeArgv("echo boom >&2; exit 3");
    var s = try Session.start(testing.allocator, testing.io, &argv, .fromTrusted("."));
    defer s.deinit();
    try testing.expectError(error.CompilerDied, s.update(10_000));
    try testing.expect(!s.alive());
    try testing.expect(std.mem.indexOf(u8, s.stderrTail(), "boom") != null);
    // exit after death, twice, is harmless.
    s.exit();
    s.exit();
}

// The script reads the 8-byte `update` header, answers with `emit_digest`
// (digest bytes 1..16) and an empty error bundle. The second update gets an
// empty bundle without a digest. Then it waits for stdin to close.
const digest_script =
    \\head -c 8 >/dev/null
    \\printf '\002\000\000\000\021\000\000\000\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020'
    \\printf '\001\000\000\000\010\000\000\000\000\000\000\000\000\000\000\000'
    \\head -c 8 >/dev/null
    \\printf '\001\000\000\000\010\000\000\000\000\000\000\000\000\000\000\000'
    \\cat >/dev/null
;

test "the output file name follows -target" {
    const a = testing.allocator;
    const cases = [_]struct { argv: []const []const u8, want: []const u8 }{
        .{ .argv = &.{ "zig", "build-lib", "--name", "g", "-target", "x86_64-windows-gnu", "-Mroot=r.zig" }, .want = "g.dll" },
        .{ .argv = &.{ "zig", "build-lib", "--name", "g", "-target", "x86_64-linux-gnu.2.28", "-Mroot=r.zig" }, .want = "libg.so" },
        .{ .argv = &.{ "zig", "build-lib", "--name", "g", "-target", "aarch64-macos", "-Mroot=r.zig" }, .want = "libg.dylib" },
    };
    for (cases) |c| {
        const got = try libFileName(a, outputOs(c.argv), "g");
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
    // No `-target`, or one that does not parse: this host's name.
    const host = try libFileName(a, builtin.os.tag, "g");
    defer a.free(host);
    for ([_][]const []const u8{ &.{ "zig", "build-lib", "--name", "g" }, &.{ "zig", "-target", "not a triple", "x" } }) |argv| {
        const got = try libFileName(a, outputOs(argv), "g");
        defer a.free(got);
        try testing.expectEqualStrings(host, got);
    }
}

test "emit_digest gives the output path" {
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    const argv = fakeArgv(digest_script);
    var s = try Session.start(a, testing.io, &argv, .fromTrusted("."));
    defer s.deinit();
    var r = try s.update(10_000);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.bundle.errorMessageCount());
    const want = if (builtin.os.tag.isDarwin())
        "/nonexistent-ziggurat/cache/o/0102030405060708090a0b0c0d0e0f10/libzz.dylib"
    else
        "/nonexistent-ziggurat/cache/o/0102030405060708090a0b0c0d0e0f10/libzz.so";
    try testing.expectEqualStrings(want, r.output.?.bytes);
    // An update without its own digest has no output, even after a digest.
    var r2 = try s.update(10_000);
    defer r2.deinit(a);
    try testing.expectEqual(@as(u32, 0), r2.bundle.errorMessageCount());
    try testing.expect(r2.output == null);
    s.exit();
    try testing.expect(!s.alive());
    s.exit();
}

test "a chatty stderr does not block the server" {
    if (is_windows) return error.SkipZigTest;
    const script = "head -c 300000 /dev/zero | tr '\\000' x >&2\n" ++ digest_script;
    const argv = fakeArgv(script);
    var s = try Session.start(testing.allocator, testing.io, &argv, .fromTrusted("."));
    defer s.deinit();
    var r = try s.update(10_000);
    defer r.deinit(testing.allocator);
    try testing.expect(r.output != null);
    try testing.expectEqual(@as(usize, 4096), s.stderrTail().len);
    for (s.stderrTail()) |c| try testing.expectEqual(@as(u8, 'x'), c);
}

test "release does not wait for ever on a stderr held outside the group" {
    if (is_windows) return error.SkipZigTest;
    // `setsid` puts `sleep` in its own session, so the group kill misses it
    // and it keeps the stderr pipe open for 5 s.
    const argv = fakeArgv("if command -v setsid >/dev/null; then setsid sleep 5 </dev/null >/dev/null & else echo nosetsid >&2; fi; cat >/dev/null");
    const io = testing.io;
    var s = try Session.start(testing.allocator, io, &argv, .fromTrusted("."));
    // Give the shell time to start `sleep` or to report it cannot.
    try io.sleep(.fromMilliseconds(200), .awake);
    const t0 = std.Io.Clock.awake.now(io);
    s.exit();
    const ms = t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    const no_setsid = std.mem.indexOf(u8, s.stderrTail(), "nosetsid") != null;
    s.deinit();
    if (no_setsid) return error.SkipZigTest;
    try testing.expect(ms >= drain_grace_ms - 100);
    try testing.expect(ms < drain_grace_ms + 1500);
}

/// A temporary two-script project, prepared through the Task 6 workspace.
const Project = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    ws: workspace.Workspace,
    proj: []const u8,

    fn init(p: *Project) !void {
        const io = testing.io;
        p.arena_state = .init(testing.allocator);
        errdefer p.arena_state.deinit();
        const a = p.arena_state.allocator();
        p.tmp = testing.tmpDir(.{});
        errdefer p.tmp.cleanup();
        try p.tmp.dir.createDirPath(io, "proj");
        try p.tmp.dir.createDirPath(io, "cache");
        try p.tmp.dir.writeFile(io, .{ .sub_path = "proj/a.zig", .data = a_source });
        try p.tmp.dir.writeFile(io, .{ .sub_path = "proj/b.zig", .data = b_source });
        p.proj = try p.tmp.dir.realPathFileAlloc(io, "proj", a);
        const cache = try p.tmp.dir.realPathFileAlloc(io, "cache", a);
        const env: platform.path.HostEnv = .{
            .os = builtin.os.tag,
            .home = cache,
            .xdg_cache_home = cache,
            .local_app_data = cache,
        };
        const ps = platform.path.PathService.init(.{ .project = .fromTrusted(p.proj) }, env);
        const sc = try scan_mod.scan(a, io, .fromTrusted(p.proj), scan_mod.default_script_dirs);
        const stub = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.stub_sdk_path, a);
        const sdk = try a.dupe(workspace.ModuleDep, &.{.{ .name = "ziggurat", .root = .fromTrusted(stub), .deps = &.{} }});
        var msg: std.ArrayList(u8) = .empty;
        p.ws = try workspace.prepare(testing.allocator, io, ps, sc, sdk, .{}, &msg);
    }

    fn deinit(p: *Project) void {
        p.ws.deinit(testing.allocator);
        p.tmp.cleanup();
        p.arena_state.deinit();
    }

    fn argv(p: *Project, incremental: bool) ![]const []const u8 {
        const zig: platform.zig_locator.ZigInstall = .{ .exe = .fromTrusted(build_options.zig_exe), .version = "0.17.0" };
        return p.ws.argv(p.arena_state.allocator(), zig, .{ .incremental = incremental, .use_llvm = false, .optimize = .Debug });
    }

    fn write(p: *Project, sub: []const u8, data: []const u8) !void {
        var d = try p.tmp.dir.openDir(testing.io, "proj", .{});
        defer d.close(testing.io);
        try d.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }
};

const a_source =
    \\pub const extends = "Node";
    \\
    \\export fn ziggurat_test_a() i32 {
    \\    return 7;
    \\}
    \\
;

const b_source =
    \\pub const extends = "Node";
    \\
    \\export fn ziggurat_test_b() i32 {
    \\    return 1;
    \\}
    \\
;

const update_timeout_ms = 180_000;

/// Copies `output` to `<tmp>/<copy_name>` (the compiler rewrites the output
/// in place on the next update), loads the copy and calls `ziggurat_test_b`.
fn callB(p: *Project, output: OsPath, copy_name: []const u8) !i32 {
    const a = p.arena_state.allocator();
    const base = try p.tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const copy = try platform.path.join(a, .fromTrusted(base), &.{copy_name});
    try std.Io.Dir.cwd().copyFile(output.bytes, std.Io.Dir.cwd(), copy.bytes, testing.io, .{});
    var diag: [256]u8 = undefined;
    const lib = platform.loader.open(a, testing.io, copy, &diag) catch |err| {
        std.debug.print("load failed: {s}\n", .{platform.elf.diagText(&diag)});
        return err;
    };
    defer platform.loader.close(lib);
    const f = platform.loader.lookup(lib, *const fn () callconv(.c) i32, "ziggurat_test_b") orelse return error.SymbolNotFound;
    return f();
}

test "integration: session clean then edit" {
    try platform.testing_support.requireIntegration();
    const a = testing.allocator;
    var p: Project = undefined;
    try p.init();
    defer p.deinit();
    var s = try Session.start(a, testing.io, try p.argv(true), p.ws.build_dir);
    defer s.deinit();

    var r1 = try s.update(update_timeout_ms);
    defer r1.deinit(a);
    try testing.expectEqual(@as(u32, 0), r1.bundle.errorMessageCount());
    try testing.expectEqual(@as(i32, 1), try callB(&p, r1.output.?, "load1.so"));

    const good = try std.mem.replaceOwned(u8, p.arena_state.allocator(), b_source, "return 1;", "return 22;");
    try p.write("b.zig", good);
    var r2 = try s.update(update_timeout_ms);
    defer r2.deinit(a);
    try testing.expectEqual(@as(u32, 0), r2.bundle.errorMessageCount());
    try testing.expectEqual(@as(i32, 22), try callB(&p, r2.output.?, "load2.so"));

    const broken_line: u32 = @intCast(std.mem.count(u8, good, "\n") + 1);
    try p.write("b.zig", try std.mem.concat(p.arena_state.allocator(), u8, &.{ good, "fn broken( {\n" }));
    var r3 = try s.update(update_timeout_ms);
    defer r3.deinit(a);
    try testing.expect(r3.output == null);
    const ds = try diagnostics.decode(p.arena_state.allocator(), testing.io, r3.bundle, &p.ws);
    try testing.expectEqual(@as(usize, 1), ds.len);
    try testing.expectEqualStrings("b.zig", ds[0].rel.?);
    try testing.expectEqual(broken_line, ds[0].line);

    // Fixed, with a new value, so the recovery build is checked as well.
    try p.write("b.zig", try std.mem.replaceOwned(u8, p.arena_state.allocator(), b_source, "return 1;", "return 333;"));
    var r4 = try s.update(update_timeout_ms);
    defer r4.deinit(a);
    try testing.expectEqual(@as(u32, 0), r4.bundle.errorMessageCount());
    try testing.expectEqual(@as(i32, 333), try callB(&p, r4.output.?, "load4.so"));
}

test "integration: non-incremental one-shot" {
    try platform.testing_support.requireIntegration();
    const a = testing.allocator;
    var p: Project = undefined;
    try p.init();
    defer p.deinit();
    var s = try Session.start(a, testing.io, try p.argv(false), p.ws.build_dir);
    defer s.deinit();
    var r = try s.update(update_timeout_ms);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.bundle.errorMessageCount());
    s.exit();
    try testing.expect(!s.alive());
    try std.Io.Dir.cwd().access(testing.io, r.output.?.bytes, .{});
}

test "interrupt from another thread ends a running update" {
    if (is_windows) return error.SkipZigTest;
    const argv = fakeArgv("cat >/dev/null");
    var s = try Session.start(testing.allocator, testing.io, &argv, .fromTrusted("."));
    defer s.deinit();
    const Killer = struct {
        fn run(sess: Session) void {
            std.Io.sleep(testing.io, .fromMilliseconds(100), .awake) catch {};
            sess.interrupt();
        }
    };
    const t = try std.Thread.spawn(.{}, Killer.run, .{s});
    const t0 = std.Io.Clock.awake.now(testing.io);
    try testing.expectError(error.CompilerDied, s.update(30_000));
    t.join();
    try testing.expect(t0.durationTo(std.Io.Clock.awake.now(testing.io)).toMilliseconds() < 10_000);
    try testing.expect(!s.alive());
    // After release it is a no-op.
    s.interrupt();
}

test "integration: compiler died" {
    try platform.testing_support.requireIntegration();
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    var p: Project = undefined;
    try p.init();
    defer p.deinit();
    var s = try Session.start(a, testing.io, try p.argv(true), p.ws.build_dir);
    defer s.deinit();
    var r = try s.update(update_timeout_ms);
    defer r.deinit(a);
    try testing.expectEqual(@as(u32, 0), r.bundle.errorMessageCount());
    try std.posix.kill(s.pid().?, .KILL);
    try testing.expectError(error.CompilerDied, s.update(update_timeout_ms));
    try testing.expect(!s.alive());
}

test "interrupt ends a running update on Windows" {
    if (!is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    // The fake compiler reads its input and never answers: a long update.
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.fake_compiler_exe, a);
    defer a.free(exe);
    const argv = [_][]const u8{ exe, "server", "--cache-dir", "C:\\nonexistent-ziggurat\\cache", "--name", "zz" };
    var s = try Session.start(a, io, &argv, .fromTrusted("."));
    defer s.deinit();
    const Killer = struct {
        fn run(sess: Session) void {
            std.Io.sleep(testing.io, .fromMilliseconds(500), .awake) catch {};
            sess.interrupt();
        }
    };
    const t = try std.Thread.spawn(.{}, Killer.run, .{s});
    const t0 = std.Io.Clock.awake.now(io);
    try testing.expectError(error.CompilerDied, s.update(20_000));
    t.join();
    try testing.expect(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 10_000);
    try testing.expect(!s.alive());
    s.interrupt();
}
