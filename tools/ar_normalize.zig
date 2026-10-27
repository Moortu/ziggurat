//! Build tool: makes the export host archive the same bytes in every
//! checkout and with every cache folder.
//!
//! Usage: ar_normalize <in archive> <out archive>
//!
//! Zig names an archive member after the object's path in the build
//! cache, `<cache dir>/o/<hash>/<name>.o`. The cache dir is relative or
//! absolute as `--cache-dir` was given, and the hash differs between
//! checkouts, while the object bytes are the same. So the name leaks the
//! build machine's paths and makes the archive differ per build.
//!
//! The tool writes the archive again with each member named by the base
//! name of its path, all names in the long-name table (`//`), and the
//! member offsets in the symbol table moved to match. Member headers keep
//! their other fields, member data is copied as is.
//!
//! Two forms are read and written back in the same form:
//! - GNU (Linux): one symbol table (`/` or `/SYM64/`, big endian), names
//!   in `//` end with `/\n`.
//! - Microsoft COFF (Windows `.lib`): the first linker member `/` (as
//!   GNU's), then the second linker member `/` (little endian: the member
//!   count, one offset per member, the symbol count, a 1-based member
//!   index per symbol, the names); names in `//` end with a NUL byte.
const std = @import("std");
const Io = std.Io;

const magic = "!<arch>\n";
const header_len = 60;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: ar_normalize <in archive> <out archive>\n", .{});
        std.process.exit(2);
    }
    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, args[1], arena, .limited(1 << 30)) catch |err|
        fail("cannot read {s} ({t})", .{ args[1], err });
    var problem: Problem = .{};
    const out = normalizeProblem(arena, bytes, &problem) catch |err| {
        var buf: [256]u8 = undefined;
        fail("{s}: {s}", .{ args[1], problem.text(&buf, err) });
    };
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ar_normalize: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub const Error = error{ NotAnArchive, BadMember, BadName, BadSymbolTable, DuplicateName, SecondNameTable, OutOfMemory };

/// What `normalizeProblem` found wrong, for the message.
pub const Problem = struct {
    /// For `error.DuplicateName`: the base name two members share (points
    /// into the input).
    name: []const u8 = "",

    /// One sentence for `err` (in `buf` when it names the member).
    pub fn text(p: Problem, buf: []u8, err: Error) []const u8 {
        return switch (err) {
            error.DuplicateName => std.fmt.bufPrint(buf, "two members have the same base name {s}, so their normalized names would be the same", .{p.name}) catch
                "two members have the same base name, so their normalized names would be the same",
            error.SecondNameTable => "the archive has a second long-name table (//); only one is allowed",
            error.NotAnArchive => "not an ar archive",
            error.BadMember => "a member header or size is malformed",
            error.BadName => "a member name is malformed",
            error.BadSymbolTable => "the symbol table is malformed",
            error.OutOfMemory => "out of memory",
        };
    }
};

const Member = struct {
    /// Offset of the header in the input.
    offset: usize,
    header: *const [header_len]u8,
    data: []const u8,
};

/// The archive `bytes` with base names as member names (see the file
/// comment). Allocates the result with `a`.
pub fn normalize(a: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    var problem: Problem = .{};
    return normalizeProblem(a, bytes, &problem);
}

