//! Error bundle decoding (L2): turns the compiler's `std.zig.ErrorBundle` into
//! project-relative diagnostics.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const ErrorBundle = std.zig.ErrorBundle;

/// One compiler error. `line` and `column` are 1-based; both are 0 when the
/// error has no source location.
pub const Diagnostic = struct {
    /// Project-relative path with `/` separators, or null for errors outside
    /// the project (std, the SDK without a marker, the generated root).
    rel: ?[]const u8,
    line: u32,
    column: u32,
    message: []const u8,
    notes: []const []const u8,
};

/// Frees a list returned by `decode`.
pub fn free(a: std.mem.Allocator, list: []Diagnostic) void {
    for (list) |d| freeOne(a, d);
    a.free(list);
}

fn freeOne(a: std.mem.Allocator, d: Diagnostic) void {
    if (d.rel) |r| a.free(r);
    a.free(d.message);
    for (d.notes) |n| a.free(n);
    a.free(d.notes);
}

/// Checks every index in `bundle` that `decode` or the `std.zig.ErrorBundle`
/// accessors would read.
pub fn validate(bundle: ErrorBundle) error{MalformedBundle}!void {
    const v: View = .{ .eb = bundle };
    return v.validate();
}

/// Largest script file read to find the line of an SDK marker.
const max_marker_file_bytes = 4 * 1024 * 1024;

const marker_open = "[ziggurat:";

/// Decodes `bundle` into diagnostics, one per root error message, in bundle
/// order. Every index in the bundle is checked before it is read; a bundle
/// with any index out of range is `error.MalformedBundle`.
///
/// Source paths are mapped with `ws.mapPath`. An error whose source is outside
/// the project (or that has no source) and whose message contains the SDK
/// marker `[ziggurat:<rel>#<name>]` is mapped to `<rel>`, at the first
/// top-level line of `<source_root>/<rel>` that declares `<name>` (`<name>:`,
/// `const <name>`, `fn <name>(`, each optionally after `pub `), or line 1.
/// The marker is removed from every message that carries one.
/// Free the result with `free`.
pub fn decode(a: std.mem.Allocator, io: std.Io, bundle: ErrorBundle, ws: *const Workspace) error{ MalformedBundle, OutOfMemory }![]Diagnostic {
    const v: View = .{ .eb = bundle };
    try v.validate();
    if (bundle.extra.len == 0) return a.alloc(Diagnostic, 0);

    const list = v.list() catch unreachable;
    var out: std.ArrayList(Diagnostic) = .empty;
    errdefer {
        for (out.items) |d| freeOne(a, d);
        out.deinit(a);
    }
    try out.ensureTotalCapacityPrecise(a, list.len);
    for (0..list.len) |i| {
        const mi = bundle.extra[list.start + i];
        out.appendAssumeCapacity(try decodeOne(a, io, v, mi, ws));
    }
    return out.toOwnedSlice(a);
}

fn decodeOne(a: std.mem.Allocator, io: std.Io, v: View, mi: u32, ws: *const Workspace) error{ MalformedBundle, OutOfMemory }!Diagnostic {
    const m = try v.message(mi);
    const raw = try v.string(m.msg);
    const marker = findMarker(raw);

    var rel: ?[]const u8 = null;
    errdefer if (rel) |r| a.free(r);
    var line: u32 = 0;
    var column: u32 = 0;
    if (m.src_loc != 0) {
        const loc = try v.sourceLocation(m.src_loc);
        line = loc.line +| 1;
        column = loc.column +| 1;
        rel = ws.mapPath(a, try v.string(loc.src_path)) catch |err| switch (err) {
            error.OutsideProject => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    if (rel == null) {
        if (marker) |mk| {
            rel = try a.dupe(u8, mk.rel);
            line = markerLineInFile(a, io, ws.*, mk.rel, mk.name);
            column = 1;
        }
    }

    const message = if (marker) |mk|
        try stripMarker(a, raw, mk)
    else
        try a.dupe(u8, raw);
    errdefer a.free(message);

    const note_indexes = try v.notes(mi, m.notes_len);
    const notes = try a.alloc([]const u8, note_indexes.len);
    var filled: usize = 0;
    errdefer {
        for (notes[0..filled]) |n| a.free(n);
        a.free(notes);
    }
    for (note_indexes) |ni| {
        const note = try v.message(ni);
        notes[filled] = try a.dupe(u8, try v.string(note.msg));
        filled += 1;
    }
    return .{ .rel = rel, .line = line, .column = column, .message = message, .notes = notes };
}

const Marker = struct {
    /// Byte range of the whole `[ziggurat:...]` text in the message.
    start: usize,
    end: usize,
    rel: []const u8,
    name: []const u8,
};

/// The first well-formed SDK marker in `msg`. A marker whose path could leave
/// the project or whose name is not an identifier is ignored.
fn findMarker(msg: []const u8) ?Marker {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, msg, from, marker_open)) |start| {
        from = start + 1;
        const body_start = start + marker_open.len;
        const close = std.mem.indexOfScalarPos(u8, msg, body_start, ']') orelse return null;
        const body = msg[body_start..close];
        const hash = std.mem.lastIndexOfScalar(u8, body, '#') orelse continue;
        const rel = body[0..hash];
        const name = body[hash + 1 ..];
        if (!validMarkerRel(rel) or !validIdentifier(name)) continue;
        return .{ .start = start, .end = close + 1, .rel = rel, .name = name };
    }
    return null;
}

