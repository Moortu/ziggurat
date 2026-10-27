//! Mach-O file reader (L1, std only): the format of macOS dylibs. It checks
//! that a file is complete before the loader or the generation store accepts
//! it, and lists a dylib's export and import names, its minimum macOS
//! version and its code signature for the export output checks.
//!
//! A file is either thin (one 64-bit little-endian Mach-O image) or fat (a
//! big-endian header and arch table, then one thin image per CPU, called a
//! slice). `checkComplete` and `slices` take the whole file; `exports`,
//! `imports`, `minOs` and `codeSignature` take one thin image, which is the
//! whole file when it is thin and `bytes[s.offset..][0..s.size]` for a slice
//! `s` of a fat file. Offsets inside a thin image count from its first byte.
//!
//! Every offset and size comes from the file, so every read is bounds-checked
//! and every sum is done in 64 bits. No input makes these functions panic.
const std = @import("std");
const Allocator = std.mem.Allocator;
const LC = std.macho.LC;

pub const Error = error{
    /// A header, table, slice, segment or linkedit range ends past the end
    /// of the file (or of its slice).
    Truncated,
    /// The file starts with no Mach-O or fat magic number. The thin-image
    /// functions also return it for a fat file.
    NotMachO,
    /// A header or table value is impossible (32-bit or big-endian image,
    /// a load command that does not fit, overlapping slices, a broken
    /// export trie, ...).
    BadHeader,
};

/// A CPU type from a fat arch table or a Mach-O header.
pub const Cpu = enum(u32) {
    x86_64 = std.macho.CPU_TYPE_X86_64,
    arm64 = std.macho.CPU_TYPE_ARM64,
    _,
};

/// One thin image of a file: its CPU and where its bytes are.
pub const Slice = struct { cpu: Cpu, offset: u64, size: u64 };

/// The code signature blob of a thin image (`LC_CODE_SIGNATURE`): its offset
/// from the start of the image and its size.
pub const CodeSignature = struct { offset: u32, size: u32 };

// Output limits of `exports` and `imports`, as in `pe.zig`. Past any limit
// the result is `error.TooLarge`.
/// The most names one list may hold.
pub const max_entries = 1 << 16;
/// The longest name, in bytes.
pub const max_name_len = 4096;
/// The most name bytes one list may hold in total.
pub const max_output_bytes = 16 << 20;
/// The most slices a fat file may have. Real files have two or three.
pub const max_fat_arches = 64;

/// Errors of `exports` and `imports`.
pub const ListError = Error || error{
    /// The list would pass `max_entries`, `max_name_len` or `max_output_bytes`.
    TooLarge,
} || Allocator.Error;

/// Counts what a list has used of the output limits.
const Budget = struct {
    entries: usize = 0,
    bytes: u64 = 0,

    fn take(self: *Budget, len: usize) error{TooLarge}!void {
        self.entries += 1;
        if (self.entries > max_entries) return error.TooLarge;
        if (len > max_name_len) return error.TooLarge;
        self.bytes += len;
        if (self.bytes > max_output_bytes) return error.TooLarge;
    }
};

const mh_magic_64: u32 = std.macho.MH_MAGIC_64;
const fat_magic: u32 = std.macho.FAT_MAGIC;
const fat_magic_64: u32 = std.macho.FAT_MAGIC_64;
const header_size = 32; // mach_header_64
const fat_header_size = 8;
const fat_arch_size = 20;
const fat_arch_64_size = 32;
const nlist_size = 16; // nlist_64
const segment_command_size = 72; // segment_command_64
const section_size = 80; // section_64
const platform_macos = 1;

fn lc(c: LC) u32 {
    return @backingInt(c);
}

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn readU64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

fn readU32Be(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

fn readU64Be(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .big);
}

/// Writes one sentence into `diag`, NUL-terminated, cut to fit if too long.
/// Same form as `elf.setDiag`; repeated here so this file imports only std.
fn setDiag(diag: ?*[256]u8, comptime fmt: []const u8, args: anytype) void {
    const d = diag orelse return;
    @memset(d, 0);
    var w: std.Io.Writer = .fixed(d[0..255]);
    w.print(fmt, args) catch {};
}

fn diagSpan(d: *const [256]u8) []const u8 {
    return std.mem.sliceTo(d, 0);
}

const Kind = enum { thin, fat32, fat64 };

/// What the first bytes say the file is. A file shorter than 4 bytes that
/// starts like a known magic number is `Truncated`.
fn kindOf(bytes: []const u8, diag: ?*[256]u8) Error!Kind {
    const known = [_]struct { m: [4]u8, k: Kind }{
        .{ .m = .{ 0xcf, 0xfa, 0xed, 0xfe }, .k = .thin },
        .{ .m = .{ 0xca, 0xfe, 0xba, 0xbe }, .k = .fat32 },
        .{ .m = .{ 0xca, 0xfe, 0xba, 0xbf }, .k = .fat64 },
    };
    for (known) |e| {
        if (bytes.len >= 4) {
            if (std.mem.eql(u8, bytes[0..4], &e.m)) return e.k;
        } else if (std.mem.startsWith(u8, &e.m, bytes)) {
            setDiag(diag, "The Mach-O file is truncated: it has {d} bytes, the magic number needs 4.", .{bytes.len});
            return error.Truncated;
        }
    }
    if (bytes.len >= 4) {
        const le = readU32(bytes, 0);
        if (le == std.macho.MH_MAGIC or le == std.macho.MH_CIGAM or le == std.macho.MH_CIGAM_64 or
            le == std.macho.FAT_MAGIC or le == std.macho.FAT_MAGIC_64)
        {
            setDiag(diag, "The Mach-O file has the magic 0x{x}: only 64-bit little-endian images and big-endian fat files are supported.", .{le});
            return error.BadHeader;
        }
    }
    setDiag(diag, "The file is not a Mach-O file: it has no Mach-O magic number ({d} bytes).", .{bytes.len});
    return error.NotMachO;
}

