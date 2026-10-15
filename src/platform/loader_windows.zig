//! Windows loader stub. Real loading is stage 7 work.
const std = @import("std");
const path = @import("path.zig");
const elf = @import("elf.zig");

pub const LoadError = error{ LoadFailed, Unsupported } || elf.ElfError;

pub const Library = struct {
    handle: *anyopaque,
};

pub fn open(a: std.mem.Allocator, io: std.Io, p: path.OsPath, diag: *[256]u8) LoadError!Library {
    _ = a;
    _ = io;
    _ = p;
    @memset(diag, 0);
    const msg = "The Windows loader is not implemented yet (stage 7).";
    @memcpy(diag[0..msg.len], msg);
    return error.Unsupported;
}

pub fn lookup(lib: Library, comptime T: type, name: [:0]const u8) ?T {
    _ = lib;
    _ = name;
    return null;
}

pub fn close(lib: Library) void {
    _ = lib;
}

test "windows loader is unsupported" {
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Unsupported, open(std.testing.allocator, std.testing.io, path.OsPath.fromTrusted("x.dll"), &diag));
    try std.testing.expectEqualStrings("The Windows loader is not implemented yet (stage 7).", elf.diagText(&diag));
}
