//! Build workspace (L2): the per-project cache folder, the build lock, the
//! generated root file (in the project, or in a mirror copy when the project
//! folder is read-only), the compiler command line, and the map from
//! compiler-reported paths back to project-relative paths.
//!
//! Layout under `<cache>/projects/<projectId>/`:
//!   build.lock   held exclusively by a `Workspace` until `deinit`
//!   build/       the compiler's working folder
//!   zig-cache/   the compiler's cache folder
//!   mirror/      copy of the scanned `.zig` files and the root (read-only projects only)
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const scan_mod = @import("scan.zig");
const rootgen = @import("rootgen.zig");
const OsPath = platform.path.OsPath;
const PathService = platform.path.PathService;
const FileLock = platform.lock.FileLock;
const ZigInstall = platform.zig_locator.ZigInstall;
const ScanResult = scan_mod.ScanResult;

pub const ModuleDep = struct {
    name: []const u8,
    root: OsPath,
    /// Names of the modules this module imports (each needs its own entry in the SDK list).
    deps: []const []const u8,
};

pub const BuildMode = struct {
    incremental: bool,
    use_llvm: bool,
    optimize: std.builtin.OptimizeMode,
};

pub const PrepareOptions = struct {
    lock_timeout_ms: u32 = 30000,
    /// The build id written into the generated root; null: the scan's id.
    build_id: ?[]const u8 = null,
    /// `rootgen.RootOptions.hidden_exports`: a Windows export build.
    hidden_exports: bool = false,
};

/// Godot's entry point in the export host archive: the one symbol an
/// exported game's library exports (`export_build` checks it).
pub const entry_symbol = "ziggurat_host_init";

/// What `Workspace.exportArgv` adds for an exported game's library: one
/// shared library of the scripts and the export host archive.
pub const ExportLink = struct {
    /// `-target` value for every module, e.g. `platform.pins.export_target`.
    target: []const u8,
    /// The object format of `target`.
    format: Format = .elf,
    /// The export host archive (`libziggurat_host_export.a`, or
    /// `ziggurat_host_export.lib` on Windows).
    host_archive: OsPath,
    /// The file that limits the exports to `ziggurat_host_init`: a linker
    /// version script for ELF (`--version-script`), a module-definition
    /// file (`.def`, given as an input) for PE.
    exports_file: OsPath,
    /// Library name: the compiler writes `lib<name>.so` (ELF) or
    /// `<name>.dll` (PE).
    name: []const u8,
    /// `-fstrip`: no debug information, so the bytes do not depend on the
    /// project's folder. False gives `-fno-strip` (a debug export): the
    /// library keeps its debug information, with absolute paths.
    strip: bool = true,
};

/// The object format of an export target.
pub const Format = enum { elf, pe };