/// One load command: its type and all of its `cmdsize` bytes.
const Command = struct { cmd: u32, data: []const u8 };

/// A thin image whose header and load commands were checked by `parse`.
const Image = struct {
    bytes: []const u8,
    cpu: Cpu,
    ncmds: u32,

    /// Checks the header, every load command's size, and every file range
    /// a load command names (segments, sections, symbol and string tables,
    /// dyld info, linkedit data). `in_fat`: a slice of a fat file, where any
    /// magic but a 64-bit image's is `BadHeader`.
    fn parse(bytes: []const u8, in_fat: bool, diag: ?*[256]u8) Error!Image {
        const kind = kindOf(bytes, diag) catch |e| return if (in_fat and e == error.NotMachO) error.BadHeader else e;
        if (kind != .thin) {
            setDiag(diag, "The Mach-O image is a fat file, not one thin image.", .{});
            return if (in_fat) error.BadHeader else error.NotMachO;
        }
        const len: u64 = bytes.len;
        if (len < header_size) {
            setDiag(diag, "The Mach-O file is truncated: it has {d} bytes, the header needs {d}.", .{ len, header_size });
            return error.Truncated;
        }
        const ncmds = readU32(bytes, 16);
        const sizeofcmds: u64 = readU32(bytes, 20);
        const cmds_end = header_size + sizeofcmds;
        if (cmds_end > len) {
            setDiag(diag, "The Mach-O file is truncated: the load commands end at byte {d}, the file has {d} bytes.", .{ cmds_end, len });
            return error.Truncated;
        }
        if (@as(u64, ncmds) * 8 > sizeofcmds) {
            setDiag(diag, "The Mach-O header names {d} load commands in {d} bytes.", .{ ncmds, sizeofcmds });
            return error.BadHeader;
        }
        const img: Image = .{
            .bytes = bytes,
            .cpu = @fromBackingInt(@intCast(readU32(bytes, 4))),
            .ncmds = ncmds,
        };
        var off: u64 = header_size;
        var i: u32 = 0;
        while (i < ncmds) : (i += 1) {
            if (off + 8 > cmds_end) {
                setDiag(diag, "Mach-O load command {d} starts past the load command area.", .{i});
                return error.BadHeader;
            }
            const cmdsize: u64 = readU32(bytes, @intCast(off + 4));
            if (cmdsize < 8 or cmdsize % 8 != 0 or off + cmdsize > cmds_end) {
                setDiag(diag, "Mach-O load command {d} has the bad size {d}.", .{ i, cmdsize });
                return error.BadHeader;
            }
            const c: Command = .{ .cmd = readU32(bytes, @intCast(off)), .data = bytes[@intCast(off)..@intCast(off + cmdsize)] };
            try checkCommand(c, i, len, diag);
            off += cmdsize;
        }
        return img;
    }

    fn commands(self: Image) CommandIterator {
        return .{ .bytes = self.bytes, .off = header_size, .left = self.ncmds };
    }

    /// The first load command of type `cmd` (its full bytes), or null.
    fn find(self: Image, cmd: u32) ?[]const u8 {
        var it = self.commands();
        while (it.next()) |c| if (c.cmd == cmd) return c.data;
        return null;
    }
};

/// Walks the load commands of an image that `Image.parse` accepted.
const CommandIterator = struct {
    bytes: []const u8,
    off: usize,
    left: u32,

    fn next(it: *CommandIterator) ?Command {
        if (it.left == 0) return null;
        it.left -= 1;
        const size = readU32(it.bytes, it.off + 4);
        const c: Command = .{ .cmd = readU32(it.bytes, it.off), .data = it.bytes[it.off..][0..size] };
        it.off += size;
        return c;
    }
};

/// The minimum `cmdsize` of the commands whose fields `checkCommand` reads.
fn minSize(cmd: u32) u32 {
    return switch (cmd) {
        lc(.SEGMENT_64) => segment_command_size,
        lc(.SYMTAB) => 24,
        lc(.DYSYMTAB) => 80,
        lc(.DYLD_INFO), lc(.DYLD_INFO_ONLY) => 48,
        lc(.CODE_SIGNATURE), lc(.SEGMENT_SPLIT_INFO), lc(.FUNCTION_STARTS), lc(.DATA_IN_CODE), lc(.DYLIB_CODE_SIGN_DRS), lc(.LINKER_OPTIMIZATION_HINT), lc(.DYLD_EXPORTS_TRIE), lc(.DYLD_CHAINED_FIXUPS), lc_atom_info => 16,
        lc(.ENCRYPTION_INFO_64) => 24,
        lc(.TWOLEVEL_HINTS) => 16,
        lc(.NOTE) => 40,
        lc(.BUILD_VERSION) => 24,
        lc(.VERSION_MIN_MACOSX) => 16,
        else => 8,
    };
}

/// `LC_ATOM_INFO` (linkedit data); not in `std.macho.LC`.
const lc_atom_info: u32 = 0x36;

/// Checks that one file range lies inside the image.
fn checkRange(what: []const u8, i: u32, off: u64, size: u64, len: u64, diag: ?*[256]u8) Error!void {
    if (size == 0) return;
    const end = std.math.add(u64, off, size) catch std.math.maxInt(u64);
    if (end > len) {
        setDiag(diag, "The Mach-O file is truncated: the {s} of load command {d} ends at byte {d}, the file has {d} bytes.", .{ what, i, end, len });
        return error.Truncated;
    }
}

