//! A small HTTP/1.1 server on 127.0.0.1 for the host tests of the Zig
//! download. It is test code: the host library never contains it. It
//! serves the files of one folder, one request per connection. For a
//! request `/<path>` (the query is ignored) it answers:
//!
//! - `<path>.location` exists: 302, its text is the `Location`;
//! - `<path>.truncate` exists: 200 with the full `Content-Length`, but only
//!   the first half of the file, then it closes the connection;
//! - `<path>.slow` exists: 200 with the full `Content-Length` and the first
//!   half of the file, then nothing more until the server stops;
//! - `<path>.trickle` exists: 200 with the file, one byte every 100 ms
//!   (until the client goes away or the server stops);
//! - `<path>` exists: 200 with the file;
//! - otherwise 404 with an HTML page (as a web server shows it).
//!
//! Every request target is logged; `count` reads the log.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    root: []u8,
    listener: Io.net.Server,
    port: u16,
    stopping: std.atomic.Value(bool) = .init(false),
    accept_thread: std.Thread = undefined,
    mu: Io.Mutex = .init,
    log: std.ArrayList([]u8) = .empty,
    conns: std.ArrayList(std.Thread) = .empty,

    /// Listens on a free port of 127.0.0.1 and serves `root` until `stop`.
    pub fn start(gpa: Allocator, io: Io, root: []const u8) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try addr.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .root = try gpa.dupe(u8, root),
            .listener = listener,
            .port = listener.socket.address.getPort(),
        };
        errdefer gpa.free(s.root);
        s.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{s});
        return s;
    }

    /// Stops accepting, waits for every connection thread and frees all.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        // Wakes the blocked accept with one connection of our own.
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(s.port) };
        if (addr.connect(s.io, .{ .mode = .stream })) |c| c.close(s.io) else |_| {}
        s.accept_thread.join();
        for (s.conns.items) |t| t.join();
        s.conns.deinit(s.gpa);
        s.listener.deinit(s.io);
        for (s.log.items) |l| s.gpa.free(l);
        s.log.deinit(s.gpa);
        s.gpa.free(s.root);
        s.gpa.destroy(s);
    }

    /// Requests so far whose target (without the query) contains `needle`.
    pub fn count(s: *Server, needle: []const u8) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var n: usize = 0;
        for (s.log.items) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) n += 1;
        }
        return n;
    }

    /// Requests so far whose target (without the query) is `path`.
    pub fn countExact(s: *Server, path: []const u8) usize {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        var n: usize = 0;
        for (s.log.items) |l| {
            if (std.mem.eql(u8, l, path)) n += 1;
        }
        return n;
    }

    /// Prints the log (for a failing test).
    pub fn dump(s: *Server) void {
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        for (s.log.items) |l| std.debug.print("fixture server: GET {s}\n", .{l});
    }

    fn acceptLoop(s: *Server) void {
        while (!s.stopping.load(.acquire)) {
            const stream = s.listener.accept(s.io) catch continue;
            if (s.stopping.load(.acquire)) {
                stream.close(s.io);
                break;
            }
            const t = std.Thread.spawn(.{}, serve, .{ s, stream }) catch {
                stream.close(s.io);
                continue;
            };
            s.conns.append(s.gpa, t) catch t.join();
        }
    }

    fn note(s: *Server, target: []const u8) void {
        const copy = s.gpa.dupe(u8, target) catch return;
        s.mu.lockUncancelable(s.io);
        defer s.mu.unlock(s.io);
        s.log.append(s.gpa, copy) catch s.gpa.free(copy);
    }

    fn serve(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var r = stream.reader(s.io, &rbuf);
        var w = stream.writer(s.io, &wbuf);
        var hs = std.http.Server.init(&r.interface, &w.interface);
        const req = hs.receiveHead() catch return;
        const full = req.head.target;
        const target = full[0 .. std.mem.indexOfScalar(u8, full, '?') orelse full.len];
        s.note(target);
        s.respond(&w.interface, target) catch {};
    }

    fn respond(s: *Server, out: *Io.Writer, target: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const rel = safeRel(target) orelse return notFound(out);
        const file = try std.fs.path.join(a, &.{ s.root, rel });
        const dir = Io.Dir.cwd();
        const limit: Io.Limit = .limited(16 << 20);

        if (dir.readFileAlloc(s.io, try std.mem.concat(a, u8, &.{ file, ".location" }), a, limit)) |loc| {
            try out.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{std.mem.trim(u8, loc, " \r\n")});
            return out.flush();
        } else |_| {}
        const body = dir.readFileAlloc(s.io, file, a, limit) catch return notFound(out);
        try out.print("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        const truncate = exists(s.io, try std.mem.concat(a, u8, &.{ file, ".truncate" }));
        const slow = exists(s.io, try std.mem.concat(a, u8, &.{ file, ".slow" }));
        if (exists(s.io, try std.mem.concat(a, u8, &.{ file, ".trickle" }))) {
            for (body) |byte| {
                if (s.stopping.load(.acquire)) return;
                try out.writeByte(byte);
                try out.flush();
                s.io.sleep(.fromMilliseconds(100), .awake) catch return;
            }
            return;
        }
        if (!truncate and !slow) {
            try out.writeAll(body);
            return out.flush();
        }
        try out.writeAll(body[0 .. body.len / 2]);
        try out.flush();
        if (truncate) return;
        // Slow: hold the connection open until the server stops (the
        // client may close its end first; nothing more is sent either way).
        while (!s.stopping.load(.acquire)) {
            s.io.sleep(.fromMilliseconds(50), .awake) catch return;
        }
    }

    fn notFound(out: *Io.Writer) !void {
        const page = "<html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>\n";
        try out.print("HTTP/1.1 404 Not Found\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ page.len, page });
        return out.flush();
    }
};

/// The target without its leading `/`, or null when it is not a plain
/// relative path (no `..`, no empty segment, no backslash).
fn safeRel(target: []const u8) ?[]const u8 {
    if (target.len < 2 or target[0] != '/') return null;
    const rel = target[1..];
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return null;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
    }
    return rel;
}

fn exists(io: Io, p: []const u8) bool {
    Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}
