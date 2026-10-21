//! C-ABI layouts shared by the SDK and the host. Every struct here crosses a
//! dlopen boundary, so all of them are `extern` and all function pointers use
//! the C calling convention. Strings are UTF-8 and not NUL-terminated.
//!
//! # Host contract
//!
//! A host imports this module (`ziggurat_abi`), never the SDK. What it must
//! do, and what it may rely on, is written here and next to the fields it
//! governs. The SDK's `sdk/wrap.zig` implements the module side.
//!
//! Loading, in this order:
//! 1. Load the library and look up `ziggurat_describe` (`DescribeFn`) and
//!    `ziggurat_init` (`InitFn`).
//!    `ziggurat_describe` may be called before `ziggurat_init`; it runs no
//!    code beyond returning a pointer to static data.
//! 2. Run `validate` on the table with the stamp from `expectedStamp`
//!    (computed from the same `sdk_options` the SDK was built with) before
//!    reading anything else from it. A table that fails is refused whole.
//! 3. Call `ziggurat_init(api, gen)` exactly once, on the main thread, at a
//!    time when Godot can construct objects (the module makes and frees one
//!    RefCounted while it warms its caches), with
//!    a `HostApi` whose `size` is `@sizeOf(HostApi)` and with the
//!    generation number of this load. It returns nothing: a size mismatch
//!    is logged through `api.log` (when the struct reaches that far) and the
//!    module stays uninitialised, which the stamp check in step 2 should
//!    already have ruled out. The module warms its lazy caches here.
//!
//! Instances and calls (see `ScriptDesc` for each function):
//! - `create` and `create_blank` must get the same generation number
//!   `ziggurat_init` got; they return null on refusal (no init yet, another
//!   generation, the allocation failed or was misaligned) and log why.
//! - `destroy`, `call`, `get`, `set`, `notification` and `migrate` take only
//!   a pointer that this descriptor's `create` or `create_blank` returned
//!   and `destroy` has not freed. Calls on one instance must not overlap.
//! - The layout hash of a script is `layoutHash(desc)`, computed by the host
//!   from the validated field list; the module does not carry one.
//! - Methods and properties are addressed by index into the descriptor's
//!   arrays, never by name; property indexes count group entries too.
//! - Everything else the host passes (indexes, argument counts, Variant
//!   contents) is checked by the module and never makes it panic.
//! - Variants the module writes into `ret` are owned by the host, which
//!   destroys them. Variants the host passes in stay the host's.
//!
//! Threads: `HostApi.alloc`, `free` and `log` may be called from any thread
//! (script code in Godot thread groups reaches `ziggurat.allocator` and
//! `ziggurat.log`), so the host must make all three thread-safe.
//!
//! Memory: instance memory comes from `HostApi.alloc` with the instance's
//! generation as tag, at least 1 byte and an alignment of up to 4096. Tag 0
//! is the shared user heap (`ziggurat.allocator`), not tied to a generation.

const std = @import("std");
const builtin = @import("builtin");

pub const magic: u32 = 0x5A494747; // "ZIGG"
pub const abi_version: u32 = 2;

pub const Str = extern struct {
    ptr: ?[*]const u8,
    len: u32,
};

pub const LogLevel = enum(u32) { info = 0, warning = 1, err = 2 };

/// `export fn ziggurat_init(api: *const HostApi, gen: u32) callconv(.c) void`,
/// declared in the generated root (`src/build/rootgen.zig`).
pub const InitFn = *const fn (api: *const HostApi, gen: u32) callconv(.c) void;

/// `export fn ziggurat_describe() callconv(.c) *const Table`, declared in the
/// generated root. Look both up by these names.
pub const DescribeFn = *const fn () callconv(.c) *const Table;
pub const init_symbol = "ziggurat_init";
pub const describe_symbol = "ziggurat_describe";

