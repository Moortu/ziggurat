//! `ZigScript`: the `Script` of one `.zig` file (spec section 7).
//!
//! A ZigScript holds the file's text (for the script editor) and answers
//! every script-level question Godot and the editor ask from the script's
//! descriptor. The descriptor is found by the script's project-relative path
//! (its resource path without `res://`), in this order:
//! 1. once a module generation is loaded (`runtime.current`), that
//!    generation alone: a script it does not have has no descriptor (it was
//!    deleted or renamed), whatever the cache says;
//! 2. before the first load, the descriptor cache the language read at
//!    startup (`.godot/ziggurat/descriptors.json`, `loadStartupCache`), so
//!    the Inspector works before the first build of the session is done;
//! 3. none: the script is not valid, has empty lists and lets Godot keep
//!    scene values with placeholder fallback.
//! Nothing is copied: every answer is read from the descriptor in use, so a
//! new generation changes the answers at once. `_update_exports` compares
//! the descriptor generation (`DescKey`) with the one the script's
//! placeholders were fed last (`placeholder.zig`).
//!
//! Placeholders: in the editor a script that is not a tool script gets a
//! placeholder instance (`_placeholder_instance_create`), fed with the
//! property list and defaults. Placeholder fallback is on while the script
//! has no descriptors or its last build failed (`setBuildFailed`); Godot
//! then stores every scene value in the placeholder as it is, and nothing
//! feeds the placeholders.
//!
//! The code that runs is the module generation, never the text this object
//! holds.
//!
//! Threads: Godot calls these virtuals on the main thread and, while loading
//! resources, on loader threads. Generations are never freed and the
//! startup cache is freed only at SCENE exit, so the descriptor data read
//! here stays valid.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");
const snake = @import("snake");
const runtime = @import("runtime.zig");
const props = @import("props.zig");
const desc_cache = @import("desc_cache.zig");
const default_value = @import("default_value.zig");
const host_io = @import("host_io.zig");
const language = @import("language.zig");
const instance = @import("instance.zig");
const placeholder = @import("placeholder.zig");
const global_class = @import("global_class.zig");
const diag_cache = @import("diag_cache.zig");

const Allocator = std.mem.Allocator;
const Array = godot.builtin.Array;
const Dictionary = godot.builtin.Dictionary;
const String = godot.builtin.String;
const StringName = godot.builtin.StringName;
const Variant = godot.builtin.Variant;
const Object = godot.class.Object;
const FileAccess = godot.class.FileAccess;
const Script = godot.class.Script;
const ScriptExtension = godot.class.ScriptExtension;
const ScriptLanguage = godot.class.ScriptLanguage;
const RefCounted = godot.class.RefCounted;
const Error = godot.global.Error;

/// Godot's `PROPERTY_USAGE_GROUP`, `_CATEGORY` and `_SUBGROUP`
/// (core/object/property_info.h): entries that only label the Inspector.
const usage_label: u32 = 64 | 128 | 256;

/// Longest resource path and member name handled; longer ones have no
/// descriptor.
const max_path_bytes = 4096;
const max_name_bytes = 1024;

// ------------------------------------------------------------ module state

/// The descriptor cache read when the language started, or null. Written on
/// the main thread by `loadStartupCache` (language `_init`, before any
/// scene loads) and `dropStartupCache` (SCENE exit).
var startup_cache: ?desc_cache.Cache = null;

/// `Engine.is_editor_hint()`, read once at SCENE init (`setEditorHint`).
/// Godot sets the hint for the editor in `Main::setup` (main/main.cpp:2223),
/// before extensions reach SCENE init (main/main.cpp:3793). The project
/// manager and the doc tool set it later, but neither runs project scripts.
var editor_hint: std.atomic.Value(bool) = .init(false);

pub fn setEditorHint(on: bool) void {
    editor_hint.store(on, .release);
}

/// True in the editor, false in a game process (`setEditorHint`).
pub fn isEditor() bool {
    return editor_hint.load(.acquire);
}

/// Reads the project's descriptor cache once. A missing file is silent; a
/// bad one was logged by `desc_cache.read`. Main thread.
pub fn loadStartupCache() void {
    if (startup_cache != null) return;
    var buf: [max_path_bytes]u8 = undefined;
    const path = desc_cache.projectPath(&buf) orelse return;
    startup_cache = desc_cache.read(std.heap.c_allocator, host_io.get(), .fromTrusted(path)) catch |err| switch (err) {
        error.FileNotFound, error.Rejected => null,
        error.OutOfMemory => blk: {
            log("Ziggurat could not read the descriptor cache: out of memory.", .{});
            break :blk null;
        },
    };
}

/// Frees the startup cache. Main thread, at SCENE exit.
pub fn dropStartupCache() void {
    if (startup_cache) |*c| c.deinit();
    startup_cache = null;
}

// ------------------------------------------------------------ live scripts

/// Every `ZigScript` that exists, so a build can update each one
/// (`liveScripts`). Scripts are created and freed on any thread (resource
/// loads run on worker threads), so a mutex guards the list.
var live_mu: std.Io.Mutex = .init;
var live: std.ArrayList(*ZigScript) = .empty;

fn track(s: *ZigScript) void {
    live_mu.lockUncancelable(host_io.get());
    defer live_mu.unlock(host_io.get());
    // Out of memory, the script is still usable; builds just do not
    // update it.
    live.append(std.heap.c_allocator, s) catch {};
}

fn untrack(s: *ZigScript) void {
    live_mu.lockUncancelable(host_io.get());
    defer live_mu.unlock(host_io.get());
    const i = std.mem.indexOfScalar(*ZigScript, live.items, s) orelse return;
    _ = live.swapRemove(i);
}