fn checkCommand(c: Command, i: u32, len: u64, diag: ?*[256]u8) Error!void {
    const d = c.data;
    if (d.len < minSize(c.cmd)) {
        setDiag(diag, "Mach-O load command {d} (0x{x}) is {d} bytes, it needs {d}.", .{ i, c.cmd, d.len, minSize(c.cmd) });
        return error.BadHeader;
    }
    switch (c.cmd) {
        lc(.SEGMENT_64) => {
            try checkRange("segment", i, readU64(d, 40), readU64(d, 48), len, diag);
            const nsects: u64 = readU32(d, 64);
            if (segment_command_size + nsects * section_size > d.len) {
                setDiag(diag, "Mach-O segment command {d} names {d} sections but has room for {d}.", .{ i, nsects, (d.len - segment_command_size) / section_size });
                return error.BadHeader;
            }
            for (0..@intCast(nsects)) |k| {
                const s = d[segment_command_size + k * section_size ..][0..section_size];
                const kind = readU32(s, 64) & 0xff;
                if (kind == std.macho.S_ZEROFILL or kind == std.macho.S_GB_ZEROFILL or kind == std.macho.S_THREAD_LOCAL_ZEROFILL) continue;
                try checkRange("section", i, readU32(s, 48), readU64(s, 40), len, diag);
                try checkRange("relocations", i, readU32(s, 56), @as(u64, readU32(s, 60)) * 8, len, diag);
            }
        },
        lc(.SYMTAB) => {
            try checkRange("symbol table", i, readU32(d, 8), @as(u64, readU32(d, 12)) * nlist_size, len, diag);
            try checkRange("string table", i, readU32(d, 16), readU32(d, 20), len, diag);
        },
        lc(.DYSYMTAB) => {
            // (offset field, count field, entry size) of each table.
            const tables = [_][3]u32{ .{ 32, 36, 8 }, .{ 40, 44, 56 }, .{ 48, 52, 4 }, .{ 56, 60, 4 }, .{ 64, 68, 8 }, .{ 72, 76, 8 } };
            for (tables) |t| try checkRange("dynamic symbol table", i, readU32(d, t[0]), @as(u64, readU32(d, t[1])) * t[2], len, diag);
        },
        lc(.DYLD_INFO), lc(.DYLD_INFO_ONLY) => {
            var k: usize = 8;
            while (k < 48) : (k += 8) try checkRange("dyld info", i, readU32(d, k), readU32(d, k + 4), len, diag);
        },
        lc(.CODE_SIGNATURE), lc(.SEGMENT_SPLIT_INFO), lc(.FUNCTION_STARTS), lc(.DATA_IN_CODE), lc(.DYLIB_CODE_SIGN_DRS), lc(.LINKER_OPTIMIZATION_HINT), lc(.DYLD_EXPORTS_TRIE), lc(.DYLD_CHAINED_FIXUPS), lc_atom_info => {
            try checkRange("linkedit data", i, readU32(d, 8), readU32(d, 12), len, diag);
        },
        lc(.TWOLEVEL_HINTS) => try checkRange("two-level hints", i, readU32(d, 8), @as(u64, readU32(d, 12)) * 4, len, diag),
        lc(.ENCRYPTION_INFO_64) => try checkRange("encrypted range", i, readU32(d, 8), readU32(d, 12), len, diag),
        lc(.NOTE) => try checkRange("note", i, readU64(d, 24), readU64(d, 32), len, diag),
        lc(.BUILD_VERSION) => {
            const ntools: u64 = readU32(d, 20);
            if (24 + ntools * 8 > d.len) {
                setDiag(diag, "Mach-O build version command {d} names {d} tools but has room for {d}.", .{ i, ntools, (d.len - 24) / 8 });
                return error.BadHeader;
            }
        },
        else => {},
    }
}

/// The fat header's arch entry `i` (caller checked the table is in the file).
fn fatEntry(bytes: []const u8, wide: bool, i: usize) Slice {
    if (wide) {
        const e = fat_header_size + i * fat_arch_64_size;
        return .{ .cpu = @fromBackingInt(@intCast(readU32Be(bytes, e))), .offset = readU64Be(bytes, e + 8), .size = readU64Be(bytes, e + 16) };
    }
    const e = fat_header_size + i * fat_arch_size;
    return .{ .cpu = @fromBackingInt(@intCast(readU32Be(bytes, e))), .offset = readU32Be(bytes, e + 8), .size = readU32Be(bytes, e + 12) };
}

/// Checks a fat file's header and arch table: each slice is inside the
/// file, after the table, not empty, and overlaps no other slice. Returns
/// the slice count. Does not look inside the slices.
fn checkFatTable(bytes: []const u8, wide: bool, diag: ?*[256]u8) Error!usize {
    const len: u64 = bytes.len;
    if (len < fat_header_size) {
        setDiag(diag, "The fat Mach-O file is truncated: it has {d} bytes, the fat header needs {d}.", .{ len, fat_header_size });
        return error.Truncated;
    }
    const n = readU32Be(bytes, 4);
    if (n == 0 or n > max_fat_arches) {
        setDiag(diag, "The fat Mach-O file names {d} slices; between 1 and {d} are allowed.", .{ n, max_fat_arches });
        return error.BadHeader;
    }
    const entry: u64 = if (wide) fat_arch_64_size else fat_arch_size;
    const table_end = fat_header_size + n * entry;
    if (table_end > len) {
        setDiag(diag, "The fat Mach-O file is truncated: the arch table ends at byte {d}, the file has {d} bytes.", .{ table_end, len });
        return error.Truncated;
    }
    for (0..n) |i| {
        const s = fatEntry(bytes, wide, i);
        if (s.size == 0 or s.offset < table_end) {
            setDiag(diag, "Slice {d} of the fat Mach-O file is empty or starts inside the fat header (offset {d}).", .{ i, s.offset });
            return error.BadHeader;
        }
        const end = std.math.add(u64, s.offset, s.size) catch std.math.maxInt(u64);
        if (end > len) {
            setDiag(diag, "The fat Mach-O file is truncated: slice {d} ends at byte {d}, the file has {d} bytes.", .{ i, end, len });
            return error.Truncated;
        }
        for (0..i) |k| {
            const o = fatEntry(bytes, wide, k);
            if (s.offset < o.offset + o.size and o.offset < end) {
                setDiag(diag, "Slices {d} and {d} of the fat Mach-O file overlap.", .{ k, i });
                return error.BadHeader;
            }
        }
    }
    return n;
}

