//! Dynamic library loader (L1). The only code in Ziggurat that calls `dlopen`
//! (Linux, macOS) or `LoadLibraryExW` (Windows).
const builtin = @import("builtin");
const impl = switch (builtin.os.tag) {
    .windows => @import("loader_windows.zig"),
    else => @import("loader_posix.zig"),
};

pub const Library = impl.Library;
pub const LoadError = impl.LoadError;
pub const open = impl.open;
pub const lookup = impl.lookup;
pub const close = impl.close;

test {
    if (builtin.os.tag != .windows) _ = @import("loader_posix.zig");
    _ = @import("loader_windows.zig");
}
