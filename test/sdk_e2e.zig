//! End-to-end tests for the Stage 2 SDK: the build service compiling user
//! scripts against the real SDK and gdzig, with the module list from the SDK
//! manifest (`build_options.sdk_manifest_path`, written by the build).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
const abi = @import("ziggurat_abi");
const sdk_options = @import("sdk_options");
const service = zbuild.service;
const BuildService = service.BuildService;
const Outcome = service.Outcome;
const testing = std.testing;
const io = testing.io;

/// gdzig is large: a cold build of a module that imports it takes tens of seconds.
const build_wait_ms = 600_000;

fn expectOk(o: Outcome) !void {
    if (!o.ok) {
        std.debug.print("build failed: {?s}\n", .{o.message});
        for (o.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
        return error.BuildFailed;
    }
}

fn timingOn() bool {
    return testing.environ.containsUnempty(testing.allocator, "ZIGGURAT_E2E_TIMING") catch false;
}

const File = struct { rel: []const u8, data: []const u8 };

/// The layout stamp a host built with this compiler for this machine
/// expects, computed as the host computes it.
const host_stamp: u64 = abi.expectedStamp(sdk_options);

/// Service options the tests set beyond the defaults.
const Opts = struct {
    check_tables: bool = false,
    test_stale_build_id: bool = false,
};

/// A temp project with `files`, the SDK manifest and a `BuildService` on it.
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    manifest: zbuild.sdk_manifest.Manifest,
    env: platform.path.HostEnv,
    svc: *BuildService,

    /// `h` must not move while the service runs; the config borrows from it.
    fn init(h: *Harness, files: []const File) !void {
        return h.initOpts(files, .{});
    }

    fn initOpts(h: *Harness, files: []const File, opts: Opts) !void {
        h.arena = .init(testing.allocator);
        errdefer h.arena.deinit();
        const a = h.arena.allocator();

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(testing.allocator);
        const manifest_path = try std.Io.Dir.cwd().realPathFileAlloc(io, build_options.sdk_manifest_path, a);
        h.manifest = zbuild.sdk_manifest.load(testing.allocator, io, .fromTrusted(manifest_path), &msg) catch |err| {
            std.debug.print("manifest: {s}\n", .{msg.items});
            return err;
        };
        errdefer h.manifest.deinit(testing.allocator);

        h.tmp = testing.tmpDir(.{});
        errdefer h.tmp.cleanup();
        try h.tmp.dir.createDirPath(io, "proj");
        try h.tmp.dir.createDirPath(io, "cache");
        for (files) |f| {
            const sub = try std.fmt.allocPrint(a, "proj/{s}", .{f.rel});
            if (std.fs.path.dirname(sub)) |dir| try h.tmp.dir.createDirPath(io, dir);
            try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = f.data });
        }
        const base = try h.tmp.dir.realPathFileAlloc(io, ".", a);
        const project = try h.tmp.dir.realPathFileAlloc(io, "proj", a);
        const cache = try h.tmp.dir.realPathFileAlloc(io, "cache", a);
        const store = try std.fs.path.join(a, &.{ base, "store" });

        h.env = .{ .os = builtin.os.tag, .home = cache, .xdg_cache_home = cache, .local_app_data = cache };
        h.svc = try BuildService.init(testing.allocator, io, .{
            .paths = .init(.{ .project = .fromTrusted(project) }, h.env),
            .locate = .{
                .configured = .fromTrusted(build_options.zig_exe),
                .toolchain_dir = .fromTrusted(base),
                .env = h.env,
            },
            .sdk = h.manifest.modules,
            .store_root = .fromTrusted(store),
            .check_tables = opts.check_tables,
            .expected_stamp = host_stamp,
            .test_stale_build_id = opts.test_stale_build_id,
        });
    }

    fn deinit(h: *Harness) void {
        h.svc.deinit();
        h.tmp.cleanup();
        h.manifest.deinit(testing.allocator);
        h.arena.deinit();
    }

    fn write(h: *Harness, rel: []const u8, data: []const u8) !void {
        var buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(&buf, "proj/{s}", .{rel});
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = data });
    }

    fn build(h: *Harness, t: service.Trigger) !Outcome {
        h.svc.request(t);
        try h.svc.waitIdle(build_wait_ms);
        return h.svc.last() orelse error.NoOutcome;
    }
};

test "integration: skeleton sdk builds with gdzig" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var h: Harness = undefined;
    try h.init(&.{.{ .rel = "a.zig", .data = "pub const extends = @import(\"ziggurat\").godot.Node;\n" }});
    defer h.deinit();

    const o = try h.build(.open);
    try expectOk(o);
    try testing.expectEqual(service.BuildPath.full, o.path);
    const gen = o.generation orelse return error.NoGeneration;
    try testing.expectEqual(@as(u32, 1), gen.n);
    try std.Io.Dir.cwd().access(io, gen.lib.bytes, .{});

    if (timingOn()) std.debug.print("sdk_e2e: full build {d} ms\n", .{o.ms});
}

/// A script with 30 exported fields (with ranges, in three groups) and 30
/// methods, to check that `describe` stays within its branch quota.
fn bigScript(a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "const z = @import(\"ziggurat\");\npub const extends = z.godot.Node;\nbase: *z.godot.Node,\n");
    for (0..30) |i| try out.print(a, "field{d}: i32 = {d},\n", .{ i, i });
    try out.appendSlice(a, "pub const meta = .{\n");
    for (0..30) |i| try out.print(a, "    .field{d} = .{{ .range = .{{ 0, {d} }}, .group = \"Group{d}\" }},\n", .{ i, 100 + i, i % 3 });
    for (0..30) |i| try out.print(a, "    .method{d} = .{{ .args = .{{ \"value\", \"scale\" }} }},\n", .{i});
    try out.appendSlice(a, "};\n");
    for (0..30) |i| try out.print(a, "pub fn method{d}(self: *@This(), value: i32, scale: f64) f64 {{\n    return @as(f64, @floatFromInt(self.field{d} + value)) * scale;\n}}\n", .{ i, i });
    return out.items;
}

test "integration: fixture project builds" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var h: Harness = undefined;
    try h.init(&.{
        .{ .rel = "player.zig", .data = @embedFile("fixtures/sdk_project/player.zig") },
        .{ .rel = "items/coin.zig", .data = @embedFile("fixtures/sdk_project/items/coin.zig") },
        .{ .rel = "ui/hud_label.zig", .data = @embedFile("fixtures/sdk_project/ui/hud_label.zig") },
        .{ .rel = "big.zig", .data = try bigScript(arena.allocator()) },
    });
    defer h.deinit();

    const o = try h.build(.open);
    try expectOk(o);
    if (timingOn()) std.debug.print("sdk_e2e: fixture project (3 fixtures + 30-field, 30-method script) full build {d} ms\n", .{o.ms});
}

