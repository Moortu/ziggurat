//! The swap engine (spec section 6, reload steps 4 and 5): moves every live
//! script instance to a newer generation.
//!
//! `request` only records the generation (the newest request wins); the
//! swap runs at `ZigLanguage._frame` (`runPending`), and only when no
//! module code is on the main thread's stack (`gate.depth` is 0) and the
//! gate's try-lock succeeds. Otherwise it waits for a later frame. Each
//! outcome is logged once per change.
//!
//! Under the gate's write side, in this order:
//! 1. Plan per script (by the old descriptor): the same layout (equal
//!    `abi.layoutHash`, `instance_size` and `instance_align`) keeps the
//!    instance data; a changed layout gets the list of fields that move
//!    (equal name and exact type identity: `type_name`, `shape`, `size`,
//!    `align`; `base` never moves, `create_blank` sets it). A script the
//!    new generation lacks keeps its instances on the old code.
//! 2. Allocate: `create_blank` a new block for every instance whose layout
//!    changed. Any failure frees every new block (`HostApi.free`, no module
//!    code: a blank block holds only the defaults image, whose engine
//!    values are empty) and rejects the swap; nothing has changed. This is
//!    the rollback boundary: migration itself cannot fail.
//! 3. Per instance: a same layout retags the block (`runtime.retag`) and
//!    rewrites the record's generation and index. A changed layout marks the
//!    instance as migrating (`gate.setMigrating`), byte-copies the moving
//!    fields and marks them moved (`PrevView.moved` 1), calls the new
//!    `migrate(new, prev)` if there is one (its `take` marks more fields
//!    moved, its `get` marks fields read: 2), resets every moved old field
//!    (1 only) from the old defaults image, calls the old `destroy` (its
//!    `deinit` sees only what did not move), then writes generation, index
//!    and data of the record as one unit and ends the migration.
//! 4. Publish the new generation as current (its name maps are complete
//!    since `runtime.load`), then end the swap.
//! After the write side is released: the records freed during the swap are
//! released (`instance.releaseDeferred`), the dropped fields and missing
//! scripts are logged (once per script path, old layout and new layout for
//! the process, so repeated swaps between the same layouts stay quiet),
//! and every live script refreshes its placeholders (`_update_exports`) and
//! tool placeholders; in the editor each object whose instance was
//! migrated to a changed layout also emits `property_list_changed` for the
//! Inspector. These Godot calls can take Godot's own locks, which a thread
//! waiting at the gate may hold, so the host never makes them under the
//! write side. Script descriptors need no refresh: every script answer is
//! read from `runtime.current()`. Module code that runs under the write
//! side (`create_blank`, `migrate`, an old `deinit`) prints only through
//! `HostApi.log`, which goes to Godot's print functions; that is accepted
//! (spec section 6, calls from `migrate` and `deinit`).
//!
//! Should `gate.endSwap` refuse (a caller bug: it is called at the depth
//! `trySwap` saw, 0 from `_frame`), the swap stays open (`swap_open`): none
//! of the work above runs under the write side, and the next `runPending`
//! first ends the swap at depth 0, then releases the deferred records and
//! refreshes the placeholders (the Inspector and the log lines of that
//! swap are skipped).
//!
//! Code the swap runs (`migrate`, an old `deinit`) runs on the swapping
//! thread, which passes through the gate. A call into the instance being
//! migrated is refused (`gate.enterInstance`); instances not reached yet run
//! old code, migrated ones new code. An instance such code frees is taken
//! off the registry and released after the swap (`instance.deferFrees`);
//! the swap then skips it and frees its new block. An instance such code
//! makes lands on the new generation (`runtime.setSwapTarget`). Instances
//! made on other threads wait at the gate and land on the new generation.
//!
//! Threads: `request` from any thread; everything else on the main thread.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const runtime = @import("runtime.zig");
const gate = @import("gate.zig");
const registry = @import("registry.zig");
const instance = @import("instance.zig");
const script = @import("script.zig");

