//! Export build (L2): an exported game's library `libziggurat_game.so`,
//! built deterministically (spec section 10).
//!
//! One compiler run, driven through the compiler server like the editor's
//! full builds (`compiler.Session` on `Workspace.exportArgv`), with the Zig
//! the caller located:
//!   - the generated root with the fixed build id `export` (scripts sorted by
//!     path, as in editor builds) and the SDK modules are compiled
//!     non-incrementally with LLVM, `-OReleaseSafe`, for
//!     `platform.pins.export_target` (glibc `pins.export_glibc`, baseline
//!     CPU), without debug information (`-fstrip`: debug information holds
//!     absolute paths, so the same project in two folders gave different
//!     bytes);
//!   - the result is linked with the export host archive
//!     (`zig build host-archive`, built ReleaseSafe for the same target)
//!     into one shared library. `--force_undefined ziggurat_host_init`
//!     pulls in the archive member that defines Godot's entry point, and a
//!     version script exports only that symbol: the scripts'
//!     `ziggurat_describe` and `ziggurat_init` resolve inside the library.
//!     compiler_rt is added once, by this link (neither the archive nor the
//!     scripts carry one).
//! The library is checked before it is written to `Options.out_path`: it
//! must export only `ziggurat_host_init`, must not import `dlopen`, and must
//! need no glibc symbol version newer than `pins.export_glibc`.
//!
//! The workspace is the editor's (`<cache_dir>/projects/<project id>/`), so
//! an export build and an editor build of the same project take turns on
//! `build.lock`. The root is written into the project folder, or into the
//! mirror when the folder is read-only; the editor's next build writes its
//! own root back.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("ziggurat_platform");
const scan_mod = @import("scan.zig");
const workspace = @import("workspace.zig");
const compiler = @import("compiler.zig");
const diagnostics = @import("diagnostics.zig");
const OsPath = platform.path.OsPath;
const ZigInstall = platform.zig_locator.ZigInstall;
const ModuleDep = workspace.ModuleDep;
const pins = platform.pins;
pub const Diagnostic = diagnostics.Diagnostic;
pub const DynSymbol = platform.elf.DynSymbol;

/// The build id every export build writes into its table.
pub const build_id = "export";
/// The library's name; the file is `lib_file`.
pub const lib_name = "ziggurat_game";
pub const lib_file = "lib" ++ lib_name ++ ".so";
/// The add-on's export host archive, in `addons/ziggurat/bin/`.
pub const host_archive_file = "libziggurat_host_export.a";
/// Godot's entry point, the one symbol the library exports.
pub const entry_symbol = "ziggurat_host_init";
const version_script = "{ global: " ++ entry_symbol ++ "; local: *; };\n";
const version_script_name = "export.map";
/// Largest library `run` reads back for its check.
const max_lib_bytes = 1 << 30;

/// Everything is borrowed for the call.
pub const Options = struct {
    /// The user's located Zig (`platform.zig_locator`).
    zig: ZigInstall,
    /// Realpath of the project folder.
    project_root: OsPath,
    /// The SDK modules; one must be named `ziggurat`.
    sdk: []const ModuleDep,
    /// `libziggurat_host_export.a` (`zig build host-archive`).
    host_archive: OsPath,
    /// Where the library is written (atomically; parent folders are created).
    out_path: OsPath,
    /// The per-user cache folder (`PathService.dir(.cache)`), shared with
    /// editor builds.
    cache_dir: OsPath,
    script_dirs: []const []const u8 = scan_mod.default_script_dirs,
    /// How long the build waits for another build's `build.lock` (an
    /// editor build of the same project).
    lock_timeout_ms: u32 = 30000,
    /// Longest compiler run before the compiler is killed.
    update_timeout_ms: u32 = 600000,
};

