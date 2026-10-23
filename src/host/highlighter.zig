//! `ZigHighlighter`: colours Zig in the script editor (spec section 9).
//! The colours of a line come from `highlight.zig` (std only); this file is
//! the Godot side.
//!
//! The class is an `EditorSyntaxHighlighter` (a RefCounted), registered at
//! the EDITOR level like the editor plugin and never exposed. Its name is
//! `Zig` and it supports the language `Zig` (`ZigLanguage._get_name`), so
//! the script editor makes it the current highlighter of every Zig tab.
//! `ZigEditorPlugin._enterTree` makes one and hands it to the script
//! editor (`attach`, `ScriptEditor.register_syntax_highlighter`; the
//! script editor does not exist yet at EDITOR init); `_exitTree` takes it
//! back (`detach`). For each tab the script editor calls `_create`, which
//! makes a new `ZigHighlighter`: without that override Godot would give
//! each tab a plain `EditorSyntaxHighlighter`.
//!
//! `_update_cache` (Godot calls it when the highlighter is given a text
//! editor) reads the colours from the editor settings
//! `text_editor/theme/highlighting/*`. `_get_line_syntax_highlighting`
//! returns `{column: {"color": Color}}`, where a region runs to the next
//! column key; Godot keeps the result per line until the line changes.
//! All of it runs on the main thread. An export build has none of this.
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const highlight = @import("highlight.zig");
const editor_build = @import("editor_build.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const Color = godot.builtin.Color;
const Dictionary = godot.builtin.Dictionary;
const PackedStringArray = godot.builtin.PackedStringArray;
const Variant = godot.builtin.Variant;
const EditorSyntaxHighlighter = godot.class.EditorSyntaxHighlighter;
const EditorInterface = godot.class.EditorInterface;
const Engine = godot.class.Engine;

/// The colour of every kind until `_update_cache` read the settings.
const fallback_color: Color = .{ .r = 0.8, .g = 0.8, .b = 0.8, .a = 1 };

pub const ZigHighlighter = struct {
    base: *EditorSyntaxHighlighter,
    /// One colour per `highlight.Kind`.
    colors: std.EnumArray(highlight.Kind, Color) = .initFill(fallback_color),

    pub fn create(allocator: *Allocator) !*ZigHighlighter {
        const self = try allocator.create(ZigHighlighter);
        self.* = .{ .base = EditorSyntaxHighlighter.init() };
        self.base.setInstance(ZigHighlighter, self);
        return self;
    }

    /// Called by gdzig's free callback when Godot frees the object (the
    /// last reference dropped); `base.destroy` then does nothing more.
    pub fn destroy(self: *ZigHighlighter, allocator: *Allocator) void {
        self.base.destroy();
        allocator.destroy(self);
    }

    pub fn _getName(_: *ZigHighlighter) String {
        return .fromLatin1("Zig");
    }

    pub fn _getSupportedLanguages(_: *ZigHighlighter) PackedStringArray {
        var a: PackedStringArray = .init();
        var s: String = .fromLatin1("Zig");
        defer s.deinit();
        _ = a.pushBack(s);
        return a;
    }

    /// A new highlighter for one script editor tab. `init` gave it one
    /// counted reference, which goes to the `Ref` Godot reads the pointer
    /// into. Null (Godot skips it) when out of memory.
    pub fn _create(_: *ZigHighlighter) ?*EditorSyntaxHighlighter {
        var alloc = godot.engine_allocator;
        const h = ZigHighlighter.create(&alloc) catch return null;
        return h.base;
    }

    /// Reads the colours from the editor settings; a missing setting, or
    /// one that is not a colour, keeps the colour it had.
    pub fn _updateCache(self: *ZigHighlighter) void {
        if (!Engine.hasSingleton(.fromComptimeLatin1("EditorInterface"))) return;
        const es = EditorInterface.getEditorSettings() orelse return;
        // `get_editor_settings` returns a Ref: the reference is the caller's.
        defer editor_build.releaseRef(es);
        for (std.meta.tags(highlight.Kind)) |kind| {
            var n = String.fromLatin1(highlight.settingName(kind));
            defer n.deinit();
            if (!es.hasSetting(n)) continue;
            const v = es.getSetting(n);
            defer v.deinit();
            self.colors.set(kind, v.as(Color) orelse continue);
        }
    }

    /// The colours of line `line` of the text editor, as
    /// `{column: {"color": Color}}`. Empty without a text editor or for a
    /// line number out of range.
    pub fn _getLineSyntaxHighlighting(self: *ZigHighlighter, line: i64) Dictionary {
        var d: Dictionary = .init();
        const te = self.base.getTextEdit() orelse return d;
        if (line < 0 or line >= te.getLineCount()) return d;
        var s = te.getLineWithIme(@intCast(line));
        defer s.deinit();
        const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(s.constPtr(), null, 0)));
        var small: [1024]u8 = undefined;
        const a = std.heap.c_allocator;
        const heap = n >= small.len;
        const buf: []u8 = if (heap) a.alloc(u8, n + 1) catch return d else small[0 .. n + 1];
        defer if (heap) a.free(buf);
        if (n != 0) _ = godot.raw.stringToUtf8Chars(s.constPtr(), buf.ptr, @intCast(n));
        buf[n] = 0;
        var out: [highlight.max_regions]highlight.Region = undefined;
        for (highlight.lineZ(buf[0..n :0], &out)) |r| {
            self.putRegion(&d, r);
        }
        return d;
    }

    fn putRegion(self: *ZigHighlighter, d: *Dictionary, r: highlight.Region) void {
        var inner: Dictionary = .init();
        defer inner.deinit();
        var key: String = .fromLatin1("color");
        defer key.deinit();
        const kv = Variant.init(String, key);
        defer kv.deinit();
        const cv = Variant.init(Color, self.colors.get(r.kind));
        defer cv.deinit();
        _ = inner.set(kv, cv);
        const col = Variant.init(i64, r.column);
        defer col.deinit();
        const iv = Variant.init(Dictionary, inner);
        defer iv.deinit();
        _ = d.set(col, iv);
    }
};

/// The highlighter given to the script editor while the editor plugin is
/// in the tree; this module holds one counted reference to it. Main thread.
var current: ?*ZigHighlighter = null;

/// Makes the highlighter and gives it to the script editor
/// (`ZigEditorPlugin._enterTree`). Main thread.
pub fn attach() void {
    comptime std.debug.assert(!host_options.export_build);
    if (current != null) return;
    const se = EditorInterface.getScriptEditor() orelse return;
    var alloc = godot.engine_allocator;
    const h = ZigHighlighter.create(&alloc) catch {
        log("Ziggurat cannot colour Zig scripts: out of memory.");
        return;
    };
    // `init` gave this module one counted reference; the script editor
    // takes its own.
    se.registerSyntaxHighlighter(h.base);
    current = h;
}

/// Takes the highlighter back from the script editor and drops this
/// module's reference (`ZigEditorPlugin._exitTree`). Tabs keep the copies
/// `_create` made until they close. Main thread.
pub fn detach() void {
    comptime std.debug.assert(!host_options.export_build);
    const h = current orelse return;
    current = null;
    if (EditorInterface.getScriptEditor()) |se| se.unregisterSyntaxHighlighter(h.base);
    editor_build.releaseRef(h.base);
}

/// Adds the class registry entry: EDITOR level, not exposed (only this
/// file creates it).
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    _ = registry.createClass(ZigHighlighter, registry.allocator, .{ .level = .editor, .is_exposed = false });
}

fn log(comptime msg: []const u8) void {
    var s = String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}