pub const Workspace = struct {
    cache_dir: OsPath,
    build_dir: OsPath,
    /// Where the generated root and the scripts are read from: the project folder,
    /// or `<cache_dir>/mirror` when `mirrored`.
    source_root: OsPath,
    /// Realpath of `source_root` when it differs (a symlinked project folder);
    /// the compiler may report paths in either form.
    source_real: ?OsPath = null,
    mirrored: bool,
    os: std.Target.Os.Tag,
    /// Borrowed from the caller of `prepare`; it must outlive the workspace.
    sdk: []const ModuleDep,
    lock: FileLock,

    pub fn deinit(self: *Workspace, a: std.mem.Allocator) void {
        self.lock.release();
        a.free(self.cache_dir.bytes);
        a.free(self.build_dir.bytes);
        a.free(self.source_root.bytes);
        if (self.source_real) |r| a.free(r.bytes);
        self.* = undefined;
    }

    /// The editor build's reference-trace depth (`argv`).
    pub const reference_trace_flag = "-freference-trace=16";

    /// The compiler command line; run it with `build_dir` as the working folder.
    /// Free with `freeArgv`, or use an arena.
    pub fn argv(self: Workspace, a: std.mem.Allocator, zig: ZigInstall, mode: BuildMode) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer freeArgv(a, out.items);
        try push(a, &out, "{s}", .{zig.exe.bytes});
        try push(a, &out, "build-lib", .{});
        try push(a, &out, "-dynamic", .{});
        try push(a, &out, "-lc", .{});
        if (mode.use_llvm) try push(a, &out, "-fllvm", .{}) else try push(a, &out, "-fno-llvm", .{});
        if (mode.incremental) try push(a, &out, "-fincremental", .{});
        // Up to 16 frames of reference trace (the compiler keeps 2 by
        // default): the diagnostics map an error outside the project to
        // its first frame in a project file, such as the script line that
        // names a withheld helper deep inside other code (spec risk 24).
        // Measured at 300 scripts: no change in the median body edit.
        try push(a, &out, reference_trace_flag, .{});
        try self.pushOutput(a, &out, "zmod");
        // `-O` is a per-module option: each `-M` gets its own, so no module
        // depends on how the compiler fills in a missing one.
        try self.pushModules(a, &out, &.{optFlag(mode.optimize)});
        return out.toOwnedSlice(a);
    }

    /// The compiler command line of an exported game's library (spec
    /// section 10): the generated root and the SDK compiled for
    /// `link.target`, non-incremental, LLVM, ReleaseSafe, without debug
    /// information unless `link.strip` is false (it holds absolute paths, so
    /// the same project in two folders would give different bytes), linked with the export host
    /// archive into one shared library that exports only
    /// `ziggurat_host_init`. Run it with `build_dir` as the working folder.
    /// Free with `freeArgv`, or use an arena.
    pub fn exportArgv(self: Workspace, a: std.mem.Allocator, zig: ZigInstall, link: ExportLink) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer freeArgv(a, out.items);
        try push(a, &out, "{s}", .{zig.exe.bytes});
        try push(a, &out, "build-lib", .{});
        try push(a, &out, "-dynamic", .{});
        try push(a, &out, "-lc", .{});
        try push(a, &out, "-fllvm", .{});
        try self.pushOutput(a, &out, link.name);
        switch (link.format) {
            .elf => {
                try push(a, &out, "--version-script", .{});
                try push(a, &out, "{s}", .{link.exports_file.bytes});
            },
            // The compiler takes a `.def` file as an input and hands it to
            // the COFF linker; there is no version script on PE.
            .pe => try push(a, &out, "{s}", .{link.exports_file.bytes}),
        }
        // Nothing in the scripts refers to Godot's entry point, so the
        // archive member that defines it is pulled in by name.
        try push(a, &out, "--force_undefined", .{});
        try push(a, &out, entry_symbol, .{});
        try push(a, &out, "{s}", .{link.host_archive.bytes});
        // `-target`, `-O` and `-fstrip` are per-module options.
        try self.pushModules(a, &out, &.{ "-target", link.target, optFlag(.ReleaseSafe), if (link.strip) "-fstrip" else "-fno-strip" });
        return out.toOwnedSlice(a);
    }

    fn pushOutput(self: Workspace, a: std.mem.Allocator, out: *std.ArrayList([]const u8), name: []const u8) !void {
        const zig_cache = try platform.path.joinFor(self.os, a, self.cache_dir, &.{"zig-cache"});
        defer a.free(zig_cache.bytes);
        try push(a, out, "--name", .{});
        try push(a, out, "{s}", .{name});
        try push(a, out, "--cache-dir", .{});
        try push(a, out, "{s}", .{zig_cache.bytes});
        try push(a, out, "--listen=-", .{});
    }

    /// The root module, then every SDK module, each preceded by `per_module`.
    fn pushModules(self: Workspace, a: std.mem.Allocator, out: *std.ArrayList([]const u8), per_module: []const []const u8) !void {
        const root = try platform.path.joinFor(self.os, a, self.source_root, &.{rootgen.root_file_name});
        defer a.free(root.bytes);
        for (per_module) |f| try push(a, out, "{s}", .{f});
        try push(a, out, "--dep", .{});
        try push(a, out, "ziggurat", .{});
        try push(a, out, "-Mroot={s}", .{root.bytes});
        for (self.sdk) |m| {
            for (per_module) |f| try push(a, out, "{s}", .{f});
            for (m.deps) |d| {
                try push(a, out, "--dep", .{});
                try push(a, out, "{s}", .{d});
            }
            try push(a, out, "-M{s}={s}", .{ m.name, m.root.bytes });
        }
    }

    pub fn freeArgv(a: std.mem.Allocator, v: []const []const u8) void {
        for (v) |item| a.free(item);
        a.free(v);
    }

    /// Turns a compiler-reported path (absolute, or relative to `build_dir`)
    /// into a project-relative path with `/` separators. `error.OutsideProject`
    /// for anything not below `source_root` (the SDK, std, the root itself).
    pub fn mapPath(self: Workspace, a: std.mem.Allocator, reported: []const u8) ![]const u8 {
        if (try self.mapUnder(a, self.source_root.bytes, reported)) |r| return r;
        if (self.source_real) |real| {
            if (try self.mapUnder(a, real.bytes, reported)) |r| return r;
        }
        return error.OutsideProject;
    }

    fn mapUnder(self: Workspace, a: std.mem.Allocator, root: []const u8, reported: []const u8) !?[]const u8 {
        var root_parts: std.ArrayList([]const u8) = .empty;
        defer root_parts.deinit(a);
        try normalize(a, self.os, &root_parts, root);

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(a);
        if (!isAbsoluteFor(self.os, reported)) try normalize(a, self.os, &parts, self.build_dir.bytes);
        try normalize(a, self.os, &parts, reported);

        if (parts.items.len <= root_parts.items.len) return null;
        for (root_parts.items, parts.items[0..root_parts.items.len]) |r, p| {
            if (!partEql(self.os, r, p)) return null;
        }
        return try std.mem.join(a, "/", parts.items[root_parts.items.len..]);
    }
};