/// Refuses a file that is not a complete Mach-O file. A thin file must be
/// a 64-bit little-endian image whose header, load commands and every file
/// range they name (segments, sections, symbol and string tables, dyld
/// info, export trie, chained fixups, code signature, ...) lie inside the
/// file. A fat file must have a complete arch table whose slices lie inside
/// the file without overlapping, and every slice must be such an image of
/// the CPU type its arch entry names. The Mach-O version of
/// `pe.checkComplete`.
pub fn checkComplete(bytes: []const u8) Error!void {
    return checkCompleteDiag(bytes, null);
}

/// `checkComplete` that also writes one sentence about the problem into
/// `diag` (NUL-terminated; `elf.diagText` reads it).
pub fn checkCompleteDiag(bytes: []const u8, diag: ?*[256]u8) Error!void {
    const kind = try kindOf(bytes, diag);
    if (kind == .thin) {
        _ = try Image.parse(bytes, false, diag);
        return;
    }
    const wide = kind == .fat64;
    const n = try checkFatTable(bytes, wide, diag);
    for (0..n) |i| {
        const s = fatEntry(bytes, wide, i);
        const sb = bytes[@intCast(s.offset)..][0..@intCast(s.size)];
        var inner: [256]u8 = @splat(0);
        const img = Image.parse(sb, true, &inner) catch |e| {
            setDiag(diag, "Slice {d} of the fat Mach-O file (at byte {d}): {s}", .{ i, s.offset, diagSpan(&inner) });
            return e;
        };
        if (img.cpu != s.cpu) {
            setDiag(diag, "Slice {d} of the fat Mach-O file has the CPU type 0x{x}, its arch entry says 0x{x}.", .{ i, @backingInt(img.cpu), @backingInt(s.cpu) });
            return error.BadHeader;
        }
    }
}

/// The slices of a file: one per arch entry of a fat file, or one covering
/// a whole thin file. Checks the fat header and arch table (as
/// `checkComplete` does) and a thin file's header, but not the contents of
/// each slice; call `checkComplete` for that. The caller frees the result.
pub fn slices(a: Allocator, bytes: []const u8) (Error || Allocator.Error)![]Slice {
    const kind = try kindOf(bytes, null);
    if (kind == .thin) {
        if (bytes.len < header_size) return error.Truncated;
        const out = try a.alloc(Slice, 1);
        out[0] = .{ .cpu = @fromBackingInt(@intCast(readU32(bytes, 4))), .offset = 0, .size = bytes.len };
        return out;
    }
    const wide = kind == .fat64;
    const n = try checkFatTable(bytes, wide, null);
    const out = try a.alloc(Slice, n);
    for (out, 0..) |*s, i| s.* = fatEntry(bytes, wide, i);
    return out;
}

/// The NUL-terminated string at `off` in `table`, without the NUL. The scan
/// stops after `max_name_len + 1` bytes: `error.TooLarge` when no NUL is
/// found within that, `error.BadHeader` when the table ends first.
fn stringAt(table: []const u8, off: u64) (Error || error{TooLarge})![]const u8 {
    if (off >= table.len) return error.BadHeader;
    const t = table[@intCast(off)..];
    const window = t[0..@min(t.len, max_name_len + 1)];
    const end = std.mem.indexOfScalar(u8, window, 0) orelse
        return if (t.len > max_name_len) error.TooLarge else error.BadHeader;
    return t[0..end];
}

/// Reads an unsigned LEB128 number at `p.*` and moves `p` past it.
fn uleb(b: []const u8, p: *usize) Error!u64 {
    var v: u64 = 0;
    var shift: u32 = 0;
    while (true) {
        if (p.* >= b.len) return error.BadHeader;
        const byte = b[p.*];
        p.* += 1;
        const bits: u64 = byte & 0x7f;
        if (shift >= 64 or (shift > 0 and bits >> @intCast(64 - shift) != 0)) return error.BadHeader;
        v |= bits << @intCast(shift);
        if (byte & 0x80 == 0) return v;
        shift += 7;
    }
}

fn appendName(a: Allocator, out: *std.ArrayList([]const u8), budget: *Budget, name: []const u8) ListError!void {
    try budget.take(name.len);
    try out.ensureUnusedCapacity(a, 1);
    out.appendAssumeCapacity(try a.dupe(u8, name));
}

fn freeArrayList(a: Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| a.free(s);
    list.deinit(a);
}

/// The export trie of an image, or null when it has none (or an empty one).
fn exportTrie(img: Image) ?[]const u8 {
    var off: u32 = 0;
    var size: u32 = 0;
    if (img.find(lc(.DYLD_EXPORTS_TRIE))) |d| {
        off = readU32(d, 8);
        size = readU32(d, 12);
    } else if (img.find(lc(.DYLD_INFO_ONLY)) orelse img.find(lc(.DYLD_INFO))) |d| {
        off = readU32(d, 40);
        size = readU32(d, 44);
    }
    if (size == 0) return null;
    return img.bytes[off..][0..size]; // in the file: `Image.parse` checked it
}

