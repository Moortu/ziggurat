//! The host's minimal module runtime (L3, Stage 3): load one generation of
//! the user module, check its table, initialise it and map names to indexes.
//! Swaps, the gate and migration are Stage 4.
//!
//! `load` follows the host contract in `src/abi/abi.zig`: open the staged
//! library, look up `ziggurat_describe` and `ziggurat_init`, `validate` the
//! table against the stamp this host was built for, then call
//! `ziggurat_init` once with the `HostApi` below. A library refused before
//! `ziggurat_init` is closed again. A library that ran `ziggurat_init` is
//! never closed (spec section 6, unload policy): its code may still be on a
//! stack or in a Godot callback, and its static data backs the table.
//!
//! Threads: `load`, `shutdown` and `ScriptNames` construction run
//! on the main thread (`load` refuses any other). The `HostApi` functions run
//! on any thread: `mu` (locked with the process Io, `host_io`) guards the
//! list of generations; the byte counters are atomics, and memory is
//! allocated and freed outside the lock. `current` runs on any thread: the
//! current-generation pointer is atomic (release on publish, acquire on read).
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const platform = @import("ziggurat_platform");
const sdk_options = @import("sdk_options");
const names = @import("names.zig");
const host_io = @import("host_io.zig");

const Allocator = std.mem.Allocator;
const OsPath = platform.path.OsPath;
const loader = platform.loader;
const String = godot.builtin.String;

pub const ScriptNames = names.ScriptNames;

/// The layout stamp this host accepts: that of a module built against the
/// same `sdk_options` (and Zig, and target) as the host.
pub const expected_stamp: u64 = abi.expectedStamp(sdk_options);

/// The prefix of every line a module logs through the `HostApi`.
pub const log_prefix = "[ziggurat] ";

/// One loaded generation of the user module. Created by `load`, never freed
/// (its library is never closed); `shutdown` releases its engine names.
pub const Generation = struct {
    n: u32,
    lib: loader.Library,
    /// Static data of `lib`, validated.
    table: *const abi.Table,
    /// One per script, in table order. Empty after `shutdown`.
    names: []ScriptNames,
    /// Script path (as in the table) to script index.
    by_path: std.StringHashMapUnmanaged(u32),
    /// Times `ziggurat_init` was called for this generation (always 1).
    init_calls: u32 = 0,
    /// Bytes this generation holds from `HostApi.alloc` with its own tag.
    live_bytes: std.atomic.Value(u64) = .init(0),

    /// The scripts of the table.
    pub fn scripts(self: *const Generation) []const abi.ScriptDesc {
        return self.table.scripts[0..self.table.script_count];
    }
};

/// Guards `generations`. Locked with `host_io.get()`.
var mu: std.Io.Mutex = .init;
/// Every generation that ran `ziggurat_init`, oldest first. Allocated with
/// `list_allocator`. Entries are never removed or freed, so a pointer read
/// under `mu` stays valid after unlocking.
var generations: std.ArrayList(*Generation) = .empty;
var list_allocator: ?Allocator = null;
/// Bytes held on the shared user heap (tag 0). Works from the start, before
/// any load.
var user_heap_bytes: std.atomic.Value(u64) = .init(0);
/// The thread `setEngine` ran on (Godot's main thread), or null before it.
var main_thread: ?std.Thread.Id = null;
/// The generation scripts use now. Written on the main thread with release
/// ordering after the generation is complete; read from any thread
/// (script virtuals run on resource-loader threads too) with acquire
/// ordering, so a reader that sees the pointer also sees its maps.
var current_gen: std.atomic.Value(?*Generation) = .init(null);
/// Set once `request_swap` has logged.
var swap_logged: std.atomic.Value(bool) = .init(false);

/// The memory behind `HostApi.alloc` (malloc: thread-safe, any alignment).
const heap = std.heap.c_allocator;

/// The table each module keeps. `get_proc_address` and `library` are set by
/// `setEngine`.
var host_api: abi.HostApi = .{
    .size = @sizeOf(abi.HostApi),
    .get_proc_address = null,
    .library = null,
    .alloc = &apiAlloc,
    .free = &apiFree,
    .log = &apiLog,
    .request_swap = &apiRequestSwap,
};

/// Gives modules what Godot passed the host's entry point
/// (`HostApi.get_proc_address` and `library`) and records the calling
/// thread as the main thread. Call once, on Godot's main thread, before
/// `load`.
pub fn setEngine(get_proc_address: ?*const anyopaque, library: ?*anyopaque) void {
    host_api.get_proc_address = get_proc_address;
    host_api.library = library;
    main_thread = std.Thread.getCurrentId();
}

