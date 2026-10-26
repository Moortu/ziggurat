//! Tests of the release package (`zig build package`, tools/package.zig):
//! the zip that is both the release download and the Asset Store upload.
//! The build runs the packager twice on the same inputs and hands both
//! zips to these tests (`package_options`).
const std = @import("std");
const options = @import("package_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const testing = std.testing;
const io = testing.io;

const root = "addons/ziggurat/";

/// Where the template keys of `ziggurat.gdextension` point: the export
/// plugin writes the game library there at export.
const export_dir = "res://.godot/ziggurat/export/";

/// The Asset Store limit per version (1 GB).
const max_size = 1_000_000_000;

/// Every file outside `sdk/`, relative to the add-on folder.
const top_files = [_][]const u8{
    "LICENSE",
    "README.md",
    "THIRD_PARTY_LICENSES.md",
    "bin/libziggurat_game_empty.so",
    "bin/libziggurat_host.so",
    "bin/libziggurat_host_export.a",
    "gdzig-PATCHES.md",
    "ziggurat.gdextension",
};

/// gdzig's change list (vendor/gdzig/PATCHES.md), which THIRD_PARTY_LICENSES.md
/// names. It describes the removal of `oopz`, so it is the one entry that may
/// name it; it holds no code.
const gdzig_patches = root ++ "gdzig-PATCHES.md";

/// Folders that hold build machine paths on Linux: no package entry may
/// name them. (`/usr/` is left out: Zig's standard library holds the
/// default `PATH`.)
const generic_paths = [_][]const u8{ "/home/", "/tmp/", "/nix/store/" };

/// Names the Asset Store guidelines ask to leave out (any path component).
const unwanted = [_][]const u8{ ".gitignore", ".gitattributes", ".github", "Thumbs.db", ".DS_Store", "__MACOSX", "zig", "zig.exe" };

const Entry = struct {
    name: []const u8,
    method: u16,
    time: u16,
    date: u16,
    made_by: u16,
    external: u32,
    data: []const u8,
};

/// The entries of a zip in central directory order, read with no other
/// help than the format (APPNOTE 4.3). Supports what the packager
/// writes: no zip64, no encryption, store or deflate.
fn readZip(a: std.mem.Allocator, bytes: []const u8) ![]Entry {
    if (bytes.len < 22) return error.TooShort;
    const eocd = bytes[bytes.len - 22 ..];
    try testing.expectEqualSlices(u8, "PK\x05\x06", eocd[0..4]);
    try testing.expectEqual(@as(u16, 0), rd(u16, eocd, 20)); // no comment
    const count = rd(u16, eocd, 10);
    const cd_size = rd(u32, eocd, 12);
    const cd_off = rd(u32, eocd, 16);
    try testing.expectEqual(bytes.len - 22, @as(usize, cd_off) + cd_size);
    var out: std.ArrayList(Entry) = .empty;
    var p: usize = cd_off;
    for (0..count) |_| {
        const h = bytes[p..];
        try testing.expectEqualSlices(u8, "PK\x01\x02", h[0..4]);
        const flags = rd(u16, h, 8);
        try testing.expectEqual(@as(u16, 0), flags & 1); // not encrypted
        const method = rd(u16, h, 10);
        const crc = rd(u32, h, 16);
        const csize = rd(u32, h, 20);
        const usize_ = rd(u32, h, 24);
        const nlen = rd(u16, h, 28);
        const xlen = rd(u16, h, 30);
        const clen = rd(u16, h, 32);
        const local = rd(u32, h, 42);
        const name = h[46..][0..nlen];
        // The local header repeats the name and sizes.
        const l = bytes[local..];
        try testing.expectEqualSlices(u8, "PK\x03\x04", l[0..4]);
        try testing.expectEqualSlices(u8, name, l[30..][0..rd(u16, l, 26)]);
        try testing.expectEqual(crc, rd(u32, l, 14));
        const start = local + 30 + rd(u16, l, 26) + rd(u16, l, 28);
        const raw = bytes[start..][0..csize];
        const data = switch (method) {
            0 => raw,
            8 => blk: {
                var in: std.Io.Reader = .fixed(raw);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var d: std.compress.flate.Decompress = .init(&in, .raw, &window);
                break :blk try d.reader.allocRemaining(a, .limited(max_size));
            },
            else => return error.UnknownMethod,
        };
        try testing.expectEqual(@as(usize, usize_), data.len);
        try testing.expectEqual(crc, std.hash.Crc32.hash(data));
        try out.append(a, .{
            .name = name,
            .method = method,
            .time = rd(u16, h, 12),
            .date = rd(u16, h, 14),
            .made_by = rd(u16, h, 4),
            .external = rd(u32, h, 38),
            .data = data,
        });
        p += 46 + nlen + xlen + clen;
    }
    try testing.expectEqual(@as(usize, cd_off) + cd_size, p);
    return out.toOwnedSlice(a);
}

fn rd(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_size));
}

fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// Whether an ELF file is an executable: a type other than a shared
/// object, or a shared object with a program interpreter (a PIE).
fn isElfExecutable(b: []const u8) !bool {
    if (b.len < 64) return error.ShortElf;
    try testing.expectEqual(@as(u8, 2), b[4]); // 64-bit
    try testing.expectEqual(@as(u8, 1), b[5]); // little endian
    const e_type = rd(u16, b, 16);
    if (e_type != 3) return true; // not ET_DYN
    const phoff = rd(u64, b, 32);
    const phentsize = rd(u16, b, 54);
    const phnum = rd(u16, b, 56);
    for (0..phnum) |i| {
        const off = phoff + i * phentsize;
        if (off + 4 > b.len) return error.ShortElf;
        if (rd(u32, b, @intCast(off)) == 3) return true; // PT_INTERP
    }
    return false;
}

fn hasComponent(path: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

test "integration: package contents" {
    try platform.testing_support.requireIntegration();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const entries = try readZip(a, try readFile(a, options.package_zip));

    // The build machine's paths, absolute (the cache options may be relative).
    var machine_paths: [3 + generic_paths.len][]const u8 = undefined;
    for (machine_paths[0..3], [_][]const u8{ options.build_machine_repo, options.build_machine_global_cache, options.build_machine_local_cache }) |*out, p| {
        out.* = try std.Io.Dir.cwd().realPathFileAlloc(io, p, a);
        try testing.expect(std.fs.path.isAbsolute(out.*));
    }
    machine_paths[3..].* = generic_paths;

    // Sorted, unique, all under the add-on folder, regular files only,
    // with fixed time stamps and no executable bit.
    for (entries, 0..) |e, i| {
        if (i > 0) try testing.expect(std.mem.order(u8, entries[i - 1].name, e.name) == .lt);
        if (!std.mem.startsWith(u8, e.name, root)) {
            std.debug.print("outside {s}: {s}\n", .{ root, e.name });
            return error.OutsideAddon;
        }
        try testing.expect(!std.mem.endsWith(u8, e.name, "/"));
        try testing.expectEqual(@as(u16, 0), e.time);
        try testing.expectEqual(@as(u16, (0 << 9) | (1 << 5) | 1), e.date); // 1980-01-01
        try testing.expectEqual(@as(u16, 3), e.made_by >> 8); // Unix attributes
        try testing.expectEqual(@as(u32, 0o100644), e.external >> 16);
        for (unwanted) |u| if (hasComponent(e.name, u)) {
            std.debug.print("unwanted file in the package: {s}\n", .{e.name});
            return error.UnwantedFile;
        };
        if (!std.mem.eql(u8, e.name, gdzig_patches) and (std.mem.indexOf(u8, e.name, "oopz") != null or std.mem.indexOf(u8, e.data, "oopz") != null)) {
            std.debug.print("{s} names oopz\n", .{e.name});
            return error.Oopz;
        }
        if (std.mem.startsWith(u8, e.data, "\x7fELF") and try isElfExecutable(e.data)) {
            std.debug.print("{s} is an ELF executable\n", .{e.name});
            return error.Executable;
        }
        // No path of the machine that built the package.
        for (machine_paths) |needle| {
            if (std.mem.indexOf(u8, e.data, needle) != null) {
                std.debug.print("{s} holds the build machine path {s}\n", .{ e.name, needle });
                return error.BuildMachinePath;
            }
        }
    }

    // Exactly the add-on's files outside sdk/.
    var outside: std.ArrayList([]const u8) = .empty;
    for (entries) |e| {
        const rel = e.name[root.len..];
        if (!std.mem.startsWith(u8, rel, "sdk/")) try outside.append(a, rel);
    }
    try testing.expectEqual(top_files.len, outside.items.len);
    for (top_files, outside.items) |want, got| try testing.expectEqualStrings(want, got);

    // sdk/ is exactly the staged SDK, byte for byte.
    var staged: std.ArrayList([]const u8) = .empty;
    // The staged SDK folder holds the manifest.
    var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(options.staged_sdk_manifest).?, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |w| {
        if (w.kind == .directory) continue;
        try testing.expectEqual(std.Io.File.Kind.file, w.kind);
        try staged.append(a, try a.dupe(u8, w.path));
    }
    var sdk_count: usize = 0;
    for (entries) |e| {
        if (std.mem.startsWith(u8, e.name, root ++ "sdk/")) sdk_count += 1;
    }
    try testing.expectEqual(staged.items.len, sdk_count);
    for (staged.items) |rel| {
        const e = find(entries, try std.fmt.allocPrint(a, root ++ "sdk/{s}", .{rel})) orelse {
            std.debug.print("staged file missing from the package: sdk/{s}\n", .{rel});
            return error.MissingSdkFile;
        };
        try testing.expectEqualSlices(u8, try dir.readFileAlloc(io, rel, a, .limited(max_size)), e.data);
    }
    try testing.expect(find(entries, root ++ "sdk/.gdignore") != null);
    try testing.expect(find(entries, root ++ "sdk/sdk-manifest.json") != null);

    // gdzig's change list is the repository's, byte for byte.
    const patches_src = try std.fs.path.join(a, &.{ options.build_machine_repo, "vendor/gdzig/PATCHES.md" });
    try testing.expectEqualSlices(u8, try std.Io.Dir.cwd().readFileAlloc(io, patches_src, a, .limited(max_size)), find(entries, gdzig_patches).?.data);

    // The licence files carry copyright lines.
    try testing.expect(std.mem.indexOf(u8, find(entries, root ++ "LICENSE").?.data, "Copyright (c) 2026 moortu") != null);
    const third = find(entries, root ++ "THIRD_PARTY_LICENSES.md").?.data;
    for ([_][]const u8{ "Copyright (c) 2025 gdzig", "Copyright (c) Zig contributors", "Godot Engine contributors", "casez", "`gdzig-PATCHES.md`" }) |needle| {
        if (std.mem.indexOf(u8, third, needle) == null) {
            std.debug.print("THIRD_PARTY_LICENSES.md lacks \"{s}\"\n", .{needle});
            return error.MissingNotice;
        }
    }

    // The libraries load on the pinned glibc, like an exported game.
    for ([_][]const u8{ "bin/libziggurat_host.so", "bin/libziggurat_game_empty.so" }) |rel| {
        const data = find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})).?.data;
        const versions = try platform.elf.neededVersions(a, data);
        if (zbuild.export_build.glibcAbove(versions, platform.pins.export_glibc)) |v| {
            std.debug.print("{s} needs {s}\n", .{ rel, v });
            return error.GlibcTooNew;
        }
    }
    // The export host is the archive the export build links.
    try testing.expect(std.mem.startsWith(u8, find(entries, root ++ "bin/libziggurat_host_export.a").?.data, "!<arch>\n"));
}

