//! Backend policy (L2): which compiler mode a build uses, keyed by target and
//! build phase (spec section 5, "Backend policy").
const std = @import("std");
const workspace = @import("workspace.zig");
const BuildMode = workspace.BuildMode;

pub const Phase = enum {
    /// The first build of an editor session, and every build that does not
    /// go through a warm incremental session.
    session_start,
    /// The background incremental compiler server.
    warm,
    /// The separate build for attaching a debugger.
    debug_build,
};

/// The mode for `phase` on `target`. `override` (the editor setting
/// `ziggurat/build/backend`, `SettingReader`) replaces the table in the
/// `session_start` and `warm` phases; the debug build ignores it (it must
/// stay LLVM, non-incremental and Debug for a debugger to read it).
/// Optimize is `.Debug` unless overridden.
///
/// - x86_64 Linux: session start is self-hosted and non-incremental, warm is
///   self-hosted and incremental, the debug build is LLVM and non-incremental
///   (incremental debug info is broken).
/// - Every other target (Windows, macOS, and also aarch64 Linux and other
///   Linux CPUs, which are unmeasured): LLVM, non-incremental, until the
///   self-hosted backend and incremental mode are verified there. The
///   override is available for trying them.
pub fn policy(target: std.Target, phase: Phase, override: ?BuildMode) BuildMode {
    if (phase != .debug_build) if (override) |o| return o;
    const self_hosted = target.cpu.arch == .x86_64 and target.os.tag == .linux;
    if (!self_hosted) return .{ .incremental = false, .use_llvm = true, .optimize = .Debug };
    return switch (phase) {
        .session_start => .{ .incremental = false, .use_llvm = false, .optimize = .Debug },
        .warm => .{ .incremental = true, .use_llvm = false, .optimize = .Debug },
        .debug_build => .{ .incremental = false, .use_llvm = true, .optimize = .Debug },
    };
}

/// The values of the editor setting `ziggurat/build/backend`.
pub const Setting = enum {
    /// The policy table (the default).
    auto,
    /// LLVM, non-incremental.
    llvm,
    /// The self-hosted backend, non-incremental.
    self_hosted,
    /// The self-hosted backend, incremental.
    self_hosted_incremental,

    /// The override this value gives `policy`; null for `auto`.
    pub fn override(s: Setting) ?BuildMode {
        return switch (s) {
            .auto => null,
            .llvm => .{ .incremental = false, .use_llvm = true, .optimize = .Debug },
            .self_hosted => .{ .incremental = false, .use_llvm = false, .optimize = .Debug },
            .self_hosted_incremental => .{ .incremental = true, .use_llvm = false, .optimize = .Debug },
        };
    }
};

/// The setting's values for the inspector (an enum hint string).
pub const setting_values = "auto,llvm,self_hosted,self_hosted_incremental";

/// What `SettingReader.read` says the first time the setting holds a value
/// that is not one of `Setting`'s.
pub const unknown_setting_warning = "Ziggurat: the editor setting ziggurat/build/backend has an unknown value; using auto.";

/// Turns the text of the editor setting `ziggurat/build/backend` into a
/// `policy` override. Keep one per session: an unknown value is read as
/// `auto`, and only the first one gives a warning.
pub const SettingReader = struct {
    warned: bool = false,

    pub const Read = struct {
        override: ?BuildMode,
        /// `unknown_setting_warning` once per reader, else null.
        warning: ?[]const u8 = null,
    };

    /// `text` is the setting's value; an empty one (unset) is `auto`.
    pub fn read(r: *SettingReader, text: []const u8) Read {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return .{ .override = null };
        if (std.meta.stringToEnum(Setting, t)) |s| return .{ .override = s.override() };
        if (r.warned) return .{ .override = null };
        r.warned = true;
        return .{ .override = null, .warning = unknown_setting_warning };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn resolve(triple: []const u8) !std.Target {
    const query = try std.Target.Query.parse(.{ .arch_os_abi = triple });
    return std.zig.system.resolveTargetQuery(testing.io, query);
}

fn expectMode(want: BuildMode, got: BuildMode) !void {
    try testing.expectEqual(want.incremental, got.incremental);
    try testing.expectEqual(want.use_llvm, got.use_llvm);
    try testing.expectEqual(want.optimize, got.optimize);
}

test "policy table" {
    const linux = try resolve("x86_64-linux-gnu");
    try expectMode(.{ .incremental = false, .use_llvm = false, .optimize = .Debug }, policy(linux, .session_start, null));
    try expectMode(.{ .incremental = true, .use_llvm = false, .optimize = .Debug }, policy(linux, .warm, null));
    try expectMode(.{ .incremental = false, .use_llvm = true, .optimize = .Debug }, policy(linux, .debug_build, null));

    const llvm: BuildMode = .{ .incremental = false, .use_llvm = true, .optimize = .Debug };
    for ([_][]const u8{ "x86_64-windows-gnu", "aarch64-macos", "x86_64-macos", "aarch64-linux-gnu" }) |triple| {
        const t = try resolve(triple);
        for ([_]Phase{ .session_start, .warm, .debug_build }) |phase| try expectMode(llvm, policy(t, phase, null));
    }

    const forced: BuildMode = .{ .incremental = false, .use_llvm = true, .optimize = .ReleaseSafe };
    for ([_]Phase{ .session_start, .warm }) |phase| try expectMode(forced, policy(linux, phase, forced));
}

test "policy: override never applies to debug_build" {
    const forced: BuildMode = .{ .incremental = true, .use_llvm = false, .optimize = .ReleaseFast };
    const debug: BuildMode = .{ .incremental = false, .use_llvm = true, .optimize = .Debug };
    for ([_][]const u8{ "x86_64-linux-gnu", "x86_64-windows-gnu", "aarch64-macos", "aarch64-linux-gnu" }) |triple| {
        const t = try resolve(triple);
        try expectMode(debug, policy(t, .debug_build, forced));
        try expectMode(debug, policy(t, .debug_build, null));
        try expectMode(forced, policy(t, .session_start, forced));
        try expectMode(forced, policy(t, .warm, forced));
    }
}

test "backend setting: unknown value reads as auto" {
    var r: SettingReader = .{};
    const first = r.read("fastest");
    try testing.expect(first.override == null);
    try testing.expectEqualStrings(unknown_setting_warning, first.warning.?);
    try testing.expectEqualStrings("Ziggurat: the editor setting ziggurat/build/backend has an unknown value; using auto.", first.warning.?);
    // Once per session.
    const again = r.read("LLVM ");
    try testing.expect(again.override == null);
    try testing.expect(again.warning == null);

    var fresh: SettingReader = .{};
    for ([_][]const u8{ "", "auto", " auto\n" }) |text| {
        const got = fresh.read(text);
        try testing.expect(got.override == null);
        try testing.expect(got.warning == null);
    }
    try expectMode(.{ .incremental = false, .use_llvm = true, .optimize = .Debug }, fresh.read("llvm").override.?);
    try expectMode(.{ .incremental = false, .use_llvm = false, .optimize = .Debug }, fresh.read("self_hosted").override.?);
    try expectMode(.{ .incremental = true, .use_llvm = false, .optimize = .Debug }, fresh.read("self_hosted_incremental").override.?);
    try testing.expect(!fresh.warned);
}