const fixture_player = @import("fixture_player");
const fixture_coin = @import("fixture_coin");
const fixture_hud_label = @import("fixture_hud_label");

fn str(s: abi.Str) []const u8 {
    const p = s.ptr orelse return "";
    return p[0..s.len];
}

/// A staged library opened the way the host will open it, with its table
/// read through the `ziggurat_describe` export (the module is never
/// initialised, so no Godot is needed).
const Loaded = struct {
    lib: platform.loader.Library,
    table: *const abi.Table,

    fn open(gen: service.Generation) !Loaded {
        var diag: [256]u8 = undefined;
        const lib = platform.loader.open(testing.allocator, io, gen.lib, &diag) catch |err| {
            std.debug.print("load failed: {s}\n", .{std.mem.sliceTo(&diag, 0)});
            return err;
        };
        errdefer platform.loader.close(lib);
        const describe = platform.loader.lookup(lib, *const fn () callconv(.c) *const abi.Table, "ziggurat_describe") orelse
            return error.SymbolNotFound;
        return .{ .lib = lib, .table = describe() };
    }

    fn close(l: Loaded) void {
        platform.loader.close(l.lib);
    }

    /// The host's own check, with the stamp the host computes.
    fn validate(l: Loaded) !void {
        var diag: [256]u8 = undefined;
        abi.validate(testing.allocator, l.table, host_stamp, .{}, &diag) catch |err| {
            std.debug.print("validate: {s}\n", .{std.mem.sliceTo(&diag, 0)});
            return err;
        };
    }

    fn scripts(l: Loaded) []const abi.ScriptDesc {
        return l.table.scripts[0..l.table.script_count];
    }
};

const t_nil: u32 = 0;
const t_bool: u32 = 1;
const t_int: u32 = 2;
const t_float: u32 = 3;
const t_string: u32 = 4;
const t_vector2: u32 = 5;
const t_object: u32 = 24;
const usage_script: u32 = 4102;
const usage_group: u32 = 64;
const hint_range: u32 = 1;
const hint_enum: u32 = 2;
const hint_resource_type: u32 = 17;
const hint_node_type: u32 = 34;
const group = "Movement/Fast motion";

const PropWant = struct {
    name: []const u8,
    field: u32,
    vt: u32,
    class: []const u8 = "",
    hint: u32 = 0,
    hint_string: []const u8 = "",
    usage: u32 = usage_script,
};

fn expectProps(d: *const abi.ScriptDesc, want: []const PropWant) !void {
    try testing.expectEqual(@as(u32, @intCast(want.len)), d.property_count);
    for (want, 0..) |w, i| {
        const p = d.properties[i];
        errdefer std.debug.print("property {d} ({s})\n", .{ i, w.name });
        try testing.expectEqualStrings(w.name, str(p.name));
        try testing.expectEqual(w.field, p.field_index);
        try testing.expectEqual(w.vt, p.variant_type);
        try testing.expectEqualStrings(w.class, str(p.class_name));
        try testing.expectEqual(w.hint, p.hint);
        try testing.expectEqualStrings(w.hint_string, str(p.hint_string));
        try testing.expectEqual(w.usage, p.usage);
    }
}

fn expectFixtureTable(l: Loaded) !void {
    try l.validate();
    const t = l.table;
    try testing.expectEqual(host_stamp, t.layout_stamp);
    try testing.expectEqualStrings(sdk_options.sdk_version, str(t.sdk_version));
    try testing.expectEqual(@as(usize, 16), str(t.build_id).len);

    // Three scripts, sorted by path in byte order.
    const s = l.scripts();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("items/coin.zig", str(s[0].path));
    try testing.expectEqualStrings("player.zig", str(s[1].path));
    try testing.expectEqualStrings("ui/hud_label.zig", str(s[2].path));

    // class_name, base class, flags and instance layout.
    const coin = &s[0];
    try testing.expectEqualStrings("Coin", str(coin.class_name));
    try testing.expectEqualStrings("Area2D", str(coin.base_class));
    try testing.expectEqual(@as(u32, 0), coin.flags);
    try testing.expectEqual(@as(u32, @sizeOf(fixture_coin)), coin.instance_size);
    try testing.expectEqual(@as(u32, @alignOf(fixture_coin)), coin.instance_align);

    const p = &s[1];
    try testing.expectEqualStrings("Player", str(p.class_name));
    try testing.expectEqualStrings("CharacterBody2D", str(p.base_class));
    try testing.expectEqual(@as(u32, 0), p.flags);
    try testing.expectEqual(@as(u32, @sizeOf(fixture_player)), p.instance_size);
    try testing.expectEqual(@as(u32, @alignOf(fixture_player)), p.instance_align);
    try testing.expectEqual(@as(u32, 10), p.field_count);

    const hud = &s[2];
    try testing.expectEqualStrings("HudLabel", str(hud.class_name));
    try testing.expectEqualStrings("Label", str(hud.base_class));
    try testing.expectEqual(abi.script_flag_tool, hud.flags);
    try testing.expectEqual(@as(u32, @sizeOf(fixture_hud_label)), hud.instance_size);
    try testing.expectEqual(@as(u32, @alignOf(fixture_hud_label)), hud.instance_align);

    // Player: properties in source order with groups and hints.
    try expectProps(p, &.{
        .{ .name = group, .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "speed", .field = 1, .vt = t_float, .hint = hint_range, .hint_string = "0,1000,5" },
        .{ .name = "", .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "health", .field = 2, .vt = t_int, .hint = hint_range, .hint_string = "0,100" },
        .{ .name = "alive", .field = 3, .vt = t_bool },
        .{ .name = "mood", .field = 4, .vt = t_int, .hint = hint_enum, .hint_string = "calm:0,angry:1" },
        .{ .name = "layers", .field = 5, .vt = t_int },
        .{ .name = group, .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "spawn_point", .field = 6, .vt = t_vector2 },
        .{ .name = "", .field = abi.no_field, .vt = t_nil, .usage = usage_group },
        .{ .name = "title", .field = 7, .vt = t_string },
        .{ .name = "target", .field = 8, .vt = t_object, .class = "Node", .hint = hint_node_type, .hint_string = "Node" },
    });
    try expectProps(coin, &.{
        .{ .name = "value", .field = 1, .vt = t_int },
        .{ .name = "texture", .field = 2, .vt = t_object, .class = "Texture2D", .hint = hint_resource_type, .hint_string = "Texture2D" },
    });
    try expectProps(hud, &.{
        .{ .name = "prefix", .field = 0, .vt = t_string },
        .{ .name = "blink", .field = 1, .vt = t_float },
    });

    // Player: methods, in source order, with the Godot names.
    try testing.expectEqual(@as(u32, 3), p.method_count);
    const m0 = p.methods[0];
    try testing.expectEqualStrings("_physics_process", str(m0.name));
    try testing.expectEqual(abi.method_flag_virtual, m0.flags);
    try testing.expectEqual(@as(u32, 1), m0.arg_count);
    try testing.expectEqual(t_float, m0.args[0].variant_type);
    try testing.expectEqual(t_nil, m0.ret.variant_type);
    const m1 = p.methods[1];
    try testing.expectEqualStrings("take_damage", str(m1.name));
    try testing.expectEqual(@as(u32, 0), m1.flags);
    try testing.expectEqual(@as(u32, 2), m1.arg_count);
    try testing.expectEqualStrings("amount", str(m1.args[0].name));
    try testing.expectEqual(t_int, m1.args[0].variant_type);
    try testing.expectEqualStrings("critical", str(m1.args[1].name));
    try testing.expectEqual(t_bool, m1.args[1].variant_type);
    const m2 = p.methods[2];
    try testing.expectEqualStrings("leap", str(m2.name));
    try testing.expectEqual(@as(u32, 1), m2.arg_count);
    try testing.expectEqual(t_float, m2.args[0].variant_type);
    try testing.expectEqual(t_float, m2.ret.variant_type);
    try testing.expectEqual(@as(u32, 1), coin.method_count);
    try testing.expectEqualStrings("collect", str(coin.methods[0].name));
    try testing.expectEqual(@as(u32, 1), hud.method_count);
    try testing.expectEqualStrings("_process", str(hud.methods[0].name));

    // Player: signals.
    try testing.expectEqual(@as(u32, 2), p.signal_count);
    try testing.expectEqualStrings("died", str(p.signals[0].name));
    try testing.expectEqual(@as(u32, 0), p.signals[0].arg_count);
    const hit = p.signals[1];
    try testing.expectEqualStrings("hit", str(hit.name));
    try testing.expectEqual(@as(u32, 2), hit.arg_count);
    try testing.expectEqualStrings("damage", str(hit.args[0].name));
    try testing.expectEqual(t_int, hit.args[0].variant_type);
    try testing.expectEqualStrings("source", str(hit.args[1].name));
    try testing.expectEqual(t_object, hit.args[1].variant_type);
    try testing.expectEqualStrings("Node", str(hit.args[1].class_name));
    try testing.expectEqual(@as(u32, 1), coin.signal_count);
    try testing.expectEqualStrings("collected", str(coin.signals[0].name));
    try testing.expectEqual(@as(u32, 0), hud.signal_count);
}