test "integration: package is deterministic" {
    try platform.testing_support.requireIntegration();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Two runs of the packager on the same inputs.
    try testing.expect(!std.mem.eql(u8, options.package_zip, options.package_zip_again));
    const first = try readFile(a, options.package_zip);
    const second = try readFile(a, options.package_zip_again);
    try testing.expect(std.mem.eql(u8, first, second));
}

test "integration: package size" {
    try platform.testing_support.requireIntegration();
    const stat = try std.Io.Dir.cwd().statFile(io, options.package_zip, .{});
    try testing.expect(stat.size > 0);
    try testing.expect(stat.size < max_size);
}

test "integration: every gdextension library present" {
    try platform.testing_support.requireIntegration();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const entries = try readZip(a, try readFile(a, options.package_zip));
    const ext = find(entries, root ++ "ziggurat.gdextension").?.data;
    const readme = find(entries, root ++ "README.md").?.data;
    var section: []const u8 = "";
    var keys: usize = 0;
    var editor_keys: usize = 0;
    var it = std.mem.splitScalar(u8, ext, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        if (line[0] == '[') {
            section = line;
            continue;
        }
        if (!std.mem.eql(u8, section, "[libraries]")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadLine;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, std.mem.trim(u8, line[eq + 1 ..], " \t"), "\"");
        keys += 1;
        // The editor library: the editor cannot load the add-on without it.
        if (std.mem.indexOf(u8, key, ".editor.") != null) editor_keys += 1;
        if (std.mem.startsWith(u8, value, "res://.godot/")) {
            // A template key: the export plugin fills it at export, and the
            // README says so.
            try testing.expect(std.mem.indexOf(u8, key, "template") != null);
            try testing.expect(std.mem.startsWith(u8, value, export_dir));
            try testing.expect(std.mem.indexOf(u8, readme, export_dir) != null);
            continue;
        }
        const rel = if (std.mem.startsWith(u8, value, "res://" ++ root)) value[("res://" ++ root).len..] else value;
        if (find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})) == null) {
            std.debug.print("{s} names {s}, which is not in the package\n", .{ key, value });
            return error.MissingLibrary;
        }
    }
    try testing.expect(keys >= 1);
    try testing.expect(editor_keys >= 1);
}

