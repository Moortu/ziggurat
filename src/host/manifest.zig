//! The generation manifest (spec section 6, "The running game"): the file
//! `.godot/ziggurat/manifest` that tells a game process the editor started
//! which staged generation to load. This file has the editor's writer and
//! the game's trusted reader.
//!
//! Format: exactly two lines, `gen=<n>\n` and `path=gen/<n>/<library>\n`,
//! where the path is relative to the folder that holds the manifest and
//! names the library the generation store staged (`gen/<n>/libzmod.<n>.so`
//! on Linux). The file is replaced atomically: the text goes to a temporary
//! file in the same folder, which is flushed (`fsync`) and renamed over the
//! manifest, and the folder is flushed after the rename, so a game reads
//! the old manifest or the new one, never a mix.
//!
//! The reader (`readTrusted`, then `recheck` right before the load) trusts
//! nothing in the file (spec section 6, "Trust"): the file is at most
//! `max_file_bytes` and each line at most `max_line_bytes`; no NUL byte;
//! exactly the two lines above; the generation is decimal, without sign or
//! leading zeros, in 1..`max_generation`; the path is relative, made of
//! `[A-Za-z0-9._/-]` only, has no empty, `.` or `..` part, starts with
//! `gen/<n>/` for the same `n` and ends in the library name the store gives
//! generation `n`. Tying the path to `n` also refuses a path loaded before
//! under another generation: its name carries that other number. The
//! manifest must be a regular file, not a symbolic link; the library,
//! resolved with `realpath`, must be a regular file inside
//! `realpath(<store>)`. Each refusal has a fixed sentence (`Refusal`) that
//! never quotes the file. This protects against a manifest that points
//! elsewhere, not against a hostile writer inside the folder; the re-check
//! narrows the window between check and load but does not close it.
//!
//! An export build compiles the reader out: nothing may reference it unless
//! `host_options.export_build` is false.
//!
//! Imports only std and the platform module, so the unit tests run without
//! Godot.
const std = @import("std");
const platform = @import("ziggurat_platform");

const OsPath = platform.path.OsPath;

/// The manifest's file name inside the store folder (`.godot/ziggurat`).
pub const file_name = "manifest";

/// Longest manifest text `format` writes: two keys, two decimal u32s
/// and a library name of at most `max_lib_name` bytes.
pub const max_lib_name = 128;
pub const max_bytes = "gen=\npath=gen//\n".len + 2 * 10 + max_lib_name;

/// Largest generation number a manifest may name.
pub const max_generation: u32 = std.math.maxInt(u32) - 1;

pub const FormatError = error{ InvalidGeneration, InvalidLibraryName };

/// The manifest text for generation `n` whose staged library file is
/// `lib_name` (a bare file name), written into `buf`. Generation 0 or above
/// `max_generation` and a name that is empty, too long, `.`/`..` or holds a separator, a NUL, a
/// line break or a non-printable byte are refused.
pub fn format(buf: *[max_bytes]u8, n: u32, lib_name: []const u8) FormatError![]const u8 {
    if (n == 0 or n > max_generation) return error.InvalidGeneration;
    if (lib_name.len == 0 or lib_name.len > max_lib_name) return error.InvalidLibraryName;
    if (std.mem.eql(u8, lib_name, ".") or std.mem.eql(u8, lib_name, "..")) return error.InvalidLibraryName;
    for (lib_name) |c| {
        if (c == '/' or c == '\\' or c < 0x21 or c > 0x7e) return error.InvalidLibraryName;
    }
    return std.fmt.bufPrint(buf, "gen={d}\npath=gen/{d}/{s}\n", .{ n, n, lib_name }) catch unreachable;
}