/// Every live script, each with a counted reference taken under the lock,
/// so none is freed while the caller uses it. A script whose last
/// reference is already gone (being freed on another thread) is left out.
/// Drop each reference with `release`, then free the slice with `a`.
pub fn liveScripts(a: Allocator) Allocator.Error![]*ZigScript {
    live_mu.lockUncancelable(host_io.get());
    defer live_mu.unlock(host_io.get());
    var out: std.ArrayList(*ZigScript) = try .initCapacity(a, live.items.len);
    for (live.items) |s| {
        if (RefCounted.upcast(s.base).reference()) out.appendAssumeCapacity(s);
    }
    return out.toOwnedSlice(a);
}

/// Drops a reference from `liveScripts`; frees the script when it was the
/// last one.
pub fn release(s: *ZigScript) void {
    if (RefCounted.upcast(s.base).unreference()) godot.raw.objectDestroy(@ptrCast(s.base));
}

// ------------------------------------------------------------ descriptors

/// Which descriptors a script uses: their source and generation number.
/// Cache and module numbers are separate spaces (a cache written by
/// generation 1 of an earlier session is not generation 1 of this one).
pub const DescKey = struct {
    source: enum { none, cached, loaded } = .none,
    n: u32 = 0,

    pub fn eql(a: DescKey, b: DescKey) bool {
        return a.source == b.source and a.n == b.n;
    }
};

/// The descriptor of one script, from a loaded generation or the cache.
const Desc = union(enum) {
    loaded: struct { gen: *runtime.Generation, index: u32 },
    cached: struct { script: *const desc_cache.Script, n: u32 },

    fn key(d: Desc) DescKey {
        return switch (d) {
            .loaded => |l| .{ .source = .loaded, .n = l.gen.n },
            .cached => |c| .{ .source = .cached, .n = c.n },
        };
    }

    fn abiDesc(d: Desc) ?*const abi.ScriptDesc {
        return switch (d) {
            .loaded => |l| &l.gen.scripts()[l.index],
            .cached => null,
        };
    }

    /// The name maps; null for the cache or after `runtime.shutdown`.
    fn names(d: Desc) ?*const runtime.ScriptNames {
        const l = switch (d) {
            .loaded => |l| l,
            .cached => return null,
        };
        if (l.index >= l.gen.names.len) return null;
        return &l.gen.names[l.index];
    }

    fn flags(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.flags,
            .cached => |c| c.script.flags.v,
        };
    }

    fn className(d: Desc) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.class_name),
            .cached => |c| c.script.class_name,
        };
    }

    fn baseClass(d: Desc) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.base_class),
            .cached => |c| c.script.base_class,
        };
    }

    fn propertyCount(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.property_count,
            .cached => |c| @intCast(c.script.properties.len),
        };
    }

    /// Name of property entry `i` and whether it is a label (a group).
    fn property(d: Desc, i: u32) struct { name: []const u8, label: bool } {
        return switch (d) {
            .loaded => blk: {
                const p = d.abiDesc().?.properties[i];
                break :blk .{ .name = props.text(p.name), .label = p.field_index == abi.no_field };
            },
            .cached => |c| .{ .name = c.script.properties[i].name, .label = c.script.properties[i].usage.v & usage_label != 0 },
        };
    }

    fn methodCount(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.method_count,
            .cached => |c| @intCast(c.script.methods.len),
        };
    }

    fn methodName(d: Desc, i: u32) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.methods[i].name),
            .cached => |c| c.script.methods[i].name,
        };
    }

    fn signalCount(d: Desc) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.signal_count,
            .cached => |c| @intCast(c.script.signals.len),
        };
    }

    fn signalName(d: Desc, i: u32) []const u8 {
        return switch (d) {
            .loaded => props.text(d.abiDesc().?.signals[i].name),
            .cached => |c| c.script.signals[i].name,
        };
    }

    /// The index of the method named `sn`.
    fn methodIndex(d: Desc, sn: StringName) ?u32 {
        if (d.names()) |m| return m.method(sn);
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(sn, &buf) orelse return null;
        for (0..d.methodCount()) |i| {
            if (std.mem.eql(u8, d.methodName(@intCast(i)), name)) return @intCast(i);
        }
        return null;
    }

    /// The property entry index of the exported property named `sn` (group
    /// entries are never found).
    fn propertyIndex(d: Desc, sn: StringName) ?u32 {
        if (d.names()) |m| return m.property(sn);
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(sn, &buf) orelse return null;
        for (0..d.propertyCount()) |i| {
            const p = d.property(@intCast(i));
            if (!p.label and std.mem.eql(u8, p.name, name)) return @intCast(i);
        }
        return null;
    }

    fn hasSignal(d: Desc, sn: StringName) bool {
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(sn, &buf) orelse return false;
        for (0..d.signalCount()) |i| {
            if (std.mem.eql(u8, d.signalName(@intCast(i)), name)) return true;
        }
        return false;
    }

    /// Whether property entry `i` has a default, by one rule for both
    /// sources: the default exists and has a stored form in the descriptor
    /// cache (`default_value`), so it survives the cache round trip. A
    /// module default the cache would drop (a string over
    /// `default_value.max_text_bytes`, a non-finite vector) has none, as it
    /// has none when read back from the cache. Calls the module's
    /// `get_default` for a loaded descriptor.
    fn hasDefault(d: Desc, i: u32) bool {
        switch (d) {
            .loaded => {
                const desc = d.abiDesc().?;
                const v = props.defaultValue(desc, i) orelse return false;
                defer v.deinit();
                var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
                defer arena.deinit();
                const stored = default_value.fromVariant(arena.allocator(), desc.properties[i].variant_type, v) catch return false;
                return stored != .absent and default_value.fits(desc.properties[i].variant_type, stored);
            },
            // `desc_cache.parse` already dropped defaults that do not fit.
            .cached => |c| return c.script.properties[i].default != .absent,
        }
    }

    /// The argument count of method `i`.
    fn methodArgCount(d: Desc, i: u32) u32 {
        return switch (d) {
            .loaded => d.abiDesc().?.methods[i].arg_count,
            .cached => |c| @intCast(c.script.methods[i].args.len),
        };
    }

    /// The default value of property entry `i`; the caller owns it.
    fn defaultValue(d: Desc, i: u32) ?Variant {
        return switch (d) {
            .loaded => props.defaultValue(d.abiDesc().?, i),
            .cached => |c| c.script.defaultValue(i),
        };
    }

    fn propertyList(d: Desc) Array {
        return switch (d) {
            .loaded => props.propertyList(d.abiDesc().?),
            .cached => |c| c.script.propertyList(),
        };
    }

    fn methodList(d: Desc) Array {
        return switch (d) {
            .loaded => props.methodList(d.abiDesc().?),
            .cached => |c| c.script.methodList(),
        };
    }

    fn signalList(d: Desc) Array {
        return switch (d) {
            .loaded => props.signalList(d.abiDesc().?),
            .cached => |c| c.script.signalList(),
        };
    }

    fn methodInfo(d: Desc, i: u32) Dictionary {
        return switch (d) {
            .loaded => props.methodInfo(d.abiDesc().?, i),
            .cached => |c| c.script.methodInfo(i),
        };
    }
};

