//! `ZigguratTestProbe`: a class the host registers only when it is built
//! with `-Dtest_probe` (`host_options.test_probe`), for the host tests. It
//! lets a GDScript check drive the runtime directly (load a staged module,
//! read the name maps) before the editor and game paths that call it exist.
//! The product library has no such class: it would let any script load a
//! library.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const RefCounted = godot.class.RefCounted;

/// The Io the probe loads with.
var threaded: std.Io.Threaded = .init_single_threaded;

pub const ZigguratTestProbe = struct {
    base: *RefCounted,

    pub fn create(allocator: *Allocator) !*ZigguratTestProbe {
        const self = try allocator.create(ZigguratTestProbe);
        self.* = .{ .base = RefCounted.init() };
        self.base.setInstance(ZigguratTestProbe, self);
        return self;
    }

    pub fn destroy(self: *ZigguratTestProbe, allocator: *Allocator) void {
        allocator.destroy(self);
    }

    /// Loads the library at `path` as generation `gen`: "" on success, the
    /// refusal sentence otherwise.
    pub fn loadModule(_: *ZigguratTestProbe, path: String, gen: i64) String {
        var buf: [4096]u8 = undefined;
        const p = path.toUtf8Buf(&buf);
        var diag: [256]u8 = undefined;
        const n = std.math.cast(u32, gen) orelse return .fromLatin1("generation out of range");
        _ = runtime.load(std.heap.c_allocator, threaded.io(), .fromTrusted(p), n, &diag) catch |err| switch (err) {
            error.Refused => return String.fromUtf8(std.mem.sliceTo(&diag, 0)) catch .fromLatin1("refused"),
            error.OutOfMemory => return .fromLatin1("out of memory"),
        };
        return .fromLatin1("");
    }

    /// Calls `HostApi.log` as a module would, from the calling thread.
    pub fn apiLog(_: *ZigguratTestProbe, level: i64, line: String) void {
        var buf: [1024]u8 = undefined;
        const t = line.toUtf8Buf(&buf);
        const lv = std.math.cast(u32, level) orelse return;
        runtime.hostApi().log(lv, t.ptr, t.len);
    }

    /// Calls `HostApi.request_swap` as a module would.
    pub fn apiRequestSwap(_: *ZigguratTestProbe) void {
        runtime.hostApi().request_swap();
    }

    /// The current generation's number, or 0.
    pub fn currentGeneration(_: *ZigguratTestProbe) i64 {
        const g = runtime.current() orelse return 0;
        return g.n;
    }

    /// Times `ziggurat_init` ran for generation `gen` (0 when not loaded).
    pub fn initCalls(_: *ZigguratTestProbe, gen: i64) i64 {
        const n = std.math.cast(u32, gen) orelse return 0;
        const g = runtime.find(n) orelse return 0;
        return g.init_calls;
    }

    /// Script index of `rel` in the current generation, or -1.
    pub fn findScript(_: *ZigguratTestProbe, rel: String) i64 {
        const g = runtime.current() orelse return -1;
        var buf: [1024]u8 = undefined;
        return runtime.findScript(g, rel.toUtf8Buf(&buf)) orelse -1;
    }

    pub fn methodIndex(_: *ZigguratTestProbe, script: i64, name: StringName) i64 {
        const s = scriptNames(script) orelse return -1;
        return s.method(name) orelse -1;
    }

    pub fn propertyIndex(_: *ZigguratTestProbe, script: i64, name: StringName) i64 {
        const s = scriptNames(script) orelse return -1;
        return s.property(name) orelse -1;
    }

    pub fn methodCount(_: *ZigguratTestProbe, script: i64) i64 {
        const d = scriptDesc(script) orelse return 0;
        return d.method_count;
    }

    pub fn methodName(_: *ZigguratTestProbe, script: i64, index: i64) String {
        const d = scriptDesc(script) orelse return .fromLatin1("");
        const i = std.math.cast(u32, index) orelse return .fromLatin1("");
        if (i >= d.method_count) return .fromLatin1("");
        return text(d.methods[i].name);
    }

    pub fn propertyCount(_: *ZigguratTestProbe, script: i64) i64 {
        const d = scriptDesc(script) orelse return 0;
        return d.property_count;
    }

    pub fn propertyName(_: *ZigguratTestProbe, script: i64, index: i64) String {
        const d = scriptDesc(script) orelse return .fromLatin1("");
        const i = std.math.cast(u32, index) orelse return .fromLatin1("");
        if (i >= d.property_count) return .fromLatin1("");
        return text(d.properties[i].name);
    }

    pub fn propertyIsGroup(_: *ZigguratTestProbe, script: i64, index: i64) bool {
        const d = scriptDesc(script) orelse return false;
        const i = std.math.cast(u32, index) orelse return false;
        if (i >= d.property_count) return false;
        return d.properties[i].field_index == abi.no_field;
    }
};

pub const method_names = [_][:0]const u8{
    "load_module",      "current_generation", "init_calls",        "find_script",
    "method_index",     "property_index",     "method_count",      "method_name",
    "property_count",   "property_name",      "property_is_group", "api_log",
    "api_request_swap",
};

fn scriptDesc(script: i64) ?*const abi.ScriptDesc {
    const g = runtime.current() orelse return null;
    const i = std.math.cast(u32, script) orelse return null;
    if (i >= g.table.script_count) return null;
    return &g.table.scripts[i];
}

fn scriptNames(script: i64) ?*const runtime.ScriptNames {
    const g = runtime.current() orelse return null;
    const i = std.math.cast(usize, script) orelse return null;
    if (i >= g.names.len) return null;
    return &g.names[i];
}

fn text(s: abi.Str) String {
    if (s.len == 0) return .fromLatin1("");
    return String.fromUtf8(s.ptr.?[0..s.len]) catch .fromLatin1("");
}