fn validMarkerRel(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    for (rel) |c| if (c == '\\' or c == ':' or c == 0) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// `msg` without the marker and the one space before it, trimmed at the end.
fn stripMarker(a: std.mem.Allocator, msg: []const u8, mk: Marker) ![]const u8 {
    var head = msg[0..mk.start];
    if (head.len > 0 and head[head.len - 1] == ' ') head = head[0 .. head.len - 1];
    const tail = msg[mk.end..];
    const joined = try std.mem.concat(a, u8, &.{ head, tail });
    const trimmed = std.mem.trimEnd(u8, joined, " ");
    if (trimmed.len == joined.len) return joined;
    defer a.free(joined);
    return a.dupe(u8, trimmed);
}

/// Line of `name` in `<source_root>/<rel>`, or 1 when the file cannot be read.
fn markerLineInFile(a: std.mem.Allocator, io: std.Io, ws: Workspace, rel: []const u8, name: []const u8) u32 {
    const sep: []const u8 = if (ws.os == .windows) "\\" else "/";
    const native_rel = a.dupe(u8, rel) catch return 1;
    defer a.free(native_rel);
    if (ws.os == .windows) std.mem.replaceScalar(u8, native_rel, '/', '\\');
    const full = std.mem.concat(a, u8, &.{ ws.source_root.bytes, sep, native_rel }) catch return 1;
    defer a.free(full);
    const text = std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(max_marker_file_bytes)) catch return 1;
    defer a.free(text);
    return markerLine(text, name);
}

/// 1-based line of the first top-level (unindented) line in `text` that
/// declares `name`, or 1 if none does.
fn markerLine(text: []const u8, name: []const u8) u32 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 1;
    while (it.next()) |raw| : (n +|= 1) {
        var l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "pub ")) l = l["pub ".len..];
        if (declares(l, "", name, ":")) return n;
        if (declares(l, "const ", name, "")) return n;
        if (declares(l, "fn ", name, "(")) return n;
    }
    return 1;
}

/// Whether `l` is `prefix ++ name ++ after`, and when `after` is empty, the
/// name is not followed by more identifier characters.
fn declares(l: []const u8, prefix: []const u8, name: []const u8, after: []const u8) bool {
    if (!std.mem.startsWith(u8, l, prefix)) return false;
    const rest = l[prefix.len..];
    if (!std.mem.startsWith(u8, rest, name)) return false;
    const tail = rest[name.len..];
    if (after.len > 0) return std.mem.startsWith(u8, tail, after);
    return tail.len == 0 or !(std.ascii.isAlphanumeric(tail[0]) or tail[0] == '_');
}

