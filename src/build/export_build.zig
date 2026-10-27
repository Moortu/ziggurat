//! Export build (L2): an exported game's library (`libziggurat_game.so` for
//! Linux x86_64, `ziggurat_game.dll` for Windows x86_64; `libFile`), built
//! deterministically (spec section 10).
//!
//! One compiler run, driven through the compiler server like the editor's
//! full builds (`compiler.Session` on `Workspace.exportArgv`), with the Zig
//! the caller located:
//!   - the generated root with the fixed build id `export` (scripts sorted by
//!     path, as in editor builds) and the SDK modules are compiled
//!     non-incrementally with LLVM, `-OReleaseSafe`, for the target of
//!     `Options.target_key` (`targetTriple`: `platform.pins.export_target`
//!     with glibc `pins.export_glibc`, or `x86_64-windows-gnu`; baseline
//!     CPU), without debug information (`-fstrip`: debug information holds
//!     absolute paths, so the same project in two folders gave different
//!     bytes); a debug export (`Options.strip` false) keeps it
//!     (`-fno-strip`) and is not reproducible;
//!   - the result is linked with the export host archive
//!     (`zig build host-archive`, built ReleaseSafe for the same target)
//!     into one shared library. `--force_undefined ziggurat_host_init`
//!     pulls in the archive member that defines Godot's entry point, and
//!     only that symbol is exported: the scripts' `ziggurat_describe` and
//!     `ziggurat_init` resolve inside the library. On Linux a version
//!     script exports it. On Windows a module-definition file does, and the
//!     generated root exports the scripts' two entry points with hidden
//!     visibility (an `export fn` is a DLL export there); without the
//!     `.def` file the COFF linker also exported the MinGW runtime's
//!     `_CRT_INIT`, `__mingw_module_is_dll` and `atexit`.
//!     compiler_rt is added once, by this link (neither the archive nor the
//!     scripts carry one).
//! The library is checked before it is written to `Options.out_path`: it
//! must export only `ziggurat_host_init`; on Linux it must not import
//! `dlopen` and must need no glibc symbol version newer than
//! `pins.export_glibc`; on Windows it must import no `LoadLibrary*` and no
//! `GetProcAddress` (`peProblem`).
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
const target_key = platform.target_key;
pub const Diagnostic = diagnostics.Diagnostic;
pub const DynSymbol = platform.elf.DynSymbol;

/// The build id every export build writes into its table.
pub const build_id = "export";
/// The library's name; the file is `libFile(key)`.
pub const lib_name = "ziggurat_game";
/// The Linux library's file (`libFile("x86_64-linux")`).
pub const lib_file = "lib" ++ lib_name ++ ".so";
/// The add-on's Linux export host archive, in
/// `addons/ziggurat/bin/x86_64-linux/` (`platform.target_key.Files`).
pub const host_archive_file = "libziggurat_host_export.a";
/// Godot's entry point, the one symbol the library exports.
pub const entry_symbol = workspace.entry_symbol;
const version_script = "{ global: " ++ entry_symbol ++ "; local: *; };\n";
const version_script_name = "export.map";
/// The Windows counterpart of `version_script`.
pub const module_definition = "EXPORTS\n    " ++ entry_symbol ++ "\n";
const module_definition_name = "export.def";
/// The target of a Windows export (MinGW ABI, as Godot's own templates).
pub const windows_target = "x86_64-windows-gnu";

/// The object format of an export target.
pub const Format = workspace.Format;

/// The `-target` of an export for target key `key`, or null for a key
/// Ziggurat does not export to.
pub fn targetTriple(key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, target_key.x86_64_linux)) return pins.export_target;
    if (std.mem.eql(u8, key, target_key.x86_64_windows)) return windows_target;
    return null;
}

/// The object format of the library for target key `key`, or null.
pub fn formatOf(key: []const u8) ?Format {
    if (std.mem.eql(u8, key, target_key.x86_64_linux)) return .elf;
    if (std.mem.eql(u8, key, target_key.x86_64_windows)) return .pe;
    return null;
}