/// Replaces `<store_root>/manifest` with the manifest of generation `n`
/// (see `format`), atomically. `store_root` is the generation store's folder,
/// which already exists (the generation was staged there).
pub fn write(a: std.mem.Allocator, io: std.Io, store_root: OsPath, n: u32, lib_name: []const u8) !void {
    var buf: [max_bytes]u8 = undefined;
    const text = try format(&buf, n, lib_name);
    const file = try platform.path.join(a, store_root, &.{file_name});
    defer a.free(file.bytes);
    try platform.atomic_file.writeInFolder(io, file, text);
}

// ------------------------------------------------------------- reader

/// Largest manifest file the reader accepts.
pub const max_file_bytes = 256;
/// Longest line the reader accepts, without its line break.
pub const max_line_bytes = 200;

/// Why the reader refused the manifest. `sentence` is what the game logs.
pub const Refusal = enum {
    missing,
    manifest_symlink,
    manifest_not_regular,
    manifest_unreadable,
    too_large,
    nul_byte,
    not_two_lines,
    line_too_long,
    bad_gen_line,
    gen_not_decimal,
    gen_out_of_range,
    bad_path_line,
    path_absolute,
    path_bad_char,
    path_bad_part,
    path_not_in_generation,
    wrong_library_name,
    store_unresolvable,
    library_missing,
    library_outside_store,
    library_not_regular,
    changed_before_load,

    /// One fixed sentence; it never holds bytes from the file.
    pub fn sentence(r: Refusal) []const u8 {
        const ignored = "Ziggurat ignores the generation manifest because ";
        const end = ", so this game runs without Zig scripts.";
        return switch (r) {
            .missing => "Ziggurat found no generation manifest, so this game runs without Zig scripts (the editor writes one when it builds them).",
            inline else => |t| ignored ++ comptime reason(t) ++ end,
        };
    }

    fn reason(comptime r: Refusal) []const u8 {
        return switch (r) {
            .missing => unreachable,
            .manifest_symlink => "it is a symbolic link",
            .manifest_not_regular => "it is not a regular file",
            .manifest_unreadable => "it cannot be read",
            .too_large => std.fmt.comptimePrint("it is larger than {d} bytes", .{max_file_bytes}),
            .nul_byte => "it holds a NUL byte",
            .not_two_lines => "it is not exactly two lines that each end with a line break",
            .line_too_long => std.fmt.comptimePrint("a line is longer than {d} bytes", .{max_line_bytes}),
            .bad_gen_line => "its first line does not start with gen=",
            .gen_not_decimal => "the generation is not a decimal number without sign or leading zeros",
            .gen_out_of_range => std.fmt.comptimePrint("the generation is not between 1 and {d}", .{max_generation}),
            .bad_path_line => "its second line does not start with path=",
            .path_absolute => "the library path is absolute",
            .path_bad_char => "the library path has a character other than A-Z, a-z, 0-9, '.', '_', '-' and '/'",
            .path_bad_part => "the library path has an empty, '.' or '..' part",
            .path_not_in_generation => "the library path does not start with gen/<generation>/",
            .wrong_library_name => "the library file name is not the one the editor writes for that generation",
            .store_unresolvable => "the folder .godot/ziggurat cannot be resolved",
            .library_missing => "the library does not exist or cannot be resolved",
            .library_outside_store => "the library resolves to a file outside .godot/ziggurat",
            .library_not_regular => "the library is not a regular file",
            .changed_before_load => "the manifest or the library changed between the check and the load",
        };
    }
};

/// A manifest's text that passed every rule on its text.
pub const Parsed = struct {
    n: u32,
    /// The library path, relative to the store folder (a slice of the text).
    path: []const u8,
};

pub const ParseResult = union(enum) { ok: Parsed, refused: Refusal };

