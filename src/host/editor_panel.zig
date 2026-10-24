//! The Zig panel (spec section 9): a bottom `EditorDock` titled `Zig`,
//! added by the editor plugin (`EditorPlugin.add_dock`; the bottom-panel
//! call is deprecated in Godot 4.7). It holds:
//!
//! - a Build button (the same request as the Tools menu item
//!   `Build Zig Scripts`, trigger `manual`) and the status line of the
//!   last applied build: `Build <n> ok (<trigger>, <path>, <ms> ms)` or
//!   `Build failed: <e> errors, <w> warnings (<ms> ms); build <n> stays in
//!   use`;
//! - a memory line, `Loaded builds: <n> (<size>); descriptor snapshots:
//!   <size>` (`editor_build.memoryText`, refreshed by `update`; hidden
//!   while the text is empty, that is without a build service);
//! - a download row (hidden until `showDownload` shows it): the Zig
//!   download's line and a Cancel button while it transfers;
//! - a `RichTextLabel` of the last build's diagnostics. Each diagnostic in
//!   a project file starts with a link `res://<path>:<line>:<column>`;
//!   clicking it (`meta_clicked`) opens the script there with
//!   `EditorInterface.edit_script`, whose line and column are 1-based like
//!   the compiler's.
//!
//! The plugin calls `update` when an outcome was applied and `setBuilding`
//! when a build starts or ends, and `pushToast` for the toasts of a new
//! outcome. Everything here runs on the main thread (Godot's bound
//! `push_toast` adds nodes directly). None of it exists in an export build.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const editor_build = @import("editor_build.zig");
const zig_download = @import("zig_download.zig");
const host_callable = @import("host_callable.zig");
const props = @import("props.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const Vector2 = godot.builtin.Vector2;
const Object = godot.class.Object;
const Node = godot.class.Node;
const Control = godot.class.Control;
const EditorDock = godot.class.EditorDock;
const VBoxContainer = godot.class.VBoxContainer;
const HBoxContainer = godot.class.HBoxContainer;
const Label = godot.class.Label;
const Button = godot.class.Button;
const RichTextLabel = godot.class.RichTextLabel;
const EditorInterface = godot.class.EditorInterface;
const ResourceLoader = godot.class.ResourceLoader;
const Script = godot.class.Script;

/// Longest diagnostic line handled (longer messages are cut).
const max_line_bytes = 4096 + 1024;

pub const ZigPanel = struct {
    base: *EditorDock,
    button: *Button,
    status: *Label,
    memory: *Label,
    download_row: *HBoxContainer,
    download_text: *Label,
    download_cancel: *Button,
    diagnostics: *RichTextLabel,

    /// Builds the dock and its children. Godot calls it too if the class
    /// is ever instantiated by name, but the plugin creates the panel.
    pub fn create(allocator: *Allocator) !*ZigPanel {
        const self = try allocator.create(ZigPanel);
        const dock = EditorDock.init();
        self.* = .{
            .base = dock,
            .button = Button.init(),
            .status = Label.init(),
            .memory = Label.init(),
            .download_row = HBoxContainer.init(),
            .download_text = Label.init(),
            .download_cancel = Button.init(),
            .diagnostics = RichTextLabel.init(),
        };
        dock.setInstance(ZigPanel, self);
        self.build();
        return self;
    }

    /// Godot frees the dock (and its children) when the plugin calls this
    /// or when the engine deletes it; either way the Zig side goes too.
    pub fn destroy(self: *ZigPanel, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    fn build(self: *ZigPanel) void {
        const dock = self.base;
        setText(EditorDock, dock, "setTitle", "Zig");
        setText(EditorDock, dock, "setLayoutKey", "Ziggurat");
        dock.setDefaultSlot(.dock_slot_bottom);
        dock.setAvailableLayouts(.{ .dock_layout_horizontal = true, .dock_layout_vertical = true });
        dock.setName(.fromComptimeLatin1("Zig"));

        const column = VBoxContainer.init();
        column.setName(.fromComptimeLatin1("Column"));
        dock.addChild(.upcast(column), .{});

        const top = HBoxContainer.init();
        top.setName(.fromComptimeLatin1("Top"));
        column.addChild(.upcast(top), .{});
        self.button.setName(.fromComptimeLatin1("BuildButton"));
        setText(Button, self.button, "setText", "Build");
        setText(Button, self.button, "setTooltipText", "Build the project's Zig scripts now");
        top.addChild(.upcast(self.button), .{});
        self.status.setName(.fromComptimeLatin1("Status"));
        self.status.setHSizeFlags(.{ .size_fill = true, .size_expand = true });
        setText(Label, self.status, "setText", "No build yet");
        top.addChild(.upcast(self.status), .{});

        self.memory.setName(.fromComptimeLatin1("Memory"));
        self.memory.setVisible(false);
        column.addChild(.upcast(self.memory), .{});

        self.download_row.setName(.fromComptimeLatin1("Download"));
        self.download_row.setVisible(false);
        self.download_text.setName(.fromComptimeLatin1("DownloadText"));
        self.download_row.addChild(.upcast(self.download_text), .{});
        self.download_cancel.setName(.fromComptimeLatin1("DownloadCancel"));
        setText(Button, self.download_cancel, "setText", "Cancel");
        setText(Button, self.download_cancel, "setTooltipText", "Stop the Zig download");
        self.download_cancel.setVisible(false);
        self.download_row.addChild(.upcast(self.download_cancel), .{});
        column.addChild(.upcast(self.download_row), .{});

        const rt = self.diagnostics;
        rt.setName(.fromComptimeLatin1("Diagnostics"));
        rt.setSelectionEnabled(true);
        rt.setContextMenuEnabled(true);
        rt.setVSizeFlags(.{ .size_fill = true, .size_expand = true });
        rt.setHSizeFlags(.{ .size_fill = true, .size_expand = true });
        rt.setCustomMinimumSize(Vector2.initXY(0, 96));
        column.setVSizeFlags(.{ .size_fill = true, .size_expand = true });
        column.addChild(.upcast(rt), .{});

        const obj = Object.upcast(dock);
        connect(Object.upcast(self.button), "pressed", obj, "build_pressed");
        connect(Object.upcast(rt), "meta_clicked", obj, "on_meta_clicked");
        connect(Object.upcast(self.download_cancel), "pressed", obj, "download_cancel_pressed");
    }

    /// Bound as `download_cancel_pressed` (the download row's Cancel).
    pub fn downloadCancelPressed(_: *ZigPanel) void {
        zig_download.cancel();
    }

    /// Bound as `build_pressed` (the Build button).
    pub fn buildPressed(_: *ZigPanel) void {
        editor_build.requestBuild(.manual);
    }

    /// Bound as `on_meta_clicked` (the diagnostics' `meta_clicked`): opens
    /// the script a link `res://<path>[:<line>[:<column>]]` names there.
    pub fn onMetaClicked(_: *ZigPanel, meta: String) void {
        var buf: [max_line_bytes]u8 = undefined;
        const text = props.stringText(&meta, &buf) orelse return;
        const link = parseLink(text) orelse return;
        openAt(link);
    }

    /// Shows the outcome `st.last` and the diagnostics `files` (from
    /// `editor_build.diagnosticsCopy`). Main thread.
    pub fn update(self: *ZigPanel, st: editor_build.Status, files: []const editor_build.FileDiagnostics) void {
        self.setBuilding(st.building);
        var buf: [256]u8 = undefined;
        const line = if (st.last) |l| statusLine(&buf, l, st.good_n) else "No build yet";
        setText(Label, self.status, "setText", line);
        var memory_buf: [256]u8 = undefined;
        self.setMemory(editor_build.memoryText(&memory_buf));

        const rt = self.diagnostics;
        rt.clear();
        if (st.last) |l| if (l.message) |m| if (!l.ok) {
            addText(rt, m);
            rt.newline();
        };
        for (files) |f| for (f.items) |d| {
            if (f.rel.len == 0) {
                addText(rt, d.message);
            } else {
                var link_buf: [max_line_bytes]u8 = undefined;
                const link = linkText(&link_buf, f.rel, d.line, d.column);
                var meta = props.gstring(link);
                defer meta.deinit();
                const v = Variant.init(String, meta);
                defer v.deinit();
                rt.pushMeta(v, .{});
                addText(rt, link);
                rt.pop();
                addText(rt, ": ");
                addText(rt, d.message);
            }
            rt.newline();
        };
    }

    /// The Build button while a build runs (or waits to be applied).
    pub fn setBuilding(self: *ZigPanel, building: bool) void {
        setText(Button, self.button, "setText", if (building) "Building..." else "Build");
        self.button.setDisabled(building);
    }

    /// The memory line (filled by the loaded-size accounting); hidden
    /// while `text` is empty.
    pub fn setMemory(self: *ZigPanel, text: []const u8) void {
        setText(Label, self.memory, "setText", text);
        self.memory.setVisible(text.len != 0);
    }

    /// The download row (filled by the Zig download): hidden in state
    /// `hidden`, otherwise it shows `text`; Cancel only while `downloading`.
    pub fn showDownload(self: *ZigPanel, state: DownloadState, text: []const u8) void {
        setText(Label, self.download_text, "setText", text);
        self.download_row.setVisible(state != .hidden);
        self.download_cancel.setVisible(state == .downloading);
    }

    /// Brings the dock to the front (for example after a failed build).
    pub fn makeVisible(self: *ZigPanel) void {
        self.base.makeVisible();
    }
};

/// What the download row shows (`showDownload`).
pub const DownloadState = enum { hidden, idle, downloading, checking, installed, failed };

fn connect(source: *Object, comptime signal: [:0]const u8, target: *Object, comptime method: [:0]const u8) void {
    var c = host_callable.callable(target, method);
    defer c.deinit();
    _ = source.connectRaw(.fromComptimeLatin1(signal), c, .{});
}

/// Calls the String setter `method` of `obj` with `text` (UTF-8).
fn setText(comptime T: type, obj: *T, comptime method: []const u8, text: []const u8) void {
    var s = props.gstring(text);
    defer s.deinit();
    @field(T, method)(obj, s);
}

fn addText(rt: *RichTextLabel, text: []const u8) void {
    var s = props.gstring(text);
    defer s.deinit();
    rt.addText(s);
}

fn openAt(link: Link) void {
    var path = props.gstring(link.path);
    defer path.deinit();
    const res = ResourceLoader.load(path, .{}) orelse {
        log("Ziggurat cannot open {s}: it does not load.", .{link.path});
        return;
    };
    // `load` returns a reference for the caller.
    defer editor_build.releaseRef(res);
    const script = Script.downcast(res) orelse {
        log("Ziggurat cannot open {s}: it is not a script.", .{link.path});
        return;
    };
    EditorInterface.editScript(script, .{ .line = link.line, .column = link.column });
}

// ------------------------------------------------------------ toasts

pub const Toast = struct {
    severity: enum { warning, @"error" },
    text: []const u8,
    /// The outcome's own sentence, or "".
    tooltip: []const u8 = "",
};

/// The toast a newly applied outcome gets, or null: an error toast with the
/// download hint when no usable Zig was found, otherwise a warning toast
/// when a build failed while an earlier one is in use. The text has no
/// times in it, so the same failure again reuses the toast Godot shows.
pub fn toastFor(buf: []u8, last: editor_build.Last, good_n: ?u32) ?Toast {
    if (last.ok) return null;
    const hint = " Use Project > Tools > Download Zig 0.17.0, or set " ++ editor_build.setting_zig_path ++ ".";
    const tooltip = last.message orelse "";
    switch (last.zig_problem) {
        .none => {},
        .missing => return .{ .severity = .@"error", .text = "Ziggurat found no usable Zig 0.17.0." ++ hint, .tooltip = tooltip },
        .wrong_version => return .{ .severity = .@"error", .text = "The Zig that Ziggurat found is not version 0.17.0." ++ hint, .tooltip = tooltip },
        .no_answer => return .{ .severity = .@"error", .text = "The Zig that Ziggurat found does not answer." ++ hint, .tooltip = tooltip },
    }
    const n = good_n orelse return null;
    const text = std.fmt.bufPrint(buf, "Zig build failed: {d} errors, {d} warnings; build {d} stays in use. See the Zig panel.", .{ last.error_count, last.warning_count, n }) catch return null;
    return .{ .severity = .warning, .text = text, .tooltip = tooltip };
}

/// Shows `t` with the editor's toaster. Main thread.
pub fn pushToast(t: Toast) void {
    if (host_options.test_probe) noteToast(t);
    const toaster = EditorInterface.getEditorToaster() orelse return;
    var text = props.gstring(t.text);
    defer text.deinit();
    var tooltip = props.gstring(t.tooltip);
    defer tooltip.deinit();
    toaster.pushToast(text, .{
        .severity = switch (t.severity) {
            .warning => .severity_warning,
            .@"error" => .severity_error,
        },
        .tooltip = tooltip,
    });
}

/// TEST ONLY (probe `editor_panel_toasts`): the toasts pushed so far, as
/// `<severity>: <text>`, oldest first; the first `toast_log.len` are kept.
pub var toast_log: [32][320]u8 = undefined;
pub var toast_log_len: [32]usize = undefined;
pub var toast_count: usize = 0;

fn noteToast(t: Toast) void {
    if (toast_count >= toast_log.len) return;
    const s = std.fmt.bufPrint(&toast_log[toast_count], "{t}: {s}", .{ t.severity, t.text }) catch toast_log[toast_count][0..];
    toast_log_len[toast_count] = s.len;
    toast_count += 1;
}

// ------------------------------------------------------------ text

/// The status line of `last`; `good_n` is the build in use.
pub fn statusLine(buf: []u8, last: editor_build.Last, good_n: ?u32) []const u8 {
    if (last.ok) {
        if (last.n) |n| return std.fmt.bufPrint(buf, "Build {d} ok ({t}, {t}, {d} ms)", .{ n, last.trigger, last.path, last.ms }) catch "";
        // A project without Zig scripts.
        if (last.warning_count == 0) return "No Zig scripts; nothing to build";
        return std.fmt.bufPrint(buf, "No Zig scripts; nothing to build ({d} warnings)", .{last.warning_count}) catch "";
    }
    if (good_n) |n|
        return std.fmt.bufPrint(buf, "Build failed: {d} errors, {d} warnings ({d} ms); build {d} stays in use", .{ last.error_count, last.warning_count, last.ms, n }) catch "";
    return std.fmt.bufPrint(buf, "Build failed: {d} errors, {d} warnings ({d} ms); no build is in use", .{ last.error_count, last.warning_count, last.ms }) catch "";
}

/// `res://<rel>:<line>:<column>`, or `res://<rel>` without a line.
pub fn linkText(buf: []u8, rel: []const u8, line: u32, column: u32) []const u8 {
    const r = if (line == 0)
        std.fmt.bufPrint(buf, "res://{s}", .{rel})
    else
        std.fmt.bufPrint(buf, "res://{s}:{d}:{d}", .{ rel, line, column });
    return r catch "";
}

pub const Link = struct {
    path: []const u8,
    /// 1-based, or -1 for none (`edit_script`'s default).
    line: i32 = -1,
    /// 1-based, or 0 for none.
    column: i32 = 0,
};

/// Splits a link `linkText` made. Null when `text` is not a `res://` path.
pub fn parseLink(text: []const u8) ?Link {
    if (!std.mem.startsWith(u8, text, "res://") or text.len <= "res://".len) return null;
    var link: Link = .{ .path = text };
    const last = trailingNumber(link.path) orelse return link;
    const before = trailingNumber(last.rest);
    if (before) |b| {
        link = .{ .path = b.rest, .line = b.value, .column = last.value };
    } else {
        link = .{ .path = last.rest, .line = last.value };
    }
    if (link.path.len <= "res://".len) return null;
    if (link.line < 1) link.line = -1;
    if (link.column < 1) link.column = 0;
    return link;
}

const Trailing = struct { rest: []const u8, value: i32 };

/// `<rest>:<digits>` at the end of `text`, or null.
fn trailingNumber(text: []const u8) ?Trailing {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const digits = text[colon + 1 ..];
    if (digits.len == 0 or colon < "res:".len) return null;
    const value = std.fmt.parseInt(i32, digits, 10) catch return null;
    return .{ .rest = text[0..colon], .value = value };
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_line_bytes]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s = props.gstring(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

test "status line" {
    var buf: [256]u8 = undefined;
    const ok: editor_build.Last = .{ .n = 4, .ok = true, .trigger = .open, .path = .full, .ms = 812, .message = null, .error_count = 0, .warning_count = 0, .zig_problem = .none };
    try std.testing.expectEqualStrings("Build 4 ok (open, full, 812 ms)", statusLine(&buf, ok, 4));
    var failed = ok;
    failed.ok = false;
    failed.n = null;
    failed.error_count = 2;
    failed.warning_count = 1;
    failed.ms = 90;
    try std.testing.expectEqualStrings("Build failed: 2 errors, 1 warnings (90 ms); build 4 stays in use", statusLine(&buf, failed, 4));
    try std.testing.expectEqualStrings("Build failed: 2 errors, 1 warnings (90 ms); no build is in use", statusLine(&buf, failed, null));
    // A project without Zig scripts: a good build with nothing built.
    var empty = ok;
    empty.n = null;
    try std.testing.expectEqualStrings("No Zig scripts; nothing to build", statusLine(&buf, empty, null));
    empty.warning_count = 2;
    try std.testing.expectEqualStrings("No Zig scripts; nothing to build (2 warnings)", statusLine(&buf, empty, 4));
    try std.testing.expect(toastFor(&buf, empty, null) == null);
}

test "toasts" {
    var buf: [256]u8 = undefined;
    var last: editor_build.Last = .{ .n = null, .ok = false, .trigger = .save, .path = .full, .ms = 5, .message = null, .error_count = 1, .warning_count = 0, .zig_problem = .none };
    // No build in use yet: no warning toast.
    try std.testing.expect(toastFor(&buf, last, null) == null);
    const w = toastFor(&buf, last, 3).?;
    try std.testing.expect(w.severity == .warning);
    try std.testing.expectEqualStrings("Zig build failed: 1 errors, 0 warnings; build 3 stays in use. See the Zig panel.", w.text);
    last.zig_problem = .missing;
    last.message = "Ziggurat needs Zig 0.17.0, but no zig was found.";
    const e = toastFor(&buf, last, null).?;
    try std.testing.expect(e.severity == .@"error");
    try std.testing.expect(std.mem.indexOf(u8, e.text, "Download Zig 0.17.0") != null);
    try std.testing.expectEqualStrings(last.message.?, e.tooltip);
    last.ok = true;
    last.zig_problem = .none;
    try std.testing.expect(toastFor(&buf, last, 3) == null);
}

test "links" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("res://a/b.zig:3:28", linkText(&buf, "a/b.zig", 3, 28));
    try std.testing.expectEqualStrings("res://a/b.zig", linkText(&buf, "a/b.zig", 0, 0));
    const l = parseLink("res://a/b.zig:3:28").?;
    try std.testing.expectEqualStrings("res://a/b.zig", l.path);
    try std.testing.expectEqual(@as(i32, 3), l.line);
    try std.testing.expectEqual(@as(i32, 28), l.column);
    const no_line = parseLink("res://a/b.zig").?;
    try std.testing.expectEqualStrings("res://a/b.zig", no_line.path);
    try std.testing.expectEqual(@as(i32, -1), no_line.line);
    const line_only = parseLink("res://x.zig:7").?;
    try std.testing.expectEqualStrings("res://x.zig", line_only.path);
    try std.testing.expectEqual(@as(i32, 7), line_only.line);
    try std.testing.expectEqual(@as(i32, 0), line_only.column);
    try std.testing.expect(parseLink("https://example.org") == null);
    try std.testing.expect(parseLink("res://") == null);
    try std.testing.expect(parseLink("res://:3:4") == null);
}
