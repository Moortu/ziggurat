//! The root of the linked fixture module, written as `rootgen.zig` writes
//! a project's generated root (two scripts, sorted by path, build id
//! "export"). build.zig compiles it on its own into an object and links
//! that object with the export host archive into one shared library
//! (`linkedLibrary`), so this file is `@import("root")` for the SDK, as a
//! generated root is.

const ziggurat = @import("ziggurat");

pub const panic = ziggurat.Panic;

pub const s0 = ziggurat.describe(@import("alpha.zig"), "alpha.zig");
pub const s1 = ziggurat.describe(@import("sub/beta.zig"), "sub/beta.zig");

const scripts = ziggurat.scriptList(&.{ &s0, &s1 });
const table = ziggurat.tableOf(scripts, "export");

export fn ziggurat_init(api: *const ziggurat.HostApi, gen: u32) callconv(.c) void {
    ziggurat.moduleInit(api, gen);
}

export fn ziggurat_describe() callconv(.c) *const ziggurat.Table {
    return &table;
}