pub const LoadError = error{ Refused, NotMainThread, OutOfMemory };

/// Loads the staged library at `path` as generation `n`, which must be
/// non-zero and not loaded yet, and makes it `current`. Main thread only, at
/// a time when Godot can construct objects (`ziggurat_init` makes one).
///
/// On `error.Refused` nothing was initialised, the library is closed again,
/// `current` is unchanged and `diag` holds one sentence naming the file and
/// the loader's or validator's reason. The caller logs it.
/// On `error.NotMainThread` (called on another thread than `setEngine`)
/// nothing was touched; `diag` holds the sentence, which is also logged.
/// `a` must be thread-safe and never destroyed (the generation, its maps
/// and the generation list are never freed), like `std.heap.c_allocator`.
pub fn load(a: Allocator, path: OsPath, n: u32, diag: *[256]u8) LoadError!*Generation {
    @memset(diag, 0);
    const file = std.fs.path.basename(path.bytes);
    if (!onMainThread()) {
        var w: std.Io.Writer = .fixed(diag[0..255]);
        w.print("Ziggurat cannot load the module {s} from a thread other than the main thread.", .{file}) catch {};
        const text = std.mem.sliceTo(diag, 0);
        apiLog(@backingInt(abi.LogLevel.err), text.ptr, text.len);
        return error.NotMainThread;
    }
    const io = host_io.get();
    if (n == 0) return refuse(diag, file, "generation 0 is reserved for the shared user heap.", .{});
    if (find(n) != null) return refuse(diag, file, "generation {d} is already loaded.", .{n});

    var reason: [256]u8 = undefined;
    const lib = loader.open(a, io, path, &reason) catch {
        return refuse(diag, file, "{s}", .{lowerFirst(&reason)});
    };
    var keep = false;
    defer if (!keep) loader.close(lib);

    const describe = loader.lookup(lib, abi.DescribeFn, abi.describe_symbol) orelse
        return refuse(diag, file, "it has no {s} function.", .{abi.describe_symbol});
    const init = loader.lookup(lib, abi.InitFn, abi.init_symbol) orelse
        return refuse(diag, file, "it has no {s} function.", .{abi.init_symbol});
    const table = describe();
    abi.validate(a, table, expected_stamp, .{}, &reason) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadStamp => return refuse(diag, file, "{s}, so it was built with another SDK, Zig or Godot version.", .{
            std.mem.trimEnd(u8, lowerFirst(&reason), "."),
        }),
        else => return refuse(diag, file, "{s}", .{lowerFirst(&reason)}),
    };

    // Everything that can fail happens before `ziggurat_init`, so a failure
    // still closes the library.
    const gen = try a.create(Generation);
    errdefer a.destroy(gen);
    gen.* = .{ .n = n, .lib = lib, .table = table, .names = &.{}, .by_path = .empty };
    errdefer gen.by_path.deinit(a);
    const scripts = gen.scripts();
    try gen.by_path.ensureTotalCapacity(a, @intCast(scripts.len));
    for (scripts, 0..) |*s, i| gen.by_path.putAssumeCapacity(str(s.path), @intCast(i));

    const maps = try a.alloc(ScriptNames, scripts.len);
    var built: usize = 0;
    errdefer {
        for (maps[0..built]) |*m| m.deinit(a);
        a.free(maps);
    }
    for (scripts, 0..) |*s, i| {
        maps[i] = try ScriptNames.build(a, s);
        built += 1;
    }
    gen.names = maps;

    // Register before init: the module may allocate with its tag in init.
    mu.lockUncancelable(io);
    if (list_allocator == null) list_allocator = a;
    const appended = generations.append(list_allocator.?, gen);
    mu.unlock(io);
    try appended;

    keep = true;
    gen.init_calls += 1;
    init(&host_api, n);
    current_gen.store(gen, .release);
    return gen;
}

/// The `HostApi` every module gets.
pub fn hostApi() *const abi.HostApi {
    return &host_api;
}

/// True on the thread `setEngine` ran on, or anywhere before `setEngine`
/// (unit tests have no engine).
fn onMainThread() bool {
    const id = main_thread orelse return true;
    return std.Thread.getCurrentId() == id;
}

/// The generation scripts use now, or null before the first good load.
/// Any thread; the generation it returns is never freed.
pub fn current() ?*Generation {
    return current_gen.load(.acquire);
}