const Allocator = std.mem.Allocator;
const Generation = runtime.Generation;
const Instance = instance.Instance;
const String = godot.builtin.String;
const Object = godot.class.Object;

const gpa = std.heap.c_allocator;

/// What `runPending` did this frame.
pub const Outcome = enum(u8) {
    /// No swap was requested, or the request was for the current generation.
    none = 0,
    /// Module code is on the main thread's stack; retried next frame.
    deferred_depth = 1,
    /// Another thread is inside the gate; retried next frame.
    deferred_lock = 2,
    swapped = 3,
    /// A new instance block could not be made; nothing changed and the
    /// request is dropped.
    rejected = 4,
};

/// The generation the newest request named, or null.
var pending: std.atomic.Value(?*Generation) = .init(null);
/// The last outcome and its generation number (main thread), for logging
/// once per change.
var last: struct { outcome: Outcome = .none, n: u32 = 0 } = .{};
/// Swaps done in this process (main thread).
var swaps: u32 = 0;
/// Set when `endSwap` refused after a swap: the write side is still held
/// by the main thread and the after-swap work waits (main thread).
var swap_open: bool = false;
/// Keys of the warnings logged (`warnOnce`), for the process (main thread).
var warned: std.AutoHashMapUnmanaged(u64, void) = .empty;

/// Code to run once on the swapping thread, after the first instance with
/// a changed layout was migrated, standing in for user code in `migrate`
/// or `deinit`. For the host tests.
pub const Hook = struct {
    run: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};
pub var test_hook: ?Hook = null;

/// Asks for a swap to `gen`, a generation `runtime.load` returned whose
/// checks passed. It runs at a later `_frame`, never here; a later request
/// replaces this one. Any thread.
pub fn request(gen: *Generation) void {
    pending.store(gen, .release);
}

/// Asks for a swap to the newest good generation (`runtime.newestGood`)
/// when it is newer than the current one. False when there is none. Any
/// thread (reload hooks, `HostApi.request_swap`).
pub fn requestNewest() bool {
    const gen = runtime.newestGood() orelse return false;
    if (runtime.current()) |cur| {
        if (cur.n >= gen.n) return false;
    }
    request(gen);
    return true;
}

/// The outcome of the last `runPending`.
pub fn lastOutcome() Outcome {
    return last.outcome;
}

/// Swaps done in this process.
pub fn swapCount() u32 {
    return swaps;
}

/// Runs the requested swap if it can run now. `ZigLanguage._frame` only,
/// on the main thread.
pub fn runPending() Outcome {
    if (swap_open) {
        if (gate.depth() != 0 or !gate.endSwap()) return note(.deferred_depth, last.n, null);
        swap_open = false;
        _ = instance.releaseDeferred();
        refreshScripts(&.{});
    }
    const gen = pending.load(.acquire) orelse return note(.none, 0, null);
    const old = runtime.current();
    if (old == gen) {
        _ = pending.cmpxchgStrong(gen, null, .acq_rel, .acquire);
        return note(.none, gen.n, null);
    }
    if (gate.depth() > 0) return note(.deferred_depth, gen.n, null);
    if (!gate.trySwap()) return note(.deferred_lock, gen.n, null);
    // A request that arrived meanwhile stays for a later frame.
    _ = pending.cmpxchgStrong(gen, null, .acq_rel, .acquire);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var w: Work = .{ .a = arena_state.allocator(), .new = gen, .old = old };
    const ok = w.run();
    // `run` stopped putting frees off and cleared the swap target.
    if (!gate.endSwap()) {
        // Not reachable from `_frame` (the depth was 0 at `trySwap`);
        // `endSwap` logged it. The lock stays with this thread until the
        // next frame ends it; nothing more runs under it now.
        swap_open = true;
        if (ok) swaps += 1;
        return note(if (ok) .swapped else .rejected, gen.n, &w);
    }
    _ = instance.releaseDeferred();
    if (!ok) return note(.rejected, gen.n, &w);
    swaps += 1;
    w.logDropped();
    w.refresh();
    return note(.swapped, gen.n, &w);
}

