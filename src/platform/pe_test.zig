//! Tests of `pe.zig` against a real DLL (`test/fixtures/pe/answer_dll.zig`,
//! built by build.zig as `build_options.answer_dll`). They live here so that
//! `pe.zig` itself imports only std.
const std = @import("std");
const build_options = @import("build_options");
const pe = @import("pe.zig");

fn readFixture(a: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, build_options.answer_dll, a, .unlimited);
}

fn hasImport(list: []const pe.Import, dll: []const u8, name: []const u8) bool {
    for (list) |i| {
        if (std.ascii.eqlIgnoreCase(i.dll, dll) and std.mem.eql(u8, i.name, name)) return true;
    }
    return false;
}

fn hasName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

test "truncated DLL refused" {
    const a = std.testing.allocator;
    const bytes = try readFixture(a);
    defer a.free(bytes);
    try pe.checkComplete(bytes);
    try std.testing.expectError(error.Truncated, pe.checkComplete(bytes[0 .. bytes.len / 2]));
    try std.testing.expectError(error.Truncated, pe.checkComplete(bytes[0 .. bytes.len - 1]));
    try std.testing.expectError(error.Truncated, pe.checkComplete(bytes[0..0x3e]));
    try std.testing.expectError(error.Truncated, pe.checkComplete(bytes[0..1]));
    try std.testing.expectError(error.Truncated, pe.checkComplete(bytes[0..0]));
    var elf_like: [71]u8 = @splat(0);
    @memcpy(elf_like[0..7], "\x7fELF\x02\x01\x01");
    try std.testing.expectError(error.NotPe, pe.checkComplete(&elf_like));
}

test "a broken PE signature or header is refused" {
    const a = std.testing.allocator;
    const bytes = try readFixture(a);
    defer a.free(bytes);
    const lfanew = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    {
        const copy = try a.dupe(u8, bytes);
        defer a.free(copy);
        copy[lfanew] = 'X';
        try std.testing.expectError(error.NotPe, pe.checkComplete(copy));
    }
    {
        // Optional header magic.
        const copy = try a.dupe(u8, bytes);
        defer a.free(copy);
        copy[lfanew + 24] = 0x55;
        try std.testing.expectError(error.BadHeader, pe.checkComplete(copy));
    }
}

test "exports and imports of a small DLL" {
    const a = std.testing.allocator;
    const bytes = try readFixture(a);
    defer a.free(bytes);

    const ex = try pe.exports(a, bytes);
    defer pe.freeExports(a, ex);
    try std.testing.expect(hasName(ex, "answer"));
    try std.testing.expect(hasName(ex, "answer_pid"));

    const im = try pe.imports(a, bytes);
    defer pe.freeImports(a, im);
    try std.testing.expect(hasImport(im, "kernel32.dll", "GetCurrentProcessId"));
    for (im) |i| {
        try std.testing.expect(!std.mem.startsWith(u8, i.name, "LoadLibrary"));
        try std.testing.expect(!std.mem.eql(u8, i.name, "GetProcAddress"));
    }
}

test "an import by ordinal is named #<ordinal>" {
    const a = std.testing.allocator;
    const bytes = try readFixture(a);
    defer a.free(bytes);
    const copy = try a.dupe(u8, bytes);
    defer a.free(copy);

    // Find the hint/name entry of GetCurrentProcessId and point every thunk
    // that names it at ordinal 7 instead.
    const at = std.mem.indexOf(u8, copy, "GetCurrentProcessId\x00") orelse return error.NoName;
    const img = try pe.Image.parse(copy);
    const rva = img.rvaOf(at - 2) orelse return error.NoRva;
    var changed: usize = 0;
    var off: usize = 0;
    while (off + 8 <= copy.len) : (off += 8) {
        if (std.mem.readInt(u64, copy[off..][0..8], .little) == rva) {
            std.mem.writeInt(u64, copy[off..][0..8], (1 << 63) | 7, .little);
            changed += 1;
        }
    }
    try std.testing.expect(changed >= 1);

    const im = try pe.imports(a, copy);
    defer pe.freeImports(a, im);
    try std.testing.expect(hasImport(im, "kernel32.dll", "#7"));
    try std.testing.expect(!hasImport(im, "kernel32.dll", "GetCurrentProcessId"));
}

/// Calls every reader on `bytes`; any error is fine, a panic or leak is not.
fn readAll(a: std.mem.Allocator, bytes: []const u8) void {
    pe.checkComplete(bytes) catch {};
    if (pe.exports(a, bytes)) |ex| pe.freeExports(a, ex) else |_| {}
    if (pe.imports(a, bytes)) |im| pe.freeImports(a, im) else |_| {}
}

test "malformed input never panics" {
    const a = std.testing.allocator;
    const bytes = try readFixture(a);
    defer a.free(bytes);

    // Every truncation in the headers, then every 61st byte.
    var len: usize = 0;
    while (len <= bytes.len) : (len += if (len < 2048) 1 else 61) readAll(a, bytes[0..len]);

    // Random bit flips, one to four at a time, from a fixed seed.
    const copy = try a.dupe(u8, bytes);
    defer a.free(copy);
    var prng: std.Random.DefaultPrng = .init(0x7e57_c0de);
    const rnd = prng.random();
    for (0..4000) |_| {
        @memcpy(copy, bytes);
        const flips = rnd.intRangeAtMost(u8, 1, 4);
        for (0..flips) |_| {
            // Half of the flips go into the first 1 KiB (the headers).
            const limit = if (rnd.boolean()) @min(copy.len, 1024) else copy.len;
            const i = rnd.uintLessThan(usize, limit);
            copy[i] ^= @as(u8, 1) << rnd.int(u3);
        }
        readAll(a, copy);
    }

    // Whole fields set to extreme values.
    const lfanew = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    const fields = [_]usize{ 0x3c, lfanew + 6, lfanew + 20, lfanew + 24 + 108, lfanew + 24 + 112, lfanew + 24 + 120, lfanew + 24 + 124 };
    for (fields) |f| {
        for ([_]u32{ 0, 1, 0x7fff_ffff, 0xffff_ffff, 0xffff_fff0 }) |v| {
            @memcpy(copy, bytes);
            if (f + 4 <= copy.len) std.mem.writeInt(u32, copy[f..][0..4], v, .little);
            readAll(a, copy);
        }
    }
}
