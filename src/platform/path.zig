//! Path service (L1). Every path string in Ziggurat is built through here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Os = std.Target.Os.Tag;

/// A path as WTF-8 bytes. Build one with `PathService` functions, or with
/// `fromTrusted` for values that came from the OS or from L4.
/// `fromTrusted` borrows `bytes`; functions that build paths allocate them and
/// the caller frees `bytes`.
pub const OsPath = struct {
    bytes: []const u8,

    pub fn fromTrusted(bytes: []const u8) OsPath {
        return .{ .bytes = bytes };
    }
};

pub const HostEnv = struct {
    os: Os,
    home: ?[]const u8,
    xdg_cache_home: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_data_home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
    app_data: ?[]const u8 = null,
    path: ?[]const u8 = null,

    /// Reads the fields from an environment map. The result borrows from `env`.
    pub fn fromEnviron(os: Os, env: *const std.process.Environ.Map) HostEnv {
        return .{
            .os = os,
            .home = env.get("HOME") orelse if (os == .windows) env.get("USERPROFILE") else null,
            .xdg_cache_home = env.get("XDG_CACHE_HOME"),
            .xdg_config_home = env.get("XDG_CONFIG_HOME"),
            .xdg_data_home = env.get("XDG_DATA_HOME"),
            .local_app_data = env.get("LOCALAPPDATA"),
            .app_data = env.get("APPDATA"),
            .path = env.get("PATH"),
        };
    }
};

pub const ProjectRoots = struct {
    /// Absolute project folder, given by L4.
    project: OsPath,
};

pub const DirKind = enum { cache, config, temp, toolchain };

pub const DirError = error{ NoHomeDirectory, NoLocalAppData, NoAppData };

fn sepFor(os: Os) u8 {
    return if (os == .windows) '\\' else '/';
}

fn isSep(os: Os, c: u8) bool {
    return c == '/' or (os == .windows and c == '\\');
}

/// Joins `parts` onto `base` with the separator of `os`. A part that is empty,
/// `.`, `..`, or contains a separator gives `error.InvalidPathPart`.
pub fn joinFor(os: Os, a: Allocator, base: OsPath, parts: []const []const u8) !OsPath {
    var total: usize = base.bytes.len;
    for (parts) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, ".."))
            return error.InvalidPathPart;
        for (p) |c| if (isSep(os, c)) return error.InvalidPathPart;
        total += p.len + 1;
    }
    var out = try std.ArrayList(u8).initCapacity(a, total);
    errdefer out.deinit(a);
    out.appendSliceAssumeCapacity(base.bytes);
    for (parts) |p| {
        if (out.items.len == 0 or !isSep(os, out.items[out.items.len - 1]))
            out.appendAssumeCapacity(sepFor(os));
        out.appendSliceAssumeCapacity(p);
    }
    return .{ .bytes = try out.toOwnedSlice(a) };
}

/// `joinFor` with the separator of the host this was compiled for.
pub fn join(a: Allocator, base: OsPath, parts: []const []const u8) !OsPath {
    return joinFor(@import("builtin").os.tag, a, base, parts);
}

/// Name of a generation library, written into `buf`.
pub fn libName(buf: []u8, os: Os, stem: []const u8, gen: u32) ![]const u8 {
    return switch (os) {
        .windows => std.fmt.bufPrint(buf, "{s}.{d}.dll", .{ stem, gen }),
        .macos, .ios, .tvos, .watchos, .visionos => std.fmt.bufPrint(buf, "lib{s}.{d}.dylib", .{ stem, gen }),
        else => std.fmt.bufPrint(buf, "lib{s}.{d}.so", .{ stem, gen }),
    };
}

/// Zig string literal (with quotes) for a project-relative path, for use in
/// `@import`. On Windows `\` becomes `/`. Valid UTF-8 above ASCII is kept.
pub fn importLiteral(a: Allocator, os: Os, rel: OsPath) ![]const u8 {
    var tmp: ?[]u8 = null;
    defer if (tmp) |t| a.free(t);
    var src = rel.bytes;
    if (os == .windows) {
        const t = try a.dupe(u8, rel.bytes);
        tmp = t;
        std.mem.replaceScalar(u8, t, '\\', '/');
        src = t;
    }
    return std.fmt.allocPrint(a, "\"{f}\"", .{std.zig.fmtString(src)});
}