fn optFlag(mode: std.builtin.OptimizeMode) []const u8 {
    return switch (mode) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        .ReleaseFast => "-OReleaseFast",
        .ReleaseSmall => "-OReleaseSmall",
    };
}

fn push(a: std.mem.Allocator, out: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
    const item = try std.fmt.allocPrint(a, fmt, args);
    errdefer a.free(item);
    try out.append(a, item);
}

fn isSepFor(os: std.Target.Os.Tag, c: u8) bool {
    return c == '/' or (os == .windows and c == '\\');
}

fn isAbsoluteFor(os: std.Target.Os.Tag, p: []const u8) bool {
    if (p.len == 0) return false;
    if (isSepFor(os, p[0])) return true;
    return os == .windows and p.len >= 2 and p[1] == ':';
}

fn partEql(os: std.Target.Os.Tag, x: []const u8, y: []const u8) bool {
    return if (os == .windows) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
}

/// Appends the components of `p` to `parts`, resolving `.` and `..` lexically.
/// `..` at the top is dropped.
fn normalize(a: std.mem.Allocator, os: std.Target.Os.Tag, parts: *std.ArrayList([]const u8), p: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= p.len) : (i += 1) {
        if (i < p.len and !isSepFor(os, p[i])) continue;
        const part = p[start..i];
        start = i + 1;
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(a, part);
    }
}

fn isReadOnlyError(err: anyerror) bool {
    return err == error.AccessDenied or err == error.PermissionDenied or err == error.ReadOnlyFileSystem;
}

/// Writes `data` to `sub` under `dir` only when the bytes differ from what is
/// there, through `<sub>.tmp` and a rename so readers never see half a file.
/// Returns true when it wrote.
fn writeIfChanged(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8, data: []const u8) !bool {
    if (dir.readFileAlloc(io, sub, a, .limited(max_file_bytes))) |old| {
        defer a.free(old);
        if (std.mem.eql(u8, old, data)) return false;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{sub});
    defer a.free(tmp);
    errdefer dir.deleteFile(io, tmp) catch {};
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    try dir.rename(tmp, dir, sub, io);
    return true;
}

const max_file_bytes = 16 * 1024 * 1024;

pub fn prepare(
    a: std.mem.Allocator,
    io: std.Io,
    ps: PathService,
    scan: ScanResult,
    sdk: []const ModuleDep,
    opts: PrepareOptions,
    msg: *std.ArrayList(u8),
) !Workspace {
    const cache_root = try ps.dir(.cache, a);
    defer a.free(cache_root.bytes);
    return prepareIn(a, io, ps, cache_root, scan, sdk, opts, msg);
}

/// `prepare` with the per-user cache folder given: the workspace is
/// `<cache_root>/projects/<ps.projectId()>/`. `ps.env` is read only for its
/// `os`.
pub fn prepareIn(
    a: std.mem.Allocator,
    io: std.Io,
    ps: PathService,
    cache_root: OsPath,
    scan: ScanResult,
    sdk: []const ModuleDep,
    opts: PrepareOptions,
    msg: *std.ArrayList(u8),
) !Workspace {
    const os = ps.env.os;
    const cwd = std.Io.Dir.cwd();
    const id = ps.projectId();
    const cache_dir = try platform.path.joinFor(os, a, cache_root, &.{ "projects", &id });
    errdefer a.free(cache_dir.bytes);
    const build_dir = try platform.path.joinFor(os, a, cache_dir, &.{"build"});
    errdefer a.free(build_dir.bytes);
    try cwd.createDirPath(io, build_dir.bytes);

    const lock_path = try platform.path.joinFor(os, a, cache_dir, &.{"build.lock"});
    defer a.free(lock_path.bytes);
    var lock = FileLock.acquire(io, lock_path, .exclusive, opts.lock_timeout_ms) catch |err| {
        if (err == error.Timeout) {
            msg.clearRetainingCapacity();
            try msg.print(a, "Another editor is building this project (lock: {s}).", .{lock_path.bytes});
        }
        return err;
    };
    errdefer lock.release();

    const root_text = try rootgen.generateRootWith(a, os, scan.scripts, opts.build_id orelse &scan.build_id, .{ .hidden_exports = opts.hidden_exports });
    defer a.free(root_text);

    var mirrored = false;
    {
        var pdir = try cwd.openDir(io, ps.roots.project.bytes, .{});
        defer pdir.close(io);
        // The write is the read-only probe.
        if (writeIfChanged(a, io, pdir, rootgen.root_file_name, root_text)) |_| {} else |err| {
            if (!isReadOnlyError(err)) return err;
            mirrored = true;
        }
    }
    const source_root: OsPath = if (mirrored)
        try platform.path.joinFor(os, a, cache_dir, &.{"mirror"})
    else
        .{ .bytes = try a.dupe(u8, ps.roots.project.bytes) };
    errdefer a.free(source_root.bytes);
    if (mirrored) try syncMirror(a, io, ps.roots.project, source_root, scan, root_text);
    const source_real: ?OsPath = blk: {
        const real = cwd.realPathFileAlloc(io, source_root.bytes, a) catch break :blk null;
        defer a.free(real);
        if (std.mem.eql(u8, real, source_root.bytes)) break :blk null;
        break :blk .{ .bytes = try a.dupe(u8, real) };
    };
    errdefer if (source_real) |r| a.free(r.bytes);
    return .{
        .cache_dir = cache_dir,
        .build_dir = build_dir,
        .source_root = source_root,
        .source_real = source_real,
        .mirrored = mirrored,
        .os = os,
        .sdk = sdk,
        .lock = lock,
    };
}

