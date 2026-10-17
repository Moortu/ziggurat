//! Build tool: writes the module scripts see as `ziggurat.godot`.
//!
//! Usage: godot_surface <out.zig> <sdk/godot.zig> <extension_api.json> <gdzig class.zig>
//!
//! The output is the text of `sdk/godot.zig` (builtin value types and global
//! enums, written by hand) followed by one declaration per engine class:
//! `pub const <Godot name> = gdzig.class.<gdzig name>;`. Godot names come from
//! extension_api.json. gdzig spells many of them differently
//! (`CharacterBody2d` for CharacterBody2D, `AesContext` for AESContext), so
//! each one is matched, ignoring case, against the class declarations in
//! gdzig's generated `class.zig`; no two engine class names differ only in
//! case. A class with no match fails the tool, so a gdzig update cannot drop
//! a class without notice. The classes in `withheld` are left out.
const std = @import("std");

/// Engine classes that are not re-exported: gdzig's `ClassDb` carries the
/// registration API, and the GDExtension classes load and unload extensions.
pub const withheld = [_][]const u8{ "ClassDB", "GDExtension", "GDExtensionManager" };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: godot_surface <out.zig> <sdk/godot.zig> <extension_api.json> <gdzig class.zig>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const head = try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 20));
    const api = try cwd.readFileAlloc(io, args[3], arena, .limited(256 << 20));
    const class_zig = try cwd.readFileAlloc(io, args[4], arena, .limited(16 << 20));

    const Api = struct { classes: []const struct { name: []const u8 } };
    const parsed = try std.json.parseFromSliceLeaky(Api, arena, api, .{ .ignore_unknown_fields = true });
    const decls = try classDecls(arena, class_zig);

    var text: std.Io.Writer.Allocating = .init(arena);
    try text.writer.writeAll(head);
    try text.writer.writeAll(
        \\
        \\// ---- Engine classes, appended by tools/godot_surface.zig ----
        \\
    );
    var missing: u32 = 0;
    for (parsed.classes) |c| {
        if (isWithheld(c.name)) continue;
        const decl = for (decls) |d| {
            if (std.ascii.eqlIgnoreCase(d, c.name)) break d;
        } else {
            std.debug.print("godot_surface: engine class {s} has no declaration in gdzig's class.zig\n", .{c.name});
            missing += 1;
            continue;
        };
        try text.writer.print("pub const {f} = gdzig.class.{f};\n", .{ std.zig.fmtId(c.name), std.zig.fmtId(decl) });
    }
    if (missing != 0) std.process.exit(1);
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = text.written() });
}

fn isWithheld(name: []const u8) bool {
    for (withheld) |w| {
        if (std.mem.eql(u8, w, name)) return true;
    }
    return false;
}

/// The names of the lines `pub const X = @import("class/...` in gdzig's
/// `class.zig`: one per engine class (plus a few helpers such as `VTable`,
/// which match no engine class name).
fn classDecls(arena: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    const prefix = "pub const ";
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const eq = std.mem.indexOf(u8, rest, " = @import(\"class/") orelse continue;
        try out.append(arena, rest[0..eq]);
    }
    return out.items;
}