pub const PathService = struct {
    roots: ProjectRoots,
    env: HostEnv,

    /// Drops a trailing separator from the project path (the root `/` stays).
    pub fn init(roots: ProjectRoots, env: HostEnv) PathService {
        var r = roots;
        var b = r.project.bytes;
        while (b.len > 1 and isSep(env.os, b[b.len - 1])) b = b[0 .. b.len - 1];
        r.project = .{ .bytes = b };
        return .{ .roots = r, .env = env };
    }

    fn present(v: ?[]const u8) ?[]const u8 {
        const s = v orelse return null;
        return if (s.len == 0) null else s;
    }

    pub fn dir(self: PathService, kind: DirKind, a: Allocator) !OsPath {
        const e = self.env;
        const os = e.os;
        switch (os) {
            .windows => {
                if (kind == .config) {
                    const base = present(e.app_data) orelse return error.NoAppData;
                    return joinFor(os, a, .fromTrusted(base), &.{"ziggurat"});
                }
                const base = present(e.local_app_data) orelse return error.NoLocalAppData;
                return switch (kind) {
                    .cache => joinFor(os, a, .fromTrusted(base), &.{ "ziggurat", "cache" }),
                    .temp => joinFor(os, a, .fromTrusted(base), &.{ "ziggurat", "cache", "tmp" }),
                    .toolchain => joinFor(os, a, .fromTrusted(base), &.{ "ziggurat", "toolchains" }),
                    .config => unreachable,
                };
            },
            .macos => {
                const home = present(e.home) orelse return error.NoHomeDirectory;
                const h: OsPath = .fromTrusted(home);
                return switch (kind) {
                    .cache => joinFor(os, a, h, &.{ "Library", "Caches", "ziggurat" }),
                    .temp => joinFor(os, a, h, &.{ "Library", "Caches", "ziggurat", "tmp" }),
                    .config => joinFor(os, a, h, &.{ "Library", "Application Support", "ziggurat" }),
                    .toolchain => joinFor(os, a, h, &.{ "Library", "Application Support", "ziggurat", "toolchains" }),
                };
            },
            else => {
                const home = present(e.home);
                switch (kind) {
                    .cache, .temp => {
                        const tail: []const []const u8 = if (kind == .cache) &.{"ziggurat"} else &.{ "ziggurat", "tmp" };
                        if (present(e.xdg_cache_home)) |x| return joinFor(os, a, .fromTrusted(x), tail);
                        const h = home orelse return error.NoHomeDirectory;
                        return joinFor(os, a, .fromTrusted(h), if (kind == .cache) &.{ ".cache", "ziggurat" } else &.{ ".cache", "ziggurat", "tmp" });
                    },
                    .config => {
                        if (present(e.xdg_config_home)) |x| return joinFor(os, a, .fromTrusted(x), &.{"ziggurat"});
                        const h = home orelse return error.NoHomeDirectory;
                        return joinFor(os, a, .fromTrusted(h), &.{ ".config", "ziggurat" });
                    },
                    .toolchain => {
                        if (present(e.xdg_data_home)) |x| return joinFor(os, a, .fromTrusted(x), &.{ "ziggurat", "toolchains" });
                        const h = home orelse return error.NoHomeDirectory;
                        return joinFor(os, a, .fromTrusted(h), &.{ ".local", "share", "ziggurat", "toolchains" });
                    },
                }
            },
        }
    }

    /// First 16 lowercase hex characters of the sha256 of the project path.
    pub fn projectId(self: PathService) [16]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.roots.project.bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return hex[0..16].*;
    }
};

fn expectDir(env: HostEnv, kind: DirKind, want: []const u8) !void {
    const a = std.testing.allocator;
    const svc = PathService.init(.{ .project = .fromTrusted("/p") }, env);
    const got = try svc.dir(kind, a);
    defer a.free(got.bytes);
    try std.testing.expectEqualStrings(want, got.bytes);
}

test "dir linux xdg" {
    const env: HostEnv = .{ .os = .linux, .home = "/home/u", .xdg_cache_home = "/c" };
    try expectDir(env, .cache, "/c/ziggurat");
    try expectDir(env, .temp, "/c/ziggurat/tmp");
    try expectDir(env, .config, "/home/u/.config/ziggurat");
    try expectDir(env, .toolchain, "/home/u/.local/share/ziggurat/toolchains");
}

test "dir linux defaults" {
    const env: HostEnv = .{ .os = .linux, .home = "/home/u" };
    try expectDir(env, .cache, "/home/u/.cache/ziggurat");
    try expectDir(env, .temp, "/home/u/.cache/ziggurat/tmp");
}

test "dir windows" {
    const env: HostEnv = .{ .os = .windows, .home = null, .local_app_data = "C:\\Users\\u\\AppData\\Local", .app_data = "C:\\Users\\u\\AppData\\Roaming" };
    try expectDir(env, .cache, "C:\\Users\\u\\AppData\\Local\\ziggurat\\cache");
    try expectDir(env, .temp, "C:\\Users\\u\\AppData\\Local\\ziggurat\\cache\\tmp");
    try expectDir(env, .toolchain, "C:\\Users\\u\\AppData\\Local\\ziggurat\\toolchains");
    try expectDir(env, .config, "C:\\Users\\u\\AppData\\Roaming\\ziggurat");
}