/// Makes `mirror` hold exactly the root and every scanned `.zig` file, copying
/// only files whose bytes differ.
fn syncMirror(a: std.mem.Allocator, io: std.Io, project: OsPath, mirror: OsPath, scan: ScanResult, root_text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const scan_mod.Script{ scan.scripts, scan.helper_paths }) |list| {
        for (list) |sc| try checkRel(sc.rel);
    }
    try cwd.createDirPath(io, mirror.bytes);
    var mdir = try cwd.openDir(io, mirror.bytes, .{ .iterate = true });
    defer mdir.close(io);
    var pdir = try cwd.openDir(io, project.bytes, .{});
    defer pdir.close(io);

    var keep: std.StringHashMapUnmanaged(void) = .empty;
    defer keep.deinit(a);
    try keep.put(a, rootgen.root_file_name, {});
    _ = try writeIfChanged(a, io, mdir, rootgen.root_file_name, root_text);

    for ([_][]const scan_mod.Script{ scan.scripts, scan.helper_paths }) |list| {
        for (list) |sc| {
            try keep.put(a, sc.rel, {});
            const data = try pdir.readFileAlloc(io, sc.rel, a, .limited(max_file_bytes));
            defer a.free(data);
            if (std.fs.path.dirname(sc.rel)) |d| try mdir.createDirPath(io, d);
            _ = try writeIfChanged(a, io, mdir, sc.rel, data);
        }
    }

    // Remove what the scan no longer lists, then folders that became empty.
    var stale: std.ArrayList([]const u8) = .empty;
    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (stale.items) |x| a.free(x);
        for (dirs.items) |x| a.free(x);
        stale.deinit(a);
        dirs.deinit(a);
    }
    var walker = try mdir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        // Mirror paths are written with `/`; the walker reports the host separator.
        const rel = try a.dupe(u8, e.path);
        errdefer a.free(rel);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, rel, '\\', '/');
        if (e.kind == .directory) {
            try dirs.append(a, rel);
        } else if (keep.contains(rel)) {
            a.free(rel);
        } else {
            try stale.append(a, rel);
        }
    }
    for (stale.items) |rel| mdir.deleteFile(io, rel) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    // Deepest first, so a parent is empty by the time it is tried.
    std.mem.sort([]const u8, dirs.items, {}, deeperFirst);
    for (dirs.items) |rel| mdir.deleteDir(io, rel) catch |err| switch (err) {
        error.DirNotEmpty, error.FileNotFound => {},
        else => return err,
    };
}

/// A scanned path must stay inside the project and the mirror.
fn checkRel(rel: []const u8) !void {
    if (rel.len == 0 or rel[0] == '/' or rel[0] == '\\' or (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, rel, ':') != null)) return error.InvalidPath;
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
}

fn deeperFirst(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.count(u8, x, "/") > std.mem.count(u8, y, "/");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    project: OsPath,
    cache_base: []const u8,
    ps: PathService,

    fn init(a: std.mem.Allocator) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "proj");
        try tmp.dir.createDirPath(testing.io, "cache");
        const project = try tmp.dir.realPathFileAlloc(testing.io, "proj", a);
        const cache_base = try tmp.dir.realPathFileAlloc(testing.io, "cache", a);
        const env: platform.path.HostEnv = .{
            .os = builtin.os.tag,
            .home = cache_base,
            .xdg_cache_home = cache_base,
            .local_app_data = cache_base,
        };
        return .{
            .tmp = tmp,
            .project = .fromTrusted(project),
            .cache_base = cache_base,
            .ps = PathService.init(.{ .project = .fromTrusted(project) }, env),
        };
    }

    fn put(self: Fixture, sub: []const u8, data: []const u8) !void {
        var proj = try self.tmp.dir.openDir(testing.io, "proj", .{});
        defer proj.close(testing.io);
        if (std.fs.path.dirname(sub)) |d| try proj.createDirPath(testing.io, d);
        try proj.writeFile(testing.io, .{ .sub_path = sub, .data = data });
    }

    fn scan(self: Fixture, a: std.mem.Allocator) !ScanResult {
        return scan_mod.scan(a, testing.io, self.project, scan_mod.default_script_dirs);
    }
};

