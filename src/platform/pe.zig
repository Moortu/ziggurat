//! PE (Portable Executable) file reader (L1, std only): the format of
//! Windows DLLs. It checks that a file is complete before the loader or the
//! generation store accepts it, and lists a DLL's export and import names
//! for the export output checks.
//!
//! Every offset and size comes from the file, so every read is bounds-checked
//! and every sum is done in 64 bits. No input makes these functions panic.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// A header, table or section ends past the end of the file.
    Truncated,
    /// No `MZ` DOS header or no `PE\0\0` signature.
    NotPe,
    /// A header or table value is impossible (unknown optional header,
    /// a table outside every section, a missing string end, ...).
    BadHeader,
};

/// One imported function. `name` is the function name, or `#<ordinal>`
/// (decimal) for an import by ordinal.
pub const Import = struct { dll: []const u8, name: []const u8 };

const dos_header_size = 0x40;
const coff_header_size = 20;
const section_header_size = 40;
const max_data_dirs = 16;
/// The Windows loader refuses more sections than this. The cap also bounds
/// each RVA lookup, which scans the section table.
const max_sections = 96;

// Output limits of `exports` and `imports`. Many table entries may name one
// string, so without them a file could ask for memory quadratic in its
// size. Past any limit the result is `error.TooLarge`.
/// The most names one list may hold.
pub const max_entries = 1 << 16;
/// The longest name (export, imported function or DLL name), in bytes.
pub const max_name_len = 4096;
/// The most name bytes one list may hold in total (DLL names included).
pub const max_output_bytes = 16 << 20;

/// Errors of `exports` and `imports`.
pub const ListError = Error || error{
    /// The lists would pass `max_entries`, `max_name_len` or `max_output_bytes`.
    TooLarge,
} || Allocator.Error;

/// Counts what a list has used of the output limits.
const Budget = struct {
    entries: usize = 0,
    bytes: u64 = 0,

    /// Accounts for one more entry whose names are `lens` bytes long.
    fn take(self: *Budget, lens: []const usize) error{TooLarge}!void {
        self.entries += 1;
        if (self.entries > max_entries) return error.TooLarge;
        for (lens) |n| {
            if (n > max_name_len) return error.TooLarge;
            self.bytes += n;
        }
        if (self.bytes > max_output_bytes) return error.TooLarge;
    }
};

const dir_export = 0;
const dir_import = 1;
const dir_security = 4;
const dir_delay_import = 13;

fn readU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn readU64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// Writes one sentence into `diag`, NUL-terminated, cut to fit if too long.
/// Same form as `elf.setDiag`; repeated here so this file imports only std.
fn setDiag(diag: ?*[256]u8, comptime fmt: []const u8, args: anytype) void {
    const d = diag orelse return;
    @memset(d, 0);
    var w: std.Io.Writer = .fixed(d[0..255]);
    w.print(fmt, args) catch {};
}

pub const Section = struct {
    virtual_address: u32,
    virtual_size: u32,
    raw_offset: u32,
    raw_size: u32,

    /// How many raw bytes the loader maps at `virtual_address`: the raw
    /// data, but no more than the virtual size (0 means "use the raw
    /// size"). Raw bytes past the virtual size are not visible at those
    /// RVAs, so the reader must not read tables from them.
    fn mappedSize(s: Section) u32 {
        if (s.virtual_size == 0) return s.raw_size;
        return @min(s.raw_size, s.virtual_size);
    }
};

pub const DataDir = struct { rva: u32, size: u32 };