/// Records `o` and logs it when it differs from the last outcome.
fn note(o: Outcome, n: u32, w: ?*const Work) Outcome {
    const changed = o != last.outcome or n != last.n;
    last = .{ .outcome = o, .n = n };
    if (!changed) return o;
    switch (o) {
        .none => {},
        .deferred_depth => log("ziggurat: the swap to build {d} waits: a script call is on the main thread's stack", .{n}),
        .deferred_lock => log("ziggurat: the swap to build {d} waits for script calls on other threads to return", .{n}),
        .swapped => log("ziggurat: swapped to build {d} ({d} instances kept their data, {d} migrated)", .{ n, w.?.kept, w.?.migrated }),
        .rejected => {
            const keep = if (w.?.old) |g| g.n else 0;
            logError("Ziggurat could not swap to build {d}: {s}; build {d} stays in use.", .{ n, w.?.reason, keep });
        },
    }
    return o;
}

/// What happens to one old field.
pub const Fate = enum(u8) { base, moved, removed, type_changed };

/// One field the host byte-copies.
pub const Move = struct { old_field: u32, from: u32, to: u32, size: u32 };

/// The fields of a script whose layout changed.
pub const FieldPlan = struct {
    moves: []Move,
    /// One per old field.
    fates: []Fate,
};

/// True when an instance of `old` can be kept as it is by `new`.
pub fn sameLayout(old: *const abi.ScriptDesc, new: *const abi.ScriptDesc) bool {
    return old.instance_size == new.instance_size and old.instance_align == new.instance_align and
        abi.layoutHash(old) == abi.layoutHash(new);
}

/// Exact type identity (spec section 6): equal type name, shape, size and
/// alignment.
pub fn sameType(a: *const abi.FieldDesc, b: *const abi.FieldDesc) bool {
    return eqlStr(a.type_name, b.type_name) and a.shape == b.shape and a.size == b.size and a.@"align" == b.@"align";
}

/// Which old fields move to which new ones, by equal name and exact type
/// identity; `base` never moves.
pub fn planFields(a: Allocator, old: []const abi.FieldDesc, new: []const abi.FieldDesc) Allocator.Error!FieldPlan {
    const fates = try a.alloc(Fate, old.len);
    var moves: std.ArrayList(Move) = .empty;
    for (old, fates, 0..) |*f, *fate, i| {
        if (std.mem.eql(u8, text(f.name), "base")) {
            fate.* = .base;
            continue;
        }
        fate.* = .removed;
        for (new) |*n| {
            if (!eqlStr(f.name, n.name)) continue;
            if (!sameType(f, n)) {
                fate.* = .type_changed;
                break;
            }
            fate.* = .moved;
            try moves.append(a, .{ .old_field = @intCast(i), .from = f.offset, .to = n.offset, .size = f.size });
            break;
        }
    }
    return .{ .moves = try moves.toOwnedSlice(a), .fates = fates };
}

/// How one old script's instances swap.
const Plan = struct {
    old: *const abi.ScriptDesc,
    new: *const abi.ScriptDesc,
    new_index: u32,
    same: bool,
    fields: FieldPlan,
    /// One byte per old field, reused for each instance (`PrevView.moved`).
    moved: []u8,
    /// Per old field: some instance carried its value over (moved by the
    /// host or taken by `migrate`).
    carried: []bool,
    /// Instances of this script migrated with a changed layout.
    migrated: u32 = 0,
};

/// One live instance to swap.
const Job = struct {
    entry: registry.Entry,
    plan: *Plan,
    /// The new block (`create_blank`) for a changed layout.
    blank: ?*anyopaque = null,
    /// The owner's object id, for the Inspector refresh (editor only, and
    /// only for a changed layout: a kept block keeps its property list).
    owner_id: u64 = 0,
};

