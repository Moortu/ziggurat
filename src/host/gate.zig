//! The gate (spec section 6): every entry from Godot into module code, or
//! into a script instance record a swap rewrites, holds the shared side of
//! one process-wide reader-writer lock. A swap takes the write side, so
//! while it moves data and rewrites records no other thread is inside.
//!
//! Rules:
//! - The swap only ever uses `trySwap` (a try-lock), never a blocking write
//!   lock. In Zig 0.17 `std.Io.RwLock.tryLock` does not register a waiting
//!   writer, so readers keep taking the fast path while a swap tries; a
//!   blocking `lockUncancelable` registers one, after which every new
//!   `lockShared` waits, and a thread that is already inside (an entry that
//!   calls back into another instance) would wait for itself. With the
//!   try-lock, nested entries on any thread never block.
//! - The thread that holds the write lock (the swapper) passes through
//!   `enter`: code the swap runs (`migrate`, the old `deinit`) may call back
//!   into instances. A call into the one instance being migrated
//!   (`setMigrating`) is refused (`refuse`, one log line per instance per
//!   swap); instances not yet migrated run old code, migrated ones new code
//!   (plan, "Callbacks during migration").
//! - `depth` counts the calling thread's entries. The swap engine asks it on
//!   the main thread: a swap while module code is on the main thread's stack
//!   (a nested main-loop iteration) waits for a later frame.
//! - `lockForShutdown` is the one place that waits for the write side: at
//!   SCENE exit, after the main loop stopped, by retrying the try-lock, so a
//!   nested entry on another thread still gets in and leaves.
//!
//! Entries that hold the gate (each one `enter`/`leave`):
//! - instance.zig, the `GDExtensionScriptInstanceInfo3` callbacks that read
//!   the record or run module code: `set`, `get`, `property_can_revert`,
//!   `property_get_revert`, `get_property_type`, `get_property_state`,
//!   `get_property_list`, `get_method_list`, `has_method`,
//!   `get_method_argument_count`, `call`, `notification`, `to_string`,
//!   `free` (the module's `destroy`).
//! - `ZigScript._instance_create`, from before it chooses the generation
//!   until `instance.create` (the module's `create`) has registered the
//!   record, so a swap never misses an instance made meanwhile. The
//!   tool-placeholder swap (`ZigScript.swapToolPlaceholders` sets the
//!   script again) goes through it too.
//! - script.zig placeholder updates: `_placeholder_instance_create` (feeds
//!   a new placeholder) and `_update_exports` (refreshes placeholders); both
//!   read descriptors of a generation.
//! Not gated, with the reason:
//! - `get_owner`, `get_script`, `is_placeholder`, `get_language`,
//!   `validate_property`, `free_property_list`, `free_method_list`: they
//!   read neither the record's generation nor module data.
//! - `refcount_incremented` / `refcount_decremented`: they do not reach the
//!   module (no-op, constant answer).
//! - Callables and signals: `get` hands out `Callable`s and `Signal`s on the
//!   owner; calling one goes through `Object::callp` to `call` above, and a
//!   module's `emit` reaches handlers that enter through the same callbacks.
//!   There is no other path into module code.
//! - `runtime.load` runs `ziggurat_init` of a new generation on the main
//!   thread; it touches no instance (the swap engine runs it under the
//!   write lock, Task 4).
//!
//! Rule for the swap engine: the callbacks that only read descriptors
//! (`has_method`, the lists, revert, property type, argument count) and the
//! refusal log answer for the migrating instance too, reading its `gen` and
//! `index`. The engine therefore writes `gen`, `index` and `data` of a
//! record as one unit, with no module code run between those writes.
//!
//! Threads: any. The Io is `host_io.get()`; its mutexes and futexes work
//! across threads before and after `host_io.init`.
const std = @import("std");
const godot = @import("gdzig");
const host_io = @import("host_io.zig");
const instance = @import("instance.zig");

const Instance = instance.Instance;