/// Makes what placeholders are fed from a descriptor: its property list and
/// a default per exported property (`Desc.defaultValue`). Without a
/// descriptor, empty data.
const Feed = struct {
    d: ?Desc,

    pub fn make(f: Feed) placeholder.Data {
        var values = Dictionary.init();
        const d = f.d orelse return .{ .properties = .init(), .values = values };
        for (0..d.propertyCount()) |i| {
            const p = d.property(@intCast(i));
            if (p.label) continue;
            const v = d.defaultValue(@intCast(i)) orelse continue;
            defer v.deinit();
            var sn = StringName.fromUtf8(p.name);
            defer sn.deinit();
            const k = Variant.init(StringName, sn);
            defer k.deinit();
            _ = values.set(k, v);
        }
        return .{ .properties = d.propertyList(), .values = values };
    }
};

/// The descriptor of the script at project-relative path `rel`. Once a
/// generation is loaded the cache is never asked (no stale validity for a
/// script the module no longer has).
fn findDesc(rel: []const u8) ?Desc {
    if (runtime.current()) |gen| {
        const i = runtime.findScript(gen, rel) orelse return null;
        return .{ .loaded = .{ .gen = gen, .index = i } };
    }
    if (startup_cache) |*c| {
        if (c.find(rel)) |s| return .{ .cached = .{ .script = s, .n = c.generation() } };
    }
    return null;
}

const stringText = props.stringText;
const nameText = props.nameText;

/// The project-relative path of a `res://` resource path, normalised into
/// `buf` like Godot's `String::simplify_path` (core/string/ustring.cpp:4149):
/// a backslash becomes `/`, empty and `.` segments are dropped and `..` removes the
/// segment before it. Null for any other path (an unsaved script has none),
/// for a `..` that would leave the project, for an empty result and when
/// `buf` is too small. Paths set by the resource loader are already
/// simplified; paths set directly (`resource_path`, `take_over_path`) may
/// not be. The result is compared byte for byte with the table's paths:
/// Godot resource paths are case-sensitive, so `res://Player.zig` is not
/// `res://player.zig`.
pub fn relPath(res_path: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "res://";
    if (!std.mem.startsWith(u8, res_path, prefix)) return null;
    var len: usize = 0;
    var it = std.mem.tokenizeAny(u8, res_path[prefix.len..], "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (len == 0) return null;
            len = if (std.mem.lastIndexOfScalar(u8, buf[0..len], '/')) |slash| slash else 0;
            continue;
        }
        const sep: usize = if (len == 0) 0 else 1;
        if (len + sep + seg.len > buf.len) return null;
        if (sep == 1) buf[len] = '/';
        @memcpy(buf[len + sep ..][0..seg.len], seg);
        len += sep + seg.len;
    }
    if (len == 0) return null;
    return buf[0..len];
}

// ------------------------------------------------------------ member lines

/// 1-based number of the first top-level (unindented) line of `text` that
/// declares the Godot member `name`, or null. The rule of the SDK marker
/// lookup (src/build/diagnostics.zig, `markerLine`), with Godot names: after
/// an optional `pub `, a field `<name>:`, a `const <name>` or `var <name>`,
/// or a `fn` whose `snake.toSnakeCaseBuf` name is `name` (the SDK names
/// methods that way). Members renamed with `meta` and signals (declared
/// inside `signals`) have no line of their own.
pub fn memberLine(text: []const u8, name: []const u8) ?u32 {
    if (name.len == 0) return null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 1;
    while (it.next()) |raw| : (n +|= 1) {
        var l = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, l, "pub ")) l = l["pub ".len..];
        if (std.mem.startsWith(u8, l, "fn ")) {
            const id = ident(l["fn ".len..]);
            if (std.mem.eql(u8, id, name)) return n;
            var buf: [2 * max_name_bytes]u8 = undefined;
            if (id.len <= max_name_bytes) {
                const snake_id = snake.toSnakeCaseBuf(&buf, id) catch continue;
                if (std.mem.eql(u8, snake_id, name)) return n;
            }
            continue;
        }
        const rest = if (std.mem.startsWith(u8, l, "const "))
            l["const ".len..]
        else if (std.mem.startsWith(u8, l, "var "))
            l["var ".len..]
        else blk: {
            // A field: the identifier is followed by `:`.
            const id = ident(l);
            if (id.len == 0 or !std.mem.startsWith(u8, std.mem.trimStart(u8, l[id.len..], " "), ":")) continue;
            break :blk l;
        };
        if (std.mem.eql(u8, ident(rest), name)) return n;
    }
    return null;
}

/// The identifier at the start of `s` (possibly empty).
fn ident(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) : (i += 1) {}
    if (i > 0 and std.ascii.isDigit(s[0])) return s[0..0];
    return s[0..i];
}

// ------------------------------------------------------------ file text

pub const FileText = union(enum) {
    /// The file's text; the caller owns it.
    text: String,
    /// What Godot reports for a file that cannot be read.
    err: Error,
};

