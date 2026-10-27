//! Tests of the release package (`zig build package`, tools/package.zig):
//! the zip that is both the release download and the Asset Store upload.
//! The build runs the packager twice on the same inputs and hands both
//! zips to these tests (`package_options`).
const std = @import("std");
const options = @import("package_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const testing = std.testing;
const macho = platform.macho;
const io = testing.io;

const root = "addons/ziggurat/";

/// Where the template keys of `ziggurat.gdextension` point: the export
/// plugin writes the game library there at export.
const export_dir = "res://.godot/ziggurat/export/";

/// The Asset Store limit per version (1 GB).
const max_size = 1_000_000_000;

/// Every file outside `sdk/`, relative to the add-on folder, in name
/// order: the editor libraries in `bin/`, per target key the export host
/// archive and the empty game library in `bin/<key>/`, and the universal
/// macOS empty game library in `bin/universal-macos/`.
const top_files = [_][]const u8{
    "LICENSE",
    "README.md",
    "THIRD_PARTY_LICENSES.md",
    "bin/aarch64-macos/libziggurat_game_empty.dylib",
    "bin/aarch64-macos/libziggurat_host_export.a",
    "bin/libziggurat_host.dylib",
    "bin/libziggurat_host.so",
    "bin/universal-macos/libziggurat_game_empty.dylib",
    "bin/x86_64-linux/libziggurat_game_empty.so",
    "bin/x86_64-linux/libziggurat_host_export.a",
    "bin/x86_64-macos/libziggurat_game_empty.dylib",
    "bin/x86_64-macos/libziggurat_host_export.a",
    "bin/x86_64-windows/ziggurat_game_empty.dll",
    "bin/x86_64-windows/ziggurat_host_export.lib",
    "bin/ziggurat_host.dll",
    "gdzig-PATCHES.md",
    "ziggurat.gdextension",
};

/// The target keys the package holds, with the staged SDK of each (the
/// path of its `sdk-manifest.json`).
const packaged = [_]struct { key: []const u8, staged_manifest: []const u8 }{
    .{ .key = "x86_64-linux", .staged_manifest = options.staged_sdk_x86_64_linux },
    .{ .key = "x86_64-windows", .staged_manifest = options.staged_sdk_x86_64_windows },
    .{ .key = "aarch64-macos", .staged_manifest = options.staged_sdk_aarch64_macos },
    .{ .key = "x86_64-macos", .staged_manifest = options.staged_sdk_x86_64_macos },
};

/// The macOS files of the package (Stage 7c), relative to the add-on
/// folder: the universal editor library, and the folders of both macOS
/// target keys and of the universal empty game library.
const macos_file = "bin/libziggurat_host.dylib";
const macos_folders = [_][]const u8{
    "bin/aarch64-macos/",
    "bin/x86_64-macos/",
    "bin/universal-macos/",
    "sdk/aarch64-macos/",
    "sdk/x86_64-macos/",
};

fn isMacosPath(rel: []const u8) bool {
    if (std.mem.eql(u8, rel, macos_file)) return true;
    for (macos_folders) |f| if (std.mem.startsWith(u8, rel, f)) return true;
    return false;
}

/// The files shared with the 7b package that 7c changes on purpose:
///   - the Linux and Windows editor libraries, which now hold the Mach-O
///     reader (the macOS file checks run in every editor);
///   - `ziggurat.gdextension`, which gains the macOS keys;
///   - `README.md`, which gains the macOS section.
const changed_since_7b = [_][]const u8{
    "README.md",
    "bin/libziggurat_host.so",
    "bin/ziggurat_host.dll",
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

/// Whether a PE file (`MZ`) is an executable: its COFF header lacks the
/// DLL flag.
fn isPeExecutable(b: []const u8) !bool {
    if (b.len < 0x40) return error.ShortPe;
    const pe_at = rd(u32, b, 0x3c);
    if (pe_at > b.len - 24) return error.ShortPe;
    try testing.expectEqualSlices(u8, "PE\x00\x00", b[pe_at..][0..4]);
    const characteristics = rd(u16, b, pe_at + 4 + 18);
    return characteristics & 0x2000 == 0; // IMAGE_FILE_DLL
}

/// Whether an ELF file is an executable: a type other than a shared
/// object, or a shared object with a program interpreter (a PIE).
/// Whether `b` starts with a Mach-O magic number: thin 64-bit or 32-bit
/// (little-endian), or fat.
fn isMachO(b: []const u8) bool {
    for ([_][]const u8{ "\xcf\xfa\xed\xfe", "\xce\xfa\xed\xfe", "\xca\xfe\xba\xbe", "\xca\xfe\xba\xbf" }) |m| {
        if (std.mem.startsWith(u8, b, m)) return true;
    }
    return false;
}

/// Why the Mach-O file `b` is not a complete dylib in every slice, or null.
fn machoNotDylib(a: std.mem.Allocator, b: []const u8) !?[]const u8 {
    macho.checkComplete(b) catch |err| return @errorName(err);
    for (try macho.slices(a, b)) |sl| {
        if (rd(u32, b, @intCast(sl.offset + 12)) != std.macho.MH_DYLIB) return "a slice is not MH_DYLIB";
    }
    return null;
}

/// The number of 64-bit Mach-O objects of `cpu` in the BSD archive `arc`,
/// walking its members by their headers. Every member but the symbol
/// table (`__.SYMDEF...`) must be one.
fn bsdArchiveObjects(arc: []const u8, cpu: macho.Cpu) !usize {
    if (!std.mem.startsWith(u8, arc, "!<arch>\n")) return error.NotAnArchive;
    var at: usize = 8;
    var objects: usize = 0;
    var symdef = false;
    while (at < arc.len) {
        if (arc.len - at < 60) return error.ShortArchive;
        const h = arc[at..][0..60];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.BadMemberHeader;
        const size = std.fmt.parseInt(usize, std.mem.trimEnd(u8, h[48..58], " "), 10) catch return error.BadMemberHeader;
        at += 60;
        if (arc.len - at < size) return error.ShortArchive;
        var body = arc[at..][0..size];
        var name: []const u8 = std.mem.trimEnd(u8, h[0..16], " ");
        if (std.mem.startsWith(u8, name, "#1/")) {
            const len = std.fmt.parseInt(usize, name[3..], 10) catch return error.BadMemberHeader;
            if (len > body.len) return error.BadMemberHeader;
            name = std.mem.sliceTo(body[0..len], 0);
            body = body[len..];
        }
        at += size + (size & 1);
        if (std.mem.startsWith(u8, name, "__.SYMDEF")) {
            symdef = true;
            continue;
        }
        if (body.len < 16 or rd(u32, body, 0) != std.macho.MH_MAGIC_64 or rd(u32, body, 12) != std.macho.MH_OBJECT) {
            std.debug.print("archive member {s} is not a 64-bit Mach-O object\n", .{name});
            return error.NotAnObject;
        }
        try testing.expectEqual(@backingInt(cpu), rd(u32, body, 4));
        objects += 1;
    }
    if (!symdef) return error.NoSymbolTable;
    return objects;
}

test "bsdArchiveObjects: short and broken archives fail cleanly" {
    try testing.expectError(error.NotAnArchive, bsdArchiveObjects("", .arm64));
    try testing.expectError(error.NotAnArchive, bsdArchiveObjects("!<arch>", .arm64));
    try testing.expectError(error.NoSymbolTable, bsdArchiveObjects("!<arch>\n", .arm64));
    try testing.expectError(error.ShortArchive, bsdArchiveObjects("!<arch>\n__.SYMDEF", .arm64));
    const header = "__.SYMDEF       0           0     0     644     99        `\n";
    try testing.expectError(error.ShortArchive, bsdArchiveObjects("!<arch>\n" ++ header, .arm64));
    const bad = "__.SYMDEF       0           0     0     644     x         `\n";
    try testing.expectError(error.BadMemberHeader, bsdArchiveObjects("!<arch>\n" ++ bad, .arm64));
    const long = "#1/400          0           0     0     644     4         `\n";
    try testing.expectError(error.BadMemberHeader, bsdArchiveObjects("!<arch>\n" ++ long ++ "abcd", .arm64));
    const empty_symdef = "__.SYMDEF       0           0     0     644     0         `\n";
    try testing.expectEqual(@as(usize, 0), try bsdArchiveObjects("!<arch>\n" ++ empty_symdef, .arm64));
    const text = "a.o             0           0     0     644     4         `\n";
    try testing.expectError(error.NotAnObject, bsdArchiveObjects("!<arch>\n" ++ empty_symdef ++ text ++ "abcd", .arm64));
}

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
        if (std.mem.startsWith(u8, e.data, "MZ") and try isPeExecutable(e.data)) {
            std.debug.print("{s} is a PE executable\n", .{e.name});
            return error.Executable;
        }
        // Every Mach-O file is a dylib, in every slice (spec section 1).
        if (isMachO(e.data)) if (try machoNotDylib(a, e.data)) |why| {
            std.debug.print("{s} is a Mach-O file but not a dylib: {s}\n", .{ e.name, why });
            return error.NotADylib;
        };
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

    // sdk/ is `.gdignore` and, per target key, exactly that key's staged
    // SDK, byte for byte, in sdk/<key>/.
    var sdk_count: usize = 0;
    for (entries) |e| {
        if (std.mem.startsWith(u8, e.name, root ++ "sdk/")) sdk_count += 1;
    }
    var staged_count: usize = 1; // sdk/.gdignore
    try testing.expect(find(entries, root ++ "sdk/.gdignore") != null);
    for (packaged) |t| {
        var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(t.staged_manifest).?, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |w| {
            if (w.kind == .directory) continue;
            try testing.expectEqual(std.Io.File.Kind.file, w.kind);
            staged_count += 1;
            const name = try std.fmt.allocPrint(a, root ++ "sdk/{s}/{s}", .{ t.key, w.path });
            const e = find(entries, name) orelse {
                std.debug.print("staged file missing from the package: {s}\n", .{name});
                return error.MissingSdkFile;
            };
            try testing.expectEqualSlices(u8, try dir.readFileAlloc(io, w.path, a, .limited(max_size)), e.data);
        }
        try testing.expect(find(entries, try std.fmt.allocPrint(a, root ++ "sdk/{s}/sdk-manifest.json", .{t.key})) != null);
    }
    try testing.expectEqual(staged_count, sdk_count);

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
    for ([_][]const u8{ "bin/libziggurat_host.so", "bin/x86_64-linux/libziggurat_game_empty.so" }) |rel| {
        const data = find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})).?.data;
        const versions = try platform.elf.neededVersions(a, data);
        if (zbuild.export_build.glibcAbove(versions, platform.pins.export_glibc)) |v| {
            std.debug.print("{s} needs {s}\n", .{ rel, v });
            return error.GlibcTooNew;
        }
    }
}