/// Checks the manifest text `bytes` against every rule on the text (see the
/// file comment). `os` and `stem` give the library name the store uses
/// (`platform.path.libName`).
pub fn parse(bytes: []const u8, os: std.Target.Os.Tag, stem: []const u8) ParseResult {
    if (bytes.len > max_file_bytes) return .{ .refused = .too_large };
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return .{ .refused = .nul_byte };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len > max_line_bytes) return .{ .refused = .line_too_long };
    }
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return .{ .refused = .not_two_lines };
    const body = bytes[0 .. bytes.len - 1];
    const nl = std.mem.indexOfScalar(u8, body, '\n') orelse return .{ .refused = .not_two_lines };
    const gen_line = body[0..nl];
    const path_line = body[nl + 1 ..];
    if (std.mem.indexOfScalar(u8, path_line, '\n') != null) return .{ .refused = .not_two_lines };

    const gen_key = "gen=";
    if (!std.mem.startsWith(u8, gen_line, gen_key)) return .{ .refused = .bad_gen_line };
    const digits = gen_line[gen_key.len..];
    if (digits.len == 0) return .{ .refused = .gen_not_decimal };
    for (digits) |c| if (!std.ascii.isDigit(c)) return .{ .refused = .gen_not_decimal };
    if (digits.len > 1 and digits[0] == '0') return .{ .refused = .gen_not_decimal };
    // Ten digits always fit a u64; more never fit a u32.
    if (digits.len > 10) return .{ .refused = .gen_out_of_range };
    const value = std.fmt.parseInt(u64, digits, 10) catch return .{ .refused = .gen_out_of_range };
    if (value == 0 or value > max_generation) return .{ .refused = .gen_out_of_range };
    const n: u32 = @intCast(value);

    const path_key = "path=";
    if (!std.mem.startsWith(u8, path_line, path_key)) return .{ .refused = .bad_path_line };
    const path = path_line[path_key.len..];
    if (path.len != 0 and path[0] == '/') return .{ .refused = .path_absolute };
    for (path) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '/', '-' => {},
        else => return .{ .refused = .path_bad_char },
    };
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return .{ .refused = .path_bad_part };
    }

    var prefix_buf: [16]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "gen/{d}/", .{n}) catch unreachable;
    if (!std.mem.startsWith(u8, path, prefix)) return .{ .refused = .path_not_in_generation };
    var name_buf: [max_lib_name + 32]u8 = undefined;
    const name = platform.path.libName(&name_buf, os, stem, n) catch return .{ .refused = .wrong_library_name };
    if (!std.mem.eql(u8, path[prefix.len..], name)) return .{ .refused = .wrong_library_name };
    return .{ .ok = .{ .n = n, .path = path } };
}

/// A generation the manifest names that passed every rule.
pub const Trusted = struct {
    n: u32,
    /// The library's resolved absolute path (`realpath`), inside the
    /// resolved store folder; the path to load.
    lib: [:0]u8,
    /// The library's inode when it was checked.
    inode: std.Io.File.INode,

    pub fn deinit(t: *Trusted, a: std.mem.Allocator) void {
        a.free(t.lib);
    }
};

pub const ReadResult = union(enum) {
    ok: Trusted,
    refused: Refusal,

    pub fn deinit(r: *ReadResult, a: std.mem.Allocator) void {
        switch (r.*) {
            .ok => |*t| t.deinit(a),
            .refused => {},
        }
    }
};