/// The exported symbol names of one thin image (`slice_bytes`), with
/// Mach-O's leading underscore (`_answer`). They come from the export trie
/// (`LC_DYLD_EXPORTS_TRIE`, or the export part of `LC_DYLD_INFO(_ONLY)`),
/// which is what dyld reads: every terminal node, re-exports included. An
/// image without a trie falls back to the symbol table's external defined
/// symbols. The caller frees the result with `freeList`.
pub fn exports(a: Allocator, slice_bytes: []const u8) ListError![]const []const u8 {
    const img = try Image.parse(slice_bytes, false, null);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeArrayList(a, &out);
    var budget: Budget = .{};
    if (exportTrie(img)) |trie| {
        try walkTrie(a, trie, &out, &budget);
    } else {
        try symbols(a, img, .defined, &out, &budget);
    }
    return out.toOwnedSlice(a);
}

/// Lists every terminal node of an export trie. The trie must be a tree:
/// a node reached twice (a cycle, or two edges to one node) or an empty
/// edge label is `BadHeader`. Each node is visited once, so the work is
/// linear in the trie size; the name length cap bounds the depth.
fn walkTrie(a: Allocator, trie: []const u8, out: *std.ArrayList([]const u8), budget: *Budget) ListError!void {
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(a, trie.len);
    defer seen.deinit(a);
    // A node to visit: where it is, how long its parent's name is, and the
    // edge label that leads to it (copied in when it is visited, so the
    // name buffer always holds the current node's name).
    const Pending = struct { node: usize, parent_len: usize, label: []const u8 };
    var stack: std.ArrayList(Pending) = .empty;
    defer stack.deinit(a);
    var name: [max_name_len]u8 = undefined;

    seen.set(0);
    try stack.append(a, .{ .node = 0, .parent_len = 0, .label = "" });
    while (stack.pop()) |pend| {
        const name_len = pend.parent_len + pend.label.len;
        if (name_len > max_name_len) return error.TooLarge;
        @memcpy(name[pend.parent_len..name_len], pend.label);

        var p = pend.node;
        const terminal_size = try uleb(trie, &p);
        if (terminal_size > trie.len - p) return error.BadHeader;
        if (terminal_size > 0) try appendName(a, out, budget, name[0..name_len]);
        p += @intCast(terminal_size);
        if (p >= trie.len) return error.BadHeader;
        const children = trie[p];
        p += 1;
        for (0..children) |_| {
            const label = stringAt(trie, p) catch |e| return switch (e) {
                error.TooLarge => error.TooLarge,
                else => error.BadHeader,
            };
            if (label.len == 0) return error.BadHeader;
            p += label.len + 1;
            const child = try uleb(trie, &p);
            if (child >= trie.len) return error.BadHeader;
            const c: usize = @intCast(child);
            if (seen.isSet(c)) return error.BadHeader;
            seen.set(c);
            try stack.append(a, .{ .node = c, .parent_len = name_len, .label = label });
        }
    }
}

const SymbolKind = enum { defined, undefined };

/// Appends the names of the external symbols of the symbol table that are
/// defined (not private extern) or undefined. Debug (stab) entries are
/// skipped.
fn symbols(a: Allocator, img: Image, kind: SymbolKind, out: *std.ArrayList([]const u8), budget: *Budget) ListError!void {
    const d = img.find(lc(.SYMTAB)) orelse return;
    const symoff = readU32(d, 8);
    const nsyms = readU32(d, 12);
    const strsize = readU32(d, 20);
    // In the file when not empty: `Image.parse` checked it.
    const strtab: []const u8 = if (strsize == 0) &.{} else img.bytes[readU32(d, 16)..][0..strsize];
    for (0..nsyms) |k| {
        const e = img.bytes[symoff + k * nlist_size ..][0..nlist_size];
        const n_type = e[4];
        if (n_type & std.macho.N_STAB != 0 or n_type & std.macho.N_EXT == 0) continue;
        const t = n_type & std.macho.N_TYPE;
        const is_undef = t == std.macho.N_UNDF or t == std.macho.N_PBUD;
        const want = switch (kind) {
            .defined => !is_undef and n_type & std.macho.N_PEXT == 0,
            .undefined => is_undef,
        };
        if (!want) continue;
        try appendName(a, out, budget, try stringAt(strtab, readU32(e, 0)));
    }
}

/// The imported symbol names of one thin image (`slice_bytes`): the
/// symbol table's undefined external symbols, with the leading underscore
/// (`_getpid`). It does not read bind opcodes or chained fixups, so it is
/// complete for linker output but not proof against a crafted file that
/// binds a symbol with no undefined symbol table entry. Zig's Mach-O
/// linker writes `LC_DYLD_INFO_ONLY` bind
/// opcodes, not chained fixups, and every bound symbol is also an undefined
/// symbol table entry. The caller frees the result with `freeList`.
pub fn imports(a: Allocator, slice_bytes: []const u8) ListError![]const []const u8 {
    const img = try Image.parse(slice_bytes, false, null);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeArrayList(a, &out);
    var budget: Budget = .{};
    try symbols(a, img, .undefined, &out, &budget);
    return out.toOwnedSlice(a);
}

/// Frees a list from `exports` or `imports`.
pub fn freeList(a: Allocator, list: []const []const u8) void {
    for (list) |s| a.free(s);
    a.free(list);
}

