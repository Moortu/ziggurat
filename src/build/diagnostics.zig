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
    /// the project (std, the SDK without a marker, the generated root) whose
    /// reference trace names no project file.
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
/// marker `[ziggurat:<rel>#<name>]` (`<rel>` percent-encoded as the root
/// contract in `rootgen.zig` says) is mapped to the decoded `<rel>`, at the first
/// top-level line of `<source_root>/<rel>` that declares `<name>` (`<name>:`,
/// `const <name>`, `fn <name>(`, each optionally after `pub `), or line 1.
/// The marker is removed from every message that carries one. Any other
/// error outside the project whose reference trace names a project file is
/// mapped to the first such frame (`firstProjectFrame`).
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
    const marker = findMarker(raw, ws.os);

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
            var buf: [max_marker_rel]u8 = undefined;
            // `findMarker` already checked that the path decodes.
            const plain = decodeMarkerRel(mk.rel, &buf).?;
            rel = try a.dupe(u8, plain);
            line = markerLineInFile(a, io, ws.*, plain, mk.name);
            column = 1;
        }
    }
    if (rel == null and m.src_loc != 0) {
        if (try firstProjectFrame(a, v, m.src_loc, ws)) |f| {
            rel = f.rel;
            line = f.line;
            column = f.column;
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

const Frame = struct { rel: []const u8, line: u32, column: u32 };

/// The first entry of the reference trace of source location `si` that lies
/// in the project's files (1-based), or null. For an error outside the
/// files, such as a withheld gdzig helper reported at gdzig's generated
/// class file, this is the script line that named it. The compiler keeps
/// two frames by default.
fn firstProjectFrame(a: std.mem.Allocator, v: View, si: u32, ws: *const Workspace) error{ MalformedBundle, OutOfMemory }!?Frame {
    const loc = try v.sourceLocation(si);
    const base = @as(u64, si) + View.source_location_words;
    for (0..loc.reference_trace_len) |k| {
        const trace_loc = try v.word(base + k * View.reference_trace_words + 1);
        // The sentinel entry (src_loc 0) counts hidden references.
        if (trace_loc == 0) continue;
        const tl = try v.sourceLocation(trace_loc);
        const rel = ws.mapPath(a, try v.string(tl.src_path)) catch |err| switch (err) {
            error.OutsideProject => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .rel = rel, .line = tl.line +| 1, .column = tl.column +| 1 };
    }
    return null;
}

const Marker = struct {
    /// Byte range of the whole `[ziggurat:...]` text in the message.
    start: usize,
    end: usize,
    /// As written in the message (percent-encoded); see `decodeMarkerRel`.
    rel: []const u8,
    name: []const u8,
};

/// Longest decoded marker path.
const max_marker_rel = 4096;

/// Decodes the marker's percent-encoding into `buf`: `%25` is `%`, `%5D` is
/// `]`, `%3A` is `:`, `%5C` is `\` (hex digits in either case). Any other
/// `%` sequence, or a result longer than `buf`, gives null.
fn decodeMarkerRel(enc: []const u8, buf: *[max_marker_rel]u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < enc.len) : (n += 1) {
        if (n == buf.len) return null;
        if (enc[i] != '%') {
            buf[n] = enc[i];
            i += 1;
            continue;
        }
        if (i + 3 > enc.len) return null;
        const code = std.fmt.parseInt(u8, enc[i + 1 .. i + 3], 16) catch return null;
        buf[n] = switch (code) {
            '%', ']', ':', '\\' => code,
            else => return null,
        };
        i += 3;
    }
    return buf[0..n];
}

/// The first well-formed SDK marker in `msg`. A marker whose path has a bad
/// escape or could leave the project, or whose name is not an identifier, is
/// ignored.
fn findMarker(msg: []const u8, os: std.Target.Os.Tag) ?Marker {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, msg, from, marker_open)) |start| {
        from = start + 1;
        const body_start = start + marker_open.len;
        const close = std.mem.indexOfScalarPos(u8, msg, body_start, ']') orelse return null;
        const body = msg[body_start..close];
        const hash = std.mem.lastIndexOfScalar(u8, body, '#') orelse continue;
        const rel = body[0..hash];
        const name = body[hash + 1 ..];
        var buf: [max_marker_rel]u8 = undefined;
        const plain = decodeMarkerRel(rel, &buf) orelse continue;
        if (!validMarkerRel(plain, os) or !validIdentifier(name)) continue;
        return .{ .start = start, .end = close + 1, .rel = rel, .name = name };
    }
    return null;
}