fn rootMtime(io: std.Io, ws: Workspace, a: std.mem.Allocator) !std.Io.Timestamp {
    const p = try std.fs.path.join(a, &.{ ws.source_root.bytes, rootgen.root_file_name });
    const st = try std.Io.Dir.cwd().statFile(io, p, .{});
    return st.mtime;
}

test "prepare writes root once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    try fx.put("a/x.zig", "pub const extends = \"Node\";\n");
    const sc = try fx.scan(arena);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);

    var ws = try prepare(testing.allocator, testing.io, fx.ps, sc, &.{}, .{}, &msg);
    try testing.expect(!ws.mirrored);
    try testing.expectEqualStrings(fx.project.bytes, ws.source_root.bytes);
    const m1 = try rootMtime(testing.io, ws, arena);
    const want = try rootgen.generateRoot(arena, builtin.os.tag, sc.scripts, &sc.build_id);
    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(arena, &.{ ws.source_root.bytes, rootgen.root_file_name }), arena, .limited(1 << 20));
    try testing.expectEqualStrings(want, got);
    ws.deinit(testing.allocator);

    try testing.io.sleep(.fromMilliseconds(30), .awake);
    var ws2 = try prepare(testing.allocator, testing.io, fx.ps, sc, &.{}, .{}, &msg);
    defer ws2.deinit(testing.allocator);
    const m2 = try rootMtime(testing.io, ws2, arena);
    try testing.expectEqual(m1.nanoseconds, m2.nanoseconds);
    // The build and cache folders exist.
    try std.Io.Dir.cwd().access(testing.io, ws2.build_dir.bytes, .{});
}

test "prepare lock timeout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    try fx.put("a.zig", "pub const extends = \"Node\";\n");
    const sc = try fx.scan(arena);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);

    var ws = try prepare(testing.allocator, testing.io, fx.ps, sc, &.{}, .{}, &msg);
    defer ws.deinit(testing.allocator);
    try testing.expectError(error.Timeout, prepare(testing.allocator, testing.io, fx.ps, sc, &.{}, .{ .lock_timeout_ms = 50 }, &msg));
    const want = try std.fmt.allocPrint(arena, "Another editor is building this project (lock: {s}{c}build.lock).", .{
        ws.cache_dir.bytes, std.fs.path.sep,
    });
    try testing.expectEqualStrings(want, msg.items);
}

fn setMode(path: []const u8, a: std.mem.Allocator, mode: std.c.mode_t) !void {
    const z = try std.mem.concatWithSentinel(a, u8, &.{path}, 0);
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(z, mode));
}

fn skipUnlessReadOnlyWorks() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.geteuid() == 0) return error.SkipZigTest;
}

test "mirror_maps_paths_back" {
    try skipUnlessReadOnlyWorks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    try fx.put("a/x.zig", "pub const extends = \"Node\";\n");
    try fx.put("lib/h.zig", "pub fn f() void {}\n");
    const sc = try fx.scan(arena);
    try setMode(fx.project.bytes, arena, 0o555);
    defer setMode(fx.project.bytes, arena, 0o755) catch {};
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);

    var ws = try prepare(testing.allocator, testing.io, fx.ps, sc, &.{}, .{}, &msg);
    defer ws.deinit(testing.allocator);
    try testing.expect(ws.mirrored);
    const mirror = try std.fs.path.join(arena, &.{ ws.cache_dir.bytes, "mirror" });
    try testing.expectEqualStrings(mirror, ws.source_root.bytes);
    for ([_][]const u8{ "a/x.zig", "lib/h.zig", rootgen.root_file_name }) |f| {
        try std.Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ mirror, f }), .{});
    }

    const abs = try std.fs.path.join(arena, &.{ mirror, "a", "x.zig" });
    const m1 = try ws.mapPath(testing.allocator, abs);
    defer testing.allocator.free(m1);
    try testing.expectEqualStrings("a/x.zig", m1);
    const m2 = try ws.mapPath(testing.allocator, "../mirror/a/x.zig");
    defer testing.allocator.free(m2);
    try testing.expectEqualStrings("a/x.zig", m2);
}

test "mirror resync" {
    try skipUnlessReadOnlyWorks();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    try fx.put("a/x.zig", "pub const extends = \"Node\";\n");
    try fx.put("b/y.zig", "pub const extends = \"Node\";\n");
    try setMode(fx.project.bytes, arena, 0o555);
    defer setMode(fx.project.bytes, arena, 0o755) catch {};
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);

    var ws = try prepare(testing.allocator, testing.io, fx.ps, try fx.scan(arena), &.{}, .{}, &msg);
    const mirror = try arena.dupe(u8, ws.source_root.bytes);
    const y_path = try std.fs.path.join(arena, &.{ mirror, "b", "y.zig" });
    const st1 = try std.Io.Dir.cwd().statFile(testing.io, y_path, .{});
    ws.deinit(testing.allocator);

    // The project root is read-only, but the sub folder `a` is not.
    var proj = try fx.tmp.dir.openDir(testing.io, "proj", .{});
    defer proj.close(testing.io);
    try proj.deleteFile(testing.io, "a/x.zig");

    try testing.io.sleep(.fromMilliseconds(30), .awake);
    var ws2 = try prepare(testing.allocator, testing.io, fx.ps, try fx.scan(arena), &.{}, .{}, &msg);
    defer ws2.deinit(testing.allocator);
    try testing.expect(ws2.mirrored);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ mirror, "a", "x.zig" }), .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ mirror, "a" }), .{}));
    // Unchanged files keep their mtime.
    const st2 = try std.Io.Dir.cwd().statFile(testing.io, y_path, .{});
    try testing.expectEqual(st1.mtime.nanoseconds, st2.mtime.nanoseconds);
}