/// One swap. Its memory comes from `a`, an arena freed after the swap.
const Work = struct {
    a: Allocator,
    new: *Generation,
    old: ?*Generation,
    /// Plans by old descriptor; null for a script the new generation lacks.
    plans: std.AutoArrayHashMapUnmanaged(*const abi.ScriptDesc, ?*Plan) = .empty,
    jobs: []Job = &.{},
    kept: u32 = 0,
    migrated: u32 = 0,
    /// Why the swap was rejected.
    reason: []const u8 = "",

    /// Steps 1 to 4 under the write side. False: rejected, nothing changed.
    fn run(w: *Work) bool {
        if (!w.prepare()) return false;
        instance.deferFrees(true);
        runtime.setSwapTarget(w.new);
        var hook = test_hook;
        test_hook = null;
        for (w.jobs) |*j| {
            const p = j.plan;
            // Freed during this swap by code it ran: released afterwards on
            // the generation and data its record still holds.
            if (!registry.contains(j.entry)) {
                if (j.blank) |b| freeBlank(w.new, p.new, b);
                continue;
            }
            const rec = j.entry.rec;
            if (p.same) {
                _ = runtime.retag(rec.data, blockSize(p.old), rec.gen.n, w.new.n);
                rec.gen = w.new;
                rec.index = p.new_index;
                w.kept += 1;
                continue;
            }
            migrate(rec, p, j.blank.?, w.new);
            w.migrated += 1;
            if (hook) |h| {
                hook = null;
                h.run(h.ctx);
            }
        }
        runtime.publish(w.new);
        runtime.setSwapTarget(null);
        instance.deferFrees(false);
        return true;
    }

    /// Plans every live instance and makes the new blocks. On a failure it
    /// frees the blocks made so far and returns false.
    fn prepare(w: *Work) bool {
        const entries = registry.all(w.a) catch return w.reject("out of memory");
        const jobs = w.a.alloc(Job, entries.len) catch return w.reject("out of memory");
        const editor = script.isEditor();
        var n: usize = 0;
        for (entries) |e| {
            const rec = e.rec;
            if (rec.gen == w.new) continue;
            const p = (w.planFor(rec) catch {
                w.jobs = jobs[0..n];
                w.rollback();
                return w.reject("out of memory");
            }) orelse continue;
            jobs[n] = .{ .entry = e, .plan = p };
            if (!p.same) {
                jobs[n].blank = p.new.create_blank(@ptrCast(rec.owner), w.new.n) orelse {
                    w.jobs = jobs[0..n];
                    w.rollback();
                    w.reason = std.fmt.allocPrint(w.a, "the new data of an instance of {s} could not be made", .{text(p.new.path)}) catch "out of memory";
                    return false;
                };
            }
            // Reads a field of the object; takes no Godot lock.
            if (editor and !p.same) jobs[n].owner_id = godot.raw.objectGetInstanceId(@ptrCast(rec.owner));
            n += 1;
        }
        w.jobs = jobs[0..n];
        return true;
    }

    fn reject(w: *Work, why: []const u8) bool {
        w.reason = why;
        return false;
    }

    /// Frees every new block made so far.
    fn rollback(w: *Work) void {
        for (w.jobs) |j| {
            if (j.blank) |b| freeBlank(w.new, j.plan.new, b);
        }
    }

    /// The plan for `rec`'s script, made on first use; null when the new
    /// generation lacks the script.
    fn planFor(w: *Work, rec: *const Instance) Allocator.Error!?*Plan {
        const old = &rec.gen.scripts()[rec.index];
        const gop = try w.plans.getOrPut(w.a, old);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = null;
        const ni = runtime.findScript(w.new, text(old.path)) orelse return null;
        const new = &w.new.scripts()[ni];
        const p = try w.a.create(Plan);
        p.* = .{
            .old = old,
            .new = new,
            .new_index = ni,
            .same = sameLayout(old, new),
            .fields = .{ .moves = &.{}, .fates = &.{} },
            .moved = &.{},
            .carried = &.{},
        };
        if (!p.same) {
            p.fields = try planFields(w.a, fieldsOf(old), fieldsOf(new));
            p.moved = try w.a.alloc(u8, old.field_count);
            p.carried = try w.a.alloc(bool, old.field_count);
            @memset(p.carried, false);
        }
        gop.value_ptr.* = p;
        return p;
    }

    /// Logs each field no instance carried over (neither moved nor read),
    /// and each script the new generation lacks: once per script path, old
    /// layout and new layout for the process (`warnOnce`). After the swap.
    fn logDropped(w: *const Work) void {
        for (w.plans.keys(), w.plans.values()) |old, plan| {
            const old_hash = abi.layoutHash(old);
            const p = plan orelse {
                if (warnOnce(text(old.path), old_hash, 0))
                    logWarning("{s} is not in build {d}; its instances keep the old code", .{ text(old.path), w.new.n });
                continue;
            };
            if (p.same or p.migrated == 0) continue;
            if (!warnOnce(text(old.path), old_hash, abi.layoutHash(p.new))) continue;
            for (fieldsOf(old), p.fields.fates, p.carried) |f, fate, carried| {
                if (carried) continue;
                const why = switch (fate) {
                    .base, .moved => continue,
                    .removed => "removed",
                    .type_changed => "type changed",
                };
                logWarning("{s}: field '{s}' was dropped ({s})", .{ text(old.path), text(f.name), why });
            }
        }
    }

    /// Step 5, after the write side is released.
    fn refresh(w: *const Work) void {
        var ids: std.ArrayList(u64) = .empty;
        for (w.jobs) |j| {
            if (j.owner_id != 0) ids.append(w.a, j.owner_id) catch break;
        }
        refreshScripts(ids.items);
    }
};