/// The parsed headers of a PE file. `parse` checks only the headers; it does
/// not check that section data is inside the file (that is `checkComplete`).
pub const Image = struct {
    bytes: []const u8,
    /// PE32+ (64-bit) when true, PE32 otherwise.
    plus: bool,
    image_base: u64,
    size_of_headers: u32,
    section_table: usize,
    section_count: u16,
    data_dirs: usize,
    data_dir_count: u32,

    pub fn parse(bytes: []const u8) Error!Image {
        return parseDiag(bytes, null);
    }

    fn parseDiag(bytes: []const u8, diag: ?*[256]u8) Error!Image {
        const len: u64 = bytes.len;
        if (bytes.len < 2) {
            if (std.mem.startsWith(u8, "MZ", bytes)) {
                setDiag(diag, "The PE file is cut short: it has {d} bytes, the DOS header needs {d}.", .{ len, dos_header_size });
                return error.Truncated;
            }
            setDiag(diag, "The file is not a PE file: it has no MZ header ({d} bytes).", .{len});
            return error.NotPe;
        }
        if (!std.mem.eql(u8, bytes[0..2], "MZ")) {
            setDiag(diag, "The file is not a PE file: it has no MZ header ({d} bytes).", .{len});
            return error.NotPe;
        }
        if (len < dos_header_size) {
            setDiag(diag, "The PE file is cut short: it has {d} bytes, the DOS header needs {d}.", .{ len, dos_header_size });
            return error.Truncated;
        }
        const lfanew: u64 = readU32(bytes, 0x3c);
        const coff: u64 = lfanew + 4;
        const opt: u64 = coff + coff_header_size;
        if (opt > len) {
            setDiag(diag, "The PE file is cut short: the PE header ends at byte {d}, the file has {d} bytes.", .{ opt, len });
            return error.Truncated;
        }
        if (!std.mem.eql(u8, bytes[@intCast(lfanew)..][0..4], "PE\x00\x00")) {
            setDiag(diag, "The file is not a PE file: no PE signature at byte {d}.", .{lfanew});
            return error.NotPe;
        }
        const section_count = readU16(bytes, @intCast(coff + 2));
        const opt_size: u64 = readU16(bytes, @intCast(coff + 16));
        const opt_end = opt + opt_size;
        if (opt_end > len) {
            setDiag(diag, "The PE file is cut short: the optional header ends at byte {d}, the file has {d} bytes.", .{ opt_end, len });
            return error.Truncated;
        }
        if (opt_size < 2) {
            setDiag(diag, "The PE optional header is {d} bytes, too small.", .{opt_size});
            return error.BadHeader;
        }
        const o: usize = @intCast(opt);
        const magic = readU16(bytes, o);
        const plus = switch (magic) {
            0x20b => true,
            0x10b => false,
            else => {
                setDiag(diag, "The PE optional header has the unknown magic 0x{x}.", .{magic});
                return error.BadHeader;
            },
        };
        // Fixed fields: up to NumberOfRvaAndSizes (PE32+ 112 bytes, PE32 96).
        const fixed: u64 = if (plus) 112 else 96;
        if (opt_size < fixed) {
            setDiag(diag, "The PE optional header is {d} bytes, it needs at least {d}.", .{ opt_size, fixed });
            return error.BadHeader;
        }
        const image_base: u64 = if (plus) readU64(bytes, o + 24) else readU32(bytes, o + 28);
        const size_of_headers = readU32(bytes, o + 60);
        const dir_count = readU32(bytes, o + @as(usize, @intCast(fixed - 4)));
        const dirs = opt + fixed;
        const used_dirs: u32 = @min(dir_count, max_data_dirs);
        if (dirs + @as(u64, used_dirs) * 8 > opt_end) {
            setDiag(diag, "The PE optional header names {d} data directories but has room for {d}.", .{ dir_count, (opt_end - dirs) / 8 });
            return error.BadHeader;
        }
        if (section_count == 0) {
            setDiag(diag, "The PE file has no sections.", .{});
            return error.BadHeader;
        }
        if (section_count > max_sections) {
            setDiag(diag, "The PE file has {d} sections; Windows loads at most {d}.", .{ section_count, max_sections });
            return error.BadHeader;
        }
        const table_end = opt_end + @as(u64, section_count) * section_header_size;
        if (table_end > len) {
            setDiag(diag, "The PE file is cut short: the section table ends at byte {d}, the file has {d} bytes.", .{ table_end, len });
            return error.Truncated;
        }
        if (size_of_headers > len) {
            setDiag(diag, "The PE file is cut short: the headers are {d} bytes, the file has {d} bytes.", .{ size_of_headers, len });
            return error.Truncated;
        }
        return .{
            .bytes = bytes,
            .plus = plus,
            .image_base = image_base,
            .size_of_headers = size_of_headers,
            .section_table = @intCast(opt_end),
            .section_count = section_count,
            .data_dirs = @intCast(dirs),
            .data_dir_count = used_dirs,
        };
    }

    /// Section `i`, or null when `i` is not below `section_count`.
    pub fn section(self: Image, i: u16) ?Section {
        if (i >= self.section_count) return null;
        const off = self.section_table + @as(usize, i) * section_header_size;
        return .{
            .virtual_size = readU32(self.bytes, off + 8),
            .virtual_address = readU32(self.bytes, off + 12),
            .raw_size = readU32(self.bytes, off + 16),
            .raw_offset = readU32(self.bytes, off + 20),
        };
    }

    /// Data directory `i`, or a zero entry when the file has fewer.
    pub fn dataDir(self: Image, i: u32) DataDir {
        if (i >= self.data_dir_count) return .{ .rva = 0, .size = 0 };
        const off = self.data_dirs + @as(usize, i) * 8;
        return .{ .rva = readU32(self.bytes, off), .size = readU32(self.bytes, off + 4) };
    }

    /// The file bytes from `rva` to the end of the raw data that holds it
    /// (a section's raw data, or the headers), or null when no file byte
    /// backs `rva`.
    fn tail(self: Image, rva: u32) ?[]const u8 {
        var i: u16 = 0;
        while (i < self.section_count) : (i += 1) {
            const s = self.section(i).?;
            if (rva < s.virtual_address) continue;
            const delta: u64 = rva - s.virtual_address;
            const mapped = s.mappedSize();
            if (delta >= mapped) continue;
            const start = @as(u64, s.raw_offset) + delta;
            const end = @min(@as(u64, s.raw_offset) + mapped, self.bytes.len);
            if (start >= end) return null;
            return self.bytes[@intCast(start)..@intCast(end)];
        }
        if (rva < self.size_of_headers and rva < self.bytes.len) {
            return self.bytes[rva..@min(self.size_of_headers, self.bytes.len)];
        }
        return null;
    }

    /// The file offset that holds `rva`, or null.
    pub fn offsetOf(self: Image, rva: u32) ?usize {
        const t = self.tail(rva) orelse return null;
        return @intFromPtr(t.ptr) - @intFromPtr(self.bytes.ptr);
    }

    /// The RVA that the file offset `off` is loaded at, or null when `off`
    /// is in no section's raw data and not in the headers.
    pub fn rvaOf(self: Image, off: usize) ?u32 {
        var i: u16 = 0;
        while (i < self.section_count) : (i += 1) {
            const s = self.section(i).?;
            if (off < s.raw_offset) continue;
            const delta: u64 = off - s.raw_offset;
            if (delta >= s.mappedSize()) continue;
            const rva = @as(u64, s.virtual_address) + delta;
            return std.math.cast(u32, rva);
        }
        if (off < self.size_of_headers) return @intCast(off);
        return null;
    }

    /// `n` file bytes at `rva`, all inside one section's raw data.
    fn slice(self: Image, rva: u32, n: u64) Error![]const u8 {
        if (n == 0) return &.{};
        const t = self.tail(rva) orelse return error.BadHeader;
        if (n > t.len) return error.BadHeader;
        return t[0..@intCast(n)];
    }

    /// The NUL-terminated string at `rva`, without the NUL.
    fn string(self: Image, rva: u32) Error![]const u8 {
        const t = self.tail(rva) orelse return error.BadHeader;
        const end = std.mem.indexOfScalar(u8, t, 0) orelse return error.BadHeader;
        return t[0..end];
    }
};

