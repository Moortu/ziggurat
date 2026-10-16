//! Compile-time script descriptors (spec section 8).
//!
//! `describe(S, rel)` reads the script struct `S` and builds its
//! `abi.ScriptDesc`: every field, the exported properties (with groups and
//! hints from `meta`), the methods, the signals, the layout hash and the
//! defaults image. Every string and array the descriptor points to is a
//! comptime constant with static lifetime.
//!
//! A mistake in a script is a compile error of one sentence followed by the
//! SDK marker `[ziggurat:<rel>#<name>]` (see `src/build/rootgen.zig`), so the
//! build service reports it on the script's line that declares `<name>`.
//!
//! Godot names: a property is named after its field, a method after
//! `toSnakeCase` of its name, a signal after its declaration; `meta` can
//! override the first two with `.name`. All of them must be distinct, because
//! the host looks them up by name. Group names are labels: any non-empty
//! UTF-8 text (`/` nests sections), and they may repeat.
//!
//! Property order: exported fields in source order. A group entry starts each
//! run of fields with the same `meta` group, and an entry with an empty name
//! ends the group before the next field without one.
//!
//! Hints (as GDScript exports): `.range` gives RANGE; an enum gives ENUM with
//! `"tag:value,..."`; `z.Obj(T)` of a Node class gives NODE_TYPE and
//! `z.Ref(T)` of a Resource class RESOURCE_TYPE, each with the engine class
//! name. Other object handles cannot be exported. `meta` `.hint` and
//! `.hint_string` override all of these.
//!
//! Limit: a field that defaults to `undefined` fails the build, but with Zig's
//! own "use of undefined value" error at this file, not at the script line.
//! Zig 0.17 has no comptime test for `undefined` that does not raise that
//! error. Every scalar, pointer and optional inside the default is compared
//! with itself (arrays and struct fields recursively, padding never read), so
//! all v1 field types are covered; unions and vectors are not looked into.
const std = @import("std");
const abi = @import("ziggurat_abi");
const snake = @import("snake.zig");
const convert = @import("convert.zig");
const object = @import("object.zig");
const godot = @import("gdzig");

/// Usage of an exported field: STORAGE | EDITOR | SCRIPT_VARIABLE, as
/// GDScript sets for script variables.
pub const usage_script_variable: u32 = 2 | 4 | 4096;
pub const hint_none: u32 = 0;
/// PROPERTY_HINT_RANGE; the hint string is `"min,max"` or `"min,max,step"`.
pub const hint_range: u32 = 1;
/// PROPERTY_HINT_ENUM; the hint string is `"Tag:value,..."`.
pub const hint_enum: u32 = 2;
/// PROPERTY_HINT_RESOURCE_TYPE; the hint string is the engine class name.
pub const hint_resource_type: u32 = 17;
/// PROPERTY_HINT_NODE_TYPE; the hint string is the engine class name.
pub const hint_node_type: u32 = 34;

const t_nil: u32 = 0;

const field_meta_keys = [_][]const u8{ "range", "group", "name", "hint", "hint_string" };
const field_meta_list = "range, group, name, hint, hint_string";
const method_meta_keys = [_][]const u8{ "name", "args" };
const method_meta_list = "name, args";
/// `pub fn`s with a script first parameter that are lifecycle hooks, not methods.
const not_methods = [_][]const u8{ "init", "deinit", "migrate" };

/// Marker name used when the declaration's name is not a plain identifier;
/// the decoder then reports the error on line 1.
const unnamed = "ziggurat_unnamed";

/// The descriptor of the script `S` at the project-relative path `rel`.
pub fn describe(comptime S: type, comptime rel: []const u8) abi.ScriptDesc {
    return Script(S, rel).desc;
}