/// Bounds-checked reads of an `ErrorBundle`. Every accessor checks its
/// indexes and returns `error.MalformedBundle` instead of reading out of range.
const View = struct {
    eb: ErrorBundle,

    const Error = error{MalformedBundle};
    const message_words = 4;
    const source_location_words = 8;
    const reference_trace_words = 2;

    fn word(v: View, i: u64) Error!u32 {
        if (i >= v.eb.extra.len) return error.MalformedBundle;
        return v.eb.extra[@intCast(i)];
    }

    /// Checks that `count` words starting at `start` lie inside `extra`.
    fn span(v: View, start: u64, count: u64) Error!void {
        if (start > v.eb.extra.len or count > v.eb.extra.len - start) return error.MalformedBundle;
    }

    fn string(v: View, i: u32) Error![]const u8 {
        const sb = v.eb.string_bytes;
        if (i >= sb.len) return error.MalformedBundle;
        const end = std.mem.indexOfScalarPos(u8, sb, i, 0) orelse return error.MalformedBundle;
        return sb[i..end];
    }

    fn list(v: View) Error!ErrorBundle.ErrorMessageList {
        try v.span(0, 3);
        const l: ErrorBundle.ErrorMessageList = .{ .len = v.eb.extra[0], .start = v.eb.extra[1], .compile_log_text = v.eb.extra[2] };
        try v.span(l.start, l.len);
        return l;
    }

    const Msg = struct { msg: u32, src_loc: u32, notes_len: u32 };

    fn message(v: View, mi: u32) Error!Msg {
        try v.span(mi, message_words);
        const m: Msg = .{ .msg = v.eb.extra[mi], .src_loc = v.eb.extra[mi + 2], .notes_len = v.eb.extra[mi + 3] };
        try v.span(@as(u64, mi) + message_words, m.notes_len);
        return m;
    }

    fn notes(v: View, mi: u32, notes_len: u32) Error![]const u32 {
        const start = @as(u64, mi) + message_words;
        try v.span(start, notes_len);
        return v.eb.extra[@intCast(start)..][0..notes_len];
    }

    const Loc = struct { src_path: u32, line: u32, column: u32, source_line: u32, reference_trace_len: u32 };

    fn sourceLocation(v: View, si: u32) Error!Loc {
        try v.span(si, source_location_words);
        const e = v.eb.extra[si..][0..source_location_words];
        const loc: Loc = .{ .src_path = e[0], .line = e[1], .column = e[2], .source_line = e[6], .reference_trace_len = e[7] };
        try v.span(@as(u64, si) + source_location_words, @as(u64, loc.reference_trace_len) * reference_trace_words);
        return loc;
    }

    /// Checks a source location, its strings and its reference trace.
    fn checkSourceLocation(v: View, si: u32, follow_traces: bool) Error!void {
        const loc = try v.sourceLocation(si);
        _ = try v.string(loc.src_path);
        if (loc.source_line != 0) _ = try v.string(loc.source_line);
        if (!follow_traces) return;
        const base = @as(u64, si) + source_location_words;
        for (0..loc.reference_trace_len) |k| {
            const at = base + k * reference_trace_words;
            const decl_name = try v.word(at);
            const trace_loc = try v.word(at + 1);
            // The sentinel entry (src_loc 0) holds a count in decl_name, not a string.
            if (trace_loc == 0) continue;
            _ = try v.string(decl_name);
            try v.checkSourceLocation(trace_loc, false);
        }
    }

    /// Checks every index reachable from the root list: messages, their
    /// strings, source locations, reference traces and notes (one level).
    fn validate(v: View) Error!void {
        if (v.eb.extra.len == 0) return;
        const l = try v.list();
        if (l.compile_log_text != 0) _ = try v.string(l.compile_log_text);
        for (0..l.len) |i| {
            const mi = v.eb.extra[l.start + i];
            try v.checkMessage(mi);
            for (try v.notes(mi, (try v.message(mi)).notes_len)) |ni| try v.checkMessage(ni);
        }
    }

    fn checkMessage(v: View, mi: u32) Error!void {
        const m = try v.message(mi);
        _ = try v.string(m.msg);
        if (m.src_loc != 0) try v.checkSourceLocation(m.src_loc, true);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A workspace value for decoding only: no lock, no folders on disk.
fn fakeWorkspace(source_root: []const u8, build_dir: []const u8) Workspace {
    return .{
        .cache_dir = .fromTrusted(build_dir),
        .build_dir = .fromTrusted(build_dir),
        .source_root = .fromTrusted(source_root),
        .mirrored = false,
        .os = builtin.os.tag,
        .sdk = &.{},
        .lock = undefined,
    };
}

const Src = struct { path: []const u8, line: u32, column: u32 };

/// Builds a bundle with one root message per entry of `msgs`; each may have a
/// source and notes.
fn buildBundle(a: std.mem.Allocator, msgs: []const struct { msg: []const u8, src: ?Src = null, notes: []const []const u8 = &.{} }) !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(a);
    errdefer wip.deinit();
    for (msgs) |m| {
        const src_loc: ErrorBundle.SourceLocationIndex = if (m.src) |s| try wip.addSourceLocation(.{
            .src_path = try wip.addString(s.path),
            .line = s.line,
            .column = s.column,
            .span_start = 0,
            .span_main = 0,
            .span_end = 0,
        }) else .none;
        try wip.addRootErrorMessage(.{
            .msg = try wip.addString(m.msg),
            .src_loc = src_loc,
            .notes_len = @intCast(m.notes.len),
        });
        const first = try wip.reserveNotes(@intCast(m.notes.len));
        for (m.notes, 0..) |n, i| {
            const ni = try wip.addErrorMessage(.{ .msg = try wip.addString(n) });
            wip.extra.items[first + i] = @backingInt(ni);
        }
    }
    return wip.toOwnedBundle("");
}

test "decode maps project paths, notes and 1-based positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ws = fakeWorkspace("/proj", "/cache/build");
    const eb = try buildBundle(a, &.{
        .{ .msg = "expected ';'", .src = .{ .path = "/proj/b.zig", .line = 4, .column = 0 }, .notes = &.{"declared here"} },
        .{ .msg = "std trouble", .src = .{ .path = "/opt/zig/lib/std/mem.zig", .line = 9, .column = 2 } },
        .{ .msg = "no source" },
    });
    const ds = try decode(a, testing.io, eb, &ws);
    try testing.expectEqual(@as(usize, 3), ds.len);
    try testing.expectEqualStrings("b.zig", ds[0].rel.?);
    try testing.expectEqual(@as(u32, 5), ds[0].line);
    try testing.expectEqual(@as(u32, 1), ds[0].column);
    try testing.expectEqualStrings("expected ';'", ds[0].message);
    try testing.expectEqual(@as(usize, 1), ds[0].notes.len);
    try testing.expectEqualStrings("declared here", ds[0].notes[0]);
    try testing.expect(ds[1].rel == null);
    try testing.expectEqual(@as(u32, 10), ds[1].line);
    try testing.expectEqual(@as(u32, 3), ds[1].column);
    try testing.expect(ds[2].rel == null);
    try testing.expectEqual(@as(u32, 0), ds[2].line);
}