/// What the host gives `ziggurat_init`. The pointer must stay valid until
/// the library is unloaded; the module keeps it.
pub const HostApi = extern struct {
    /// Must be `@sizeOf(HostApi)`; the module refuses any other value.
    size: u32,
    /// Godot's `GDExtensionInterfaceGetProcAddress`. Null only in test hosts:
    /// the module then never calls into Godot.
    get_proc_address: ?*const anyopaque,
    /// Godot's `GDExtensionClassLibraryPtr` of the host extension.
    library: ?*anyopaque,
    /// Returns memory of at least `size` bytes aligned to `alignment` (a
    /// power of two up to 4096), or null. `gen` tags the memory: an
    /// instance's generation, or 0 for the shared user heap.
    alloc: *const fn (gen: u32, size: usize, alignment: u32) callconv(.c) ?*anyopaque,
    /// Frees memory from `alloc` with the same `gen`, `size` and `alignment`.
    free: *const fn (gen: u32, ptr: ?*anyopaque, size: usize, alignment: u32) callconv(.c) void,
    /// One line of UTF-8 text, not NUL-terminated; `level` is a `LogLevel`.
    /// `alloc`, `free` and `log` must be safe to call from any thread.
    log: *const fn (level: u32, msg: [*]const u8, len: usize) callconv(.c) void,
    /// Asks the host to swap in a newer generation when it next can.
    request_swap: *const fn () callconv(.c) void,
};

/// Values from `gdextension_interface.h` (GDExtensionCallErrorType).
pub const call_ok: u32 = 0;
pub const call_invalid_method: u32 = 1;
pub const call_invalid_argument: u32 = 2;
pub const call_too_many_arguments: u32 = 3;
pub const call_too_few_arguments: u32 = 4;
pub const call_instance_is_null: u32 = 5;

/// Godot's `GDExtensionCallError`, with Godot's meaning for each field:
/// for INVALID_ARGUMENT, `argument` is the bad argument's index and
/// `expected` the Variant type wanted; for TOO_MANY/TOO_FEW_ARGUMENTS,
/// `expected` is the argument count wanted.
pub const CallError = extern struct {
    @"error": u32,
    argument: i32,
    expected: i32,
};

/// How the host may read a field's bytes in the defaults image (and in an
/// instance), for the Inspector's defaults without running module code.
/// Integers and floats are little-endian of the field's `size`; the
/// validator checks that the size fits the kind. For the integer, enum and
/// flags kinds only the low `FieldDesc.bits` bits carry the value (an
/// `enum(u3)` tag or a `packed struct` of 2 bools in one byte): the host
/// masks the rest away, or sign-extends from bit `bits - 1` for the signed
/// kinds, and does not rely on how the compiler filled the unused bits.
/// A one-tag enum and an empty packed struct have size 0 and value 0.
pub const ValueKind = enum(u32) {
    /// The host never reads it: `base` and private (`_`-prefixed) fields.
    none = 0,
    /// One byte, 0 or 1.
    bool = 1,
    /// A two's-complement integer of 1, 2, 4 or 8 bytes.
    int_signed = 2,
    /// An unsigned integer of 1, 2, 4 or 8 bytes.
    int_unsigned = 3,
    /// An IEEE float of 4 or 8 bytes.
    float = 4,
    /// 2 to 16 `f32` (Vector2/3/4, Rect2, Transform2D, Plane, Quaternion,
    /// AABB, Basis, Transform3D, Projection in single precision).
    vector_f32 = 5,
    /// 2 to 4 `i32` (Vector2i/3i/4i, Rect2i).
    vector_i32 = 6,
    /// Four `f32`: r, g, b, a.
    color = 7,
    /// A String, StringName or NodePath field; its default is always empty.
    string_empty = 8,
    /// An object handle; its default is always null.
    object_null = 9,
    /// An enum tag, signed, of 0, 1, 2, 4 or 8 bytes.
    enum_signed = 10,
    /// An enum tag, unsigned, of 0, 1, 2, 4 or 8 bytes.
    enum_unsigned = 11,
    /// A packed struct's backing integer (unsigned) of 0, 1, 2, 4 or 8 bytes.
    flags = 12,
    /// The host must not decode it.
    other = 13,
};