test "integration: fixture project end to end" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const player_src = @embedFile("fixtures/sdk_project/player.zig");

    var h: Harness = undefined;
    try h.initOpts(&.{
        .{ .rel = "player.zig", .data = player_src },
        .{ .rel = "items/coin.zig", .data = @embedFile("fixtures/sdk_project/items/coin.zig") },
        .{ .rel = "ui/hud_label.zig", .data = @embedFile("fixtures/sdk_project/ui/hud_label.zig") },
    }, .{ .check_tables = true });
    defer h.deinit();

    // Full build, then the staged library: load, validate, compare.
    const o1 = try h.build(.open);
    try expectOk(o1);
    try testing.expectEqual(service.BuildPath.full, o1.path);
    const gen1 = o1.generation orelse return error.NoGeneration;
    var first_id: [16]u8 = undefined;
    var first_hash: u64 = 0;
    {
        const l = try Loaded.open(gen1);
        defer l.close();
        try expectFixtureTable(l);
        @memcpy(&first_id, str(l.table.build_id));
        first_hash = abi.layoutHash(&l.scripts()[1]);
    }

    // Warm up, then one body edit on the incremental path with the table check.
    const t_warm = std.Io.Clock.awake.now(io);
    try h.svc.waitWarm(build_wait_ms);
    const warm_ms = t_warm.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

    const needle = "return height * self.speed;";
    try testing.expect(std.mem.indexOf(u8, player_src, needle) != null);
    try h.write("player.zig", try std.mem.replaceOwned(u8, a, player_src, needle, "return height * self.speed + 1;"));
    const o2 = try h.build(.save);
    try expectOk(o2);
    try testing.expectEqual(service.BuildPath.incremental, o2.path);
    try testing.expect(o2.message == null);
    const gen2 = o2.generation orelse return error.NoGeneration;
    try testing.expectEqual(gen1.n + 1, gen2.n);
    const check_us = h.svc.stats().table_check_us;
    try testing.expect(check_us > 0);
    try testing.expectEqual(@as(u32, 0), h.svc.stats().session_deaths);
    {
        const l = try Loaded.open(gen2);
        defer l.close();
        try expectFixtureTable(l);
        // The edit changed the build id and not the layout.
        try testing.expect(!std.mem.eql(u8, &first_id, str(l.table.build_id)));
        try testing.expectEqual(first_hash, abi.layoutHash(&l.scripts()[1]));
    }

    if (timingOn()) std.debug.print(
        "sdk_e2e: fixture project: session-start build {d} ms, warm-up {d} ms, incremental body edit {d} ms (table check {d} us)\n",
        .{ o1.ms, warm_ms, o2.ms, check_us },
    );
}

/// One script that must fail with exactly `sentence`, reported at `rel` on
/// the first line that starts with `decl`.
const BadScript = struct { rel: []const u8, data: []const u8, sentence: []const u8, decl: []const u8 };

const prelude =
    \\const z = @import("ziggurat");
    \\const g = z.godot;
    \\
;

/// A script with inline anonymous field types, a union over a named tag and
/// two different anonymous structs. `tag_values` is the body of `Tag`.
fn anonScript(comptime tag_values: []const u8) []const u8 {
    return prelude ++
        \\pub const extends = g.Node;
        \\mode: enum { idle, run } = .idle,
        \\layers: packed struct { ground: bool = true, water: bool = false } = .{},
        \\_inner: struct { v: i32 = 0, w: f32 = 0 } = .{},
        \\_a: struct { x: i32 = 0 } = .{},
        \\_b: struct { y: i32 = 0 } = .{},
        \\_u: U = .{ .a = 0 },
        \\_opt: ?struct { k: [2]enum { p, q } = .{ .p, .q } } = null,
        \\pub const U = union(Tag) { a: i32, b: f32 };
        \\
    ++ "pub const Tag = enum(u8) { " ++ tag_values ++ " };\n";
}

