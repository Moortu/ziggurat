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

/// The mode for `phase` on `target`. `override` (from the editor settings)
/// replaces the table in every phase. Optimize is `.Debug` unless overridden.
///
/// - x86_64 Linux: session start is self-hosted and non-incremental, warm is
///   self-hosted and incremental, the debug build is LLVM and non-incremental
///   (incremental debug info is broken).
/// - Every other target (Windows, macOS, and also aarch64 Linux and other
///   Linux CPUs, which are unmeasured): LLVM, non-incremental, until the
///   self-hosted backend and incremental mode are verified there. The
///   override is available for trying them.
pub fn policy(target: std.Target, phase: Phase, override: ?BuildMode) BuildMode {
    if (override) |o| return o;
    const self_hosted = target.cpu.arch == .x86_64 and target.os.tag == .linux;
    if (!self_hosted) return .{ .incremental = false, .use_llvm = true, .optimize = .Debug };
    return switch (phase) {
        .session_start => .{ .incremental = false, .use_llvm = false, .optimize = .Debug },
        .warm => .{ .incremental = true, .use_llvm = false, .optimize = .Debug },
        .debug_build => .{ .incremental = false, .use_llvm = true, .optimize = .Debug },
    };
}

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
    for ([_]Phase{ .session_start, .warm, .debug_build }) |phase| try expectMode(forced, policy(linux, phase, forced));
}