/// Refuses a file that is not a complete PE file: the DOS header, the PE
/// signature, the COFF and optional headers, the section table, the headers'
/// stated size, every section's raw data and the certificate table must lie
/// inside the file. The PE version of `elf.checkComplete`, on bytes.
pub fn checkComplete(bytes: []const u8) Error!void {
    return checkCompleteDiag(bytes, null);
}

/// `checkComplete` that also writes one sentence about the problem into
/// `diag` (NUL-terminated; `elf.diagText` reads it).
pub fn checkCompleteDiag(bytes: []const u8, diag: ?*[256]u8) Error!void {
    const img = try Image.parseDiag(bytes, diag);
    const len: u64 = bytes.len;
    var i: u16 = 0;
    while (i < img.section_count) : (i += 1) {
        const s = img.section(i).?;
        if (s.raw_size == 0) continue;
        const end = @as(u64, s.raw_offset) + s.raw_size;
        if (end > len) {
            setDiag(diag, "The PE file is truncated: section {d} ends at byte {d}, the file has {d} bytes.", .{ i, end, len });
            return error.Truncated;
        }
    }
    // The certificate table's "RVA" is a file offset.
    const cert = img.dataDir(dir_security);
    if (cert.size != 0) {
        const end = @as(u64, cert.rva) + cert.size;
        if (end > len) {
            setDiag(diag, "The PE file is truncated: the certificate table ends at byte {d}, the file has {d} bytes.", .{ end, len });
            return error.Truncated;
        }
    }
}