/// As `normalize`; on `error.DuplicateName` (two members with the same
/// base name) `problem` names it. A second long-name table (`//`) is
/// `error.SecondNameTable`.
pub fn normalizeProblem(a: std.mem.Allocator, bytes: []const u8, problem: *Problem) Error![]u8 {
    if (!std.mem.startsWith(u8, bytes, magic)) return error.NotAnArchive;
    var symtab: ?Member = null;
    var sym64 = false;
    // The COFF second linker member, when the archive is COFF.
    var second: ?Member = null;
    var long_names: []const u8 = "";
    var seen_long_names = false;
    var members: std.ArrayList(Member) = .empty;
    defer members.deinit(a);
    var p: usize = magic.len;
    while (p < bytes.len) {
        if (bytes.len - p < header_len) return error.BadMember;
        const h = bytes[p..][0..header_len];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.BadMember;
        const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, h[48..58], " "), 10) catch return error.BadMember;
        const start = p + header_len;
        if (size > bytes.len - start) return error.BadMember;
        const m: Member = .{ .offset = p, .header = h, .data = bytes[start..][0..size] };
        const name = std.mem.trimEnd(u8, h[0..16], " ");
        if (std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "/SYM64/")) {
            if (members.items.len != 0) return error.BadSymbolTable;
            if (symtab == null) {
                symtab = m;
                sym64 = name.len > 1;
            } else if (second == null and !sym64 and name.len == 1 and !seen_long_names) {
                second = m;
            } else return error.BadSymbolTable;
        } else if (std.mem.eql(u8, name, "//")) {
            if (seen_long_names) return error.SecondNameTable;
            seen_long_names = true;
            long_names = m.data;
        } else {
            try members.append(a, m);
        }
        p = start + size + (size & 1);
    }

    // The new long-name table: `<base name>/\n` per member (GNU) or
    // `<base name>\x00` (COFF).
    const coff = second != null;
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(a);
    const name_at = try a.alloc(usize, members.items.len);
    defer a.free(name_at);
    var bases: std.StringHashMapUnmanaged(void) = .empty;
    defer bases.deinit(a);
    for (members.items, name_at) |m, *at| {
        const full = try memberName(m.header, long_names);
        const base = full[if (std.mem.lastIndexOfAny(u8, full, "/\\")) |i| i + 1 else 0..];
        if (base.len == 0) return error.BadName;
        if ((try bases.getOrPut(a, base)).found_existing) {
            problem.name = base;
            return error.DuplicateName;
        }
        at.* = table.items.len;
        try table.appendSlice(a, base);
        try table.appendSlice(a, if (coff) "\x00" else "/\n");
    }

    // New member offsets: magic, symbol table, long names, members.
    var off: usize = magic.len;
    if (symtab) |s| off += header_len + padded(s.data.len);
    if (second) |s| off += header_len + padded(s.data.len);
    if (members.items.len > 0) off += header_len + padded(table.items.len);
    const new_offset = try a.alloc(usize, members.items.len);
    defer a.free(new_offset);
    for (members.items, new_offset) |m, *n| {
        n.* = off;
        off += header_len + padded(m.data.len);
    }

    var out: std.ArrayList(u8) = try .initCapacity(a, off);
    errdefer out.deinit(a);
    out.appendSliceAssumeCapacity(magic);
    if (symtab) |s| {
        out.appendSliceAssumeCapacity(s.header);
        const at = out.items.len;
        out.appendSliceAssumeCapacity(s.data);
        if (sym64) {
            try moveOffsets(u64, out.items[at..][0..s.data.len], members.items, new_offset);
        } else {
            try moveOffsets(u32, out.items[at..][0..s.data.len], members.items, new_offset);
        }
        if (s.data.len & 1 == 1) out.appendAssumeCapacity('\n');
    }
    if (second) |s| {
        out.appendSliceAssumeCapacity(s.header);
        const at = out.items.len;
        out.appendSliceAssumeCapacity(s.data);
        try moveCoffOffsets(out.items[at..][0..s.data.len], members.items, new_offset);
        if (s.data.len & 1 == 1) out.appendAssumeCapacity('\n');
    }
    if (members.items.len > 0) {
        var h: [header_len]u8 = @splat(' ');
        h[0] = '/';
        h[1] = '/';
        _ = std.fmt.bufPrint(h[48..58], "{d}", .{table.items.len}) catch return error.BadMember;
        h[58] = '`';
        h[59] = '\n';
        out.appendSliceAssumeCapacity(&h);
        out.appendSliceAssumeCapacity(table.items);
        if (table.items.len & 1 == 1) out.appendAssumeCapacity('\n');
    }
    for (members.items, name_at) |m, at| {
        var h = m.header.*;
        @memset(h[0..16], ' ');
        _ = std.fmt.bufPrint(h[0..16], "/{d}", .{at}) catch return error.BadName;
        out.appendSliceAssumeCapacity(&h);
        out.appendSliceAssumeCapacity(m.data);
        if (m.data.len & 1 == 1) out.appendAssumeCapacity('\n');
    }
    std.debug.assert(out.items.len == off);
    return out.toOwnedSlice(a);
}

fn padded(n: usize) usize {
    return n + (n & 1);
}