test "package: holds both targets" {
    try platform.testing_support.requireIntegration();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const zip = try readFile(a, options.package_zip);
    const entries = try readZip(a, zip);
    // Every path of the plan's package layout.
    for ([_][]const u8{
        "bin/libziggurat_host.so",
        "bin/ziggurat_host.dll",
        "bin/x86_64-linux/libziggurat_host_export.a",
        "bin/x86_64-windows/ziggurat_host_export.lib",
        "bin/x86_64-linux/libziggurat_game_empty.so",
        "bin/x86_64-windows/ziggurat_game_empty.dll",
        "sdk/.gdignore",
        "sdk/x86_64-linux/sdk-manifest.json",
        "sdk/x86_64-windows/sdk-manifest.json",
    }) |rel| {
        if (find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})) == null) {
            std.debug.print("the package lacks {s}\n", .{rel});
            return error.MissingFile;
        }
    }
    // The ELF libraries are x86_64 shared objects, the PE libraries
    // complete x86_64 DLLs.
    for ([_][]const u8{ "bin/libziggurat_host.so", "bin/x86_64-linux/libziggurat_game_empty.so" }) |rel| {
        const data = find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})).?.data;
        try testing.expect(std.mem.startsWith(u8, data, "\x7fELF"));
        try testing.expectEqual(@as(u16, 62), rd(u16, data, 18)); // EM_X86_64
        try testing.expect(!try isElfExecutable(data));
    }
    for ([_][]const u8{ "bin/ziggurat_host.dll", "bin/x86_64-windows/ziggurat_game_empty.dll" }) |rel| {
        const data = find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})).?.data;
        try platform.pe.checkComplete(data);
        try testing.expectEqual(@as(u16, 0x8664), rd(u16, data, rd(u32, data, 0x3c) + 4)); // AMD64
        try testing.expect(!try isPeExecutable(data));
    }
    // The empty game libraries pass the export build's own checks: the DLL
    // exports only `ziggurat_host_init` (no MinGW runtime exports, no
    // script entry points) and imports no module loader.
    for ([_]struct { []const u8, zbuild.export_build.Format }{
        .{ "bin/x86_64-linux/libziggurat_game_empty.so", .elf },
        .{ "bin/x86_64-windows/ziggurat_game_empty.dll", .pe },
    }) |lib| {
        const data = find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{lib[0]})).?.data;
        var why: [256]u8 = undefined;
        if (try zbuild.export_build.checkLibrary(a, lib[1], data, &why)) |sentence| {
            std.debug.print("{s}: {s}\n", .{ lib[0], sentence });
            return error.EmptyGameLibraryRefused;
        }
    }
    {
        const dll = find(entries, root ++ "bin/x86_64-windows/ziggurat_game_empty.dll").?.data;
        const ex = try platform.pe.exports(a, dll);
        try testing.expectEqual(@as(usize, 1), ex.len);
        try testing.expectEqualStrings("ziggurat_host_init", ex[0]);
    }
    // The export host archives: a GNU archive and a COFF archive (two
    // linker members `/`), each with base names only, so no cache path.
    for ([_]struct { []const u8, bool }{
        .{ "bin/x86_64-linux/libziggurat_host_export.a", false },
        .{ "bin/x86_64-windows/ziggurat_host_export.lib", true },
    }) |arc| {
        const data = find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{arc[0]})).?.data;
        try testing.expect(std.mem.startsWith(u8, data, "!<arch>\n"));
        try testing.expect(std.mem.indexOf(u8, data, "zig-cache") == null);
        const first_size = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, data[8 + 48 ..][0..10], " "), 10);
        const second_at = 8 + 60 + first_size + (first_size & 1);
        try testing.expectEqualStrings("/", std.mem.trimEnd(u8, data[8..][0..16], " "));
        try testing.expectEqual(arc[1], std.mem.eql(u8, std.mem.trimEnd(u8, data[second_at..][0..16], " "), "/"));
    }

    // Both shipped manifests load from the unpacked add-on, and every
    // module root is inside that key's folder.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var f = try std.Io.Dir.cwd().openFile(io, options.package_zip, .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var reader = f.reader(io, &buf);
        try tmp.dir.createDirPath(io, "unpacked");
        var dst = try tmp.dir.openDir(io, "unpacked", .{});
        defer dst.close(io);
        try std.zip.extract(dst, &reader, .{});
    }
    const unpacked = try tmp.dir.realPathFileAlloc(io, "unpacked", a);
    for (packaged) |t| {
        const folder = try std.fs.path.join(a, &.{ unpacked, root, "sdk", t.key });
        const path = try std.fs.path.join(a, &.{ folder, "sdk-manifest.json" });
        var why: std.ArrayList(u8) = .empty;
        var m = zbuild.sdk_manifest.load(a, io, .fromTrusted(path), &why) catch |err| {
            std.debug.print("{s} does not load: {s} ({t})\n", .{ path, why.items, err });
            return err;
        };
        defer m.deinit(a);
        try testing.expectEqualStrings(options.sdk_version, m.sdk_version);
        try testing.expect(m.modules.len > 0);
        for (m.modules) |mod| {
            try testing.expect(std.mem.startsWith(u8, mod.root.bytes, folder));
            _ = try std.Io.Dir.cwd().statFile(io, mod.root.bytes, .{});
        }
    }
}