/// Analysed before `s.zig` (paths sort first): it resolves more anonymous
/// types, which moves Zig's counters for the types analysed after it.
const anon_first = prelude ++
    \\pub const extends = g.Node;
    \\_p: struct { a: u8 = 0 } = .{},
    \\_q: enum { x, y } = .x,
    \\_r: union { a: i32, b: u8 } = .{ .a = 0 },
    \\_s: packed struct { a: bool = false } = .{},
    \\_t: struct { z: struct { y: u8 = 0 } = .{} } = .{},
    \\pub fn touch(self: *@This()) i64 {
    \\    const L = struct { k: u8, m: enum { u, v } };
    \\    _ = self;
    \\    return @sizeOf(L);
    \\}
    \\
;

const FieldSnap = struct { name: []const u8, type_name: []const u8, shape: u64, bits: u32 };
const ScriptSnap = struct { fields: []const FieldSnap, layout_hash: u64 };

/// Builds `files` in a fresh project and copies the fields of `rel`.
fn snapFields(a: std.mem.Allocator, files: []const File, rel: []const u8) !ScriptSnap {
    var h: Harness = undefined;
    try h.initOpts(files, .{ .check_tables = true });
    defer h.deinit();
    const o = try h.build(.open);
    try expectOk(o);
    const l = try Loaded.open(o.generation orelse return error.NoGeneration);
    defer l.close();
    try l.validate();
    for (l.scripts()) |*d| {
        if (!std.mem.eql(u8, str(d.path), rel)) continue;
        const out = try a.alloc(FieldSnap, d.field_count);
        for (d.fields[0..d.field_count], out) |f, *fs| fs.* = .{
            .name = try a.dupe(u8, str(f.name)),
            .type_name = try a.dupe(u8, str(f.type_name)),
            .shape = f.shape,
            .bits = f.bits,
        };
        return .{ .fields = out, .layout_hash = abi.layoutHash(d) };
    }
    return error.ScriptMissing;
}

fn snapField(s: ScriptSnap, name: []const u8) !FieldSnap {
    for (s.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return error.FieldMissing;
}

/// True when `name` still holds one of Zig's anonymous-type counters.
fn hasCounter(name: []const u8) bool {
    for ([_][]const u8{ "__struct_", "__enum_", "__union_", "__opaque_" }) |m| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, name, at, m)) |k| : (at = k + 1) {
            if (k + m.len < name.len and std.ascii.isDigit(name[k + m.len])) return true;
        }
    }
    return false;
}

test "integration: type names and shapes are stable across builds" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 = anonScript("a = 1, b = 0");

    // The same script alone and after another script full of anonymous types.
    const alone = try snapFields(a, &.{.{ .rel = "s.zig", .data = v1 }}, "s.zig");
    const after = try snapFields(a, &.{ .{ .rel = "0first.zig", .data = anon_first }, .{ .rel = "s.zig", .data = v1 } }, "s.zig");
    try testing.expectEqual(alone.fields.len, after.fields.len);
    for (alone.fields, after.fields) |x, y| {
        errdefer std.debug.print("field {s}: {s} / {s}\n", .{ x.name, x.type_name, y.type_name });
        try testing.expect(!hasCounter(x.type_name));
        try testing.expectEqualStrings(x.type_name, y.type_name);
        try testing.expectEqual(x.shape, y.shape);
    }
    try testing.expectEqual(alone.layout_hash, after.layout_hash);

    // Two different anonymous structs: one name, told apart by shape.
    const fa = try snapField(alone, "_a");
    const fb = try snapField(alone, "_b");
    try testing.expectEqualStrings(fa.type_name, fb.type_name);
    try testing.expect(fa.shape != 0 and fb.shape != 0 and fa.shape != fb.shape);
    // The logical bit widths of the enum and the flags.
    try testing.expectEqual(@as(u32, 1), (try snapField(alone, "mode")).bits);
    try testing.expectEqual(@as(u32, 2), (try snapField(alone, "layers")).bits);

    // Only the tag values change: the union keeps its name, not its shape.
    const v2 = try snapFields(a, &.{.{ .rel = "s.zig", .data = anonScript("a = 0, b = 1") }}, "s.zig");
    const union1 = try snapField(alone, "_u");
    const union2 = try snapField(v2, "_u");
    try testing.expectEqualStrings(union1.type_name, union2.type_name);
    try testing.expect(union1.shape != union2.shape);
    try testing.expect(alone.layout_hash != v2.layout_hash);
}

