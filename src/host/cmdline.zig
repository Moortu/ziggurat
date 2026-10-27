//! Which editor runs are not interactive, from the process's own command
//! line. Godot consumes `--import` and `--quit` without keeping them in
//! `OS.get_cmdline_args()` (main/main.cpp, the argument loop before
//! `set_cmdline`), so the host reads the command line the process started
//! with: `/proc/self/cmdline` on Linux (editor_build.zig), on Windows
//! `GetCommandLineW` split by `CommandLineToArgvW` (`windowsArgs`), and on
//! macOS libSystem's `_NSGetArgc`/`_NSGetArgv` (`darwinArgs`).
//! Imports only std.
const std = @import("std");
const builtin = @import("builtin");

/// Command-line arguments of editor runs that are not interactive: an
/// import, an export, the doc tool, API dumps, and `--quit`/`-q` (which
/// quits after the first frame). `--quit-after <n>` keeps an interactive
/// editor (the host tests use it).
pub const non_interactive = [_][]const u8{
    "--import",                 "--doctool",                      "--gdextension-docs",
    "--dump-extension-api",     "--dump-extension-api-with-docs", "--dump-gdextension-interface",
    "--validate-extension-api", "--check-only",                   "--quit",
    "-q",
};

/// True for an argument that makes the run non-interactive
/// (`non_interactive`, or any `--export-*`).
pub fn nonInteractive(arg: []const u8) bool {
    if (std.mem.startsWith(u8, arg, "--export-")) return true;
    for (non_interactive) |want| if (std.mem.eql(u8, arg, want)) return true;
    return false;
}

/// The first non-interactive argument among the NUL-separated arguments
/// `raw` (as `/proc/self/cmdline` holds them), or null. The scan stops at
/// `--` or `++`: Godot hands what follows to the game as user arguments.
pub fn nonInteractiveIn(raw: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "++")) return null;
        if (nonInteractive(arg)) return arg;
    }
    return null;
}

/// Upper bound for `argsFromCommandLine`'s output: Windows allows 32,767
/// UTF-16 units in a command line, and one unit is at most 3 bytes of UTF-8
/// (a NUL separator replaces each separating space).
pub const max_windows_args_bytes = 32768 * 3;

/// This process's arguments on Windows (`GetCommandLineW`), as
/// `argsFromCommandLine` gives them, or null.
pub fn windowsArgs(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    return argsFromCommandLine(GetCommandLineW(), buf);
}

/// Splits the Windows command line `line` with `CommandLineToArgvW` (the
/// rules Godot's own `wmain` gets its arguments by) and writes the
/// arguments into `buf` as UTF-8, NUL-separated like `/proc/self/cmdline`.
/// Null when the split fails or the arguments do not fit `buf`. Windows
/// only.
pub fn argsFromCommandLine(line: [*:0]const u16, buf: []u8) ?[]const u8 {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(line, &argc) orelse return null;
    defer _ = LocalFree(@ptrCast(argv));
    var n: usize = 0;
    for (argv[0..@intCast(argc)], 0..) |arg, i| {
        if (i != 0) {
            if (n >= buf.len) return null;
            buf[n] = 0;
            n += 1;
        }
        const units = std.mem.sliceTo(arg, 0);
        const len = std.unicode.calcWtf8Len(units);
        if (len > buf.len - n) return null;
        n += std.unicode.wtf16LeToWtf8(buf[n..][0..len], units);
    }
    return buf[0..n];
}

/// This process's arguments on macOS (`_NSGetArgc`/`_NSGetArgv`, the
/// `argc`/`argv` the process started with), NUL-separated like
/// `/proc/self/cmdline` (`argsFromArgv`), or null; null on every other OS.
/// Arguments longer than `buf` give null, and the caller reads only
/// Godot's own list. Compiled for macOS, never run there (no Mac tests it).
pub fn darwinArgs(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const argc_ptr = _NSGetArgc() orelse return null;
    const argv_ptr = _NSGetArgv() orelse return null;
    const argv = argv_ptr.* orelse return null;
    const argc = argc_ptr.*;
    if (argc <= 0) return if (argc == 0) buf[0..0] else null;
    return argsFromArgv(argv[0..@intCast(argc)], buf);
}

/// Writes the C arguments `argv` into `buf`, NUL-separated like
/// `/proc/self/cmdline` (without the last NUL). A null entry ends the list.
/// Null when they do not fit `buf`.
pub fn argsFromArgv(argv: []const ?[*:0]const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (argv, 0..) |entry, i| {
        const arg = std.mem.span(entry orelse break);
        if (i != 0) {
            if (n >= buf.len) return null;
            buf[n] = 0;
            n += 1;
        }
        if (arg.len > buf.len - n) return null;
        @memcpy(buf[n..][0..arg.len], arg);
        n += arg.len;
    }
    return buf[0..n];
}

