//! Build tool: makes the export host archive the same bytes in every
//! checkout.
//!
//! Usage: ar_normalize <in archive> <out archive>
//!
//! Zig names an archive member after the object's cache path,
//! `.zig-cache/o/<32 hex digits>/<name>.o`, and the hash differs between
//! checkouts in different folders, while the object bytes are the same.
//! The tool replaces those hex digits in the GNU long-name table (`//`)
//! with `0`. The names keep their length, so no offset in the archive
//! changes. Everything else is copied as is.
const std = @import("std");
const Io = std.Io;

const magic = "!<arch>\n";
const header_len = 60;
const hash_len = 32;

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
    normalize(bytes) catch |err| fail("{s}: {t}", .{ args[1], err });
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = bytes });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ar_normalize: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Rewrites the cache hashes in the long-name table of the archive in
/// place.
pub fn normalize(bytes: []u8) error{ NotAnArchive, BadMember }!void {
    if (!std.mem.startsWith(u8, bytes, magic)) return error.NotAnArchive;
    var p: usize = magic.len;
    while (p < bytes.len) {
        if (bytes.len - p < header_len) return error.BadMember;
        const h = bytes[p..][0..header_len];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.BadMember;
        const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, h[48..58], " "), 10) catch return error.BadMember;
        const start = p + header_len;
        if (size > bytes.len - start) return error.BadMember;
        if (std.mem.eql(u8, h[0..16], "//              ")) zeroHashes(bytes[start..][0..size]);
        p = start + size + (size & 1);
    }
}

/// Replaces each `o/<32 lowercase hex digits>/` in `names` with
/// `o/<32 zeros>/`.
fn zeroHashes(names: []u8) void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, names, i, "o/")) |at| {
        i = at + 2;
        if (at > 0 and names[at - 1] != '/') continue;
        if (names.len - i < hash_len + 1 or names[i + hash_len] != '/') continue;
        const hex = names[i..][0..hash_len];
        for (hex) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) break else @memset(hex, '0');
    }
}

test "the cache hash in a long name becomes zeros, the length stays" {
    var names = ".zig-cache/o/78464930e0cabd22d552a656365626ee/a_zcu.o/\nplain.o/\n".*;
    zeroHashes(&names);
    try std.testing.expectEqualStrings(".zig-cache/o/00000000000000000000000000000000/a_zcu.o/\nplain.o/\n", &names);
}

test "a name that is not a cache path is kept" {
    var names = "foo/o/xyz/bar.o/\nfo/0123456789abcdef0123456789abcdef/x.o/\n".*;
    const before = names;
    zeroHashes(&names);
    try std.testing.expectEqualSlices(u8, &before, &names);
}

test "an archive whose long-name table holds a cache path" {
    const table = ".zig-cache/o/78464930e0cabd22d552a656365626ee/a.o/\n";
    var buf: [magic.len + header_len + table.len + 1]u8 = undefined;
    @memcpy(buf[0..magic.len], magic);
    var hdr: [header_len]u8 = @splat(' ');
    @memcpy(hdr[0..2], "//");
    _ = std.fmt.bufPrint(hdr[48..58], "{d}", .{table.len}) catch unreachable;
    @memcpy(hdr[58..60], "`\n");
    @memcpy(buf[magic.len..][0..header_len], &hdr);
    @memcpy(buf[magic.len + header_len ..][0..table.len], table);
    buf[buf.len - 1] = '\n'; // padding to an even size
    try normalize(&buf);
    try std.testing.expect(std.mem.indexOf(u8, &buf, "o/00000000000000000000000000000000/a.o") != null);
    try std.testing.expectError(error.NotAnArchive, normalize(buf[1..]));
}
