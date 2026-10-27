//! A fake compiler for the Windows process tests, built by build.zig as
//! `build_options.fake_compiler_exe` (under Wine a Windows test cannot start
//! the Linux `zig`). The first argument picks what it does:
//!
//!     fake_compiler tree <pid file>   start `fake_compiler sleep` as a child,
//!                                     write "<own pid> <child pid>" to
//!                                     <pid file>, then sleep 60 s
//!     fake_compiler sleep             sleep 60 s
//!     fake_compiler server ...        read stdin until it closes and never
//!                                     answer (a long update)
const std = @import("std");

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetProcessId(process: *anyopaque) callconv(.winapi) u32;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.NoMode;
    const mode = args[1];
    if (std.mem.eql(u8, mode, "sleep")) {
        try io.sleep(.fromSeconds(60), .awake);
    } else if (std.mem.eql(u8, mode, "tree")) {
        if (args.len < 3) return error.NoPidFile;
        // The child inherits stdout and stderr, so it holds the pipes too.
        var child = try std.process.spawn(io, .{
            .argv = &.{ args[0], "sleep" },
            .stdin = .ignore,
        });
        _ = &child;
        const text = try std.fmt.allocPrint(arena, "{d} {d}", .{ GetCurrentProcessId(), GetProcessId(child.id.?) });
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{args[2]});
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = text });
        try cwd.rename(tmp, cwd, args[2], io);
        try io.sleep(.fromSeconds(60), .awake);
    } else if (std.mem.eql(u8, mode, "server")) {
        var buf: [256]u8 = undefined;
        var bufs = [_][]u8{&buf};
        const stdin = std.Io.File.stdin();
        while (true) {
            _ = stdin.readStreaming(io, &bufs) catch break;
        }
    } else return error.UnknownMode;
}
