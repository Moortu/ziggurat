//! Placeholder script instances (spec sections 2 and 7): what the editor
//! holds for an object whose Zig script does not run there (a script that
//! is not a tool script, or one without descriptors).
//!
//! The placeholder itself is Godot's `PlaceHolderScriptInstance`, made with
//! `placeholder_script_instance_create` and fed with
//! `placeholder_script_instance_update` (gdextension_interface.h,
//! placeholder_script_instance_create/update). No user code runs: it only
//! stores values. Godot facts this relies on (Godot 4.7.2):
//! - `placeholder_script_instance_create` takes a counted reference to the
//!   script (core/extension/gdextension_interface.cpp:1551-1559), so the
//!   script outlives its placeholders; the owner object deletes the
//!   placeholder, and its destructor calls the script's `_placeholder_erased`
//!   (core/object/script_language.cpp:919-923).
//! - `update` keeps a stored value only for a property in the new list and
//!   drops values equal to the script's default (script_language.cpp:806-852).
//!   It then emits the owner's `property_list_changed`.
//! - With placeholder fallback on, `set` refuses and Godot stores every value
//!   through `property_set_fallback` instead, adding a stored property entry
//!   for a name the list lacks (script_language.cpp:680-707, 854-884), so a
//!   scene save keeps it. An update while fallback is on would drop those
//!   values, so GDScript does not update then (modules/gdscript/gdscript.cpp:
//!   574-583, `_update_exports` returns before its placeholder loop), and
//!   neither does `Set.refresh`.
//!
//! `Set` is a script's list of its live placeholders and the descriptors it
//! last fed them. Godot makes placeholders on resource-loader threads too, so
//! the list is guarded by a mutex. An update emits a signal on the owner,
//! whose handlers may create or free placeholders of the same script on the
//! same thread; those calls see that the thread already holds the lock
//! (`in_refresh`) and do not lock again.
const std = @import("std");
const godot = @import("gdzig");
const host_io = @import("host_io.zig");

const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const Object = godot.class.Object;
const ScriptExtension = godot.class.ScriptExtension;

/// A new placeholder of `script` for `owner`, or null when Godot lacks the
/// interface function. `lang` is the language object (`ScriptLanguage`).
pub fn create(lang: *anyopaque, script: *ScriptExtension, owner: *Object) ?*anyopaque {
    const make = godot.raw.placeholderScriptInstanceCreate orelse return null;
    return make(@ptrCast(lang), @ptrCast(script), @ptrCast(owner));
}

/// What placeholders are fed: the property list (Godot's dictionaries,
/// group entries included) and a default value per property name.
pub const Data = struct {
    properties: Array,
    values: Dictionary,

    pub fn deinit(d: *Data) void {
        d.properties.deinit();
        d.values.deinit();
    }

    pub fn feed(d: *const Data, p: *anyopaque) void {
        const update = godot.raw.placeholderScriptInstanceUpdate orelse return;
        update(@ptrCast(p), @ptrCast(&d.properties), @ptrCast(&d.values));
    }
};

/// The `Set` running a refresh on this thread, if any.
threadlocal var in_refresh: ?*const anyopaque = null;

