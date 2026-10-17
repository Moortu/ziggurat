//! `emit`: emits a signal the script declares in `pub const signals`
//! (spec section 8), checked at compile time.
//!
//! `z.emit(self, .hit, .{ .damage = amount })` compiles only when `hit` is a
//! signal of the script and the argument struct has exactly the signal's
//! fields, each of a type that coerces to the field's type (the same type,
//! a number literal for a number, `null` for an optional, an enum literal
//! for an enum, a pointer for a const or optional pointer to the same type).
//! A mistake is a compile error of one sentence with the SDK marker
//! `[ziggurat:<rel>#signals]` (see `src/build/rootgen.zig`), so the build
//! service reports it at the script's `pub const signals` line (line 1 when
//! the script has none). Zig analyses only bodies that are reached, so an
//! `emit` in a private function nothing calls is not checked.
//!
//! The marker's `<rel>` is found by matching `@typeName` of the script with
//! the paths of the descriptors in the generated root. When that is not
//! possible (no generated root, as in tests, or two script paths with the
//! same type name such as `a/b.c.zig` and `a/b/c.zig`) the error has no
//! marker and the build shows it without a file.
//!
//! At run time the arguments go through the checked conversions into
//! Variants, and `Object.emit_signal` is called on `self.base` through the
//! method bind (gdzig's own `emit` helpers convert through `Variant.init`
//! and read the result with `Variant.as`, which the SDK never uses). A
//! failed emit (for example a signal the host has not registered) is logged
//! as a warning, never a panic. The method bind is cached in a plain `var`
//! without atomics: the first `emit` must run on the main thread.
const std = @import("std");
const abi = @import("ziggurat_abi");
const godot = @import("gdzig");
const convert = @import("convert.zig");
const names = @import("names.zig");
const describe = @import("describe.zig");
const runtime = @import("runtime.zig");

const Variant = godot.builtin.Variant;
const StringName = godot.builtin.StringName;

/// Emits `signal` on the script instance `self` (a `*Script`) with `args`,
/// a struct literal with one field per signal argument.
pub fn emit(self: anytype, comptime signal: @EnumLiteral(), args: anytype) void {
    const S = comptime ScriptOf(@TypeOf(self));
    const sname = @tagName(signal);
    const Sig = comptime SignalArgs(S, sname);
    comptime checkArgs(S, sname, Sig, @TypeOf(args));

    const si = @typeInfo(Sig).@"struct";
    const n = si.field_names.len;
    var slots: [1 + n]Variant = undefined;
    var ptrs: [1 + n]*const anyopaque = undefined;
    const name: *const StringName = @ptrCast(@alignCast(names.StaticName(sname).ptr()));
    convert.write(StringName, name, &slots[0]);
    inline for (si.field_names, si.field_types, 1..) |aname, FT, i| {
        const value: FT = @field(args, aname);
        convert.write(FT, &value, &slots[i]);
    }
    for (&ptrs, &slots) |*p, *s| p.* = s;
    defer for (&slots) |*s| godot.raw.variantDestroy(s);

    var ret: Variant = undefined;
    var err: godot.c.GDExtensionCallError = undefined;
    godot.raw.objectMethodBindCall(emitBind(), @ptrCast(self.base), @ptrCast(&ptrs), ptrs.len, @ptrCast(&ret), &err);
    defer godot.raw.variantDestroy(&ret);
    var code: i64 = 0;
    const bad_ret = convert.read(i64, &ret, &code) != null;
    if (err.@"error" != 0 or bad_ret or code != 0)
        runtime.log(.warning, "emit of signal '{s}' failed (call error {d}, result {d}); is the signal registered?", .{ sname, err.@"error", code });
}

/// Hash of `Object.emit_signal` in extension_api.json (Godot 4.7.2).
const emit_signal_hash: i64 = 4047867050;

var emit_bind: godot.c.GDExtensionMethodBindPtr = null;

fn emitBind() godot.c.GDExtensionMethodBindPtr {
    if (emit_bind == null) {
        emit_bind = godot.raw.classdbGetMethodBind(
            @ptrCast(names.StaticName("Object").ptr()),
            @ptrCast(names.StaticName("emit_signal").ptr()),
            emit_signal_hash,
        );
    }
    return emit_bind;
}

/// The script struct behind `self`, which must be `*S` or `*const S` for a
/// struct `S` with a `base` field.
fn ScriptOf(comptime P: type) type {
    const ok = switch (@typeInfo(P)) {
        .pointer => |p| p.size == .one and @typeInfo(p.child) == .@"struct",
        else => false,
    };
    if (!ok) @compileError("ziggurat: emit takes the script instance (self) first, found " ++ @typeName(P) ++ ".");
    const S = @typeInfo(P).pointer.child;
    if (!@hasField(S, "base"))
        fail(S, "emit needs the script's 'base' field: the signal is emitted on the Godot object it holds.");
    return S;
}