/// The names in the export table, in table order, then `#<ordinal>` for each
/// function exported by ordinal only. The caller frees the result with
/// `freeExports`.
pub fn exports(a: Allocator, bytes: []const u8) ListError![]const []const u8 {
    const img = try Image.parse(bytes);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeList(a, &out);

    // A directory is present when its address is not 0, whatever its
    // Size: the Windows and Wine loaders read it that way
    // (`RtlImageDirectoryEntryToData`), so this reader must too.
    const dir = img.dataDir(dir_export);
    var budget: Budget = .{};
    if (dir.rva == 0) return out.toOwnedSlice(a);
    const ed = try img.slice(dir.rva, 40);
    const base = readU32(ed, 16);
    const nfuncs = readU32(ed, 20);
    const nnames = readU32(ed, 24);
    const funcs = try img.slice(readU32(ed, 28), @as(u64, nfuncs) * 4);
    const names = try img.slice(readU32(ed, 32), @as(u64, nnames) * 4);
    const ords = try img.slice(readU32(ed, 36), @as(u64, nnames) * 2);

    // `nfuncs` fits in the file (4 bytes each), so this is bounded.
    const named = try a.alloc(bool, nfuncs);
    defer a.free(named);
    @memset(named, false);

    for (0..nnames) |k| {
        const idx = readU16(ords, k * 2);
        if (idx >= nfuncs) return error.BadHeader;
        named[idx] = true;
        const name = try img.string(readU32(names, k * 4));
        try budget.take(&.{name.len});
        try out.ensureUnusedCapacity(a, 1);
        out.appendAssumeCapacity(try a.dupe(u8, name));
    }
    for (named, 0..) |is_named, k| {
        if (is_named or readU32(funcs, k * 4) == 0) continue;
        try budget.take(&.{11}); // "#" and up to 10 digits
        try out.ensureUnusedCapacity(a, 1);
        out.appendAssumeCapacity(try std.fmt.allocPrint(a, "#{d}", .{@as(u64, base) + k}));
    }
    return out.toOwnedSlice(a);
}

pub fn freeExports(a: Allocator, list: []const []const u8) void {
    for (list) |s| a.free(s);
    a.free(list);
}

fn freeList(a: Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| a.free(s);
    list.deinit(a);
}