test "dir windows missing" {
    const a = std.testing.allocator;
    const svc = PathService.init(.{ .project = .fromTrusted("C:\\p") }, .{ .os = .windows, .home = null });
    try std.testing.expectError(error.NoLocalAppData, svc.dir(.cache, a));
}

test "dir macos" {
    const env: HostEnv = .{ .os = .macos, .home = "/Users/u" };
    try expectDir(env, .cache, "/Users/u/Library/Caches/ziggurat");
    try expectDir(env, .temp, "/Users/u/Library/Caches/ziggurat/tmp");
    try expectDir(env, .config, "/Users/u/Library/Application Support/ziggurat");
    try expectDir(env, .toolchain, "/Users/u/Library/Application Support/ziggurat/toolchains");
}

test "dir missing home" {
    const a = std.testing.allocator;
    const svc = PathService.init(.{ .project = .fromTrusted("/p") }, .{ .os = .linux, .home = null });
    try std.testing.expectError(error.NoHomeDirectory, svc.dir(.cache, a));
    try std.testing.expectError(error.NoHomeDirectory, svc.dir(.config, a));
}

test "libName" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("libzmod.3.so", try libName(&buf, .linux, "zmod", 3));
    try std.testing.expectEqualStrings("zmod.3.dll", try libName(&buf, .windows, "zmod", 3));
    try std.testing.expectEqualStrings("libzmod.3.dylib", try libName(&buf, .macos, "zmod", 3));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, libName(&tiny, .linux, "zmod", 3));
}

fn expectLit(os: Os, rel: []const u8, want: []const u8) !void {
    const a = std.testing.allocator;
    const got = try importLiteral(a, os, .fromTrusted(rel));
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "importLiteral" {
    try expectLit(.linux, "a/b.zig", "\"a/b.zig\"");
    try expectLit(.linux, "q\"uote/x.zig", "\"q\\\"uote/x.zig\"");
    try expectLit(.linux, "back\\slash/y.zig", "\"back\\\\slash/y.zig\"");
    try expectLit(.linux, "dir ünï/z.zig", "\"dir ünï/z.zig\"");
    try expectLit(.linux, "a\nb.zig", "\"a\\nb.zig\"");
    try expectLit(.windows, "a\\b.zig", "\"a/b.zig\"");
}

test "join" {
    const a = std.testing.allocator;
    const p = try joinFor(.linux, a, .fromTrusted("/a"), &.{ "b", "c.zig" });
    defer a.free(p.bytes);
    try std.testing.expectEqualStrings("/a/b/c.zig", p.bytes);
    const q = try joinFor(.windows, a, .fromTrusted("C:\\a\\"), &.{ "b", "c" });
    defer a.free(q.bytes);
    try std.testing.expectEqualStrings("C:\\a\\b\\c", q.bytes);
    const r = try joinFor(.linux, a, .fromTrusted("/"), &.{"x"});
    defer a.free(r.bytes);
    try std.testing.expectEqualStrings("/x", r.bytes);
    const n = try join(a, .fromTrusted("/a"), &.{"b"});
    defer a.free(n.bytes);
}

test "join rejects bad parts" {
    const a = std.testing.allocator;
    const base: OsPath = .fromTrusted("/a");
    try std.testing.expectError(error.InvalidPathPart, joinFor(.linux, a, base, &.{".."}));
    try std.testing.expectError(error.InvalidPathPart, joinFor(.linux, a, base, &.{"."}));
    try std.testing.expectError(error.InvalidPathPart, joinFor(.linux, a, base, &.{""}));
    try std.testing.expectError(error.InvalidPathPart, joinFor(.linux, a, base, &.{"x/y"}));
    try std.testing.expectError(error.InvalidPathPart, joinFor(.windows, a, base, &.{"x\\y"}));
    // backslash is an ordinary byte on Linux
    const ok = try joinFor(.linux, a, base, &.{"x\\y"});
    a.free(ok.bytes);
}

test "projectId" {
    const env: HostEnv = .{ .os = .linux, .home = "/h" };
    const a = PathService.init(.{ .project = .fromTrusted("/p") }, env);
    const b = PathService.init(.{ .project = .fromTrusted("/p/") }, env);
    const c = PathService.init(.{ .project = .fromTrusted("/q") }, env);
    try std.testing.expectEqualSlices(u8, &a.projectId(), &b.projectId());
    try std.testing.expect(!std.mem.eql(u8, &a.projectId(), &c.projectId()));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("/p", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualSlices(u8, hex[0..16], &a.projectId());
    for (a.projectId()) |ch| try std.testing.expect(std.ascii.isHex(ch) and !std.ascii.isUpper(ch));
}

test "fromEnviron" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/home/u");
    try map.put("XDG_CACHE_HOME", "/c");
    const e = HostEnv.fromEnviron(.linux, &map);
    try std.testing.expectEqualStrings("/home/u", e.home.?);
    try std.testing.expectEqualStrings("/c", e.xdg_cache_home.?);
    try std.testing.expect(e.app_data == null);
}
