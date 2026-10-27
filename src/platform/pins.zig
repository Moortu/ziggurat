//! Pinned versions. Single source of truth for the Zig version.
const std = @import("std");

pub const zig_version = "0.17.0";

/// The newest glibc symbol version an exported game's library may need: the
/// highest `GLIBC_` version the official Godot 4.7.2 `linux_release.x86_64`
/// export template needs (`readelf -V`), so the library runs wherever the
/// template runs.
pub const export_glibc = "2.28";

/// The target an exported game's library and the export host archive are
/// built for (baseline CPU).
pub const export_target = "x86_64-linux-gnu." ++ export_glibc;

/// The minimum macOS version of every shipped and exported Mach-O file
/// (its `minos`), on both architectures.
pub const macos_min = "11.0";

/// The targets of the macOS libraries, arm64 then x86_64: the order
/// `macho_fat.join` takes the thin dylibs in.
pub const macos_targets = [2][]const u8{ "aarch64-macos." ++ macos_min, "x86_64-macos." ++ macos_min };

/// The Zig Software Foundation's minisign public key, as published on
/// https://ziglang.org/download/. Every downloaded Zig archive must carry a
/// signature from this key.
pub const zig_minisign_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

/// A CPU and OS pair, as in the release file names (`zig-<arch>-<os>-<version>`).
pub const Target = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,

    pub fn of(t: std.Target) Target {
        return .{ .arch = t.cpu.arch, .os = t.os.tag };
    }
};

/// One official release archive: file name, exact size in bytes and SHA-256,
/// copied from https://ziglang.org/download/index.json. They are checked in
/// addition to the minisign signature.
pub const Archive = struct {
    name: []const u8,
    size: u64,
    sha256: [32]u8,
};

const Entry = struct {
    target: Target,
    archive: Archive,
    /// False for targets that are listed but not offered yet (Stage 7).
    active: bool,
};

fn entry(arch: std.Target.Cpu.Arch, os: std.Target.Os.Tag, name: []const u8, size: u64, comptime sha_hex: []const u8, active: bool) Entry {
    var sha: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sha, sha_hex) catch unreachable;
    return .{ .target = .{ .arch = arch, .os = os }, .archive = .{ .name = name, .size = size, .sha256 = sha }, .active = active };
}

const archives = [_]Entry{
    entry(.x86_64, .linux, "zig-x86_64-linux-0.17.0.tar.xz", 57332648, "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026", true),
    entry(.aarch64, .linux, "zig-aarch64-linux-0.17.0.tar.xz", 52877280, "9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8", false),
    entry(.x86_64, .windows, "zig-x86_64-windows-0.17.0.zip", 100268137, "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428", true),
    entry(.aarch64, .macos, "zig-aarch64-macos-0.17.0.tar.xz", 53985220, "b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a", false),
    entry(.x86_64, .macos, "zig-x86_64-macos-0.17.0.tar.xz", 59317572, "4f9a1c5269aa17ebda5e6d3c2b89d6cbf36f7d2b22a0306e9ab98f25f95529c6", false),
};

/// The pinned Zig release archive for `target`, or null when Ziggurat does
/// not offer a download for it (yet).
pub fn zig_archive(target: Target) ?Archive {
    for (archives) |e| {
        if (e.active and e.target.arch == target.arch and e.target.os == target.os) return e.archive;
    }
    return null;
}

test "pins: archives for x86_64-linux and x86_64-windows only" {
    const a = zig_archive(.{ .arch = .x86_64, .os = .linux }).?;
    try std.testing.expectEqualStrings("zig-x86_64-linux-0.17.0.tar.xz", a.name);
    try std.testing.expectEqual(@as(u64, 57332648), a.size);
    try std.testing.expectEqual(@as(u8, 0x1c), a.sha256[0]);
    try std.testing.expectEqual(@as(u8, 0x26), a.sha256[31]);
    // Offered since the real zip installed under Wine (Stage 7b Task 6).
    const w = zig_archive(.{ .arch = .x86_64, .os = .windows }).?;
    try std.testing.expectEqualStrings("zig-x86_64-windows-0.17.0.zip", w.name);
    try std.testing.expectEqual(@as(u64, 100268137), w.size);
    try std.testing.expectEqual(@as(u8, 0xb5), w.sha256[0]);
    try std.testing.expectEqual(@as(u8, 0x28), w.sha256[31]);
    try std.testing.expect(zig_archive(.{ .arch = .aarch64, .os = .macos }) == null);
    try std.testing.expect(zig_archive(.{ .arch = .x86_64, .os = .macos }) == null);
    try std.testing.expect(zig_archive(.{ .arch = .aarch64, .os = .linux }) == null);
    try std.testing.expect(zig_archive(.{ .arch = .riscv64, .os = .linux }) == null);
    // Every listed name has the pinned version.
    for (archives) |e| try std.testing.expect(std.mem.indexOf(u8, e.archive.name, "-" ++ zig_version ++ ".") != null);
}

test "pins: export target parses with the pinned glibc" {
    const q = try std.Target.Query.parse(.{ .arch_os_abi = export_target });
    try std.testing.expectEqual(std.Target.Cpu.Arch.x86_64, q.cpu_arch.?);
    try std.testing.expectEqual(std.Target.Os.Tag.linux, q.os_tag.?);
    try std.testing.expectEqual(std.Target.Abi.gnu, q.abi.?);
    try std.testing.expectEqual(std.SemanticVersion{ .major = 2, .minor = 28, .patch = 0 }, q.glibc_version.?);
}

test "pins: the macOS targets parse with the minimum version, arm64 first" {
    for (macos_targets, [_]std.Target.Cpu.Arch{ .aarch64, .x86_64 }) |triple, arch| {
        const q = try std.Target.Query.parse(.{ .arch_os_abi = triple });
        try std.testing.expectEqual(arch, q.cpu_arch.?);
        try std.testing.expectEqual(std.Target.Os.Tag.macos, q.os_tag.?);
        try std.testing.expectEqual(@as(usize, 11), q.os_version_min.?.semver.major);
        try std.testing.expectEqual(@as(usize, 0), q.os_version_min.?.semver.minor);
    }
}