fn dummyZig() ZigInstall {
    return .{ .exe = .fromTrusted("/opt/zig/zig"), .version = "0.17.0" };
}

test "argv golden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const deps = [_]ModuleDep{.{ .name = "ziggurat", .root = .fromTrusted("/sdk/ziggurat.zig"), .deps = &.{"gdzig"} }};
    const ws: Workspace = .{
        .cache_dir = .fromTrusted("/c/projects/p"),
        .build_dir = .fromTrusted("/c/projects/p/build"),
        .source_root = .fromTrusted("/proj"),
        .mirrored = false,
        .os = builtin.os.tag,
        .sdk = &deps,
        .lock = undefined,
    };
    const inc = try ws.argv(arena, dummyZig(), .{ .incremental = true, .use_llvm = false, .optimize = .Debug });
    const want_inc: []const []const u8 = &.{
        "/opt/zig/zig", "build-lib",                    "-dynamic",   "-lc",     "-fno-llvm", "-fincremental", "-freference-trace=16",            "--name",  "zmod",
        "--cache-dir",  "/c/projects/p/zig-cache",      "--listen=-", "-ODebug", "--dep",     "ziggurat",      "-Mroot=/proj/.ziggurat_root.zig", "-ODebug", "--dep",
        "gdzig",        "-Mziggurat=/sdk/ziggurat.zig",
    };
    try expectArgv(want_inc, inc);
    const full = try ws.argv(arena, dummyZig(), .{ .incremental = false, .use_llvm = true, .optimize = .ReleaseFast });
    const want_full: []const []const u8 = &.{
        "/opt/zig/zig",                 "build-lib",  "-dynamic",      "-lc",   "-fllvm",   "-freference-trace=16",            "--name",        "zmod",  "--cache-dir",
        "/c/projects/p/zig-cache",      "--listen=-", "-OReleaseFast", "--dep", "ziggurat", "-Mroot=/proj/.ziggurat_root.zig", "-OReleaseFast", "--dep", "gdzig",
        "-Mziggurat=/sdk/ziggurat.zig",
    };
    try expectArgv(want_full, full);
}

test "argv repeats optimize" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const deps = [_]ModuleDep{
        .{ .name = "ziggurat", .root = .fromTrusted("/sdk/ziggurat.zig"), .deps = &.{ "gdzig", "sdk_options" } },
        .{ .name = "gdzig", .root = .fromTrusted("/g/gdzig.zig"), .deps = &.{"gdzig"} },
        .{ .name = "sdk_options", .root = .fromTrusted("/o/options.zig"), .deps = &.{} },
    };
    const ws: Workspace = .{
        .cache_dir = .fromTrusted("/c/projects/p"),
        .build_dir = .fromTrusted("/c/projects/p/build"),
        .source_root = .fromTrusted("/proj"),
        .mirrored = false,
        .os = builtin.os.tag,
        .sdk = &deps,
        .lock = undefined,
    };
    const got = try ws.argv(arena, dummyZig(), .{ .incremental = false, .use_llvm = false, .optimize = .Debug });
    const want: []const []const u8 = &.{
        "/opt/zig/zig",            "build-lib",   "-dynamic",                     "-lc",     "-fno-llvm", "-freference-trace=16",            "--name",               "zmod",    "--cache-dir",
        "/c/projects/p/zig-cache", "--listen=-",  "-ODebug",                      "--dep",   "ziggurat",  "-Mroot=/proj/.ziggurat_root.zig", "-ODebug",              "--dep",   "gdzig",
        "--dep",                   "sdk_options", "-Mziggurat=/sdk/ziggurat.zig", "-ODebug", "--dep",     "gdzig",                           "-Mgdzig=/g/gdzig.zig", "-ODebug", "-Msdk_options=/o/options.zig",
    };
    try expectArgv(want, got);
    // Exactly one -O per module, each before that module's -M.
    var o_count: usize = 0;
    var m_count: usize = 0;
    for (got, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "-O")) o_count += 1;
        if (std.mem.startsWith(u8, arg, "-M")) {
            m_count += 1;
            var j = i;
            while (j > 0) : (j -= 1) {
                if (std.mem.startsWith(u8, got[j - 1], "-O")) break;
                try testing.expect(!std.mem.startsWith(u8, got[j - 1], "-M"));
            }
            try testing.expect(j > 0);
        }
    }
    try testing.expectEqual(@as(usize, 4), m_count);
    try testing.expectEqual(m_count, o_count);
}