const bad_scripts = [_]BadScript{
    .{
        .rel = "bad_getter.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\pub fn get_speed(self: *const @This()) f64 {
            \\    return self.speed;
            \\}
            \\
        ,
        .sentence = "'get_speed' overrides reading 'speed' and must be 'pub fn get_speed(self: *const @This()) f32'.",
        .decl = "pub fn get_speed",
    },
    .{
        .rel = "bad_init.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\pub fn init(self: *@This()) bool {
            \\    _ = self;
            \\    return true;
            \\}
            \\
        ,
        .sentence = "'init' must be 'pub fn init(self: *@This()) void'.",
        .decl = "pub fn init",
    },
    .{
        .rel = "bad_deinit.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\pub fn deinit(self: *const @This()) void {
            \\    _ = self;
            \\}
            \\
        ,
        .sentence = "'deinit' must be 'pub fn deinit(self: *@This()) void'.",
        .decl = "pub fn deinit",
    },
    .{
        .rel = "full_default.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\title: z.String = .{ ._raw = .{ .@"_" = .{ 1, 0, 0, 0, 0, 0, 0, 0 } } },
            \\
        ,
        .sentence = "Field 'title' must default to an empty value (.empty or .{}), because every instance starts as a copy of the defaults.",
        .decl = "title:",
    },
    // A field of a borrowed text type: the owning field types are required.
    .{
        .rel = "plain_string.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\title: g.String = .empty,
            \\
        ,
        .sentence = "Field 'title' has type String; use z.String for a field, so stored text is owned.",
        .decl = "title:",
    },
    .{
        .rel = "plain_string_name.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\_tag: g.StringName = .empty,
            \\
        ,
        .sentence = "Field '_tag' has type StringName; use z.StringName for a field, so stored text is owned.",
        .decl = "_tag:",
    },
    .{
        .rel = "plain_node_path.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\target: g.NodePath = std.mem.zeroes(g.NodePath),
            \\const std = @import("std");
            \\
        ,
        .sentence = "Field 'target' has type NodePath; use z.NodePath for a field, so stored text is owned.",
        .decl = "target:",
    },
    .{
        .rel = "bad_setter.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\pub fn set_speed(self: *@This(), value: f64) void {
            \\    self.speed = @floatCast(value);
            \\}
            \\
        ,
        .sentence = "'set_speed' overrides writing 'speed' and must be 'pub fn set_speed(self: *@This(), value: f32) void'.",
        .decl = "pub fn set_speed",
    },
    .{
        .rel = "bad_notification.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\pub fn _notification(self: *@This(), what: i64) void {
            \\    _ = self;
            \\    _ = what;
            \\}
            \\
        ,
        .sentence = "'_notification' must be 'pub fn _notification(self: *@This(), what: i32) void'.",
        .decl = "pub fn _notification",
    },
    .{
        .rel = "h#a%25x[b]:c/bad_type.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\base: *g.Node,
            \\count: u64 = 0,
            \\
        ,
        .sentence = "Field 'count' has type u64, which Godot cannot hold; not supported in v1.",
        .decl = "count:",
    },
    .{
        .rel = "obj_ptr.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\target: ?*g.Node2D = null,
            \\
        ,
        .sentence = "Field 'target' has type ?*Node2D, which Godot cannot hold; use z.Obj(Node2D).",
        .decl = "target:",
    },
    .{
        .rel = "no_default.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\
            \\health: i32 = 1,
            \\speed: f32,
            \\
        ,
        .sentence = "Field 'speed' needs a default value.",
        .decl = "speed:",
    },
    .{
        .rel = "bad_base.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\base: *g.Node2D,
            \\
        ,
        .sentence = "Field 'base' must have type *Node.",
        .decl = "base:",
    },
    .{
        .rel = "bad_extends.zig",
        .data = prelude ++
            \\
            \\pub const extends = u8;
            \\
        ,
        .sentence = "extends must be a Godot engine class, found u8.",
        .decl = "pub const extends",
    },
    .{
        .rel = "bad_class_name.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\pub const class_name = "my class";
            \\
        ,
        .sentence = "class_name 'my class' must be an identifier.",
        .decl = "pub const class_name",
    },
    .{
        .rel = "meta_unknown.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\
            \\pub const meta = .{ .speed = .{ .range = .{ 0, 10 } }, .sped = .{ .range = .{ 0, 10 } } };
            \\
        ,
        .sentence = "meta names 'sped', which is not a field or method of this script.",
        .decl = "pub const meta",
    },
    .{
        .rel = "meta_key.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\health: i32 = 1,
            \\speed: f32 = 1,
            \\
            \\pub const meta = .{ .speed = .{ .rnage = .{ 0, 10 } } };
            \\
        ,
        .sentence = "meta key 'rnage' for 'speed' is not one of range, group, name, hint, hint_string.",
        .decl = "speed:",
    },
    .{
        .rel = "meta_method_key.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\pub const meta = .{ .jump = .{ .nmae = "leap" } };
            \\
            \\pub fn jump(self: *@This()) void {
            \\    _ = self;
            \\}
            \\
        ,
        .sentence = "meta key 'nmae' for 'jump' is not one of name, args.",
        .decl = "pub fn jump",
    },
    .{
        .rel = "collide.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\
            \\pub fn getHUD(self: *@This()) void {
            \\    _ = self;
            \\}
            \\
            \\pub fn getHud(self: *@This()) void {
            \\    _ = self;
            \\}
            \\
        ,
        .sentence = "'getHUD' and 'getHud' both map to the Godot name 'get_hud'; give one a name override in meta.",
        .decl = "pub fn getHud",
    },
    .{
        .rel = "collide_kinds.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\take_damage: i32 = 0,
            \\
            \\pub fn takeDamage(self: *@This()) void {
            \\    _ = self;
            \\}
            \\
        ,
        .sentence = "'take_damage' and 'takeDamage' both map to the Godot name 'take_damage'; give one a name override in meta.",
        .decl = "pub fn takeDamage",
    },
    .{
        .rel = "collide_reverse.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\height: f32 = 0,
            \\pub const meta = .{ .height = .{ .name = "jump" } };
            \\
            \\pub fn jump(self: *@This()) void {
            \\    _ = self;
            \\}
            \\
        ,
        .sentence = "'height' and 'jump' both map to the Godot name 'jump'; give one a name override in meta.",
        .decl = "pub fn jump",
    },
    .{
        .rel = "by_value.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\
            \\pub fn boost(self: @This()) f32 {
            \\    return self.speed;
            \\}
            \\
        ,
        .sentence = "Method 'boost' takes the script by value; take self as *@This() or *const @This().",
        .decl = "pub fn boost",
    },
    .{
        .rel = "range_on_bool.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\alive: bool = true,
            \\pub const meta = .{ .alive = .{ .range = .{ 0, 1 } } };
            \\
        ,
        .sentence = "meta range for 'alive' needs a number field, but 'alive' has type bool.",
        .decl = "alive:",
    },
    .{
        .rel = "neither.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\thing: z.Obj(g.Object) = .{},
            \\
        ,
        .sentence = "Field 'thing' holds z.Obj(Object), which is neither a Node nor a Resource; Godot cannot export it.",
        .decl = "thing:",
    },
    .{
        .rel = "weak_resource.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\tex: z.Obj(g.Texture2D) = .{},
            \\
        ,
        .sentence = "Field 'tex' holds z.Obj(Texture2D), a Resource that the field would not keep alive; use z.Ref(Texture2D).",
        .decl = "tex:",
    },
    .{
        .rel = "enum_tag.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\mode: enum { plain, @"a:b" } = .plain,
            \\
        ,
        .sentence = "Field 'mode' has the enum tag 'a:b', which Godot's enum hint cannot show because it contains ',' or ':'.",
        .decl = "mode:",
    },
    .{
        .rel = "bad_param.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\
            \\pub fn hit(self: *@This(), amount: u64) void {
            \\    _ = self;
            \\    _ = amount;
            \\}
            \\
        ,
        .sentence = "Method 'hit' has a parameter of type u64, which Godot cannot pass.",
        .decl = "pub fn hit",
    },
    .{
        .rel = "bad_return.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\
            \\pub fn name(self: *@This()) []const u8 {
            \\    _ = self;
            \\    return "x";
            \\}
            \\
        ,
        .sentence = "Method 'name' returns []const u8, which Godot cannot hold.",
        .decl = "pub fn name",
    },
    .{
        .rel = "bad_signal.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\
            \\pub const signals = struct {
            \\    pub const hit = struct { amount: u64 };
            \\};
            \\
        ,
        .sentence = "Signal 'hit' argument 'amount' has type u64, which Godot cannot hold.",
        .decl = "pub const signals",
    },
    // Names, strings and counts the host's validator would refuse. A name
    // that is not an identifier has no line to point at: line 1.
    .{
        .rel = "spaced_field.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\@"max hp": i32 = 0,
            \\
        ,
        .sentence = "Field 'max hp' needs an identifier name (letters, digits and '_', not starting with a digit).",
        .decl = "const z",
    },
    .{
        .rel = "spaced_signal_arg.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\
            \\pub const signals = struct {
            \\    pub const hit = struct { @"a b": i32 };
            \\};
            \\
        ,
        .sentence = "Signal 'hit' argument 'a b' needs an identifier name (letters, digits and '_', not starting with a digit).",
        .decl = "pub const signals",
    },
    .{
        .rel = "many_args.zig",
        .data = many_args_script,
        .sentence = "Method 'many' takes 65 arguments; Godot allows at most 64.",
        .decl = "pub fn many",
    },
    .{
        .rel = "long_hint.zig",
        .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = 1,
            \\pub const meta = .{ .speed = .{ .hint_string = &@as([4097]u8, @splat('x')) } };
            \\
        ,
        .sentence = "The hint string of 'speed' is 4097 bytes long; the limit is 4096.",
        .decl = "speed:",
    },
};