test "package: deterministic with macOS" {
    try platform.testing_support.requireIntegration();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Two runs of the packager on the same inputs.
    try testing.expect(!std.mem.eql(u8, options.package_zip, options.package_zip_again));
    const first = try readFile(a, options.package_zip);
    const second = try readFile(a, options.package_zip_again);
    try testing.expect(std.mem.eql(u8, first, second));
    // The zips hold the macOS files, so the comparison covers them (and
    // "integration: package from two cache folders gives identical bytes"
    // builds them in two fresh caches).
    var macos: usize = 0;
    for (try readZip(a, first)) |e| {
        if (isMacosPath(e.name[root.len..])) macos += 1;
    }
    var want: usize = 2; // the two macOS SDK manifests, at least
    for (top_files) |f| {
        if (isMacosPath(f)) want += 1;
    }
    try testing.expect(macos >= want);
}

test "integration: package size" {
    try platform.testing_support.requireIntegration();
    const stat = try std.Io.Dir.cwd().statFile(io, options.package_zip, .{});
    try testing.expect(stat.size > 0);
    try testing.expect(stat.size < max_size);
}

test "package: every gdextension library is present" {
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
    // Per platform: an editor key and both template keys.
    const platforms = [_][]const u8{ "linux", "windows", "macos" };
    var seen: [platforms.len]u8 = @splat(0);
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
        // `<platform>.<build>[.<arch>]`: the macOS keys have no arch.
        var parts = std.mem.splitScalar(u8, key, '.');
        const plat = parts.next().?;
        const build = parts.next() orelse return error.BadKey;
        const plat_index = for (platforms, 0..) |name, i| {
            if (std.mem.eql(u8, plat, name)) break i;
        } else {
            std.debug.print("unknown platform in {s}\n", .{key});
            return error.BadKey;
        };
        if (std.mem.eql(u8, plat, "macos") and parts.next() != null) {
            std.debug.print("{s}: the macOS libraries are universal, so the key has no arch\n", .{key});
            return error.BadKey;
        }
        for ([_][]const u8{ "editor", "template_debug", "template_release" }, 0..) |name, bit| {
            if (std.mem.eql(u8, build, name)) seen[plat_index] |= @as(u8, 1) << @intCast(bit);
        }
        // The editor library: the editor cannot load the add-on without it.
        if (std.mem.eql(u8, build, "editor")) editor_keys += 1;
        if (std.mem.startsWith(u8, value, "res://.godot/")) {
            // A template key: the export plugin fills it at export, and the
            // README says so.
            try testing.expect(std.mem.indexOf(u8, key, "template") != null);
            try testing.expect(std.mem.startsWith(u8, value, export_dir));
            try testing.expect(std.mem.indexOf(u8, readme, export_dir) != null);
            // macOS exports write the universal library.
            if (std.mem.eql(u8, plat, "macos")) try testing.expectEqualStrings(export_dir ++ "universal-macos/libziggurat_game.dylib", value);
            continue;
        }
        const rel = if (std.mem.startsWith(u8, value, "res://" ++ root)) value[("res://" ++ root).len..] else value;
        if (find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})) == null) {
            std.debug.print("{s} names {s}, which is not in the package\n", .{ key, value });
            return error.MissingLibrary;
        }
    }
    try testing.expect(keys >= 1);
    try testing.expectEqual(platforms.len, editor_keys);
    for (platforms, seen) |name, bits| {
        if (bits != 0b111) {
            std.debug.print("the {s} keys are incomplete (editor, template_debug, template_release: {b:0>3})\n", .{ name, bits });
            return error.MissingKey;
        }
    }
    // What the export plugin reads for each platform it exports to: the
    // export host archive and the SDK per target key, and the game library
    // of a project without Zig scripts (per key on Linux and Windows,
    // universal on macOS).
    for (packaged) |t| {
        const f = platform.target_key.files(t.key).?;
        for ([_][]const u8{
            try std.fmt.allocPrint(a, "bin/{s}/{s}", .{ t.key, f.host_archive }),
            try std.fmt.allocPrint(a, "sdk/{s}/sdk-manifest.json", .{t.key}),
        }) |rel| try expectEntry(a, entries, rel);
        if (!std.mem.endsWith(u8, t.key, "-macos")) try expectEntry(a, entries, try std.fmt.allocPrint(a, "bin/{s}/{s}", .{ t.key, f.game_empty }));
    }
    try expectEntry(a, entries, "bin/" ++ platform.target_key.universal_macos ++ "/libziggurat_game_empty.dylib");
}