/// Owned; free with `deinit`.
pub const Result = struct {
    /// True when the library was written to `Options.out_path`. When false,
    /// `out_path` was not touched.
    ok: bool,
    /// Compile errors mapped to project files as in editor builds, then the
    /// scan's problems (line 0). Any scan problem fails the build before the
    /// workspace and the compiler: then these are the problems only.
    diagnostics: []Diagnostic,
    /// One sentence when the build failed for a reason other than compile
    /// errors: another build holds `build.lock`, the compiler could not
    /// start, stopped, timed out or sent an unreadable error report, the
    /// library failed its check, or it could not be written.
    message: ?[]const u8,

    pub fn deinit(self: Result, a: std.mem.Allocator) void {
        diagnostics.free(a, self.diagnostics);
        if (self.message) |m| a.free(m);
    }
};

/// Builds the library. Blocking; any thread. A returned error (the SDK list
/// has no `ziggurat` module, the scan or the build folder failed, a file
/// read or write in the build folder failed, out of memory) leaves one
/// sentence in `diag` (read it with `platform.elf.diagText`); every other
/// failure is a `Result` with `ok == false`.
pub fn run(a: std.mem.Allocator, io: std.Io, opts: Options, diag: *[256]u8) !Result {
    @memset(diag, 0);
    const setDiag = platform.elf.setDiag;
    for (opts.sdk) |m| {
        if (std.mem.eql(u8, m.name, "ziggurat")) break;
    } else {
        setDiag(diag, "The SDK module list has no module named ziggurat.", .{});
        return error.MissingSdkModule;
    }
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();

    const sc = scan_mod.scan(arena, io, opts.project_root, opts.script_dirs) catch |err| {
        setDiag(diag, "Scanning the project folder {s} failed: {t}.", .{ opts.project_root.bytes, err });
        return err;
    };
    var out: Builder = .{ .a = a, .problems = sc.problems };
    errdefer out.deinit();
    // A file the scan could not read may be a script, and the library would
    // leave it out without a word.
    if (sc.problems.len != 0) return out.fail("The scan found the problems above, so it does not build the game library.", .{});

    // `env` is read only for its `os`: the cache folder is given.
    const ps = platform.path.PathService.init(.{ .project = opts.project_root }, .{ .os = builtin.os.tag, .home = null });
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    var ws = workspace.prepareIn(a, io, ps, opts.cache_dir, sc, opts.sdk, .{
        .lock_timeout_ms = opts.lock_timeout_ms,
        .build_id = build_id,
    }, &msg) catch |err| {
        // The lock holder is usually this editor's own build, so the
        // workspace's "another editor" sentence would mislead.
        if (err == error.Timeout) return out.fail("A Zig build of this project still ran after the export waited {d} s for it, so the export did not build; export again when it is done.", .{opts.lock_timeout_ms / 1000});
        setDiag(diag, "Preparing the build folder for {s} failed: {t}.", .{ opts.project_root.bytes, err });
        return err;
    };
    defer ws.deinit(a);

    const map = try platform.path.joinFor(ws.os, arena, ws.build_dir, &.{version_script_name});
    cwd.writeFile(io, .{ .sub_path = map.bytes, .data = version_script }) catch |err| {
        setDiag(diag, "Writing the linker version script {s} failed: {t}.", .{ map.bytes, err });
        return err;
    };
    const argv = try ws.exportArgv(arena, opts.zig, .{
        .target = pins.export_target,
        .host_archive = opts.host_archive,
        .version_script = map,
        .name = lib_name,
    });

    var s = compiler.Session.start(a, io, argv, ws.build_dir) catch |err|
        return out.fail("Starting the Zig compiler {s} failed: {t}.", .{ opts.zig.exe.bytes, err });
    defer s.deinit();
    var r = s.update(opts.update_timeout_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return out.fail("The Zig compiler {s} did not finish within {d} ms and was stopped.", .{ opts.zig.exe.bytes, opts.update_timeout_ms }),
        error.CompilerDied => {
            const tail = std.mem.trim(u8, s.stderrTail(), " \t\r\n");
            if (tail.len == 0) return out.fail("The Zig compiler {s} stopped during the export build without output.", .{opts.zig.exe.bytes});
            return out.fail("The Zig compiler {s} stopped during the export build; its last output was: {s}", .{ opts.zig.exe.bytes, tail });
        },
    };
    defer r.deinit(a);
    if (r.bundle.errorMessageCount() > 0) {
        out.compile = diagnostics.decode(a, io, r.bundle, &ws) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedBundle => return out.fail("The Zig compiler {s} reported errors in a form Ziggurat cannot read.", .{opts.zig.exe.bytes}),
        };
        return out.finish(false);
    }
    const built = r.output orelse
        return out.fail("The compiler reported no errors but named no output file in {s}.", .{ws.cache_dir.bytes});

    const bytes = cwd.readFileAlloc(io, built.bytes, a, .limited(max_lib_bytes)) catch |err| {
        setDiag(diag, "Reading the built library {s} failed: {t}.", .{ built.bytes, err });
        return err;
    };
    defer a.free(bytes);
    var why: [256]u8 = undefined;
    if (checkLibrary(a, bytes, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            platform.elf.setDiag(&why, "The built library {s} is not a readable ELF file ({t}).", .{ built.bytes, err });
            break :blk platform.elf.diagText(&why);
        },
    }) |sentence| return out.fail("{s}", .{sentence});

    // Atomic: `Dir.copyFile` writes a temporary file in the destination's
    // folder and renames it over `out_path` (Zig 0.17 `createFileAtomic`
    // and `File.Atomic.replace`), so a reader never sees half a library.
    cwd.copyFile(built.bytes, cwd, opts.out_path.bytes, io, .{ .make_path = true, .replace = true }) catch |err|
        return out.fail("Writing the export library {s} failed: {t}.", .{ opts.out_path.bytes, err });
    return out.finish(true);
}

