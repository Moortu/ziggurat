//! The panic probe as a `-lc` dynamic library: the shape of a user module.
//! Loaded by `panic_probe_loader.zig`.
const z = @import("ziggurat");

pub const panic = z.Panic;

export fn probe_init(api: *const z.HostApi, gen: u32) callconv(.c) void {
    z.moduleInit(api, gen);
}

export fn probe_boom() callconv(.c) void {
    @panic("probe");
}