/// Every imported function, from the import table and the delay-load import
/// table. An import by ordinal is named `#<ordinal>`. The caller frees the
/// result with `freeImports`.
pub fn imports(a: Allocator, bytes: []const u8) ListError![]const Import {
    const img = try Image.parse(bytes);
    var out: std.ArrayList(Import) = .empty;
    errdefer {
        for (out.items) |i| freeImport(a, i);
        out.deinit(a);
    }

    var budget: Budget = .{};
    // Present when the address is not 0, whatever the Size (see `exports`).
    const dir = img.dataDir(dir_import);
    if (dir.rva != 0) {
        var rva: u64 = dir.rva;
        while (true) : (rva += 20) {
            const d = try img.slice(std.math.cast(u32, rva) orelse return error.BadHeader, 20);
            if (std.mem.allEqual(u8, d, 0)) break;
            const lookup = readU32(d, 0);
            const iat = readU32(d, 16);
            try addThunks(a, img, &out, &budget, readU32(d, 12), if (lookup != 0) lookup else iat, 0);
        }
    }

    const delay = img.dataDir(dir_delay_import);
    if (delay.rva != 0) {
        var rva: u64 = delay.rva;
        while (true) : (rva += 32) {
            const d = try img.slice(std.math.cast(u32, rva) orelse return error.BadHeader, 32);
            if (std.mem.allEqual(u8, d, 0)) break;
            // Attribute bit 0 clear: the old form, with virtual addresses
            // instead of RVAs.
            const va_base: u64 = if (readU32(d, 0) & 1 == 0) img.image_base else 0;
            try addThunks(a, img, &out, &budget, readU32(d, 4), readU32(d, 16), va_base);
        }
    }
    return out.toOwnedSlice(a);
}

/// Appends one `Import` per entry of the zero-ended thunk array at
/// `thunks` (an RVA, or a VA when `va_base` is not 0) for the DLL named at
/// `dll_ref`.
fn addThunks(a: Allocator, img: Image, out: *std.ArrayList(Import), budget: *Budget, dll_ref: u32, thunks: u32, va_base: u64) ListError!void {
    const dll = try img.string(try toRva(dll_ref, va_base));
    const size: u64 = if (img.plus) 8 else 4;
    const ordinal_flag: u64 = if (img.plus) 1 << 63 else 1 << 31;
    var rva: u64 = try toRva(thunks, va_base);
    while (true) : (rva += size) {
        const t = try img.slice(std.math.cast(u32, rva) orelse return error.BadHeader, size);
        const entry: u64 = if (img.plus) readU64(t, 0) else readU32(t, 0);
        if (entry == 0) break;
        // The name is found before anything is copied, so the budget is
        // checked first.
        const fn_name: ?[]const u8 = if (entry & ordinal_flag != 0) null else blk: {
            // Hint/name entry: a 2-byte hint, then the name.
            const hint_name = std.math.cast(u32, (try toRva(@truncate(entry & 0x7fff_ffff), va_base)) + @as(u64, 2)) orelse return error.BadHeader;
            break :blk try img.string(hint_name);
        };
        try budget.take(&.{ dll.len, if (fn_name) |n| n.len else 6 }); // "#65535"
        try out.ensureUnusedCapacity(a, 1);
        const dll_copy = try a.dupe(u8, dll);
        errdefer a.free(dll_copy);
        const name = if (fn_name) |n| try a.dupe(u8, n) else try std.fmt.allocPrint(a, "#{d}", .{entry & 0xffff});
        out.appendAssumeCapacity(.{ .dll = dll_copy, .name = name });
    }
}

fn toRva(ref: u32, va_base: u64) Error!u32 {
    if (va_base == 0) return ref;
    if (ref < va_base) return error.BadHeader;
    return std.math.cast(u32, ref - va_base) orelse error.BadHeader;
}

fn freeImport(a: Allocator, i: Import) void {
    a.free(i.dll);
    a.free(i.name);
}

pub fn freeImports(a: Allocator, list: []const Import) void {
    for (list) |i| freeImport(a, i);
    a.free(list);
}