/// Reads the `.zig` file at `path` the way the loader and the reload hooks
/// need it. Text that is not valid UTF-8 is refused with `ERR_INVALID_DATA`
/// and one log line, because Godot's own string read would swap the bad
/// bytes for U+FFFD and a later save would write those into the file.
/// Any thread: the open error is per thread and is read on the same one.
pub fn readFileText(path: String) FileText {
    var bytes = FileAccess.getFileAsBytes(path);
    defer bytes.deinit();
    const open_err = FileAccess.getOpenError();
    if (open_err != .ok) return .{ .err = open_err };
    const n: usize = @intCast(@max(0, bytes.size()));
    const data: []const u8 = if (n == 0) "" else @as([*]const u8, @ptrCast(bytes.indexConst(0)))[0..n];
    const valid = std.unicode.utf8ValidateSlice(data);
    var text: String = if (valid) (String.fromUtf8(data) catch return .{ .err = .err_invalid_data }) else .init();
    if (!valid) {
        text.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        logError("Cannot load {s}: the file is not valid UTF-8.", .{stringText(&path, &buf) orelse "(path too long)"});
        return .{ .err = .err_invalid_data };
    }
    return .{ .text = text };
}

// ------------------------------------------------------------ the script

pub const ZigScript = struct {
    base: *ScriptExtension,
    /// The file's text, as the script editor shows it.
    source: String,
    /// The live placeholder instances and the descriptors they were fed.
    placeholders: placeholder.Set(DescKey) = .{},
    /// Set while the script's last build failed (`setBuildFailed`).
    build_failed: std.atomic.Value(bool) = .init(false),
    /// Set once a reload request has been logged.
    reload_logged: bool = false,
    /// Set once a refused instance has been logged.
    instance_logged: std.atomic.Value(bool) = .init(false),
    /// The objects that hold a placeholder of this script, so a build that
    /// makes it a runnable tool script can give them real instances
    /// (`swapToolPlaceholders`). Guarded by `owners_mu`: placeholders are
    /// made and erased on any thread.
    owners_mu: std.Io.Mutex = .init,
    owners: std.ArrayList(Owner) = .empty,
    /// What the host last read from or wrote to the script's file: the
    /// file's modification time (seconds, Godot's `get_modified_time`) and a
    /// hash of the text. `disk_mtime` 0: the text never came from a file.
    /// Set by the loader (any thread, before the script is shared), the
    /// saver and the main thread.
    disk_mtime: u64 = 0,
    disk_hash: u64 = 0,

    const Owner = struct { placeholder: *anyopaque, id: u64 };

    pub fn create(allocator: *Allocator) !*ZigScript {
        const self = try allocator.create(ZigScript);
        self.* = .{ .base = ScriptExtension.init(), .source = .init() };
        self.base.setInstance(ZigScript, self);
        track(self);
        return self;
    }

    pub fn destroy(self: *ZigScript, allocator: *Allocator) void {
        untrack(self);
        self.owners.deinit(std.heap.c_allocator);
        self.placeholders.deinit();
        self.source.deinit();
        self.base.destroy();
        allocator.destroy(self);
    }

    /// A new script holding `text`. Its one counted reference belongs to the
    /// caller.
    pub fn withSource(text: String) ?*ZigScript {
        var alloc = godot.engine_allocator;
        const s = create(&alloc) catch return null;
        s.source.deinit();
        s.source = .copy(text);
        return s;
    }

    /// The descriptor for this script's resource path, or null.
    fn desc(self: *const ZigScript) ?Desc {
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const res_path = stringText(&path, &buf) orelse return null;
        var rel_buf: [max_path_bytes]u8 = undefined;
        return findDesc(relPath(res_path, &rel_buf) orelse return null);
    }

    /// The descriptor placeholders are fed from: null while placeholder
    /// fallback is on (no descriptor, or the last build failed). A script
    /// object made after the build (a later load) has no flag set, so the
    /// diagnostics the build recorded for its file count too.
    fn liveDesc(self: *const ZigScript) ?Desc {
        if (self.build_failed.load(.acquire)) return null;
        var buf: [max_path_bytes]u8 = undefined;
        if (self.rel(&buf)) |r| {
            if (diag_cache.hasErrors(r)) return null;
        }
        return self.desc();
    }

    /// Marks the script's last build as failed (true) or good (false).
    /// While it is failed, placeholder fallback is on and placeholders keep
    /// what they hold; the next `_update_exports` after a good build feeds
    /// them again. Any thread.
    pub fn setBuildFailed(self: *ZigScript, failed: bool) void {
        self.build_failed.store(failed, .release);
    }

    /// Re-reads the text of a script that is a file under `res://` and
    /// replaces the held text with it; a script without such a file, or a
    /// file that cannot be read, keeps its text. Called when the editor
    /// discards edits (`Script::reload_from_file`). Main thread.
    pub fn reloadSourceFromDisk(self: *ZigScript) void {
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const p = stringText(&path, &buf) orelse return;
        if (!std.mem.startsWith(u8, p, "res://") or std.mem.indexOf(u8, p, "::") != null) return;
        switch (readFileText(path)) {
            .text => |t| {
                self.source.deinit();
                self.source = t;
                self.noteDisk(FileAccess.getModifiedTime(path));
            },
            .err => {},
        }
    }

    /// Records that the held text is what the file holds, with the file's
    /// modification time `mtime`.
    pub fn noteDisk(self: *ZigScript, mtime: u64) void {
        const text = props.utf8Alloc(std.heap.c_allocator, &self.source) catch return;
        defer std.heap.c_allocator.free(text);
        self.noteDiskText(mtime, text);
    }

    /// As `noteDisk`, when the caller has the text as UTF-8 already.
    pub fn noteDiskText(self: *ZigScript, mtime: u64, text: []const u8) void {
        self.disk_hash = std.hash.Wyhash.hash(0, text);
        self.disk_mtime = mtime;
    }

    /// Picks up an edit made outside the editor: when the file's
    /// modification time is not the one the host last saw and the held text
    /// has no unsaved edits (it is still what the host last read or wrote),
    /// the text is read again. A script with unsaved edits keeps them (the
    /// script editor asks the user about such files). Main thread. True
    /// when the text was replaced.
    pub fn refreshFromDisk(self: *ZigScript) bool {
        if (self.disk_mtime == 0) return false;
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const p = stringText(&path, &buf) orelse return false;
        if (!std.mem.startsWith(u8, p, "res://") or std.mem.indexOf(u8, p, "::") != null) return false;
        const mtime = FileAccess.getModifiedTime(path);
        if (mtime == 0 or mtime == self.disk_mtime) return false;
        const text = props.utf8Alloc(std.heap.c_allocator, &self.source) catch return false;
        const unchanged = std.hash.Wyhash.hash(0, text) == self.disk_hash;
        std.heap.c_allocator.free(text);
        if (!unchanged) return false;
        switch (readFileText(path)) {
            .text => |t| {
                self.source.deinit();
                self.source = t;
                self.noteDisk(mtime);
                return true;
            },
            .err => return false,
        }
    }

    /// The project-relative path of the script (see `relPath`), in `buf`.
    pub fn rel(self: *const ZigScript, buf: []u8) ?[]const u8 {
        var path = self.base.getPath();
        defer path.deinit();
        var res_buf: [max_path_bytes]u8 = undefined;
        const res_path = stringText(&path, &res_buf) orelse return null;
        return relPath(res_path, buf);
    }

    /// Gives every object that holds a placeholder of this script a real
    /// instance, once a loaded module describes the script as a tool script
    /// whose build did not fail (a placeholder is made while only the cache,
    /// or nothing, describes it). As GDScript does on reload
    /// (modules/gdscript/gdscript.cpp, `reload_scripts`): the exported
    /// values are read through the placeholder, the script is taken off the
    /// object and set again, which makes `Object::set_script` ask
    /// `instance_create`, then the values are set on the instance. `_ready`
    /// does not run again for a node already in the tree. Main thread.
    pub fn swapToolPlaceholders(self: *ZigScript) void {
        if (!editor_hint.load(.acquire) or self.build_failed.load(.acquire)) return;
        const d = self.desc() orelse return;
        if (d != .loaded or d.flags() & abi.script_flag_tool == 0) return;
        const ids = blk: {
            self.owners_mu.lockUncancelable(host_io.get());
            defer self.owners_mu.unlock(host_io.get());
            const list = std.heap.c_allocator.alloc(u64, self.owners.items.len) catch return;
            for (self.owners.items, list) |o, *id| id.* = o.id;
            break :blk list;
        };
        defer std.heap.c_allocator.free(ids);
        // Keeps the script alive while objects drop and take it.
        const keep = Variant.init(*ScriptExtension, self.base);
        defer keep.deinit();
        for (ids) |id| {
            if (!self.hasOwner(id)) continue;
            const raw = godot.raw.objectGetInstanceFromId(id) orelse continue;
            const obj: *Object = @ptrCast(@alignCast(raw));
            var cur = obj.getScript();
            defer cur.deinit();
            const cur_obj = cur.as(*Object) orelse continue;
            if (@intFromPtr(cur_obj) != @intFromPtr(self.base)) continue;

            var saved: std.ArrayList(Saved) = .empty;
            defer {
                for (saved.items) |*e| e.deinit();
                saved.deinit(std.heap.c_allocator);
            }
            for (0..d.propertyCount()) |i| {
                const prop = d.property(@intCast(i));
                if (prop.label) continue;
                var sn = StringName.fromUtf8(prop.name);
                const v = obj.get(sn);
                // Nothing stored (a placeholder without descriptors knows
                // only the values set on it): the instance keeps its default.
                if (v.tag == .nil) {
                    sn.deinit();
                    continue;
                }
                saved.append(std.heap.c_allocator, .{ .name = sn, .value = v }) catch {
                    v.deinit();
                    sn.deinit();
                };
            }
            obj.setScript(.nil);
            obj.setScript(keep);
            for (saved.items) |e| obj.set(e.name, e.value);
        }
    }

    const Saved = struct {
        name: StringName,
        value: Variant,

        fn deinit(e: *Saved) void {
            e.value.deinit();
            e.name.deinit();
        }
    };

    fn addOwner(self: *ZigScript, p: *anyopaque, id: u64) void {
        self.owners_mu.lockUncancelable(host_io.get());
        defer self.owners_mu.unlock(host_io.get());
        self.owners.append(std.heap.c_allocator, .{ .placeholder = p, .id = id }) catch {};
    }

    fn removeOwner(self: *ZigScript, p: *anyopaque) void {
        self.owners_mu.lockUncancelable(host_io.get());
        defer self.owners_mu.unlock(host_io.get());
        for (self.owners.items, 0..) |o, i| {
            if (o.placeholder != p) continue;
            _ = self.owners.swapRemove(i);
            return;
        }
    }

    fn hasOwner(self: *ZigScript, id: u64) bool {
        self.owners_mu.lockUncancelable(host_io.get());
        defer self.owners_mu.unlock(host_io.get());
        for (self.owners.items) |o| if (o.id == id) return true;
        return false;
    }

    /// The source text as UTF-8 with a terminating 0, for the scanners;
    /// owned by the caller (C allocator).
    fn sourceZ(self: *const ZigScript) ?[:0]u8 {
        const n: usize = @intCast(@max(0, godot.raw.stringToUtf8Chars(self.source.constPtr(), null, 0)));
        const buf = std.heap.c_allocator.allocSentinel(u8, n, 0) catch return null;
        if (n != 0) _ = godot.raw.stringToUtf8Chars(self.source.constPtr(), buf.ptr, @intCast(n));
        return buf;
    }

    /// The signal names the source text declares (`global_class.signalNames`),
    /// for a script without descriptors. Calls `each(ctx, name)` per name.
    fn scannedSignals(self: *const ZigScript, ctx: anytype, comptime each: fn (@TypeOf(ctx), []const u8) bool) void {
        const text = self.sourceZ() orelse return;
        defer std.heap.c_allocator.free(text);
        var names: [global_class.max_signals][]const u8 = undefined;
        const n = global_class.signalNames(text, &names);
        for (names[0..n]) |name| if (!each(ctx, name)) return;
    }

    /// `reloadSourceFromDisk` for any object Godot hands to a reload hook;
    /// objects that are not Zig scripts are ignored.
    pub fn reloadObjectFromDisk(obj: ?*Object) void {
        const o = obj orelse return;
        if (!o.isClass(.fromComptimeLatin1("ZigScript"))) return;
        const self = o.asInstance(ZigScript) orelse return;
        self.reloadSourceFromDisk();
    }

    /// Writes `Script <path> <what>` to Godot's output.
    fn logScript(self: *const ZigScript, comptime what: []const u8) void {
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const p = stringText(&path, &buf) orelse "(path too long)";
        log("Script {s} " ++ what, .{if (p.len == 0) "(unsaved)" else p});
    }

    // ---------------------------------------------------------- identity

    pub fn _getLanguage(_: *ZigScript) ?*ScriptLanguage {
        const lang = language.registered orelse return null;
        return .upcast(lang.base);
    }

    /// True when a descriptor describes the script. A script without one
    /// was never built (or its build failed before any good build).
    pub fn _isValid(self: *ZigScript) bool {
        return self.desc() != null;
    }

    /// The descriptor's tool flag (`pub const tool = true;`), per script.
    pub fn _isTool(self: *ZigScript) bool {
        const d = self.desc() orelse return false;
        return d.flags() & abi.script_flag_tool != 0;
    }

    pub fn _isAbstract(_: *ZigScript) bool {
        return false;
    }

    /// The engine class the script extends; empty without a descriptor.
    pub fn _getInstanceBaseType(self: *ZigScript) StringName {
        const d = self.desc() orelse return .init();
        return .fromUtf8(d.baseClass());
    }

    /// The script's `class_name`, or empty.
    pub fn _getGlobalName(self: *ZigScript) StringName {
        const d = self.desc() orelse return .init();
        return .fromUtf8(d.className());
    }

    /// Zig scripts do not inherit from scripts: only this script itself.
    pub fn _inheritsScript(self: *ZigScript, script: ?*Script) bool {
        const s = script orelse return false;
        return @intFromPtr(s) == @intFromPtr(self.base);
    }

    pub fn _getBaseScript(_: *ZigScript) ?*Script {
        return null;
    }

    /// GDScript's rule (modules/gdscript/gdscript.cpp:258): valid, and tool
    /// or scripting enabled, and not in recovery mode. A GDExtension cannot
    /// read `ScriptServer::is_scripting_enabled()`; the editor turns
    /// scripting off when it starts (editor/editor_node.cpp:8388) and is the
    /// only place that does, so the editor hint stands for "scripting
    /// disabled". Recovery mode needs no check: Godot loads no GDExtension
    /// in it (core/extension/gdextension_manager.cpp:116), so this code
    /// never runs there.
    pub fn _canInstantiate(self: *ZigScript) bool {
        const d = self.desc() orelse return false;
        const tool = d.flags() & abi.script_flag_tool != 0;
        return tool or !editor_hint.load(.acquire);
    }

    // ---------------------------------------------------------- instances

    /// A script instance for `owner` (`instance.create`), or null: Godot
    /// then keeps the object without a script. Refused when the owner's
    /// class is neither the script's `extends` class nor derived from it
    /// (one line naming the script and both classes, each time), and when
    /// no loaded module describes the script (cached descriptors cannot
    /// run; logged once per script). In the editor a tool script that no
    /// loaded module describes gets a placeholder instead, so the scene
    /// keeps its values until a module runs it.
    pub fn _instanceCreate(self: *ZigScript, owner: ?*Object) ?*anyopaque {
        const o = owner orelse return null;
        const loaded = if (self.desc()) |d| d == .loaded else false;
        if (!loaded and editor_hint.load(.acquire)) return self._placeholderInstanceCreate(o);
        const d = self.desc() orelse {
            self.logRefusedInstance();
            return null;
        };
        const l = switch (d) {
            .loaded => |l| l,
            .cached => {
                self.logRefusedInstance();
                return null;
            },
        };
        if (!instance.ownerFits(o, d.baseClass())) {
            self.logWrongOwner(o, d.baseClass());
            return null;
        }
        return instance.create(self.base, o, l.gen, l.index);
    }

    fn logWrongOwner(self: *const ZigScript, owner: *Object, base_class: []const u8) void {
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const p = stringText(&path, &buf) orelse "(path too long)";
        var cls = owner.getClass();
        defer cls.deinit();
        var cls_buf: [max_name_bytes]u8 = undefined;
        const c = stringText(&cls, &cls_buf) orelse "(name too long)";
        logError("Script {s} extends {s}, so it cannot be attached to an object of class {s}.", .{ if (p.len == 0) "(unsaved)" else p, base_class, c });
    }

    /// A placeholder instance for `owner` (`placeholder.create`), recorded
    /// and, unless fallback is on, fed with the descriptor's property list
    /// and defaults, as GDScript does (modules/gdscript/gdscript.cpp:427-436).
    pub fn _placeholderInstanceCreate(self: *ZigScript, owner: ?*Object) ?*anyopaque {
        const o = owner orelse return null;
        const lang = language.registered orelse return null;
        const p = placeholder.create(lang.base, self.base, o) orelse return null;
        self.addOwner(p, o.getInstanceId());
        const d = self.liveDesc();
        self.placeholders.add(p, if (d) |x| x.key() else null, Feed{ .d = d });
        return p;
    }

    /// Any thread: Godot instantiates scenes on worker threads too.
    fn logRefusedInstance(self: *ZigScript) void {
        if (self.instance_logged.swap(true, .acq_rel)) return;
        var path = self.base.getPath();
        defer path.deinit();
        var buf: [max_path_bytes]u8 = undefined;
        const p = stringText(&path, &buf) orelse "(path too long)";
        logError("Script {s} cannot create instances yet.", .{if (p.len == 0) "(unsaved)" else p});
    }

    /// Godot is deleting placeholder `p` (`~PlaceHolderScriptInstance`).
    pub fn _placeholderErased(self: *ZigScript, p: ?*anyopaque) void {
        const ph = p orelse return;
        self.removeOwner(ph);
        self.placeholders.remove(ph);
    }

    /// Idempotent: Godot calls it once per property while saving a scene.
    /// Only when the descriptors differ from those the placeholders were fed
    /// last (another generation, the cache replaced by a module, or the
    /// first good build after a failed one) are they fed again. Nothing is
    /// fed while fallback is on.
    pub fn _updateExports(self: *ZigScript) void {
        const d = self.liveDesc();
        _ = self.placeholders.refresh(if (d) |x| x.key() else null, Feed{ .d = d });
    }

    /// True while the script has no descriptors or its last build failed:
    /// Godot then keeps every scene value of a placeholder instead of
    /// dropping the ones the script does not list (spec section 2).
    pub fn _isPlaceholderFallbackEnabled(self: *ZigScript) bool {
        return self.liveDesc() == null;
    }

    // ---------------------------------------------------------- source

    pub fn _hasSourceCode(_: *ZigScript) bool {
        return true;
    }

    pub fn _getSourceCode(self: *ZigScript) String {
        return .copy(self.source);
    }

    pub fn _setSourceCode(self: *ZigScript, code: String) void {
        self.source.deinit();
        self.source = .copy(code);
    }

    /// Returns OK: the code that runs changes only when a new build is
    /// loaded, so a reload request changes nothing. Logged once per script.
    pub fn _reload(self: *ZigScript, _: bool) Error {
        if (!self.reload_logged) {
            self.reload_logged = true;
            self.logScript("reloads when a new build is loaded; the reload request changed nothing.");
        }
        return .ok;
    }

    /// False, as for Godot's own `Script` (core/object/script_language.h).
    /// With true, the editor's file-changed path (`EditorNode::
    /// _resources_changed`) would call `Script::reload_from_file`, which only
    /// asks the language to reload and never re-reads the text. The script
    /// editor re-reads a changed file itself, with a `CACHE_MODE_IGNORE` load
    /// through the `.zig` loader (script_editor_plugin.cpp, `_reload_scripts`).
    pub fn _editorCanReloadFromFile(_: *ZigScript) bool {
        return false;
    }

    // ---------------------------------------------------------- members

    pub fn _hasMethod(self: *ZigScript, method: StringName) bool {
        const d = self.desc() orelse return false;
        return d.methodIndex(method) != null;
    }

    /// The method's argument count as an int Variant; nil for an unknown
    /// method, so Godot falls back to its default (unknown count).
    pub fn _getScriptMethodArgumentCount(self: *ZigScript, method: StringName) Variant {
        const d = self.desc() orelse return .nil;
        const i = d.methodIndex(method) orelse return .nil;
        return Variant.init(i64, d.methodArgCount(i));
    }

    pub fn _hasStaticMethod(_: *ZigScript, _: StringName) bool {
        return false;
    }

    /// The method's dictionary, as in `_get_script_method_list`; empty for
    /// an unknown method.
    pub fn _getMethodInfo(self: *ZigScript, method: StringName) Dictionary {
        const d = self.desc() orelse return .init();
        const i = d.methodIndex(method) orelse return .init();
        return d.methodInfo(i);
    }

    pub fn _getScriptMethodList(self: *ZigScript) Array {
        const d = self.desc() orelse return .init();
        return d.methodList();
    }

    /// Exported properties with their group entries, in descriptor order.
    pub fn _getScriptPropertyList(self: *ZigScript) Array {
        const d = self.desc() orelse return .init();
        return d.propertyList();
    }

    /// Without descriptors, the signals the source text declares (names
    /// only, `global_class.signalNames`), so Godot keeps scene connections
    /// to them; `meta` name overrides are not seen there.
    pub fn _hasScriptSignal(self: *ZigScript, signal: StringName) bool {
        if (self.desc()) |d| return d.hasSignal(signal);
        var buf: [max_name_bytes]u8 = undefined;
        var want = Want{ .name = nameText(signal, &buf) orelse return false };
        self.scannedSignals(&want, Want.check);
        return want.found;
    }

    pub fn _getScriptSignalList(self: *ZigScript) Array {
        if (self.desc()) |d| return d.signalList();
        var arr = Array.init();
        self.scannedSignals(&arr, pushSignal);
        return arr;
    }

    const Want = struct {
        name: []const u8,
        found: bool = false,

        fn check(w: *Want, name: []const u8) bool {
            if (!std.mem.eql(u8, w.name, name)) return true;
            w.found = true;
            return false;
        }
    };

    fn pushSignal(arr: *Array, name: []const u8) bool {
        var args = Array.init();
        defer args.deinit();
        var d = props.signalDict(name, args);
        defer d.deinit();
        props.pushDict(arr, d);
        return true;
    }

    /// True for an exported property whose default round-trips through
    /// the descriptor cache (`Desc.hasDefault`), the same answer from a
    /// loaded module and from the cache. The SDK requires a default for
    /// every field, so this is false only for defaults with no stored form;
    /// Godot then saves that property's value in every scene.
    pub fn _hasPropertyDefaultValue(self: *ZigScript, property: StringName) bool {
        const d = self.desc() orelse return false;
        const i = d.propertyIndex(property) orelse return false;
        return d.hasDefault(i);
    }

    pub fn _getPropertyDefaultValue(self: *ZigScript, property: StringName) Variant {
        const d = self.desc() orelse return .nil;
        const i = d.propertyIndex(property) orelse return .nil;
        return d.defaultValue(i) orelse .nil;
    }

    /// The exported property names (group entries left out), like
    /// GDScript's member variables.
    pub fn _getMembers(self: *ZigScript) Array {
        var arr = Array.init();
        const d = self.desc() orelse return arr;
        for (0..d.propertyCount()) |i| {
            const p = d.property(@intCast(i));
            if (p.label) continue;
            var sn = StringName.fromUtf8(p.name);
            defer sn.deinit();
            const v = Variant.init(StringName, sn);
            defer v.deinit();
            arr.pushBack(v);
        }
        return arr;
    }

    /// The 1-based line declaring `member` in the source text (see
    /// `memberLine`), or -1.
    pub fn _getMemberLine(self: *ZigScript, member: StringName) i64 {
        var buf: [max_name_bytes]u8 = undefined;
        const name = nameText(member, &buf) orelse return -1;
        const text = props.utf8Alloc(std.heap.c_allocator, &self.source) catch return -1;
        defer std.heap.c_allocator.free(text);
        return memberLine(text, name) orelse -1;
    }

    /// Zig scripts expose no constants to Godot.
    pub fn _getConstants(_: *ZigScript) Dictionary {
        return .init();
    }

    /// No RPC methods. Godot caches an object's RPC config once and never
    /// refreshes it, so RPCs that a reload would add are ignored.
    pub fn _getRpcConfig(_: *ZigScript) Variant {
        var d = Dictionary.init();
        defer d.deinit();
        return Variant.init(Dictionary, d);
    }

    // ---------------------------------------------------------- documentation

    pub fn _getDocClassName(_: *ZigScript) StringName {
        return .init();
    }

    pub fn _getDocumentation(_: *ZigScript) Array {
        return .init();
    }
};