/// `rel` is the decoded path. `:` and `\\` are plain name bytes on POSIX; on
/// Windows they could name a drive or a separator, so they are refused there.
fn validMarkerRel(rel: []const u8, os: std.Target.Os.Tag) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    for (rel) |c| {
        if (c == 0) return false;
        if (os == .windows and (c == '\\' or c == ':')) return false;
    }
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

    /// Deepest note nesting accepted; real bundles use one or two levels.
    const max_note_depth = 16;

    /// Checks every index reachable from the root list: messages, their
    /// strings, source locations, reference traces, and notes at every depth.
    /// Message visits are capped at `extra.len` (a real message takes four
    /// words), so notes that point back at each other cannot make it slow.
    fn validate(v: View) Error!void {
        if (v.eb.extra.len == 0) return;
        const l = try v.list();
        if (l.compile_log_text != 0) _ = try v.string(l.compile_log_text);
        var budget: u64 = v.eb.extra.len;
        for (0..l.len) |i| try v.checkMessage(v.eb.extra[l.start + i], 0, &budget);
    }

    fn checkMessage(v: View, mi: u32, depth: u32, budget: *u64) Error!void {
        if (depth > max_note_depth or budget.* == 0) return error.MalformedBundle;
        budget.* -= 1;
        const m = try v.message(mi);
        _ = try v.string(m.msg);
        if (m.src_loc != 0) try v.checkSourceLocation(m.src_loc, true);
        for (try v.notes(mi, m.notes_len)) |ni| try v.checkMessage(ni, depth + 1, budget);
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

/// One root error at `src` whose reference trace lists `trace` (outermost
/// last), then the hidden-references sentinel.
fn buildTraced(a: std.mem.Allocator, msg: []const u8, src: Src, trace: []const Src) !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(a);
    errdefer wip.deinit();
    const locs = try a.alloc(ErrorBundle.SourceLocationIndex, trace.len);
    defer a.free(locs);
    for (trace, locs) |t, *l| l.* = try wip.addSourceLocation(.{
        .src_path = try wip.addString(t.path),
        .line = t.line,
        .column = t.column,
        .span_start = 0,
        .span_main = 0,
        .span_end = 0,
    });
    const src_loc = try wip.addSourceLocation(.{
        .src_path = try wip.addString(src.path),
        .line = src.line,
        .column = src.column,
        .span_start = 0,
        .span_main = 0,
        .span_end = 0,
        .reference_trace_len = @intCast(trace.len + 1),
    });
    for (locs) |l| try wip.addReferenceTrace(.{ .decl_name = try wip.addString("go"), .src_loc = l });
    try wip.addReferenceTrace(.{ .decl_name = 5, .src_loc = .none });
    try wip.addRootErrorMessage(.{ .msg = try wip.addString(msg), .src_loc = src_loc, .notes_len = 0 });
    return wip.toOwnedBundle("");
}

test "an error outside the project takes the first project frame of its reference trace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ws = fakeWorkspace("/proj", "/cache/build");
    const helper = "ziggurat: connect is not available in scripts; use z.emit or z.godot.Callable";
    const node: Src = .{ .path = "/sdk/gdzig/class/Node.zig", .line = 120, .column = 4 };
    // SDK frame first, then the script's line, then the generated root.
    const eb = try buildTraced(a, helper, node, &.{
        .{ .path = "/sdk/ziggurat/z.zig", .line = 30, .column = 8 },
        .{ .path = "/proj/scripts/hero.zig", .line = 7, .column = 13 },
        .{ .path = "/cache/build/root.zig", .line = 2, .column = 1 },
    });
    const ds = try decode(a, testing.io, eb, &ws);
    try testing.expectEqual(@as(usize, 1), ds.len);
    try testing.expectEqualStrings("scripts/hero.zig", ds[0].rel.?);
    try testing.expectEqual(@as(u32, 8), ds[0].line);
    try testing.expectEqual(@as(u32, 14), ds[0].column);
    try testing.expectEqualStrings(helper, ds[0].message);
    // No project frame: the error stays outside the files.
    const outside = try buildTraced(a, "std trouble", node, &.{.{ .path = "/cache/build/root.zig", .line = 2, .column = 1 }});
    const ds2 = try decode(a, testing.io, outside, &ws);
    try testing.expect(ds2[0].rel == null);
    try testing.expectEqual(@as(u32, 121), ds2[0].line);
    // An error in a project file keeps its own place.
    const inside = try buildTraced(a, "expected type", .{ .path = "/proj/a.zig", .line = 3, .column = 0 }, &.{.{ .path = "/proj/scripts/hero.zig", .line = 7, .column = 13 }});
    const ds3 = try decode(a, testing.io, inside, &ws);
    try testing.expectEqualStrings("a.zig", ds3[0].rel.?);
    try testing.expectEqual(@as(u32, 4), ds3[0].line);
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
        // A note (at 9) whose own note index is past the end.
        .{ .string_bytes = "\x00ab\x00", .extra = &.{ 1, 3, 0, 4, 1, 1, 0, 1, 9, 1, 1, 0, 1, 999 } },
        // A note that lists itself as its note: the nesting never ends.
        .{ .string_bytes = "\x00ab\x00", .extra = &.{ 1, 3, 0, 4, 1, 1, 0, 1, 9, 1, 1, 0, 1, 9 } },
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

/// A valid bundle: one message "ab" at /x/b.zig:1:1 with one note "n".
const seed_extra = [_]u32{ 1, 3, 0, 4, 1, 1, 9, 1, 17, 4, 0, 0, 0, 0, 0, 0, 0, 13, 1, 0, 0 };
const seed_strings = "\x00ab\x00/x/b.zig\x00n\x00";

