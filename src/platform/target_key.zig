//! Target keys: the names of the per-platform folders under the add-on's
//! `bin/` and `sdk/` and under `.godot/ziggurat/export/` (plan decision:
//! `x86_64-linux`, `x86_64-windows`, `aarch64-macos`, `x86_64-macos`).
//! Imports only std.
const std = @import("std");

pub const x86_64_linux = "x86_64-linux";
pub const x86_64_windows = "x86_64-windows";
pub const aarch64_macos = "aarch64-macos";
pub const x86_64_macos = "x86_64-macos";

/// Every key, in a fixed order.
pub const all = [_][]const u8{ x86_64_linux, x86_64_windows, aarch64_macos, x86_64_macos };

/// The key of a Zig target, or null for a platform Ziggurat does not ship.
pub fn fromTarget(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .linux => if (t.cpu.arch == .x86_64) x86_64_linux else null,
        .windows => if (t.cpu.arch == .x86_64) x86_64_windows else null,
        .macos => switch (t.cpu.arch) {
            .aarch64 => aarch64_macos,
            .x86_64 => x86_64_macos,
            else => null,
        },
        else => null,
    };
}

/// The key of a Godot export preset from its feature names, or null when
/// Ziggurat does not export to it: `linux` + `x86_64` and `windows` +
/// `x86_64`. macOS presets are mapped in 7c.
pub fn fromFeatures(features: []const []const u8) ?[]const u8 {
    if (!has(features, "x86_64")) return null;
    if (has(features, "linux")) return x86_64_linux;
    if (has(features, "windows")) return x86_64_windows;
    return null;
}

fn has(features: []const []const u8, name: []const u8) bool {
    for (features) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

/// The add-on's file names for one key.
pub const Files = struct {
    /// The editor library, in `addons/ziggurat/bin/`.
    editor_lib: []const u8,
    /// The export host archive, in `addons/ziggurat/bin/<key>/`.
    host_archive: []const u8,
    /// The game library of a project without Zig scripts, in
    /// `addons/ziggurat/bin/<key>/`.
    game_empty: []const u8,
    /// The game library an export writes, in
    /// `.godot/ziggurat/export/<key>/`; the `.gdextension`'s template
    /// keys name it.
    game_lib: []const u8,
};

const linux_files: Files = .{
    .editor_lib = "libziggurat_host.so",
    .host_archive = "libziggurat_host_export.a",
    .game_empty = "libziggurat_game_empty.so",
    .game_lib = "libziggurat_game.so",
};
const windows_files: Files = .{
    .editor_lib = "ziggurat_host.dll",
    .host_archive = "ziggurat_host_export.lib",
    .game_empty = "ziggurat_game_empty.dll",
    .game_lib = "ziggurat_game.dll",
};

/// The file names for `key`, or null for a key whose files are not
/// shipped yet (macOS: 7c) or an unknown one.
pub fn files(key: []const u8) ?Files {
    if (std.mem.eql(u8, key, x86_64_linux)) return linux_files;
    if (std.mem.eql(u8, key, x86_64_windows)) return windows_files;
    return null;
}

/// The keys the release package holds (`files` is non-null for each).
pub const packaged = [_][]const u8{ x86_64_linux, x86_64_windows };

/// `key` as one of the constants of this file (so it outlives the
/// caller's text), or null when it is not a key.
pub fn canonical(key: []const u8) ?[]const u8 {
    for (all) |k| if (std.mem.eql(u8, k, key)) return k;
    return null;
}

fn target(triple: []const u8) !std.Target {
    const q = try std.Target.Query.parse(.{ .arch_os_abi = triple });
    return std.zig.system.resolveTargetQuery(std.testing.io, q);
}

test "target_key: fromTarget" {
    try std.testing.expectEqualStrings("x86_64-linux", fromTarget(try target("x86_64-linux-gnu.2.28")).?);
    try std.testing.expectEqualStrings("x86_64-linux", fromTarget(try target("x86_64-linux-musl")).?);
    try std.testing.expectEqualStrings("x86_64-windows", fromTarget(try target("x86_64-windows-gnu")).?);
    try std.testing.expectEqualStrings("aarch64-macos", fromTarget(try target("aarch64-macos")).?);
    try std.testing.expectEqualStrings("x86_64-macos", fromTarget(try target("x86_64-macos")).?);
    try std.testing.expect(fromTarget(try target("aarch64-linux-gnu")) == null);
    try std.testing.expect(fromTarget(try target("aarch64-windows-gnu")) == null);
    try std.testing.expect(fromTarget(try target("x86-windows-gnu")) == null);
    try std.testing.expect(fromTarget(try target("x86_64-freebsd")) == null);
}

test "target_key: fromFeatures" {
    try std.testing.expectEqualStrings("x86_64-linux", fromFeatures(&.{ "pc", "linux", "x86_64", "template" }).?);
    try std.testing.expectEqualStrings("x86_64-windows", fromFeatures(&.{ "windows", "x86_64", "pc" }).?);
    try std.testing.expect(fromFeatures(&.{ "linux", "arm64" }) == null);
    try std.testing.expect(fromFeatures(&.{ "windows", "arm64" }) == null);
    try std.testing.expect(fromFeatures(&.{ "windows", "x86_32" }) == null);
    try std.testing.expect(fromFeatures(&.{ "macos", "x86_64", "universal" }) == null);
    try std.testing.expect(fromFeatures(&.{"x86_64"}) == null);
    try std.testing.expect(fromFeatures(&.{}) == null);
}

test "target_key: files and keys" {
    try std.testing.expectEqualStrings("libziggurat_host_export.a", files("x86_64-linux").?.host_archive);
    try std.testing.expectEqualStrings("ziggurat_host.dll", files("x86_64-windows").?.editor_lib);
    try std.testing.expectEqualStrings("ziggurat_game.dll", files("x86_64-windows").?.game_lib);
    try std.testing.expect(files("aarch64-macos") == null);
    try std.testing.expect(files("linux.x86_64") == null);
    for (packaged) |k| try std.testing.expect(files(k) != null);
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..12], "x86_64-linux");
    try std.testing.expectEqual(@as([*]const u8, x86_64_linux.ptr), canonical(buf[0..12]).?.ptr);
    try std.testing.expect(canonical("x86_64") == null);
}
