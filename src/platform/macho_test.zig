//! Tests of `macho.zig` against real dylibs (`test/fixtures/macho/answer_dylib.zig`,
//! built by build.zig for arm64 and x86_64 as `build_options.macho_arm64_dylib`
//! and `build_options.macho_x86_64_dylib`). The fat file is joined here. They
//! live here so that `macho.zig` itself imports only std.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const macho = @import("macho.zig");
const Allocator = std.mem.Allocator;

fn readFile(a: Allocator, p: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, a, .unlimited);
}

const Thin = struct {
    arm64: []u8,
    x86_64: []u8,

    fn read(a: Allocator) !Thin {
        const arm = try readFile(a, build_options.macho_arm64_dylib);
        errdefer a.free(arm);
        return .{ .arm64 = arm, .x86_64 = try readFile(a, build_options.macho_x86_64_dylib) };
    }
    fn deinit(t: Thin, a: Allocator) void {
        a.free(t.arm64);
        a.free(t.x86_64);
    }
};

const slice_align_log2 = 14;

/// Joins thin files into a fat file the way `lipo` does: a big-endian
/// header and arch table, then each slice at the next multiple of 2^14.
/// `wide` writes FAT_MAGIC_64 with 64-bit offsets and sizes.
fn joinFat(a: Allocator, thins: []const []const u8, wide: bool) ![]u8 {
    const entry: usize = if (wide) 32 else 20;
    var offsets: [8]u64 = undefined;
    var end: u64 = 8 + entry * thins.len;
    for (thins, 0..) |t, i| {
        offsets[i] = std.mem.alignForward(u64, end, 1 << slice_align_log2);
        end = offsets[i] + t.len;
    }
    const out = try a.alloc(u8, @intCast(end));
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], if (wide) 0xcafebabf else 0xcafebabe, .big);
    std.mem.writeInt(u32, out[4..8], @intCast(thins.len), .big);
    for (thins, 0..) |t, i| {
        const e = out[8 + entry * i ..][0..entry];
        std.mem.writeInt(u32, e[0..4], std.mem.readInt(u32, t[4..8], .little), .big); // cputype
        std.mem.writeInt(u32, e[4..8], std.mem.readInt(u32, t[8..12], .little), .big); // cpusubtype
        if (wide) {
            std.mem.writeInt(u64, e[8..16], offsets[i], .big);
            std.mem.writeInt(u64, e[16..24], t.len, .big);
            std.mem.writeInt(u32, e[24..28], slice_align_log2, .big);
        } else {
            std.mem.writeInt(u32, e[8..12], @intCast(offsets[i]), .big);
            std.mem.writeInt(u32, e[12..16], @intCast(t.len), .big);
            std.mem.writeInt(u32, e[16..20], slice_align_log2, .big);
        }
        @memcpy(out[@intCast(offsets[i])..][0..t.len], t);
    }
    return out;
}

/// The file offsets where each load command of a thin file starts, plus
/// the end of the last one.
fn commandBoundaries(a: Allocator, thin: []const u8) ![]u64 {
    const ncmds = std.mem.readInt(u32, thin[16..20], .little);
    const out = try a.alloc(u64, ncmds + 1);
    var off: u64 = 32;
    for (0..ncmds) |i| {
        out[i] = off;
        off += std.mem.readInt(u32, thin[@intCast(off + 4)..][0..4], .little);
    }
    out[ncmds] = off;
    return out;
}

test "macho: complete thin and fat accepted" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    try macho.checkComplete(t.arm64);
    try macho.checkComplete(t.x86_64);

    for ([_]bool{ false, true }) |wide| {
        const fat = try joinFat(a, &.{ t.arm64, t.x86_64 }, wide);
        defer a.free(fat);
        try macho.checkComplete(fat);
        const list = try macho.slices(a, fat);
        defer a.free(list);
        try std.testing.expectEqual(@as(usize, 2), list.len);
        try std.testing.expectEqual(macho.Cpu.arm64, list[0].cpu);
        try std.testing.expectEqual(macho.Cpu.x86_64, list[1].cpu);
        try std.testing.expectEqualSlices(u8, t.arm64, fat[@intCast(list[0].offset)..][0..@intCast(list[0].size)]);
        try std.testing.expectEqualSlices(u8, t.x86_64, fat[@intCast(list[1].offset)..][0..@intCast(list[1].size)]);
        try std.testing.expectEqual(@as(u64, 0), list[0].offset % (1 << slice_align_log2));
    }

    // A thin file is one slice covering the whole file.
    const one = try macho.slices(a, t.x86_64);
    defer a.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqual(macho.Cpu.x86_64, one[0].cpu);
    try std.testing.expectEqual(@as(u64, 0), one[0].offset);
    try std.testing.expectEqual(@as(u64, t.x86_64.len), one[0].size);
}

