//! `ZigEditorPlugin`: the host's editor plugin (spec section 9). It is
//! registered at the EDITOR initialization level, because its parent
//! `EditorPlugin` is registered there (`register_editor_types`), and handed
//! to the editor with `editor_add_plugin`. Godot keeps the class name until
//! EditorNode exists, then creates one plugin and adds it as a child of
//! EditorNode (editor/editor_node.cpp, `add_extension_editor_plugin`). A
//! game started from an editor binary runs the EDITOR level too; the class
//! is registered there, but no plugin is added (`Engine.is_editor_hint()` is
//! false), so none exists. An export build has neither.
//!
//! When it enters the tree the plugin registers the editor setting
//! `ziggurat/zig_path` (the per-user Zig path, with a file picker), lets
//! the build at open start if it waited for that setting
//! (`editor_build.editorReady`), adds the Zig panel (a bottom dock,
//! editor_panel.zig) and the Tools menu items `Build Zig Scripts` and
//! `Download Zig 0.17.0`. Each frame (`_process`) it checks whether a new
//! build outcome was applied (`editor_build.outcomes_applied`) or a build
//! started or ended; then it updates the panel and pushes the outcome's
//! toast. It also adds the debugger plugin (debugger_plugin.zig), which
//! tells running games to reload after each manifest write. When it leaves
//! the tree it takes the menu items, the panel and the debugger plugin
//! back. The download builds on it (editor_build.zig has the build API).
//!
//! Build on Play (`_build`: Godot calls it on the main thread when Play is
//! pressed, after it saved the open scenes and scripts, and the run waits
//! for its answer; `--build-solutions` calls it once and exits with status
//! 1 on false): with the project setting
//! `ziggurat/build/build_on_play` on (the default) and a build service,
//! the plugin requests a `play` build, waits up to
//! `ziggurat/build/play_wait_seconds` (60 by default) for the service and
//! applies the outcome, so the manifest names the new build before the
//! game starts. A good build plays; a failed one cancels the run and shows
//! the Zig panel, as C# does. After the timeout the game starts with the
//! last good build (this session's, else the one the manifest names) and a
//! toast says it reloads when the build finishes; without any good build
//! the run is cancelled.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const editor_build = @import("editor_build.zig");
const editor_panel = @import("editor_panel.zig");
const debugger_plugin = @import("debugger_plugin.zig");
const host_callable = @import("host_callable.zig");
const host_io = @import("host_io.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const EditorPlugin = godot.class.EditorPlugin;
const Object = godot.class.Object;
const ZigPanel = editor_panel.ZigPanel;

pub const menu_build = "Build Zig Scripts";
pub const menu_download = "Download Zig 0.17.0";

pub const ZigEditorPlugin = struct {
    base: *EditorPlugin,
    /// The Zig panel while the plugin is in the tree.
    panel: ?*ZigPanel = null,
    /// `editor_build.outcomes_applied` the panel shows. It starts at 0 and
    /// is not reset when the panel is made, so an outcome applied before
    /// the panel existed still gets its toast once (`_process`).
    seen_outcomes: u32 = 0,
    /// `editor_build.status().building` the panel shows.
    seen_building: bool = false,

    pub fn create(allocator: *Allocator) !*ZigEditorPlugin {
        const self = try allocator.create(ZigEditorPlugin);
        self.* = .{ .base = EditorPlugin.init() };
        self.base.setInstance(ZigEditorPlugin, self);
        return self;
    }

    pub fn destroy(self: *ZigEditorPlugin, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    pub fn _getPluginName(_: *ZigEditorPlugin) String {
        return .fromLatin1("Ziggurat");
    }

    pub fn _enterTree(self: *ZigEditorPlugin) void {
        editor_build.editorReady();
        var alloc = godot.engine_allocator;
        if (ZigPanel.create(&alloc)) |panel| {
            self.panel = panel;
            self.base.addDock(panel.base);
            _ = self.refresh();
        } else |_| {
            log("Ziggurat could not create the Zig panel: out of memory.", .{});
        }
        self.addMenuItem(menu_build, "build_menu");
        self.addMenuItem(menu_download, "download_menu");
        debugger_plugin.attach(self.base);
        self.base.setProcess(true);
    }

    pub fn _exitTree(self: *ZigEditorPlugin) void {
        self.base.setProcess(false);
        debugger_plugin.detach(self.base);
        inline for (.{ menu_build, menu_download }) |name| {
            var n = String.fromLatin1(name);
            defer n.deinit();
            self.base.removeToolMenuItem(n);
        }
        if (self.panel) |panel| {
            self.base.removeDock(panel.base);
            var alloc = godot.engine_allocator;
            panel.destroy(&alloc);
            self.panel = null;
        }
    }

    /// Each frame: a new applied outcome updates the panel and pushes its
    /// toast; a build that starts or ends updates the Build button.
    pub fn _process(self: *ZigEditorPlugin, _: f64) void {
        const panel = self.panel orelse return;
        const outcomes = editor_build.outcomes_applied.load(.acquire);
        if (outcomes != self.seen_outcomes) {
            self.seen_outcomes = outcomes;
            const st = self.refresh();
            if (st.last) |last| {
                var buf: [256]u8 = undefined;
                if (editor_panel.toastFor(&buf, last, st.good_n)) |t| editor_panel.pushToast(t);
            }
            return;
        }
        const building = editor_build.status().building;
        if (building != self.seen_building) {
            self.seen_building = building;
            panel.setBuilding(building);
        }
    }

    /// `EditorPlugin._build`: Build on Play (see the file comment). True
    /// lets the game start; false cancels the run. Main thread.
    pub fn _build(self: *ZigEditorPlugin) bool {
        play_calls += 1;
        play_result = self.playBuild();
        return play_result;
    }

    fn playBuild(self: *ZigEditorPlugin) bool {
        if (!editor_build.hasService() or !editor_build.buildOnPlay()) return true;
        play_requests += 1;
        // Play saved the open scenes and scripts just before; a save's
        // build request may still wait in the main-thread queue. Running
        // the queue first turns it into a request this one joins.
        editor_build.applyFinished();
        editor_build.requestBuild(.play);
        const wait_s = editor_build.playWaitSeconds();
        const limit_ms: u64 = @as(u64, wait_s) * 1000;
        const io = host_io.get();
        const t0 = std.Io.Clock.awake.now(io);
        while (true) {
            const spent: u64 = @intCast(@max(t0.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds(), 0));
            const left = std.math.cast(u32, limit_ms -| spent) orelse std.math.maxInt(u32);
            const idle = left > 0 and editor_build.waitIdle(left);
            // Applies the outcome now: the manifest names the build before
            // the game starts.
            editor_build.applyFinished();
            const st = editor_build.status();
            if (!st.building) {
                const last = st.last orelse return true;
                if (last.ok) return true;
                log("Ziggurat cancelled the run because the Zig build failed; see the Zig panel.", .{});
                self.showPanel();
                return false;
            }
            // Still building: an applied outcome may have asked for another
            // build (a stale fast build is built again in full), or more
            // outcomes wait than one drain runs. Wait on while time is left.
            if (idle) continue;
            if (editor_build.startableGeneration()) |n| {
                var buf: [160]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "Zig build still running; the game starts with build {d} and reloads when the build finishes", .{n}) catch return true;
                editor_panel.pushToast(.{ .severity = .warning, .text = text, .tooltip = "" });
                return true;
            }
            log("Ziggurat cancelled the run because the Zig build still runs after {d} s and no good build exists yet; see the Zig panel.", .{wait_s});
            self.showPanel();
            return false;
        }
    }

    /// Updates the panel and brings it to the front.
    fn showPanel(self: *ZigEditorPlugin) void {
        const panel = self.panel orelse return;
        _ = self.refresh();
        panel.makeVisible();
    }

    /// Shows the current status and diagnostics in the panel.
    fn refresh(self: *ZigEditorPlugin) editor_build.Status {
        const st = editor_build.status();
        self.seen_building = st.building;
        const panel = self.panel orelse return st;
        const a = std.heap.c_allocator;
        const files = editor_build.diagnosticsCopy(a) catch {
            panel.update(st, &.{});
            return st;
        };
        defer editor_build.freeDiagnostics(a, files);
        panel.update(st, files);
        return st;
    }

    fn addMenuItem(self: *ZigEditorPlugin, comptime name: []const u8, comptime method: [:0]const u8) void {
        var n = String.fromLatin1(name);
        defer n.deinit();
        var c = host_callable.callable(Object.upcast(self.base), method);
        defer c.deinit();
        self.base.addToolMenuItem(n, c);
    }

    /// Bound as `build_menu` (Tools > Build Zig Scripts).
    pub fn buildMenu(_: *ZigEditorPlugin) void {
        editor_build.requestBuild(.manual);
    }

    /// Bound as `download_menu` (Tools > Download Zig 0.17.0). The download
    /// comes in a later version; until then the item says so once.
    pub fn downloadMenu(_: *ZigEditorPlugin) void {
        if (download_logged) return;
        download_logged = true;
        log("Ziggurat cannot download Zig yet; install Zig 0.17.0 and set " ++ editor_build.setting_zig_path ++ ".", .{});
    }

    /// TEST ONLY (bound as `test_ping` in probe builds): counts its calls,
    /// so a host test can check that a Callable made in Zig reaches a
    /// method bound on this class.
    pub fn testPing(_: *ZigEditorPlugin) void {
        test_pings += 1;
    }
};

/// Calls of `test_ping`. Main thread.
pub var test_pings: i64 = 0;

/// Calls of `_build` (for the host tests). Main thread.
pub var play_calls: i64 = 0;
/// What the last `_build` returned (for the host tests). Main thread.
pub var play_result: bool = false;
/// Calls of `_build` that requested a build (for the host tests). Main
/// thread.
pub var play_requests: i64 = 0;

/// Set once `download_menu` logged. Main thread.
var download_logged = false;

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s = String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

/// Adds the class registry entry: EDITOR level, not exposed (Godot creates
/// the plugin itself; scripts and the Create Node dialog have no use for
/// it). `test_ping` is bound only in probe builds. The panel's class
/// (`ZigPanel`, an `EditorDock`) is registered the same way; the plugin
/// creates it.
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    const cls = registry.createClass(ZigEditorPlugin, registry.allocator, .{ .level = .editor, .is_exposed = false });
    cls.addMethod("build_menu", .auto);
    cls.addMethod("download_menu", .auto);
    if (host_options.test_probe) cls.addMethod("test_ping", .auto);
    const panel = registry.createClass(ZigPanel, registry.allocator, .{ .level = .editor, .is_exposed = false });
    panel.addMethod("build_pressed", .auto);
    panel.addMethod("on_meta_clicked", .auto);
    debugger_plugin.register(registry);
}

/// Hands the class to the editor (EDITOR init, after the class is
/// registered). Only in the editor: in a game process nothing is added.
pub fn addToEditor() void {
    comptime std.debug.assert(!host_options.export_build);
    if (!godot.class.Engine.isEditorHint()) return;
    // A comptime StringName: gdzig keeps it for the whole process and it is
    // never freed; Godot copies the name it is given.
    const class_name: StringName = .fromComptimeLatin1("ZigEditorPlugin");
    godot.raw.editorAddPlugin(@ptrCast(&class_name));
}

/// Takes the class back (EDITOR exit). EditorNode is gone by then (its
/// destructor clears the editor's hooks), so Godot only drops the name it
/// kept, which would otherwise be reported as an orphan StringName at exit.
pub fn removeFromEditor() void {
    comptime std.debug.assert(!host_options.export_build);
    if (!godot.class.Engine.isEditorHint()) return;
    const class_name: StringName = .fromComptimeLatin1("ZigEditorPlugin");
    godot.raw.editorRemovePlugin(@ptrCast(&class_name));
}
