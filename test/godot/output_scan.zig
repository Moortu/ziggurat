//! The output rules shared by the Godot runners (`clean_exit_runner.zig` and
//! `test/host/runner.zig`): test markers and Godot's exit-time reports.
const std = @import("std");

/// Adds a problem when a test failed or the run did not reach `ZTEST DONE`.
pub fn checkTestMarkers(arena: std.mem.Allocator, out: []const u8, problems: *std.ArrayList([]const u8)) !void {
    if (std.mem.indexOf(u8, out, "ZTEST FAIL") != null) try problems.append(arena, "a test failed");
    if (std.mem.indexOf(u8, out, "ZTEST DONE") == null) try problems.append(arena, "the test run did not finish");
}

/// Adds one problem per Godot leak or crash report found in `out`.
pub fn checkReports(arena: std.mem.Allocator, out: []const u8, problems: *std.ArrayList([]const u8)) !void {
    if (std.mem.indexOf(u8, out, "ObjectDB instance was leaked") != null or
        std.mem.indexOf(u8, out, "ObjectDB instances were leaked") != null)
        try problems.append(arena, "ObjectDB instances leaked");
    // Godot's exit-time reports; the sources are in the Stage 2 report.
    for ([_][]const u8{
        "Unreferenced static string", // core/string/string_name.cpp:118
        "Orphan StringName:", // core/string/string_name.cpp:98, --verbose only
        "RID allocations of type", // core/templates/rid_owner.h:430
        "resources still in use at exit", // core/io/resource.cpp:817,822
        "Program crashed with signal", // platform/linuxbsd/crash_handler_linuxbsd.cpp
    }) |pattern| {
        if (std.mem.indexOf(u8, out, pattern) != null) try problems.append(arena, pattern);
    }
}

test "checkReports finds each report" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problems: std.ArrayList([]const u8) = .empty;
    try checkReports(arena, "WARNING: 1 ObjectDB instance was leaked at exit\nOrphan StringName: x\n", &problems);
    try std.testing.expectEqual(2, problems.items.len);
    problems.clearRetainingCapacity();
    try checkTestMarkers(arena, "ZTEST PASS a\nZTEST DONE\n", &problems);
    try std.testing.expectEqual(0, problems.items.len);
    try checkTestMarkers(arena, "ZTEST FAIL a: why\n", &problems);
    try std.testing.expectEqual(2, problems.items.len);
}