/// Refreshes the placeholders and tool placeholders of every live script
/// and, in the editor, the property lists of the objects `owner_ids` name
/// (for the Inspector). After the write side is released.
fn refreshScripts(owner_ids: []const u64) void {
    const scripts = script.liveScripts(gpa) catch {
        logError("Ziggurat could not refresh the Zig scripts after a swap: out of memory.", .{});
        return;
    };
    defer gpa.free(scripts);
    for (scripts) |s| {
        defer script.release(s);
        s._updateExports();
        s.swapToolPlaceholders();
    }
    if (!script.isEditor()) return;
    for (owner_ids) |id| {
        const raw = godot.raw.objectGetInstanceFromId(id) orelse continue;
        const obj: *Object = @ptrCast(@alignCast(raw));
        obj.notifyPropertyListChanged();
    }
}

/// True the first time `(path, old_hash, new_hash)` is seen in this
/// process (also when the set cannot grow: a repeated warning is better
/// than a lost one). Main thread.
fn warnOnce(path: []const u8, old_hash: u64, new_hash: u64) bool {
    var h = std.hash.Wyhash.init(0);
    h.update(path);
    h.update(std.mem.asBytes(&old_hash));
    h.update(std.mem.asBytes(&new_hash));
    const gop = warned.getOrPut(gpa, h.final()) catch return true;
    return !gop.found_existing;
}

/// Moves one instance with a changed layout to `new` (step 3).
fn migrate(rec: *Instance, p: *Plan, blank: *anyopaque, new: *Generation) void {
    gate.setMigrating(rec);
    const old = p.old;
    const old_data: [*]u8 = @ptrCast(rec.data);
    const new_data: [*]u8 = @ptrCast(blank);
    @memset(p.moved, 0);
    for (p.fields.moves) |m| {
        @memcpy(new_data[m.to..][0..m.size], old_data[m.from..][0..m.size]);
        p.moved[m.old_field] = 1;
    }
    if (p.new.migrate) |hook| {
        const view: abi.PrevView = .{ .data = rec.data, .fields = old.fields, .field_count = old.field_count, .moved = p.moved.ptr };
        hook(blank, &view);
    }
    // What moved now belongs to the new instance: the old `destroy` must
    // not release it.
    const defaults: [*]const u8 = @ptrCast(old.defaults);
    // 1: moved (reset); 2: read by `migrate` (kept for the old `deinit`).
    for (fieldsOf(old), p.moved, p.carried) |f, moved, *carried| {
        if (moved == 0) continue;
        carried.* = true;
        if (moved != 1 or std.mem.eql(u8, text(f.name), "base")) continue;
        @memcpy(old_data[f.offset..][0..f.size], defaults[f.offset..][0..f.size]);
    }
    old.destroy(rec.data);
    // One unit: no module code between these writes.
    rec.gen = new;
    rec.index = p.new_index;
    rec.data = blank;
    p.migrated += 1;
    _ = instance.endMigration(rec);
}

