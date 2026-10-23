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
//!
//! A game reads the manifest at start, and the editor accepts its debugger
//! connection a frame or more later; a manifest written in between would
//! reach the game through no message. So each session's `started` signal
//! (a game connected) sends the generation of the last manifest write once
//! more (`session_started`); the game ignores a generation it runs.
//! An export build has none of this.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const host_callable = @import("host_callable.zig");

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

    /// Called by gdzig's free callback when Godot frees the object (the
    /// last reference dropped, see `detach`); `base.destroy` then does
    /// nothing more.
    pub fn destroy(self: *ZigDebuggerPlugin, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    /// `EditorDebuggerPlugin._setup_session`: Godot calls it once per
    /// session (one per debugger, so per game instance the editor can run),
    /// when the plugin is added and when a debugger is added later. The
    /// session may be inactive then; its `started` signal fires each time a
    /// game connects and the session becomes active.
    pub fn _setupSession(self: *ZigDebuggerPlugin, session_id: i32) void {
        const s = self.base.getSession(session_id) orelse return;
        // `get_session` returns a Ref: the reference is the caller's.
        defer {
            const rc = RefCounted.upcast(s);
            if (rc.unreference()) godot.raw.objectDestroy(@ptrCast(rc));
        }
        var c = host_callable.callable(Object.upcast(self.base), "session_started");
        defer c.deinit();
        _ = Object.upcast(s).connectRaw(.fromComptimeLatin1("started"), c, .{});
    }

    /// Bound as `session_started` (a session's `started` signal): a game
    /// connected. It may have read the manifest before the editor accepted
    /// its connection, and a manifest written in between sent it nothing,
    /// so the generation of the last manifest write goes to every active
    /// session again. A game that runs it already does nothing.
    pub fn sessionStarted(self: *ZigDebuggerPlugin) void {
        test_started += 1;
        if (last_written) |n| test_resent_n = n;
        sendNow(self, last_written);
    }
};

/// The generation of the last manifest write (`sendReload`) in this editor
/// session, or null. Main thread.
var last_written: ?u32 = null;

/// The plugin while the editor plugin is in the tree; this module holds one
/// counted reference to it. Main thread.
var current: ?*ZigDebuggerPlugin = null;

/// Messages `sendReload` sent, and the generation of its last call (-1:
/// none), for the host tests. Main thread.
pub var test_sends: i64 = 0;
pub var test_last_n: i64 = -1;
/// Calls of `session_started`, and the generation it sent last (-1: none),
/// for the host tests. Main thread.
pub var test_started: i64 = 0;
pub var test_resent_n: i64 = -1;

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
    last_written = n;
    const plugin = current orelse return;
    sendNow(plugin, n);
}

/// Sends generation `last` (none when null) on every active session of
/// `plugin`.
fn sendNow(plugin: *ZigDebuggerPlugin, last: ?u32) void {
    const n = last orelse return;
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
    test_sends += sendLast(list, n);
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

/// The plugin's sessions (an empty Array without a plugin), for the host
/// tests. The caller deinits the Array.
pub fn testSessions() Array {
    const plugin = current orelse return Array.init();
    return plugin.base.getSessions();
}

/// What `session_started` does with the sessions: the last written
/// generation (if any) to each active one.
pub fn sendLast(sessions: anytype, last: ?u32) u32 {
    return sendToActive(sessions, last orelse return 0);
}

/// Adds the class registry entry: EDITOR level, not exposed.
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    const cls = registry.createClass(ZigDebuggerPlugin, registry.allocator, .{ .level = .editor, .is_exposed = false });
    cls.addMethod("session_started", .auto);
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

test "a session that becomes active after the write gets the last generation" {
    var got: std.ArrayList(u32) = .empty;
    defer got.deinit(std.testing.allocator);
    var list = [_]FakeSession{.{ .active = false, .got = &got }};
    // The manifest write: the game's session is not active yet.
    try std.testing.expectEqual(@as(u32, 0), sendToActive(&list, 9));
    try std.testing.expectEqual(@as(usize, 0), got.items.len);
    // The session starts: the last written generation goes out once.
    list[0].active = true;
    try std.testing.expectEqual(@as(u32, 1), sendLast(&list, 9));
    try std.testing.expectEqualSlices(u32, &.{9}, got.items);
    // Nothing written yet in this editor session: nothing is sent.
    try std.testing.expectEqual(@as(u32, 0), sendLast(&list, null));
    try std.testing.expectEqualSlices(u32, &.{9}, got.items);
}