/// The minimum macOS version of one thin image: `minos` of its first
/// `LC_BUILD_VERSION` for the macOS platform, else the version of
/// `LC_VERSION_MIN_MACOSX`. Null when it has neither, or when the image is
/// not complete (see `checkComplete`).
pub fn minOs(slice_bytes: []const u8) ?std.SemanticVersion {
    const img = Image.parse(slice_bytes, false, null) catch return null;
    var it = img.commands();
    var old: ?u32 = null;
    while (it.next()) |c| {
        if (c.cmd == lc(.BUILD_VERSION) and readU32(c.data, 8) == platform_macos) return version(readU32(c.data, 12));
        if (c.cmd == lc(.VERSION_MIN_MACOSX) and old == null) old = readU32(c.data, 8);
    }
    return if (old) |v| version(v) else null;
}

/// A Mach-O packed version: `xxxx.yy.zz` in the bytes of a u32.
fn version(v: u32) std.SemanticVersion {
    return .{ .major = v >> 16, .minor = (v >> 8) & 0xff, .patch = v & 0xff };
}

/// The code signature blob of one thin image (`LC_CODE_SIGNATURE`), or
/// null when it has none or the image is not complete. A returned range
/// always lies inside `slice_bytes`.
pub fn codeSignature(slice_bytes: []const u8) ?CodeSignature {
    const img = Image.parse(slice_bytes, false, null) catch return null;
    const d = img.find(lc(.CODE_SIGNATURE)) orelse return null;
    const size = readU32(d, 12);
    if (size == 0) return null;
    return .{ .offset = readU32(d, 8), .size = size };
}

// Forged images. The tests against real dylibs are in `macho_test.zig`.

/// Test helper: a thin arm64 image with the given load commands (each a
/// whole command, its size a multiple of 8) and `tail` zero bytes after
/// them. The caller frees the result.
fn forge(a: Allocator, cmds: []const []const u8, tail: usize) ![]u8 {
    var size: usize = 0;
    for (cmds) |c| size += c.len;
    const b = try a.alloc(u8, header_size + size + tail);
    @memset(b, 0);
    std.mem.writeInt(u32, b[0..4], mh_magic_64, .little);
    std.mem.writeInt(u32, b[4..8], std.macho.CPU_TYPE_ARM64, .little);
    std.mem.writeInt(u32, b[12..16], std.macho.MH_DYLIB, .little);
    std.mem.writeInt(u32, b[16..20], @intCast(cmds.len), .little);
    std.mem.writeInt(u32, b[20..24], @intCast(size), .little);
    var off: usize = header_size;
    for (cmds) |c| {
        @memcpy(b[off..][0..c.len], c);
        off += c.len;
    }
    return b;
}

/// Test helper: a load command of type `cmd` with `fields` as u32 words
/// after `cmd` and `cmdsize`, padded to a multiple of 8.
fn command(cmd: u32, comptime n: usize, fields: [n]u32) [std.mem.alignForward(usize, 8 + 4 * n, 8)]u8 {
    var b: [std.mem.alignForward(usize, 8 + 4 * n, 8)]u8 = @splat(0);
    std.mem.writeInt(u32, b[0..4], cmd, .little);
    std.mem.writeInt(u32, b[4..8], b.len, .little);
    for (fields, 0..) |f, i| std.mem.writeInt(u32, b[8 + 4 * i ..][0..4], f, .little);
    return b;
}

test "not a Mach-O file" {
    try std.testing.expectError(error.NotMachO, checkComplete("hello, world, this is not a Mach-O file at all"));
    try std.testing.expectError(error.NotMachO, checkComplete("X"));
    try std.testing.expectError(error.NotMachO, checkComplete("MZ\x90\x00"));
    try std.testing.expectError(error.Truncated, checkComplete(""));
    try std.testing.expectError(error.Truncated, checkComplete("\xcf\xfa"));
    try std.testing.expectError(error.Truncated, checkComplete("\xca\xfe\xba"));
    // 32-bit and big-endian images are not supported.
    try std.testing.expectError(error.BadHeader, checkComplete("\xce\xfa\xed\xfe" ++ @as([28]u8, @splat(0))));
    try std.testing.expectError(error.BadHeader, checkComplete("\xfe\xed\xfa\xcf" ++ @as([28]u8, @splat(0))));
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, checkCompleteDiag("\xcf\xfa\xed\xfe\x00", &diag));
    try std.testing.expect(std.mem.indexOf(u8, diagSpan(&diag), "truncated") != null);
}

test "forged images: load command sizes and ranges" {
    const a = std.testing.allocator;
    {
        // No load commands: complete.
        const b = try forge(a, &.{}, 0);
        defer a.free(b);
        try checkComplete(b);
    }
    {
        // A linkedit range one byte past the end.
        const sig = command(lc(.CODE_SIGNATURE), 2, .{ 48, 33 });
        const b = try forge(a, &.{&sig}, 32);
        defer a.free(b);
        try std.testing.expectError(error.Truncated, checkComplete(b));
        try std.testing.expect(codeSignature(b) == null);
        std.mem.writeInt(u32, b[header_size + 12 ..][0..4], 32, .little);
        try checkComplete(b);
        try std.testing.expectEqual(CodeSignature{ .offset = 48, .size = 32 }, codeSignature(b).?);
    }
    {
        // A range whose sum overflows 32 bits is past the end, not wrapped.
        const st = command(lc(.SYMTAB), 4, .{ 0, 0, 0xffff_fff0, 0x20 });
        const b = try forge(a, &.{&st}, 0);
        defer a.free(b);
        try std.testing.expectError(error.Truncated, checkComplete(b));
    }
    {
        // A command size that is not a multiple of 8, or too small.
        var c = command(lc(.UUID), 4, .{ 0, 0, 0, 0 });
        std.mem.writeInt(u32, c[4..8], 12, .little);
        const b = try forge(a, &.{&c}, 0);
        defer a.free(b);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
        std.mem.writeInt(u32, b[header_size + 4 ..][0..4], 0, .little);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
    }
    {
        // More commands than fit in sizeofcmds.
        const b = try forge(a, &.{}, 8);
        defer a.free(b);
        std.mem.writeInt(u32, b[16..20], 2, .little);
        std.mem.writeInt(u32, b[20..24], 8, .little);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
    }
    {
        // A segment naming more sections than it holds.
        const fields = comptime blk: {
            var f: [16]u32 = @splat(0);
            f[14] = 5; // nsects
            break :blk f;
        };
        const seg = command(lc(.SEGMENT_64), 16, fields);
        const b = try forge(a, &.{&seg}, 0);
        defer a.free(b);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
    }
}

