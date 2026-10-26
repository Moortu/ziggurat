//! Community mirror list for Zig downloads (L1, std only). Rules from
//! https://ziglang.org/download/community-mirrors/: refetch the list about
//! once a day, try mirrors in random order, ziglang.org last, and name the
//! requester with `?source=`.
const std = @import("std");
const pins = @import("pins.zig");

pub const list_url = "https://ziglang.org/download/community-mirrors.txt";
/// Where ziglang.org itself serves the pinned release (the last resort).
pub const official_base = "https://ziglang.org/download/" ++ pins.zig_version;
/// Appended to every archive and signature request.
pub const source_query = "?source=ziggurat";
/// How long a fetched list is used before it is fetched again.
pub const cache_ns: i96 = 24 * std.time.ns_per_hour;

/// A list larger than this, with more mirrors, or a longer line is refused.
pub const max_list_bytes = 64 * 1024;
pub const max_mirrors = 256;
pub const max_line = 256;

pub const Error = error{Malformed} || std.mem.Allocator.Error;

/// One place to try: the archive and its signature come from the same base.
pub const Url = struct {
    /// The mirror base URL as listed (or `official_base`).
    base: []const u8,
    archive: []const u8,
    signature: []const u8,
};

/// Parses the mirror list strictly: ASCII lines ending in LF (the last LF
/// may be missing), each `https://<host>[:port][/path]` with no spaces,
/// query, fragment or user part. Any bad line refuses the whole list. The
/// caller frees the result with `freeList`.
pub fn parse(a: std.mem.Allocator, text: []const u8) Error![][]const u8 {
    if (text.len == 0 or text.len > max_list_bytes) return error.Malformed;
    const body = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |m| a.free(m);
        out.deinit(a);
    }
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (!validBase(line)) return error.Malformed;
        if (out.items.len == max_mirrors) return error.Malformed;
        const copy = try a.dupe(u8, line);
        out.append(a, copy) catch |err| {
            a.free(copy);
            return err;
        };
    }
    return out.toOwnedSlice(a);
}

/// `https://<host>[:port][/path]`: host labels of letters, digits and `-`
/// (not first or last) joined by single dots; a port from 1 to 65535; path segments of letters, digits and `-._~`,
/// never `.` or `..`; a trailing `/` is allowed.
fn validBase(line: []const u8) bool {
    const scheme = "https://";
    if (line.len > max_line or !std.mem.startsWith(u8, line, scheme)) return false;
    const rest = line[scheme.len..];
    const host_end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
    const host = rest[0..host_end];
    if (host.len == 0) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    var tail = rest[host_end..];
    if (tail.len != 0 and tail[0] == ':') {
        const port_end = std.mem.indexOfScalar(u8, tail, '/') orelse tail.len;
        const port = tail[1..port_end];
        if (port.len == 0 or port.len > 5) return false;
        for (port) |c| if (!std.ascii.isDigit(c)) return false;
        const n = std.fmt.parseInt(u32, port, 10) catch return false;
        if (n < 1 or n > 65535) return false;
        tail = tail[port_end..];
    }
    if (tail.len == 0) return true;
    // tail starts with '/'.
    var segs = std.mem.splitScalar(u8, tail[1..], '/');
    while (segs.next()) |seg| {
        if (seg.len == 0) {
            // Only a single trailing '/' may give an empty segment.
            if (segs.peek() != null) return false;
            continue;
        }
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        for (seg) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._~", c) == null) return false;
    }
    return true;
}

/// A plain release file name: letters, digits and `-._`, not starting with `.`.
fn validFile(file: []const u8) bool {
    if (file.len == 0 or file.len > max_line or file[0] == '.') return false;
    for (file) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "-._", c) == null) return false;
    return true;
}

pub fn freeList(a: std.mem.Allocator, list: []const []const u8) void {
    for (list) |m| a.free(m);
    a.free(list);
}

/// The URLs to try for `file`, in order: the mirrors shuffled with `rng`
/// (the caller passes a CSPRNG), then ziglang.org. Each base is joined to
/// the file name with exactly one `/`, and both URLs end in `source_query`.
/// `file` must be a plain file name. The caller frees the result with
/// `freeUrls`.
pub fn urls(a: std.mem.Allocator, list: []const []const u8, file: []const u8, rng: std.Random) Error![]Url {
    return urlsWith(a, list, file, rng, official_base);
}