/// Collects a `Result`: compile diagnostics, then the scan's problems.
const Builder = struct {
    a: std.mem.Allocator,
    problems: []const scan_mod.Problem,
    compile: []Diagnostic = &.{},

    fn deinit(b: *Builder) void {
        diagnostics.free(b.a, b.compile);
        b.compile = &.{};
    }

    fn fail(b: *Builder, comptime fmt: []const u8, args: anytype) !Result {
        const m = try std.fmt.allocPrint(b.a, fmt, args);
        errdefer b.a.free(m);
        var res = try b.finish(false);
        res.message = m;
        return res;
    }

    /// Moves the diagnostics into the result.
    fn finish(b: *Builder, ok: bool) !Result {
        const a = b.a;
        const list = try a.alloc(Diagnostic, b.compile.len + b.problems.len);
        var filled: usize = b.compile.len;
        errdefer {
            for (list[b.compile.len..filled]) |d| {
                if (d.rel) |r| a.free(r);
                a.free(d.message);
            }
            a.free(list);
        }
        for (b.problems) |p| {
            const rel: ?[]const u8 = if (p.rel.len == 0) null else try a.dupe(u8, p.rel);
            errdefer if (rel) |x| a.free(x);
            list[filled] = .{ .rel = rel, .line = 0, .column = 0, .message = try a.dupe(u8, p.message), .notes = &.{} };
            filled += 1;
        }
        @memcpy(list[0..b.compile.len], b.compile);
        a.free(b.compile);
        b.compile = &.{};
        return .{ .ok = ok, .diagnostics = list, .message = null };
    }
};

/// Why the linked library `bytes` must not ship, or null when it may: what
/// it exports and imports (`exportProblem`) and the glibc versions it needs
/// (`glibcAbove` with `pins.export_glibc`). The sentence is in `buf`.
pub fn checkLibrary(a: std.mem.Allocator, bytes: []const u8, buf: *[256]u8) !?[]const u8 {
    const syms = try platform.elf.dynamicSymbols(a, bytes);
    defer a.free(syms);
    if (exportProblem(syms, buf)) |s| return s;
    const vers = try platform.elf.neededVersions(a, bytes);
    defer a.free(vers);
    if (glibcAbove(vers, pins.export_glibc)) |v| {
        platform.elf.setDiag(buf, "The export library needs {s}, but Godot's export template needs nothing newer than GLIBC_{s}.", .{ v, pins.export_glibc });
        return platform.elf.diagText(buf);
    }
    return null;
}