fn Script(comptime S: type, comptime rel: []const u8) type {
    if (@typeInfo(S) != .@"struct")
        @compileError("ziggurat: a script is a struct (a file), found " ++ @typeName(S));
    return struct {
        const info = @typeInfo(S).@"struct";
        const marker_rel = encodeRel(rel);
        /// The comptime work grows with the number of fields, methods and
        /// meta entries; this covers several hundred of each.
        const quota = 200_000 + 20_000 * (info.field_names.len + info.decl_names.len);

        /// A compile error about the declaration `name`.
        fn fail(comptime name: []const u8, comptime sentence: []const u8) noreturn {
            @compileError(sentence ++ " [ziggurat:" ++ marker_rel ++ "#" ++
                (if (isIdentifier(name)) name else unnamed) ++ "]");
        }

        fn isPub(comptime name: []const u8) bool {
            for (info.decl_names) |d| {
                if (eql(d, name)) return true;
            }
            return false;
        }

        fn fieldIndex(comptime name: []const u8) ?usize {
            for (info.field_names, 0..) |f, i| {
                if (eql(f, name)) return i;
            }
            return null;
        }

        fn exported(comptime name: []const u8) bool {
            return !eql(name, "base") and !(name.len > 0 and name[0] == '_');
        }

        // ---- script-level declarations ----

        const Extends: type = blk: {
            if (!isPub("extends"))
                fail("extends", "The script needs 'pub const extends' set to a Godot engine class.");
            const E = S.extends;
            if (@TypeOf(E) != type)
                fail("extends", "extends must be a Godot engine class, found " ++ @typeName(@TypeOf(E)) ++ ".");
            if (!object.isEngineClass(E))
                fail("extends", "extends must be a Godot engine class, found " ++ @typeName(E) ++ ".");
            break :blk E;
        };

        const class_name: []const u8 = blk: {
            if (!isPub("class_name")) break :blk "";
            if (!isString(@TypeOf(S.class_name)))
                fail("class_name", "class_name must be a string.");
            const v: []const u8 = S.class_name;
            if (!isIdentifier(v)) fail("class_name", "class_name '" ++ v ++ "' must be an identifier.");
            break :blk v;
        };

        const tool: bool = blk: {
            if (!isPub("tool")) break :blk false;
            if (@TypeOf(S.tool) != bool) fail("tool", "tool must be true or false.");
            break :blk S.tool;
        };

        const has_meta = isPub("meta");
        const meta = if (has_meta) S.meta else .{};
        const Meta = @TypeOf(meta);

        // ---- methods ----

        fn isMethod(comptime d: []const u8) bool {
            for (not_methods) |n| {
                if (eql(d, n)) return false;
            }
            const T = @TypeOf(@field(S, d));
            if (@typeInfo(T) != .@"fn") return false;
            const f = @typeInfo(T).@"fn";
            if (f.param_types.len == 0) return false;
            const P = f.param_types[0] orelse return false;
            return P == *S or P == *const S;
        }

        const method_decls: []const [:0]const u8 = blk: {
            @setEvalBranchQuota(quota);
            var n: usize = 0;
            for (info.decl_names) |d| {
                if (isMethod(d)) n += 1;
            }
            var out: [n][:0]const u8 = undefined;
            var i: usize = 0;
            for (info.decl_names) |d| {
                if (isMethod(d)) {
                    out[i] = d;
                    i += 1;
                }
            }
            const final = out;
            break :blk &final;
        };

        /// A `pub fn` that takes the script by value would work on a copy.
        fn checkByValue() void {
            for (info.decl_names) |d| {
                const T = @TypeOf(@field(S, d));
                if (@typeInfo(T) != .@"fn") continue;
                const f = @typeInfo(T).@"fn";
                if (f.param_types.len > 0 and f.param_types[0] == S)
                    fail(d, "Method '" ++ d ++ "' takes the script by value; take self as *@This() or *const @This().");
            }
        }

        fn isMethodName(comptime name: []const u8) bool {
            for (method_decls) |d| {
                if (eql(d, name)) return true;
            }
            return false;
        }

        // ---- meta ----

        fn checkEntryKeys(comptime owner: []const u8, comptime E: type, comptime allowed: []const []const u8, comptime list: []const u8) void {
            if (@typeInfo(E) != .@"struct")
                fail(owner, "meta for '" ++ owner ++ "' must be a struct literal such as .{ .name = \"x\" }.");
            for (@typeInfo(E).@"struct".field_names) |k| {
                if (!inList(k, allowed))
                    fail(owner, "meta key '" ++ k ++ "' for '" ++ owner ++ "' is not one of " ++ list ++ ".");
            }
        }

        fn checkMeta() void {
            if (@typeInfo(Meta) != .@"struct")
                fail("meta", "meta must be a struct literal such as .{ .speed = .{ .range = .{ 0, 10 } } }.");
            for (@typeInfo(Meta).@"struct".field_names) |k| {
                const E = @TypeOf(@field(meta, k));
                if (fieldIndex(k) != null) {
                    if (!exported(k)) fail("meta", "meta names '" ++ k ++ "', which is not an exported field.");
                    checkEntryKeys(k, E, &field_meta_keys, field_meta_list);
                } else if (isMethodName(k)) {
                    checkEntryKeys(k, E, &method_meta_keys, method_meta_list);
                } else {
                    fail("meta", "meta names '" ++ k ++ "', which is not a field or method of this script.");
                }
            }
        }

        /// `meta.<owner>.<key>` as a string, or null when absent.
        fn metaString(comptime owner: []const u8, comptime key: []const u8) ?[]const u8 {
            if (!@hasField(Meta, owner)) return null;
            const e = @field(meta, owner);
            if (!@hasField(@TypeOf(e), key)) return null;
            const v = @field(e, key);
            if (!isString(@TypeOf(v))) fail(owner, "meta key '" ++ key ++ "' for '" ++ owner ++ "' must be a string.");
            const s: []const u8 = v;
            return s;
        }

        fn metaIdentifier(comptime owner: []const u8, comptime key: []const u8) ?[]const u8 {
            const s = metaString(owner, key) orelse return null;
            if (!isIdentifier(s))
                fail(owner, "meta key '" ++ key ++ "' for '" ++ owner ++ "' must be an identifier, found '" ++ s ++ "'.");
            return s;
        }

        // ---- fields and properties ----

        fn checkFields() void {
            for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
                if (attrs.@"comptime") fail(name, "Field '" ++ name ++ "' must not be comptime.");
                if (eql(name, "base")) {
                    if (FT != *Extends)
                        fail("base", "Field 'base' must have type *" ++ shortName(Extends) ++ ".");
                    continue;
                }
                if (exported(name)) {
                    if (engineOptionalPtr(FT)) |C|
                        fail(name, "Field '" ++ name ++ "' has type ?*" ++ shortName(C) ++ ", which Godot cannot hold; use z.Obj(" ++ shortName(C) ++ ").");
                    if (!convert.supported(FT))
                        fail(name, "Field '" ++ name ++ "' has type " ++ @typeName(FT) ++ ", which Godot cannot hold; not supported in v1.");
                    checkExportable(name, FT);
                }
                const d = attrs.defaultValue(FT) orelse fail(name, "Field '" ++ name ++ "' needs a default value.");
                requireDefined(FT, d);
            }
        }

        /// Object handles Godot's Inspector can edit, and enum tags its enum
        /// hint can show.
        fn checkExportable(comptime name: []const u8, comptime FT: type) void {
            if (handleKind(FT)) |k| {
                const C = FT.Class;
                const spelled = (if (k == .obj) "z.Obj(" else "z.Ref(") ++ shortName(C) ++ ")";
                const is_node = godot.class.isA(godot.class.Node, C);
                const is_resource = godot.class.isA(godot.class.Resource, C);
                if (k == .obj and is_resource)
                    fail(name, "Field '" ++ name ++ "' holds " ++ spelled ++ ", a Resource that the field would not keep alive; use z.Ref(" ++ shortName(C) ++ ").");
                if (!(k == .obj and is_node) and !(k == .ref and is_resource))
                    fail(name, "Field '" ++ name ++ "' holds " ++ spelled ++ ", which is neither a Node nor a Resource; Godot cannot export it.");
            }
            if (@typeInfo(FT) == .@"enum") {
                for (@typeInfo(FT).@"enum".field_names) |tag| {
                    if (std.mem.indexOfAny(u8, tag, ",:") != null)
                        fail(name, "Field '" ++ name ++ "' has the enum tag '" ++ tag ++ "', which Godot's enum hint cannot show because it contains ',' or ':'.");
                }
            }
        }

        fn godotFieldName(comptime name: []const u8) []const u8 {
            return metaIdentifier(name, "name") orelse name;
        }

        fn groupOf(comptime name: []const u8) ?[]const u8 {
            const g = metaString(name, "group") orelse return null;
            if (g.len == 0 or std.mem.indexOfScalar(u8, g, 0) != null or !std.unicode.utf8ValidateSlice(g))
                fail(name, "meta group for '" ++ name ++ "' must be non-empty UTF-8 text without NUL bytes.");
            return g;
        }

        fn rangeHint(comptime name: []const u8) ?[]const u8 {
            if (!@hasField(Meta, name)) return null;
            const e = @field(meta, name);
            if (!@hasField(@TypeOf(e), "range")) return null;
            const FT = @FieldType(S, name);
            switch (@typeInfo(FT)) {
                .int, .float => {},
                else => fail(name, "meta range for '" ++ name ++ "' needs a number field, but '" ++ name ++ "' has type " ++ @typeName(FT) ++ "."),
            }
            const r = @field(e, "range");
            const bad = "meta range for '" ++ name ++ "' must be .{ min, max } or .{ min, max, step } with numbers.";
            const R = @TypeOf(r);
            if (@typeInfo(R) != .@"struct" or !@typeInfo(R).@"struct".is_tuple) fail(name, bad);
            const n = @typeInfo(R).@"struct".field_names.len;
            if (n != 2 and n != 3) fail(name, bad);
            var out: []const u8 = "";
            for (0..n) |i| {
                const v = r[i];
                switch (@typeInfo(@TypeOf(v))) {
                    .comptime_int, .comptime_float, .int, .float => {},
                    else => fail(name, bad),
                }
                out = out ++ (if (i == 0) "" else ",") ++ std.fmt.comptimePrint("{d}", .{v});
            }
            return out;
        }

        const Hint = struct { hint: u32, string: []const u8 };

        /// The hint a field gets from its type: an enum dropdown, a node
        /// picker or a resource picker (as GDScript exports them).
        fn typeHint(comptime FT: type) Hint {
            if (handleKind(FT)) |k| {
                const class = object.engineClassName(FT.Class);
                return .{ .hint = if (k == .obj) hint_node_type else hint_resource_type, .string = class };
            }
            if (@typeInfo(FT) == .@"enum") {
                const e = @typeInfo(FT).@"enum";
                var out: []const u8 = "";
                for (e.field_names, e.field_values, 0..) |tag, value, i| {
                    out = out ++ (if (i == 0) "" else ",") ++ tag ++ ":" ++ std.fmt.comptimePrint("{d}", .{value});
                }
                return .{ .hint = hint_enum, .string = out };
            }
            return .{ .hint = hint_none, .string = "" };
        }

        fn property(comptime name: []const u8) abi.PropertyDesc {
            const FT = @FieldType(S, name);
            const th = typeHint(FT);
            var hint: u32 = th.hint;
            var hint_string: []const u8 = th.string;
            if (rangeHint(name)) |h| {
                hint = hint_range;
                hint_string = h;
            }
            if (@hasField(Meta, name) and @hasField(@TypeOf(@field(meta, name)), "hint")) {
                const h = @field(@field(meta, name), "hint");
                switch (@typeInfo(@TypeOf(h))) {
                    .comptime_int, .int => {},
                    else => fail(name, "meta key 'hint' for '" ++ name ++ "' must be an integer."),
                }
                if (h < 0 or h > std.math.maxInt(u32))
                    fail(name, "meta key 'hint' for '" ++ name ++ "' must be an integer."); // out of range
                hint = h;
            }
            if (metaString(name, "hint_string")) |hs| hint_string = hs;
            return .{
                .name = str(godotFieldName(name)),
                .field_index = fieldIndex(name).?,
                .variant_type = convert.variantType(FT),
                .class_name = str(classNameOf(FT)),
                .hint = hint,
                .hint_string = str(hint_string),
                .usage = usage_script_variable,
            };
        }

        fn groupEntry(comptime name: []const u8) abi.PropertyDesc {
            return .{
                .name = str(name),
                .field_index = abi.no_field,
                .variant_type = t_nil,
                .class_name = str(""),
                .hint = hint_none,
                .hint_string = str(""),
                .usage = abi.usage_group,
            };
        }

        /// Exported fields in source order. A group entry starts each run of
        /// fields with the same group; an empty-name entry ends a group
        /// before the next field without one.
        const properties: []const abi.PropertyDesc = blk: {
            @setEvalBranchQuota(quota);
            var list: []const abi.PropertyDesc = &.{};
            var current: ?[]const u8 = null;
            for (info.field_names) |name| {
                if (!exported(name)) continue;
                if (groupOf(name)) |g| {
                    if (current == null or !eql(current.?, g)) {
                        list = list ++ [_]abi.PropertyDesc{groupEntry(g)};
                        current = g;
                    }
                } else if (current != null) {
                    list = list ++ [_]abi.PropertyDesc{groupEntry("")};
                    current = null;
                }
                list = list ++ [_]abi.PropertyDesc{property(name)};
            }
            const final = list[0..list.len].*;
            break :blk &final;
        };

        const fields: []const abi.FieldDesc = blk: {
            @setEvalBranchQuota(quota);
            var out: [info.field_names.len]abi.FieldDesc = undefined;
            for (info.field_names, info.field_types, 0..) |name, FT, i| {
                out[i] = .{
                    .name = str(name),
                    .type_id = typeId(FT),
                    .offset = @offsetOf(S, name),
                    .size = @sizeOf(FT),
                };
            }
            const final = out;
            break :blk &final;
        };

        /// Wyhash over the size and alignment of `S`, then each field's
        /// name, type id and offset, in declaration order.
        const layout_hash: u64 = blk: {
            @setEvalBranchQuota(quota);
            var h = std.hash.Wyhash.init(0);
            hashInt(&h, @sizeOf(S));
            hashInt(&h, @alignOf(S));
            for (fields) |f| {
                h.update(f.name.ptr.?[0..f.name.len]);
                hashInt(&h, f.type_id);
                hashInt(&h, f.offset);
            }
            break :blk h.final();
        };

        /// Every field at its default; `base` stays undefined (the host sets
        /// it on every instance; a `*T` cannot be zero).
        const defaults: S = blk: {
            @setEvalBranchQuota(quota);
            var v: S = undefined;
            for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
                if (eql(name, "base")) continue;
                @field(v, name) = attrs.defaultValue(FT).?;
            }
            break :blk v;
        };

        // ---- methods ----

        fn checkMethods() void {
            for (method_decls) |d| {
                const f = @typeInfo(@TypeOf(@field(S, d))).@"fn";
                for (f.param_types[1..]) |maybe_p| {
                    const P = maybe_p orelse
                        fail(d, "Method '" ++ d ++ "' has a parameter of type anytype, which Godot cannot pass.");
                    if (!convert.supported(P))
                        fail(d, "Method '" ++ d ++ "' has a parameter of type " ++ @typeName(P) ++ ", which Godot cannot pass.");
                }
                const R = f.return_type orelse
                    fail(d, "Method '" ++ d ++ "' returns a generic type, which Godot cannot hold.");
                if (R != void and !convert.supported(R))
                    fail(d, "Method '" ++ d ++ "' returns " ++ @typeName(R) ++ ", which Godot cannot hold.");
                if (@hasField(Meta, d) and @hasField(@TypeOf(@field(meta, d)), "args")) {
                    const args = @field(@field(meta, d), "args");
                    const A = @TypeOf(args);
                    const want = f.param_types.len - 1;
                    if (@typeInfo(A) != .@"struct" or !@typeInfo(A).@"struct".is_tuple)
                        fail(d, "meta args for '" ++ d ++ "' must be a list of names such as .{ \"a\", \"b\" }.");
                    const have = @typeInfo(A).@"struct".field_names.len;
                    if (have != want)
                        fail(d, std.fmt.comptimePrint("meta args for '{s}' has {d} names, but the method takes {d} arguments.", .{ d, have, want }));
                    for (0..have) |i| {
                        if (!isString(@TypeOf(args[i])) or !isIdentifier(args[i]))
                            fail(d, "meta args for '" ++ d ++ "' must be identifiers in quotes.");
                    }
                }
            }
        }

        fn godotMethodName(comptime d: []const u8) []const u8 {
            if (metaIdentifier(d, "name")) |n| return n;
            if (!isIdentifier(d)) fail(d, "Method '" ++ d ++ "' needs a name override in meta, because its name is not an identifier.");
            return snake.toSnakeCase(d);
        }

        fn argName(comptime d: []const u8, comptime i: usize) []const u8 {
            if (@hasField(Meta, d) and @hasField(@TypeOf(@field(meta, d)), "args")) {
                const s: []const u8 = @field(@field(meta, d), "args")[i];
                return s;
            }
            return std.fmt.comptimePrint("arg{d}", .{i});
        }

        fn methodArgs(comptime d: []const u8) []const abi.ArgDesc {
            const f = @typeInfo(@TypeOf(@field(S, d))).@"fn";
            var out: [f.param_types.len - 1]abi.ArgDesc = undefined;
            for (f.param_types[1..], 0..) |P, i| out[i] = argDesc(argName(d, i), P.?);
            const final = out;
            return &final;
        }

        const methods: []const abi.MethodDesc = blk: {
            @setEvalBranchQuota(quota);
            var out: [method_decls.len]abi.MethodDesc = undefined;
            for (method_decls, 0..) |d, i| {
                const f = @typeInfo(@TypeOf(@field(S, d))).@"fn";
                const args = methodArgs(d);
                const R = f.return_type.?;
                out[i] = .{
                    .name = str(godotMethodName(d)),
                    .args = args.ptr,
                    .arg_count = args.len,
                    .ret = if (R == void) argDesc("", void) else argDesc("", R),
                    .flags = if (d[0] == '_') abi.method_flag_virtual else 0,
                };
            }
            const final = out;
            break :blk &final;
        };

        // ---- signals ----

        const Signals: type = blk: {
            if (!isPub("signals")) break :blk struct {};
            if (@TypeOf(S.signals) != type or @typeInfo(S.signals) != .@"struct")
                fail("signals", "signals must be a struct type that declares one struct per signal.");
            break :blk S.signals;
        };

        fn checkSignals() void {
            for (@typeInfo(Signals).@"struct".decl_names) |sname| {
                const T = @field(Signals, sname);
                if (@TypeOf(T) != type or @typeInfo(T) != .@"struct")
                    fail("signals", "Signal '" ++ sname ++ "' must be a struct type whose fields are its arguments.");
                if (!isIdentifier(sname))
                    fail("signals", "Signal '" ++ sname ++ "' must have an identifier name.");
                const si = @typeInfo(T).@"struct";
                for (si.field_names, si.field_types) |aname, AT| {
                    if (!convert.supported(AT))
                        fail("signals", "Signal '" ++ sname ++ "' argument '" ++ aname ++ "' has type " ++ @typeName(AT) ++ ", which Godot cannot hold.");
                }
            }
        }

        fn signalArgs(comptime T: type) []const abi.ArgDesc {
            const si = @typeInfo(T).@"struct";
            var out: [si.field_names.len]abi.ArgDesc = undefined;
            for (si.field_names, si.field_types, 0..) |aname, AT, i| out[i] = argDesc(aname, AT);
            const final = out;
            return &final;
        }

        const signals: []const abi.SignalDesc = blk: {
            @setEvalBranchQuota(quota);
            const names = @typeInfo(Signals).@"struct".decl_names;
            var out: [names.len]abi.SignalDesc = undefined;
            for (names, 0..) |sname, i| {
                const args = signalArgs(@field(Signals, sname));
                out[i] = .{ .name = str(sname), .args = args.ptr, .arg_count = args.len };
            }
            const final = out;
            break :blk &final;
        };

        // ---- name collisions ----

        const Named = struct { zig: []const u8, godot: []const u8, marker: []const u8 };

        fn checkCollisions() void {
            var list: []const Named = &.{};
            for (info.field_names) |name| {
                if (exported(name)) list = list ++ [_]Named{.{ .zig = name, .godot = godotFieldName(name), .marker = name }};
            }
            for (method_decls) |d| list = list ++ [_]Named{.{ .zig = d, .godot = godotMethodName(d), .marker = d }};
            for (@typeInfo(Signals).@"struct".decl_names) |sname| {
                list = list ++ [_]Named{.{ .zig = sname, .godot = sname, .marker = "signals" }};
            }
            for (list, 0..) |b, j| {
                for (list[0..j]) |a| {
                    if (eql(a.godot, b.godot))
                        fail(b.marker, "'" ++ a.zig ++ "' and '" ++ b.zig ++ "' both map to the Godot name '" ++ b.godot ++ "'; give one a name override in meta.");
                }
            }
        }

        fn check() void {
            @setEvalBranchQuota(quota);
            _ = Extends;
            _ = class_name;
            _ = tool;
            checkByValue();
            checkFields();
            checkMeta();
            _ = properties;
            checkMethods();
            checkSignals();
            checkCollisions();
        }

        const desc: abi.ScriptDesc = blk: {
            check();
            break :blk .{
                .path = str(rel),
                .class_name = str(class_name),
                .base_class = str(object.engineClassName(Extends)),
                .flags = if (tool) abi.script_flag_tool else 0,
                .layout_hash = layout_hash,
                .instance_size = @sizeOf(S),
                .instance_align = @alignOf(S),
                .defaults = @ptrCast(&defaults),
                .fields = fields.ptr,
                .field_count = fields.len,
                .properties = properties.ptr,
                .property_count = properties.len,
                .methods = methods.ptr,
                .method_count = methods.len,
                .signals = signals.ptr,
                .signal_count = signals.len,
                .create = placeholder.create,
                .destroy = placeholder.destroy,
                .call = placeholder.call,
                .get = placeholder.get,
                .set = placeholder.set,
                .get_default = placeholder.getDefault,
                .notification = placeholder.notification,
                .migrate = null,
            };
        };
    };
}