/// Reads `<store_root>/manifest` (`store_root` absolute) and checks it and
/// the library it names against every rule (see the file comment). Only
/// running out of memory is an error; everything else is a refusal.
pub fn readTrusted(a: std.mem.Allocator, io: std.Io, store_root: []const u8, os: std.Target.Os.Tag, stem: []const u8) std.mem.Allocator.Error!ReadResult {
    const cwd = std.Io.Dir.cwd();
    const manifest_path = try std.fs.path.join(a, &.{ store_root, file_name });
    defer a.free(manifest_path);

    // The manifest itself: a regular file, never followed through a link.
    const st = cwd.statFile(io, manifest_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{ .refused = .missing },
        else => return .{ .refused = .manifest_unreadable },
    };
    switch (st.kind) {
        .file => {},
        .sym_link => return .{ .refused = .manifest_symlink },
        else => return .{ .refused = .manifest_not_regular },
    }
    if (st.size > max_file_bytes) return .{ .refused = .too_large };
    var buf: [max_file_bytes + 1]u8 = undefined;
    const len = blk: {
        const file = cwd.openFile(io, manifest_path, .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
            error.SymLinkLoop => return .{ .refused = .manifest_symlink },
            error.FileNotFound => return .{ .refused = .missing },
            error.IsDir => return .{ .refused = .manifest_not_regular },
            else => return .{ .refused = .manifest_unreadable },
        };
        defer file.close(io);
        const fst = file.stat(io) catch return .{ .refused = .manifest_unreadable };
        if (fst.kind != .file) return .{ .refused = .manifest_not_regular };
        break :blk file.readPositionalAll(io, &buf, 0) catch return .{ .refused = .manifest_unreadable };
    };
    const parsed = switch (parse(buf[0..len], os, stem)) {
        .ok => |p| p,
        .refused => |r| return .{ .refused = r },
    };

    // The library: resolved, inside the resolved store, a regular file.
    const store_real = cwd.realPathFileAlloc(io, store_root, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = .store_unresolvable },
    };
    defer a.free(store_real);
    const joined = try std.fs.path.join(a, &.{ store_root, parsed.path });
    defer a.free(joined);
    const lib = cwd.realPathFileAlloc(io, joined, a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = .library_missing },
    };
    var keep = false;
    defer if (!keep) a.free(lib);
    if (!inside(store_real, lib)) return .{ .refused = .library_outside_store };
    const lst = cwd.statFile(io, lib, .{ .follow_symlinks = false }) catch return .{ .refused = .library_missing };
    if (lst.kind != .file) return .{ .refused = .library_not_regular };
    keep = true;
    return .{ .ok = .{ .n = parsed.n, .lib = lib, .inode = lst.inode } };
}

/// True when the resolved path `path` lies below the resolved folder `root`.
fn inside(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len <= root.len) return false;
    // A root that ends in a separator (the file system root) already
    // separates.
    if (std.fs.path.isSep(root[root.len - 1])) return true;
    return std.fs.path.isSep(path[root.len]);
}

/// Repeats every check right before the load: the manifest must still name
/// the same generation and the library must still resolve to the same
/// regular file. Null when nothing changed.
pub fn recheck(a: std.mem.Allocator, io: std.Io, store_root: []const u8, t: *const Trusted, os: std.Target.Os.Tag, stem: []const u8) std.mem.Allocator.Error!?Refusal {
    var again = try readTrusted(a, io, store_root, os, stem);
    defer again.deinit(a);
    const now = switch (again) {
        .ok => |*n| n,
        .refused => return .changed_before_load,
    };
    if (now.n != t.n or now.inode != t.inode or !std.mem.eql(u8, now.lib, t.lib)) return .changed_before_load;
    return null;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "format gives exactly two lines" {
    var buf: [max_bytes]u8 = undefined;
    try testing.expectEqualStrings("gen=1\npath=gen/1/libzmod.1.so\n", try format(&buf, 1, "libzmod.1.so"));
    try testing.expectEqualStrings("gen=4294967294\npath=gen/4294967294/zmod.4294967294.dll\n", try format(&buf, max_generation, "zmod.4294967294.dll"));
    const long: [max_lib_name]u8 = @splat('l');
    try testing.expect((try format(&buf, max_generation, &long)).len <= max_bytes);
}

test "format refuses generation 0 and bad library names" {
    var buf: [max_bytes]u8 = undefined;
    try testing.expectError(error.InvalidGeneration, format(&buf, 0, "libzmod.0.so"));
    try testing.expectError(error.InvalidGeneration, format(&buf, std.math.maxInt(u32), "libzmod.4294967295.so"));
    for ([_][]const u8{ "", ".", "..", "a/b.so", "a\\b.dll", "a b.so", "a\nb.so", "a\x00.so", "\xc3\xa9.so" }) |name| {
        try testing.expectError(error.InvalidLibraryName, format(&buf, 1, name));
    }
    const too_long: [max_lib_name + 1]u8 = @splat('l');
    try testing.expectError(error.InvalidLibraryName, format(&buf, 1, &too_long));
}

test "write replaces the manifest and leaves no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const a = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    try write(a, io, .fromTrusted(root), 1, "libzmod.1.so");
    try write(a, io, .fromTrusted(root), 12, "libzmod.12.so");
    const got = try tmp.dir.readFileAlloc(io, file_name, a, .limited(1024));
    defer a.free(got);
    try testing.expectEqualStrings("gen=12\npath=gen/12/libzmod.12.so\n", got);
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);

    // A refused manifest leaves the old one.
    try testing.expectError(error.InvalidLibraryName, write(a, io, .fromTrusted(root), 13, "../x.so"));
    const kept = try tmp.dir.readFileAlloc(io, file_name, a, .limited(1024));
    defer a.free(kept);
    try testing.expectEqualStrings(got, kept);
}