test "fuzz decode" {
    const valid = comptime fuzzInput(&seed_extra, seed_strings);
    const truncated = valid[0 .. valid.len - 9];
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{ valid, truncated } });
}

test "the seed bundle decodes as expected" {
    const ws = fakeWorkspace("/x", "/x/build");
    const ds = try decode(testing.allocator, testing.io, .{ .string_bytes = seed_strings, .extra = &seed_extra }, &ws);
    defer free(testing.allocator, ds);
    try testing.expectEqual(@as(usize, 1), ds.len);
    try testing.expectEqualStrings("b.zig", ds[0].rel.?);
    try testing.expectEqual(@as(u32, 1), ds[0].line);
    try testing.expectEqual(@as(u32, 1), ds[0].column);
    try testing.expectEqualStrings("ab", ds[0].message);
    try testing.expectEqual(@as(usize, 1), ds[0].notes.len);
    try testing.expectEqualStrings("n", ds[0].notes[0]);
}

test "mutated bundles give MalformedBundle or a valid list" {
    var prng = std.Random.DefaultPrng.init(0x5eed_7a5c);
    const rand = prng.random();
    const ws = fakeWorkspace("/x", "/x/build");
    var extra: [seed_extra.len]u32 = undefined;
    var strings: [seed_strings.len]u8 = undefined;
    var valid: usize = 0;
    var malformed: usize = 0;
    for (0..20_000) |_| {
        extra = seed_extra;
        strings = seed_strings.*;
        var extra_len: usize = extra.len;
        var strings_len: usize = strings.len;
        const changes = rand.intRangeAtMost(u32, 1, 4);
        for (0..changes) |_| switch (rand.uintLessThan(u32, 6)) {
            // Flip one byte of a word.
            0 => {
                const bytes = std.mem.sliceAsBytes(&extra);
                bytes[rand.uintLessThan(usize, bytes.len)] ^= rand.int(u8) | 1;
            },
            // Flip one string byte.
            1 => strings[rand.uintLessThan(usize, strings.len)] ^= rand.int(u8) | 1,
            // A word just past the end of extra or string_bytes.
            2 => extra[rand.uintLessThan(usize, extra.len)] = @intCast(extra.len + rand.uintLessThan(u32, 4)),
            3 => extra[rand.uintLessThan(usize, extra.len)] = @intCast(strings.len + rand.uintLessThan(u32, 4)),
            // Any value at all.
            4 => extra[rand.uintLessThan(usize, extra.len)] = rand.int(u32),
            // Truncate one of the arrays.
            else => if (rand.boolean()) {
                extra_len = rand.uintLessThan(usize, extra_len + 1);
            } else {
                strings_len = rand.uintLessThan(usize, strings_len + 1);
            },
        };
        const eb: ErrorBundle = .{ .string_bytes = strings[0..strings_len], .extra = extra[0..extra_len] };
        if (decode(testing.allocator, testing.io, eb, &ws)) |ds| {
            free(testing.allocator, ds);
            valid += 1;
        } else |err| switch (err) {
            error.MalformedBundle => malformed += 1,
            else => return err,
        }
    }
    // Both outcomes must occur, or the mutations are not reaching the checks.
    try testing.expect(valid > 0 and malformed > 0);
}

test "sdk marker with a percent-encoded path" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/[old]:x");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/[old]:x/a%b.zig", .data = "const q = 1;\nspeed: u64 = 0,\n" });
    const proj = try tmp.dir.realPathFileAlloc(testing.io, "proj", a);
    const stub = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, build_options.stub_sdk_path, a);
    const ws = fakeWorkspace(proj, try std.fs.path.join(a, &.{ proj, "..", "build" }));
    const eb = try buildBundle(a, &.{
        .{ .msg = "bad field [ziggurat:[old%5d%3Ax/a%25b.zig#speed]", .src = .{ .path = stub, .line = 1, .column = 1 } },
        // Bad escapes: no marker.
        .{ .msg = "m1 [ziggurat:a%2.zig#speed]", .src = .{ .path = stub, .line = 1, .column = 1 } },
        .{ .msg = "m2 [ziggurat:a%41.zig#speed]", .src = .{ .path = stub, .line = 1, .column = 1 } },
        .{ .msg = "m3 [ziggurat:a%.zig#speed]", .src = .{ .path = stub, .line = 1, .column = 1 } },
        // An encoded path that leaves the project is still refused.
        .{ .msg = "m4 [ziggurat:a/../../x.zig#speed]", .src = .{ .path = stub, .line = 1, .column = 1 } },
    });
    const ds = try decode(a, testing.io, eb, &ws);
    try testing.expectEqual(@as(usize, 5), ds.len);
    try testing.expectEqualStrings("[old]:x/a%b.zig", ds[0].rel.?);
    try testing.expectEqual(@as(u32, 2), ds[0].line);
    try testing.expectEqualStrings("bad field", ds[0].message);
    for (ds[1..]) |d| try testing.expect(d.rel == null);
    try testing.expectEqualStrings("m1 [ziggurat:a%2.zig#speed]", ds[1].message);
}