/// One field of the instance struct, `base` and private fields included.
/// Exact type identity (for moving a field between generations) is equal
/// `type_name`, `shape`, `size` and `align`. The validator guarantees that
/// `offset` is a multiple of `align` and that `align` is at most the
/// script's `instance_align`.
pub const FieldDesc = extern struct {
    name: Str,
    /// The Zig type name (`@typeName`), for example `i32` or `player.Mood`,
    /// with Zig's anonymous-type counters removed (`player__struct_785`
    /// becomes `player__struct`): the counter depends on what else the
    /// compiler analysed first, so it is not stable between builds. Two
    /// anonymous types of one parent can then share a name; `shape` tells
    /// them apart.
    type_name: Str,
    /// 0 for types whose name fixes their layout (scalars, pointers, engine
    /// values, SDK handles). For struct, array, union, enum and packed
    /// types, a hash of the inner layout (field or tag names, type names,
    /// offsets or values, recursively), so a type that kept its name but
    /// changed inside is not the same type.
    shape: u64,
    offset: u32,
    size: u32,
    @"align": u32,
    /// A `ValueKind`.
    value_kind: u32,
    /// The logical width in bits of an integer, enum or flags value
    /// (`@bitSizeOf`), at most `8 * size`; 0 for every other kind.
    bits: u32,
};

pub const ArgDesc = extern struct {
    name: Str,
    variant_type: u32,
    class_name: Str,
};

/// `field_index` of group entries, which have no backing field.
pub const no_field: u32 = 0xFFFF_FFFF;

/// `PropertyDesc.usage` bit of a group entry (PROPERTY_USAGE_GROUP). A group
/// entry has `field_index = no_field`; its name is the section label (any
/// UTF-8 text, `/` nests sections) and the empty name ends the group.
pub const usage_group: u32 = 64;

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

