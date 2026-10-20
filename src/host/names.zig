//! Name maps: from a Godot `StringName` to a method or property index of one
//! script (plan decision "Names to indexes").
//!
//! Godot calls a script with names, the module takes indexes. At load the
//! host makes one engine `StringName` per method name and per property name
//! (group entries have no value and are left out), keeps it for the
//! generation's lifetime, and maps the StringName's data pointer to the index.
//!
//! Why the data pointer is a valid key: Godot interns StringNames. Every
//! constructor looks the text up in one global table (guarded by a mutex)
//! and, when an entry exists, takes a reference to that entry instead of
//! making a new one. So all live StringNames with the same text share one
//! data pointer, and different texts have different pointers. The entry is
//! freed only when its last reference goes; the map holds a reference to each
//! of its names, so a mapped entry cannot be freed and its address reused for
//! other text while the map lives. The empty StringName has a null data
//! pointer; a lookup with it falls back to comparing text.
//!
//! Lookups only read memory; they are safe from any thread while the map
//! lives. `build` and `deinit` call into Godot and run on the main thread.
const std = @import("std");
const godot = @import("gdzig");
const abi = @import("ziggurat_abi");

const Allocator = std.mem.Allocator;
const StringName = godot.builtin.StringName;

/// The data pointer of `sn` (Godot's `StringName::_data`), as an integer;
/// 0 for the empty name.
pub fn dataKey(sn: *const StringName) usize {
    return std.mem.bytesToValue(usize, std.mem.asBytes(sn)[0..@sizeOf(usize)]);
}

/// Index lookup by key, with the names' text for the null-key fallback.
/// Pure data: no Godot calls, so it is unit-tested without an engine.
pub const NameMap = struct {
    by_key: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    /// Text of every mapped name with its index; borrowed from the table.
    texts: []const Entry = &.{},

    pub const Entry = struct { text: []const u8, index: u32 };

    pub fn deinit(m: *NameMap, a: Allocator) void {
        m.by_key.deinit(a);
        a.free(m.texts);
        m.* = .{};
    }

    /// The index mapped to `key`. A zero key (the empty name, which has no
    /// data pointer) is looked up by its text, the empty string.
    pub fn get(m: *const NameMap, key: usize) ?u32 {
        if (key == 0) return m.byText("");
        return m.by_key.get(key);
    }

    pub fn byText(m: *const NameMap, text: []const u8) ?u32 {
        for (m.texts) |e| {
            if (std.mem.eql(u8, e.text, text)) return e.index;
        }
        return null;
    }
};

/// The method and property maps of one script, with the StringNames they
/// keep alive.
pub const ScriptNames = struct {
    methods: NameMap = .{},
    properties: NameMap = .{},
    /// One per mapped name, owned; released by `deinit`.
    names: []StringName = &.{},

    /// The method index for `sn`, or null when the script has no method of
    /// that name.
    pub fn method(self: *const ScriptNames, sn: StringName) ?u32 {
        return self.methods.get(dataKey(&sn));
    }

    /// The property index for `sn` (indexes count group entries, as the
    /// table does), or null when no exported property has that name.
    pub fn property(self: *const ScriptNames, sn: StringName) ?u32 {
        return self.properties.get(dataKey(&sn));
    }

    /// Makes the StringNames of `desc`'s methods and non-group properties and
    /// maps them. `desc` must have passed `abi.validate`; its strings must
    /// outlive the result (they are static data of a library that is never
    /// unloaded). Main thread only.
    pub fn build(a: Allocator, desc: *const abi.ScriptDesc) error{OutOfMemory}!ScriptNames {
        var count: usize = desc.method_count;
        for (desc.properties[0..desc.property_count]) |*p| {
            if (!isGroup(p)) count += 1;
        }
        const names = try a.alloc(StringName, count);
        var made: usize = 0;
        errdefer {
            for (names[0..made]) |*sn| sn.deinit();
            a.free(names);
        }
        var self: ScriptNames = .{};
        errdefer {
            self.methods.deinit(a);
            self.properties.deinit(a);
        }

        const m_texts = try a.alloc(NameMap.Entry, desc.method_count);
        self.methods.texts = m_texts;
        try self.methods.by_key.ensureTotalCapacity(a, desc.method_count);
        for (desc.methods[0..desc.method_count], 0..) |*m, i| {
            const text = str(m.name);
            names[made] = StringName.fromUtf8(text);
            m_texts[i] = .{ .text = text, .index = @intCast(i) };
            insert(&self.methods, &names[made], @intCast(i));
            made += 1;
        }

        const p_texts = try a.alloc(NameMap.Entry, count - desc.method_count);
        self.properties.texts = p_texts;
        try self.properties.by_key.ensureTotalCapacity(a, @intCast(p_texts.len));
        var k: usize = 0;
        for (desc.properties[0..desc.property_count], 0..) |*p, i| {
            if (isGroup(p)) continue;
            const text = str(p.name);
            names[made] = StringName.fromUtf8(text);
            p_texts[k] = .{ .text = text, .index = @intCast(i) };
            insert(&self.properties, &names[made], @intCast(i));
            made += 1;
            k += 1;
        }

        self.names = names;
        return self;
    }

    /// Releases the StringNames and the maps. Main thread only.
    pub fn deinit(self: *ScriptNames, a: Allocator) void {
        for (self.names) |*sn| sn.deinit();
        a.free(self.names);
        self.methods.deinit(a);
        self.properties.deinit(a);
        self.* = .{};
    }
};

/// Keeps the first index for a key: the validator refuses duplicate names,
/// so a second one cannot happen with a validated table.
fn insert(m: *NameMap, sn: *const StringName, index: u32) void {
    const key = dataKey(sn);
    if (key == 0) return; // the empty name: found by text
    const gop = m.by_key.getOrPutAssumeCapacity(key);
    if (!gop.found_existing) gop.value_ptr.* = index;
}

fn isGroup(p: *const abi.PropertyDesc) bool {
    return p.field_index == abi.no_field;
}

fn str(s: abi.Str) []const u8 {
    if (s.len == 0) return "";
    return s.ptr.?[0..s.len];
}

const testing = std.testing;

test "NameMap maps keys and finds the empty name by text" {
    const a = testing.allocator;
    var m: NameMap = .{};
    defer m.deinit(a);
    const texts = try a.alloc(NameMap.Entry, 2);
    texts[0] = .{ .text = "jump", .index = 0 };
    texts[1] = .{ .text = "run", .index = 2 };
    m.texts = texts;
    try m.by_key.put(a, 0x1000, 0);
    try m.by_key.put(a, 0x2000, 2);

    try testing.expectEqual(@as(?u32, 0), m.get(0x1000));
    try testing.expectEqual(@as(?u32, 2), m.get(0x2000));
    try testing.expectEqual(@as(?u32, null), m.get(0x3000));
    // No mapped name is empty, so the null key finds nothing.
    try testing.expectEqual(@as(?u32, null), m.get(0));
    try testing.expectEqual(@as(?u32, 2), m.byText("run"));
}

test "dataKey reads the first pointer-sized bytes" {
    var sn: StringName = std.mem.zeroes(StringName);
    try testing.expectEqual(@as(usize, 0), dataKey(&sn));
    const want: usize = 0xdead_beef;
    @memcpy(std.mem.asBytes(&sn)[0..@sizeOf(usize)], std.mem.asBytes(&want));
    try testing.expectEqual(want, dataKey(&sn));
}