/// A member's name: `<name>/` in the header, or `/<offset>` into the
/// long-name table, whose names end with `/\n` (GNU) or a NUL byte
/// (COFF). Without the final `/`.
fn memberName(h: *const [header_len]u8, long_names: []const u8) Error![]const u8 {
    const field = std.mem.trimEnd(u8, h[0..16], " ");
    if (field.len > 1 and field[0] == '/') {
        const at = std.fmt.parseInt(usize, field[1..], 10) catch return error.BadName;
        if (at >= long_names.len) return error.BadName;
        const rest = long_names[at..];
        const end = std.mem.indexOfAny(u8, rest, "\x00\n") orelse return error.BadName;
        if (rest[end] == 0) return rest[0..end];
        if (end == 0 or rest[end - 1] != '/') return error.BadName;
        return rest[0 .. end - 1];
    }
    if (field.len < 2 or field[field.len - 1] != '/') return error.BadName;
    return field[0 .. field.len - 1];
}

/// Rewrites the member offsets in a symbol table (big endian count, then
/// one offset per symbol, each the offset of a member's header).
fn moveOffsets(comptime T: type, table: []u8, members: []const Member, new_offset: []const usize) Error!void {
    const w = @sizeOf(T);
    if (table.len < w) return error.BadSymbolTable;
    const count = std.mem.readInt(T, table[0..w], .big);
    if (count > (table.len - w) / w) return error.BadSymbolTable;
    for (0..@intCast(count)) |i| {
        const slot = table[w + i * w ..][0..w];
        const old = std.mem.readInt(T, slot, .big);
        const idx = for (members, 0..) |m, j| {
            if (m.offset == old) break j;
        } else return error.BadSymbolTable;
        std.mem.writeInt(T, slot, std.math.cast(T, new_offset[idx]) orelse return error.BadSymbolTable, .big);
    }
}

/// Rewrites the member offsets in a COFF second linker member (little
/// endian member count, one offset per member, symbol count, a 1-based
/// member index per symbol); every index must name a member.
fn moveCoffOffsets(table: []u8, members: []const Member, new_offset: []const usize) Error!void {
    if (table.len < 4) return error.BadSymbolTable;
    const m = std.mem.readInt(u32, table[0..4], .little);
    if (m > (table.len - 4) / 4) return error.BadSymbolTable;
    for (0..m) |i| {
        const slot = table[4 + i * 4 ..][0..4];
        const old = std.mem.readInt(u32, slot, .little);
        const idx = for (members, 0..) |mem, j| {
            if (mem.offset == old) break j;
        } else return error.BadSymbolTable;
        std.mem.writeInt(u32, slot, std.math.cast(u32, new_offset[idx]) orelse return error.BadSymbolTable, .little);
    }
    const n_at = 4 + 4 * @as(usize, m);
    if (table.len - n_at < 4) return error.BadSymbolTable;
    const n = std.mem.readInt(u32, table[n_at..][0..4], .little);
    if (n > (table.len - n_at - 4) / 2) return error.BadSymbolTable;
    for (0..n) |i| {
        const index = std.mem.readInt(u16, table[n_at + 4 + 2 * i ..][0..2], .little);
        if (index == 0 or index > m) return error.BadSymbolTable;
    }
}