/// Stand-ins until the wrappers exist: no method, no property, no instance.
const placeholder = struct {
    fn create(owner: *anyopaque, gen: u32) callconv(.c) ?*anyopaque {
        _ = owner;
        _ = gen;
        return null;
    }

    fn destroy(inst: *anyopaque) callconv(.c) void {
        _ = inst;
    }

    fn call(inst: *anyopaque, method: u32, args: [*]const *const anyopaque, argc: i64, ret: *anyopaque, err: *abi.CallError) callconv(.c) void {
        _ = inst;
        _ = method;
        _ = args;
        _ = argc;
        _ = ret;
        err.* = .{ .@"error" = abi.call_invalid_method, .argument = 0, .expected = 0 };
    }

    fn get(inst: *anyopaque, property: u32, ret: *anyopaque) callconv(.c) u8 {
        _ = inst;
        _ = property;
        _ = ret;
        return 0;
    }

    fn set(inst: *anyopaque, property: u32, value: *const anyopaque) callconv(.c) u8 {
        _ = inst;
        _ = property;
        _ = value;
        return 0;
    }

    fn getDefault(property: u32, ret: *anyopaque) callconv(.c) u8 {
        _ = property;
        _ = ret;
        return 0;
    }

    fn notification(inst: *anyopaque, what: i32, reversed: u8) callconv(.c) void {
        _ = inst;
        _ = what;
        _ = reversed;
    }
};