var lock: std.Io.RwLock = .init;
/// Entries of the calling thread, the pass-through ones of the swapper
/// included.
threadlocal var depth_count: u32 = 0;
/// True on the thread that holds the write lock (`trySwap` or
/// `lockForShutdown`): its entries pass through.
threadlocal var swapping: bool = false;
/// `depth_count` when `trySwap` took the lock; `endSwap` must see it again.
threadlocal var swap_depth: u32 = 0;
/// The instance being migrated now, or null.
var migrating: std.atomic.Value(?*Instance) = .init(null);
/// The migrating instance whose refusal was logged, so it is logged once.
var refusal_logged: std.atomic.Value(?*Instance) = .init(null);

fn io() std.Io {
    return host_io.get();
}

/// Takes the shared side, unless this thread is the swapper. Always pair
/// with `leave` on the same thread.
pub fn enter() void {
    if (!swapping) lock.lockSharedUncancelable(io());
    depth_count += 1;
}

pub fn leave() void {
    std.debug.assert(depth_count > 0);
    depth_count -= 1;
    if (!swapping) lock.unlockShared(io());
}

/// The calling thread's entries now (asked on the main thread: the
/// main-thread depth).
pub fn depth() u32 {
    return depth_count;
}

/// Takes the write side if no thread is inside, never waiting. False also
/// when the calling thread is inside itself (its own shared hold counts).
/// On success the calling thread is the swapper until `endSwap`.
pub fn trySwap() bool {
    if (swapping) return false;
    if (!lock.tryLock(io())) return false;
    swapping = true;
    swap_depth = depth_count;
    return true;
}

/// Releases the write side `trySwap` took. The swapper's thread, at the
/// entry depth it had at `trySwap`: inside a pass-through entry that
/// began during the swap, the matching `leave` would release a shared
/// hold it never took. Such a call is a bug in the caller: Debug builds
/// stop on the assertion; other builds log, keep the lock and return
/// false (the caller retries once it left its entries).
pub fn endSwap() bool {
    std.debug.assert(swapping);
    std.debug.assert(depth_count == swap_depth);
    if (!swapping) return false;
    if (depth_count != swap_depth) {
        const msg = "Ziggurat refused to end a swap from inside a script call; the swap stays open until the call returns.";
        godot.raw.printError(msg, "ZigScript", "src/host/gate.zig", @src().line, 1);
        return false;
    }
    setMigrating(null);
    swapping = false;
    lock.unlock(io());
    return true;
}

/// True on the thread that holds the write lock.
pub fn isSwapper() bool {
    return swapping;
}

/// Marks `inst` as the instance being migrated (null: none). The swapper,
/// under the write lock. A new instance starts a new refusal log.
pub fn setMigrating(inst: ?*Instance) void {
    migrating.store(inst, .release);
    refusal_logged.store(null, .release);
}

pub fn isMigrating(inst: *const Instance) bool {
    const m = migrating.load(.acquire) orelse return false;
    return @intFromPtr(m) == @intFromPtr(inst);
}

/// Enters, and returns true when the entry may use `inst`. When `inst` is
/// being migrated it logs once (per instance per migration), leaves again
/// and returns false; the caller then answers as for a missing instance.
pub fn enterInstance(inst: *Instance) bool {
    enter();
    if (!isMigrating(inst)) return true;
    refuse(inst);
    leave();
    return false;
}

fn refuse(inst: *Instance) void {
    if (refusal_logged.swap(inst, .acq_rel) == inst) return;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "Ziggurat refused an entry into an instance of res://{s} while it is being migrated to new code.", .{instance.scriptPath(inst)}, 0) catch return;
    godot.raw.printError(msg.ptr, "ZigScript", "src/host/gate.zig", @src().line, 1);
}

/// How many times `lockForShutdown` retries the try-lock, 1 ms apart.
const shutdown_attempts = 5000;

