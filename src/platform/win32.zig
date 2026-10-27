//! The kernel32 functions, types and constants the platform layer calls on
//! Windows, in one place. Only Windows code paths reference them, so other
//! targets never link them. std 0.17 declares none of these.
const std = @import("std");

pub const HANDLE = *anyopaque;
pub const BOOL = c_int;

pub const INFINITE: u32 = 0xffff_ffff;
pub const WAIT_OBJECT_0: u32 = 0;
pub const WAIT_TIMEOUT: u32 = 0x102;

// ---------------------------------------------------------------- errors

pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn FormatMessageW(flags: u32, source: ?*const anyopaque, id: u32, lang: u32, buf: [*]u16, size: u32, args: ?*anyopaque) callconv(.winapi) u32;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------- locks

pub const LOCKFILE_FAIL_IMMEDIATELY: u32 = 0x1;
pub const LOCKFILE_EXCLUSIVE_LOCK: u32 = 0x2;
pub const ERROR_LOCK_VIOLATION: u32 = 33;

pub const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?*anyopaque = null,
};

pub extern "kernel32" fn LockFileEx(file: HANDLE, flags: u32, reserved: u32, len_low: u32, len_high: u32, ov: *OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn UnlockFileEx(file: HANDLE, reserved: u32, len_low: u32, len_high: u32, ov: *OVERLAPPED) callconv(.winapi) BOOL;

// ---------------------------------------------------------------- loader

pub extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?HANDLE, flags: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetProcAddress(module: HANDLE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn FreeLibrary(module: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, len: u32, buf: ?[*]u16, file_part: ?*?[*:0]u16) callconv(.winapi) u32;

/// Paths of this many UTF-16 units or more need the `\\?\` prefix.
const max_path = 260;

/// `p` as a fully qualified UTF-16 path (for `LoadLibraryExW` or
/// `MoveFileExW`), with the
/// `\\?\` (or `\\?\UNC\`) prefix when it is 260 characters or longer.
pub fn fullPath(a: std.mem.Allocator, p: []const u8) ![:0]u16 {
    const in = try std.unicode.wtf8ToWtf16LeAllocZ(a, p);
    defer a.free(in);
    var buf: []u16 = try a.alloc(u16, max_path);
    defer a.free(buf);
    var n = GetFullPathNameW(in.ptr, @intCast(buf.len), buf.ptr, null);
    if (n == 0) return error.BadPath;
    if (n >= buf.len) {
        // `n` is the size needed, with the NUL.
        const bigger = try a.alloc(u16, n);
        a.free(buf);
        buf = bigger;
        n = GetFullPathNameW(in.ptr, @intCast(buf.len), buf.ptr, null);
        if (n == 0 or n >= buf.len) return error.BadPath;
    }
    const full = buf[0..n];
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const prefix: []const u16, const rest: []const u16 = if (full.len < max_path or
        std.mem.startsWith(u16, full, L("\\\\?\\")) or std.mem.startsWith(u16, full, L("\\\\.\\")))
        .{ &.{}, full }
    else if (std.mem.startsWith(u16, full, L("\\\\")))
        .{ L("\\\\?\\UNC\\"), full[2..] }
    else
        .{ L("\\\\?\\"), full };
    const out = try a.allocSentinel(u16, prefix.len + rest.len, 0);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], rest);
    return out;
}

// ---------------------------------------------------------------- rename

pub extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) BOOL;

pub const MoveError = error{ FileNotFound, AccessDenied, FileBusy, PathAlreadyExists, BadPath, Unexpected } || std.mem.Allocator.Error;

/// Renames the file `from` to `to` (both absolute, in one volume) with
/// `MoveFileExW`, which opens the file with delete access only. So a DLL
/// another process has loaded can be renamed, which std's rename (it asks
/// for write access too) cannot. An existing `to` is an error.
pub fn moveFile(a: std.mem.Allocator, from: []const u8, to: []const u8) MoveError!void {
    const from_w = fullPath(a, from) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPath,
    };
    defer a.free(from_w);
    const to_w = fullPath(a, to) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadPath,
    };
    defer a.free(to_w);
    if (MoveFileExW(from_w.ptr, to_w.ptr, 0) != 0) return;
    return switch (GetLastError()) {
        2, 3 => error.FileNotFound, // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
        5 => error.AccessDenied, // ERROR_ACCESS_DENIED
        32 => error.FileBusy, // ERROR_SHARING_VIOLATION
        80, 183 => error.PathAlreadyExists, // ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS
        else => error.Unexpected,
    };
}

// ---------------------------------------------------------------- file identity

pub const FILETIME = extern struct { low: u32, high: u32 };

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    attributes: u32,
    creation_time: FILETIME,
    last_access_time: FILETIME,
    last_write_time: FILETIME,
    volume_serial: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

pub extern "kernel32" fn GetFileInformationByHandle(file: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;

// ---------------------------------------------------------------- processes and jobs

pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
/// `JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation`.
pub const JobObjectExtendedLimitInformation: c_int = 9;

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    per_process_user_time_limit: i64 = 0,
    per_job_user_time_limit: i64 = 0,
    limit_flags: u32 = 0,
    minimum_working_set_size: usize = 0,
    maximum_working_set_size: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};

pub const IO_COUNTERS = extern struct {
    read_operation_count: u64 = 0,
    write_operation_count: u64 = 0,
    other_operation_count: u64 = 0,
    read_transfer_count: u64 = 0,
    write_transfer_count: u64 = 0,
    other_transfer_count: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    basic: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    io: IO_COUNTERS = .{},
    process_memory_limit: usize = 0,
    job_memory_limit: usize = 0,
    peak_process_memory_used: usize = 0,
    peak_job_memory_used: usize = 0,
};

comptime {
    // The x86_64 layout Windows expects.
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144);
}

pub const SYNCHRONIZE: u32 = 0x0010_0000;
pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

pub extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(process: HANDLE, exit_code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) u32;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
pub extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?HANDLE;