/// Why the dynamic symbols `syms` are wrong for an export library, or null:
/// it must export `entry_symbol` and nothing else, and must not import
/// `dlopen`. The sentence is in `buf`.
pub fn exportProblem(syms: []const DynSymbol, buf: *[256]u8) ?[]const u8 {
    var has_entry = false;
    for (syms) |s| {
        if (s.name.len == 0) continue;
        if (s.defined) {
            if (std.mem.eql(u8, s.name, entry_symbol)) {
                has_entry = true;
                continue;
            }
            platform.elf.setDiag(buf, "The export library exports {s}; it may export only " ++ entry_symbol ++ ".", .{s.name});
            return platform.elf.diagText(buf);
        }
        if (std.mem.eql(u8, s.name, "dlopen")) {
            platform.elf.setDiag(buf, "The export library imports dlopen; it must load nothing at run time.", .{});
            return platform.elf.diagText(buf);
        }
    }
    if (has_entry) return null;
    platform.elf.setDiag(buf, "The export library does not export " ++ entry_symbol ++ ".", .{});
    return platform.elf.diagText(buf);
}

/// The first `GLIBC_` version in `versions` newer than `max` (`2.28`), or
/// null. A `GLIBC_` name that does not parse as a version (such as
/// `GLIBC_PRIVATE`) counts as newer: it cannot be shown to be old enough.
/// Other names (`GCC_3.0`) are ignored.
pub fn glibcAbove(versions: []const []const u8, max: []const u8) ?[]const u8 {
    const limit = parseVersion(max) orelse return if (versions.len > 0) versions[0] else null;
    for (versions) |v| {
        if (!std.mem.startsWith(u8, v, "GLIBC_")) continue;
        const got = parseVersion(v["GLIBC_".len..]) orelse return v;
        if (std.mem.order(u32, &got, &limit) == .gt) return v;
    }
    return null;
}

/// `major.minor[.patch]`; missing parts are 0.
fn parseVersion(s: []const u8) ?[3]u32 {
    var out = [3]u32{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 3) return null;
        out[n] = std.fmt.parseInt(u32, part, 10) catch return null;
    }
    if (n < 2) return null;
    return out;
}

/// What an export writes, from its output path, as Godot 4.7.2 routes it.
pub const OutputKind = enum {
    /// A full export: the game executable, its pack and the game library
    /// next to it.
    full,
    /// A pack export (`.pck`, also as a patch): no executable and no shared
    /// library.
    pack,
    /// A path ending in `zip`: a pack export to `.zip` (no shared library),
    /// or a full Linux export that Godot zips (with the library). The zip
    /// tells which (`zipHoldsLibrary`).
    zip,
};

/// The kind of export that writes `path`. Godot compares case-sensitively:
/// a pack export needs a path ending in `.pck` or `.zip` (`EditorNode`,
/// `ProjectExportDialog`), and the Linux platform zips a full export whose
/// path ends in `zip` (`EditorExportPlatformLinuxBSD::export_project`).
pub fn outputKind(path: []const u8) OutputKind {
    if (std.mem.endsWith(u8, path, ".pck")) return .pack;
    if (std.mem.endsWith(u8, path, "zip")) return .zip;
    return .full;
}

/// True when the zip at `path` has an entry named `lib_file` (in any
/// folder): a full export that Godot zipped. Reads only the central
/// directory.
pub fn zipHoldsLibrary(io: std.Io, path: []const u8) !bool {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var it = try std.zip.Iterator.init(&reader);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |entry| {
        if (entry.filename_len > name_buf.len) continue;
        const name = name_buf[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name);
        const base = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name[i + 1 ..] else name;
        if (std.mem.eql(u8, base, lib_file)) return true;
    }
    return false;
}