/// Makes `gen` (a loaded generation, or null) the one scripts use again,
/// after a newer generation was loaded but must not be used (the editor's
/// load checks refused it). The newer one stays loaded and never runs new
/// instances. Main thread.
pub fn setCurrent(gen: ?*Generation) void {
    current_gen.store(gen, .release);
}

/// The loaded generation `n`, or null.
pub fn find(n: u32) ?*Generation {
    const io = host_io.get();
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    return findLocked(n);
}

fn findLocked(n: u32) ?*Generation {
    for (generations.items) |g| {
        if (g.n == n) return g;
    }
    return null;
}

/// The index of the script at project-relative path `rel` (`/` separators,
/// as in the table), or null.
pub fn findScript(gen: *const Generation, rel: []const u8) ?u32 {
    return gen.by_path.get(rel);
}

/// Bytes held through `HostApi.alloc` with tag `gen` (0: the shared user
/// heap), or null for a generation that is not loaded.
pub fn liveBytes(gen: u32) ?u64 {
    const counter = counterFor(gen) orelse return null;
    return counter.load(.acquire);
}

/// Releases the engine names of every generation (Godot reports names still
/// held at exit) and clears `current`. Libraries stay open and generations
/// stay registered, so a late `HostApi` call from module code stays safe.
/// Main thread, at SCENE exit, after the language is unregistered. No other
/// thread may call into script instances then: `names` is replaced without
/// synchronisation, and readers (instance.zig) check its length first and
/// fall back to text lookup once it is empty.
pub fn shutdown() void {
    current_gen.store(null, .release);
    const io = host_io.get();
    const a = list_allocator orelse return;
    mu.lockUncancelable(io);
    const gens = generations.items;
    mu.unlock(io);
    // Only the main thread appends, so `gens` stays valid here.
    for (gens) |g| {
        for (g.names) |*m| m.deinit(a);
        a.free(g.names);
        g.names = &.{};
    }
}

fn refuse(diag: *[256]u8, file: []const u8, comptime fmt: []const u8, args: anytype) error{Refused} {
    @memset(diag, 0);
    var w: std.Io.Writer = .fixed(diag[0..255]);
    w.print("Ziggurat refused the module {s}: " ++ fmt, .{file} ++ args) catch {};
    return error.Refused;
}

/// The sentence in `buf` (NUL-terminated) with its first letter lowercased
/// when it starts a plain word ("The table ..." but not "ELF ...").
fn lowerFirst(buf: *[256]u8) []const u8 {
    const s = std.mem.sliceTo(buf, 0);
    if (s.len >= 2 and std.ascii.isUpper(s[0]) and std.ascii.isLower(s[1])) s[0] = std.ascii.toLower(s[0]);
    return s;
}

fn str(s: abi.Str) []const u8 {
    if (s.len == 0) return "";
    return s.ptr.?[0..s.len];
}

// ------------------------------------------------------------- HostApi

const max_alignment = 4096;

fn validAlignment(alignment: u32) ?std.mem.Alignment {
    if (alignment == 0 or alignment > max_alignment or !std.math.isPowerOfTwo(alignment)) return null;
    return .fromByteUnits(alignment);
}

/// The byte counter for tag `gen`, or null for an unknown generation.
/// Tag 0 takes no lock. A generation's counter lives as long as the process
/// (generations are never freed), so it is used after `mu` is released.
fn counterFor(gen: u32) ?*std.atomic.Value(u64) {
    if (gen == 0) return &user_heap_bytes;
    const g = find(gen) orelse return null;
    return &g.live_bytes;
}

/// Adds `size` to `counter`, saturating.
fn countAlloc(counter: *std.atomic.Value(u64), size: usize) void {
    var old = counter.load(.monotonic);
    while (counter.cmpxchgWeak(old, old +| size, .acq_rel, .monotonic)) |seen| old = seen;
}

/// Takes `size` from `counter`, saturating at 0.
fn countFree(counter: *std.atomic.Value(u64), size: usize) void {
    var old = counter.load(.monotonic);
    while (counter.cmpxchgWeak(old, old -| size, .acq_rel, .monotonic)) |seen| old = seen;
}

fn apiAlloc(gen: u32, size: usize, alignment: u32) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    const al = validAlignment(alignment) orelse return null;
    const counter = counterFor(gen) orelse return null;
    const p = heap.rawAlloc(size, al, @returnAddress()) orelse return null;
    countAlloc(counter, size);
    return p;
}

