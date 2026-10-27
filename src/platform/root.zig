//! L1 platform services: public surface.
const std = @import("std");
const build_options = @import("build_options");

pub const pins = @import("pins.zig");
pub const target_key = @import("target_key.zig");
pub const path = @import("path.zig");
pub const elf = @import("elf.zig");
pub const pe = @import("pe.zig");
pub const macho = @import("macho.zig");
pub const macho_fat = @import("macho_fat.zig");
pub const loader = @import("loader.zig");
pub const atomic_file = @import("atomic_file.zig");
pub const lock = @import("lock.zig");
pub const safe_open = @import("safe_open.zig");
pub const generation_store = @import("generation_store.zig");
pub const counting_allocator = @import("counting_allocator.zig");
pub const process = @import("process.zig");
pub const zig_locator = @import("zig_locator.zig");
pub const minisign = @import("minisign.zig");
pub const mirrors = @import("mirrors.zig");
pub const toolchain_install = @import("toolchain_install.zig");
pub const testing_support = @import("testing_support.zig");
/// Windows only: renames a file with delete access only, so a loaded DLL
/// can be renamed (`win32.moveFile`).
pub const moveFile = @import("win32.zig").moveFile;

test {
    std.testing.refAllDecls(path);
    std.testing.refAllDecls(elf);
    std.testing.refAllDecls(pe);
    _ = @import("pe_test.zig");
    std.testing.refAllDecls(macho);
    _ = @import("macho_test.zig");
    std.testing.refAllDecls(macho_fat);
    _ = @import("macho_fat_test.zig");
    std.testing.refAllDecls(loader);
    std.testing.refAllDecls(atomic_file);
    std.testing.refAllDecls(lock);
    std.testing.refAllDecls(safe_open);
    std.testing.refAllDecls(generation_store);
    std.testing.refAllDecls(counting_allocator);
    std.testing.refAllDecls(process);
    std.testing.refAllDecls(zig_locator);
    std.testing.refAllDecls(pins);
    std.testing.refAllDecls(target_key);
    std.testing.refAllDecls(minisign);
    std.testing.refAllDecls(mirrors);
    std.testing.refAllDecls(toolchain_install);
}

test "pins" {
    try std.testing.expectEqualStrings("0.17.0", pins.zig_version);
}

test "integration: zig_exe exists" {
    try testing_support.requireIntegration();
    try std.testing.expect(build_options.zig_exe.len != 0);
    try std.Io.Dir.cwd().access(std.testing.io, build_options.zig_exe, .{});
}