/// The game library's file name for target key `key`, or null.
pub fn libFile(key: []const u8) ?[]const u8 {
    if (formatOf(key) == null) return null;
    return (target_key.files(key) orelse return null).game_lib;
}

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
    /// The target the library is for (`platform.target_key`):
    /// `x86_64-linux` or `x86_64-windows`.
    target_key: []const u8 = "x86_64-linux",
    /// The export host archive for `target_key` (`zig build host-archive`):
    /// `libziggurat_host_export.a`, or `ziggurat_host_export.lib`.
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
    /// Build without debug information (`-fstrip`), so the bytes are the
    /// same in every project folder. False for a debug export
    /// (`-fno-strip`): the library keeps its debug information, which
    /// holds absolute paths, so it is not reproducible.
    strip: bool = true,
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
    const triple = targetTriple(opts.target_key) orelse {
        setDiag(diag, "Ziggurat cannot build a game library for the target {s}.", .{opts.target_key});
        return error.UnknownTarget;
    };
    const format = formatOf(opts.target_key).?;
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
    if (sc.problems.len != 0) return out.fail("The scan found the problems above, so it does not build the game library. For a file or folder it could not read, fix its permissions, or add a `.gdignore` file to a folder that holds no scripts.", .{});

    // `env` is read only for its `os`: the cache folder is given.
    const ps = platform.path.PathService.init(.{ .project = opts.project_root }, .{ .os = builtin.os.tag, .home = null });
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(a);
    var ws = workspace.prepareIn(a, io, ps, opts.cache_dir, sc, opts.sdk, .{
        .lock_timeout_ms = opts.lock_timeout_ms,
        .build_id = build_id,
        .hidden_exports = format == .pe,
    }, &msg) catch |err| {
        // The lock holder is usually this editor's own build, so the
        // workspace's "another editor" sentence would mislead.
        if (err == error.Timeout) return out.fail("A Zig build of this project still ran after the export waited {d} s for it, so the export did not build; export again when it is done.", .{opts.lock_timeout_ms / 1000});
        setDiag(diag, "Preparing the build folder for {s} failed: {t}.", .{ opts.project_root.bytes, err });
        return err;
    };
    defer ws.deinit(a);

    const exports_name: []const u8, const exports_text: []const u8 = switch (format) {
        .elf => .{ version_script_name, version_script },
        .pe => .{ module_definition_name, module_definition },
    };
    const exports_file = try platform.path.joinFor(ws.os, arena, ws.build_dir, &.{exports_name});
    cwd.writeFile(io, .{ .sub_path = exports_file.bytes, .data = exports_text }) catch |err| {
        setDiag(diag, "Writing the linker exports file {s} failed: {t}.", .{ exports_file.bytes, err });
        return err;
    };
    const argv = try ws.exportArgv(arena, opts.zig, .{
        .target = triple,
        .format = format,
        .host_archive = opts.host_archive,
        .exports_file = exports_file,
        .name = lib_name,
        .strip = opts.strip,
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
    // A PE list past `pe`'s limits (`error.TooLarge`) is a failed check too.
    if (checkLibrary(a, format, bytes, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            platform.elf.setDiag(&why, "The built library {s} is not a readable {s} file ({t}).", .{ built.bytes, if (format == .pe) "PE" else "ELF", err });
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

/// Why the linked library `bytes` (of `format`) must not ship, or null when
/// it may. ELF: what it exports and imports (`exportProblem`) and the glibc
/// versions it needs (`glibcAbove` with `pins.export_glibc`). PE: the file
/// is complete (`pe.checkComplete`) and what it exports and imports
/// (`peProblem`). The sentence is in `buf`. A file that cannot be read is
/// an error (`pe` gives `error.TooLarge` past its list limits), never a
/// panic.
pub fn checkLibrary(a: std.mem.Allocator, format: Format, bytes: []const u8, buf: *[256]u8) !?[]const u8 {
    if (format == .pe) {
        try platform.pe.checkComplete(bytes);
        const ex = try platform.pe.exports(a, bytes);
        defer platform.pe.freeExports(a, ex);
        const im = try platform.pe.imports(a, bytes);
        defer platform.pe.freeImports(a, im);
        return peProblem(ex, im, buf);
    }
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

/// Why the export and import names of a Windows game DLL are wrong, or
/// null: it must export `entry_symbol` and nothing else (an export by
/// ordinal only, `#<n>`, counts as another export), and must import no
/// `LoadLibrary*` and no `GetProcAddress` from any DLL: the game loads no
/// module at run time, so the editor's loader must not be linked in. Every
/// other import is allowed, among them `GetFileInformationByHandle` (file
/// identity) and ntdll's `LdrLoadDll` and `LdrGetProcedureAddress`, which
/// Zig's std uses to load `iphlpapi.dll` and `dnsapi.dll` by fixed name for
/// its network functions. The sentence is in `buf`.
pub fn peProblem(exports: []const []const u8, imports: []const platform.pe.Import, buf: *[256]u8) ?[]const u8 {
    var has_entry = false;
    for (exports) |name| {
        if (std.mem.eql(u8, name, entry_symbol)) {
            has_entry = true;
            continue;
        }
        platform.elf.setDiag(buf, "The export library exports {s}; it may export only " ++ entry_symbol ++ ".", .{name});
        return platform.elf.diagText(buf);
    }
    for (imports) |im| {
        if (std.mem.startsWith(u8, im.name, "LoadLibrary") or std.mem.eql(u8, im.name, "GetProcAddress")) {
            platform.elf.setDiag(buf, "The export library imports {s} from {s}; it must load nothing at run time.", .{ im.name, im.dll });
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
    /// or a full Linux or Windows export that Godot zips (with the
    /// library). The zip tells which (`zipHoldsLibrary`).
    zip,
};

/// The kind of export that writes `path`. Godot compares case-sensitively:
/// a pack export needs a path ending in `.pck` or `.zip` (`EditorNode`,
/// `ProjectExportDialog`), and the Linux and Windows platforms zip a full
/// export whose path ends in `zip` (`EditorExportPlatformLinuxBSD` and
/// `EditorExportPlatformWindows::export_project`).
pub fn outputKind(path: []const u8) OutputKind {
    if (std.mem.endsWith(u8, path, ".pck")) return .pack;
    if (std.mem.endsWith(u8, path, "zip")) return .zip;
    return .full;
}

/// True when the zip at `path` has an entry named `lib` (the target's
/// `libFile`, in any folder): a full export that Godot zipped. Reads only
/// the central directory.
pub fn zipHoldsLibrary(io: std.Io, path: []const u8, lib: []const u8) !bool {
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
        if (std.mem.eql(u8, base, lib)) return true;
    }
    return false;
}

/// What `removeOldLibrary` did. Free with `deinit`.
pub const OldLibrary = union(enum) {
    /// Nothing is at the path now: there was no file, or it was deleted.
    gone,
    /// Deleting failed, so the file was renamed to this path in the same
    /// folder (`<name>.old-<16 hex>`); the next export deletes it
    /// (`sweepRenamedLibraries`).
    renamed: []u8,
    /// Deleting and renaming failed: the file stays, and this is the
    /// sentence that fails the export.
    stays: []u8,

    pub fn deinit(self: OldLibrary, a: std.mem.Allocator) void {
        switch (self) {
            .gone => {},
            .renamed, .stays => |t| a.free(t),
        }
    }
};

/// The file operations of `removeOldLibrary`; tests replace them to fail.
pub const FileOps = struct {
    delete: *const fn (io: std.Io, path: []const u8) anyerror!void = deleteFile,
    rename: *const fn (io: std.Io, from: []const u8, to: []const u8) anyerror!void = renameFile,

    fn deleteFile(io: std.Io, path: []const u8) anyerror!void {
        return std.Io.Dir.cwd().deleteFile(io, path);
    }

    fn renameFile(io: std.Io, from: []const u8, to: []const u8) anyerror!void {
        const cwd = std.Io.Dir.cwd();
        return cwd.rename(from, cwd, to, io);
    }
};

/// The Windows rule for the game library of an earlier export at `path`
/// (absolute), so it can never ship again (plan decision "Old game library
/// on Windows"): delete it; when that fails (another process has it open
/// or loaded), rename it to `<name>.old-<16 hex>` in the same folder; when
/// that fails too, the export fails with the sentence of `.stays` and
/// writes nothing. POSIX systems keep their own rule (export_plugin.zig).
pub fn removeOldLibrary(a: std.mem.Allocator, io: std.Io, path: []const u8, ops: FileOps) std.mem.Allocator.Error!OldLibrary {
    const del_err = if (ops.delete(io, path)) |_| return .gone else |e| e;
    if (del_err == error.FileNotFound) return .gone;
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const aside = try std.fmt.allocPrint(a, "{s}" ++ renamed_infix ++ "{s}", .{ path, &std.fmt.bytesToHex(rnd, .lower) });
    if (ops.rename(io, path, aside)) |_| {
        return .{ .renamed = aside };
    } else |ren_err| {
        a.free(aside);
        return .{ .stays = try std.fmt.allocPrint(a, "Ziggurat cannot replace the old game library {s}: {t} (renaming it aside failed: {t}). Close programs that use it and export again.", .{ path, del_err, ren_err }) };
    }
}

const renamed_infix = ".old-";

/// True when `name` is what `removeOldLibrary` renames the library `base`
/// to: `<base>.old-` and 16 lowercase hex digits.
pub fn isRenamedLibrary(base: []const u8, name: []const u8) bool {
    if (name.len != base.len + renamed_infix.len + 16) return false;
    if (!std.mem.startsWith(u8, name, base)) return false;
    if (!std.mem.eql(u8, name[base.len..][0..renamed_infix.len], renamed_infix)) return false;
    for (name[base.len + renamed_infix.len ..]) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Deletes each file in the folder `dir` that `removeOldLibrary` renamed
/// the library `base` to (`isRenamedLibrary`). What is still in use stays
/// for a later export; nothing else is touched and nothing is reported.
pub fn sweepRenamedLibraries(io: std.Io, dir: []const u8, base: []const u8) void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !isRenamedLibrary(base, entry.name)) continue;
        d.deleteFile(io, entry.name) catch {};
    }
}

/// The error for an export whose SDK (the manifest at `manifest_path`, of
/// version `sdk_version`) is not the version `host_version` that the add-on's
/// export archive (`archive_rel`, relative to `addons/ziggurat/bin/`) was
/// built for. `from_setting` is true when the project setting
/// `ziggurat/dev/sdk_manifest` chose the manifest. Allocated with `a`.
pub fn sdkMismatchMessage(a: std.mem.Allocator, archive_rel: []const u8, manifest_path: []const u8, sdk_version: []const u8, host_version: []const u8, from_setting: bool) std.mem.Allocator.Error![]u8 {
    const advice = if (from_setting)
        "Clear the project setting ziggurat/dev/sdk_manifest, or install the add-on that matches the SDK."
    else
        "Reinstall the add-on.";
    return std.fmt.allocPrint(a, "Ziggurat cannot export: the SDK at {s} is version {s}, but this add-on's export library (addons/ziggurat/bin/{s}) needs SDK version {s}. {s}", .{ manifest_path, sdk_version, archive_rel, host_version, advice });
}

const testing = std.testing;
const build_options = @import("build_options");

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
        try testing.expectEqual(c.want, try zipHoldsLibrary(io, path, lib_file));
        // A Windows export's zip names the DLL.
        try testing.expect(!try zipHoldsLibrary(io, path, "ziggurat_game.dll"));
    }
    // Not a zip, and no file: errors, never a panic.
    try tmp.dir.writeFile(io, .{ .sub_path = "game.x86_64", .data = "\x7fELF not a zip" });
    const elf = try tmp.dir.realPathFileAlloc(io, "game.x86_64", testing.allocator);
    defer testing.allocator.free(elf);
    try testing.expect(std.meta.isError(zipHoldsLibrary(io, elf, lib_file)));
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const missing = try std.fs.path.join(testing.allocator, &.{ dir, "missing.zip" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, zipHoldsLibrary(io, missing, lib_file));
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

fn imp(dll: []const u8, name: []const u8) platform.pe.Import {
    return .{ .dll = dll, .name = name };
}

test "export_build: windows output exports only ziggurat_host_init" {
    var buf: [256]u8 = undefined;
    const imports = [_]platform.pe.Import{ imp("KERNEL32.dll", "GetLastError"), imp("ntdll.dll", "NtClose") };
    try testing.expect(peProblem(&.{"ziggurat_host_init"}, &imports, &buf) == null);
    // The scripts' entry points and the MinGW runtime's exports are refused.
    for ([_][]const u8{ "ziggurat_describe", "ziggurat_init", "_CRT_INIT", "__mingw_module_is_dll", "atexit", "#7" }) |extra| {
        const want = try std.fmt.allocPrint(testing.allocator, "The export library exports {s}; it may export only ziggurat_host_init.", .{extra});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, peProblem(&.{ "ziggurat_host_init", extra }, &imports, &buf).?);
    }
    try testing.expectEqualStrings("The export library does not export ziggurat_host_init.", peProblem(&.{}, &imports, &buf).?);
    try testing.expectEqualStrings("The export library exports answer; it may export only ziggurat_host_init.", peProblem(&.{"answer"}, &.{}, &buf).?);
    // A real DLL that exports other names (`answer`, `answer_pid`, and
    // `DllMainCRTStartup`, which the linker exports from a DLL built
    // without libc).
    const dll = try std.Io.Dir.cwd().readFileAlloc(testing.io, build_options.answer_dll, testing.allocator, .unlimited);
    defer testing.allocator.free(dll);
    const refused = (try checkLibrary(testing.allocator, .pe, dll, &buf)).?;
    try testing.expect(std.mem.startsWith(u8, refused, "The export library exports "));
    try testing.expect(std.mem.endsWith(u8, refused, "; it may export only ziggurat_host_init."));
    // Not a PE file, or a cut one: errors, never a panic.
    try testing.expectError(error.NotPe, checkLibrary(testing.allocator, .pe, "\x7fELF not a PE file at all, but long enough to have a DOS header field..........", &buf));
    try testing.expectError(error.Truncated, checkLibrary(testing.allocator, .pe, dll[0 .. dll.len / 2], &buf));
}

test "export_build: windows output has no LoadLibrary import" {
    var buf: [256]u8 = undefined;
    const ok = [_]platform.pe.Import{
        imp("KERNEL32.dll", "GetFileInformationByHandle"),
        // Zig's std loads iphlpapi.dll and dnsapi.dll by name for its
        // network functions (ruling in the Task 5 report).
        imp("ntdll.dll", "LdrLoadDll"),
        imp("ntdll.dll", "LdrGetProcedureAddress"),
    };
    try testing.expect(peProblem(&.{"ziggurat_host_init"}, &ok, &buf) == null);
    for ([_][]const u8{ "LoadLibraryA", "LoadLibraryW", "LoadLibraryExA", "LoadLibraryExW", "GetProcAddress" }) |name| {
        const bad = ok ++ [_]platform.pe.Import{imp("KERNEL32.dll", name)};
        const want = try std.fmt.allocPrint(testing.allocator, "The export library imports {s} from KERNEL32.dll; it must load nothing at run time.", .{name});
        defer testing.allocator.free(want);
        try testing.expectEqualStrings(want, peProblem(&.{"ziggurat_host_init"}, &bad, &buf).?);
    }
}

test "export_build: target keys give the triple, format and library name" {
    try testing.expectEqualStrings(pins.export_target, targetTriple("x86_64-linux").?);
    try testing.expectEqualStrings("x86_64-windows-gnu", targetTriple("x86_64-windows").?);
    try testing.expect(targetTriple("aarch64-macos") == null);
    try testing.expectEqual(Format.elf, formatOf("x86_64-linux").?);
    try testing.expectEqual(Format.pe, formatOf("x86_64-windows").?);
    try testing.expect(formatOf("nope") == null);
    try testing.expectEqualStrings("libziggurat_game.so", libFile("x86_64-linux").?);
    try testing.expectEqualStrings("ziggurat_game.dll", libFile("x86_64-windows").?);
    try testing.expect(libFile("aarch64-macos") == null);
}

test "the module-definition file exports only the entry point" {
    try testing.expectEqualStrings("EXPORTS\n    ziggurat_host_init\n", module_definition);
}

test "the empty game root of a Windows export is the hidden generated root" {
    const text = try @import("rootgen.zig").generateRootWith(testing.allocator, .linux, &.{}, build_id, .{ .hidden_exports = true });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(text, @import("empty_root.zig").hidden_text);
}

fn failDelete(_: std.Io, _: []const u8) anyerror!void {
    return error.FileBusy;
}

fn failRename(_: std.Io, _: []const u8, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

test "export: an old game library held open is renamed aside" {
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ziggurat_game.dll", .data = "old library" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const lib = try std.fs.path.join(a, &.{ dir, "ziggurat_game.dll" });
    defer a.free(lib);

    // Windows refuses to delete a DLL another process has loaded, but lets
    // it be renamed. Linux cannot hold such a lock, so the delete fails here
    // by injection.
    const r = try removeOldLibrary(a, io, lib, .{ .delete = failDelete });
    defer r.deinit(a);
    const aside = switch (r) {
        .renamed => |p| p,
        else => return error.NotRenamed,
    };
    try testing.expectEqualStrings(dir, std.fs.path.dirname(aside).?);
    const base = std.fs.path.basename(aside);
    try testing.expect(isRenamedLibrary("ziggurat_game.dll", base));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "ziggurat_game.dll", .{}));
    const kept = try tmp.dir.readFileAlloc(io, base, a, .limited(64));
    defer a.free(kept);
    try testing.expectEqualStrings("old library", kept);
    // The next export's sweep deletes it.
    sweepRenamedLibraries(io, dir, "ziggurat_game.dll");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, base, .{}));
}