fn apiFree(gen: u32, ptr: ?*anyopaque, size: usize, alignment: u32) callconv(.c) void {
    const p = ptr orelse return;
    if (size == 0) return;
    // Memory with an alignment `alloc` would refuse cannot be ours.
    const al = validAlignment(alignment) orelse return;
    heap.rawFree(@as([*]u8, @ptrCast(p))[0..size], al, @returnAddress());
    if (counterFor(gen)) |counter| countFree(counter, size);
}

/// Longest message text logged; longer text is cut.
const log_max = 4096;

/// Writes one line to Godot's output: info through `print`, warnings through
/// `print_warning` and errors (and unknown levels) through `print_error`.
/// Godot's printing is thread-safe. The gdzig function pointers `print` uses
/// are cached on first use; the host's ready line (`entry.zig`) fills them
/// on the main thread before any module is loaded.
fn apiLog(level: u32, msg: [*]const u8, len: usize) callconv(.c) void {
    var buf: [log_prefix.len + log_max + 1]u8 = undefined;
    var text = msg[0..@min(len, log_max)];
    // print_error takes a C string: stop at an embedded NUL.
    if (std.mem.indexOfScalar(u8, text, 0)) |i| text = text[0..i];
    @memcpy(buf[0..log_prefix.len], log_prefix);
    @memcpy(buf[log_prefix.len..][0..text.len], text);
    const line_len = log_prefix.len + text.len;
    buf[line_len] = 0;
    const line = buf[0..line_len];
    const z: [*:0]const u8 = @ptrCast(&buf);
    switch (level) {
        @backingInt(abi.LogLevel.info) => {
            var s: String = String.fromUtf8(line) catch String.fromLatin1(line);
            defer s.deinit();
            godot.general.print(.init(String, s), .{});
        },
        @backingInt(abi.LogLevel.warning) => godot.raw.printWarning(z, "ziggurat module", "", 0, 0),
        else => godot.raw.printError(z, "ziggurat module", "", 0, 0),
    }
}

fn apiRequestSwap() callconv(.c) void {
    if (swap_logged.swap(true, .acq_rel)) return;
    const msg = "swap requested (swaps arrive in a later version)";
    apiLog(@backingInt(abi.LogLevel.info), msg, msg.len);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// Registers a fake generation for the HostApi tests, bypassing `load`.
fn testRegister(gen: *Generation) !void {
    list_allocator = testing.allocator;
    try generations.append(testing.allocator, gen);
}

fn testReset() void {
    generations.deinit(testing.allocator);
    generations = .empty;
    user_heap_bytes.store(0, .release);
    list_allocator = null;
}

test "HostApi tag 0 works before any load" {
    defer testReset();
    try testing.expectEqual(@as(usize, 0), generations.items.len);
    const p = apiAlloc(0, 48, 16) orelse return error.AllocFailed;
    try testing.expectEqual(@as(?u64, 48), liveBytes(0));
    apiFree(0, p, 48, 16);
    try testing.expectEqual(@as(?u64, 0), liveBytes(0));
    // A generation tag still needs a loaded generation.
    try testing.expect(apiAlloc(1, 8, 8) == null);
}

test "HostApi counters stay right with allocations held across threads" {
    var g: Generation = .{ .n = 5, .lib = undefined, .table = undefined, .names = &.{}, .by_path = .empty };
    try testRegister(&g);
    defer testReset();

    const per_thread = 500;
    const Held = struct { ptrs: [per_thread]*anyopaque = undefined, bytes: u64 = 0 };
    const Worker = struct {
        fn alloc(tag: u32, held: *Held) void {
            for (&held.ptrs, 0..) |*slot, i| {
                const size = 1 + (i * 7) % 300;
                slot.* = apiAlloc(tag, size, 32) orelse @panic("alloc failed");
                held.bytes += size;
            }
        }
        fn free(tag: u32, held: *Held) void {
            for (held.ptrs, 0..) |ptr, i| apiFree(tag, ptr, 1 + (i * 7) % 300, 32);
        }
    };
    var held: [8]Held = @splat(.{});
    var threads: [8]std.Thread = undefined;
    // All threads allocate at once and keep their memory.
    for (&threads, &held, 0..) |*t, *h, i| t.* = try std.Thread.spawn(.{}, Worker.alloc, .{ @as(u32, if (i % 2 == 0) 5 else 0), h });
    for (threads) |t| t.join();
    var want_gen: u64 = 0;
    var want_heap: u64 = 0;
    for (held, 0..) |h, i| {
        if (i % 2 == 0) want_gen += h.bytes else want_heap += h.bytes;
    }
    try testing.expectEqual(@as(?u64, want_gen), liveBytes(5));
    try testing.expectEqual(@as(?u64, want_heap), liveBytes(0));
    // Then all free at once.
    for (&threads, &held, 0..) |*t, *h, i| t.* = try std.Thread.spawn(.{}, Worker.free, .{ @as(u32, if (i % 2 == 0) 5 else 0), h });
    for (threads) |t| t.join();
    try testing.expectEqual(@as(?u64, 0), liveBytes(5));
    try testing.expectEqual(@as(?u64, 0), liveBytes(0));
}

test "load refuses a thread other than the main thread" {
    const saved = main_thread;
    defer main_thread = saved;
    main_thread = std.Thread.getCurrentId();
    const Worker = struct {
        fn run(diag: *[256]u8, result: *?LoadError) void {
            // `load` logs its sentence through Godot, which a unit test does
            // not have; the Godot check covers `load` itself.
            _ = diag;
            result.* = if (onMainThread()) null else error.NotMainThread;
        }
    };
    var diag: [256]u8 = undefined;
    var result: ?LoadError = null;
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &diag, &result });
    t.join();
    try testing.expectEqual(@as(?LoadError, error.NotMainThread), result);
    try testing.expect(onMainThread());
}