test "write needs the store folder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    defer a.free(missing);
    try testing.expectError(error.FileNotFound, write(a, io, .fromTrusted(missing), 1, "libzmod.1.so"));
}

// ------------------------------------------------------- reader tests

const builtin = @import("builtin");
const lib_os = builtin.os.tag;

fn libFor(buf: []u8, n: u32) []const u8 {
    return platform.path.libName(buf, lib_os, "zmod", n) catch unreachable;
}

fn expectParsed(bytes: []const u8, n: u32, path: []const u8) !void {
    switch (parse(bytes, lib_os, "zmod")) {
        .ok => |p| {
            try testing.expectEqual(n, p.n);
            try testing.expectEqualStrings(path, p.path);
        },
        .refused => |r| {
            std.debug.print("refused {t}: {s}\n", .{ r, bytes });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectRefused(bytes: []const u8, want: Refusal) !void {
    switch (parse(bytes, lib_os, "zmod")) {
        .ok => {
            std.debug.print("accepted: {s}\n", .{bytes});
            return error.TestUnexpectedResult;
        },
        .refused => |r| {
            if (r != want) std.debug.print("{s}: got {t}, want {t}\n", .{ bytes, r, want });
            try testing.expectEqual(want, r);
        },
    }
}

test "parse accepts what the writer writes" {
    var buf: [max_bytes]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    for ([_]u32{ 1, 12, max_generation }) |n| {
        const name = libFor(&name_buf, n);
        const text = try format(&buf, n, name);
        var want_buf: [96]u8 = undefined;
        const want = try std.fmt.bufPrint(&want_buf, "gen/{d}/{s}", .{ n, name });
        try expectParsed(text, n, want);
    }
}

test "parse refuses every malformed manifest with its reason" {
    var lib1_buf: [64]u8 = undefined;
    const lib1 = libFor(&lib1_buf, 1);
    var good_buf: [96]u8 = undefined;
    const good_path = try std.fmt.bufPrint(&good_buf, "gen/1/{s}", .{lib1});
    var t: [512]u8 = undefined;

    try expectRefused("", .not_two_lines);
    try expectRefused("gen=1\n", .not_two_lines);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath={s}", .{good_path}), .not_two_lines);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath={s}\n\n", .{good_path}), .not_two_lines);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath={s}\nextra=1\n", .{good_path}), .not_two_lines);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\x00\npath={s}\n", .{good_path}), .nul_byte);
    const big: [max_file_bytes + 1]u8 = @splat('a');
    try expectRefused(&big, .too_large);
    const long_part: [max_line_bytes]u8 = @splat('a');
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=gen/1/{s}\n", .{&long_part}), .line_too_long);

    try expectRefused(try std.fmt.bufPrint(&t, "gen 1\npath={s}\n", .{good_path}), .bad_gen_line);
    try expectRefused(try std.fmt.bufPrint(&t, "path={s}\ngen=1\n", .{good_path}), .bad_gen_line);
    for ([_][]const u8{ "", "+1", "-1", "01", "1a", " 1", "1 ", "0x1", "1\r" }) |g| {
        try expectRefused(try std.fmt.bufPrint(&t, "gen={s}\npath={s}\n", .{ g, good_path }), .gen_not_decimal);
    }
    for ([_][]const u8{ "0", "4294967295", "4294967296", "99999999999", "123456789012345678901234567890" }) |g| {
        try expectRefused(try std.fmt.bufPrint(&t, "gen={s}\npath={s}\n", .{ g, good_path }), .gen_out_of_range);
    }

    try expectRefused("gen=1\nlib=gen/1/x\n", .bad_path_line);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=/abs/{s}\n", .{lib1}), .path_absolute);
    for ([_][]const u8{ "gen/1/lib zmod.1.so", "gen/1/libzmod$.so", "gen\\1\\x.dll", "C:gen/1/x", "gen/1/\xc3\xa9.so", "gen/1/x~" }) |p| {
        try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath={s}\n", .{p}), .path_bad_char);
    }
    for ([_][]const u8{ "", "gen/1/../1/x.so", "gen/1/./x.so", "gen//1/x.so", "gen/1/x.so/", "./gen/1/x.so", ".." }) |p| {
        try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath={s}\n", .{p}), .path_bad_part);
    }
    // The path names another generation's folder, or no generation folder.
    try expectRefused(try std.fmt.bufPrint(&t, "gen=2\npath={s}\n", .{good_path}), .path_not_in_generation);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=lib/{s}\n", .{lib1}), .path_not_in_generation);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=gen/1\n", .{}), .path_not_in_generation);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=gen/10/{s}\n", .{lib1}), .path_not_in_generation);
    // The right folder, but not the file the editor writes there.
    try expectRefused("gen=1\npath=gen/1/other.so\n", .wrong_library_name);
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=gen/1/sub/{s}\n", .{lib1}), .wrong_library_name);
    var lib2_buf: [64]u8 = undefined;
    try expectRefused(try std.fmt.bufPrint(&t, "gen=1\npath=gen/1/{s}\n", .{libFor(&lib2_buf, 2)}), .wrong_library_name);
}

