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
//! Three forms are read and written back in the same form:
//! - GNU (Linux): one symbol table (`/` or `/SYM64/`, big endian), names
//!   in `//` end with `/\n`.
//! - Microsoft COFF (Windows `.lib`): the first linker member `/` (as
//!   GNU's), then the second linker member `/` (little endian: the member
//!   count, one offset per member, the symbol count, a 1-based member
//!   index per symbol, the names); names in `//` end with a NUL byte.
//! - BSD (macOS): no name table; each name is extended (`#1/<len>` in the
//!   header, the name at the start of the member data, NUL-padded so that
//!   the data after it starts at a multiple of 8, as Zig's Mach-O linker
//!   pads it). The symbol table is the first member, `__.SYMDEF` (little
//!   endian: the size of the `ranlib` entries, each a name offset and the
//!   member's header offset, then the size of the names and the names), or
//!   `__.SYMDEF_64` with 64-bit fields. Zig 0.17 already names BSD members
//!   by base name; the tool still rewrites them, so the shipped archive
//!   does not depend on that.
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
    if (isBsd(bytes)) return normalizeBsd(a, bytes, problem);
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

/// True when the first member has a BSD name: extended (`#1/`) or the
/// BSD symbol table `__.SYMDEF`. GNU and COFF archives start with `/`.
fn isBsd(bytes: []const u8) bool {
    if (bytes.len - magic.len < header_len) return false;
    const field = bytes[magic.len..][0..16];
    return std.mem.startsWith(u8, field, "#1/") or std.mem.startsWith(u8, field, "__.SYMDEF");
}

/// A BSD archive member: its name (without NUL padding) and its data
/// after the name.
const BsdMember = struct {
    /// Offset of the header in the input.
    offset: usize,
    header: *const [header_len]u8,
    name: []const u8,
    body: []const u8,
};

/// The length of the extended name field for a name of `len` bytes whose
/// member header is at `header_offset`: at least one NUL byte, and as many
/// more as make the data after the name start at a multiple of 8.
fn bsdNameLen(header_offset: usize, len: usize) usize {
    const start = header_offset + header_len;
    return std.mem.alignForward(usize, start + len + 1, 8) - start;
}

/// `normalizeProblem` for a BSD archive (see the file comment).
fn normalizeBsd(a: std.mem.Allocator, bytes: []const u8, problem: *Problem) Error![]u8 {
    var symdef: ?BsdMember = null;
    var members: std.ArrayList(BsdMember) = .empty;
    defer members.deinit(a);
    var p: usize = magic.len;
    while (p < bytes.len) {
        if (bytes.len - p < header_len) return error.BadMember;
        const h = bytes[p..][0..header_len];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.BadMember;
        const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, h[48..58], " "), 10) catch return error.BadMember;
        const start = p + header_len;
        if (size > bytes.len - start) return error.BadMember;
        const data = bytes[start..][0..size];
        const field = std.mem.trimEnd(u8, h[0..16], " ");
        var m: BsdMember = .{ .offset = p, .header = h, .name = field, .body = data };
        if (std.mem.startsWith(u8, field, "#1/")) {
            const n = std.fmt.parseInt(usize, field[3..], 10) catch return error.BadName;
            if (n > data.len) return error.BadName;
            m.name = std.mem.sliceTo(data[0..n], 0);
            m.body = data[n..];
        }
        if (m.name.len == 0) return error.BadName;
        if (std.mem.startsWith(u8, m.name, "__.SYMDEF")) {
            if (symdef != null or members.items.len != 0) return error.BadSymbolTable;
            symdef = m;
        } else {
            try members.append(a, m);
        }
        p = start + size + (size & 1);
    }

    const base_of = try a.alloc([]const u8, members.items.len);
    defer a.free(base_of);
    var bases: std.StringHashMapUnmanaged(void) = .empty;
    defer bases.deinit(a);
    for (members.items, base_of) |m, *base| {
        base.* = m.name[if (std.mem.lastIndexOfAny(u8, m.name, "/\\")) |i| i + 1 else 0..];
        if (base.len == 0) return error.BadName;
        if ((try bases.getOrPut(a, base.*)).found_existing) {
            problem.name = base.*;
            return error.DuplicateName;
        }
    }

    // New header offsets and name lengths: magic, symbol table, members.
    var off: usize = magic.len;
    const symdef_name_len = if (symdef) |s| bsdNameLen(off, s.name.len) else 0;
    if (symdef) |s| off += header_len + padded(symdef_name_len + s.body.len);
    const new_offset = try a.alloc(usize, members.items.len);
    defer a.free(new_offset);
    const name_len = try a.alloc(usize, members.items.len);
    defer a.free(name_len);
    for (members.items, base_of, new_offset, name_len) |m, base, *n, *nl| {
        n.* = off;
        nl.* = bsdNameLen(off, base.len);
        off += header_len + padded(nl.* + m.body.len);
    }

    var out: std.ArrayList(u8) = try .initCapacity(a, off);
    errdefer out.deinit(a);
    out.appendSliceAssumeCapacity(magic);
    if (symdef) |s| {
        try appendBsdMember(&out, s.header, s.name, symdef_name_len, s.body);
        const table = out.items[out.items.len - s.body.len - ((symdef_name_len + s.body.len) & 1) ..][0..s.body.len];
        if (std.mem.startsWith(u8, s.name, "__.SYMDEF_64")) {
            try moveRanlibOffsets(u64, table, members.items, new_offset);
        } else {
            try moveRanlibOffsets(u32, table, members.items, new_offset);
        }
    }
    for (members.items, base_of, name_len) |m, base, nl| try appendBsdMember(&out, m.header, base, nl, m.body);
    std.debug.assert(out.items.len == off);
    return out.toOwnedSlice(a);
}