test "not a PE file" {
    try std.testing.expectError(error.NotPe, checkComplete("hello, world, this is not a PE file at all......................................"));
    try std.testing.expectError(error.Truncated, checkComplete("M"));
    try std.testing.expectError(error.Truncated, checkComplete("MZ"));
    try std.testing.expectError(error.NotPe, checkComplete("X"));
    var diag: [256]u8 = undefined;
    try std.testing.expectError(error.Truncated, checkCompleteDiag("MZ\x00\x00", &diag));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&diag, 0), "cut short") != null);
}

/// Test helper: a PE32+ file with one section of `data_len` bytes, whose
/// raw data starts at file offset 0x200 and is loaded at RVA 0x1000. All
/// data directories are empty. The caller frees the result.
fn forge(a: Allocator, data_len: u32) ![]u8 {
    const b = try a.alloc(u8, 0x200 + data_len);
    @memset(b, 0);
    @memcpy(b[0..2], "MZ");
    std.mem.writeInt(u32, b[0x3c..][0..4], 0x40, .little);
    @memcpy(b[0x40..0x44], "PE\x00\x00");
    std.mem.writeInt(u16, b[0x44..][0..2], 0x8664, .little); // machine
    std.mem.writeInt(u16, b[0x46..][0..2], 1, .little); // sections
    std.mem.writeInt(u16, b[0x54..][0..2], 240, .little); // optional header size
    const opt = 0x58;
    std.mem.writeInt(u16, b[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u64, b[opt + 24 ..][0..8], 0x1_8000_0000, .little);
    std.mem.writeInt(u32, b[opt + 60 ..][0..4], 0x200, .little); // SizeOfHeaders
    std.mem.writeInt(u32, b[opt + 108 ..][0..4], 16, .little);
    const sec = opt + 240;
    @memcpy(b[sec..][0..5], ".data");
    std.mem.writeInt(u32, b[sec + 8 ..][0..4], data_len, .little); // VirtualSize
    std.mem.writeInt(u32, b[sec + 12 ..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, b[sec + 16 ..][0..4], data_len, .little);
    std.mem.writeInt(u32, b[sec + 20 ..][0..4], 0x200, .little);
    return b;
}

/// Test helper: the file offset of `rva` in a `forge` file.
fn at(rva: u32) usize {
    return rva - 0x1000 + 0x200;
}

fn setDir(b: []u8, i: u32, rva: u32, size: u32) void {
    const off = 0x58 + 112 + i * 8;
    std.mem.writeInt(u32, b[off..][0..4], rva, .little);
    std.mem.writeInt(u32, b[off + 4 ..][0..4], size, .little);
}

fn put32(b: []u8, rva: u32, v: u32) void {
    std.mem.writeInt(u32, b[at(rva)..][0..4], v, .little);
}

/// A forged export table: `n` name pointers that all point at one name of
/// `name_len` bytes, and one function. Directory Size is `dir_size`.
fn forgeExports(a: Allocator, n: u32, name_len: u32, dir_size: u32) ![]u8 {
    const names_rva = 0x1000 + 0x100 + name_len + 1;
    const ords_rva = names_rva + 4 * n;
    const funcs_rva = ords_rva + 2 * n;
    const b = try forge(a, funcs_rva + 4 - 0x1000);
    setDir(b, dir_export, 0x1000, dir_size);
    put32(b, 0x1000 + 20, 1); // NumberOfFunctions
    put32(b, 0x1000 + 24, n); // NumberOfNames
    put32(b, 0x1000 + 28, funcs_rva);
    put32(b, 0x1000 + 32, names_rva);
    put32(b, 0x1000 + 36, ords_rva); // all ordinals 0
    @memset(b[at(0x1100)..][0..name_len], 'e');
    for (0..n) |k| put32(b, names_rva + @as(u32, @intCast(k)) * 4, 0x1100);
    put32(b, funcs_rva, 0x1000);
    return b;
}

/// A forged import table: one descriptor for `x.dll` whose `n` thunks all
/// name one function of `name_len` bytes. Directory Size is `dir_size`.
fn forgeImports(a: Allocator, n: u32, name_len: u32, dir_size: u32) ![]u8 {
    const hint_rva = 0x1200;
    const thunks_rva = std.mem.alignForward(u32, hint_rva + 2 + name_len + 1, 8);
    const b = try forge(a, thunks_rva + 8 * (n + 1) - 0x1000);
    setDir(b, dir_import, 0x1000, dir_size);
    put32(b, 0x1000 + 0, thunks_rva);
    put32(b, 0x1000 + 12, 0x1100);
    put32(b, 0x1000 + 16, thunks_rva);
    @memcpy(b[at(0x1100)..][0..5], "x.dll");
    @memset(b[at(hint_rva + 2)..][0..name_len], 'i');
    for (0..n) |k| std.mem.writeInt(u64, b[at(thunks_rva) + k * 8 ..][0..8], hint_rva, .little);
    return b;
}

test "forged files: a sane table lists its names" {
    const a = std.testing.allocator;
    {
        const b = try forgeExports(a, 3, 4, 40);
        defer a.free(b);
        try checkComplete(b);
        const ex = try exports(a, b);
        defer freeExports(a, ex);
        try std.testing.expectEqual(@as(usize, 3), ex.len);
        try std.testing.expectEqualStrings("eeee", ex[2]);
    }
    {
        const b = try forgeImports(a, 3, 4, 40);
        defer a.free(b);
        const im = try imports(a, b);
        defer freeImports(a, im);
        try std.testing.expectEqual(@as(usize, 3), im.len);
        try std.testing.expectEqualStrings("x.dll", im[0].dll);
        try std.testing.expectEqualStrings("iiii", im[0].name);
    }
}

test "forged files: many entries sharing one long name are TooLarge" {
    const a = std.testing.allocator;
    // 5,000 x 4,000 bytes = 20 MB of output, over `max_output_bytes`.
    {
        const b = try forgeExports(a, 5000, 4000, 40);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, exports(a, b));
    }
    {
        const b = try forgeImports(a, 5000, 4000, 40);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, imports(a, b));
    }
    // One name longer than `max_name_len`.
    {
        const b = try forgeExports(a, 1, max_name_len + 1, 40);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, exports(a, b));
    }
    {
        const b = try forgeImports(a, 1, max_name_len + 1, 40);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, imports(a, b));
    }
    // More entries than `max_entries`, each name short.
    {
        const b = try forgeExports(a, max_entries + 1, 1, 40);
        defer a.free(b);
        try std.testing.expectError(error.TooLarge, exports(a, b));
    }
}

