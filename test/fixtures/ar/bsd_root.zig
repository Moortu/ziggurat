//! A two-member static library for the BSD archive test of
//! tools/ar_normalize.zig: this root's object and helper.c's.

extern fn bsd_helper() c_int;

export fn bsd_entry() c_int {
    return bsd_helper() + 1;
}
