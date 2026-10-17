//! End-to-end tests for the Stage 2 SDK: the build service compiling user
//! scripts against the real SDK and gdzig, with the module list from the SDK
//! manifest (`build_options.sdk_manifest_path`, written by the build).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform = @import("ziggurat_platform");
const zbuild = @import("ziggurat_build");
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

/// A temp project with `files`, the SDK manifest and a `BuildService` on it.
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    manifest: zbuild.sdk_manifest.Manifest,
    env: platform.path.HostEnv,
    svc: *BuildService,

    /// `h` must not move while the service runs; the config borrows from it.
    fn init(h: *Harness, files: []const File) !void {
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
        });
    }

    fn deinit(h: *Harness) void {
        h.svc.deinit();
        h.tmp.cleanup();
        h.manifest.deinit(testing.allocator);
        h.arena.deinit();
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

    // gdzig keeps engine classes in `class`; the SDK's `godot` is gdzig as is for now.
    var h: Harness = undefined;
    try h.init(&.{.{ .rel = "a.zig", .data = "pub const extends = @import(\"ziggurat\").godot.class.Node;\n" }});
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
    try out.appendSlice(a, "const z = @import(\"ziggurat\");\npub const extends = z.godot.class.Node;\nbase: *z.godot.class.Node,\n");
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

/// One script that must fail with exactly `sentence`, reported at `rel` on
/// the first line that starts with `decl`.
const BadScript = struct { rel: []const u8, data: []const u8, sentence: []const u8, decl: []const u8 };

const prelude =
    \\const z = @import("ziggurat");
    \\const class = z.godot.class;
    \\
;

const bad_scripts = [_]BadScript{
    .{
        .rel = "bad_setter.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
            \\base: *class.Node,
            \\count: u64 = 0,
            \\
        ,
        .sentence = "Field 'count' has type u64, which Godot cannot hold; not supported in v1.",
        .decl = "count:",
    },
    .{
        .rel = "obj_ptr.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
            \\speed: f32 = 1,
            \\target: ?*class.Node2d = null,
            \\
        ,
        .sentence = "Field 'target' has type ?*Node2d, which Godot cannot hold; use z.Obj(Node2d).",
        .decl = "target:",
    },
    .{
        .rel = "no_default.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
            \\base: *class.Node2d,
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
            \\pub const extends = class.Node;
            \\pub const class_name = "my class";
            \\
        ,
        .sentence = "class_name 'my class' must be an identifier.",
        .decl = "pub const class_name",
    },
    .{
        .rel = "meta_unknown.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
            \\speed: f32 = 1,
            \\thing: z.Obj(class.Object) = .{},
            \\
        ,
        .sentence = "Field 'thing' holds z.Obj(Object), which is neither a Node nor a Resource; Godot cannot export it.",
        .decl = "thing:",
    },
    .{
        .rel = "weak_resource.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
            \\speed: f32 = 1,
            \\tex: z.Obj(class.Texture2d) = .{},
            \\
        ,
        .sentence = "Field 'tex' holds z.Obj(Texture2d), a Resource that the field would not keep alive; use z.Ref(Texture2d).",
        .decl = "tex:",
    },
    .{
        .rel = "enum_tag.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
            \\mode: enum { plain, @"a:b" } = .plain,
            \\
        ,
        .sentence = "Field 'mode' has the enum tag 'a:b', which Godot's enum hint cannot show because it contains ',' or ':'.",
        .decl = "mode:",
    },
    .{
        .rel = "bad_param.zig",
        .data = prelude ++
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
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
            \\pub const extends = class.Node;
            \\
            \\pub const signals = struct {
            \\    pub const hit = struct { amount: u64 };
            \\};
            \\
        ,
        .sentence = "Signal 'hit' argument 'amount' has type u64, which Godot cannot hold.",
        .decl = "pub const signals",
    },
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
            \\pub const extends = class.Node;
            \\speed: f32 = undefined,
            \\
        },
        .{ .rel = "undef_vector.zig", .data = prelude ++
            \\pub const extends = class.Node;
            \\spawn: z.godot.builtin.Vector2 = undefined,
            \\
        },
        .{ .rel = "undef_string.zig", .data = prelude ++
            \\pub const extends = class.Node;
            \\_name: z.godot.builtin.String = undefined,
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
    if (timingOn()) std.debug.print("sdk_e2e: {d} failing builds took {d} ms in total\n", .{ bad_scripts.len + undef_cases.len, total_ms });
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
