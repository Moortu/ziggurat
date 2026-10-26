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
/// More imports than this is not a real DLL; the cap keeps a crafted file
/// (many descriptors sharing one long thunk array) from using memory
/// quadratic in its size.
const max_imports = 1 << 16;

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

    pub fn section(self: Image, i: u16) Section {
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
            const s = self.section(i);
            if (rva < s.virtual_address) continue;
            const delta: u64 = rva - s.virtual_address;
            if (delta >= s.raw_size) continue;
            const start = @as(u64, s.raw_offset) + delta;
            const end = @min(@as(u64, s.raw_offset) + s.raw_size, self.bytes.len);
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
            const s = self.section(i);
            if (off < s.raw_offset) continue;
            const delta: u64 = off - s.raw_offset;
            if (delta >= s.raw_size) continue;
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
        const s = img.section(i);
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
pub fn exports(a: Allocator, bytes: []const u8) (Error || Allocator.Error)![]const []const u8 {
    const img = try Image.parse(bytes);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeList(a, &out);

    const dir = img.dataDir(dir_export);
    if (dir.rva == 0 or dir.size == 0) return out.toOwnedSlice(a);
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
        try out.ensureUnusedCapacity(a, 1);
        out.appendAssumeCapacity(try a.dupe(u8, name));
    }
    for (named, 0..) |is_named, k| {
        if (is_named or readU32(funcs, k * 4) == 0) continue;
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
pub fn imports(a: Allocator, bytes: []const u8) (Error || Allocator.Error)![]const Import {
    const img = try Image.parse(bytes);
    var out: std.ArrayList(Import) = .empty;
    errdefer {
        for (out.items) |i| freeImport(a, i);
        out.deinit(a);
    }

    const dir = img.dataDir(dir_import);
    if (dir.rva != 0 and dir.size != 0) {
        var rva: u64 = dir.rva;
        while (true) : (rva += 20) {
            const d = try img.slice(std.math.cast(u32, rva) orelse return error.BadHeader, 20);
            if (std.mem.allEqual(u8, d, 0)) break;
            const lookup = readU32(d, 0);
            const iat = readU32(d, 16);
            try addThunks(a, img, &out, readU32(d, 12), if (lookup != 0) lookup else iat, 0);
        }
    }

    const delay = img.dataDir(dir_delay_import);
    if (delay.rva != 0 and delay.size != 0) {
        var rva: u64 = delay.rva;
        while (true) : (rva += 32) {
            const d = try img.slice(std.math.cast(u32, rva) orelse return error.BadHeader, 32);
            if (std.mem.allEqual(u8, d, 0)) break;
            // Attribute bit 0 clear: the old form, with virtual addresses
            // instead of RVAs.
            const va_base: u64 = if (readU32(d, 0) & 1 == 0) img.image_base else 0;
            try addThunks(a, img, &out, readU32(d, 4), readU32(d, 16), va_base);
        }
    }
    return out.toOwnedSlice(a);
}

/// Appends one `Import` per entry of the zero-ended thunk array at
/// `thunks` (an RVA, or a VA when `va_base` is not 0) for the DLL named at
/// `dll_ref`.
fn addThunks(a: Allocator, img: Image, out: *std.ArrayList(Import), dll_ref: u32, thunks: u32, va_base: u64) (Error || Allocator.Error)!void {
    const dll = try img.string(try toRva(dll_ref, va_base));
    const size: u64 = if (img.plus) 8 else 4;
    const ordinal_flag: u64 = if (img.plus) 1 << 63 else 1 << 31;
    var rva: u64 = try toRva(thunks, va_base);
    while (true) : (rva += size) {
        const t = try img.slice(std.math.cast(u32, rva) orelse return error.BadHeader, size);
        const entry: u64 = if (img.plus) readU64(t, 0) else readU32(t, 0);
        if (entry == 0) break;
        const dll_copy = try a.dupe(u8, dll);
        errdefer a.free(dll_copy);
        const name = if (entry & ordinal_flag != 0)
            try std.fmt.allocPrint(a, "#{d}", .{entry & 0xffff})
        else blk: {
            // Hint/name entry: a 2-byte hint, then the name.
            const hint_name = std.math.cast(u32, (try toRva(@truncate(entry & 0x7fff_ffff), va_base)) + @as(u64, 2)) orelse return error.BadHeader;
            break :blk try a.dupe(u8, try img.string(hint_name));
        };
        errdefer a.free(name);
        if (out.items.len >= max_imports) return error.BadHeader;
        try out.append(a, .{ .dll = dll_copy, .name = name });
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