/// Reads every scalar in `v`, so an `undefined` one is a compile error
/// (see the file header). Padding is never read.
fn requireDefined(comptime T: type, comptime v: T) void {
    @setEvalBranchQuota(100_000);
    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => if (v != v) {},
        .pointer => |p| switch (p.size) {
            .slice => if (v.ptr != v.ptr or v.len != v.len) {},
            else => if (v != v) {},
        },
        .optional => |o| if (v != null) requireDefined(o.child, v.?),
        .array => |a| for (v) |e| requireDefined(a.child, e),
        .@"struct" => |s| {
            if (s.backing_integer) |I| {
                const bits: I = @bitCast(v);
                if (bits != bits) {}
                return;
            }
            inline for (s.field_names, s.field_types, s.field_attrs) |name, FT, attrs| {
                if (!attrs.@"comptime") requireDefined(FT, @field(v, name));
            }
        },
        else => {},
    }
}

/// `.obj` or `.ref` when `T` is a `z.Obj` or `z.Ref` handle.
fn handleKind(comptime T: type) ?@TypeOf(.obj) {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, object.handle_decl)) return null;
    return T.ziggurat_handle;
}

/// An argument or return value of type `T` named `name`; `void` is NIL.
fn argDesc(comptime name: []const u8, comptime T: type) abi.ArgDesc {
    return .{
        .name = str(name),
        .variant_type = if (T == void) t_nil else convert.variantType(T),
        .class_name = str(if (T == void) "" else classNameOf(T)),
    };
}