test "HostApi alloc and free count bytes per tag" {
    var g: Generation = .{ .n = 7, .lib = undefined, .table = undefined, .names = &.{}, .by_path = .empty };
    try testRegister(&g);
    defer testReset();

    const p = apiAlloc(7, 100, 64) orelse return error.AllocFailed;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 64);
    try testing.expectEqual(@as(?u64, 100), liveBytes(7));
    const q = apiAlloc(0, 10, 4096) orelse return error.AllocFailed;
    try testing.expectEqual(@as(usize, 0), @intFromPtr(q) % 4096);
    try testing.expectEqual(@as(?u64, 10), liveBytes(0));
    apiFree(7, p, 100, 64);
    apiFree(0, q, 10, 4096);
    try testing.expectEqual(@as(?u64, 0), liveBytes(7));
    try testing.expectEqual(@as(?u64, 0), liveBytes(0));
}

test "HostApi alloc refuses bad requests" {
    var g: Generation = .{ .n = 3, .lib = undefined, .table = undefined, .names = &.{}, .by_path = .empty };
    try testRegister(&g);
    defer testReset();

    try testing.expect(apiAlloc(3, 0, 8) == null); // zero bytes
    try testing.expect(apiAlloc(3, 8, 0) == null); // no alignment
    try testing.expect(apiAlloc(3, 8, 24) == null); // not a power of two
    try testing.expect(apiAlloc(3, 8, 8192) == null); // above 4096
    try testing.expect(apiAlloc(4, 8, 8) == null); // generation not loaded
    try testing.expect(liveBytes(4) == null);
    apiFree(3, null, 8, 8); // a null pointer is ignored
    try testing.expectEqual(@as(?u64, 0), liveBytes(3));
}

test "HostApi alloc and free from many threads" {
    var g: Generation = .{ .n = 2, .lib = undefined, .table = undefined, .names = &.{}, .by_path = .empty };
    try testRegister(&g);
    defer testReset();

    const Worker = struct {
        fn run(tag: u32) void {
            for (0..2000) |i| {
                const size = 1 + i % 200;
                const p = apiAlloc(tag, size, 16) orelse @panic("alloc failed");
                @memset(@as([*]u8, @ptrCast(p))[0..size], 0xAA);
                apiFree(tag, p, size, 16);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{@as(u32, if (i % 2 == 0) 2 else 0)});
    for (threads) |t| t.join();
    try testing.expectEqual(@as(?u64, 0), liveBytes(2));
    try testing.expectEqual(@as(?u64, 0), liveBytes(0));
}

test "refusal sentence names the file and lowers the reason" {
    var diag: [256]u8 = undefined;
    var reason: [256]u8 = @splat(0);
    @memcpy(reason[0..20], "The table is broken.");
    try testing.expectError(error.Refused, @as(error{Refused}!void, refuse(&diag, "libzmod.so", "{s}", .{lowerFirst(&reason)})));
    try testing.expectEqualStrings("Ziggurat refused the module libzmod.so: the table is broken.", std.mem.sliceTo(&diag, 0));
    @memset(&reason, 0);
    @memcpy(reason[0..12], "ELF is cut.\x00");
    try testing.expectEqualStrings("ELF is cut.", lowerFirst(&reason));
}

test {
    _ = names;
    _ = host_io;
}