test "export: an old game library that cannot be renamed fails with the sentence" {
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ziggurat_game.dll", .data = "old library" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const lib = try std.fs.path.join(a, &.{ dir, "ziggurat_game.dll" });
    defer a.free(lib);
    const r = try removeOldLibrary(a, io, lib, .{ .delete = failDelete, .rename = failRename });
    defer r.deinit(a);
    const sentence = switch (r) {
        .stays => |s| s,
        else => return error.NotRefused,
    };
    const want = try std.fmt.allocPrint(a, "Ziggurat cannot replace the old game library {s}: FileBusy (renaming it aside failed: AccessDenied). Close programs that use it and export again.", .{lib});
    defer a.free(want);
    try testing.expectEqualStrings(want, sentence);
    // Nothing moved.
    _ = try tmp.dir.statFile(io, "ziggurat_game.dll", .{});
}

test "export: no old game library, or one that deletes, is gone" {
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const lib = try std.fs.path.join(a, &.{ dir, "ziggurat_game.dll" });
    defer a.free(lib);
    const none = try removeOldLibrary(a, io, lib, .{});
    try testing.expect(none == .gone);
    try tmp.dir.writeFile(io, .{ .sub_path = "ziggurat_game.dll", .data = "old library" });
    const del = try removeOldLibrary(a, io, lib, .{});
    try testing.expect(del == .gone);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "ziggurat_game.dll", .{}));
}

