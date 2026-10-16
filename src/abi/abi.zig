//! C-ABI layouts shared by the SDK and the host. Every struct here crosses a
//! dlopen boundary, so all of them are `extern` and all function pointers use
//! the C calling convention. Strings are UTF-8 and not NUL-terminated.

const std = @import("std");
const builtin = @import("builtin");

pub const magic: u32 = 0x5A494747; // "ZIGG"
pub const abi_version: u32 = 1;

pub const Str = extern struct {
    ptr: ?[*]const u8,
    len: u32,
};

pub const LogLevel = enum(u32) { info = 0, warning = 1, err = 2 };

pub const HostApi = extern struct {
    size: u32,
    get_proc_address: ?*const anyopaque,
    library: ?*anyopaque,
    alloc: *const fn (gen: u32, size: usize, alignment: u32) callconv(.c) ?*anyopaque,
    free: *const fn (gen: u32, ptr: ?*anyopaque, size: usize, alignment: u32) callconv(.c) void,
    log: *const fn (level: u32, msg: [*]const u8, len: usize) callconv(.c) void,
    request_swap: *const fn () callconv(.c) void,
};

/// Values from `gdextension_interface.h` (GDExtensionCallErrorType).
pub const call_ok: u32 = 0;
pub const call_invalid_method: u32 = 1;
pub const call_invalid_argument: u32 = 2;
pub const call_too_many_arguments: u32 = 3;
pub const call_too_few_arguments: u32 = 4;
pub const call_instance_is_null: u32 = 5;

pub const CallError = extern struct {
    @"error": u32,
    argument: i32,
    expected: i32,
};

pub const FieldDesc = extern struct {
    name: Str,
    type_id: u64,
    offset: u32,
    size: u32,
};

pub const ArgDesc = extern struct {
    name: Str,
    variant_type: u32,
    class_name: Str,
};

/// `field_index` of group entries, which have no backing field.
pub const no_field: u32 = 0xFFFF_FFFF;

pub const PropertyDesc = extern struct {
    name: Str,
    field_index: u32,
    variant_type: u32,
    class_name: Str,
    hint: u32,
    hint_string: Str,
    usage: u32,
};

/// Method name starts with `_`.
pub const method_flag_virtual: u32 = 1;

pub const MethodDesc = extern struct {
    name: Str,
    args: [*]const ArgDesc,
    arg_count: u32,
    ret: ArgDesc,
    flags: u32,
};

pub const SignalDesc = extern struct {
    name: Str,
    args: [*]const ArgDesc,
    arg_count: u32,
};

pub const script_flag_tool: u32 = 1;

pub const ScriptDesc = extern struct {
    path: Str,
    class_name: Str,
    base_class: Str,
    flags: u32,
    layout_hash: u64,
    instance_size: u32,
    instance_align: u32,
    defaults: *const anyopaque,
    fields: [*]const FieldDesc,
    field_count: u32,
    properties: [*]const PropertyDesc,
    property_count: u32,
    methods: [*]const MethodDesc,
    method_count: u32,
    signals: [*]const SignalDesc,
    signal_count: u32,
    create: *const fn (owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque,
    destroy: *const fn (inst: *anyopaque) callconv(.c) void,
    call: *const fn (inst: *anyopaque, method: u32, args: [*]const *const anyopaque, argc: i64, ret: *anyopaque, err: *CallError) callconv(.c) void,
    get: *const fn (inst: *anyopaque, property: u32, ret: *anyopaque) callconv(.c) u8,
    set: *const fn (inst: *anyopaque, property: u32, value: *const anyopaque) callconv(.c) u8,
    get_default: *const fn (property: u32, ret: *anyopaque) callconv(.c) u8,
    notification: *const fn (inst: *anyopaque, what: i32, reversed: u8) callconv(.c) void,
    migrate: ?*const anyopaque,
};

pub const Table = extern struct {
    magic: u32,
    abi_version: u32,
    size: u32,
    layout_stamp: u64,
    sdk_version: Str,
    build_id: Str,
    scripts: [*]const ScriptDesc,
    script_count: u32,
};

/// Build facts mixed into the stamp so host and module agree on more than
/// struct layout.
pub const StampInputs = struct {
    api_json_sha256: []const u8,
    interface_h_sha256: []const u8,
    zig_version: []const u8,
    target: []const u8,
    precision: []const u8,
    sdk_version: []const u8,
};

/// Wyhash (seed 0) over, for each struct above in declaration order, its
/// `@sizeOf`, then every field name, `@offsetOf` and `@typeName` of its type
/// (so a changed function-pointer signature changes the stamp); then each
/// input string preceded by its length as a little-endian u64. Enum values
/// and constants are not hashed; `abi_version` covers those.
pub fn layoutStamp(comptime in: StampInputs) u64 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var h = std.hash.Wyhash.init(0);
        for (.{ Str, HostApi, CallError, FieldDesc, ArgDesc, PropertyDesc, MethodDesc, SignalDesc, ScriptDesc, Table }) |T| {
            hashStruct(&h, T);
        }
        for ([_][]const u8{ in.api_json_sha256, in.interface_h_sha256, in.zig_version, in.target, in.precision, in.sdk_version }) |s| {
            hashInt(&h, s.len);
            h.update(s);
        }
        break :blk h.final();
    };
}

fn hashStruct(h: *std.hash.Wyhash, comptime T: type) void {
    hashInt(h, @sizeOf(T));
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        h.update(name);
        hashInt(h, @offsetOf(T, name));
        h.update(@typeName(FT));
    }
}

fn hashInt(h: *std.hash.Wyhash, v: u64) void {
    const le = std.mem.nativeToLittle(u64, v);
    h.update(std.mem.asBytes(&le));
}

const sample: StampInputs = .{
    .api_json_sha256 = "aa",
    .interface_h_sha256 = "bb",
    .zig_version = builtin.zig_version_string,
    .target = "x86_64-linux",
    .precision = "single",
    .sdk_version = "0.1.0",
};

test "stamp is stable" {
    try std.testing.expectEqual(layoutStamp(sample), layoutStamp(sample));
}

test "stamp changes" {
    const base = comptime layoutStamp(sample);
    inline for (@typeInfo(StampInputs).@"struct".field_names) |name| {
        comptime var changed = sample;
        @field(changed, name) = @field(sample, name) ++ "x";
        try std.testing.expect(layoutStamp(changed) != base);
    }
}

test "stamp changes when bytes move between inputs" {
    comptime var a = sample;
    comptime var b = sample;
    a.target = "ab";
    a.precision = "c";
    b.target = "a";
    b.precision = "bc";
    try std.testing.expect(layoutStamp(a) != layoutStamp(b));
}

test "stamp changes with a function pointer signature" {
    const A = extern struct { f: *const fn (x: u32) callconv(.c) void };
    const B = extern struct { f: *const fn (x: u64) callconv(.c) void };
    const differ = comptime blk: {
        var ha = std.hash.Wyhash.init(0);
        var hb = std.hash.Wyhash.init(0);
        hashStruct(&ha, A);
        hashStruct(&hb, B);
        break :blk ha.final() != hb.final();
    };
    try std.testing.expect(differ);
}

test "layout pinned" {
    // A change to any number below is an ABI change: bump `abi_version` by one
    // and update the numbers together. Pinned for x86_64 only; other targets
    // have different pointer sizes.
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Table));
    try std.testing.expectEqual(@as(usize, 208), @sizeOf(ScriptDesc));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(ScriptDesc, "create"));
}
