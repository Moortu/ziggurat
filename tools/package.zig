//! Build tool: writes the release package (`zig build package`), the zip
//! that is both the release download and the Asset Store upload.
//!
//! Usage: package <out zip> (<zip path> <source>)...  (at least one pair)
//!
//! A source that is a file goes into the zip as `<zip path>`. A source
//! that is a folder goes in with every regular file below it, as
//! `<zip path>/<relative path>`; the files the Asset Store guidelines ask
//! to leave out (`.gitignore`, `.gitattributes`, `.github`, `Thumbs.db`,
//! `.DS_Store`, `__MACOSX`) are skipped, and anything other than a folder
//! or a regular file (a symlink) stops the tool.
//!
//! The zip is deterministic: entries sorted by name (bytewise), every time
//! stamp 1980-01-01 00:00, Unix mode 0644 for every file, no directory
//! entries (Godot's installer and unzip tools make the folders), no extra
//! fields, no comment. Each file is deflated, or stored when deflate does
//! not make it smaller. No zip64: the tool stops on a file or a zip of
//! 4 GiB or more, or more than 65535 entries.
const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;

/// The largest file the tool reads (the Asset Store takes 1 GB per version).
const max_file = 1 << 30;

const skipped = [_][]const u8{ ".gitignore", ".gitattributes", ".github", "Thumbs.db", ".DS_Store", "__MACOSX" };

/// DOS time and date of every entry: 00:00:00 on 1980-01-01.
const dos_time: u16 = 0;
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;
/// Version made by: Unix (3), spec 2.0.
const made_by: u16 = (3 << 8) | 20;
const needed: u16 = 20;
/// A regular file, rw-r--r--.
const external_attrs: u32 = 0o100644 << 16;

const Input = struct {
    name: []const u8,
    source: []const u8,

    fn lessThan(_: void, a: Input, b: Input) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

const Central = struct {
    name: []const u8,
    method: u16,
    crc: u32,
    csize: u32,
    size: u32,
    offset: u32,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4 or (args.len - 2) % 2 != 0) {
        std.debug.print("usage: package <out zip> (<zip path> <source>)...\n", .{});
        std.process.exit(2);
    }
    const cwd = Io.Dir.cwd();

    var inputs: std.ArrayList(Input) = .empty;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const name = args[i];
        const source = args[i + 1];
        checkName(name);
        const stat = cwd.statFile(io, source, .{ .follow_symlinks = false }) catch |err|
            fail("cannot read {s} ({t})", .{ source, err });
        switch (stat.kind) {
            .file => try inputs.append(arena, .{ .name = name, .source = source }),
            .directory => try addTree(arena, io, &inputs, name, source),
            else => fail("{s} is neither a file nor a folder", .{source}),
        }
    }
    std.mem.sort(Input, inputs.items, {}, Input.lessThan);
    for (inputs.items[1..], inputs.items[0 .. inputs.items.len - 1]) |b, a| {
        if (std.mem.eql(u8, a.name, b.name)) fail("two files for {s}", .{a.name});
    }
    if (inputs.items.len > std.math.maxInt(u16)) fail("too many files ({d})", .{inputs.items.len});

    var file = try cwd.createFile(io, args[1], .{});
    defer file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &out_buf);
    const w = &fw.interface;

    var central: std.ArrayList(Central) = .empty;
    var offset: u64 = 0;
    for (inputs.items) |in| {
        const data = cwd.readFileAlloc(io, in.source, gpa, .limited(max_file)) catch |err|
            fail("cannot read {s} ({t})", .{ in.source, err });
        defer gpa.free(data);
        const deflated = try deflate(gpa, data);
        defer gpa.free(deflated);
        const stored = deflated.len >= data.len;
        const body = if (stored) data else deflated;
        const c: Central = .{
            .name = in.name,
            .method = if (stored) 0 else 8,
            .crc = std.hash.Crc32.hash(data),
            .csize = fit32(body.len, in.name),
            .size = fit32(data.len, in.name),
            .offset = fit32(offset, in.name),
        };
        try central.append(arena, c);
        try w.writeAll("PK\x03\x04");
        try w.writeInt(u16, needed, .little);
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, c.method, .little);
        try w.writeInt(u16, dos_time, .little);
        try w.writeInt(u16, dos_date, .little);
        try w.writeInt(u32, c.crc, .little);
        try w.writeInt(u32, c.csize, .little);
        try w.writeInt(u32, c.size, .little);
        try w.writeInt(u16, @intCast(in.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeAll(in.name);
        try w.writeAll(body);
        offset += 30 + in.name.len + body.len;
    }
    const cd_start = offset;
    for (central.items) |c| {
        try w.writeAll("PK\x01\x02");
        try w.writeInt(u16, made_by, .little);
        try w.writeInt(u16, needed, .little);
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, c.method, .little);
        try w.writeInt(u16, dos_time, .little);
        try w.writeInt(u16, dos_date, .little);
        try w.writeInt(u32, c.crc, .little);
        try w.writeInt(u32, c.csize, .little);
        try w.writeInt(u32, c.size, .little);
        try w.writeInt(u16, @intCast(c.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, external_attrs, .little);
        try w.writeInt(u32, c.offset, .little);
        try w.writeAll(c.name);
        offset += 46 + c.name.len;
    }
    const count: u16 = @intCast(central.items.len);
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little); // disk
    try w.writeInt(u16, 0, .little); // disk with the central directory
    try w.writeInt(u16, count, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u32, fit32(offset - cd_start, "the central directory"), .little);
    try w.writeInt(u32, fit32(cd_start, "the central directory"), .little);
    try w.writeInt(u16, 0, .little); // comment
    try w.flush();
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("package: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn fit32(n: u64, what: []const u8) u32 {
    return std.math.cast(u32, n) orelse fail("{s} is too large for a zip without zip64", .{what});
}

/// Zip names: relative, `/` separated, printable ASCII, no empty, `.` or
/// `..` component.
fn checkName(name: []const u8) void {
    if (name.len == 0 or name.len > std.math.maxInt(u16)) fail("bad zip name \"{s}\"", .{name});
    for (name) |ch| {
        if (ch < 0x20 or ch > 0x7e or ch == '\\' or ch == ':') fail("bad character in zip name \"{s}\"", .{name});
    }
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, ".."))
            fail("bad zip name \"{s}\"", .{name});
    }
}

fn isSkipped(rel: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |c| for (skipped) |s| if (std.mem.eql(u8, c, s)) return true;
    return false;
}

fn addTree(arena: std.mem.Allocator, io: Io, inputs: *std.ArrayList(Input), prefix: []const u8, source: []const u8) !void {
    var dir = Io.Dir.cwd().openDir(io, source, .{ .iterate = true }) catch |err|
        fail("cannot open {s} ({t})", .{ source, err });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        const rel = try arena.dupe(u8, e.path);
        std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        if (isSkipped(rel)) continue;
        switch (e.kind) {
            .directory => {},
            .file => {
                const name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, rel });
                checkName(name);
                try inputs.append(arena, .{
                    .name = name,
                    .source = try std.fs.path.join(arena, &.{ source, e.path }),
                });
            },
            else => fail("{s}/{s} is neither a file nor a folder", .{ source, e.path }),
        }
    }
}

/// Raw deflate (no header) of `data` at the default level.
fn deflate(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .raw, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}