/// The argument struct of the signal `sname` of `S`.
fn SignalArgs(comptime S: type, comptime sname: []const u8) type {
    const list = declared(S);
    const Signals = if (@hasDecl(S, "signals") and @TypeOf(S.signals) == type and @typeInfo(S.signals) == .@"struct") S.signals else struct {};
    if (!@hasDecl(Signals, sname) or @TypeOf(@field(Signals, sname)) != type)
        fail(S, "'" ++ sname ++ "' is not a signal of this script; " ++
            (if (list.len == 0) "it declares none in 'pub const signals'." else "its signals are " ++ list ++ "."));
    const T = @field(Signals, sname);
    if (@typeInfo(T) != .@"struct")
        fail(S, "Signal '" ++ sname ++ "' must be a struct type whose fields are its arguments.");
    return T;
}

/// The script's signal names, comma-separated.
fn declared(comptime S: type) []const u8 {
    if (!@hasDecl(S, "signals") or @TypeOf(S.signals) != type or @typeInfo(S.signals) != .@"struct") return "";
    var out: []const u8 = "";
    for (@typeInfo(S.signals).@"struct".decl_names, 0..) |d, i| out = out ++ (if (i == 0) "" else ", ") ++ d;
    return out;
}

fn checkArgs(comptime S: type, comptime sname: []const u8, comptime Sig: type, comptime A: type) void {
    if (@typeInfo(A) != .@"struct")
        fail(S, "emit of '" ++ sname ++ "' takes its arguments as a struct literal such as .{ .name = value }, found " ++ @typeName(A) ++ ".");
    const sig = @typeInfo(Sig).@"struct";
    const got = @typeInfo(A).@"struct";
    for (got.field_names) |aname| {
        if (!@hasField(Sig, aname))
            fail(S, "emit of '" ++ sname ++ "' passes '" ++ aname ++ "', which is not an argument of the signal.");
    }
    for (sig.field_names, sig.field_types) |aname, FT| {
        if (!@hasField(A, aname))
            fail(S, "emit of '" ++ sname ++ "' is missing the argument '" ++ aname ++ "'.");
        const G = @FieldType(A, aname);
        if (!coerces(G, FT))
            fail(S, "emit of '" ++ sname ++ "' passes '" ++ aname ++ "' as " ++ @typeName(G) ++ ", but the signal declares " ++ @typeName(FT) ++ ".");
    }
}

/// True when a value of type `From` coerces to `To` in the ways listed in
/// the file comment. Anything else would fail inside the SDK with Zig's own
/// message, so it is rejected here with a sentence at the script.
fn coerces(comptime From: type, comptime To: type) bool {
    if (From == To) return true;
    const to = @typeInfo(To);
    switch (@typeInfo(From)) {
        .comptime_int => return to == .int or to == .float,
        .comptime_float => return to == .float,
        .null => return to == .optional,
        .enum_literal => return to == .@"enum",
        else => {},
    }
    if (to == .optional) return coerces(From, to.optional.child);
    const from = @typeInfo(From);
    if (from == .pointer and to == .pointer) {
        const f = from.pointer;
        const t = to.pointer;
        return f.size == t.size and f.child == t.child and (t.is_const or !f.is_const);
    }
    return false;
}

/// A compile error about `S`'s signals, with the SDK marker when the
/// script's path can be found.
fn fail(comptime S: type, comptime sentence: []const u8) noreturn {
    if (scriptRel(S)) |rel| @compileError(sentence ++ " [ziggurat:" ++ describe.encodeRel(rel) ++ "#signals]");
    @compileError("ziggurat: " ++ sentence);
}

/// The project-relative path of `S`: the one descriptor in the generated
/// root (`pub const s<i>`) whose path gives `@typeName(S)`, or null.
fn scriptRel(comptime S: type) ?[]const u8 {
    @setEvalBranchQuota(100_000);
    const root = @import("root");
    if (@typeInfo(root) != .@"struct") return null;
    const want = @typeName(S);
    var found: ?[]const u8 = null;
    for (@typeInfo(root).@"struct".decl_names) |d| {
        if (!isScriptDecl(d)) continue;
        const v = @field(root, d);
        if (@TypeOf(v) != abi.ScriptDesc) continue;
        const rel = (v.path.ptr orelse continue)[0..v.path.len];
        if (!std.mem.eql(u8, typeNameOf(rel), want)) continue;
        if (found != null) return null;
        found = rel;
    }
    return found;
}

/// True for `s` followed by digits, the generated root's descriptor names.
fn isScriptDecl(comptime d: []const u8) bool {
    if (d.len < 2 or d[0] != 's') return false;
    for (d[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `@typeName` of the file at `rel` in the root module: `a/b.zig` gives `a.b`.
fn typeNameOf(comptime rel: []const u8) []const u8 {
    const stem = if (std.mem.endsWith(u8, rel, ".zig")) rel[0 .. rel.len - 4] else rel;
    var out: [stem.len]u8 = undefined;
    for (stem, 0..) |c, i| out[i] = if (c == '/') '.' else c;
    const final = out;
    return &final;
}