test "export argv golden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const deps = [_]ModuleDep{
        .{ .name = "ziggurat", .root = .fromTrusted("/sdk/ziggurat.zig"), .deps = &.{"gdzig"} },
        .{ .name = "gdzig", .root = .fromTrusted("/g/gdzig.zig"), .deps = &.{} },
    };
    const ws: Workspace = .{
        .cache_dir = .fromTrusted("/c/projects/p"),
        .build_dir = .fromTrusted("/c/projects/p/build"),
        .source_root = .fromTrusted("/proj"),
        .mirrored = false,
        .os = builtin.os.tag,
        .sdk = &deps,
        .lock = undefined,
    };
    const got = try ws.exportArgv(arena, dummyZig(), .{
        .target = "x86_64-linux-gnu.2.28",
        .host_archive = .fromTrusted("/a/libziggurat_host_export.a"),
        .exports_file = .fromTrusted("/c/projects/p/build/export.map"),
        .name = "ziggurat_game",
    });
    const want: []const []const u8 = &.{
        "/opt/zig/zig",          "build-lib",                       "-dynamic",          "-lc",                          "-fllvm",
        "--name",                "ziggurat_game",                   "--cache-dir",       "/c/projects/p/zig-cache",      "--listen=-",
        "--version-script",      "/c/projects/p/build/export.map",  "--force_undefined", "ziggurat_host_init",           "/a/libziggurat_host_export.a",
        "-target",               "x86_64-linux-gnu.2.28",           "-OReleaseSafe",     "-fstrip",                      "--dep",
        "ziggurat",              "-Mroot=/proj/.ziggurat_root.zig", "-target",           "x86_64-linux-gnu.2.28",        "-OReleaseSafe",
        "-fstrip",               "--dep",                           "gdzig",             "-Mziggurat=/sdk/ziggurat.zig", "-target",
        "x86_64-linux-gnu.2.28", "-OReleaseSafe",                   "-fstrip",           "-Mgdzig=/g/gdzig.zig",
    };
    try expectArgv(want, got);
    // Never incremental.
    for (got) |arg| try testing.expect(!std.mem.eql(u8, arg, "-fincremental"));

    // A debug export: the same, with `-fno-strip` in place of `-fstrip`.
    const debug = try ws.exportArgv(arena, dummyZig(), .{
        .target = "x86_64-linux-gnu.2.28",
        .host_archive = .fromTrusted("/a/libziggurat_host_export.a"),
        .exports_file = .fromTrusted("/c/projects/p/build/export.map"),
        .name = "ziggurat_game",
        .strip = false,
    });
    try testing.expectEqual(want.len, debug.len);
    var no_strip: usize = 0;
    for (want, debug) |w, d| {
        if (std.mem.eql(u8, w, "-fstrip")) {
            try testing.expectEqualStrings("-fno-strip", d);
            no_strip += 1;
        } else try testing.expectEqualStrings(w, d);
    }
    try testing.expectEqual(@as(usize, 3), no_strip);
}

test "export argv golden for a Windows DLL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const deps = [_]ModuleDep{
        .{ .name = "ziggurat", .root = .fromTrusted("/sdk/ziggurat.zig"), .deps = &.{} },
    };
    const ws: Workspace = .{
        .cache_dir = .fromTrusted("/c/projects/p"),
        .build_dir = .fromTrusted("/c/projects/p/build"),
        .source_root = .fromTrusted("/proj"),
        .mirrored = false,
        .os = .linux,
        .sdk = &deps,
        .lock = undefined,
    };
    // No version script: a module-definition file, given as an input.
    const got = try ws.exportArgv(arena, dummyZig(), .{
        .target = "x86_64-windows-gnu",
        .format = .pe,
        .host_archive = .fromTrusted("/a/ziggurat_host_export.lib"),
        .exports_file = .fromTrusted("/c/projects/p/build/export.def"),
        .name = "ziggurat_game",
    });
    const want: []const []const u8 = &.{
        "/opt/zig/zig",                    "build-lib",         "-dynamic",           "-lc",                         "-fllvm",
        "--name",                          "ziggurat_game",     "--cache-dir",        "/c/projects/p/zig-cache",     "--listen=-",
        "/c/projects/p/build/export.def",  "--force_undefined", "ziggurat_host_init", "/a/ziggurat_host_export.lib", "-target",
        "x86_64-windows-gnu",              "-OReleaseSafe",     "-fstrip",            "--dep",                       "ziggurat",
        "-Mroot=/proj/.ziggurat_root.zig", "-target",           "x86_64-windows-gnu", "-OReleaseSafe",               "-fstrip",
        "-Mziggurat=/sdk/ziggurat.zig",
    };
    try expectArgv(want, got);
    for (got) |arg| try testing.expect(!std.mem.eql(u8, arg, "--version-script"));
}