/// Frees a block `create_blank` made that never reached `migrate`. Its
/// bytes are the defaults image plus `base`, which hold no engine value, so
/// no module code needs to run.
fn freeBlank(gen: *Generation, d: *const abi.ScriptDesc, block: *anyopaque) void {
    runtime.hostApi().free(gen.n, block, blockSize(d), d.instance_align);
}

/// The bytes the SDK allocates for an instance of `d` (at least 1).
fn blockSize(d: *const abi.ScriptDesc) usize {
    return @max(d.instance_size, 1);
}

fn fieldsOf(d: *const abi.ScriptDesc) []const abi.FieldDesc {
    if (d.field_count == 0) return &.{};
    return d.fields[0..d.field_count];
}

fn text(s: abi.Str) []const u8 {
    if (s.len == 0) return "";
    return s.ptr.?[0..s.len];
}

fn eqlStr(a: abi.Str, b: abi.Str) bool {
    return std.mem.eql(u8, text(a), text(b));
}

const max_line = 4096;

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_line]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

fn logWarning(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_line]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printWarning(msg.ptr, "Zig scripts", "src/host/swap.zig", @src().line, 1);
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_line]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printError(msg.ptr, "Zig scripts", "src/host/swap.zig", @src().line, 1);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn field(name: []const u8, type_name: []const u8, shape: u64, offset: u32, size: u32) abi.FieldDesc {
    return .{
        .name = .{ .ptr = name.ptr, .len = @intCast(name.len) },
        .type_name = .{ .ptr = type_name.ptr, .len = @intCast(type_name.len) },
        .shape = shape,
        .offset = offset,
        .size = size,
        .@"align" = size,
        .value_kind = 0,
        .bits = 0,
    };
}

test "fields move by name and exact type, base never moves" {
    const old = [_]abi.FieldDesc{
        field("base", "*Node", 0, 0, 8),
        field("speed", "f32", 0, 8, 4),
        field("hp", "i32", 0, 12, 4),
        field("count", "i32", 0, 16, 4),
        field("stats", "m.Stats", 1, 24, 8),
        field("mood", "m.Mood", 5, 32, 1),
    };
    const new = [_]abi.FieldDesc{
        field("base", "*Node", 0, 0, 8),
        field("count", "u32", 0, 8, 4),
        field("speed", "f32", 0, 12, 4),
        // Same name and type name, other shape: another type.
        field("stats", "m.Stats", 2, 16, 8),
        field("mood", "m.Mood", 5, 24, 1),
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try planFields(arena.allocator(), &old, &new);
    try testing.expectEqualSlices(Fate, &.{ .base, .moved, .removed, .type_changed, .type_changed, .moved }, p.fates);
    try testing.expectEqual(@as(usize, 2), p.moves.len);
    try testing.expectEqual(Move{ .old_field = 1, .from = 8, .to = 12, .size = 4 }, p.moves[0]);
    try testing.expectEqual(Move{ .old_field = 5, .from = 32, .to = 24, .size = 1 }, p.moves[1]);
}

test "type identity needs equal size and alignment too" {
    const a = field("x", "T", 3, 0, 4);
    var b = a;
    try testing.expect(sameType(&a, &b));
    b.size = 8;
    try testing.expect(!sameType(&a, &b));
    b = a;
    b.@"align" = 2;
    try testing.expect(!sameType(&a, &b));
}
