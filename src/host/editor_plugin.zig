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
//! Today the plugin registers the editor setting `ziggurat/zig_path` (the
//! per-user Zig path, with a file picker) when it enters the tree, and
//! then lets the build at open start if it waited for that setting
//! (`editor_build.editorReady`). The panel, Play and the download build on
//! it (editor_build.zig has the build API they use).
const std = @import("std");
const godot = @import("gdzig");
const host_options = @import("host_options");
const editor_build = @import("editor_build.zig");

const Allocator = std.mem.Allocator;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const EditorPlugin = godot.class.EditorPlugin;

pub const ZigEditorPlugin = struct {
    base: *EditorPlugin,

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

    pub fn _enterTree(_: *ZigEditorPlugin) void {
        editor_build.editorReady();
    }

    pub fn _exitTree(_: *ZigEditorPlugin) void {}

    /// TEST ONLY (bound as `test_ping` in probe builds): counts its calls,
    /// so a host test can check that a Callable made in Zig reaches a
    /// method bound on this class.
    pub fn testPing(_: *ZigEditorPlugin) void {
        test_pings += 1;
    }
};

/// Calls of `test_ping`. Main thread.
pub var test_pings: i64 = 0;

/// Adds the class registry entry: EDITOR level, not exposed (Godot creates
/// the plugin itself; scripts and the Create Node dialog have no use for
/// it). `test_ping` is bound only in probe builds.
pub fn register(registry: *godot.extension.Registry) void {
    comptime std.debug.assert(!host_options.export_build);
    const cls = registry.createClass(ZigEditorPlugin, registry.allocator, .{ .level = .editor, .is_exposed = false });
    if (host_options.test_probe) cls.addMethod("test_ping", .auto);
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
