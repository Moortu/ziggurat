//! Runs Godot on a prepared host test project and decides pass or fail from
//! its output.
//!
//! Usage:
//!   runner <godot> <project dir> script <check.gd> <deadline s> [--expect <text>]...
//!   runner <godot> <project dir> editor <quit-after frames> <deadline s> [--expect <text>]...
//!   runner <godot> <project dir> game <scene> <deadline s> [--expect <text>]...
//!
//! Writes `<project>/.godot/extension_list.cfg` with every `.gdextension`
//! file of the project (Godot #111645), then runs
//! `godot --headless --verbose --path <project> --script <check.gd>` (or
//! `--editor --quit-after <frames>`, or the scene path for a game run of that
//! scene) with stdin from /dev/null and one
//! deadline for the whole run. The run fails when Godot times out or exits
//! non-zero, the output has no `ZTEST DONE` line, has a `ZTEST FAIL` line,
//! lacks an `--expect` text, has an `--expect-once` text other than exactly
//! once, has a `--reject` text, or has one of Godot's leak or crash reports
//! (`test/godot/output_scan.zig`). An `--allow-report` line is left out of
//! the report scan when an output line equals it exactly, for a known
//! engine leak a test cannot avoid (the reload stress test's mesh
//! previews); when the run already failed (a test marker or the exit
//! status), it matches with any count, because a run that stopped early
//! counts fewer events. Godot's output is printed only on failure, except
//! the lines that start with an `--echo` prefix, which are printed in every
//! case. `runner --print <dir> <name>` only prints that file to stderr.
//! Exits 0 on success, 1 on failure and 2 on a usage error.
//!
//! Orphan StringName reports fail only on ordinary (non-static) references
//! beyond what Godot itself leaves: Godot 4.7.2's editor (headless or not,
//! with no extension loaded) ends with `Orphan StringName: Node (static: 3,
//! total: 4)`, one ordinary reference (`editor_stock`); script mode leaves
//! none. Static references, such as a loaded module's comptime names, are
//! never a failure.
const std = @import("std");
const Io = std.Io;
const scan = @import("godot_output_scan");

/// StringNames the stock Godot 4.7.2 editor holds at exit in an empty
/// project with no extension (checked with `--editor --quit-after 30`,
/// headless and under Xvfb).
const editor_stock = [_]scan.StockOrphan{.{ .name = "Node", .non_static = 1 }};

const usage =
    \\usage: runner <godot> <project dir> script <check.gd> <deadline s> [--expect[-once] <text> | --reject <text> | --allow-report <line> | --echo <prefix>]...
    \\       runner <godot> <project dir> editor <quit-after frames> <deadline s> [--expect[-once] <text> | --reject <text> | --allow-report <line> | --echo <prefix>]...
    \\       runner <godot> <project dir> game <scene> <deadline s> [--expect[-once] <text> | --reject <text> | --allow-report <line> | --echo <prefix>]...
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 4 and std.mem.eql(u8, args[1], "--print")) return printFile(arena, io, args[2], args[3]);
    if (args.len < 6) {
        std.debug.print(usage, .{});
        return 2;
    }
    const godot = args[1];
    const project = args[2];
    const mode = args[3];
    const mode_arg = args[4];
    const deadline_s = std.fmt.parseInt(u32, args[5], 10) catch {
        std.debug.print("runner: deadline '{s}' is not a whole number of seconds\n{s}", .{ args[5], usage });
        return 2;
    };
    var expects: std.ArrayList([]const u8) = .empty;
    var expects_once: std.ArrayList([]const u8) = .empty;
    var rejects: std.ArrayList([]const u8) = .empty;
    var allowed: std.ArrayList([]const u8) = .empty;
    var echoes: std.ArrayList([]const u8) = .empty;
    var i: usize = 6;
    while (i < args.len) : (i += 2) {
        const list = if (std.mem.eql(u8, args[i], "--expect"))
            &expects
        else if (std.mem.eql(u8, args[i], "--expect-once"))
            &expects_once
        else if (std.mem.eql(u8, args[i], "--reject"))
            &rejects
        else if (std.mem.eql(u8, args[i], "--allow-report"))
            &allowed
        else if (std.mem.eql(u8, args[i], "--echo"))
            &echoes
        else
            null;
        if (list == null or i + 1 >= args.len) {
            std.debug.print("runner: unexpected argument '{s}'\n{s}", .{ args[i], usage });
            return 2;
        }
        try list.?.append(arena, args[i + 1]);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ godot, "--headless", "--verbose", "--path", project });
    if (std.mem.eql(u8, mode, "script")) {
        try argv.appendSlice(arena, &.{ "--script", mode_arg });
    } else if (std.mem.eql(u8, mode, "editor")) {
        _ = std.fmt.parseInt(u32, mode_arg, 10) catch {
            std.debug.print("runner: frame count '{s}' is not a whole number\n{s}", .{ mode_arg, usage });
            return 2;
        };
        try argv.appendSlice(arena, &.{ "--editor", "--quit-after", mode_arg });
    } else if (std.mem.eql(u8, mode, "game")) {
        try argv.append(arena, mode_arg);
    } else {
        std.debug.print("runner: unknown mode '{s}'\n{s}", .{ mode, usage });
        return 2;
    }

    try writeExtensionList(arena, io, project);

    const deadline: Io.Clock.Timestamp = .fromNow(io, .{ .raw = .fromSeconds(deadline_s), .clock = .awake });
    const result = std.process.run(arena, io, .{
        .argv = argv.items,
        .timeout = .{ .deadline = deadline },
    }) catch |err| {
        // On a timeout the output is lost with the child; say so plainly.
        std.debug.print("runner: running Godot failed: {t} (deadline {d} s)\n", .{ err, deadline_s });
        return 1;
    };
    const out = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });
    const stock: []const scan.StockOrphan = if (std.mem.eql(u8, mode, "editor")) &editor_stock else &.{};

    var problems: std.ArrayList([]const u8) = .empty;
    if (!result.term.success()) try problems.append(arena, try std.fmt.allocPrint(arena, "Godot did not exit with status 0 ({any})", .{result.term}));
    try scan.checkTestMarkers(arena, out, &problems);
    // A run that already failed may have stopped early, with fewer of the
    // events an allowed report counts: an allowed line then matches with
    // any count, so the earlier problem is the one reported.
    const stopped = problems.items.len > 0;
    try scan.checkReports(arena, try withoutLines(arena, out, allowed.items, stopped), stock, &problems);
    for (expects.items) |text| {
        if (std.mem.indexOf(u8, out, text) == null)
            try problems.append(arena, try std.fmt.allocPrint(arena, "missing expected text: {s}", .{text}));
    }
    for (expects_once.items) |text| {
        const n = std.mem.count(u8, out, text);
        if (n != 1)
            try problems.append(arena, try std.fmt.allocPrint(arena, "expected text {d} times, want once: {s}", .{ n, text }));
    }
    for (rejects.items) |text| {
        if (std.mem.indexOf(u8, out, text) != null)
            try problems.append(arena, try std.fmt.allocPrint(arena, "rejected text present: {s}", .{text}));
    }

    if (echoes.items.len > 0) {
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            for (echoes.items) |prefix| {
                if (std.mem.startsWith(u8, line, prefix)) {
                    std.debug.print("{s}\n", .{line});
                    break;
                }
            }
        }
    }
    if (problems.items.len == 0) return 0;
    std.debug.print("--- Godot output (stdout, then stderr) ---\n{s}\n---\n", .{out});
    for (problems.items) |p| std.debug.print("runner: {s}\n", .{p});
    for (allowed.items) |l| std.debug.print("runner: allowed report: {s}\n", .{l});
    return 1;
}

