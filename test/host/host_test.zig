//! Host integration tests. Each test copies a fixture project from
//! test/host/projects into a temporary folder, puts the host library and its
//! `.gdextension` into the project's `addon/` folder, adds a check script
//! from test/host/checks as `res://check.gd`, and runs Godot through
//! test/host/runner.zig, which decides pass or fail.
const std = @import("std");
const opts = @import("host_test_options");
const testing = std.testing;
const Io = std.Io;
const io = testing.io;

/// One deadline for a whole Godot run, in seconds.
const deadline_s = "120";

fn requireIntegration() error{SkipZigTest}!void {
    if (!opts.run_integration) return error.SkipZigTest;
}

/// A temporary copy of a fixture project with the host installed.
const Project = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    path: []const u8,

    fn init(p: *Project, fixture: []const u8) !void {
        p.arena_state = .init(testing.allocator);
        errdefer p.arena_state.deinit();
        const a = p.arena_state.allocator();
        p.tmp = testing.tmpDir(.{});
        errdefer p.tmp.cleanup();
        const cwd = Io.Dir.cwd();

        var projects = try cwd.openDir(io, opts.projects_dir, .{});
        defer projects.close(io);
        var src = try projects.openDir(io, fixture, .{ .iterate = true });
        defer src.close(io);
        try p.tmp.dir.createDirPath(io, "project");
        var dst = try p.tmp.dir.openDir(io, "project", .{});
        defer dst.close(io);
        var walker = try src.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => try dst.createDirPath(io, entry.path),
                .file => try src.copyFile(entry.path, dst, entry.path, io, .{}),
                else => {},
            }
        }

        try dst.createDirPath(io, "addon");
        try cwd.copyFile(opts.host_lib, dst, "addon/libziggurat_host.so", io, .{});
        try cwd.copyFile(opts.gdextension, dst, "addon/ziggurat_host.gdextension", io, .{});
        p.path = try p.tmp.dir.realPathFileAlloc(io, "project", a);
    }

    fn deinit(p: *Project) void {
        p.tmp.cleanup();
        p.arena_state.deinit();
    }

    /// Copies test/host/checks/<name> into the project as `res://check.gd`.
    fn addCheck(p: *Project, name: []const u8) !void {
        const cwd = Io.Dir.cwd();
        var checks = try cwd.openDir(io, opts.checks_dir, .{});
        defer checks.close(io);
        var dst = try cwd.openDir(io, p.path, .{});
        defer dst.close(io);
        try checks.copyFile(name, dst, "check.gd", io, .{});
    }

    /// Adds test/host/checks/<name> as `res://check.gd` and makes it an
    /// autoload, so a `@tool` check runs inside the editor.
    fn addAutoloadCheck(p: *Project, name: []const u8) !void {
        try p.addCheck(name);
        var dir = try Io.Dir.cwd().openDir(io, p.path, .{});
        defer dir.close(io);
        const a = p.arena_state.allocator();
        const old = try dir.readFileAlloc(io, "project.godot", a, .limited(64 * 1024));
        const new = try std.mem.concat(a, u8, &.{ old, "\n[autoload]\n\ncheck=\"*res://check.gd\"\n" });
        try dir.writeFile(io, .{ .sub_path = "project.godot", .data = new });
    }

    /// Runs `res://check.gd` headless; every `expect` text must appear in
    /// Godot's output. Fails the test with the runner's report otherwise.
    fn runScript(p: *Project, expect: []const []const u8) !void {
        return p.run(&.{ "script", "res://check.gd" }, expect);
    }

    /// Opens the project in the headless editor for `frames` frames.
    fn runEditor(p: *Project, frames: []const u8, expect: []const []const u8) !void {
        return p.run(&.{ "editor", frames }, expect);
    }

    fn run(p: *Project, mode: []const []const u8, expect: []const []const u8) !void {
        const a = p.arena_state.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ opts.runner_exe, opts.godot_exe, p.path });
        try argv.appendSlice(a, mode);
        try argv.append(a, deadline_s);
        for (expect) |text| try argv.appendSlice(a, &.{ "--expect", text });
        const result = try std.process.run(a, io, .{ .argv = argv.items });
        if (result.term.success()) return;
        std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
        return error.GodotRunFailed;
    }
};

test "host loads" {
    try requireIntegration();
    var p: Project = undefined;
    try p.init("empty");
    defer p.deinit();
    try p.addCheck("host_loads.gd");
    try p.runScript(&.{"ziggurat_host 0.1.0 ready"});
}

test "host loads in editor" {
    try requireIntegration();
    var p: Project = undefined;
    try p.init("empty");
    defer p.deinit();
    // An autoload makes the editor call _add_named_global_constant, one of
    // the virtuals gdzig's unpatched branch quota could not compile.
    try p.addAutoloadCheck("host_loads_editor.gd");
    try p.runEditor("30", &.{"ziggurat_host 0.1.0 ready"});
}
