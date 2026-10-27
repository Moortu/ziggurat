//! A project folder and a cache folder whose paths have spaces, a
//! non-ASCII letter and more than 260 characters, through the scan, the
//! workspace and the generation store (and on Windows the loader). It runs
//! on every target; on Windows (under Wine in `test-windows`) it checks the
//! long-path handling.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const scan_mod = @import("scan.zig");
const workspace = @import("workspace.zig");
const rootgen = @import("rootgen.zig");
const OsPath = platform.path.OsPath;
const testing = std.testing;

/// `<base>/<prefix> 1/<prefix> 2/...`, created, with as many parts as make
/// it longer than 300 bytes. The caller frees it.
fn deepFolder(a: std.mem.Allocator, base: []const u8, prefix: []const u8) !OsPath {
    var cur: OsPath = .fromTrusted(try a.dupe(u8, base));
    var i: u32 = 1;
    while (cur.bytes.len <= 300) : (i += 1) {
        var nb: [96]u8 = undefined;
        const part = try std.fmt.bufPrint(&nb, "{s} {d}", .{ prefix, i });
        const next = try platform.path.join(a, cur, &.{part});
        a.free(cur.bytes);
        cur = next;
    }
    try std.Io.Dir.cwd().createDirPath(testing.io, cur.bytes);
    return cur;
}

fn exists(io: std.Io, p: []const u8) bool {
    // `statFile`, not `access`: Wine's folder-relative `access` misses files.
    _ = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

test "windows paths: long and unicode project under Wine" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const project = try deepFolder(arena, base, "Mein Spiel \u{fc}ber alles mit langen Ordnernamen");
    const cache = try deepFolder(arena, base, "Zwischenspeicher f\u{fc}r Ziggurat und so weiter");
    try testing.expect(project.bytes.len > 260 and cache.bytes.len > 260);
    const script = try platform.path.join(arena, project, &.{"player.zig"});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script.bytes, .data = "pub const extends = \"Node\";\n" });

    // Scan.
    const sc = try scan_mod.scan(arena, io, project, scan_mod.default_script_dirs);
    try testing.expectEqual(@as(usize, 1), sc.scripts.len);
    try testing.expectEqual(@as(usize, 0), sc.problems.len);

    // Workspace: the project is used in place, the cache folder is under
    // the long cache path, and nothing is cut.
    const env: platform.path.HostEnv = .{
        .os = builtin.os.tag,
        .home = cache.bytes,
        .xdg_cache_home = cache.bytes,
        .local_app_data = cache.bytes,
    };
    const ps = platform.path.PathService.init(.{ .project = project }, env);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    var ws = workspace.prepare(testing.allocator, io, ps, sc, &.{}, .{}, &msg) catch |err| {
        std.debug.print("prepare: {t}: {s}\n", .{ err, msg.items });
        return err;
    };
    defer ws.deinit(testing.allocator);
    try testing.expect(!ws.mirrored);
    try testing.expectEqualStrings(project.bytes, ws.source_root.bytes);
    try testing.expect(std.mem.startsWith(u8, ws.cache_dir.bytes, cache.bytes));
    try testing.expect(exists(io, (try platform.path.join(arena, ws.source_root, &.{rootgen.root_file_name})).bytes));
    try testing.expect(exists(io, ws.build_dir.bytes));

    // Generation store under the long cache path.
    const built = try platform.path.join(arena, ws.build_dir, &.{"built.lib"});
    if (builtin.os.tag == .windows) {
        const dll = try std.Io.Dir.cwd().readFileAlloc(io, build_options.answer_dll, arena, .unlimited);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = built.bytes, .data = dll });
    } else {
        var elf: [64]u8 = @splat(0);
        @memcpy(elf[0..7], "\x7fELF\x02\x01\x01");
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = built.bytes, .data = &elf });
    }
    const store_root = try platform.path.join(arena, ws.cache_dir, &.{"store"});
    var store = platform.generation_store.GenerationStore.init(arena, io, store_root, builtin.os.tag, "game", .{ .max_count = 1 });
    var first = try store.stage(built, &.{});
    first.pin.release();
    try testing.expect(std.mem.startsWith(u8, first.gen.lib.bytes, store_root.bytes));
    const want = try std.Io.Dir.cwd().readFileAlloc(io, built.bytes, arena, .unlimited);
    const got = try std.Io.Dir.cwd().readFileAlloc(io, first.gen.lib.bytes, arena, .unlimited);
    try testing.expectEqualSlices(u8, want, got);
    if (builtin.os.tag == .windows) {
        var diag: [256]u8 = undefined;
        const lib = platform.loader.open(arena, io, first.gen.lib, &diag) catch |err| {
            std.debug.print("load: {t}: {s}\n", .{ err, platform.elf.diagText(&diag) });
            return err;
        };
        defer platform.loader.close(lib);
        const answer = platform.loader.lookup(lib, *const fn () callconv(.c) i32, "answer") orelse return error.SymbolMissing;
        try testing.expectEqual(@as(i32, 42), answer());
    }
    var second = try store.stage(built, &.{});
    second.pin.release();
    const rep = try store.sweep();
    try testing.expectEqual(@as(u32, 1), rep.deleted);
    try testing.expectEqual(@as(u32, 0), rep.failed);
}