/// A method with 65 parameters, one above the validator's limit.
const many_args_script = blk: {
    var s: []const u8 = prelude ++ "pub const extends = g.Node;\npub fn many(self: *@This()";
    for (0..65) |_| s = s ++ ", _: i32";
    break :blk s ++ ") void {\n    _ = self;\n}\n";
};

fn lineOf(text: []const u8, prefix: []const u8) u32 {
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 1;
    while (it.next()) |l| : (n += 1) {
        if (std.mem.startsWith(u8, l, prefix)) return n;
    }
    return 0;
}

fn printDiagnostics(o: Outcome) void {
    for (o.diagnostics) |d| std.debug.print("  {?s}:{d}:{d}: {s}\n", .{ d.rel, d.line, d.column, d.message });
}

test "integration: compile errors map to the script" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // The compiler stops at the first script whose descriptor fails, so each
    // bad script gets a build of its own: one service, one script at a time.
    var h: Harness = undefined;
    try h.init(&.{});
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var total_ms: u64 = 0;
    for (bad_scripts) |c| {
        errdefer std.debug.print("case {s}\n", .{c.rel});
        const sub = try std.fmt.allocPrint(a, "proj/{s}", .{c.rel});
        if (std.fs.path.dirname(sub)) |dir| try h.tmp.dir.createDirPath(io, dir);
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = c.data });
        defer h.tmp.dir.deleteFile(io, sub) catch {};

        const o = try h.build(.save);
        total_ms += o.ms;
        errdefer printDiagnostics(o);
        try testing.expect(!o.ok);
        const want_line = lineOf(c.data, c.decl);
        try testing.expect(want_line != 0);
        const d = for (o.diagnostics) |d| {
            if (d.rel != null and std.mem.eql(u8, d.rel.?, c.rel)) break d;
        } else return error.NoDiagnosticForScript;
        if (!std.mem.eql(u8, d.message, c.sentence)) {
            std.debug.print("want: {s}\ngot:  {s}\n", .{ c.sentence, d.message });
            return error.WrongMessage;
        }
        try testing.expectEqual(want_line, d.line);
    }

    // A field defaulting to `undefined` fails through Zig's own error (no
    // marker), for scalars and for struct types alike; see sdk/describe.zig.
    const undef_cases = [_]File{
        .{ .rel = "undef_f32.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\speed: f32 = undefined,
            \\
        },
        .{ .rel = "undef_vector.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\spawn: z.godot.Vector2 = undefined,
            \\
        },
        .{ .rel = "undef_string.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\_name: z.String = undefined,
            \\
        },
    };
    for (undef_cases) |c| {
        errdefer std.debug.print("case {s}\n", .{c.rel});
        const sub = try std.fmt.allocPrint(a, "proj/{s}", .{c.rel});
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = c.data });
        defer h.tmp.dir.deleteFile(io, sub) catch {};
        const o = try h.build(.save);
        total_ms += o.ms;
        errdefer printDiagnostics(o);
        try testing.expect(!o.ok);
        const undef = for (o.diagnostics) |d| {
            if (std.mem.indexOf(u8, d.message, "undefined") != null) break d;
        } else return error.NoUndefinedError;
        if (timingOn()) std.debug.print("sdk_e2e: {s}: undefined default reported as {?s}:{d}: {s}\n", .{ c.rel, undef.rel, undef.line, undef.message });
    }
    // Storing a borrowed value in an owned text field, or handing a field
    // to `Owned`, is Zig's own type error at the script line.
    const misuse_cases = [_]BadScript{
        .{ .rel = "store_arg.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\name: z.String = .empty,
            \\pub fn rename(self: *@This(), value: g.String) void {
            \\    self.name = value;
            \\}
            \\
        , .sentence = "expected type", .decl = "    self.name = value;" },
        .{ .rel = "store_owned.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\name: z.String = .empty,
            \\pub fn rename(self: *@This(), value: g.String) void {
            \\    self.name = z.Owned(g.String).init(g.String.copy(value));
            \\}
            \\
        , .sentence = "expected type", .decl = "    self.name = z.Owned" },
        .{ .rel = "owned_field.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\name: z.String = .empty,
            \\pub fn label(self: *const @This()) z.Owned(g.String) {
            \\    return .init(self.name);
            \\}
            \\
        , .sentence = "expected type", .decl = "    return .init(self.name);" },
        .{ .rel = "owned_get.zig", .data = prelude ++
            \\pub const extends = g.Node;
            \\name: z.String = .empty,
            \\pub fn label(self: *const @This()) z.Owned(g.String) {
            \\    return .init(self.name.get());
            \\}
            \\
        , .sentence = "expected type", .decl = "    return .init(self.name.get());" },
    };
    for (misuse_cases) |c| {
        errdefer std.debug.print("case {s}\n", .{c.rel});
        const sub = try std.fmt.allocPrint(a, "proj/{s}", .{c.rel});
        try h.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = c.data });
        defer h.tmp.dir.deleteFile(io, sub) catch {};
        const o = try h.build(.save);
        total_ms += o.ms;
        errdefer printDiagnostics(o);
        try testing.expect(!o.ok);
        const want_line = lineOf(c.data, c.decl);
        try testing.expect(want_line != 0);
        const d = for (o.diagnostics) |d| {
            if (d.rel != null and std.mem.eql(u8, d.rel.?, c.rel)) break d;
        } else return error.NoDiagnosticForScript;
        try testing.expectEqual(want_line, d.line);
        try testing.expect(std.mem.indexOf(u8, d.message, c.sentence) != null);
        if (timingOn()) std.debug.print("sdk_e2e: {s}: {s}:{d}: {s}\n", .{ c.rel, d.rel.?, d.line, d.message });
    }
    if (timingOn()) std.debug.print("sdk_e2e: {d} failing builds took {d} ms in total\n", .{ bad_scripts.len + undef_cases.len + misuse_cases.len, total_ms });
}