fn expectEntry(a: std.mem.Allocator, entries: []const Entry, rel: []const u8) !void {
    if (find(entries, try std.fmt.allocPrint(a, root ++ "{s}", .{rel})) == null) {
        std.debug.print("the package lacks {s}\n", .{rel});
        return error.MissingFile;
    }
}

/// The thin image of `cpu` in a universal file (`macho.slices`).
fn sliceOf(a: std.mem.Allocator, bytes: []const u8, cpu: platform.macho.Cpu) ![]const u8 {
    for (try platform.macho.slices(a, bytes)) |s| {
        if (s.cpu == cpu) return bytes[@intCast(s.offset)..][0..@intCast(s.size)];
    }
    return error.NoSlice;
}

const macos_min: std.SemanticVersion = .{ .major = 11, .minor = 0, .patch = 0 };

test "package: holds macOS files" {
    try platform.testing_support.requireIntegration();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const entries = try readZip(a, try readFile(a, options.package_zip));
    for ([_][]const u8{
        "bin/libziggurat_host.dylib",
        "bin/aarch64-macos/libziggurat_host_export.a",
        "bin/aarch64-macos/libziggurat_game_empty.dylib",
        "bin/x86_64-macos/libziggurat_host_export.a",
        "bin/x86_64-macos/libziggurat_game_empty.dylib",
        "bin/universal-macos/libziggurat_game_empty.dylib",
        "sdk/aarch64-macos/sdk-manifest.json",
        "sdk/x86_64-macos/sdk-manifest.json",
    }) |rel| try expectEntry(a, entries, rel);
    const data = struct {
        fn of(al: std.mem.Allocator, es: []const Entry, rel: []const u8) ![]const u8 {
            return find(es, try std.fmt.allocPrint(al, root ++ "{s}", .{rel})).?.data;
        }
    }.of;

    // The universal files: x86_64 then arm64, every slice minos 11.0.
    // The editor library exports the entry point; the empty game library
    // passes the export build's own check (exports, no `dlopen`).
    var why: [256]u8 = undefined;
    for ([_][]const u8{ "bin/libziggurat_host.dylib", "bin/universal-macos/libziggurat_game_empty.dylib" }) |rel| {
        const bytes = try data(a, entries, rel);
        try macho.checkComplete(bytes);
        const sl = try macho.slices(a, bytes);
        try testing.expectEqual(@as(usize, 2), sl.len);
        try testing.expectEqual(macho.Cpu.x86_64, sl[0].cpu);
        try testing.expectEqual(macho.Cpu.arm64, sl[1].cpu);
        for (sl) |s| {
            const slice = bytes[@intCast(s.offset)..][0..@intCast(s.size)];
            try testing.expectEqual(@as(u32, std.macho.MH_DYLIB), rd(u32, slice, 12)); // a dylib, not a program
            try testing.expectEqual(macos_min, macho.minOs(slice).?);
            var found = false;
            for (try macho.exports(a, slice)) |name| found = found or std.mem.eql(u8, name, "_ziggurat_host_init");
            try testing.expect(found);
        }
    }
    if (try zbuild.export_build.checkUniversal(a, try data(a, entries, "bin/universal-macos/libziggurat_game_empty.dylib"), &why)) |sentence| {
        std.debug.print("bin/universal-macos/libziggurat_game_empty.dylib: {s}\n", .{sentence});
        return error.EmptyGameLibraryRefused;
    }

    // Per arch: the thin empty game library of that CPU (the universal one
    // holds it, byte for byte), and a BSD export host archive of that CPU's
    // objects with base names only.
    const universal_empty = try data(a, entries, "bin/universal-macos/libziggurat_game_empty.dylib");
    for ([_]struct { []const u8, macho.Cpu }{ .{ "aarch64-macos", .arm64 }, .{ "x86_64-macos", .x86_64 } }) |t| {
        const thin = try data(a, entries, try std.fmt.allocPrint(a, "bin/{s}/libziggurat_game_empty.dylib", .{t[0]}));
        try macho.checkComplete(thin);
        const sl = try macho.slices(a, thin);
        try testing.expectEqual(@as(usize, 1), sl.len);
        try testing.expectEqual(@as(u64, 0), sl[0].offset);
        try testing.expectEqual(t[1], sl[0].cpu);
        try testing.expectEqual(@as(u32, std.macho.MH_DYLIB), rd(u32, thin, 12));
        try testing.expectEqual(macos_min, macho.minOs(thin).?);
        if (try zbuild.export_build.checkLibrary(a, .macho, thin, &why)) |sentence| {
            std.debug.print("bin/{s}/libziggurat_game_empty.dylib: {s}\n", .{ t[0], sentence });
            return error.EmptyGameLibraryRefused;
        }
        try testing.expectEqualSlices(u8, thin, try sliceOf(a, universal_empty, t[1]));

        const arc = try data(a, entries, try std.fmt.allocPrint(a, "bin/{s}/libziggurat_host_export.a", .{t[0]}));
        try testing.expect(std.mem.indexOf(u8, arc, "zig-cache") == null);
        // A symbol table, then 64-bit Mach-O objects of this CPU only.
        try testing.expect(try bsdArchiveObjects(arc, t[1]) >= 1);
    }
}