/// Reports one line through Godot's error printing (`print_error`: shown
/// as an error in the editor's Errors tab), as GDScript reports a refused
/// instance (ERR_FAIL_V_MSG, modules/gdscript/gdscript.cpp:415).
fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_path_bytes + 2 * max_name_bytes + 256]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch return;
    godot.raw.printError(msg.ptr, "ZigScript", "src/host/script.zig", @src().line, 1);
}

/// Prints one line to Godot's output.
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [max_path_bytes + 2 * max_name_bytes + 256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var s: String = String.fromUtf8(msg) catch String.fromLatin1(msg);
    defer s.deinit();
    godot.general.print(.init(String, s), .{});
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "member line follows the SDK marker rule with Godot names" {
    const text =
        \\const z = @import("ziggurat");
        \\pub const class_name = "Player";
        \\
        \\base: *g.Node,
        \\speed: f32 = 300,
        \\    nested: i32 = 0,
        \\pub const signals = struct {
        \\    pub const hit = struct {};
        \\};
        \\pub fn takeDamage(self: *@This()) void {}
        \\fn _physicsProcess(self: *@This(), d: f64) void {}
        \\var counter: u32 = 0;
        \\speedy: f32 = 1,
        \\pub fn speed(self: *@This()) void {}
    ;
    try testing.expectEqual(@as(?u32, 5), memberLine(text, "speed"));
    try testing.expectEqual(@as(?u32, 13), memberLine(text, "speedy"));
    try testing.expectEqual(@as(?u32, 10), memberLine(text, "take_damage"));
    try testing.expectEqual(@as(?u32, 10), memberLine(text, "takeDamage"));
    try testing.expectEqual(@as(?u32, 11), memberLine(text, "_physics_process"));
    try testing.expectEqual(@as(?u32, 7), memberLine(text, "signals"));
    try testing.expectEqual(@as(?u32, 12), memberLine(text, "counter"));
    try testing.expectEqual(@as(?u32, 2), memberLine(text, "class_name"));
    // Indented declarations are not top-level.
    try testing.expectEqual(@as(?u32, null), memberLine(text, "nested"));
    try testing.expectEqual(@as(?u32, null), memberLine(text, "hit"));
    try testing.expectEqual(@as(?u32, null), memberLine(text, "spee"));
    try testing.expectEqual(@as(?u32, null), memberLine(text, ""));
    try testing.expectEqual(@as(?u32, 1), memberLine("x: i32 = 0,\r\n", "x"));
}

test "relative path of a resource path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("player.zig", relPath("res://player.zig", &buf).?);
    try testing.expectEqualStrings("ui/hud.zig", relPath("res://ui/hud.zig", &buf).?);
    try testing.expect(relPath("res://", &buf) == null);
    try testing.expect(relPath("", &buf) == null);
    try testing.expect(relPath("user://a.zig", &buf) == null);
}