test "every refusal has a fixed sentence" {
    for (std.enums.values(Refusal)) |r| {
        const s = r.sentence();
        try testing.expect(s.len > 10);
        try testing.expect(s[s.len - 1] == '.');
    }
}

/// A store folder in a temporary folder: `<tmp>/store` (returned, real
/// path) with `gen/<n>/<lib>` files, and `<tmp>/outside`.
const TestStore = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    store: []u8,

    fn init(a: std.mem.Allocator) !TestStore {
        var s: TestStore = .{ .tmp = testing.tmpDir(.{}), .root = undefined, .store = undefined };
        errdefer s.tmp.cleanup();
        try s.tmp.dir.createDirPath(testing.io, "store/gen");
        try s.tmp.dir.createDirPath(testing.io, "outside");
        s.root = try s.tmp.dir.realPathFileAlloc(testing.io, ".", a);
        s.store = try std.fs.path.join(a, &.{ s.root, "store" });
        return s;
    }

    fn deinit(s: *TestStore, a: std.mem.Allocator) void {
        a.free(s.store);
        a.free(s.root);
        s.tmp.cleanup();
    }

    /// Writes `store/gen/<n>/<lib name>` and returns its relative path.
    fn addLib(s: *TestStore, buf: []u8, n: u32) ![]const u8 {
        var name_buf: [64]u8 = undefined;
        const rel = try std.fmt.bufPrint(buf, "store/gen/{d}/{s}", .{ n, libFor(&name_buf, n) });
        try s.tmp.dir.createDirPath(testing.io, std.fs.path.dirname(rel).?);
        try s.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = "library" });
        return rel;
    }

    fn writeManifest(s: *TestStore, n: u32) !void {
        var buf: [max_bytes]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "store/manifest", .data = try format(&buf, n, libFor(&name_buf, n)) });
    }

    fn read(s: *TestStore, a: std.mem.Allocator) !ReadResult {
        return readTrusted(a, testing.io, s.store, lib_os, "zmod");
    }
};

