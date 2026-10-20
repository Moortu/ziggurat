//! Whole-file writes that readers never see half done: the bytes go to a
//! temporary file in the target's folder, are flushed to disk (`fsync`), and
//! then renamed over the target. The cache and manifest writers use this.
const std = @import("std");
const path = @import("path.zig");

const Io = std.Io;

/// Replaces the file at `file` with `bytes`, creating missing parent folders.
/// On any error the target keeps its old content (or stays absent) and the
/// temporary file is removed.
pub fn write(io: Io, file: path.OsPath, bytes: []const u8) !void {
    var af = try Io.Dir.cwd().createFileAtomic(io, file.bytes, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
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