test "export: the next export deletes the renamed libraries, and nothing else" {
    const io = testing.io;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const keep = [_][]const u8{ "ziggurat_game.dll", "ziggurat_game.dll.old-0123", "ziggurat_game.dll.old-0123456789abcdeg", "other.dll.old-0123456789abcdef", "ziggurat_game.dll.old-0123456789abcdef0" };
    const gone = [_][]const u8{ "ziggurat_game.dll.old-0123456789abcdef", "ziggurat_game.dll.old-ffffffffffffffff" };
    for (keep ++ gone) |n| try tmp.dir.writeFile(io, .{ .sub_path = n, .data = "x" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    sweepRenamedLibraries(io, dir, "ziggurat_game.dll");
    for (keep) |n| _ = try tmp.dir.statFile(io, n, .{});
    // Uppercase hex is not a name the rename writes. (Not a file here: on a
    // case-insensitive file system it would be the same file as a
    // lowercase name.)
    try testing.expect(!isRenamedLibrary("ziggurat_game.dll", "ziggurat_game.dll.old-0123456789ABCDEF"));
    for (gone) |n| try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, n, .{}));
    // A missing folder is no error.
    const missing = try std.fs.path.join(a, &.{ dir, "missing" });
    defer a.free(missing);
    sweepRenamedLibraries(io, missing, "ziggurat_game.dll");
}