test "prepare writes the given build id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    try fx.put("a/x.zig", "pub const extends = \"Node\";\n");
    const sc = try fx.scan(arena);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    var ws = try prepare(testing.allocator, testing.io, fx.ps, sc, &.{}, .{ .build_id = "export" }, &msg);
    defer ws.deinit(testing.allocator);
    const want = try rootgen.generateRoot(arena, builtin.os.tag, sc.scripts, "export");
    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, try std.fs.path.join(arena, &.{ ws.source_root.bytes, rootgen.root_file_name }), arena, .limited(1 << 20));
    try testing.expectEqualStrings(want, got);
}

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "mapPath outside" {
    const ws: Workspace = .{
        .cache_dir = .fromTrusted("/c/projects/p"),
        .build_dir = .fromTrusted("/c/projects/p/build"),
        .source_root = .fromTrusted("/proj"),
        .mirrored = false,
        .os = .linux,
        .sdk = &.{},
        .lock = undefined,
    };
    const a = testing.allocator;
    try testing.expectError(error.OutsideProject, ws.mapPath(a, "/opt/zig/lib/std/mem.zig"));
    try testing.expectError(error.OutsideProject, ws.mapPath(a, "../../../../x/y.zig"));
    try testing.expectError(error.OutsideProject, ws.mapPath(a, "/project2/a.zig"));
    try testing.expectError(error.OutsideProject, ws.mapPath(a, "/proj"));
    const ok = try ws.mapPath(a, "/proj/./a/../b/c.zig");
    defer a.free(ok);
    try testing.expectEqualStrings("b/c.zig", ok);
}

test "mapPath through a symlinked project" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    try fx.put("a/x.zig", "pub const extends = \"Node\";\n");
    try fx.tmp.dir.symLink(testing.io, "proj", "link", .{ .is_directory = true });
    const link_real_parent = try fx.tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const link_path = try std.fs.path.join(arena, &.{ link_real_parent, "link" });
    const ps = PathService.init(.{ .project = .fromTrusted(link_path) }, fx.ps.env);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    var ws = try prepare(testing.allocator, testing.io, ps, try fx.scan(arena), &.{}, .{}, &msg);
    defer ws.deinit(testing.allocator);
    try testing.expect(ws.source_real != null);
    const m1 = try ws.mapPath(testing.allocator, try std.fs.path.join(arena, &.{ link_path, "a", "x.zig" }));
    defer testing.allocator.free(m1);
    try testing.expectEqualStrings("a/x.zig", m1);
    const m2 = try ws.mapPath(testing.allocator, try std.fs.path.join(arena, &.{ fx.project.bytes, "a", "x.zig" }));
    defer testing.allocator.free(m2);
    try testing.expectEqualStrings("a/x.zig", m2);
}

test "mirror rejects paths that leave the project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    const mirror: OsPath = .fromTrusted(try std.fs.path.join(arena, &.{ fx.cache_base, "m" }));
    for ([_][]const u8{ "../evil.zig", "a/../../evil.zig", "/etc/evil.zig" }) |bad| {
        var scripts = [_]scan_mod.Script{.{ .rel = bad }};
        const sc: ScanResult = .{ .scripts = &scripts, .helpers = 0, .helper_paths = &.{}, .problems = &.{} };
        try testing.expectError(error.InvalidPath, syncMirror(testing.allocator, testing.io, fx.project, mirror, sc, "x"));
    }
    var helpers = [_]scan_mod.Script{.{ .rel = "../h.zig" }};
    const sc2: ScanResult = .{ .scripts = &.{}, .helpers = 1, .helper_paths = &helpers, .problems = &.{} };
    try testing.expectError(error.InvalidPath, syncMirror(testing.allocator, testing.io, fx.project, mirror, sc2, "x"));
    // Nothing was created, in or beside the mirror.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, mirror.bytes, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, try std.fs.path.join(arena, &.{ fx.cache_base, "evil.zig" }), .{}));
}

test "failed prepare releases the lock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fx = try Fixture.init(arena);
    defer fx.tmp.cleanup();
    // A project folder that does not exist: prepare fails after taking the lock.
    const missing = try std.fs.path.join(arena, &.{ fx.cache_base, "no_such_project" });
    const ps = PathService.init(.{ .project = .fromTrusted(missing) }, fx.ps.env);
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(testing.allocator);
    try testing.expectError(error.FileNotFound, prepare(testing.allocator, testing.io, ps, .{ .scripts = &.{}, .helpers = 0, .helper_paths = &.{}, .problems = &.{} }, &.{}, .{}, &msg));

    const cache_root = try ps.dir(.cache, arena);
    const id = ps.projectId();
    const lock_path = try std.fs.path.join(arena, &.{ cache_root.bytes, "projects", &id, "build.lock" });
    var l = try FileLock.acquire(testing.io, .fromTrusted(lock_path), .exclusive, 50);
    l.release();
}
