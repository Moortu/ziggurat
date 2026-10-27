//! A Windows helper for the Wine end-to-end tests (test/host/wine_e2e.zig):
//! it holds a file the way another program would while the Windows editor
//! exports.
//!
//!     wine_holder <share-read | load> <file> <ready file> <stop file>
//!
//! `share-read` opens `<file>` for reading with `FILE_SHARE_READ` only (no
//! write or delete sharing), `load` loads it with `LoadLibraryW`. Then it
//! writes `<ready file>` and waits until `<stop file>` exists (at most ten
//! minutes), and exits, which closes or unloads the file. Exits 1 when the
//! open or the load fails, 2 on a usage error.
const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x1;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: wine_holder <share-read | load> <file> <ready file> <stop file>\n", .{});
        return 2;
    }
    const path = try std.unicode.wtf8ToWtf16LeAllocZ(arena, args[2]);
    if (std.mem.eql(u8, args[1], "share-read")) {
        const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if (h == windows.INVALID_HANDLE_VALUE) {
            std.debug.print("wine_holder: cannot open {s}: error {d}\n", .{ args[2], GetLastError() });
            return 1;
        }
    } else if (std.mem.eql(u8, args[1], "load")) {
        if (LoadLibraryW(path) == null) {
            std.debug.print("wine_holder: cannot load {s}: error {d}\n", .{ args[2], GetLastError() });
            return 1;
        }
    } else {
        std.debug.print("wine_holder: unknown mode {s}\n", .{args[1]});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = args[3], .data = "" });
    var waited_ms: u32 = 0;
    while (waited_ms < 10 * 60 * 1000) : (waited_ms += 50) {
        if (cwd.statFile(io, args[4], .{})) |_| return 0 else |_| {}
        try io.sleep(.fromMilliseconds(50), .awake);
    }
    std.debug.print("wine_holder: no stop file after ten minutes\n", .{});
    return 1;
}