test "relative path is normalised like simplify_path" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a.zig", relPath("res://./a.zig", &buf).?);
    try testing.expectEqualStrings("a/b.zig", relPath("res://a//b.zig", &buf).?);
    try testing.expectEqualStrings("a/b.zig", relPath("res:///a/./b.zig", &buf).?);
    try testing.expectEqualStrings("a/b.zig", relPath("res://a\\b.zig", &buf).?);
    try testing.expectEqualStrings("b.zig", relPath("res://a/../b.zig", &buf).?);
    try testing.expectEqualStrings("x/b.zig", relPath("res://x/a/c/../../b.zig", &buf).?);
    try testing.expect(relPath("res://../a.zig", &buf) == null);
    try testing.expect(relPath("res://a/../..", &buf) == null);
    try testing.expect(relPath("res://./", &buf) == null);
    // Case-sensitive: kept as written.
    try testing.expectEqualStrings("Player.zig", relPath("res://Player.zig", &buf).?);
    var small: [4]u8 = undefined;
    try testing.expect(relPath("res://abcde.zig", &small) == null);
}

test "descriptor keys tell sources and generations apart" {
    const none: DescKey = .{};
    try testing.expect(none.eql(.{}));
    try testing.expect(!none.eql(.{ .source = .cached, .n = 0 }));
    try testing.expect(!(DescKey{ .source = .cached, .n = 1 }).eql(.{ .source = .loaded, .n = 1 }));
    try testing.expect(!(DescKey{ .source = .loaded, .n = 1 }).eql(.{ .source = .loaded, .n = 2 }));
}
