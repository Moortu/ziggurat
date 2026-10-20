//! The output rules shared by the Godot runners (`clean_exit_runner.zig` and
//! `test/host/runner.zig`): test markers and Godot's exit-time reports.
const std = @import("std");

/// Adds a problem when a test failed or the run did not reach `ZTEST DONE`.
pub fn checkTestMarkers(arena: std.mem.Allocator, out: []const u8, problems: *std.ArrayList([]const u8)) !void {
    if (std.mem.indexOf(u8, out, "ZTEST FAIL") != null) try problems.append(arena, "a test failed");
    if (std.mem.indexOf(u8, out, "ZTEST DONE") == null) try problems.append(arena, "the test run did not finish");
}

/// A StringName that Godot itself (with no extension) still holds at exit,
/// with its number of non-static references then.
pub const StockOrphan = struct { name: []const u8, non_static: u32 };

/// Adds one problem per Godot leak or crash report found in `out`. An
/// "Orphan StringName" line is a problem only when the name's non-static
/// references (total minus static) exceed its count in `stock` (0 for a
/// name not listed).
pub fn checkReports(arena: std.mem.Allocator, out: []const u8, stock: []const StockOrphan, problems: *std.ArrayList([]const u8)) !void {
    if (std.mem.indexOf(u8, out, "ObjectDB instance was leaked") != null or
        std.mem.indexOf(u8, out, "ObjectDB instances were leaked") != null)
        try problems.append(arena, "ObjectDB instances leaked");
    // Godot's exit-time reports; the sources are in the Stage 2 report.
    for ([_][]const u8{
        "Unreferenced static string", // core/string/string_name.cpp:118
        "RID allocations of type", // core/templates/rid_owner.h:430
        "resources still in use at exit", // core/io/resource.cpp:817,822
        "Program crashed with signal", // platform/linuxbsd/crash_handler_linuxbsd.cpp
    }) |pattern| {
        if (std.mem.indexOf(u8, out, pattern) != null) try problems.append(arena, pattern);
    }
    try checkOrphans(arena, out, stock, problems);
}

/// Godot's StringName report (core/string/string_name.cpp:93-98, --verbose
/// only): at exit it prints `Orphan StringName: <name> (static: S, total: T)`
/// for every name whose static count differs from its reference count.
/// Static references (`StringName(..., true)`, such as gdzig's comptime
/// names) are expected to stay: they are never released by design. Only
/// the T - S ordinary references are a leak, beyond what Godot's own run
/// leaves (`stock`). A line that does not parse is a problem.
fn checkOrphans(arena: std.mem.Allocator, out: []const u8, stock: []const StockOrphan, problems: *std.ArrayList([]const u8)) !void {
    const prefix = "Orphan StringName: ";
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const at = std.mem.indexOf(u8, line, prefix) orelse continue;
        const rest = line[at + prefix.len ..];
        if (!orphanAllowed(rest, stock)) try problems.append(arena, try std.fmt.allocPrint(arena, "Orphan StringName: {s}", .{rest}));
    }
}

/// Whether `<name> (static: S, total: T)` stays within `stock`.
fn orphanAllowed(rest: []const u8, stock: []const StockOrphan) bool {
    const open = " (static: ";
    const mid = ", total: ";
    const i = std.mem.lastIndexOf(u8, rest, open) orelse return false;
    const name = rest[0..i];
    const counts = rest[i + open.len ..];
    if (counts.len == 0 or counts[counts.len - 1] != ')') return false;
    const j = std.mem.indexOf(u8, counts, mid) orelse return false;
    const static_n = std.fmt.parseInt(u64, counts[0..j], 10) catch return false;
    const total = std.fmt.parseInt(u64, counts[j + mid.len .. counts.len - 1], 10) catch return false;
    if (static_n > total) return false;
    var allowed: u64 = 0;
    for (stock) |s| {
        if (std.mem.eql(u8, s.name, name)) allowed = s.non_static;
    }
    return total - static_n <= allowed;
}

test "checkReports finds each report" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var problems: std.ArrayList([]const u8) = .empty;
    try checkReports(arena, "WARNING: 1 ObjectDB instance was leaked at exit\nOrphan StringName: x\n", &.{}, &problems);
    try std.testing.expectEqual(2, problems.items.len);
    problems.clearRetainingCapacity();
    try checkTestMarkers(arena, "ZTEST PASS a\nZTEST DONE\n", &problems);
    try std.testing.expectEqual(0, problems.items.len);
    try checkTestMarkers(arena, "ZTEST FAIL a: why\n", &problems);
    try std.testing.expectEqual(2, problems.items.len);
}

test "orphan StringNames fail only on non-static references above stock" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const editor: []const StockOrphan = &.{.{ .name = "Node", .non_static = 1 }};
    var problems: std.ArrayList([]const u8) = .empty;
    // Godot's own editor line, and the same with module static references.
    try checkReports(arena, "Orphan StringName: Node (static: 3, total: 4)\nOrphan StringName: Node (static: 4, total: 5)\r\n", editor, &problems);
    try std.testing.expectEqual(0, problems.items.len);
    // One more ordinary reference than stock.
    try checkReports(arena, "Orphan StringName: Node (static: 3, total: 5)\n", editor, &problems);
    try std.testing.expectEqual(1, problems.items.len);
    try std.testing.expectEqualStrings("Orphan StringName: Node (static: 3, total: 5)", problems.items[0]);
    problems.clearRetainingCapacity();
    // Any non-static reference of a name without stock, in any mode.
    try checkReports(arena, "Orphan StringName: Node (static: 3, total: 4)\n", &.{}, &problems);
    try checkReports(arena, "Orphan StringName: speed (static: 0, total: 1)\n", editor, &problems);
    try std.testing.expectEqual(2, problems.items.len);
    problems.clearRetainingCapacity();
    // Names with spaces or parentheses; lines that do not parse.
    try checkReports(arena, "Orphan StringName: a (b) (static: 2, total: 2)\n", &.{}, &problems);
    try std.testing.expectEqual(0, problems.items.len);
    for ([_][]const u8{ "x", "Node (static: 4, total: 3)", "Node (static: a, total: 4)", "Node (static: 1, total: 4" }) |bad| {
        problems.clearRetainingCapacity();
        const line = try std.fmt.allocPrint(arena, "Orphan StringName: {s}\n", .{bad});
        try checkReports(arena, line, editor, &problems);
        try std.testing.expectEqual(1, problems.items.len);
    }
}