/// `runner --print <dir> <name>`: writes the file to stderr (build.zig's
/// test-stress prints its report this way, with inherited stdio).
fn printFile(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8) u8 {
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return 1;
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
        std.debug.print("runner: cannot read {s}: {t}\n", .{ path, err });
        return 1;
    };
    std.debug.print("{s}", .{text});
    return 0;
}

/// `out` without the lines (ignoring a trailing CR) equal to one of `lines`;
/// with `any_count`, also those that differ from one only in its first
/// number (`sameExceptCount`).
fn withoutLines(arena: std.mem.Allocator, out: []const u8, lines: []const []const u8, any_count: bool) ![]const u8 {
    if (lines.len == 0) return out;
    var kept: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    next: while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        for (lines) |l| {
            if (std.mem.eql(u8, line, l) or (any_count and sameExceptCount(line, l))) continue :next;
        }
        try kept.appendSlice(arena, raw);
        try kept.append(arena, '\n');
    }
    return kept.items;
}

/// True when `line` and `want` differ only in the digits of their first
/// number (both have one).
fn sameExceptCount(line: []const u8, want: []const u8) bool {
    const x = digitRun(line) orelse return false;
    const y = digitRun(want) orelse return false;
    return std.mem.eql(u8, line[0..x[0]], want[0..y[0]]) and std.mem.eql(u8, line[x[1]..], want[y[1]..]);
}

/// Start and end of the first run of decimal digits in `s`.
fn digitRun(s: []const u8) ?[2]usize {
    const start = std.mem.indexOfAny(u8, s, "0123456789") orelse return null;
    var end = start;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    return .{ start, end };
}

test "withoutLines drops only exact lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = "a\nERROR: 2 RID allocations of type 'X' were leaked at exit.\r\nERROR: 3 RID allocations of type 'X' were leaked at exit.\n";
    const got = try withoutLines(a, out, &.{"ERROR: 2 RID allocations of type 'X' were leaked at exit."}, false);
    try std.testing.expectEqualStrings("a\nERROR: 3 RID allocations of type 'X' were leaked at exit.\n\n", got);
    try std.testing.expectEqualStrings(out, try withoutLines(a, out, &.{}, false));
}

test "withoutLines with any count drops the same report with another count only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = "ERROR: 7 RID allocations of type 'X' were leaked at exit.\nERROR: 7 RID allocations of type 'Y' were leaked at exit.\nERROR: RID allocations of type 'X' were leaked at exit.\n";
    const got = try withoutLines(a, out, &.{"ERROR: 280 RID allocations of type 'X' were leaked at exit."}, true);
    try std.testing.expectEqualStrings("ERROR: 7 RID allocations of type 'Y' were leaked at exit.\nERROR: RID allocations of type 'X' were leaked at exit.\n\n", got);
}

/// Writes `.godot/extension_list.cfg` naming every `.gdextension` file of the
/// project (outside `.godot`), one `res://` path per line.
fn writeExtensionList(arena: std.mem.Allocator, io: Io, project: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, project, .{ .iterate = true });
    defer dir.close(io);
    var list: std.ArrayList(u8) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, ".godot")) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".gdextension")) continue;
        try list.print(arena, "res://{s}\n", .{entry.path});
    }
    try dir.createDirPath(io, ".godot");
    try dir.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = list.items });
}