/// The error for an export whose SDK (the manifest at `manifest_path`, of
/// version `sdk_version`) is not the version `host_version` that the add-on's
/// export archive was built for. `from_setting` is true when the project
/// setting `ziggurat/dev/sdk_manifest` chose the manifest. Allocated with `a`.
pub fn sdkMismatchMessage(a: std.mem.Allocator, manifest_path: []const u8, sdk_version: []const u8, host_version: []const u8, from_setting: bool) std.mem.Allocator.Error![]u8 {
    const advice = if (from_setting)
        "Clear the project setting ziggurat/dev/sdk_manifest, or install the add-on that matches the SDK."
    else
        "Reinstall the add-on.";
    return std.fmt.allocPrint(a, "Ziggurat cannot export: the SDK at {s} is version {s}, but this add-on's export library (addons/ziggurat/bin/" ++ host_archive_file ++ ") needs SDK version {s}. {s}", .{ manifest_path, sdk_version, host_version, advice });
}

const testing = std.testing;

test "exportProblem accepts only the entry point and no dlopen" {
    var buf: [256]u8 = undefined;
    const good = [_]DynSymbol{
        .{ .name = "", .defined = false },
        .{ .name = "memcpy", .defined = false },
        .{ .name = "ziggurat_host_init", .defined = true },
    };
    try testing.expect(exportProblem(&good, &buf) == null);
    const extra = good ++ [_]DynSymbol{.{ .name = "ziggurat_describe", .defined = true }};
    try testing.expectEqualStrings("The export library exports ziggurat_describe; it may export only ziggurat_host_init.", exportProblem(&extra, &buf).?);
    const loads = good ++ [_]DynSymbol{.{ .name = "dlopen", .defined = false }};
    try testing.expectEqualStrings("The export library imports dlopen; it must load nothing at run time.", exportProblem(&loads, &buf).?);
    const none = [_]DynSymbol{.{ .name = "memcpy", .defined = false }};
    try testing.expectEqualStrings("The export library does not export ziggurat_host_init.", exportProblem(&none, &buf).?);
}

test "glibcAbove finds a version newer than the pin" {
    const vers = [_][]const u8{ "GLIBC_2.2.5", "GLIBC_2.28", "GLIBC_2.17" };
    try testing.expect(glibcAbove(&vers, "2.28") == null);
    try testing.expectEqualStrings("GLIBC_2.28", glibcAbove(&vers, "2.27").?);
    const newer = vers ++ [_][]const u8{ "GCC_3.0", "GLIBC_2.34", "GLIBC_PRIVATE" };
    try testing.expectEqualStrings("GLIBC_2.34", glibcAbove(&newer, "2.28").?);
    // A version that does not parse counts as newer: it cannot be proven old enough.
    const odd = [_][]const u8{ "GCC_3.0", "GLIBC_2.x" };
    try testing.expectEqualStrings("GLIBC_2.x", glibcAbove(&odd, "2.28").?);
    const private = [_][]const u8{"GLIBC_PRIVATE"};
    try testing.expectEqualStrings("GLIBC_PRIVATE", glibcAbove(&private, "2.28").?);
    // The pin itself parses.
    try testing.expect(parseVersion(pins.export_glibc) != null);
}

test "the empty game root is the generated root of no scripts" {
    const text = try @import("rootgen.zig").generateRoot(testing.allocator, .linux, &.{}, build_id);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(text, @import("empty_root.zig").text);
}

test "the version script exports only the entry point" {
    try testing.expectEqualStrings("{ global: ziggurat_host_init; local: *; };\n", version_script);
}