/// A GNU archive with a symbol table, a long-name table and the members
/// given as (name, data); every symbol points at the member with its index.
fn testArchive(a: std.mem.Allocator, names: []const []const u8, datas: []const []const u8, symbols: []const struct { []const u8, usize }) ![]u8 {
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(a);
    var at: std.ArrayList(usize) = .empty;
    defer at.deinit(a);
    for (names) |n| {
        try at.append(a, table.items.len);
        try table.appendSlice(a, n);
        try table.appendSlice(a, "/\n");
    }
    var syms: std.ArrayList(u8) = .empty;
    defer syms.deinit(a);
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(symbols.len), .big);
    try syms.appendSlice(a, &count);
    try syms.appendNTimes(a, 0, 4 * symbols.len);
    for (symbols) |s| {
        try syms.appendSlice(a, s[0]);
        try syms.append(a, 0);
    }
    // Member offsets.
    var off = magic.len + header_len + padded(syms.items.len) + header_len + padded(table.items.len);
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(a);
    for (datas) |d| {
        try offs.append(a, off);
        off += header_len + padded(d.len);
    }
    for (symbols, 0..) |s, i| std.mem.writeInt(u32, syms.items[4 + 4 * i ..][0..4], @intCast(offs.items[s[1]]), .big);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic);
    const Part = struct { []const u8, []const u8 };
    var parts: std.ArrayList(Part) = .empty;
    defer parts.deinit(a);
    try parts.append(a, .{ "/", syms.items });
    try parts.append(a, .{ "//", table.items });
    var name_bufs: [8][16]u8 = undefined;
    for (datas, 0..) |d, i| try parts.append(a, .{ try std.fmt.bufPrint(&name_bufs[i], "/{d}", .{at.items[i]}), d });
    for (parts.items) |part| {
        var h: [header_len]u8 = @splat(' ');
        @memcpy(h[0..part[0].len], part[0]);
        h[16] = '0';
        _ = try std.fmt.bufPrint(h[40..48], "644", .{});
        _ = try std.fmt.bufPrint(h[48..58], "{d}", .{part[1].len});
        h[58] = '`';
        h[59] = '\n';
        try out.appendSlice(a, &h);
        try out.appendSlice(a, part[1]);
        if (part[1].len & 1 == 1) try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// The data of the member that the symbol table's entry `i` points at.
fn symbolTarget(bytes: []const u8, i: usize) []const u8 {
    const syms = bytes[magic.len + header_len ..];
    const off = std.mem.readInt(u32, syms[4 + 4 * i ..][0..4], .big);
    const h = bytes[off..][0..header_len];
    const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, h[48..58], " "), 10) catch unreachable;
    return bytes[off + header_len ..][0..size];
}

test "member names become base names and symbol offsets follow" {
    const a = std.testing.allocator;
    const in = try testArchive(a, &.{
        "/tmp/some/cache-1/o/78464930e0cabd22d552a656365626ee/host_zcu.o",
        ".zig-cache/o/0123456789abcdef0123456789abcdef/other.o",
    }, &.{ "first object", "second object!" }, &.{ .{ "entry", 0 }, .{ "helper", 1 } });
    defer a.free(in);
    const out = try normalize(a, in);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/tmp") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zig-cache") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "host_zcu.o/\nother.o/\n") != null);
    try std.testing.expectEqualStrings("first object", symbolTarget(out, 0));
    try std.testing.expectEqualStrings("second object!", symbolTarget(out, 1));
    // Normalizing again changes nothing.
    const again = try normalize(a, out);
    defer a.free(again);
    try std.testing.expectEqualSlices(u8, out, again);
}

test "two cache folders give the same archive" {
    const a = std.testing.allocator;
    const one = try testArchive(a, &.{"/tmp/x/package-1-cache/o/00000000000000000000000000000000/h_zcu.o"}, &.{"obj"}, &.{.{ "entry", 0 }});
    defer a.free(one);
    const two = try testArchive(a, &.{"/home/someone/longer/package-22-cache/o/11111111111111111111111111111111/h_zcu.o"}, &.{"obj"}, &.{.{ "entry", 0 }});
    defer a.free(two);
    const n1 = try normalize(a, one);
    defer a.free(n1);
    const n2 = try normalize(a, two);
    defer a.free(n2);
    try std.testing.expectEqualSlices(u8, n1, n2);
    try std.testing.expectEqualStrings("obj", symbolTarget(n1, 0));
}

test "ar_normalize: duplicate base name fails" {
    const a = std.testing.allocator;
    const in = try testArchive(a, &.{
        "/cache/o/00000000000000000000000000000000/same.o",
        "/cache/o/11111111111111111111111111111111/same.o",
    }, &.{ "one", "two" }, &.{ .{ "a", 0 }, .{ "b", 1 } });
    defer a.free(in);
    var problem: Problem = .{};
    try std.testing.expectError(error.DuplicateName, normalizeProblem(a, in, &problem));
    try std.testing.expectEqualStrings("same.o", problem.name);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "two members have the same base name same.o, so their normalized names would be the same",
        problem.text(&buf, error.DuplicateName),
    );
}