fn expectReadRefused(s: *TestStore, a: std.mem.Allocator, want: Refusal) !void {
    var r = try s.read(a);
    defer r.deinit(a);
    switch (r) {
        .ok => |t| {
            std.debug.print("accepted generation {d} at {s}\n", .{ t.n, t.lib });
            return error.TestUnexpectedResult;
        },
        .refused => |got| {
            if (got != want) std.debug.print("got {t}, want {t}\n", .{ got, want });
            try testing.expectEqual(want, got);
        },
    }
}

test "readTrusted loads the generation the manifest names" {
    const a = testing.allocator;
    var s = try TestStore.init(a);
    defer s.deinit(a);
    var buf: [256]u8 = undefined;
    const rel = try s.addLib(&buf, 3);
    try s.writeManifest(3);
    var r = try s.read(a);
    defer r.deinit(a);
    const t = r.ok;
    try testing.expectEqual(@as(u32, 3), t.n);
    const want = try std.fs.path.join(a, &.{ s.root, rel });
    defer a.free(want);
    try testing.expectEqualStrings(want, t.lib);
    try testing.expect(try recheck(a, testing.io, s.store, &t, lib_os, "zmod") == null);
}

test "readTrusted refuses a missing manifest and missing library" {
    const a = testing.allocator;
    var s = try TestStore.init(a);
    defer s.deinit(a);
    try expectReadRefused(&s, a, .missing);
    try s.writeManifest(4);
    try expectReadRefused(&s, a, .library_missing);
    // A store folder that does not exist.
    const gone = try std.fs.path.join(a, &.{ s.root, "nothing" });
    defer a.free(gone);
    var r = try readTrusted(a, testing.io, gone, lib_os, "zmod");
    defer r.deinit(a);
    try testing.expectEqual(Refusal.missing, r.refused);
}

test "readTrusted refuses a manifest that is a folder, too large or malformed" {
    const a = testing.allocator;
    var s = try TestStore.init(a);
    defer s.deinit(a);
    var buf: [256]u8 = undefined;
    _ = try s.addLib(&buf, 1);
    try s.tmp.dir.createDirPath(testing.io, "store/manifest");
    try expectReadRefused(&s, a, .manifest_not_regular);
    try s.tmp.dir.deleteDir(testing.io, "store/manifest");
    const big: [max_file_bytes + 1]u8 = @splat('a');
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "store/manifest", .data = &big });
    try expectReadRefused(&s, a, .too_large);
    try s.tmp.dir.writeFile(testing.io, .{ .sub_path = "store/manifest", .data = "gen=1\n" });
    try expectReadRefused(&s, a, .not_two_lines);
}