/// The live placeholders of one script. `Key` names the descriptors fed
/// (it has `eql`); null means none were (never, or fallback was on since).
/// A `maker` argument has `make()`, called only when placeholders need data,
/// which returns a value with `feed(*anyopaque)` and `deinit()` (`Data`).
pub fn Set(comptime Key: type) type {
    return struct {
        const Self = @This();

        mu: std.Io.Mutex = .init,
        items: std.ArrayList(*anyopaque) = .empty,
        seen: ?Key = null,
        /// How many times new descriptors were fed (for the host tests).
        refreshes: u32 = 0,

        pub fn deinit(self: *Self) void {
            self.items.deinit(std.heap.c_allocator);
        }

        fn lock(self: *Self) bool {
            if (in_refresh == @as(*const anyopaque, self)) return false;
            self.mu.lockUncancelable(host_io.get());
            return true;
        }

        fn unlock(self: *Self, locked: bool) void {
            if (locked) self.mu.unlock(host_io.get());
        }

        /// Records the new placeholder `p`. With `key` (fallback off), feeds
        /// it: when `key` is not what the others were fed, every placeholder
        /// is refreshed, as GDScript refreshes all on new exports
        /// (gdscript.cpp:607-618); otherwise only `p`. Out of memory, `p` is
        /// fed but not recorded and gets no later refreshes.
        pub fn add(self: *Self, p: *anyopaque, key: ?Key, maker: anytype) void {
            const locked = self.lock();
            defer self.unlock(locked);
            const recorded = if (self.items.append(std.heap.c_allocator, p)) true else |_| false;
            const k = key orelse {
                self.seen = null;
                return;
            };
            if (recorded and !self.isSeen(k)) {
                self.refreshLocked(k, maker);
                return;
            }
            var d = maker.make();
            defer d.deinit();
            self.feed(&d, &.{p}, false);
        }

        /// Forgets `p` (Godot is deleting it).
        pub fn remove(self: *Self, p: *anyopaque) void {
            const locked = self.lock();
            defer self.unlock(locked);
            const i = std.mem.indexOfScalar(*anyopaque, self.items.items, p) orelse return;
            _ = self.items.swapRemove(i);
        }

        /// Feeds every placeholder when `key` differs from what they were
        /// fed last; true when it did. Idempotent: Godot asks once per
        /// property while saving a scene. A null `key` (fallback on) feeds
        /// nothing and makes the next key refresh.
        pub fn refresh(self: *Self, key: ?Key, maker: anytype) bool {
            const locked = self.lock();
            defer self.unlock(locked);
            const k = key orelse {
                self.seen = null;
                return false;
            };
            if (self.isSeen(k)) return false;
            self.refreshLocked(k, maker);
            return true;
        }

        fn isSeen(self: *const Self, k: Key) bool {
            const s = self.seen orelse return false;
            return s.eql(k);
        }

        fn refreshLocked(self: *Self, k: Key, maker: anytype) void {
            self.seen = k;
            self.refreshes += 1;
            if (self.items.items.len == 0) return;
            // A copy: an update can create or free placeholders of this
            // script on this thread, which changes `items`.
            const copy = std.heap.c_allocator.dupe(*anyopaque, self.items.items) catch {
                // Out of memory: the placeholders keep their old data until
                // the next refresh.
                self.seen = null;
                return;
            };
            defer std.heap.c_allocator.free(copy);
            var d = maker.make();
            defer d.deinit();
            self.feed(&d, copy, true);
        }

        /// Feeds `ps` with `d`, marking this thread as inside the lock. With
        /// `live_only`, skips placeholders an earlier update freed.
        fn feed(self: *Self, d: anytype, ps: []const *anyopaque, live_only: bool) void {
            const outer = in_refresh;
            in_refresh = self;
            defer in_refresh = outer;
            for (ps) |p| {
                if (live_only and std.mem.indexOfScalar(*anyopaque, self.items.items, p) == null) continue;
                d.feed(p);
            }
        }

        pub fn count(self: *Self) usize {
            const locked = self.lock();
            defer self.unlock(locked);
            return self.items.items.len;
        }

        pub fn refreshCount(self: *Self) u32 {
            const locked = self.lock();
            defer self.unlock(locked);
            return self.refreshes;
        }
    };
}

// ------------------------------------------------------------- tests
//
// `Set` without Godot: placeholders are plain addresses and the data only
// counts what it was asked to feed.

const testing = std.testing;

const TestKey = struct {
    n: u32,
    pub fn eql(a: TestKey, b: TestKey) bool {
        return a.n == b.n;
    }
};