test "sdkMismatchMessage names the manifest, both versions and the advice" {
    const a = testing.allocator;
    const set = try sdkMismatchMessage(a, "x86_64-linux/libziggurat_host_export.a", "/dev/sdk/sdk-manifest.json", "9.9.9", "0.1.0", true);
    defer a.free(set);
    try testing.expectEqualStrings("Ziggurat cannot export: the SDK at /dev/sdk/sdk-manifest.json is version 9.9.9, but this add-on's export library (addons/ziggurat/bin/x86_64-linux/libziggurat_host_export.a) needs SDK version 0.1.0. Clear the project setting ziggurat/dev/sdk_manifest, or install the add-on that matches the SDK.", set);
    const shipped = try sdkMismatchMessage(a, "x86_64-windows/ziggurat_host_export.lib", "/p/addons/ziggurat/sdk/x86_64-windows/sdk-manifest.json", "0.2.0", "0.1.0", false);
    defer a.free(shipped);
    try testing.expectEqualStrings("Ziggurat cannot export: the SDK at /p/addons/ziggurat/sdk/x86_64-windows/sdk-manifest.json is version 0.2.0, but this add-on's export library (addons/ziggurat/bin/x86_64-windows/ziggurat_host_export.lib) needs SDK version 0.1.0. Reinstall the add-on.", shipped);
}
