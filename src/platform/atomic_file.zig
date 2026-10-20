//! Whole-file writes that readers never see half done: the bytes go to a
//! temporary file in the target's folder, are flushed to disk (`fsync`), and
//! then renamed over the target. The cache and manifest writers use this.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");

const Io = std.Io;

/// Replaces the file at `file` with `bytes`, creating missing parent folders.
/// On any error before the rename the target keeps its old content (or stays
/// absent) and the temporary file is removed. After the rename the folder is
/// flushed too (best effort).
pub fn write(io: Io, file: path.OsPath, bytes: []const u8) !void {
    return writeWith(io, file, bytes, true);
}

/// As `write`, but missing parent folders are an error (`error.FileNotFound`)
/// instead of being created: a save to a folder that is not there fails.
pub fn writeInFolder(io: Io, file: path.OsPath, bytes: []const u8) !void {
    return writeWith(io, file, bytes, false);
}

fn writeWith(io: Io, file: path.OsPath, bytes: []const u8, make_path: bool) !void {
    var af = try Io.Dir.cwd().createFileAtomic(io, file.bytes, .{ .make_path = make_path, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
    syncParent(io, file.bytes);
}

/// Flushes the folder that holds `file`, so the rename itself survives a
/// power loss. Best effort: a folder that cannot be opened or synced (and
/// Windows, where a folder is not opened as a file) leaves the write done.
fn syncParent(io: Io, file: []const u8) void {
    if (builtin.os.tag == .windows) return;
    const dir_path = std.fs.path.dirname(file) orelse ".";
    var dir = Io.Dir.cwd().openFile(io, dir_path, .{}) catch return;
    defer dir.close(io);
    dir.sync(io) catch {};
}

test "write creates folders, replaces content and leaves no temporary file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const file = try std.fs.path.join(a, &.{ root, "a", "b", "out.json" });
    defer a.free(file);

    try write(io, .fromTrusted(file), "first");
    try write(io, .fromTrusted(file), "second, longer");
    var dir = try tmp.dir.openDir(io, "a/b", .{ .iterate = true });
    defer dir.close(io);
    const got = try dir.readFileAlloc(io, "out.json", a, .limited(1024));
    defer a.free(got);
    try std.testing.expectEqualStrings("second, longer", got);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "writeInFolder replaces a file and refuses a missing folder" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const a = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const file = try std.fs.path.join(a, &.{ root, "out.zig" });
    defer a.free(file);
    const missing = try std.fs.path.join(a, &.{ root, "nope", "out.zig" });
    defer a.free(missing);

    try writeInFolder(io, .fromTrusted(file), "first, longer text");
    try writeInFolder(io, .fromTrusted(file), "second");
    const got = try tmp.dir.readFileAlloc(io, "out.zig", a, .limited(1024));
    defer a.free(got);
    try std.testing.expectEqualStrings("second", got);
    try std.testing.expectError(error.FileNotFound, writeInFolder(io, .fromTrusted(missing), "x"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "nope", .{}));
}
