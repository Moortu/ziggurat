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
//! name of its path, all names in the GNU long-name table (`//`), and the
//! member offsets in the symbol table (`/` or `/SYM64/`) moved to match.
//! Member headers keep their other fields, member data is copied as is.
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
    const out = normalize(arena, bytes) catch |err| fail("{s}: {t}", .{ args[1], err });
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ar_normalize: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub const Error = error{ NotAnArchive, BadMember, BadName, BadSymbolTable, OutOfMemory };

const Member = struct {
    /// Offset of the header in the input.
    offset: usize,
    header: *const [header_len]u8,
    data: []const u8,
};

/// The archive `bytes` with base names as member names (see the file
/// comment). Allocates the result with `a`.
pub fn normalize(a: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (!std.mem.startsWith(u8, bytes, magic)) return error.NotAnArchive;
    var symtab: ?Member = null;
    var sym64 = false;
    var long_names: []const u8 = "";
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
            if (symtab != null or members.items.len != 0) return error.BadSymbolTable;
            symtab = m;
            sym64 = name.len > 1;
        } else if (std.mem.eql(u8, name, "//")) {
            long_names = m.data;
        } else {
            try members.append(a, m);
        }
        p = start + size + (size & 1);
    }

    // The new long-name table: `<base name>/\n` per member.
    var table: std.ArrayList(u8) = .empty;
    defer table.deinit(a);
    const name_at = try a.alloc(usize, members.items.len);
    defer a.free(name_at);
    for (members.items, name_at) |m, *at| {
        const full = try memberName(m.header, long_names);
        const base = full[if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| i + 1 else 0..];
        if (base.len == 0) return error.BadName;
        at.* = table.items.len;
        try table.appendSlice(a, base);
        try table.appendSlice(a, "/\n");
    }

    // New member offsets: magic, symbol table, long names, members.
    var off: usize = magic.len;
    if (symtab) |s| off += header_len + padded(s.data.len);
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
/// long-name table, whose names end with `/\n`. Without the final `/`.
fn memberName(h: *const [header_len]u8, long_names: []const u8) Error![]const u8 {
    const field = std.mem.trimEnd(u8, h[0..16], " ");
    if (field.len > 1 and field[0] == '/') {
        const at = std.fmt.parseInt(usize, field[1..], 10) catch return error.BadName;
        if (at >= long_names.len) return error.BadName;
        const rest = long_names[at..];
        const end = std.mem.indexOf(u8, rest, "/\n") orelse return error.BadName;
        return rest[0..end];
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

test "not an archive, and a symbol that points nowhere" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotAnArchive, normalize(a, "!<arc>\n"));
    const in = try testArchive(a, &.{"x.o"}, &.{"obj"}, &.{.{ "entry", 0 }});
    defer a.free(in);
    std.mem.writeInt(u32, in[magic.len + header_len + 4 ..][0..4], 3, .big);
    try std.testing.expectError(error.BadSymbolTable, normalize(a, in));
}
