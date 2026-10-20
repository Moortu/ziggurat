//! The generation manifest (spec section 6, "The running game"): the file
//! `.godot/ziggurat/manifest` that tells a game process the editor started
//! which staged generation to load. This file has the editor's writer; the
//! game's trusted reader comes with the game process.
//!
//! Format: exactly two lines, `gen=<n>\n` and `path=gen/<n>/<library>\n`,
//! where the path is relative to the folder that holds the manifest and
//! names the library the generation store staged (`gen/<n>/libzmod.<n>.so`
//! on Linux). The file is replaced atomically: the text goes to a temporary
//! file in the same folder, which is flushed (`fsync`) and renamed over the
//! manifest, and the folder is flushed after the rename, so a game reads
//! the old manifest or the new one, never a mix.
//!
//! Imports only std and the platform module, so the unit tests run without
//! Godot.
const std = @import("std");
const platform = @import("ziggurat_platform");

const OsPath = platform.path.OsPath;

/// The manifest's file name inside the store folder (`.godot/ziggurat`).
pub const file_name = "manifest";

/// Longest manifest text `format` writes: two keys, two decimal u32s
/// and a library name of at most `max_lib_name` bytes.
pub const max_lib_name = 128;
pub const max_bytes = "gen=\npath=gen//\n".len + 2 * 10 + max_lib_name;

pub const FormatError = error{ InvalidGeneration, InvalidLibraryName };

/// The manifest text for generation `n` whose staged library file is
/// `lib_name` (a bare file name), written into `buf`. Generation 0 and a
/// name that is empty, too long, `.`/`..` or holds a separator, a NUL, a
/// line break or a non-printable byte are refused.
pub fn format(buf: *[max_bytes]u8, n: u32, lib_name: []const u8) FormatError![]const u8 {
    if (n == 0) return error.InvalidGeneration;
    if (lib_name.len == 0 or lib_name.len > max_lib_name) return error.InvalidLibraryName;
    if (std.mem.eql(u8, lib_name, ".") or std.mem.eql(u8, lib_name, "..")) return error.InvalidLibraryName;
    for (lib_name) |c| {
        if (c == '/' or c == '\\' or c < 0x21 or c > 0x7e) return error.InvalidLibraryName;
    }
    return std.fmt.bufPrint(buf, "gen={d}\npath=gen/{d}/{s}\n", .{ n, n, lib_name }) catch unreachable;
}

/// Replaces `<store_root>/manifest` with the manifest of generation `n`
/// (see `format`), atomically. `store_root` is the generation store's folder,
/// which already exists (the generation was staged there).
pub fn write(a: std.mem.Allocator, io: std.Io, store_root: OsPath, n: u32, lib_name: []const u8) !void {
    var buf: [max_bytes]u8 = undefined;
    const text = try format(&buf, n, lib_name);
    const file = try platform.path.join(a, store_root, &.{file_name});
    defer a.free(file.bytes);
    try platform.atomic_file.writeInFolder(io, file, text);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "format gives exactly two lines" {
    var buf: [max_bytes]u8 = undefined;
    try testing.expectEqualStrings("gen=1\npath=gen/1/libzmod.1.so\n", try format(&buf, 1, "libzmod.1.so"));
    try testing.expectEqualStrings("gen=4294967295\npath=gen/4294967295/zmod.4294967295.dll\n", try format(&buf, std.math.maxInt(u32), "zmod.4294967295.dll"));
    const long: [max_lib_name]u8 = @splat('l');
    try testing.expect((try format(&buf, std.math.maxInt(u32), &long)).len <= max_bytes);
}

test "format refuses generation 0 and bad library names" {
    var buf: [max_bytes]u8 = undefined;
    try testing.expectError(error.InvalidGeneration, format(&buf, 0, "libzmod.0.so"));
    for ([_][]const u8{ "", ".", "..", "a/b.so", "a\\b.dll", "a b.so", "a\nb.so", "a\x00.so", "\xc3\xa9.so" }) |name| {
        try testing.expectError(error.InvalidLibraryName, format(&buf, 1, name));
    }
    const too_long: [max_lib_name + 1]u8 = @splat('l');
    try testing.expectError(error.InvalidLibraryName, format(&buf, 1, &too_long));
}

test "write replaces the manifest and leaves no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const a = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    try write(a, io, .fromTrusted(root), 1, "libzmod.1.so");
    try write(a, io, .fromTrusted(root), 12, "libzmod.12.so");
    const got = try tmp.dir.readFileAlloc(io, file_name, a, .limited(1024));
    defer a.free(got);
    try testing.expectEqualStrings("gen=12\npath=gen/12/libzmod.12.so\n", got);
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);

    // A refused manifest leaves the old one.
    try testing.expectError(error.InvalidLibraryName, write(a, io, .fromTrusted(root), 13, "../x.so"));
    const kept = try tmp.dir.readFileAlloc(io, file_name, a, .limited(1024));
    defer a.free(kept);
    try testing.expectEqualStrings(got, kept);
}

test "write needs the store folder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    try testing.expectError(error.FileNotFound, write(a, io, .fromTrusted(missing), 1, "libzmod.1.so"));
}
