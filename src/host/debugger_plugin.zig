//! `ZigDebuggerPlugin`: tells a running game to reload (spec section 6).
//! Right after the editor writes the generation manifest
//! (`editor_build.zig`, `writeManifest`), `sendReload(n)` sends the
//! debugger message `ziggurat:reload` with data `[n]` on every debugger
//! session that is active, that is, to every game the editor runs. The
//! game's `ziggurat` capture (game.zig) asks for a reload of generation
//! `n`; a game that runs `n` already (Play wrote the manifest before the
//! game started) does nothing.
//!
//! The class is an `EditorDebuggerPlugin` (a RefCounted), registered at the
//! EDITOR level like the editor plugin and never exposed. `ZigEditorPlugin`
//! creates one in `_enterTree` (`attach`) and hands it to the editor with
//! `add_debugger_plugin`; Godot then gives it one session per debugger
//! (one per running game instance). `_exitTree` takes it back (`detach`).
//! An export build has none of this.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const Array = godot.builtin.Array;
const Variant = godot.builtin.Variant;
const Object = godot.class.Object;
const RefCounted = godot.class.RefCounted;
const EditorPlugin = godot.class.EditorPlugin;
const EditorDebuggerPlugin = godot.class.EditorDebuggerPlugin;
const EditorDebuggerSession = godot.class.EditorDebuggerSession;

/// The message the game's `ziggurat` capture receives as `reload`.
pub const reload_message = "ziggurat:reload";

pub const ZigDebuggerPlugin = struct {
    base: *EditorDebuggerPlugin,

    pub fn create(allocator: *Allocator) !*ZigDebuggerPlugin {
        const self = try allocator.create(ZigDebuggerPlugin);
        self.* = .{ .base = EditorDebuggerPlugin.init() };
        self.base.setInstance(ZigDebuggerPlugin, self);
        return self;
    }

    pub fn destroy(self: *ZigDebuggerPlugin, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }
};

/// The plugin while the editor plugin is in the tree; this module holds one
/// counted reference to it. Main thread.
var current: ?*ZigDebuggerPlugin = null;

/// Messages `sendReload` sent, and the generation of its last call (-1:
/// none), for the host tests. Main thread.
pub var test_sends: i64 = 0;
pub var test_last_n: i64 = -1;

/// Creates the plugin and hands it to the editor (`ZigEditorPlugin`'s
/// `_enterTree`). Main thread.
pub fn attach(editor_plugin: *EditorPlugin) void {
    comptime std.debug.assert(!host_options.export_build);
    if (current != null) return;
    var alloc = godot.engine_allocator;
    const plugin = ZigDebuggerPlugin.create(&alloc) catch {
        log("Ziggurat cannot tell running games to reload: out of memory.", .{});
        return;
    };
    // `init` gave this module one counted reference; the editor takes its
    // own.
    editor_plugin.addDebuggerPlugin(plugin.base);
    current = plugin;
}

/// Takes the plugin back from the editor and drops this module's
/// reference (`ZigEditorPlugin`'s `_exitTree`). Main thread.
pub fn detach(editor_plugin: *EditorPlugin) void {
    comptime std.debug.assert(!host_options.export_build);
    const plugin = current orelse return;
    current = null;
    editor_plugin.removeDebuggerPlugin(plugin.base);
    const rc = RefCounted.upcast(plugin.base);
    if (rc.unreference()) godot.raw.objectDestroy(@ptrCast(rc));
}

/// Sends `ziggurat:reload` with `[n]` on every active session. Main thread,
/// right after the manifest naming generation `n` is written. Without the
/// plugin (no editor plugin, a non-interactive run) nothing is sent.
pub fn sendReload(n: u32) void {
    if (comptime host_options.export_build) return;
    test_last_n = n;
    const plugin = current orelse return;
    var sessions = plugin.base.getSessions();
    defer sessions.deinit();
    const len: usize = @intCast(@max(sessions.size(), 0));
    const a = std.heap.c_allocator;
    const vars = a.alloc(Variant, len) catch {
        log("Ziggurat cannot tell running games to reload build {d}: out of memory.", .{n});
        return;
    };
    defer a.free(vars);
    const list = a.alloc(Session, len) catch {
        log("Ziggurat cannot tell running games to reload build {d}: out of memory.", .{n});
        return;
    };
    defer a.free(list);
    for (vars, list, 0..) |*v, *s, i| {
        v.* = sessions.get(@intCast(i));
        s.* = .{ .session = if (v.as(*Object)) |o| EditorDebuggerSession.downcast(o) else null };
    }
    defer for (vars) |*v| v.deinit();
    test_sends += sendToActive(list, n);
}

/// One editor debugger session as `sendToActive` sees it.
const Session = struct {
    session: ?*EditorDebuggerSession,

    pub fn isActive(self: Session) bool {
        const s = self.session orelse return false;
        return s.isActive();
    }

    pub fn send(self: Session, n: u32) void {
        const s = self.session orelse return;
        var msg = String.fromLatin1(reload_message);
        defer msg.deinit();
        var data = Array.init();
        defer data.deinit();
        data.pushBack(Variant.init(i64, n));
        s.sendMessage(msg, .{ .data = data });
    }
};

/// Sends generation `n` once on each active session of `sessions` (any
/// type with `isActive() bool` and `send(n)`); an inactive one gets
/// nothing. Returns how many were sent.
pub fn sendToActive(sessions: anytype, n: u32) u32 {
    var sent: u32 = 0;
    for (sessions) |s| {
        if (!s.isActive()) continue;
        s.send(n);
        sent += 1;
    }
    return sent;
}

/// Adds the class registry entry: EDITOR level, not exposed.
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    _ = registry.createClass(ZigDebuggerPlugin, registry.allocator, .{ .level = .editor, .is_exposed = false });
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s = String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

const FakeSession = struct {
    active: bool,
    got: *std.ArrayList(u32),

    pub fn isActive(self: FakeSession) bool {
        return self.active;
    }

    pub fn send(self: FakeSession, n: u32) void {
        self.got.append(std.testing.allocator, n) catch unreachable;
    }
};

test "two sessions: each active session gets one message, inactive ones none" {
    var a: std.ArrayList(u32) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayList(u32) = .empty;
    defer b.deinit(std.testing.allocator);
    var c: std.ArrayList(u32) = .empty;
    defer c.deinit(std.testing.allocator);
    const list = [_]FakeSession{
        .{ .active = true, .got = &a },
        .{ .active = false, .got = &b },
        .{ .active = true, .got = &c },
    };
    try std.testing.expectEqual(@as(u32, 2), sendToActive(&list, 7));
    try std.testing.expectEqualSlices(u32, &.{7}, a.items);
    try std.testing.expectEqualSlices(u32, &.{}, b.items);
    try std.testing.expectEqualSlices(u32, &.{7}, c.items);
    // No sessions at all: nothing is sent.
    try std.testing.expectEqual(@as(u32, 0), sendToActive(@as([]const FakeSession, &.{}), 8));
}