test "decode of the empty bundle is empty" {
    const ws = fakeWorkspace("/proj", "/cache/build");
    const ds = try decode(testing.allocator, testing.io, ErrorBundle.empty, &ws);
    defer free(testing.allocator, ds);
    try testing.expectEqual(@as(usize, 0), ds.len);
}

test "decode frees everything with free" {
    const ws = fakeWorkspace("/proj", "/cache/build");
    var eb = try buildBundle(testing.allocator, &.{
        .{ .msg = "m [ziggurat:a.zig#x]", .src = .{ .path = "/elsewhere/sdk.zig", .line = 0, .column = 0 }, .notes = &.{ "n1", "n2" } },
        .{ .msg = "m2", .src = .{ .path = "/proj/c/d.zig", .line = 1, .column = 1 } },
    });
    defer eb.deinit(testing.allocator);
    const ds = try decode(testing.allocator, testing.io, eb, &ws);
    free(testing.allocator, ds);
}

test "malformed bundles are rejected" {
    const ws = fakeWorkspace("/proj", "/cache/build");
    const a = testing.allocator;
    const cases = [_]ErrorBundle{
        // List header cut short.
        .{ .string_bytes = &.{0}, .extra = &.{1} },
        // One message, but the message index is past the end.
        .{ .string_bytes = &.{0}, .extra = &.{ 1, 3, 0, 99 } },
        // Message string offset past string_bytes.
        .{ .string_bytes = "\x00ab\x00", .extra = &.{ 1, 3, 0, 4, 50, 1, 0, 0 } },
        // String without a terminating zero.
        .{ .string_bytes = "\x00ab", .extra = &.{ 1, 3, 0, 4, 1, 1, 0, 0 } },
        // Notes count runs past extra.
        .{ .string_bytes = "\x00ab\x00", .extra = &.{ 1, 3, 0, 4, 1, 1, 0, 1000 } },
        // Source location index past extra.
        .{ .string_bytes = "\x00ab\x00", .extra = &.{ 1, 3, 0, 4, 1, 1, 500, 0 } },
        // List start + len overflows.
        .{ .string_bytes = &.{0}, .extra = &.{ 0xffff_ffff, 0xffff_ffff, 0 } },
        // compile_log_text out of range.
        .{ .string_bytes = &.{0}, .extra = &.{ 0, 3, 77 } },
    };
    for (cases) |eb| try testing.expectError(error.MalformedBundle, decode(a, testing.io, eb, &ws));
}

