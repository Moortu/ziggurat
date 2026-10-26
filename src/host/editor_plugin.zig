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
//! tells running games to reload after each manifest write, the export
//! plugin (export_plugin.zig), which builds an exported game's library
//! from the project's Zig scripts and leaves `.zig` files out of the
//! export, and gives the
//! script editor the Zig syntax highlighter (highlighter.zig; the script
//! editor exists from here on, not at EDITOR init). When it leaves the tree
//! it takes the menu items, the panel, the debugger and export plugins,
//! the highlighter and its signal connections back (editor_build.zig has the
//! build API).
//!
//! Zig download (zig_download.zig): `Download Zig 0.17.0` starts it. Its
//! HTTPRequest nodes are children of the plugin, which receives their
//! `request_completed` (bound `on_download_completed`). Each frame the
//! plugin lets the download take a worker result and follow its progress
//! (`zig_download.tick`), shows its state in the panel's download row, asks
//! for a build after it installed Zig (`requestBuild(.manual)`, so the
//! locator finds the new Zig) and shows an error toast when it failed.
//! Leaving the tree ends a running download.
//!
//! Indentation: Godot has one global indentation setting for every
//! language (tabs by default), and the script editor converts a file to
//! its tab's indentation on save (`convert_indent_on_save`). With the
//! editor setting `ziggurat/editor/indent_with_spaces` on (the default)
//! the plugin sets `indent_use_spaces` and `indent_size` 4 on the CodeEdit
//! of every open `.zig` tab, so a save writes spaces, as `zig fmt` does.
//! Godot sets its own values on every tab again when a `text_editor`
//! setting changes (NOTIFICATION_EDITOR_SETTINGS_CHANGED), so the plugin
//! applies them again at the next frame after that notification, after
//! every `settings_changed` signal, when a tab opens or changes
//! (`editor_script_changed`) and at focus-in. With the setting off it sets
//! Godot's own choice (`text_editor/behavior/indent/type` and `size`).
//!
//! Files edited outside Godot: there is no file watcher. When the editor
//! regains focus (NOTIFICATION_APPLICATION_FOCUS_IN) and, while the editor
//! setting `ziggurat/build/check_interval_seconds` is above 0, at that
//! interval, the plugin asks for a `watcher` build that the service runs
//! only when a script or helper file changed since the last build
//! (`editor_build.requestIfChanged`).
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
//! the run is cancelled. Where the main-thread queue may not run
//! (`language.atSafePoint` is false: module code on the main thread's
//! stack, as when a tool script starts Play, or a drain running), Play does
//! not wait: it requests the build and decides at once, as after the
//! timeout.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const editor_build = @import("editor_build.zig");
const editor_panel = @import("editor_panel.zig");
const debugger_plugin = @import("debugger_plugin.zig");
const export_plugin = @import("export_plugin.zig");
const highlighter = @import("highlighter.zig");
const zig_download = @import("zig_download.zig");
const host_callable = @import("host_callable.zig");
const host_io = @import("host_io.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const PackedStringArray = godot.builtin.PackedStringArray;
const PackedByteArray = godot.builtin.PackedByteArray;
const EditorPlugin = godot.class.EditorPlugin;
const Object = godot.class.Object;
const Node = godot.class.Node;
const CodeEdit = godot.class.CodeEdit;
const ScriptEditorBase = godot.class.ScriptEditorBase;
const EditorInterface = godot.class.EditorInterface;
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
    /// The indentation of the open `.zig` tabs is set at the next frame.
    indent_dirty: bool = true,
    /// `ziggurat/build/check_interval_seconds` in milliseconds (0 = off),
    /// read again when the editor settings change.
    check_interval_ms: i64 = 0,
    /// Awake-clock milliseconds of the last interval check.
    last_check_ms: i64 = 0,
    /// `zig_download.changes` / `completions` / `failures` handled.
    seen_download: u32 = 0,
    seen_completions: u32 = 0,
    seen_failures: u32 = 0,

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
        if (host_options.test_probe) active = self;
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
        zig_download.attach(Object.upcast(self.base), Node.upcast(self.base));
        self.seen_download = zig_download.changes;
        self.seen_completions = zig_download.completions;
        self.seen_failures = zig_download.failures;
        debugger_plugin.attach(self.base);
        export_plugin.attach(self.base);
        highlighter.attach();
        self.connectSignals(true);
        self.readSettings();
        self.indent_dirty = true;
        self.last_check_ms = nowMs();
        self.base.setProcess(true);
    }

    pub fn _exitTree(self: *ZigEditorPlugin) void {
        if (host_options.test_probe) active = null;
        self.base.setProcess(false);
        zig_download.detach();
        self.connectSignals(false);
        highlighter.detach();
        export_plugin.detach(self.base);
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

    /// Focus-in looks for files changed outside the editor; Godot applied
    /// its editor settings to every tab again (the settings dialog's
    /// `notify_changes`), so the indentation is set at the next frame.
    pub fn _notification(self: *ZigEditorPlugin, what: i32, _: bool) void {
        switch (what) {
            Node.NOTIFICATION_APPLICATION_FOCUS_IN => {
                self.indent_dirty = true;
                editor_build.requestIfChanged(.watcher);
            },
            notification_editor_settings_changed => self.onSettingsChanged(),
            else => {},
        }
    }

    /// Bound as `on_settings_changed` (EditorSettings `settings_changed`),
    /// and called for NOTIFICATION_EDITOR_SETTINGS_CHANGED.
    pub fn onSettingsChanged(self: *ZigEditorPlugin) void {
        self.indent_dirty = true;
        self.readSettings();
    }

    /// Bound as `on_script_changed` (ScriptEditor `editor_script_changed`:
    /// a tab opened or became current).
    pub fn onScriptChanged(self: *ZigEditorPlugin, _: ?*Object) void {
        self.indent_dirty = true;
    }

    /// Each frame: the indentation of the `.zig` tabs when it is due, the
    /// interval check, then the panel: a new applied outcome updates it and
    /// pushes its toast; a build that starts or ends updates the Build
    /// button.
    pub fn _process(self: *ZigEditorPlugin, _: f64) void {
        if (self.indent_dirty) {
            self.indent_dirty = false;
            applyIndent();
        }
        if (self.check_interval_ms > 0) {
            const now = nowMs();
            if (now - self.last_check_ms >= self.check_interval_ms) {
                self.last_check_ms = now;
                editor_build.requestIfChanged(.watcher);
            }
        }
        zig_download.tick();
        self.syncDownload();
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
        // the queue first turns it into a request this one joins. Where the
        // queue may not run (module code on the main thread's stack, as
        // when a tool script presses Play, or a drain running), the outcome
        // cannot be applied either, so Play decides at once.
        if (editor_build.applyFinished() == null) {
            editor_build.requestBuild(.play);
            return self.startWithoutWaiting();
        }
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
            const ran = editor_build.applyFinished() orelse 0;
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
            // outcomes wait than one drain runs. Wait on while time is left;
            // a round that applied nothing pauses briefly, so the loop
            // never spins.
            if (idle) {
                if (ran == 0) io.sleep(.fromMilliseconds(1), .awake) catch {};
                continue;
            }
            if (startNotice()) return true;
            log("Ziggurat cancelled the run because the Zig build still runs after {d} s and no good build exists yet; see the Zig panel.", .{wait_s});
            self.showPanel();
            return false;
        }
    }

    /// Play reached from where it cannot wait for the build: true with
    /// the toast while a good build exists, else false.
    fn startWithoutWaiting(self: *ZigEditorPlugin) bool {
        if (startNotice()) return true;
        log("Ziggurat cancelled the run because Play was started while Zig code or a build update ran on the main thread, so it could not wait for the Zig build, and no good build exists yet; see the Zig panel.", .{});
        self.showPanel();
        return false;
    }

    /// While a good build exists, pushes the "still running" toast and
    /// returns true; else false.
    fn startNotice() bool {
        const n = editor_build.startableGeneration() orelse return false;
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Zig build still running; the game starts with build {d} and reloads when the build finishes", .{n}) catch return true;
        editor_panel.pushToast(.{ .severity = .warning, .text = text, .tooltip = "" });
        return true;
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

    /// Reads the check interval again (a changed interval starts counting
    /// now) and the build settings (`editor_build.readBuildSettings`; they
    /// apply at the next build), and shows the debugger-builds line in the
    /// panel.
    fn readSettings(self: *ZigEditorPlugin) void {
        const ms = @as(i64, editor_build.checkIntervalSeconds()) * 1000;
        if (ms != self.check_interval_ms) self.last_check_ms = nowMs();
        self.check_interval_ms = ms;
        editor_build.readBuildSettings();
        if (self.panel) |panel| panel.setDebugger(editor_build.debuggerBuilds());
    }

    /// Connects (or disconnects) EditorSettings `settings_changed` and
    /// ScriptEditor `editor_script_changed` to the bound methods.
    fn connectSignals(self: *ZigEditorPlugin, on: bool) void {
        const obj = Object.upcast(self.base);
        if (editor_build.editorSettings()) |es| {
            defer editor_build.releaseRef(es);
            connectOne(Object.upcast(es), .fromComptimeLatin1("settings_changed"), obj, "on_settings_changed", on);
        }
        if (EditorInterface.getScriptEditor()) |se| {
            connectOne(Object.upcast(se), .fromComptimeLatin1("editor_script_changed"), obj, "on_script_changed", on);
        }
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

    /// Bound as `download_menu` (Tools > Download Zig 0.17.0): starts the
    /// download; a second click while it runs is ignored.
    pub fn downloadMenu(_: *ZigEditorPlugin) void {
        zig_download.start();
    }

    /// Bound as `on_download_completed` (HTTPRequest `request_completed`
    /// of the download's current request). Main thread.
    pub fn onDownloadCompleted(_: *ZigEditorPlugin, result: i64, code: i64, _: PackedStringArray, body: PackedByteArray) void {
        zig_download.onCompleted(result, code, &body);
    }

    /// Shows a changed download state in the panel; a finished install asks
    /// for a build, a failed download shows an error toast.
    fn syncDownload(self: *ZigEditorPlugin) void {
        if (zig_download.changes == self.seen_download) return;
        self.seen_download = zig_download.changes;
        const st = zig_download.state();
        if (self.panel) |panel| {
            var buf: [512]u8 = undefined;
            const shown: editor_panel.DownloadState = switch (st) {
                .idle => .idle,
                .fetching_mirrors, .downloading => .downloading,
                .checking => .checking,
                .done => .installed,
                .failed => .failed,
            };
            panel.showDownload(shown, zig_download.stateText(&buf, st));
        }
        if (zig_download.completions != self.seen_completions) {
            self.seen_completions = zig_download.completions;
            editor_build.requestBuild(.manual);
        }
        if (zig_download.failures != self.seen_failures) {
            self.seen_failures = zig_download.failures;
            const reason = switch (st) {
                .failed => |f| f.reason,
                else => "",
            };
            var buf: [400]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Ziggurat could not download Zig 0.17.0: {s}", .{reason}) catch "Ziggurat could not download Zig 0.17.0.";
            editor_panel.pushToast(.{ .severity = .@"error", .text = text, .tooltip = "" });
            if (self.panel) |panel| panel.makeVisible();
        }
    }

    /// TEST ONLY (bound as `test_ping` in probe builds): counts its calls,
    /// so a host test can check that a Callable made in Zig reaches a
    /// method bound on this class.
    pub fn testPing(_: *ZigEditorPlugin) void {
        test_pings += 1;
    }
};

/// `EditorSettings.NOTIFICATION_EDITOR_SETTINGS_CHANGED`
/// (editor/settings/editor_settings.h).
const notification_editor_settings_changed: i32 = 10000;

const indent_type_setting = "text_editor/behavior/indent/type";
const indent_size_setting = "text_editor/behavior/indent/size";

/// The indentation the plugin sets on `.zig` tabs: spaces and 4 with
/// `ziggurat/editor/indent_with_spaces` on, otherwise Godot's own
/// (`text_editor/behavior/indent/type` 1 = spaces, and `size`).
const Indent = struct { spaces: bool, size: i32 };

fn wantedIndent() Indent {
    if (editor_build.indentWithSpaces()) return .{ .spaces = true, .size = 4 };
    var out: Indent = .{ .spaces = false, .size = 4 };
    if (editor_build.editorSetting(indent_type_setting)) |v| {
        defer v.deinit();
        out.spaces = (v.as(i64) orelse 0) == 1;
    }
    if (editor_build.editorSetting(indent_size_setting)) |v| {
        defer v.deinit();
        out.size = std.math.cast(i32, v.as(i64) orelse 4) orelse 4;
    }
    return out;
}

/// Sets the indentation (`wantedIndent`) on the CodeEdit of every open
/// `.zig` tab. `ScriptEditor.get_open_script_editors` lists every tab's
/// editor and `get_open_scripts` the scripts of those that edit a script,
/// both in tab order; a script tab's editor is a `ScriptTextEditor`, so
/// those editors pair with the scripts. If the counts differ (an editor
/// type this does not know), only the current tab is set. Main thread.
fn applyIndent() void {
    const se = EditorInterface.getScriptEditor() orelse return;
    const want = wantedIndent();
    var editors = se.getOpenScriptEditors();
    defer editors.deinit();
    var scripts = se.getOpenScripts();
    defer scripts.deinit();
    var script_editors: [max_tabs]*ScriptEditorBase = undefined;
    var n: usize = 0;
    var i: i64 = 0;
    while (i < editors.size()) : (i += 1) {
        const v = editors.get(i);
        defer v.deinit();
        const o = v.as(*Object) orelse continue;
        const seb = ScriptEditorBase.downcast(o) orelse continue;
        if (!isClass(o, "ScriptTextEditor")) continue;
        if (n == max_tabs) break;
        script_editors[n] = seb;
        n += 1;
    }
    if (n == scripts.size()) {
        for (script_editors[0..n], 0..) |seb, k| {
            const v = scripts.get(@intCast(k));
            defer v.deinit();
            const o = v.as(*Object) orelse continue;
            if (isZig(o)) setIndent(seb, want);
        }
        return;
    }
    const seb = se.getCurrentEditor() orelse return;
    const cur = se.getCurrentScript() orelse return;
    defer editor_build.releaseRef(cur);
    if (isZig(Object.upcast(cur))) setIndent(seb, want);
}

/// Tabs looked at by `applyIndent`; more are left as Godot set them.
const max_tabs = 256;

fn setIndent(seb: *ScriptEditorBase, want: Indent) void {
    const base = seb.getBaseEditor() orelse return;
    const code = CodeEdit.downcast(base) orelse return;
    if (code.isIndentUsingSpaces() != want.spaces) code.setIndentUsingSpaces(want.spaces);
    if (code.getIndentSize() != want.size) code.setIndentSize(want.size);
}

/// True when `o` is a resource whose path ends in `.zig` (any case).
fn isZig(o: *Object) bool {
    const res = godot.class.Resource.downcast(o) orelse return false;
    var path = res.getPath();
    defer path.deinit();
    var buf: [4096]u8 = undefined;
    const p = path.toUtf8Buf(&buf);
    return p.len >= 4 and std.ascii.eqlIgnoreCase(p[p.len - 4 ..], ".zig");
}

fn isClass(o: *Object, comptime name: []const u8) bool {
    var c = o.getClass();
    defer c.deinit();
    var buf: [64]u8 = undefined;
    return std.mem.eql(u8, c.toUtf8Buf(&buf), name);
}

/// Connects or disconnects `signal` of `source` to the bound `method` of
/// `target`, once.
fn connectOne(source: *Object, signal: StringName, target: *Object, comptime method: [:0]const u8, on: bool) void {
    var c = host_callable.callable(target, method);
    defer c.deinit();
    const connected = source.isConnected(signal, c);
    if (on and !connected) {
        _ = source.connectRaw(signal, c, .{});
    } else if (!on and connected) {
        source.disconnectRaw(signal, c);
    }
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(host_io.get()).toMilliseconds();
}

/// Calls of `test_ping`. Main thread.
pub var test_pings: i64 = 0;

/// The plugin while it is in the tree; set only in probe builds (the
/// probe calls its `_build`). Main thread.
pub var active: ?*ZigEditorPlugin = null;

/// Calls of `_build` (for the host tests). Main thread.
pub var play_calls: i64 = 0;
/// What the last `_build` returned (for the host tests). Main thread.
pub var play_result: bool = false;
/// Calls of `_build` that requested a build (for the host tests). Main
/// thread.
pub var play_requests: i64 = 0;

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
    cls.addMethod("on_download_completed", .auto);
    cls.addMethod("on_settings_changed", .auto);
    cls.addMethod("on_script_changed", .auto);
    if (host_options.test_probe) cls.addMethod("test_ping", .auto);
    const panel = registry.createClass(ZigPanel, registry.allocator, .{ .level = .editor, .is_exposed = false });
    panel.addMethod("build_pressed", .auto);
    panel.addMethod("on_meta_clicked", .auto);
    panel.addMethod("download_cancel_pressed", .auto);
    debugger_plugin.register(registry);
    export_plugin.register(registry);
    highlighter.register(registry);
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