test "ar_normalize: second name table fails" {
    const a = std.testing.allocator;
    const one = try testArchive(a, &.{"x.o"}, &.{"obj"}, &.{.{ "entry", 0 }});
    defer a.free(one);
    // A second `//` member after the first archive's members.
    const extra = "y.o/\n";
    var h: [header_len]u8 = @splat(' ');
    h[0] = '/';
    h[1] = '/';
    _ = try std.fmt.bufPrint(h[48..58], "{d}", .{extra.len});
    h[58] = '`';
    h[59] = '\n';
    const in = try std.mem.concat(a, u8, &.{ one, &h, extra, "\n" });
    defer a.free(in);
    var problem: Problem = .{};
    try std.testing.expectError(error.SecondNameTable, normalizeProblem(a, in, &problem));
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "the archive has a second long-name table (//); only one is allowed",
        problem.text(&buf, error.SecondNameTable),
    );
}

/// A Microsoft COFF archive (the form lld-link and Zig write for Windows):
/// the first linker member `/` (big endian count and offsets), the second
/// linker member `/` (little endian member offsets, then 1-based member
/// indices per symbol), the long-name table `//` with names that end with
/// a NUL byte, then the members as (name, data). Every symbol points at
/// the member with its index.
fn testCoffArchive(a: std.mem.Allocator, names: []const []const u8, datas: []const []const u8, symbols: []const struct { []const u8, usize }) ![]u8 {
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(a);
    var at: std.ArrayList(usize) = .empty;
    defer at.deinit(a);
    for (names) |n| {
        try at.append(a, table.items.len);
        try table.appendSlice(a, n);
        try table.append(a, 0);
    }
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(a);
    for (symbols) |s| {
        try strings.appendSlice(a, s[0]);
        try strings.append(a, 0);
    }
    const first_len = 4 + 4 * symbols.len + strings.items.len;
    const second_len = 4 + 4 * datas.len + 4 + 2 * symbols.len + strings.items.len;
    var off = magic.len + header_len + padded(first_len) + header_len + padded(second_len) + header_len + padded(table.items.len);
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(a);
    for (datas) |d| {
        try offs.append(a, off);
        off += header_len + padded(d.len);
    }
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(a);
    var w4: [4]u8 = undefined;
    std.mem.writeInt(u32, &w4, @intCast(symbols.len), .big);
    try first.appendSlice(a, &w4);
    for (symbols) |s| {
        std.mem.writeInt(u32, &w4, @intCast(offs.items[s[1]]), .big);
        try first.appendSlice(a, &w4);
    }
    try first.appendSlice(a, strings.items);
    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(a);
    std.mem.writeInt(u32, &w4, @intCast(datas.len), .little);
    try second.appendSlice(a, &w4);
    for (offs.items) |o| {
        std.mem.writeInt(u32, &w4, @intCast(o), .little);
        try second.appendSlice(a, &w4);
    }
    std.mem.writeInt(u32, &w4, @intCast(symbols.len), .little);
    try second.appendSlice(a, &w4);
    for (symbols) |s| {
        var w2: [2]u8 = undefined;
        std.mem.writeInt(u16, &w2, @intCast(s[1] + 1), .little);
        try second.appendSlice(a, &w2);
    }
    try second.appendSlice(a, strings.items);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic);
    const Part = struct { []const u8, []const u8 };
    var parts: std.ArrayList(Part) = .empty;
    defer parts.deinit(a);
    try parts.append(a, .{ "/", first.items });
    try parts.append(a, .{ "/", second.items });
    try parts.append(a, .{ "//", table.items });
    var name_bufs: [8][16]u8 = undefined;
    for (datas, 0..) |d, i| try parts.append(a, .{ try std.fmt.bufPrint(&name_bufs[i], "/{d}", .{at.items[i]}), d });
    for (parts.items) |part| {
        var h: [header_len]u8 = @splat(' ');
        @memcpy(h[0..part[0].len], part[0]);
        h[16] = '0';
        _ = try std.fmt.bufPrint(h[40..48], "644", .{});
        _ = try std.fmt.bufPrint(h[48..58], "{d}", .{part[1].len});
        h[58] = '`';
        h[59] = '\n';
        try out.appendSlice(a, &h);
        try out.appendSlice(a, part[1]);
        if (part[1].len & 1 == 1) try out.append(a, '\n');
    }
    std.debug.assert(out.items.len == off);
    return out.toOwnedSlice(a);
}