/// Appends a BSD member with the extended name `name` (NUL-padded to
/// `name_len` bytes) and `body` after it; the header keeps its other fields.
fn appendBsdMember(out: *std.ArrayList(u8), header: *const [header_len]u8, name: []const u8, name_len: usize, body: []const u8) Error!void {
    var h = header.*;
    @memset(h[0..16], ' ');
    _ = std.fmt.bufPrint(h[0..16], "#1/{d}", .{name_len}) catch return error.BadName;
    @memset(h[48..58], ' ');
    _ = std.fmt.bufPrint(h[48..58], "{d}", .{name_len + body.len}) catch return error.BadMember;
    out.appendSliceAssumeCapacity(&h);
    out.appendSliceAssumeCapacity(name);
    out.appendNTimesAssumeCapacity(0, name_len - name.len);
    out.appendSliceAssumeCapacity(body);
    if ((name_len + body.len) & 1 == 1) out.appendAssumeCapacity('\n');
}

/// Rewrites the member offsets of a BSD symbol table (little endian: the
/// byte size of the `ranlib` entries, each a name offset and a member
/// header offset, then the byte size of the names and the names). Every
/// entry must name a string inside the names and a member.
fn moveRanlibOffsets(comptime T: type, table: []u8, members: []const BsdMember, new_offset: []const usize) Error!void {
    const w = @sizeOf(T);
    if (table.len < w) return error.BadSymbolTable;
    const entries_len = std.mem.readInt(T, table[0..w], .little);
    if (entries_len % (2 * w) != 0 or entries_len > table.len - w) return error.BadSymbolTable;
    const n: usize = @intCast(entries_len / (2 * w));
    const str_at = w + n * 2 * w;
    if (table.len - str_at < w) return error.BadSymbolTable;
    const str_len = std.mem.readInt(T, table[str_at..][0..w], .little);
    if (str_len > table.len - str_at - w) return error.BadSymbolTable;
    for (0..n) |i| {
        const entry = table[w + i * 2 * w ..][0 .. 2 * w];
        if (std.mem.readInt(T, entry[0..w], .little) >= str_len) return error.BadSymbolTable;
        const slot = entry[w..][0..w];
        const old = std.mem.readInt(T, slot, .little);
        const idx = for (members, 0..) |m, j| {
            if (m.offset == old) break j;
        } else return error.BadSymbolTable;
        std.mem.writeInt(T, slot, std.math.cast(T, new_offset[idx]) orelse return error.BadSymbolTable, .little);
    }
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

/// A BSD archive as Zig's Mach-O linker writes it: every name extended
/// (`#1/<len>`, the name NUL-padded at the start of the member data so
/// that the data after it starts at a multiple of 8), the symbol table
/// `__.SYMDEF` first (`ranlib` entries of a name offset and a member header
/// offset, little endian), then the members as (name, data). Every symbol
/// points at the member with its index. `wide` writes `__.SYMDEF_64`.
fn testBsdArchive(a: std.mem.Allocator, names: []const []const u8, datas: []const []const u8, symbols: []const struct { []const u8, usize }, comptime wide: bool) ![]u8 {
    const W = if (wide) u64 else u32;
    const w = @sizeOf(W);
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(a);
    var strx: std.ArrayList(usize) = .empty;
    defer strx.deinit(a);
    for (symbols) |s| {
        try strx.append(a, strings.items.len);
        try strings.appendSlice(a, s[0]);
        try strings.append(a, 0);
    }
    const symdef_name = if (wide) "__.SYMDEF_64" else "__.SYMDEF";
    const symdef_data_len = w + 2 * w * symbols.len + w + strings.items.len;
    // Header offsets: the symbol table, then each member.
    var offs: std.ArrayList(usize) = .empty;
    defer offs.deinit(a);
    var name_lens: std.ArrayList(usize) = .empty;
    defer name_lens.deinit(a);
    const symdef_name_len = bsdNameLen(magic.len, symdef_name.len);
    var off = magic.len + header_len + padded(symdef_name_len + symdef_data_len);
    for (names, datas) |n, d| {
        try offs.append(a, off);
        const nl = bsdNameLen(off, n.len);
        try name_lens.append(a, nl);
        off += header_len + padded(nl + d.len);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic);
    try appendBsdHeader(a, &out, symdef_name_len, symdef_data_len);
    try out.appendSlice(a, symdef_name);
    try out.appendNTimes(a, 0, symdef_name_len - symdef_name.len);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(W, buf[0..w], @intCast(2 * w * symbols.len), .little);
    try out.appendSlice(a, buf[0..w]);
    for (symbols, strx.items) |s, x| {
        std.mem.writeInt(W, buf[0..w], @intCast(x), .little);
        try out.appendSlice(a, buf[0..w]);
        std.mem.writeInt(W, buf[0..w], @intCast(offs.items[s[1]]), .little);
        try out.appendSlice(a, buf[0..w]);
    }
    std.mem.writeInt(W, buf[0..w], @intCast(strings.items.len), .little);
    try out.appendSlice(a, buf[0..w]);
    try out.appendSlice(a, strings.items);
    if ((symdef_name_len + symdef_data_len) & 1 == 1) try out.append(a, '\n');
    for (names, datas, name_lens.items, offs.items) |n, d, nl, o| {
        std.debug.assert(out.items.len == o);
        try appendBsdHeader(a, &out, nl, d.len);
        try out.appendSlice(a, n);
        try out.appendNTimes(a, 0, nl - n.len);
        try out.appendSlice(a, d);
        if ((nl + d.len) & 1 == 1) try out.append(a, '\n');
    }
    std.debug.assert(out.items.len == off);
    return out.toOwnedSlice(a);
}

fn appendBsdHeader(a: std.mem.Allocator, out: *std.ArrayList(u8), name_len: usize, data_len: usize) !void {
    var h: [header_len]u8 = @splat(' ');
    _ = try std.fmt.bufPrint(h[0..16], "#1/{d}", .{name_len});
    h[16] = '0';
    h[28] = '0';
    h[34] = '0';
    h[40] = '0';
    _ = try std.fmt.bufPrint(h[48..58], "{d}", .{name_len + data_len});
    h[58] = '`';
    h[59] = '\n';
    try out.appendSlice(a, &h);
}

/// The data (after the name) of the member that symbol `i` of a BSD
/// archive's symbol table points at.
fn bsdSymbolTarget(bytes: []const u8, i: usize) []const u8 {
    const symdef = memberAt(bytes, magic.len);
    const name_len = std.fmt.parseInt(usize, std.mem.trimEnd(u8, bytes[magic.len + 3 ..][0..13], " "), 10) catch unreachable;
    const name = std.mem.sliceTo(symdef[0..name_len], 0);
    const wide = std.mem.startsWith(u8, name, "__.SYMDEF_64");
    const table = symdef[name_len..];
    const off: usize = if (wide)
        @intCast(std.mem.readInt(u64, table[8 + 16 * i + 8 ..][0..8], .little))
    else
        std.mem.readInt(u32, table[4 + 8 * i + 4 ..][0..4], .little);
    const member = memberAt(bytes, off);
    const n = std.fmt.parseInt(usize, std.mem.trimEnd(u8, bytes[off + 3 ..][0..13], " "), 10) catch unreachable;
    return member[n..];
}

test "ar_normalize: BSD member names become base names and symbol offsets follow" {
    const a = std.testing.allocator;
    const datas = [_][]const u8{ "first object", "second object!", "third" };
    const syms = [_]struct { []const u8, usize }{ .{ "_ziggurat_host_init", 0 }, .{ "_helper", 1 }, .{ "_third", 2 } };
    inline for ([_]bool{ false, true }) |wide| {
        const one = try testBsdArchive(a, &.{
            ".zig-cache/o/55a36094f518a4ccd3666f670d9e08fb/ziggurat_host_export_zcu.o",
            "/tmp/x/package-1-cache/o/00000000000000000000000000000000/c.o",
            "short.o",
        }, &datas, &syms, wide);
        defer a.free(one);
        const two = try testBsdArchive(a, &.{
            "/home/someone/longer/package-22-cache/o/11111111111111111111111111111111/ziggurat_host_export_zcu.o",
            "c.o",
            "/elsewhere/short.o",
        }, &datas, &syms, wide);
        defer a.free(two);
        const n1 = try normalize(a, one);
        defer a.free(n1);
        const n2 = try normalize(a, two);
        defer a.free(n2);
        try std.testing.expectEqualSlices(u8, n1, n2);
        try std.testing.expect(std.mem.indexOf(u8, n1, "cache") == null);
        try std.testing.expect(std.mem.indexOf(u8, n1, "/home") == null);
        // The BSD form is kept: extended names, no GNU name table.
        try std.testing.expect(std.mem.startsWith(u8, n1[magic.len..], "#1/"));
        try std.testing.expect(std.mem.indexOf(u8, n1, "//") == null);
        // Each symbol still points at its member.
        for (datas, 0..) |d, i| try std.testing.expectEqualStrings(d, bsdSymbolTarget(n1, i));
        // It is the archive Zig would write with base names, and
        // normalizing again changes nothing.
        const want = try testBsdArchive(a, &.{ "ziggurat_host_export_zcu.o", "c.o", "short.o" }, &datas, &syms, wide);
        defer a.free(want);
        try std.testing.expectEqualSlices(u8, want, n1);
        const again = try normalize(a, n1);
        defer a.free(again);
        try std.testing.expectEqualSlices(u8, n1, again);
    }
}

test "ar_normalize: BSD archive with a symbol that points nowhere or a cut table fails" {
    const a = std.testing.allocator;
    const in = try testBsdArchive(a, &.{"x.o"}, &.{"obj"}, &.{.{ "_entry", 0 }}, false);
    defer a.free(in);
    const table = magic.len + header_len + 12;
    // The member offset of the one ranlib entry.
    const saved = std.mem.readInt(u32, in[table + 8 ..][0..4], .little);
    std.mem.writeInt(u32, in[table + 8 ..][0..4], 3, .little);
    try std.testing.expectError(error.BadSymbolTable, normalize(a, in));
    std.mem.writeInt(u32, in[table + 8 ..][0..4], saved, .little);
    // A ranlib size past the table.
    std.mem.writeInt(u32, in[table..][0..4], 4096, .little);
    try std.testing.expectError(error.BadSymbolTable, normalize(a, in));
    // An extended name longer than its member.
    const bad_name = try testBsdArchive(a, &.{"x.o"}, &.{"obj"}, &.{}, false);
    defer a.free(bad_name);
    // After the symbol table: its name (12 bytes) and an empty table (8).
    const member = magic.len + header_len + 12 + 8;
    try std.testing.expect(std.mem.startsWith(u8, bad_name[member..], "#1/"));
    @memcpy(bad_name[member + 3 ..][0..4], "9999");
    try std.testing.expectError(error.BadName, normalize(a, bad_name));
}

test "ar_normalize: BSD archive from two cache folders is identical" {
    // build.zig builds test/fixtures/ar/ (a Zig root and a C file) as a
    // static library for aarch64-macos twice, each with its own cache
    // folder, both under one folder.
    const build_options = @import("build_options");
    const a = std.testing.allocator;
    const io = std.testing.io;
    const one = try Io.Dir.cwd().readFileAlloc(io, build_options.bsd_archive_one, a, .limited(1 << 24));
    defer a.free(one);
    const two = try Io.Dir.cwd().readFileAlloc(io, build_options.bsd_archive_two, a, .limited(1 << 24));
    defer a.free(two);
    const n1 = try normalize(a, one);
    defer a.free(n1);
    const n2 = try normalize(a, two);
    defer a.free(n2);
    try std.testing.expectEqualSlices(u8, n1, n2);
    for ([_][]const u8{ "bsd-cache-one", "bsd-cache-two", "zig-cache" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, n1, needle) == null);
    }
    // BSD form: the symbol table `__.SYMDEF` first, every name extended.
    try std.testing.expect(std.mem.startsWith(u8, n1, magic ++ "#1/"));
    try std.testing.expect(std.mem.indexOf(u8, n1[0..128], "__.SYMDEF") != null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "helper.o\x00") != null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "bsd_zcu.o\x00") != null);
    // Every symbol points at a Mach-O object (64-bit magic).
    for (0..2) |i| try std.testing.expect(std.mem.startsWith(u8, bsdSymbolTarget(n1, i), "\xcf\xfa\xed\xfe"));
    // Zig 0.17 already names BSD members by base name and pads them as the
    // tool does, so normalizing its archive changes no byte.
    try std.testing.expectEqualSlices(u8, one, n1);
}
