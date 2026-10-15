//! Helpers shared by tests in this layer. Only test code uses this file.
const std = @import("std");
const build_options = @import("build_options");
const path = @import("path.zig");

/// Call first in every `integration:` test. Skips the test when the build
/// runs without integration tests (`zig build test-unit`).
pub fn requireIntegration() error{SkipZigTest}!void {
    if (!build_options.run_integration) return error.SkipZigTest;
}

const answer_source = "export fn answer() callconv(.c) i32 { return 42; }\n";

/// Builds a shared library that exports `answer() i32` (returns 42) into the
/// directory of `tmp`, by running the real Zig compiler (`build_options.zig_exe`).
/// Returns the absolute path of the library; the caller frees `.bytes`.
pub fn buildAnswerLib(a: std.mem.Allocator, tmp: std.testing.TmpDir) !path.OsPath {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "answer.zig", .data = answer_source });
    const base_bytes = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base_bytes);
    const lib = try path.join(a, path.OsPath.fromTrusted(base_bytes), &.{"libanswer.so"});
    errdefer a.free(lib.bytes);
    const emit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{lib.bytes});
    defer a.free(emit);
    const result = try std.process.run(a, io, .{
        .argv = &.{ build_options.zig_exe, "build-lib", "-dynamic", "-O", "Debug", emit, "answer.zig" },
        .cwd = .{ .dir = tmp.dir },
    });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("zig build-lib failed: {s}\n", .{result.stderr});
        return error.BuildLibFailed;
    }
    return lib;
}
