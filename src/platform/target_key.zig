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

/// The export output folder (`.godot/ziggurat/export/<it>/`) of a Godot
/// export, or null when Ziggurat does not export to it. `os_name` is the
/// export platform's `get_os_name()` (`"Linux"`, `"Windows"`, `"macOS"`;
/// Godot 4.7.2 `platform/*/export/`), and `arch` the preset's
/// `binary_format/architecture` option. Neither comes from the export's
/// feature list, which also holds the preset's custom features: a custom
/// feature `macos` on a Linux preset must not make it a macOS export.
///   - `"Linux"` or `"Windows"` with `x86_64`: `x86_64_linux`,
///     `x86_64_windows`;
///   - `"macOS"` with any arch: `universal_macos` (the universal library
///     is right for `universal`, `arm64` and `x86_64`).
pub fn exportKey(os_name: []const u8, arch: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, os_name, "macOS")) return universal_macos;
    if (!std.mem.eql(u8, arch, "x86_64")) return null;
    if (std.mem.eql(u8, os_name, "Linux")) return x86_64_linux;
    if (std.mem.eql(u8, os_name, "Windows")) return x86_64_windows;
    return null;
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

/// Both macOS keys. The editor library and the game library an export
/// writes are universal files (`universal_macos`); the export host archive
/// and the empty game library are per arch.
const macos_files: Files = .{
    .editor_lib = "libziggurat_host.dylib",
    .host_archive = "libziggurat_host_export.a",
    .game_empty = "libziggurat_game_empty.dylib",
    .game_lib = "libziggurat_game.dylib",
};

/// The folder name of the universal macOS files: the editor library and
/// the export output folder (plan decision "Target keys"). Not a target
/// key: no SDK or archive is built for it.
pub const universal_macos = "universal-macos";

/// The file names for `key`, or null for an unknown key.
pub fn files(key: []const u8) ?Files {
    if (std.mem.eql(u8, key, x86_64_linux)) return linux_files;
    if (std.mem.eql(u8, key, x86_64_windows)) return windows_files;
    if (std.mem.eql(u8, key, aarch64_macos) or std.mem.eql(u8, key, x86_64_macos)) return macos_files;
    return null;
}

/// The keys that are also export keys, Linux and Windows (`files` is non-null for each; macOS exports use `universal_macos`).
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

test "target_key: exportKey takes the platform from the export platform" {
    try std.testing.expectEqualStrings(x86_64_linux, exportKey("Linux", "x86_64").?);
    try std.testing.expectEqualStrings(x86_64_windows, exportKey("Windows", "x86_64").?);
    for ([_][]const u8{ "universal", "arm64", "x86_64" }) |arch| {
        try std.testing.expectEqualStrings(universal_macos, exportKey("macOS", arch).?);
    }
    try std.testing.expect(exportKey("Linux", "arm64") == null);
    try std.testing.expect(exportKey("Windows", "x86_32") == null);
    try std.testing.expect(exportKey("Windows", "") == null);
    try std.testing.expect(exportKey("iOS", "arm64") == null);
    try std.testing.expect(exportKey("Web", "wasm32") == null);
    // Godot compares OS names exactly; these are not platforms.
    try std.testing.expect(exportKey("linux", "x86_64") == null);
    try std.testing.expect(exportKey("macos", "universal") == null);
    try std.testing.expect(exportKey("", "x86_64") == null);
}

test "target_key: files and keys" {
    try std.testing.expectEqualStrings("libziggurat_host_export.a", files("x86_64-linux").?.host_archive);
    try std.testing.expectEqualStrings("ziggurat_host.dll", files("x86_64-windows").?.editor_lib);
    try std.testing.expectEqualStrings("ziggurat_game.dll", files("x86_64-windows").?.game_lib);
    try std.testing.expectEqualStrings("libziggurat_host_export.a", files("aarch64-macos").?.host_archive);
    try std.testing.expectEqualStrings("libziggurat_game_empty.dylib", files("x86_64-macos").?.game_empty);
    try std.testing.expectEqualStrings("libziggurat_game.dylib", files("x86_64-macos").?.game_lib);
    try std.testing.expect(files(universal_macos) == null);
    try std.testing.expect(files("linux.x86_64") == null);
    for (packaged) |k| try std.testing.expect(files(k) != null);
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..12], "x86_64-linux");
    try std.testing.expectEqual(@as([*]const u8, x86_64_linux.ptr), canonical(buf[0..12]).?.ptr);
    try std.testing.expect(canonical("x86_64") == null);
}