/// As `urls`, with `last` in place of ziglang.org (the editor's host tests
/// pass a local stand-in; the product always uses `urls`).
pub fn urlsWith(a: std.mem.Allocator, list: []const []const u8, file: []const u8, rng: std.Random, last: []const u8) Error![]Url {
    if (!validFile(file)) return error.Malformed;
    const order = try a.alloc(usize, list.len);
    defer a.free(order);
    for (order, 0..) |*o, i| o.* = i;
    rng.shuffle(usize, order);

    var out: std.ArrayList(Url) = .empty;
    errdefer {
        for (out.items) |u| freeUrl(a, u);
        out.deinit(a);
    }
    try out.ensureTotalCapacityPrecise(a, list.len + 1);
    for (order) |i| out.appendAssumeCapacity(try makeUrl(a, list[i], file));
    out.appendAssumeCapacity(try makeUrl(a, last, file));
    return out.toOwnedSlice(a);
}

fn makeUrl(a: std.mem.Allocator, base: []const u8, file: []const u8) Error!Url {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const base_copy = try a.dupe(u8, base);
    errdefer a.free(base_copy);
    const archive = try std.fmt.allocPrint(a, "{s}/{s}" ++ source_query, .{ trimmed, file });
    errdefer a.free(archive);
    const signature = try std.fmt.allocPrint(a, "{s}/{s}.minisig" ++ source_query, .{ trimmed, file });
    return .{ .base = base_copy, .archive = archive, .signature = signature };
}

pub fn freeUrls(a: std.mem.Allocator, list: []const Url) void {
    for (list) |u| freeUrl(a, u);
    a.free(list);
}

fn freeUrl(a: std.mem.Allocator, u: Url) void {
    a.free(u.base);
    a.free(u.archive);
    a.free(u.signature);
}