const TestData = struct {
    log: *Log,
    pub fn feed(d: *const TestData, p: *anyopaque) void {
        d.log.fed.append(testing.allocator, p) catch unreachable;
        if (d.log.hook) |h| h(d.log, p);
    }
    pub fn deinit(_: *TestData) void {}
};

const Log = struct {
    fed: std.ArrayList(*anyopaque) = .empty,
    makes: u32 = 0,
    set: *Set(TestKey),
    hook: ?*const fn (*Log, *anyopaque) void = null,

    pub fn make(l: *Log) TestData {
        l.makes += 1;
        return .{ .log = l };
    }

    fn deinit(l: *Log) void {
        l.fed.deinit(testing.allocator);
    }
};

fn addr(n: usize) *anyopaque {
    return @ptrFromInt(n * 16);
}

test "placeholders are fed once per descriptor key" {
    var set: Set(TestKey) = .{};
    defer set.deinit();
    var log: Log = .{ .set = &set };
    defer log.deinit();

    // The first placeholder brings the first key: a refresh.
    set.add(addr(1), .{ .n = 1 }, &log);
    try testing.expectEqual(@as(u32, 1), set.refreshCount());
    // A second one under the same key is fed alone.
    set.add(addr(2), .{ .n = 1 }, &log);
    try testing.expectEqual(@as(usize, 2), log.fed.items.len);
    try testing.expectEqual(addr(2), log.fed.items[1]);
    // Asking again and again with the same key changes nothing.
    for (0..50) |_| try testing.expect(!set.refresh(.{ .n = 1 }, &log));
    try testing.expectEqual(@as(u32, 2), log.makes);
    // A new key feeds both, once.
    try testing.expect(set.refresh(.{ .n = 2 }, &log));
    try testing.expect(!set.refresh(.{ .n = 2 }, &log));
    try testing.expectEqual(@as(usize, 4), log.fed.items.len);
    try testing.expectEqual(@as(u32, 2), set.refreshCount());
}

test "fallback feeds nothing and the next key refreshes" {
    var set: Set(TestKey) = .{};
    defer set.deinit();
    var log: Log = .{ .set = &set };
    defer log.deinit();

    // Created while fallback is on: recorded, not fed.
    set.add(addr(1), null, &log);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(usize, 0), log.fed.items.len);
    try testing.expect(set.refresh(.{ .n = 1 }, &log));
    try testing.expectEqual(@as(usize, 1), log.fed.items.len);
    // Fallback on again (a failed build), then off with the same key.
    try testing.expect(!set.refresh(null, &log));
    try testing.expect(set.refresh(.{ .n = 1 }, &log));
    try testing.expectEqual(@as(usize, 2), log.fed.items.len);
    set.remove(addr(1));
    try testing.expectEqual(@as(usize, 0), set.count());
}

test "an update may free and create placeholders of the same set" {
    var set: Set(TestKey) = .{};
    defer set.deinit();
    var log: Log = .{ .set = &set };
    defer log.deinit();
    set.add(addr(1), .{ .n = 1 }, &log);
    set.add(addr(2), .{ .n = 1 }, &log);
    set.add(addr(3), .{ .n = 1 }, &log);
    log.fed.clearRetainingCapacity();

    // Feeding placeholder 1 frees placeholder 2 and creates placeholder 4,
    // on the same thread, while the set is locked.
    log.hook = struct {
        fn h(l: *Log, p: *anyopaque) void {
            if (p != addr(1)) return;
            l.set.remove(addr(2));
            l.set.add(addr(4), .{ .n = 2 }, l);
        }
    }.h;
    try testing.expect(set.refresh(.{ .n = 2 }, &log));
    // 1, then 4 (fed on creation), then 3; 2 was freed before its turn.
    try testing.expectEqualSlices(*anyopaque, &.{ addr(1), addr(4), addr(3) }, log.fed.items);
    try testing.expectEqual(@as(usize, 3), set.count());
}
