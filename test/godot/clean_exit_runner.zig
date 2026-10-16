//! Runs the in-Godot tests once more through the clean-exit entry
//! (`clean_exit.zig`) and fails on anything Godot reports at exit.
//!
//! Usage: clean_exit_runner <godot> <harness project dir> <work dir>
//!
//! Copies the project gdzig's harness installed into <work dir>, points its
//! `.gdextension` at the clean-exit entry, runs
//! `godot --headless --path <work dir> --quit` with stdin closed, and fails
//! when Godot exits non-zero, a test fails or is skipped, the moduleInit log
//! line is missing, or the output has `ObjectDB instances leaked` or
//! `Unreferenced static string`. Godot's output is printed only on failure.
const std = @import("std");
const Io = std.Io;

const harness_entry = "entry_symbol = \"gdextension_entry\"";
const clean_entry = "entry_symbol = \"ziggurat_clean_exit_entry\"";
const module_init_marker = "ziggurat-test: moduleInit log ok";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: clean_exit_runner <godot> <harness project dir> <work dir>\n", .{});
        return 2;
    }
    const godot = args[1];
    const cwd = Io.Dir.cwd();
    var src = try cwd.openDir(io, args[2], .{});
    defer src.close(io);
    try cwd.createDirPath(io, args[3]);
    var dst = try cwd.openDir(io, args[3], .{});
    defer dst.close(io);

    const ext = try src.readFileAlloc(io, "test_extension.gdextension", arena, .limited(64 * 1024));
    if (std.mem.indexOf(u8, ext, harness_entry) == null) {
        std.debug.print("clean_exit_runner: no '{s}' in test_extension.gdextension\n", .{harness_entry});
        return 1;
    }
    const ext_new = try std.mem.replaceOwned(u8, arena, ext, harness_entry, clean_entry);
    // The library is the first `res://<file>` the descriptor names.
    const lib = blk: {
        const start = (std.mem.indexOf(u8, ext, "\"res://") orelse return error.NoLibrary) + "\"res://".len;
        const end = std.mem.indexOfScalarPos(u8, ext, start, '"') orelse return error.NoLibrary;
        break :blk ext[start..end];
    };
    try dst.writeFile(io, .{ .sub_path = "test_extension.gdextension", .data = ext_new });
    for ([_][]const u8{ "project.godot", "main.tscn", lib }) |name| {
        try src.copyFile(name, dst, name, io, .{});
    }
    try dst.createDirPath(io, ".godot");
    try dst.writeFile(io, .{ .sub_path = ".godot/extension_list.cfg", .data = "res://test_extension.gdextension\n" });

    const result = try std.process.run(arena, io, .{
        .argv = &.{ godot, "--headless", "--path", args[3], "--quit" },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
    const out = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr });

    var problems: std.ArrayList([]const u8) = .empty;
    if (!result.term.success()) try problems.append(arena, "Godot did not exit with status 0");
    if (std.mem.indexOf(u8, out, "ZTEST FAIL") != null) try problems.append(arena, "a test failed");
    if (std.mem.indexOf(u8, out, "ZTEST SKIP") != null) try problems.append(arena, "a test was skipped");
    if (std.mem.indexOf(u8, out, "ZTEST DONE") == null) try problems.append(arena, "the test run did not finish");
    if (std.mem.indexOf(u8, out, module_init_marker) == null) try problems.append(arena, "the moduleInit log line did not reach Godot's output");
    if (std.mem.indexOf(u8, out, "ObjectDB instance was leaked") != null or
        std.mem.indexOf(u8, out, "ObjectDB instances were leaked") != null)
        try problems.append(arena, "ObjectDB instances leaked");
    if (std.mem.indexOf(u8, out, "Unreferenced static string") != null) try problems.append(arena, "Unreferenced static string");

    if (problems.items.len == 0) return 0;
    std.debug.print("--- Godot output (stdout, then stderr) ---\n{s}\n---\n", .{out});
    for (problems.items) |p| std.debug.print("clean_exit_runner: {s}\n", .{p});
    return 1;
}