/// The data of the member at header offset `off`.
fn memberAt(bytes: []const u8, off: usize) []const u8 {
    const h = bytes[off..][0..header_len];
    const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, h[48..58], " "), 10) catch unreachable;
    return bytes[off + header_len ..][0..size];
}

/// The data of the member that symbol `i` points at, through the second
/// linker member of a COFF archive (member index, then member offset).
fn coffSecondTarget(bytes: []const u8, i: usize) []const u8 {
    const first = memberAt(bytes, magic.len);
    const second_at = magic.len + header_len + padded(first.len);
    std.debug.assert(std.mem.eql(u8, std.mem.trimEnd(u8, bytes[second_at..][0..16], " "), "/"));
    const second = memberAt(bytes, second_at);
    const m = std.mem.readInt(u32, second[0..4], .little);
    const n_at = 4 + 4 * @as(usize, m);
    const index = std.mem.readInt(u16, second[n_at + 4 + 2 * i ..][0..2], .little);
    const off = std.mem.readInt(u32, second[4 + 4 * (@as(usize, index) - 1) ..][0..4], .little);
    return memberAt(bytes, off);
}

test "ar_normalize: COFF archive from two cache folders is identical" {
    const a = std.testing.allocator;
    const datas = [_][]const u8{ "first object", "second object!" };
    const syms = [_]struct { []const u8, usize }{ .{ ".refptr.__stack_chk_guard", 0 }, .{ "ziggurat_host_init", 1 } };
    const one = try testCoffArchive(a, &.{
        ".zig-cache/o/55a36094f518a4ccd3666f670d9e08fb/ziggurat_host_export_zcu.obj",
        ".zig-cache/o/00000000000000000000000000000000/other.obj",
    }, &datas, &syms);
    defer a.free(one);
    const two = try testCoffArchive(a, &.{
        "/home/someone/longer/package-22-cache/o/11111111111111111111111111111111/ziggurat_host_export_zcu.obj",
        "/home/someone/longer/package-22-cache/o/22222222222222222222222222222222/other.obj",
    }, &datas, &syms);
    defer a.free(two);
    const n1 = try normalize(a, one);
    defer a.free(n1);
    const n2 = try normalize(a, two);
    defer a.free(n2);
    try std.testing.expectEqualSlices(u8, n1, n2);
    try std.testing.expect(std.mem.indexOf(u8, n1, "zig-cache") == null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "/home") == null);
    // COFF names end with a NUL byte, as the input's did.
    try std.testing.expect(std.mem.indexOf(u8, n1, "ziggurat_host_export_zcu.obj\x00other.obj\x00") != null);
    // Both linker members point at the right members.
    try std.testing.expectEqualStrings("first object", symbolTarget(n1, 0));
    try std.testing.expectEqualStrings("second object!", symbolTarget(n1, 1));
    try std.testing.expectEqualStrings("first object", coffSecondTarget(n1, 0));
    try std.testing.expectEqualStrings("second object!", coffSecondTarget(n1, 1));
    // Normalizing again changes nothing.
    const again = try normalize(a, n1);
    defer a.free(again);
    try std.testing.expectEqualSlices(u8, n1, again);
}

test "ar_normalize: COFF second linker member that points nowhere fails" {
    const a = std.testing.allocator;
    const in = try testCoffArchive(a, &.{"x.obj"}, &.{"obj"}, &.{.{ "entry", 0 }});
    defer a.free(in);
    const first = memberAt(in, magic.len);
    const second_data = magic.len + header_len + padded(first.len) + header_len;
    std.mem.writeInt(u32, in[second_data + 4 ..][0..4], 3, .little);
    try std.testing.expectError(error.BadSymbolTable, normalize(a, in));
}

test "not an archive, and a symbol that points nowhere" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotAnArchive, normalize(a, "!<arc>\n"));
    const in = try testArchive(a, &.{"x.o"}, &.{"obj"}, &.{.{ "entry", 0 }});
    defer a.free(in);
    std.mem.writeInt(u32, in[magic.len + header_len + 4 ..][0..4], 3, .big);
    try std.testing.expectError(error.BadSymbolTable, normalize(a, in));
}