test "package: linux and windows files unchanged from 7b" {
    try platform.testing_support.requireIntegration();
    // `-Dbaseline-zip=<the 7b package>`; without it there is nothing to
    // compare with.
    if (options.baseline_zip.len == 0) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const old = try readZip(a, try readFile(a, options.baseline_zip));
    const new = try readZip(a, try readFile(a, options.package_zip));
    // Every 7b file is still there, and the same bytes, except the files
    // 7c changes on purpose.
    var changed: usize = 0;
    var different: usize = 0;
    for (old) |o| {
        try testing.expect(std.mem.startsWith(u8, o.name, root));
        const rel = o.name[root.len..];
        // 7b had no macOS files.
        try testing.expect(!isMacosPath(rel));
        const n = find(new, o.name) orelse {
            std.debug.print("the 7b file {s} is missing from the package\n", .{rel});
            return error.MissingFile;
        };
        const allowed = for (changed_since_7b) |c| {
            if (std.mem.eql(u8, c, rel)) break true;
        } else false;
        if (allowed) {
            changed += 1;
            continue;
        }
        if (!std.mem.eql(u8, o.data, n.data)) {
            std.debug.print("{s} differs from 7b\n", .{rel});
            different += 1;
        }
    }
    if (different != 0) return error.ChangedSince7b;
    try testing.expectEqual(changed_since_7b.len, changed);
    // Every new file is a macOS file.
    var added: usize = 0;
    for (new) |n| {
        if (find(old, n.name) != null) continue;
        const rel = n.name[root.len..];
        if (!isMacosPath(rel)) {
            std.debug.print("{s} is new and not a macOS file\n", .{rel});
            return error.UnexpectedNewFile;
        }
        added += 1;
    }
    try testing.expect(added > 0);
}

test "integration: package from two cache folders gives identical bytes" {
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