test "forged images: minimum macOS version" {
    const a = std.testing.allocator;
    {
        const bv = command(lc(.BUILD_VERSION), 4, .{ platform_macos, 0x000b_0000, 0x000e_0000, 0 });
        const b = try forge(a, &.{&bv}, 0);
        defer a.free(b);
        try std.testing.expectEqual(std.SemanticVersion{ .major = 11, .minor = 0, .patch = 0 }, minOs(b).?);
    }
    {
        // An iOS build version is not a macOS one; the old command counts.
        const bv = command(lc(.BUILD_VERSION), 4, .{ 2, 0x000b_0000, 0, 0 });
        const vm = command(lc(.VERSION_MIN_MACOSX), 2, .{ 0x000a_0f02, 0 });
        const b = try forge(a, &.{ &bv, &vm }, 0);
        defer a.free(b);
        try std.testing.expectEqual(std.SemanticVersion{ .major = 10, .minor = 15, .patch = 2 }, minOs(b).?);
    }
    {
        const b = try forge(a, &.{}, 0);
        defer a.free(b);
        try std.testing.expect(minOs(b) == null);
        try std.testing.expect(codeSignature(b) == null);
    }
}

/// Test helper: an image whose only load command is `LC_DYLD_EXPORTS_TRIE`
/// naming `trie`, which follows the commands.
fn forgeTrie(a: Allocator, trie: []const u8) ![]u8 {
    const off: u32 = header_size + 16;
    const c = command(lc(.DYLD_EXPORTS_TRIE), 2, .{ off, 0 });
    const b = try forge(a, &.{&c}, trie.len);
    std.mem.writeInt(u32, b[header_size + 12 ..][0..4], @intCast(trie.len), .little);
    @memcpy(b[off..][0..trie.len], trie);
    return b;
}

test "forged images: export trie" {
    const a = std.testing.allocator;
    {
        // Root -"_a"-> node 11 (terminal) and -"_b"-> node 15 (terminal).
        const trie = "\x00\x02_a\x00\x0b_b\x00\x0f" ++ "\x00" ++ "\x02\x00\x10\x00" ++ "\x02\x00\x20\x00";
        const b = try forgeTrie(a, trie);
        defer a.free(b);
        const ex = try exports(a, b);
        defer freeList(a, ex);
        try std.testing.expectEqual(@as(usize, 2), ex.len);
        try std.testing.expect(std.mem.eql(u8, ex[0], "_b") or std.mem.eql(u8, ex[1], "_b"));
        try std.testing.expect(std.mem.eql(u8, ex[0], "_a") or std.mem.eql(u8, ex[1], "_a"));
    }
    {
        // A child edge back to the root: a cycle.
        const b = try forgeTrie(a, "\x00\x01_a\x00\x00");
        defer a.free(b);
        try std.testing.expectError(error.BadHeader, exports(a, b));
    }
    {
        // Two edges to one node.
        const b = try forgeTrie(a, "\x00\x02_a\x00\x0a_b\x00\x0a\x00\x00");
        defer a.free(b);
        try std.testing.expectError(error.BadHeader, exports(a, b));
    }
    {
        // An empty edge label, a child past the end, a terminal past the end,
        // and a LEB128 number that never ends.
        for ([_][]const u8{ "\x00\x01\x00\x04\x00\x00", "\x00\x01_a\x00\x40", "\x05\x00", "\x80\x80\x80" }) |t| {
            const b = try forgeTrie(a, t);
            defer a.free(b);
            try std.testing.expectError(error.BadHeader, exports(a, b));
        }
    }
    {
        // A chain of nodes whose name passes `max_name_len`: each node has
        // one child with a one-byte label, 5,000 deep.
        const depth = 5000;
        var trie: std.ArrayList(u8) = .empty;
        defer trie.deinit(a);
        for (0..depth) |i| {
            // Node i at offset 8 * i: no terminal, one child "x" at 8 * (i + 1).
            var node: [8]u8 = @splat(0);
            node[1] = 1;
            node[2] = 'x';
            var w: std.Io.Writer = .fixed(node[4..]);
            try w.writeUleb128(8 * (i + 1));
            try trie.appendSlice(a, &node);
        }
        try trie.appendSlice(a, &.{ 1, 0, 0 }); // a terminal leaf
        const b = try forgeTrie(a, trie.items);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, exports(a, b));
    }
}

/// Test helper: an image with a symbol table of `n` external defined
/// symbols that all name one string of `name_len` bytes.
fn forgeSymbols(a: Allocator, n: u32, name_len: u32, n_type: u8) ![]u8 {
    const symoff: u32 = header_size + 24;
    const stroff = symoff + n * nlist_size;
    const strsize = name_len + 2;
    const st = command(lc(.SYMTAB), 4, .{ symoff, n, stroff, strsize });
    const b = try forge(a, &.{&st}, n * nlist_size + strsize);
    for (0..n) |k| {
        const e = b[symoff + k * nlist_size ..][0..nlist_size];
        std.mem.writeInt(u32, e[0..4], 1, .little);
        e[4] = n_type;
    }
    @memset(b[stroff + 1 ..][0..name_len], 's');
    return b;
}