/// One script. Variant pointers (`ret`, `args`, `value`) point to Godot
/// Variant storage. A `ret` is uninitialised on entry; once written it is an
/// owned Variant that the host destroys.
pub const ScriptDesc = extern struct {
    /// Project-relative path with `/` separators, unique in the table.
    path: Str,
    /// Global class name, or empty; unique in the table when not empty.
    class_name: Str,
    /// Engine class the script extends, as Godot names it.
    base_class: Str,
    /// `script_flag_tool` when the script runs in the editor.
    flags: u32,
    instance_size: u32,
    instance_align: u32,
    /// An instance with every field at its default value. `base` in it is
    /// undefined (a `*E` cannot be zero at compile time): the host never
    /// reads `base` from it; `create` sets `base` of each new instance from
    /// its `owner`.
    /// Engine values in it (String, StringName, NodePath, Ref) are always
    /// empty, so a byte copy is safe; the host must never destroy them.
    defaults: *const anyopaque,
    fields: [*]const FieldDesc,
    field_count: u32,
    /// Exported fields in source order, with group entries (`usage_group`,
    /// `field_index = no_field`) between them. `get`, `set` and
    /// `get_default` take an index into this array.
    properties: [*]const PropertyDesc,
    property_count: u32,
    /// `call` takes an index into this array.
    methods: [*]const MethodDesc,
    method_count: u32,
    signals: [*]const SignalDesc,
    signal_count: u32,
    /// A new instance owned by the engine object `owner`, or null on
    /// refusal. `gen` must be the generation `ziggurat_init` got. Copies the
    /// defaults, sets `base`, then runs the script's `init`.
    create: *const fn (owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque,
    /// As `create`, without running `init`: for an instance whose fields
    /// the host is about to move in from an older generation. The block is
    /// `max(instance_size, 1)` bytes from `HostApi.alloc` with tag `gen`
    /// and alignment `instance_align`, holding the defaults image and
    /// `base`. A host that abandons a blank block before any module code
    /// used it (a swap rolled back) frees it with `HostApi.free` itself,
    /// with those arguments: the defaults hold no engine value, so there is
    /// nothing to release and no `deinit` to run.
    create_blank: *const fn (owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque,
    /// Runs the script's `deinit`, releases its engine values and frees
    /// `inst`, which must not be used afterwards.
    destroy: *const fn (inst: *anyopaque) callconv(.c) void,
    /// Calls method `method` with `argc` arguments. Always writes `ret`
    /// (NIL on every error) and `err`. `args` may be null when `argc` is 0;
    /// a null `args` with a non-zero `argc` is INVALID_ARGUMENT at 0.
    /// Arguments are borrowed for the call.
    call: *const fn (inst: *anyopaque, method: u32, args: ?[*]const *const anyopaque, argc: i64, ret: *anyopaque, err: *CallError) callconv(.c) void,
    /// 1 and writes `ret` when `property` has a value; 0 and leaves `ret`
    /// alone otherwise (group entries, indexes past the end).
    get: *const fn (inst: *anyopaque, property: u32, ret: *anyopaque) callconv(.c) u8,
    /// 1 when `value` was stored; 0 when the index has no value or `value`
    /// does not convert (the field is then unchanged). `value` is borrowed.
    set: *const fn (inst: *anyopaque, property: u32, value: *const anyopaque) callconv(.c) u8,
    /// As `get`, for the default value; needs no instance.
    get_default: *const fn (property: u32, ret: *anyopaque) callconv(.c) u8,
    /// Passes a Godot notification. `reversed` is ignored: a script is one
    /// class.
    notification: *const fn (inst: *anyopaque, what: i32, reversed: u8) callconv(.c) void,
    /// The script's `migrate` hook, or null. Runs on a new instance (from
    /// `create_blank`, with the fields that kept their exact type already
    /// moved in) with a view of the old instance; it may take more from it
    /// and marks what it took in `prev.moved`. The host cannot check that a
    /// non-null value is a function.
    migrate: ?*const fn (new_inst: *anyopaque, prev: *const PrevView) callconv(.c) void,
};

/// The old instance during a migration: its data and its generation's field
/// list. `moved` has one byte per old field; 1 means its value now belongs
/// to the new instance (the host then resets the old field before the old
/// `destroy`, so the value is not released twice).
pub const PrevView = extern struct {
    data: *const anyopaque,
    fields: [*]const FieldDesc,
    field_count: u32,
    moved: [*]u8,
};

/// The layout hash of a script: Wyhash (seed 0) over `instance_size`,
/// `instance_align`, then for each field in order its name, type name (each
/// preceded by its length), shape and offset. Defaults do not enter it.
/// Equal hashes mean the host may keep an instance's data as it is.
/// Call only on a descriptor that passed `validate`.
pub fn layoutHash(desc: *const ScriptDesc) u64 {
    var h = std.hash.Wyhash.init(0);
    hashInt(&h, desc.instance_size);
    hashInt(&h, desc.instance_align);
    if (desc.field_count > 0) {
        for (desc.fields[0..desc.field_count]) |*f| {
            hashStr(&h, f.name);
            hashStr(&h, f.type_name);
            hashInt(&h, f.shape);
            hashInt(&h, f.offset);
        }
    }
    return h.final();
}

fn hashStr(h: *std.hash.Wyhash, s: Str) void {
    hashInt(h, s.len);
    if (s.len > 0) h.update(s.ptr.?[0..s.len]);
}

/// What `ziggurat_describe` returns: static data, valid until the library
/// is unloaded. Validate it (`validate`) before reading anything else.
pub const Table = extern struct {
    magic: u32,
    abi_version: u32,
    size: u32,
    layout_stamp: u64,
    sdk_version: Str,
    /// The build service's id for this build (16 hex characters); the
    /// service compares it after a fast rebuild to catch stale output.
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

/// The `target` stamp input for `t`: `<arch>-<os>-<abi>` as Zig names them,
/// for example `x86_64-linux-gnu`. The SDK and the host both use this.
pub fn stampTarget(comptime t: std.Target) []const u8 {
    return @tagName(t.cpu.arch) ++ "-" ++ @tagName(t.os.tag) ++ "-" ++ @tagName(t.abi);
}

/// The layout stamp a module built by this compilation carries, and so the
/// stamp a host built by it must expect: `layoutStamp` over `opts` with this
/// compilation's Zig version and `stampTarget(builtin.target)`.
///
/// `opts` is the SDK's `sdk_options` module (pass the namespace itself) or
/// any value with the same fields: `api_json_sha256`, `interface_h_sha256`
/// (byte arrays or strings), `precision` and `sdk_version`. The SDK and a
/// host both call this, so the six stamp inputs are spelled in one place.
pub fn expectedStamp(comptime opts: anytype) u64 {
    return layoutStamp(.{
        .api_json_sha256 = bytesOf(opts.api_json_sha256),
        .interface_h_sha256 = bytesOf(opts.interface_h_sha256),
        .zig_version = builtin.zig_version_string,
        .target = stampTarget(builtin.target),
        .precision = bytesOf(opts.precision),
        .sdk_version = bytesOf(opts.sdk_version),
    });
}

/// A comptime byte array, or anything that coerces to a byte slice, as a slice.
fn bytesOf(comptime v: anytype) []const u8 {
    if (@typeInfo(@TypeOf(v)) == .array) {
        const copy = v;
        return &copy;
    }
    return v;
}

/// Wyhash (seed 0) over, for each struct above in declaration order, its
/// `@sizeOf`, then every field name, `@offsetOf` and `@typeName` of its type
/// (so a changed function-pointer signature changes the stamp); then each
/// input string preceded by its length as a little-endian u64. Enum values
/// and constants are not hashed; `abi_version` covers those.
pub fn layoutStamp(comptime in: StampInputs) u64 {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var h = std.hash.Wyhash.init(0);
        for (.{ Str, HostApi, CallError, FieldDesc, ArgDesc, PropertyDesc, MethodDesc, SignalDesc, ScriptDesc, PrevView, Table }) |T| {
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

test "stampTarget" {
    const t = comptime stampTarget(builtin.target);
    const want = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.abi);
    try std.testing.expectEqualStrings(want, t);
}

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

test "expectedStamp matches layoutStamp with this build's facts" {
    const opts = struct {
        pub const api_json_sha256: [2]u8 = "aa".*;
        pub const interface_h_sha256: [2]u8 = "bb".*;
        pub const precision = "single";
        pub const sdk_version = "0.1.0";
    };
    const want = comptime layoutStamp(.{
        .api_json_sha256 = "aa",
        .interface_h_sha256 = "bb",
        .zig_version = builtin.zig_version_string,
        .target = stampTarget(builtin.target),
        .precision = "single",
        .sdk_version = "0.1.0",
    });
    // A namespace such as the `sdk_options` module, and a struct value.
    try std.testing.expectEqual(want, expectedStamp(opts));
    try std.testing.expectEqual(want, expectedStamp(.{
        .api_json_sha256 = "aa",
        .interface_h_sha256 = "bb",
        .precision = "single",
        .sdk_version = "0.1.0",
    }));
}

const HashTest = struct {
    fn create(_: *anyopaque, _: u32) callconv(.c) ?*anyopaque {
        return null;
    }
    fn destroy(_: *anyopaque) callconv(.c) void {}
    fn call(_: *anyopaque, _: u32, _: ?[*]const *const anyopaque, _: i64, _: *anyopaque, _: *CallError) callconv(.c) void {}
    fn get(_: *anyopaque, _: u32, _: *anyopaque) callconv(.c) u8 {
        return 0;
    }
    fn set(_: *anyopaque, _: u32, _: *const anyopaque) callconv(.c) u8 {
        return 0;
    }
    fn getDefault(_: u32, _: *anyopaque) callconv(.c) u8 {
        return 0;
    }
    fn notification(_: *anyopaque, _: i32, _: u8) callconv(.c) void {}
    var defaults_a: [16]u8 = @splat(0);
    var defaults_b: [16]u8 = @splat(7);

    fn str(s: []const u8) Str {
        return .{ .ptr = s.ptr, .len = @intCast(s.len) };
    }

    fn field(name: []const u8, type_name: []const u8, shape: u64, offset: u32) FieldDesc {
        return .{ .name = str(name), .type_name = str(type_name), .shape = shape, .offset = offset, .size = 4, .@"align" = 4, .value_kind = @backingInt(ValueKind.int_signed), .bits = 32 };
    }

    fn desc(fields: []const FieldDesc, defaults: *const anyopaque) ScriptDesc {
        return .{
            .path = str("a.zig"),
            .class_name = str(""),
            .base_class = str("Node"),
            .flags = 0,
            .instance_size = 16,
            .instance_align = 8,
            .defaults = defaults,
            .fields = fields.ptr,
            .field_count = @intCast(fields.len),
            .properties = undefined,
            .property_count = 0,
            .methods = undefined,
            .method_count = 0,
            .signals = undefined,
            .signal_count = 0,
            .create = &create,
            .create_blank = &create,
            .destroy = &destroy,
            .call = &call,
            .get = &get,
            .set = &set,
            .get_default = &getDefault,
            .notification = &notification,
            .migrate = null,
        };
    }
};

test "layout hash in abi" {
    const T = HashTest;
    const base = [_]FieldDesc{ T.field("hp", "i32", 0, 0), T.field("pos", "script.Pos", 99, 4) };
    // Equal for identical descriptors, also when they live apart and their
    // defaults differ.
    const same = base;
    const h = layoutHash(&T.desc(&base, &T.defaults_a));
    try std.testing.expectEqual(h, layoutHash(&T.desc(&same, &T.defaults_a)));
    try std.testing.expectEqual(h, layoutHash(&T.desc(&same, &T.defaults_b)));

    // A field's type name, shape, order or offset changes it.
    const changed = [_][2]FieldDesc{
        .{ T.field("hp", "u32", 0, 0), base[1] },
        .{ base[0], T.field("pos", "script.Pos", 98, 4) },
        .{ base[1], base[0] },
        .{ base[0], T.field("pos", "script.Pos", 99, 8) },
        .{ T.field("hq", "i32", 0, 0), base[1] },
    };
    for (&changed) |*c| try std.testing.expect(layoutHash(&T.desc(c, &T.defaults_a)) != h);
    // So do the instance size and alignment, and a dropped field.
    var d = T.desc(&base, &T.defaults_a);
    d.instance_size = 24;
    try std.testing.expect(layoutHash(&d) != h);
    d = T.desc(&base, &T.defaults_a);
    d.instance_align = 16;
    try std.testing.expect(layoutHash(&d) != h);
    try std.testing.expect(layoutHash(&T.desc(base[0..1], &T.defaults_a)) != h);
    // Bytes moving between a name and a type name change it.
    const x = [_]FieldDesc{T.field("ab", "c", 0, 0)};
    const y = [_]FieldDesc{T.field("a", "bc", 0, 0)};
    try std.testing.expect(layoutHash(&T.desc(&x, &T.defaults_a)) != layoutHash(&T.desc(&y, &T.defaults_a)));
}

test "value kinds are numbered as the ABI fixes them" {
    try std.testing.expectEqual(@as(u32, 0), @backingInt(ValueKind.none));
    try std.testing.expectEqual(@as(u32, 13), @backingInt(ValueKind.other));
    try std.testing.expectEqual(@as(usize, 14), @typeInfo(ValueKind).@"enum".field_names.len);
}

test "layout pinned" {
    // A change to any number below is an ABI change: bump `abi_version` by one
    // and update the numbers together. Pinned for x86_64 only; other targets
    // have different pointer sizes.
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(Table));
    try std.testing.expectEqual(@as(usize, 208), @sizeOf(ScriptDesc));
    try std.testing.expectEqual(@as(usize, 136), @offsetOf(ScriptDesc, "create"));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(ScriptDesc, "create_blank"));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(FieldDesc));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(FieldDesc, "bits"));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PrevView));
}