test "readTrusted refuses symbolic links that leave the store, a linked manifest and a library folder" {
    if (lib_os == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var s = try TestStore.init(a);
    defer s.deinit(a);
    const io = testing.io;
    var name_buf: [64]u8 = undefined;

    // A manifest that is a symbolic link (to a good manifest).
    var good: [256]u8 = undefined;
    _ = try s.addLib(&good, 1);
    try s.writeManifest(1);
    try s.tmp.dir.rename("store/manifest", s.tmp.dir, "outside/manifest", io);
    const outside_manifest = try std.fs.path.join(a, &.{ s.root, "outside", "manifest" });
    defer a.free(outside_manifest);
    try s.tmp.dir.symLink(io, outside_manifest, "store/manifest", .{});
    try expectReadRefused(&s, a, .manifest_symlink);
    try s.tmp.dir.deleteFile(io, "store/manifest");

    // The library is a link to a file outside the store.
    try s.tmp.dir.writeFile(io, .{ .sub_path = "outside/lib", .data = "library" });
    const outside_lib = try std.fs.path.join(a, &.{ s.root, "outside", "lib" });
    defer a.free(outside_lib);
    try s.tmp.dir.createDirPath(io, "store/gen/2");
    var p2: [128]u8 = undefined;
    try s.tmp.dir.symLink(io, outside_lib, try std.fmt.bufPrint(&p2, "store/gen/2/{s}", .{libFor(&name_buf, 2)}), .{});
    try s.writeManifest(2);
    try expectReadRefused(&s, a, .library_outside_store);

    // The generation folder is a link to a folder outside the store.
    var p3: [128]u8 = undefined;
    try s.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&p3, "outside/{s}", .{libFor(&name_buf, 3)}), .data = "library" });
    const outside_dir = try std.fs.path.join(a, &.{ s.root, "outside" });
    defer a.free(outside_dir);
    try s.tmp.dir.symLink(io, outside_dir, "store/gen/3", .{ .is_directory = true });
    try s.writeManifest(3);
    try expectReadRefused(&s, a, .library_outside_store);

    // A link that stays inside the store is followed.
    try s.tmp.dir.createDirPath(io, "store/gen/4");
    var p4: [128]u8 = undefined;
    try s.tmp.dir.symLink(io, try std.fmt.bufPrint(&p2, "../1/{s}", .{libFor(&name_buf, 1)}), try std.fmt.bufPrint(&p4, "store/gen/4/{s}", .{libFor(&name_buf, 4)}), .{});
    try s.writeManifest(4);
    {
        var r = try s.read(a);
        defer r.deinit(a);
        try testing.expect(std.mem.endsWith(u8, r.ok.lib, libFor(&name_buf, 1)));
    }

    // The library is a folder.
    var p5: [128]u8 = undefined;
    try s.tmp.dir.createDirPath(io, try std.fmt.bufPrint(&p5, "store/gen/5/{s}", .{libFor(&name_buf, 5)}));
    try s.writeManifest(5);
    try expectReadRefused(&s, a, .library_not_regular);
}

test "recheck refuses a library or manifest that changed after the check" {
    if (lib_os == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    const io = testing.io;
    var s = try TestStore.init(a);
    defer s.deinit(a);
    var buf: [256]u8 = undefined;
    const rel = try s.addLib(&buf, 1);
    try s.writeManifest(1);

    // The library is swapped for a link that leaves the store.
    {
        var r = try s.read(a);
        defer r.deinit(a);
        try s.tmp.dir.rename(rel, s.tmp.dir, "outside/lib", io);
        const outside_lib = try std.fs.path.join(a, &.{ s.root, "outside", "lib" });
        defer a.free(outside_lib);
        try s.tmp.dir.symLink(io, outside_lib, rel, .{});
        try testing.expectEqual(Refusal.changed_before_load, (try recheck(a, io, s.store, &r.ok, lib_os, "zmod")).?);
        try s.tmp.dir.deleteFile(io, rel);
        try s.tmp.dir.rename("outside/lib", s.tmp.dir, rel, io);
    }
    // The library is replaced by another file.
    {
        var r = try s.read(a);
        defer r.deinit(a);
        try s.tmp.dir.deleteFile(io, rel);
        try s.tmp.dir.writeFile(io, .{ .sub_path = "outside/other", .data = "other" });
        try s.tmp.dir.rename("outside/other", s.tmp.dir, rel, io);
        try testing.expectEqual(Refusal.changed_before_load, (try recheck(a, io, s.store, &r.ok, lib_os, "zmod")).?);
    }
    // The manifest is replaced by a link.
    {
        var r = try s.read(a);
        defer r.deinit(a);
        try s.tmp.dir.rename("store/manifest", s.tmp.dir, "outside/manifest", io);
        const outside_manifest = try std.fs.path.join(a, &.{ s.root, "outside", "manifest" });
        defer a.free(outside_manifest);
        try s.tmp.dir.symLink(io, outside_manifest, "store/manifest", .{});
        try testing.expectEqual(Refusal.changed_before_load, (try recheck(a, io, s.store, &r.ok, lib_os, "zmod")).?);
    }
}