test "macho: truncated at each load command refused" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    for ([_][]const u8{ t.arm64, t.x86_64 }) |thin| {
        const bounds = try commandBoundaries(a, thin);
        defer a.free(bounds);
        try std.testing.expect(bounds.len > 10);
        for (bounds) |cut| {
            try std.testing.expectError(error.Truncated, macho.checkComplete(thin[0..@intCast(cut)]));
            try std.testing.expectError(error.Truncated, macho.checkComplete(thin[0..@intCast(cut - 1)]));
        }
        // Inside the header, in the middle and one byte short of the end.
        for ([_]usize{ 0, 1, 4, 31, thin.len / 2, thin.len - 1 }) |cut| {
            try std.testing.expectError(error.Truncated, macho.checkComplete(thin[0..cut]));
        }
    }

    for ([_]bool{ false, true }) |wide| {
        const fat = try joinFat(a, &.{ t.arm64, t.x86_64 }, wide);
        defer a.free(fat);
        const list = try macho.slices(a, fat);
        defer a.free(list);
        // Inside the fat header and arch table.
        for ([_]usize{ 0, 3, 7, 8, 27, 47 }) |cut| {
            try std.testing.expectError(error.Truncated, macho.checkComplete(fat[0..cut]));
        }
        // Every load-command boundary of each slice, and one byte short
        // of each slice's end.
        for (list, [_][]const u8{ t.arm64, t.x86_64 }) |s, thin| {
            const bounds = try commandBoundaries(a, thin);
            defer a.free(bounds);
            for (bounds) |cut| {
                try std.testing.expectError(error.Truncated, macho.checkComplete(fat[0..@intCast(s.offset + cut)]));
            }
            try std.testing.expectError(error.Truncated, macho.checkComplete(fat[0..@intCast(s.offset + s.size - 1)]));
        }
        // A cut slice inside a whole fat file: shrink the last slice's size
        // in the arch table, so the slice's own load commands point past it.
        const copy = try a.dupe(u8, fat);
        defer a.free(copy);
        if (wide) {
            std.mem.writeInt(u64, copy[8 + 32 + 16 ..][0..8], list[1].size - 1, .big);
        } else {
            std.mem.writeInt(u32, copy[8 + 20 + 12 ..][0..4], @intCast(list[1].size - 1), .big);
        }
        try std.testing.expectError(error.Truncated, macho.checkComplete(copy));
    }
}

fn hasName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// The names `llvm-objdump --macho --exports-trie` prints for `file`, or
/// null when the tool is missing (it is an optional oracle).
fn oracleExports(a: Allocator, file: []const u8) !?[]const []const u8 {
    if (builtin.os.tag != .linux) return null;
    const result = std.process.run(a, std.testing.io, .{
        .argv = &.{ "llvm-objdump", "--macho", "--exports-trie", file },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (!result.term.success()) return error.OracleFailed;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        // "0x00001578  _answer_pid"
        if (!std.mem.startsWith(u8, line, "0x")) continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        _ = words.next();
        const name = words.next() orelse continue;
        try names.append(a, try a.dupe(u8, name));
    }
    return try names.toOwnedSlice(a);
}

test "macho: exports and minos of a small dylib" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    for ([_][]const u8{ t.arm64, t.x86_64 }, [_][]const u8{ build_options.macho_arm64_dylib, build_options.macho_x86_64_dylib }) |thin, file| {
        const ex = try macho.exports(a, thin);
        defer macho.freeList(a, ex);
        try std.testing.expect(hasName(ex, "_answer"));
        try std.testing.expect(hasName(ex, "_answer_pid"));
        try std.testing.expect(!hasName(ex, "_getpid"));

        const im = try macho.imports(a, thin);
        defer macho.freeList(a, im);
        try std.testing.expect(hasName(im, "_getpid"));
        try std.testing.expect(!hasName(im, "_answer"));

        const v = macho.minOs(thin) orelse return error.NoMinOs;
        try std.testing.expectEqual(std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 }, v);

        if (try oracleExports(a, file)) |want| {
            defer {
                for (want) |n| a.free(n);
                a.free(want);
            }
            try std.testing.expectEqual(want.len, ex.len);
            for (want) |n| try std.testing.expect(hasName(ex, n));
        }
    }

    // Zig's linker signs the arm64 slice ad hoc and leaves x86_64 unsigned.
    const sig = macho.codeSignature(t.arm64) orelse return error.NoSignature;
    try std.testing.expect(sig.size > 0);
    try std.testing.expect(@as(u64, sig.offset) + sig.size <= t.arm64.len);
    try std.testing.expect(macho.codeSignature(t.x86_64) == null);

    // The functions take one slice: a fat file is not one.
    const fat = try joinFat(a, &.{ t.arm64, t.x86_64 }, false);
    defer a.free(fat);
    try std.testing.expectError(error.NotMachO, macho.exports(a, fat));
    try std.testing.expect(macho.minOs(fat) == null);
}