/// The engine class name of an object type (`?*C`, `Obj(C)`, `Ref(C)`), or "".
fn classNameOf(comptime T: type) []const u8 {
    if (engineOptionalPtr(T)) |C| return object.engineClassName(C);
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, object.handle_decl)) return object.engineClassName(T.Class);
    return "";
}

/// `C` when `T` is `?*C` for an engine class `C`.
fn engineOptionalPtr(comptime T: type) ?type {
    const i = @typeInfo(T);
    if (i != .optional) return null;
    const p = @typeInfo(i.optional.child);
    if (p != .pointer or p.pointer.size != .one) return null;
    const C = p.pointer.child;
    if (@typeInfo(C) != .@"opaque" and @typeInfo(C) != .@"struct") return null;
    return if (object.isEngineClass(C)) C else null;
}

/// The last part of a type's name: `Node2d` for `gdzig.class.node2d.Node2d`.
fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    return if (std.mem.lastIndexOfScalar(u8, full, '.')) |i| full[i + 1 ..] else full;
}

/// Wyhash of the type's name, seeded with its size (as Stage 0).
fn typeId(comptime T: type) u64 {
    return std.hash.Wyhash.hash(@sizeOf(T), @typeName(T));
}

fn hashInt(h: *std.hash.Wyhash, v: u64) void {
    const le = std.mem.nativeToLittle(u64, v);
    h.update(std.mem.asBytes(&le));
}

fn str(comptime s: []const u8) abi.Str {
    return .{ .ptr = s.ptr, .len = s.len };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn inList(comptime s: []const u8, comptime list: []const []const u8) bool {
    for (list) |x| {
        if (eql(x, s)) return true;
    }
    return false;
}

fn isString(comptime T: type) bool {
    const i = @typeInfo(T);
    if (i != .pointer) return false;
    const p = i.pointer;
    return switch (p.size) {
        .slice => p.child == u8,
        .one => @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8,
        else => false,
    };
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// `rel` for the SDK marker: `%`, `]`, `:` and `\` percent-encoded.
fn encodeRel(comptime rel: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(1000 + 100 * rel.len);
        var out: []const u8 = "";
        for (rel) |c| {
            out = out ++ switch (c) {
                '%' => "%25",
                ']' => "%5D",
                ':' => "%3A",
                '\\' => "%5C",
                else => &[_]u8{c},
            };
        }
        return out;
    }
}