/// Takes the write side for `runtime.shutdown`, retrying the try-lock
/// until no thread is inside (up to about 5 s). Main thread, at SCENE exit:
/// the main loop has stopped, so only threads that outlived it (a leaked
/// object freed on a worker) can be inside, and they leave without the
/// main thread. Retrying rather than a blocking write lock keeps their
/// nested entries from waiting behind it. False when it gave up or when
/// the calling thread is inside itself; the caller then proceeds without
/// it, as before the gate.
pub fn lockForShutdown() bool {
    if (depth_count != 0 or swapping) return false;
    var i: u32 = 0;
    while (i < shutdown_attempts) : (i += 1) {
        if (lock.tryLock(io())) {
            // The main thread passes through while it holds the lock: an
            // entry would otherwise wait for its own write side.
            swapping = true;
            swap_depth = depth_count;
            return true;
        }
        io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return false;
}

pub fn unlockShutdown() void {
    swapping = false;
    lock.unlock(io());
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "depth counts nested entries on this thread" {
    try testing.expectEqual(@as(u32, 0), depth());
    enter();
    enter();
    try testing.expectEqual(@as(u32, 2), depth());
    leave();
    leave();
    try testing.expectEqual(@as(u32, 0), depth());
}

test "try-swap fails while this thread is inside" {
    enter();
    try testing.expect(!trySwap());
    leave();
    try testing.expect(trySwap());
    try testing.expect(endSwap());
}

test "try-swap fails while another thread is inside, a nested entry there never blocks" {
    const Worker = struct {
        inside: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        nested_done: std.atomic.Value(bool) = .init(false),

        fn run(w: *@This()) void {
            enter();
            w.inside.store(true, .release);
            while (!w.release.load(.acquire)) std.atomic.spinLoopHint();
            // A nested entry while the main thread keeps trying.
            enter();
            w.nested_done.store(true, .release);
            leave();
            leave();
        }
    };
    var w: Worker = .{};
    const t = try std.Thread.spawn(.{}, Worker.run, .{&w});
    while (!w.inside.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(!trySwap());
    w.release.store(true, .release);
    // Keep trying while the worker re-enters: it must get through.
    while (!trySwap()) std.atomic.spinLoopHint();
    try testing.expect(w.nested_done.load(.acquire));
    try testing.expect(endSwap());
    t.join();
}

test "the swapper passes through and other threads wait" {
    try testing.expect(trySwap());
    try testing.expect(isSwapper());
    enter();
    try testing.expectEqual(@as(u32, 1), depth());
    leave();
    const Worker = struct {
        fn run(done: *std.atomic.Value(bool)) void {
            enter();
            done.store(true, .release);
            leave();
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Worker.run, .{&done});
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        try testing.expect(!done.load(.acquire));
        io().sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(endSwap());
    t.join();
    try testing.expect(done.load(.acquire));
    try testing.expect(!isSwapper());
}

test "migrating marks one instance" {
    var a: Instance = undefined;
    var b: Instance = undefined;
    try testing.expect(!isMigrating(&a));
    setMigrating(&a);
    try testing.expect(isMigrating(&a));
    try testing.expect(!isMigrating(&b));
    // The swap's end clears it.
    try testing.expect(trySwap());
    try testing.expect(endSwap());
    try testing.expect(!isMigrating(&a));
}

test "shutdown lock waits for a thread inside" {
    const Worker = struct {
        fn run(started: *std.atomic.Value(bool)) void {
            enter();
            started.store(true, .release);
            io().sleep(.fromMilliseconds(30), .awake) catch {};
            leave();
        }
    };
    var started: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Worker.run, .{&started});
    while (!started.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expect(lockForShutdown());
    // The worker has left: it holds nothing now.
    t.join();
    // The holder passes through.
    enter();
    try testing.expectEqual(@as(u32, 1), depth());
    leave();
    unlockShutdown();
    try testing.expect(!isSwapper());
    enter();
    try testing.expect(!lockForShutdown());
    leave();
}