test "sdk marker" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/a");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/a/x.zig", .data =
        \\pub const extends = "Node";
        \\
        \\pub fn tick() void {
        \\    const speed = 1;
        \\    _ = speed;
        \\}
        \\speed: u64 = 0,
        \\
    });
    const proj = try tmp.dir.realPathFileAlloc(testing.io, "proj", a);
    const stub = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, build_options.stub_sdk_path, a);
    const ws = fakeWorkspace(proj, try std.fs.path.join(a, &.{ proj, "..", "build" }));
    const eb = try buildBundle(a, &.{
        .{ .msg = "field type not supported [ziggurat:a/x.zig#speed]", .src = .{ .path = stub, .line = 11, .column = 4 } },
        // A name that is not declared maps to line 1.
        .{ .msg = "bad [ziggurat:a/x.zig#nothere] thing", .src = .{ .path = stub, .line = 11, .column = 4 } },
        // A file that cannot be read maps to line 1.
        .{ .msg = "gone [ziggurat:a/missing.zig#speed]", .src = .{ .path = stub, .line = 11, .column = 4 } },
        // A marker that tries to leave the project is not applied.
        .{ .msg = "evil [ziggurat:../x.zig#speed]", .src = .{ .path = stub, .line = 11, .column = 4 } },
    });
    const ds = try decode(a, testing.io, eb, &ws);
    try testing.expectEqual(@as(usize, 4), ds.len);
    try testing.expectEqualStrings("a/x.zig", ds[0].rel.?);
    try testing.expectEqual(@as(u32, 7), ds[0].line);
    try testing.expectEqual(@as(u32, 1), ds[0].column);
    try testing.expectEqualStrings("field type not supported", ds[0].message);
    try testing.expectEqualStrings("a/x.zig", ds[1].rel.?);
    try testing.expectEqual(@as(u32, 1), ds[1].line);
    try testing.expectEqualStrings("bad thing", ds[1].message);
    try testing.expectEqualStrings("a/missing.zig", ds[2].rel.?);
    try testing.expectEqual(@as(u32, 1), ds[2].line);
    try testing.expect(ds[3].rel == null);
    try testing.expectEqualStrings("evil [ziggurat:../x.zig#speed]", ds[3].message);
}

test "marker line lookup" {
    const text =
        \\const std = @import("std");
        \\pub const speedy = 1;
        \\  speed: u8 = 0,
        \\pub fn speed() void {}
        \\
    ;
    try testing.expectEqual(@as(u32, 4), markerLine(text, "speed"));
    try testing.expectEqual(@as(u32, 2), markerLine(text, "speedy"));
    try testing.expectEqual(@as(u32, 1), markerLine(text, "std"));
    try testing.expectEqual(@as(u32, 1), markerLine(text, "absent"));
    try testing.expectEqual(@as(u32, 2), markerLine("\r\nconst x = 1;\r\n", "x"));
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var extra_bytes: [512]u8 = undefined;
    var string_buf: [256]u8 = undefined;
    const n_extra = smith.slice(&extra_bytes);
    const n_str = smith.slice(&string_buf);
    var extra: [128]u32 = undefined;
    const words = n_extra / 4;
    for (0..words) |i| extra[i] = std.mem.readInt(u32, extra_bytes[i * 4 ..][0..4], .little);
    const eb: ErrorBundle = .{ .string_bytes = string_buf[0..n_str], .extra = extra[0..words] };
    const ws = fakeWorkspace("/nonexistent-ziggurat-fuzz/proj", "/nonexistent-ziggurat-fuzz/build");
    const ds = decode(testing.allocator, testing.io, eb, &ws) catch |err| switch (err) {
        error.MalformedBundle => return,
        else => return err,
    };
    free(testing.allocator, ds);
}

/// Encodes a bundle the way `fuzzOne` reads its input.
fn fuzzInput(comptime extra: []const u32, comptime strings: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, extra.len * 4, .little);
        out = out ++ &len;
        for (extra) |w| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, w, .little);
            out = out ++ &b;
        }
        std.mem.writeInt(u32, &len, strings.len, .little);
        out = out ++ &len ++ strings;
        return out;
    }
}

test "fuzz decode" {
    // A valid bundle: one message "ab" at /proj/b.zig:1:1 with one note "n".
    const valid = comptime fuzzInput(
        &.{ 1, 3, 0, 4, 1, 1, 9, 1, 17, 4, 0, 0, 0, 0, 0, 0, 0, 13, 1, 0, 0 },
        "\x00ab\x00/x/b.zig\x00n\x00",
    );
    const truncated = valid[0 .. valid.len - 9];
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{ valid, truncated } });
}
