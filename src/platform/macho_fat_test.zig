//! Tests of `macho_fat.zig` against real dylibs (`test/fixtures/macho/answer_dylib.zig`,
//! built by build.zig for arm64 and x86_64 as `build_options.macho_arm64_dylib`
//! and `build_options.macho_x86_64_dylib`). They live here so that
//! `macho_fat.zig` itself imports only std. `llvm-lipo` is an optional
//! oracle: its part is skipped when it is not on PATH.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const macho = @import("macho.zig");
const macho_fat = @import("macho_fat.zig");
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

/// The architectures `llvm-lipo -info` lists for `file`, as one line
/// ("x86_64 arm64"), or null when the tool is missing.
fn oracleArchs(a: Allocator, file: []const u8) !?[]u8 {
    if (builtin.os.tag != .linux) return null;
    const result = std.process.run(a, std.testing.io, .{
        .argv = &.{ "llvm-lipo", "-info", file },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (!result.term.success()) return error.OracleFailed;
    // "Architectures in the fat file: <file> are: x86_64 arm64 \n"
    const marker = " are: ";
    const at = std.mem.lastIndexOf(u8, result.stdout, marker) orelse return error.OracleFailed;
    return try a.dupe(u8, std.mem.trim(u8, result.stdout[at + marker.len ..], " \r\n"));
}

test "macho_fat: joins and llvm-lipo agrees" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    const fat = try macho_fat.join(a, t.arm64, t.x86_64, null);
    defer a.free(fat);

    try macho.checkComplete(fat);
    // FAT_MAGIC, x86_64 first and arm64 second, as `lipo` writes them.
    try std.testing.expectEqual(@as(u32, std.macho.FAT_MAGIC), std.mem.readInt(u32, fat[0..4], .big));
    const list = try macho.slices(a, fat);
    defer a.free(list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(macho.Cpu.x86_64, list[0].cpu);
    try std.testing.expectEqual(macho.Cpu.arm64, list[1].cpu);
    for (list, [_][]const u8{ t.x86_64, t.arm64 }, 0..) |s, thin, i| {
        try std.testing.expectEqual(@as(u64, 0), s.offset % (1 << macho_fat.align_log2));
        try std.testing.expectEqualSlices(u8, thin, fat[@intCast(s.offset)..][0..@intCast(s.size)]);
        // Each arch entry: cpusubtype from the image, alignment 2^14.
        const e = fat[8 + 20 * i ..][0..20];
        try std.testing.expectEqual(std.mem.readInt(u32, thin[8..12], .little), std.mem.readInt(u32, e[4..8], .big));
        try std.testing.expectEqual(@as(u32, macho_fat.align_log2), std.mem.readInt(u32, e[16..20], .big));
    }
    // The first slice starts at 2^14, the second at the next multiple, and
    // the file ends with the last slice; the gaps are zero bytes.
    try std.testing.expectEqual(@as(u64, 1 << 14), list[0].offset);
    try std.testing.expectEqual(std.mem.alignForward(u64, list[0].offset + list[0].size, 1 << 14), list[1].offset);
    try std.testing.expectEqual(@as(u64, fat.len), list[1].offset + list[1].size);
    for (fat[48..@intCast(list[0].offset)]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (fat[@intCast(list[0].offset + list[0].size)..@intCast(list[1].offset)]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fat.dylib", .data = fat });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "fat.dylib", a);
    defer a.free(path);
    if (try oracleArchs(a, path)) |archs| {
        defer a.free(archs);
        try std.testing.expectEqualStrings("x86_64 arm64", archs);
    }
}

test "macho_fat: refuses two slices of one arch" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    var diag: [256]u8 = @splat(0);
    try std.testing.expectError(error.WrongCpu, macho_fat.join(a, t.arm64, t.arm64, &diag));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diag, 0), "x86_64") != null);
    try std.testing.expectError(error.WrongCpu, macho_fat.join(a, t.x86_64, t.x86_64, null));
    // Swapped inputs: each is in the other's place.
    try std.testing.expectError(error.WrongCpu, macho_fat.join(a, t.x86_64, t.arm64, null));
}

test "macho_fat: refuses a fat input" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    const fat = try macho_fat.join(a, t.arm64, t.x86_64, null);
    defer a.free(fat);
    var diag: [256]u8 = @splat(0);
    try std.testing.expectError(error.NotThin, macho_fat.join(a, fat, t.x86_64, &diag));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diag, 0), "fat") != null);
    try std.testing.expectError(error.NotThin, macho_fat.join(a, t.arm64, fat, null));
    // An incomplete or foreign input is refused with the reader's error.
    try std.testing.expectError(error.Truncated, macho_fat.join(a, t.arm64[0 .. t.arm64.len - 1], t.x86_64, null));
    try std.testing.expectError(error.NotMachO, macho_fat.join(a, t.arm64, "not a dylib", null));
}

test "macho_fat: deterministic" {
    const a = std.testing.allocator;
    const t = try Thin.read(a);
    defer t.deinit(a);
    const one = try macho_fat.join(a, t.arm64, t.x86_64, null);
    defer a.free(one);
    // Fresh copies of the inputs, so no state is shared between the runs.
    const arm = try a.dupe(u8, t.arm64);
    defer a.free(arm);
    const x86 = try a.dupe(u8, t.x86_64);
    defer a.free(x86);
    const two = try macho_fat.join(a, arm, x86, null);
    defer a.free(two);
    try std.testing.expectEqualSlices(u8, one, two);
    // The header names nothing but the inputs: same CPU entries, offsets
    // and sizes as computed from the input lengths.
    const x86_off: u64 = 1 << 14;
    const arm_off = std.mem.alignForward(u64, x86_off + t.x86_64.len, 1 << 14);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, one[4..8], .big));
    try std.testing.expectEqual(@as(u32, std.macho.CPU_TYPE_X86_64), std.mem.readInt(u32, one[8..12], .big));
    try std.testing.expectEqual(@as(u32, @intCast(x86_off)), std.mem.readInt(u32, one[16..20], .big));
    try std.testing.expectEqual(@as(u32, std.macho.CPU_TYPE_ARM64), std.mem.readInt(u32, one[28..32], .big));
    try std.testing.expectEqual(@as(u32, @intCast(arm_off)), std.mem.readInt(u32, one[36..40], .big));
}
