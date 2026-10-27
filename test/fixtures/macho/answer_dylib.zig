//! Test dylib for the Mach-O reader. It exports `answer` (returns 42) and
//! `answer_pid`, and imports `getpid` from libSystem.

extern "c" fn getpid() c_int;

export fn answer() callconv(.c) i32 {
    return 42;
}

export fn answer_pid() callconv(.c) i32 {
    return getpid();
}