test "forged files: a directory with Size 0 is still read" {
    const a = std.testing.allocator;
    {
        const b = try forgeExports(a, 2, 4, 0);
        defer a.free(b);
        const ex = try exports(a, b);
        defer freeExports(a, ex);
        try std.testing.expectEqual(@as(usize, 2), ex.len);
    }
    {
        const b = try forgeImports(a, 2, 4, 0);
        defer a.free(b);
        const im = try imports(a, b);
        defer freeImports(a, im);
        try std.testing.expectEqual(@as(usize, 2), im.len);
    }
}

test "forged files: more than 96 sections is refused" {
    const a = std.testing.allocator;
    const b = try forge(a, 0x2000);
    defer a.free(b);
    std.mem.writeInt(u16, b[0x46..][0..2], max_sections + 1, .little);
    try std.testing.expectError(error.BadHeader, checkComplete(b));
    std.mem.writeInt(u16, b[0x46..][0..2], max_sections, .little);
    // 96 is allowed (the extra section headers are zero bytes).
    _ = try Image.parse(b);
}

test "forged files: raw bytes past the virtual size are not read" {
    const a = std.testing.allocator;
    const b = try forgeExports(a, 1, 4, 40);
    defer a.free(b);
    // Map only the export directory itself; the name table lies past it.
    std.mem.writeInt(u32, b[0x58 + 240 + 8 ..][0..4], 0x40, .little);
    try std.testing.expectError(error.BadHeader, exports(a, b));
    try std.testing.expect((try Image.parse(b)).section(1) == null);
}