test "forged images: symbol table" {
    const a = std.testing.allocator;
    const defined = std.macho.N_EXT | std.macho.N_SECT;
    const undefined_ext = std.macho.N_EXT | std.macho.N_UNDF;
    {
        const b = try forgeSymbols(a, 3, 4, defined);
        defer a.free(b);
        const ex = try exports(a, b);
        defer freeList(a, ex);
        try std.testing.expectEqual(@as(usize, 3), ex.len);
        try std.testing.expectEqualStrings("ssss", ex[0]);
        const im = try imports(a, b);
        defer freeList(a, im);
        try std.testing.expectEqual(@as(usize, 0), im.len);
    }
    {
        const b = try forgeSymbols(a, 2, 4, undefined_ext);
        defer a.free(b);
        const im = try imports(a, b);
        defer freeList(a, im);
        try std.testing.expectEqual(@as(usize, 2), im.len);
        const ex = try exports(a, b);
        defer freeList(a, ex);
        try std.testing.expectEqual(@as(usize, 0), ex.len);
    }
    {
        // Private extern symbols are not exported.
        const b = try forgeSymbols(a, 1, 4, defined | std.macho.N_PEXT);
        defer a.free(b);
        const ex = try exports(a, b);
        defer freeList(a, ex);
        try std.testing.expectEqual(@as(usize, 0), ex.len);
    }
    // 5,000 x 4,000 bytes = 20 MB of output, over `max_output_bytes`.
    {
        const b = try forgeSymbols(a, 5000, 4000, defined);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, exports(a, b));
    }
    // One name longer than `max_name_len`, and more than `max_entries`.
    {
        const b = try forgeSymbols(a, 1, max_name_len + 1, undefined_ext);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, imports(a, b));
    }
    {
        const b = try forgeSymbols(a, max_entries + 1, 1, undefined_ext);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, imports(a, b));
    }
    {
        // A name offset past the string table.
        const b = try forgeSymbols(a, 1, 4, defined);
        defer a.free(b);
        std.mem.writeInt(u32, b[header_size + 24 ..][0..4], 100, .little);
        try std.testing.expectError(error.BadHeader, exports(a, b));
    }
}

/// Test helper: a fat file (32-bit arch table) holding `thins`, each at
/// the next multiple of 64 bytes.
fn forgeFat(a: Allocator, thins: []const []const u8) ![]u8 {
    var end: usize = fat_header_size + fat_arch_size * thins.len;
    var offs: [4]usize = undefined;
    for (thins, 0..) |t, i| {
        offs[i] = std.mem.alignForward(usize, end, 64);
        end = offs[i] + t.len;
    }
    const b = try a.alloc(u8, end);
    @memset(b, 0);
    std.mem.writeInt(u32, b[0..4], fat_magic, .big);
    std.mem.writeInt(u32, b[4..8], @intCast(thins.len), .big);
    for (thins, 0..) |t, i| {
        const e = fat_header_size + fat_arch_size * i;
        std.mem.writeInt(u32, b[e..][0..4], readU32(t, 4), .big);
        std.mem.writeInt(u32, b[e + 8 ..][0..4], @intCast(offs[i]), .big);
        std.mem.writeInt(u32, b[e + 12 ..][0..4], @intCast(t.len), .big);
        @memcpy(b[offs[i]..][0..t.len], t);
    }
    return b;
}

test "forged fat files: table checks" {
    const a = std.testing.allocator;
    const thin = try forge(a, &.{}, 32);
    defer a.free(thin);
    {
        const b = try forgeFat(a, &.{ thin, thin });
        defer a.free(b);
        try checkComplete(b);
        // Overlapping slices: the second starts inside the first.
        std.mem.writeInt(u32, b[fat_header_size + fat_arch_size + 8 ..][0..4], 64 + 8, .big);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
        try std.testing.expectError(error.BadHeader, slices(a, b));
    }
    {
        const b = try forgeFat(a, &.{thin});
        defer a.free(b);
        // A slice past the end of the file.
        std.mem.writeInt(u32, b[fat_header_size + 12 ..][0..4], 1000, .big);
        try std.testing.expectError(error.Truncated, checkComplete(b));
        // A slice inside the fat header.
        std.mem.writeInt(u32, b[fat_header_size + 12 ..][0..4], 8, .big);
        std.mem.writeInt(u32, b[fat_header_size + 8 ..][0..4], 4, .big);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
    }
    {
        const b = try forgeFat(a, &.{thin});
        defer a.free(b);
        // The arch entry's CPU differs from the slice's header.
        std.mem.writeInt(u32, b[fat_header_size..][0..4], std.macho.CPU_TYPE_X86_64, .big);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
        // No slices, or too many.
        std.mem.writeInt(u32, b[4..8], 0, .big);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
        std.mem.writeInt(u32, b[4..8], max_fat_arches + 1, .big);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
    }
    {
        // A fat file inside a fat file, and a slice that is not Mach-O.
        const inner = try forgeFat(a, &.{thin});
        defer a.free(inner);
        const b = try forgeFat(a, &.{inner});
        defer a.free(b);
        try std.testing.expectError(error.BadHeader, checkComplete(b));
        @memset(b[64..][0..4], 'x');
        try std.testing.expectError(error.BadHeader, checkComplete(b));
    }
}