test "integration: package from two cache folders outside the checkout" {
    try platform.testing_support.requireIntegration();
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Fresh cache folders of different lengths in the test's own
    // temporary folder, as a release build or a clean CI run would have them.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const runs = [_][]const u8{ "one", "second-cache-folder" };
    var zips: [runs.len][]const u8 = undefined;
    for (runs, &zips) |name, *zip| {
        const prefix = try std.fs.path.join(a, &.{ base, name, "out" });
        const cache = try std.fs.path.join(a, &.{ base, name, "cache" });
        const result = try std.process.run(a, io, .{
            .argv = &.{ options.zig_exe, "build", "package", "-p", prefix, "--cache-dir", cache },
            .cwd = .{ .path = options.build_machine_repo },
        });
        if (!result.term.success()) {
            std.debug.print("zig build package --cache-dir {s} failed:\n{s}\n", .{ cache, result.stderr });
            return error.PackageBuildFailed;
        }
        zip.* = try readFile(a, try std.fs.path.join(a, &.{ prefix, "ziggurat-" ++ options.sdk_version ++ ".zip" }));
    }
    try testing.expect(std.mem.eql(u8, zips[0], zips[1]));
    const needles = [_][]const u8{ base, options.build_machine_repo } ++ generic_paths;
    for (try readZip(a, zips[0])) |e| {
        for (needles) |needle| {
            if (std.mem.indexOf(u8, e.name, needle) != null or std.mem.indexOf(u8, e.data, needle) != null) {
                std.debug.print("{s} holds the build machine path {s}\n", .{ e.name, needle });
                return error.BuildMachinePath;
            }
        }
    }
}