/// A script with two signals and a method that emits one. `{s}` is the
/// argument struct of the emit and `{d}` a number in the method body.
fn heroScript(a: std.mem.Allocator, emit_args: []const u8, n: i32) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\const z = @import("ziggurat");
        \\const g = z.godot;
        \\pub const extends = g.CharacterBody2D;
        \\base: *g.CharacterBody2D,
        \\health: i32 = 100,
        \\
        \\pub const signals = struct {{
        \\    pub const died = struct {{}};
        \\    pub const hit = struct {{ damage: i32, source: ?*g.Node }};
        \\}};
        \\
        \\pub fn takeDamage(self: *@This(), amount: i32) void {{
        \\    self.health -= amount + {d};
        \\    z.emit(self, {s});
        \\    if (self.health <= 0) z.emit(self, .died, .{{}});
        \\}}
        \\
    , .{ n, emit_args });
}

test "integration: emit compile errors" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A correct emit (number literal, null for an optional object) builds.
    var h: Harness = undefined;
    try h.init(&.{.{ .rel = "hero.zig", .data = try heroScript(a, ".hit, .{ .damage = 1, .source = null }", 0) }});
    defer h.deinit();
    try expectOk(try h.build(.open));

    const cases = [_]struct { args: []const u8, sentence: []const u8 }{
        .{
            .args = ".hti, .{ .damage = amount, .source = null }",
            .sentence = "'hti' is not a signal of this script; its signals are died, hit.",
        },
        .{
            .args = ".hit, .{ .damage = \"x\", .source = null }",
            .sentence = "emit of 'hit' passes 'damage' as *const [1:0]u8, but the signal declares i32.",
        },
        .{
            .args = ".hit, .{ .damage = amount }",
            .sentence = "emit of 'hit' is missing the argument 'source'.",
        },
        .{
            .args = ".hit, .{ .damage = amount, .source = null, .extra = 1 }",
            .sentence = "emit of 'hit' passes 'extra', which is not an argument of the signal.",
        },
    };
    for (cases) |c| {
        errdefer std.debug.print("case {s}\n", .{c.args});
        const data = try heroScript(a, c.args, 0);
        try h.write("hero.zig", data);
        const o = try h.build(.save);
        errdefer printDiagnostics(o);
        try testing.expect(!o.ok);
        const d = for (o.diagnostics) |d| {
            if (d.rel != null and std.mem.eql(u8, d.rel.?, "hero.zig")) break d;
        } else return error.NoDiagnosticForScript;
        if (!std.mem.eql(u8, d.message, c.sentence)) {
            std.debug.print("want: {s}\ngot:  {s}\n", .{ c.sentence, d.message });
            return error.WrongMessage;
        }
        try testing.expectEqual(lineOf(data, "pub const signals"), d.line);
    }

    // Compile probe: scripts cannot build a Callable from a function pointer.
    const probe =
        \\const z = @import("ziggurat");
        \\pub const extends = z.godot.Node;
        \\base: *z.godot.Node,
        \\fn cb() void {}
        \\pub fn hook(self: *@This()) void {
        \\    _ = z.godot.Callable.fromClosure(self, cb);
        \\}
        \\
    ;
    try h.write("hero.zig", probe);
    const o = try h.build(.save);
    errdefer printDiagnostics(o);
    try testing.expect(!o.ok);
    for (o.diagnostics) |d| {
        if (d.rel != null and std.mem.eql(u8, d.rel.?, "hero.zig") and d.line == 6 and
            std.mem.indexOf(u8, d.message, "fromClosure") != null) break;
    } else return error.FromClosureNotRefused;
}

/// Number of scripts in the large-project emit test.
const many_scripts = 1500;

test "integration: emit error in a large project" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Many small scripts with paths of the same length, so the marker lookup
    // compares bytes for each one; the last one emits an unknown signal.
    const files = try a.alloc(File, many_scripts);
    for (files, 0..) |*f, i| {
        f.rel = try std.fmt.allocPrint(a, "scripts/enemy_{d:0>4}.zig", .{i});
        f.data = "const z = @import(\"ziggurat\");\npub const extends = z.godot.Node;\nbase: *z.godot.Node,\n";
    }
    const bad =
        \\const z = @import("ziggurat");
        \\pub const extends = z.godot.Node;
        \\base: *z.godot.Node,
        \\pub const signals = struct {
        \\    pub const hit = struct {};
        \\};
        \\pub fn go(self: *@This()) void {
        \\    z.emit(self, .miss, .{});
        \\}
        \\
    ;
    files[many_scripts - 1].data = bad;
    var h: Harness = undefined;
    try h.init(files);
    defer h.deinit();
    const o = try h.build(.open);
    errdefer printDiagnostics(o);
    if (timingOn()) std.debug.print("sdk_e2e: {d}-script project with an emit error built in {d} ms\n", .{ many_scripts, o.ms });
    try testing.expect(!o.ok);
    const want_rel = files[many_scripts - 1].rel;
    const d = for (o.diagnostics) |d| {
        if (d.rel != null and std.mem.eql(u8, d.rel.?, want_rel)) break d;
    } else return error.NoDiagnosticForScript;
    try testing.expectEqualStrings("'miss' is not a signal of this script; its signals are hit.", d.message);
    try testing.expectEqual(@as(u32, 4), d.line);
}

fn expectGenGone(o_store: []const u8, n: u32) !void {
    var buf: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&buf, "{s}/gen/{d}", .{ o_store, n });
    if (std.Io.Dir.cwd().access(io, p, .{})) |_| return error.GenerationStillThere else |_| {}
}