// libSystem (crt_externs.h). Referenced on macOS only.
extern "c" fn _NSGetArgc() ?*c_int;
extern "c" fn _NSGetArgv() ?*?[*]?[*:0]const u8;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "shell32" fn CommandLineToArgvW(line: [*:0]const u16, argc: *c_int) callconv(.winapi) ?[*][*:0]u16;

test "nonInteractiveIn stops at the user arguments" {
    try std.testing.expectEqualStrings("--import", nonInteractiveIn("godot\x00--editor\x00--import\x00").?);
    try std.testing.expectEqualStrings("--export-release", nonInteractiveIn("godot\x00--export-release\x00x").?);
    try std.testing.expect(nonInteractiveIn("godot\x00--editor\x00--quit-after\x005") == null);
    // After `--` or `++` Godot passes the arguments to the game, not the
    // editor, so they do not make the editor non-interactive.
    try std.testing.expect(nonInteractiveIn("godot\x00--editor\x00--\x00--quit") == null);
    try std.testing.expect(nonInteractiveIn("godot\x00-e\x00++\x00-q\x00--import") == null);
}

test "cmdline: --import detection on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var buf: [1024]u8 = undefined;

    const line = L("\"C:\\Program Files\\Godot\\godot.exe\" --path \"C:\\Mein Projekt \u{fc}\" --headless --import");
    const raw = argsFromCommandLine(line, &buf) orelse return error.SplitFailed;
    try std.testing.expectEqualStrings("C:\\Program Files\\Godot\\godot.exe\x00--path\x00C:\\Mein Projekt \u{fc}\x00--headless\x00--import", raw);
    try std.testing.expectEqualStrings("--import", nonInteractiveIn(raw).?);

    // A quoted flag is the flag; a flag inside a quoted path is not.
    try std.testing.expectEqualStrings("--quit", nonInteractiveIn(argsFromCommandLine(L("godot.exe -e \"--quit\""), &buf).?).?);
    try std.testing.expect(nonInteractiveIn(argsFromCommandLine(L("godot.exe --path \"C:\\a --import b\" -e"), &buf).?) == null);
    // User arguments after `--` do not count.
    try std.testing.expect(nonInteractiveIn(argsFromCommandLine(L("godot.exe -e -- --import"), &buf).?) == null);
    // Too small a buffer gives null, not a cut argument.
    var small: [8]u8 = undefined;
    try std.testing.expect(argsFromCommandLine(line, &small) == null);
    // This process's own command line splits.
    try std.testing.expect(windowsArgs(&buf) != null);
}

test "cmdline: the longest Windows command line fits and still shows --import" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // `godot.exe "<32,700 euro signs>" --import`: 3 bytes of UTF-8 per unit.
    var line = try a.alloc(u16, 32768);
    defer a.free(line);
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var n: usize = 0;
    for (L("godot.exe \"")) |c| {
        line[n] = c;
        n += 1;
    }
    const tail = L("\" --import");
    while (n + tail.len < 32767) : (n += 1) line[n] = 0x20ac;
    for (tail) |c| {
        line[n] = c;
        n += 1;
    }
    line[n] = 0;
    const z: [*:0]const u16 = line[0..n :0];
    const buf = try a.alloc(u8, max_windows_args_bytes);
    defer a.free(buf);
    const raw = argsFromCommandLine(z, buf) orelse return error.SplitFailed;
    try std.testing.expectEqualStrings("--import", nonInteractiveIn(raw).?);
}

test "argsFromArgv joins the C arguments like /proc/self/cmdline" {
    var buf: [64]u8 = undefined;
    const argv = [_]?[*:0]const u8{ "godot", "--editor", "--import" };
    try std.testing.expectEqualStrings("godot\x00--editor\x00--import", argsFromArgv(&argv, &buf).?);
    try std.testing.expectEqualStrings("--import", nonInteractiveIn(argsFromArgv(&argv, &buf).?).?);
    try std.testing.expectEqualStrings("", argsFromArgv(&.{}, &buf).?);
    // A null entry ends the list, as in a C argv.
    const short = [_]?[*:0]const u8{ "godot", null, "--import" };
    try std.testing.expectEqualStrings("godot", argsFromArgv(&short, &buf).?);
    // Arguments that do not fit give null, never a cut list.
    var small: [14]u8 = undefined;
    try std.testing.expect(argsFromArgv(&argv, &small) == null);
    var exact: [23]u8 = undefined;
    try std.testing.expectEqualStrings("godot\x00--editor\x00--import", argsFromArgv(&argv, &exact).?);
    var one_short: [22]u8 = undefined;
    try std.testing.expect(argsFromArgv(&argv, &one_short) == null);
}

test "darwinArgs is null off macOS" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var buf: [16]u8 = undefined;
    try std.testing.expect(darwinArgs(&buf) == null);
}