/// True when a list saved at `mtime_ns` may still be used at `now_ns`
/// (younger than 24 hours). A time in the future counts as stale.
pub fn cacheFresh(mtime_ns: i96, now_ns: i96) bool {
    const age = @as(i128, now_ns) - @as(i128, mtime_ns);
    return age >= 0 and age < cache_ns;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sample =
    \\https://pkg.hexops.org/zig
    \\https://zig.squirl.dev
    \\https://fs.liujiacai.net/zigbuilds
    \\https://zig.example.org:8443/a/b/
    \\
;

test "strict parse" {
    const a = testing.allocator;
    const list = try parse(a, sample);
    defer freeList(a, list);
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqualStrings("https://pkg.hexops.org/zig", list[0]);
    try testing.expectEqualStrings("https://zig.example.org:8443/a/b/", list[3]);

    // The last newline may be missing.
    const no_nl = try parse(a, "https://a.example");
    defer freeList(a, no_nl);
    try testing.expectEqual(@as(usize, 1), no_nl.len);

    const bad = [_][]const u8{
        "",
        "\n",
        "http://pkg.hexops.org/zig\n",
        "https://pkg.hexops.org/zig \n",
        " https://pkg.hexops.org/zig\n",
        "https://pkg.hexops.org/z ig\n",
        "https://a.example\n\nhttps://b.example\n",
        "https://a.example\r\n",
        "https://a.example\n\n",
        "https://\n",
        "https:///zig\n",
        "https://user@a.example\n",
        "https://a.example/zig?x=1\n",
        "https://a.example/zig#x\n",
        "https://a.example/\tzig\n",
        "HTTPS://a.example\n",
        "https://a.example/\xc3\xa9\n",
        "https://a.example:\n",
        "https://a.example:80x\n",
        "https://.example\n",
        "https://a.example/../x\n",
        "ftp://a.example\n",
    };
    for (bad) |text| {
        if (parse(a, text)) |l| {
            freeList(a, l);
            std.debug.print("accepted: {f}\n", .{std.ascii.hexEscape(text, .lower)});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.Malformed, err);
    }

    // Size limits.
    const xs: [max_line]u8 = @splat('x');
    const long_line = try std.mem.concat(a, u8, &.{ "https://a.example/", &xs, "\n" });
    defer a.free(long_line);
    try testing.expectError(error.Malformed, parse(a, long_line));
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    for (0..max_mirrors + 1) |_| try many.appendSlice(a, "https://a.example\n");
    try testing.expectError(error.Malformed, parse(a, many.items));
}

test "mirrors: port and label checks" {
    const a = testing.allocator;
    const good = [_][]const u8{
        "https://a.example:1\n",
        "https://a.example:65535/zig\n",
        "https://a-b.example\n",
        "https://a.b-c-d.example:443\n",
    };
    for (good) |text| {
        const l = parse(a, text) catch |err| {
            std.debug.print("refused: {f}\n", .{std.ascii.hexEscape(text, .lower)});
            return err;
        };
        freeList(a, l);
    }
    const bad = [_][]const u8{
        "https://a.example:0\n",
        "https://a.example:00000\n",
        "https://a.example:65536\n",
        "https://a.example:99999/zig\n",
        "https://-a.example\n",
        "https://a-.example\n",
        "https://a.example-\n",
        "https://a.-example:443\n",
        "https://-\n",
    };
    for (bad) |text| {
        if (parse(a, text)) |l| {
            freeList(a, l);
            std.debug.print("accepted: {f}\n", .{std.ascii.hexEscape(text, .lower)});
            return error.TestUnexpectedResult;
        } else |err| try testing.expectEqual(error.Malformed, err);
    }
}

test "urls order" {
    const a = testing.allocator;
    const list = try parse(a, sample);
    defer freeList(a, list);
    const file = "zig-x86_64-linux-0.17.0.tar.xz";
    var prng: std.Random.DefaultPrng = .init(1234);
    const got = try urls(a, list, file, prng.random());
    defer freeUrls(a, got);
    try testing.expectEqual(list.len + 1, got.len);

    // ziglang.org is last.
    const last = got[got.len - 1];
    try testing.expectEqualStrings(official_base, last.base);
    try testing.expectEqualStrings("https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz?source=ziggurat", last.archive);
    try testing.expectEqualStrings("https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz.minisig?source=ziggurat", last.signature);

    // Every mirror once; one '/' between base and file; ?source= on both.
    var seen: [4]bool = @splat(false);
    for (got[0 .. got.len - 1]) |u| {
        const i = for (list, 0..) |m, i| {
            if (std.mem.eql(u8, m, u.base)) break i;
        } else return error.TestUnexpectedResult;
        try testing.expect(!seen[i]);
        seen[i] = true;
        const base = std.mem.trimEnd(u8, u.base, "/");
        const want_archive = try std.fmt.allocPrint(a, "{s}/{s}?source=ziggurat", .{ base, file });
        defer a.free(want_archive);
        const want_sig = try std.fmt.allocPrint(a, "{s}/{s}.minisig?source=ziggurat", .{ base, file });
        defer a.free(want_sig);
        try testing.expectEqualStrings(want_archive, u.archive);
        try testing.expectEqualStrings(want_sig, u.signature);
        try testing.expect(std.mem.indexOf(u8, u.archive["https://".len..], "//") == null);
    }
    for (seen) |s| try testing.expect(s);

    // The order depends on the random source: some seed gives another order.
    var differs = false;
    for (0..32) |seed| {
        var p: std.Random.DefaultPrng = .init(seed);
        const other = try urls(a, list, file, p.random());
        defer freeUrls(a, other);
        for (got, other) |x, y| {
            if (!std.mem.eql(u8, x.base, y.base)) differs = true;
        }
    }
    try testing.expect(differs);

    // An empty list gives only ziglang.org.
    const only = try urls(a, &.{}, file, prng.random());
    defer freeUrls(a, only);
    try testing.expectEqual(@as(usize, 1), only.len);

    // Another last resort (urlsWith) goes last the same way.
    const stand_in = try urlsWith(a, list, file, prng.random(), "http://127.0.0.1:8080/official/");
    defer freeUrls(a, stand_in);
    try testing.expectEqualStrings("http://127.0.0.1:8080/official/", stand_in[stand_in.len - 1].base);
    try testing.expectEqualStrings("http://127.0.0.1:8080/official/" ++ "zig-x86_64-linux-0.17.0.tar.xz?source=ziggurat", stand_in[stand_in.len - 1].archive);

    // The file must be a plain name.
    for ([_][]const u8{ "", "a/b.tar.xz", "../x", ".x", "a?b", "a b", "a%2fb" }) |f| {
        try testing.expectError(error.Malformed, urls(a, list, f, prng.random()));
    }
}

test "cache freshness" {
    const h: i96 = std.time.ns_per_hour;
    const t0: i96 = 1_790_965_431 * std.time.ns_per_s;
    try testing.expect(cacheFresh(t0, t0));
    try testing.expect(cacheFresh(t0, t0 + 23 * h));
    try testing.expect(!cacheFresh(t0, t0 + 24 * h));
    try testing.expect(!cacheFresh(t0, t0 + 25 * h));
    // A saved time in the future (clock moved back) is stale.
    try testing.expect(!cacheFresh(t0 + h, t0));
    // Extreme values do not overflow.
    try testing.expect(!cacheFresh(std.math.minInt(i96), std.math.maxInt(i96)));
    try testing.expect(!cacheFresh(std.math.maxInt(i96), std.math.minInt(i96)));
}