test "integration: incremental check passes" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const emit_args = ".hit, .{ .damage = amount, .source = null }";

    var h: Harness = undefined;
    try h.initOpts(&.{.{ .rel = "hero.zig", .data = try heroScript(a, emit_args, 0) }}, .{ .check_tables = true });
    defer h.deinit();
    const o1 = try h.build(.open);
    try expectOk(o1);
    try testing.expectEqual(service.BuildPath.full, o1.path);
    try h.svc.waitWarm(build_wait_ms);

    // Two body edits, each checked.
    var check_us: [2]u64 = undefined;
    for (1..3) |i| {
        try h.write("hero.zig", try heroScript(a, emit_args, @intCast(i)));
        const o = try h.build(.save);
        try expectOk(o);
        try testing.expectEqual(service.BuildPath.incremental, o.path);
        try testing.expect(o.message == null);
        try testing.expectEqual(@as(u32, @intCast(1 + i)), o.generation.?.n);
        check_us[i - 1] = h.svc.stats().table_check_us;
        try testing.expect(check_us[i - 1] > 0);
        if (timingOn()) std.debug.print("sdk_e2e: incremental edit {d} ms, of which the table check {d} us\n", .{ o.ms, check_us[i - 1] });
    }
    try testing.expectEqual(@as(u32, 0), h.svc.stats().session_deaths);
}

test "integration: stale table is caught" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const emit_args = ".hit, .{ .damage = amount, .source = null }";

    var h: Harness = undefined;
    try h.initOpts(&.{.{ .rel = "hero.zig", .data = try heroScript(a, emit_args, 0) }}, .{
        .check_tables = true,
        .test_stale_build_id = true,
    });
    defer h.deinit();
    const o1 = try h.build(.open);
    try expectOk(o1);
    try h.svc.waitWarm(build_wait_ms);

    try h.write("hero.zig", try heroScript(a, emit_args, 1));
    const o2 = try h.build(.save);
    try expectOk(o2);
    try testing.expectEqual(service.BuildPath.full, o2.path);
    try testing.expectEqualStrings(service.stale_note, o2.message.?);
    // The incremental output was staged as 2, checked, and deleted; the full
    // build that replaced it never reuses that number.
    try testing.expectEqual(@as(u32, 3), o2.generation.?.n);
    const store = try std.fs.path.join(a, &.{ try h.tmp.dir.realPathFileAlloc(io, ".", a), "store" });
    try expectGenGone(store, 2);
    try std.Io.Dir.cwd().access(io, o2.generation.?.lib.bytes, .{});
    try testing.expectEqual(@as(u32, 1), h.svc.stats().session_deaths);
}

/// A script named `class` whose body changes with `n`.
fn namedScript(a: std.mem.Allocator, class: []const u8, n: i32) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\const z = @import("ziggurat");
        \\pub const extends = z.godot.Node;
        \\pub const class_name = "{s}";
        \\base: *z.godot.Node,
        \\hp: i32 = {d},
        \\
    , .{ class, n });
}

const duplicate_sentence = "The table has two scripts with the class name \"Hero\": \"a_hero.zig\" and \"b_hero.zig\".";

test "integration: invalid table fails the full build" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two scripts with one class name: the SDK compiles it, the validator
    // refuses it, and a rebuild would not change that.
    var h: Harness = undefined;
    try h.initOpts(&.{
        .{ .rel = "a_hero.zig", .data = try namedScript(a, "Hero", 0) },
        .{ .rel = "b_hero.zig", .data = try namedScript(a, "Hero", 0) },
    }, .{ .check_tables = true });
    defer h.deinit();
    const o = try h.build(.open);
    try testing.expect(!o.ok);
    try testing.expectEqual(service.BuildPath.full, o.path);
    try testing.expect(o.generation == null);
    try testing.expectEqualStrings(duplicate_sentence, o.message.?);
    try testing.expect(h.svc.stats().table_check_us > 0);
    try testing.expectEqual(@as(u32, 0), h.svc.stats().session_deaths);
    const store = try std.fs.path.join(a, &.{ try h.tmp.dir.realPathFileAlloc(io, ".", a), "store" });
    try expectGenGone(store, 1);
}

test "integration: invalid table fails the incremental build" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var h: Harness = undefined;
    try h.initOpts(&.{
        .{ .rel = "a_hero.zig", .data = try namedScript(a, "Hero", 0) },
        .{ .rel = "b_hero.zig", .data = try namedScript(a, "Villain", 0) },
    }, .{ .check_tables = true });
    defer h.deinit();
    const o1 = try h.build(.open);
    try expectOk(o1);
    // Full builds are checked too.
    try testing.expect(h.svc.stats().table_check_us > 0);
    try h.svc.waitWarm(build_wait_ms);

    // The edit makes the table invalid: the build fails with the
    // validator's sentence, on the incremental path, with no full rebuild.
    try h.write("b_hero.zig", try namedScript(a, "Hero", 1));
    const o2 = try h.build(.save);
    try testing.expect(!o2.ok);
    try testing.expectEqual(service.BuildPath.incremental, o2.path);
    try testing.expect(o2.generation == null);
    try testing.expectEqualStrings(duplicate_sentence, o2.message.?);
    try testing.expectEqual(@as(u32, 0), h.svc.stats().session_deaths);
    const store = try std.fs.path.join(a, &.{ try h.tmp.dir.realPathFileAlloc(io, ".", a), "store" });
    try expectGenGone(store, 2);

    // The server is still warm: the fix builds incrementally.
    try h.write("b_hero.zig", try namedScript(a, "Villain", 2));
    const o3 = try h.build(.save);
    try expectOk(o3);
    try testing.expectEqual(service.BuildPath.incremental, o3.path);
    try testing.expect(o3.message == null);
    try testing.expectEqual(@as(u32, 3), o3.generation.?.n);
    try testing.expectEqual(@as(u32, 0), h.svc.stats().session_deaths);
}

/// Runs `argv`; it must print `Zig panic: probe` on stderr and die from a signal.
fn expectPanicDeath(argv: []const []const u8) !void {
    const a = testing.allocator;
    const r = try platform.process.runCapture(a, io, argv, null, 60_000, 1 << 20);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "Zig panic: probe") != null);
    switch (r.term) {
        .signal => {},
        else => {
            std.debug.print("probe {s} ended with {any}\nstderr: {s}\n", .{ argv[0], r.term, r.stderr });
            return error.NotKilledBySignal;
        },
    }
}

test "integration: panic probe executable, Debug and ReleaseSafe" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectPanicDeath(&.{build_options.panic_exe_debug});
    try expectPanicDeath(&.{build_options.panic_exe_safe});
}

test "integration: panic probe in a -lc dynamic library, Debug and ReleaseSafe" {
    try platform.testing_support.requireIntegration();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectPanicDeath(&.{ build_options.panic_loader, build_options.panic_lib_debug });
    try expectPanicDeath(&.{ build_options.panic_loader, build_options.panic_lib_safe });
}
