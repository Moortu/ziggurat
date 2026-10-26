//! Test DLL for the PE reader and the Windows loader. It exports `answer`
//! (returns 42) and `answer_pid`, and imports `GetCurrentProcessId` from
//! kernel32 by name.

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

export fn answer() callconv(.c) i32 {
    return 42;
}

export fn answer_pid() callconv(.c) u32 {
    return GetCurrentProcessId();
}