test "outputKind follows Godot's routing by file name" {
    try testing.expectEqual(OutputKind.full, outputKind("out/game.x86_64"));
    try testing.expectEqual(OutputKind.full, outputKind("/abs/my game/game"));
    try testing.expectEqual(OutputKind.pack, outputKind("out/game.pck"));
    try testing.expectEqual(OutputKind.zip, outputKind("out/game.zip"));
    // Godot compares case-sensitively: these are full exports whose
    // executable has an odd name.
    try testing.expectEqual(OutputKind.full, outputKind("out/game.PCK"));
    try testing.expectEqual(OutputKind.full, outputKind("out/game.ZIP"));
    // The Linux platform zips a full export whose path ends in "zip".
    try testing.expectEqual(OutputKind.zip, outputKind("out/gamezip"));
}

/// A zip of empty stored files named `names`.
fn testZip(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    const zeros: [12]u8 = @splat(0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(a);
    for (names) |n| {
        try offsets.append(a, @intCast(out.items.len));
        try out.appendSlice(a, "PK\x03\x04");
        // Version, flags, method, time, date; then CRC and sizes.
        try out.appendSlice(a, &[_]u8{ 20, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        try out.appendSlice(a, &zeros);
        try appendInt(a, &out, u16, @intCast(n.len));
        try appendInt(a, &out, u16, 0);
        try out.appendSlice(a, n);
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (names, offsets.items) |n, off| {
        try out.appendSlice(a, "PK\x01\x02");
        // Made by, needed, flags, method, time, date; then CRC and sizes.
        try out.appendSlice(a, &[_]u8{ 20, 3, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        try out.appendSlice(a, &zeros);
        try appendInt(a, &out, u16, @intCast(n.len));
        // Extra and comment lengths, disk, attributes.
        try out.appendSlice(a, &zeros);
        try appendInt(a, &out, u32, off);
        try out.appendSlice(a, n);
    }
    const cd_size: u32 = @as(u32, @intCast(out.items.len)) - cd_start;
    try out.appendSlice(a, "PK\x05\x06\x00\x00\x00\x00");
    try appendInt(a, &out, u16, @intCast(names.len));
    try appendInt(a, &out, u16, @intCast(names.len));
    try appendInt(a, &out, u32, cd_size);
    try appendInt(a, &out, u32, cd_start);
    try appendInt(a, &out, u16, 0);
    return out.toOwnedSlice(a);
}

fn appendInt(a: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(a, &b);
}

test "zipHoldsLibrary tells a full ZIP export from a pack" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { name: []const u8, entries: []const []const u8, want: bool }{
        .{ .name = "full.zip", .entries = &.{ "Game/game.x86_64", "Game/game.pck", "Game/" ++ lib_file }, .want = true },
        .{ .name = "top.zip", .entries = &.{lib_file}, .want = true },
        .{ .name = "pack.zip", .entries = &.{ "project.binary", "main.tscn", ".godot/global_script_class_cache.cfg" }, .want = false },
        .{ .name = "near.zip", .entries = &.{ "Game/" ++ lib_file ++ ".bak", "Game/old" ++ lib_file }, .want = false },
        .{ .name = "empty.zip", .entries = &.{}, .want = false },
    };
    for (cases) |c| {
        const bytes = try testZip(testing.allocator, c.entries);
        defer testing.allocator.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = c.name, .data = bytes });
        const path = try tmp.dir.realPathFileAlloc(io, c.name, testing.allocator);
        defer testing.allocator.free(path);
        try testing.expectEqual(c.want, try zipHoldsLibrary(io, path));
    }
    // Not a zip, and no file: errors, never a panic.
    try tmp.dir.writeFile(io, .{ .sub_path = "game.x86_64", .data = "\x7fELF not a zip" });
    const elf = try tmp.dir.realPathFileAlloc(io, "game.x86_64", testing.allocator);
    defer testing.allocator.free(elf);
    try testing.expect(std.meta.isError(zipHoldsLibrary(io, elf)));
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const missing = try std.fs.path.join(testing.allocator, &.{ dir, "missing.zip" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, zipHoldsLibrary(io, missing));
}

/// Options for `run` calls that must stop at the scan: the Zig path does
/// not exist, so starting a compiler would give a different error.
fn scanStopOptions(root: []const u8, sdk: []const ModuleDep) Options {
    return .{
        .zig = .{ .exe = .fromTrusted("/nonexistent/ziggurat-test/zig"), .version = "0.0.0" },
        .project_root = .fromTrusted(root),
        .sdk = sdk,
        .host_archive = .fromTrusted("/nonexistent/ziggurat-test/host.a"),
        .out_path = .fromTrusted("/nonexistent/ziggurat-test/out/libziggurat_game.so"),
        .cache_dir = .fromTrusted("/nonexistent/ziggurat-test/cache"),
    };
}

test "export_build.run on a project with an unreadable script fails before the compiler" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = "pub const extends = @import(\"ziggurat\").godot.Node;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "good.zig", .data = script });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.zig", .data = script });
    try tmp.dir.setFilePermissions(io, "secret.zig", .fromMode(0), .{});
    defer tmp.dir.setFilePermissions(io, "secret.zig", .fromMode(0o644), .{}) catch {};
    // A user who may read anyway (root) cannot run this test.
    if (tmp.dir.openFile(io, "secret.zig", .{})) |f| {
        f.close(io);
        return error.SkipZigTest;
    } else |_| {}
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const sdk = [_]ModuleDep{.{ .name = "ziggurat", .root = .fromTrusted("/nonexistent/ziggurat-test/sdk.zig"), .deps = &.{} }};
    var diag: [256]u8 = undefined;
    const res = try run(testing.allocator, io, scanStopOptions(root, &sdk), &diag);
    defer res.deinit(testing.allocator);
    try testing.expect(!res.ok);
    try testing.expect(res.message != null);
    try testing.expect(std.mem.indexOf(u8, res.message.?, "scan found the problems") != null);
    try testing.expectEqual(@as(usize, 1), res.diagnostics.len);
    try testing.expectEqualStrings("secret.zig", res.diagnostics[0].rel.?);
    try testing.expect(std.mem.indexOf(u8, res.diagnostics[0].message, "Could not read") != null);
}

test "export_build.run on a project with a case collision fails before the compiler" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = "pub const extends = @import(\"ziggurat\").godot.Node;\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = script });
    try tmp.dir.writeFile(io, .{ .sub_path = "A.zig", .data = script });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const sdk = [_]ModuleDep{.{ .name = "ziggurat", .root = .fromTrusted("/nonexistent/ziggurat-test/sdk.zig"), .deps = &.{} }};
    var diag: [256]u8 = undefined;
    const res = try run(testing.allocator, io, scanStopOptions(root, &sdk), &diag);
    defer res.deinit(testing.allocator);
    try testing.expect(!res.ok);
    try testing.expect(res.message != null);
    try testing.expectEqual(@as(usize, 1), res.diagnostics.len);
    try testing.expect(std.mem.indexOf(u8, res.diagnostics[0].message, "differ only by case") != null);
}

test "sdkMismatchMessage names the manifest, both versions and the advice" {
    const a = testing.allocator;
    const set = try sdkMismatchMessage(a, "/dev/sdk/sdk-manifest.json", "9.9.9", "0.1.0", true);
    defer a.free(set);
    try testing.expectEqualStrings("Ziggurat cannot export: the SDK at /dev/sdk/sdk-manifest.json is version 9.9.9, but this add-on's export library (addons/ziggurat/bin/libziggurat_host_export.a) needs SDK version 0.1.0. Clear the project setting ziggurat/dev/sdk_manifest, or install the add-on that matches the SDK.", set);
    const shipped = try sdkMismatchMessage(a, "/p/addons/ziggurat/sdk/sdk-manifest.json", "0.2.0", "0.1.0", false);
    defer a.free(shipped);
    try testing.expectEqualStrings("Ziggurat cannot export: the SDK at /p/addons/ziggurat/sdk/sdk-manifest.json is version 0.2.0, but this add-on's export library (addons/ziggurat/bin/libziggurat_host_export.a) needs SDK version 0.1.0. Reinstall the add-on.", shipped);
}
