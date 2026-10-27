//! The universal macOS editor library (`bin/libziggurat_host.dylib`), as
//! build.zig makes it: the host built for aarch64-macos.11.0 and
//! x86_64-macos.11.0 and joined by tools/macho_fat.zig. It is checked with
//! our Mach-O reader only (no Mac runs it); `rcodesign` is an optional
//! oracle for the arm64 signature and is skipped when it is not on PATH.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("macos_host_options");
const macho = @import("macho");
const Allocator = std.mem.Allocator;

/// The line the host logs once when it starts on macOS (plan, Global
/// Constraints).
const experimental_line = "Ziggurat on macOS is experimental and has not been tested on a Mac.";

fn hasName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

test "host dylib: universal, minos 11.0, exports _ziggurat_host_init, arm64 slice signed" {
    const a = std.testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, options.macos_editor_lib, a, .unlimited);
    defer a.free(bytes);

    try macho.checkComplete(bytes);
    const list = try macho.slices(a, bytes);
    defer a.free(list);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqual(macho.Cpu.x86_64, list[0].cpu);
    try std.testing.expectEqual(macho.Cpu.arm64, list[1].cpu);

    for (list) |s| {
        try std.testing.expectEqual(@as(u64, 0), s.offset % (1 << 14));
        const slice = bytes[@intCast(s.offset)..][0..@intCast(s.size)];
        const v = macho.minOs(slice) orelse return error.NoMinOs;
        try std.testing.expectEqual(std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 }, v);

        const ex = try macho.exports(a, slice);
        defer macho.freeList(a, ex);
        try std.testing.expect(hasName(ex, "_ziggurat_host_init"));
        // What a Zig 0.17 dylib exports besides the entry point; the
        // editor library may export these (the export output check of
        // the game library is stricter).
        for (ex) |name| {
            if (std.mem.eql(u8, name, "_ziggurat_host_init")) continue;
            if (std.mem.eql(u8, name, "__mh_dylib_header")) continue;
            if (std.mem.eql(u8, name, "___dso_handle")) continue;
            std.debug.print("unexpected export of the {t} slice: {s}\n", .{ s.cpu, name });
            return error.UnexpectedExport;
        }

        // The experimental line is in the library.
        try std.testing.expect(std.mem.indexOf(u8, slice, experimental_line) != null);
    }

    // Zig's linker signs the arm64 slice ad hoc and leaves x86_64 unsigned.
    const x86 = bytes[@intCast(list[0].offset)..][0..@intCast(list[0].size)];
    const arm = bytes[@intCast(list[1].offset)..][0..@intCast(list[1].size)];
    const sig = macho.codeSignature(arm) orelse return error.NoSignature;
    try std.testing.expect(sig.size > 0);
    try std.testing.expect(macho.codeSignature(x86) == null);

    if (try oracleSignature(a, options.macos_editor_lib)) |info| {
        defer a.free(info);
        // rcodesign prints one entry per slice (x86_64, then arm64): one
        // ad-hoc code directory, made by the linker, and one "signature:
        // null". (`rcodesign verify` is no oracle: it reports ad-hoc
        // signatures as problems.)
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, info, "CodeSignatureFlags(ADHOC | LINKER_SIGNED)"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, info, " signature: null"));
        const x86_entry = std.mem.indexOf(u8, info, "sub_path: macho-index:0") orelse return error.OracleFailed;
        const arm_entry = std.mem.indexOf(u8, info, "sub_path: macho-index:1") orelse return error.OracleFailed;
        const unsigned = std.mem.indexOf(u8, info, " signature: null") orelse return error.OracleFailed;
        try std.testing.expect(x86_entry < unsigned and unsigned < arm_entry);
    }
}

/// `rcodesign print-signature-info <file>`, or null when it is missing.
fn oracleSignature(a: Allocator, file: []const u8) !?[]u8 {
    if (builtin.os.tag != .linux) return null;
    const result = std.process.run(a, std.testing.io, .{
        .argv = &.{ "rcodesign", "print-signature-info", file },
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer a.free(result.stderr);
    errdefer a.free(result.stdout);
    if (!result.term.success()) {
        std.debug.print("rcodesign failed:\n{s}\n", .{result.stderr});
        return error.OracleFailed;
    }
    return result.stdout;
}
