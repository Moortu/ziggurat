//! ELF completeness check (L1). Guards `dlopen` against truncated or corrupt
//! build outputs. Reads with positional reads only (no mmap).
const std = @import("std");
const File = std.Io.File;

pub const ElfError = error{ NotElf64, Truncated, Corrupt };
/// Failures of the reads themselves (not a verdict on the file).
pub const IoError = File.ReadPositionalError || File.LengthError;

const ehdr_size = 64;
const phdr_size = 56;
const shdr_size = 64;
const pt_load: u32 = 1;

/// Decoded fields of the ELF64 file header (little endian).
const Ehdr = struct {
    phoff: u64,
    shoff: u64,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,

    fn parse(b: *const [ehdr_size]u8) Ehdr {
        return .{
            .phoff = std.mem.readInt(u64, b[32..40], .little),
            .shoff = std.mem.readInt(u64, b[40..48], .little),
            .phentsize = std.mem.readInt(u16, b[54..56], .little),
            .phnum = std.mem.readInt(u16, b[56..58], .little),
            .shentsize = std.mem.readInt(u16, b[58..60], .little),
            .shnum = std.mem.readInt(u16, b[60..62], .little),
        };
    }
};

/// Writes one sentence into `diag`, NUL-terminated, cut to fit if too long.
pub fn setDiag(diag: *[256]u8, comptime fmt: []const u8, args: anytype) void {
    @memset(diag, 0);
    var w: std.Io.Writer = .fixed(diag[0..255]);
    w.print(fmt, args) catch {};
}

/// The text `checkComplete` wrote into `diag`: everything up to the first 0 byte.
pub fn diagText(diag: *const [256]u8) []const u8 {
    return std.mem.sliceTo(diag, 0);
}

fn readAt(io: std.Io, file: File, buf: []u8, off: u64) IoError!bool {
    const n = try file.readPositionalAll(io, buf, off);
    return n == buf.len;
}

/// Refuses a file that is not a complete 64-bit little-endian ELF: the section
/// header table, the program headers and every PT_LOAD segment must lie inside
/// the file. `dlopen` alone accepts a library whose cut only removes trailing
/// sections. All offsets come from the file, so all sums are checked.
///
/// Returns `error.NotElf64` (not an ELF64 file), `error.Truncated` (a table or
/// segment ends past the end of the file) or `error.Corrupt` (a header value
/// is impossible or overflows). On any of these, `diag` holds one sentence
/// naming the problem and the byte offsets. `diag` is NUL-terminated: read it
/// with `diagText`. Read failures are returned as `IoError` and leave `diag`
/// unchanged.
pub fn checkComplete(io: std.Io, file: File, diag: *[256]u8) (ElfError || IoError)!void {
    const size = try file.length(io);
    var raw: [ehdr_size]u8 = undefined;
    const n = try file.readPositionalAll(io, &raw, 0);
    const magic_ok = n >= 4 and std.mem.eql(u8, raw[0..4], "\x7fELF");
    if (magic_ok and n < ehdr_size) {
        setDiag(diag, "The ELF header is cut short: the file has {d} bytes, the header needs {d}.", .{ size, ehdr_size });
        return error.Truncated;
    }
    if (!magic_ok or raw[4] != 2 or raw[5] != 1) {
        setDiag(diag, "The file is not a 64-bit little-endian ELF file ({d} bytes).", .{size});
        return error.NotElf64;
    }
    const eh = Ehdr.parse(&raw);

    // Section header table.
    var shnum: u64 = eh.shnum;
    if (eh.shoff != 0) {
        if (eh.shentsize != shdr_size) {
            setDiag(diag, "The ELF section header size is {d}, expected {d} (header field at byte 58).", .{ eh.shentsize, shdr_size });
            return error.Corrupt;
        }
        if (eh.shnum == 0) {
            // Extended numbering: the real count is sh_size of section header 0.
            const first_end = std.math.add(u64, eh.shoff, shdr_size) catch {
                setDiag(diag, "The ELF section header table offset 0x{x} overflows.", .{eh.shoff});
                return error.Corrupt;
            };
            if (first_end > size) {
                setDiag(diag, "The ELF file is truncated: section header 0 ends at byte {d}, the file has {d} bytes.", .{ first_end, size });
                return error.Truncated;
            }
            var sh0: [shdr_size]u8 = undefined;
            if (!try readAt(io, file, &sh0, eh.shoff)) {
                setDiag(diag, "The ELF file is truncated: section header 0 at byte {d} could not be read in full.", .{eh.shoff});
                return error.Truncated;
            }
            shnum = std.mem.readInt(u64, sh0[32..40], .little);
        }
        const sh_end = rangeEnd(eh.shoff, shnum, shdr_size) orelse {
            setDiag(diag, "The ELF section header table at offset 0x{x} with {d} entries overflows.", .{ eh.shoff, shnum });
            return error.Corrupt;
        };
        if (sh_end > size) {
            setDiag(diag, "The ELF file is truncated: section headers end at byte {d}, the file has {d} bytes.", .{ sh_end, size });
            return error.Truncated;
        }
    }

    // Program headers and loadable segments.
    if (eh.phnum != 0) {
        if (eh.phentsize != phdr_size) {
            setDiag(diag, "The ELF program header size is {d}, expected {d} (header field at byte 54).", .{ eh.phentsize, phdr_size });
            return error.Corrupt;
        }
        const ph_end = rangeEnd(eh.phoff, eh.phnum, phdr_size) orelse {
            setDiag(diag, "The ELF program header table offset 0x{x} overflows.", .{eh.phoff});
            return error.Corrupt;
        };
        if (ph_end > size) {
            setDiag(diag, "The ELF file is truncated: program headers end at byte {d}, the file has {d} bytes.", .{ ph_end, size });
            return error.Truncated;
        }
        for (0..eh.phnum) |i| {
            var ph: [phdr_size]u8 = undefined;
            // In range: phoff + phnum * phdr_size <= size was checked above.
            const off = eh.phoff + i * phdr_size;
            if (!try readAt(io, file, &ph, off)) {
                setDiag(diag, "The ELF file is truncated: program header {d} at byte {d} could not be read in full.", .{ i, off });
                return error.Truncated;
            }
            if (std.mem.readInt(u32, ph[0..4], .little) != pt_load) continue;
            const p_offset = std.mem.readInt(u64, ph[8..16], .little);
            const p_filesz = std.mem.readInt(u64, ph[32..40], .little);
            const seg_end = std.math.add(u64, p_offset, p_filesz) catch {
                setDiag(diag, "The ELF segment {d} at offset 0x{x} with size 0x{x} overflows.", .{ i, p_offset, p_filesz });
                return error.Corrupt;
            };
            if (seg_end > size) {
                setDiag(diag, "The ELF file is truncated: segment {d} ends at byte {d}, the file has {d} bytes.", .{ i, seg_end, size });
                return error.Truncated;
            }
        }
    }
}

/// `off + count * entsize`, or null on u64 overflow.
fn rangeEnd(off: u64, count: u64, entsize: u64) ?u64 {
    const len = std.math.mul(u64, count, entsize) catch return null;
    return std.math.add(u64, off, len) catch null;
}

// ------------------------------------------------- in-memory symbol reading
//
// The export build checks its own output with these (spec section 10): what
// the library exports and imports, and which glibc versions it needs. Every
// offset, size and count comes from the file, so every range is checked and
// a bad value gives `error.Corrupt` or `error.Truncated`, never an
// out-of-bounds read or an endless loop.

const sht_dynsym: u32 = 11;
const sht_gnu_verneed: u32 = 0x6ffffffe;
const sym_size = 24;
const verneed_size = 16;
const vernaux_size = 16;

/// One `.dynsym` entry. `name` borrows from the image.
pub const DynSymbol = struct {
    name: []const u8,
    /// False for an import (`st_shndx == SHN_UNDEF`).
    defined: bool,
};

/// `bytes[off..][0..len]`, or `error.Truncated` when it does not fit.
fn span(bytes: []const u8, off: u64, len: u64) ElfError![]const u8 {
    const end = std.math.add(u64, off, len) catch return error.Corrupt;
    if (end > bytes.len) return error.Truncated;
    return bytes[@intCast(off)..@intCast(end)];
}

/// The NUL-terminated string at `off` in the string table `strtab`.
fn strAt(strtab: []const u8, off: u64) ElfError![]const u8 {
    if (off >= strtab.len) return error.Corrupt;
    const s = strtab[@intCast(off)..];
    const n = std.mem.indexOfScalar(u8, s, 0) orelse return error.Corrupt;
    return s[0..n];
}

const Sections = struct {
    bytes: []const u8,
    shoff: u64,
    shnum: u64,

    fn init(bytes: []const u8) ElfError!Sections {
        if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf64;
        if (bytes.len < ehdr_size) return error.Truncated;
        if (bytes[4] != 2 or bytes[5] != 1) return error.NotElf64;
        const eh = Ehdr.parse(bytes[0..ehdr_size]);
        if (eh.shoff == 0) return .{ .bytes = bytes, .shoff = 0, .shnum = 0 };
        if (eh.shentsize != shdr_size) return error.Corrupt;
        var shnum: u64 = eh.shnum;
        if (shnum == 0) shnum = std.mem.readInt(u64, (try span(bytes, eh.shoff, shdr_size))[32..40], .little);
        const end = rangeEnd(eh.shoff, shnum, shdr_size) orelse return error.Corrupt;
        if (end > bytes.len) return error.Truncated;
        return .{ .bytes = bytes, .shoff = eh.shoff, .shnum = shnum };
    }

    const Header = struct { sh_type: u32, offset: u64, size: u64, link: u32, info: u32, entsize: u64 };

    fn header(s: Sections, i: u64) Header {
        // In range: `init` checked the whole table.
        const off: usize = @intCast(s.shoff + i * shdr_size);
        const h = s.bytes[off..][0..shdr_size];
        return .{
            .sh_type = std.mem.readInt(u32, h[4..8], .little),
            .offset = std.mem.readInt(u64, h[24..32], .little),
            .size = std.mem.readInt(u64, h[32..40], .little),
            .link = std.mem.readInt(u32, h[40..44], .little),
            .info = std.mem.readInt(u32, h[44..48], .little),
            .entsize = std.mem.readInt(u64, h[56..64], .little),
        };
    }

    fn data(s: Sections, h: Header) ElfError![]const u8 {
        return span(s.bytes, h.offset, h.size);
    }

    /// The data of the string table that section `h` links to.
    fn linked(s: Sections, h: Header) ElfError![]const u8 {
        if (h.link >= s.shnum) return error.Corrupt;
        return s.data(s.header(h.link));
    }
};

/// The dynamic symbols (`.dynsym`) of the 64-bit little-endian ELF image
/// `bytes`, in table order (entry 0, the null symbol, included). Names
/// borrow from `bytes`; free the slice with `a`.
pub fn dynamicSymbols(a: std.mem.Allocator, bytes: []const u8) (ElfError || std.mem.Allocator.Error)![]DynSymbol {
    const secs = try Sections.init(bytes);
    var out: std.ArrayList(DynSymbol) = .empty;
    errdefer out.deinit(a);
    var i: u64 = 0;
    while (i < secs.shnum) : (i += 1) {
        const h = secs.header(i);
        if (h.sh_type != sht_dynsym) continue;
        if (h.entsize != sym_size or h.size % sym_size != 0) return error.Corrupt;
        const syms = try secs.data(h);
        const strtab = try secs.linked(h);
        var at: usize = 0;
        while (at < syms.len) : (at += sym_size) {
            const e = syms[at..][0..sym_size];
            try out.append(a, .{
                .name = try strAt(strtab, std.mem.readInt(u32, e[0..4], .little)),
                .defined = std.mem.readInt(u16, e[6..8], .little) != 0,
            });
        }
    }
    return out.toOwnedSlice(a);
}

/// The symbol version names the image needs (`.gnu.version_r` auxiliary
/// entries, e.g. `GLIBC_2.28`), in file order. Names borrow from `bytes`;
/// free the slice with `a`.
pub fn neededVersions(a: std.mem.Allocator, bytes: []const u8) (ElfError || std.mem.Allocator.Error)![]const []const u8 {
    const secs = try Sections.init(bytes);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    var i: u64 = 0;
    while (i < secs.shnum) : (i += 1) {
        const h = secs.header(i);
        if (h.sh_type != sht_gnu_verneed) continue;
        const d = try secs.data(h);
        const strtab = try secs.linked(h);
        // `sh_info` entries, each followed by `vn_cnt` auxiliary entries;
        // the counts bound both loops.
        var at: u64 = 0;
        var n: u32 = 0;
        while (n < h.info) : (n += 1) {
            const vn = try span(d, at, verneed_size);
            const cnt = std.mem.readInt(u16, vn[2..4], .little);
            var aux_at = std.math.add(u64, at, std.mem.readInt(u32, vn[8..12], .little)) catch return error.Corrupt;
            var k: u16 = 0;
            while (k < cnt) : (k += 1) {
                const vna = try span(d, aux_at, vernaux_size);
                try out.append(a, try strAt(strtab, std.mem.readInt(u32, vna[8..12], .little)));
                const next = std.mem.readInt(u32, vna[12..16], .little);
                if (next == 0) break;
                aux_at = std.math.add(u64, aux_at, next) catch return error.Corrupt;
            }
            const next = std.mem.readInt(u32, vn[12..16], .little);
            if (next == 0) break;
            at = std.math.add(u64, at, next) catch return error.Corrupt;
        }
    }
    return out.toOwnedSlice(a);
}

const testing_support = @import("testing_support.zig");
const path = @import("path.zig");

fn put(buf: []u8, off: usize, comptime T: type, v: T) void {
    std.mem.writeInt(T, buf[off..][0..@sizeOf(T)], v, .little);
}

/// A valid 64-byte ELF64 header with no program or section headers.
fn minimalHeader() [64]u8 {
    var h = std.mem.zeroes([64]u8);
    @memcpy(h[0..4], "\x7fELF");
    h[4] = 2; // 64-bit
    h[5] = 1; // little endian
    h[6] = 1; // version
    put(&h, 16, u16, 3); // ET_DYN
    put(&h, 18, u16, 62); // x86-64
    put(&h, 20, u32, 1);
    put(&h, 52, u16, 64); // ehsize
    put(&h, 54, u16, 56); // phentsize
    put(&h, 58, u16, 64); // shentsize
    return h;
}

/// Header plus `n` zeroed 64-byte section headers at offset 64, with
/// `e_shnum = shnum`.
fn withSections(a: std.mem.Allocator, shnum: u16, n: usize) ![]u8 {
    const buf = try a.alloc(u8, 64 + 64 * n);
    @memset(buf, 0);
    const h = minimalHeader();
    @memcpy(buf[0..64], &h);
    put(buf, 40, u64, 64); // shoff
    put(buf, 60, u16, shnum);
    return buf;
}

fn checkBytes(bytes: []const u8, diag: *[256]u8) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.bin", .data = bytes });
    const f = try tmp.dir.openFile(io, "f.bin", .{});
    defer f.close(io);
    return checkComplete(io, f, diag);
}

test "elf minimal header passes" {
    var diag: [256]u8 = undefined;
    const h = minimalHeader();
    try checkBytes(&h, &diag);
}

test "elf not elf" {
    var diag: [256]u8 = undefined;
    const zeros = std.mem.zeroes([64]u8);
    try std.testing.expectError(error.NotElf64, checkBytes(&zeros, &diag));
    try std.testing.expect(diagText(&diag).len > 0);
    // Under 4 bytes there is no magic; with the magic but no full header the file is cut short.
    try std.testing.expectError(error.NotElf64, checkBytes("\x7fEL", &diag));
    try std.testing.expectError(error.Truncated, checkBytes("\x7fELF", &diag));
}

test "elf bad shoff" {
    var diag: [256]u8 = undefined;
    var h = minimalHeader();
    put(&h, 40, u64, 0xffff_ffff_ffff_fff0);
    put(&h, 60, u16, 2);
    try std.testing.expectError(error.Corrupt, checkBytes(&h, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diagText(&diag), "0xfffffffffffffff0") != null);
}

test "elf bad phoff" {
    var diag: [256]u8 = undefined;
    var h = minimalHeader();
    put(&h, 32, u64, 0xffff_ffff_ffff_fff0);
    put(&h, 56, u16, 1);
    try std.testing.expectError(error.Corrupt, checkBytes(&h, &diag));
    try std.testing.expect(diagText(&diag).len > 0);
}

test "elf sections past end of file are truncated" {
    var diag: [256]u8 = undefined;
    const a = std.testing.allocator;
    const full = try withSections(a, 3, 3);
    defer a.free(full);
    try checkBytes(full, &diag);
    try std.testing.expectError(error.Truncated, checkBytes(full[0 .. full.len - 1], &diag));
    try std.testing.expectError(error.Truncated, checkBytes(full[0..64], &diag));
}

test "elf extended numbering" {
    var diag: [256]u8 = undefined;
    const a = std.testing.allocator;
    // e_shnum = 0, section 0 holds the real count (5).
    const buf = try withSections(a, 0, 5);
    defer a.free(buf);
    put(buf, 64 + 32, u64, 5); // sh_size of section header 0
    try checkBytes(buf, &diag);
    // Cut inside header 4: the bound uses 5 headers, not 0.
    try std.testing.expectError(error.Truncated, checkBytes(buf[0 .. 64 + 4 * 64 + 10], &diag));
    // Section header 0 itself is cut off.
    try std.testing.expectError(error.Truncated, checkBytes(buf[0 .. 64 + 10], &diag));
    // A count that overflows when multiplied is corrupt.
    put(buf, 64 + 32, u64, std.math.maxInt(u64));
    try std.testing.expectError(error.Corrupt, checkBytes(buf, &diag));
}

test "elf load segment past end of file is truncated" {
    var diag: [256]u8 = undefined;
    const a = std.testing.allocator;
    const buf = try a.alloc(u8, 64 + 56);
    defer a.free(buf);
    @memset(buf, 0);
    const h = minimalHeader();
    @memcpy(buf[0..64], &h);
    put(buf, 32, u64, 64); // phoff
    put(buf, 56, u16, 1); // phnum
    put(buf, 64, u32, 1); // PT_LOAD
    put(buf, 64 + 8, u64, 0); // p_offset
    put(buf, 64 + 32, u64, 1000); // p_filesz > file
    try std.testing.expectError(error.Truncated, checkBytes(buf, &diag));
    put(buf, 64 + 32, u64, buf.len);
    try checkBytes(buf, &diag);
    put(buf, 64 + 8, u64, std.math.maxInt(u64));
    try std.testing.expectError(error.Corrupt, checkBytes(buf, &diag));
}

/// A small shared-library image: `.dynstr`, `.dynsym` (null, `foo`
/// defined, `bar` imported) and `.gnu.version_r` (libc.so.6 with
/// GLIBC_2.28 and GLIBC_2.2.5). Section headers at `symImageShoff`.
const SymImage = struct {
    const strtab = "\x00foo\x00bar\x00libc.so.6\x00GLIBC_2.28\x00GLIBC_2.2.5\x00";
    const str_off = 64;
    const sym_off = str_off + 48; // 8-aligned, past the strings
    const vn_off = sym_off + 3 * sym_size;
    const shoff = vn_off + verneed_size + 2 * vernaux_size;
    const len = shoff + 4 * shdr_size;
    // Section header indexes.
    const dynsym_sh = 2;
    const verneed_sh = 3;

    fn build() [len]u8 {
        var b = std.mem.zeroes([len]u8);
        const h = minimalHeader();
        @memcpy(b[0..64], &h);
        put(&b, 40, u64, shoff);
        put(&b, 60, u16, 4);
        @memcpy(b[str_off..][0..strtab.len], strtab);
        // Symbols: 0 null; 1 foo, defined (shndx 2); 2 bar, undefined.
        put(&b, sym_off + sym_size + 0, u32, 1);
        put(&b, sym_off + sym_size + 6, u16, 2);
        put(&b, sym_off + 2 * sym_size + 0, u32, 5);
        // Verneed: version 1, 2 aux entries, file "libc.so.6", aux at +16, last.
        put(&b, vn_off + 0, u16, 1);
        put(&b, vn_off + 2, u16, 2);
        put(&b, vn_off + 4, u32, 9);
        put(&b, vn_off + 8, u32, verneed_size);
        put(&b, vn_off + verneed_size + 8, u32, 19); // GLIBC_2.28
        put(&b, vn_off + verneed_size + 12, u32, vernaux_size);
        put(&b, vn_off + verneed_size + vernaux_size + 8, u32, 30); // GLIBC_2.2.5
        // Section headers: 0 null, 1 strtab, 2 dynsym, 3 verneed.
        section(&b, 1, 3, str_off, strtab.len, 0, 0, 0);
        section(&b, dynsym_sh, sht_dynsym, sym_off, 3 * sym_size, 1, 1, sym_size);
        section(&b, verneed_sh, sht_gnu_verneed, vn_off, verneed_size + 2 * vernaux_size, 1, 1, 0);
        return b;
    }

    fn section(b: []u8, i: usize, sh_type: u32, off: u64, size: u64, link: u32, info: u32, entsize: u64) void {
        const at = shoff + i * shdr_size;
        put(b, at + 4, u32, sh_type);
        put(b, at + 24, u64, off);
        put(b, at + 32, u64, size);
        put(b, at + 40, u32, link);
        put(b, at + 44, u32, info);
        put(b, at + 56, u64, entsize);
    }

    fn field(i: usize, comptime off: usize) usize {
        return shoff + i * shdr_size + off;
    }
};

test "dynamic symbols and needed versions" {
    const a = std.testing.allocator;
    const img = SymImage.build();
    const syms = try dynamicSymbols(a, &img);
    defer a.free(syms);
    try std.testing.expectEqual(@as(usize, 3), syms.len);
    try std.testing.expectEqualStrings("", syms[0].name);
    try std.testing.expectEqualStrings("foo", syms[1].name);
    try std.testing.expect(syms[1].defined);
    try std.testing.expectEqualStrings("bar", syms[2].name);
    try std.testing.expect(!syms[2].defined);
    const vers = try neededVersions(a, &img);
    defer a.free(vers);
    try std.testing.expectEqual(@as(usize, 2), vers.len);
    try std.testing.expectEqualStrings("GLIBC_2.28", vers[0]);
    try std.testing.expectEqualStrings("GLIBC_2.2.5", vers[1]);
}

test "malformed symbol tables fail instead of looping or reading out of bounds" {
    const a = std.testing.allocator;
    // Symbol entry size 0 (Task 0's test helper looped for ever on it).
    var img = SymImage.build();
    put(&img, SymImage.field(SymImage.dynsym_sh, 56), u64, 0);
    try std.testing.expectError(error.Corrupt, dynamicSymbols(a, &img));
    // Symbol table past the end of the file.
    img = SymImage.build();
    put(&img, SymImage.field(SymImage.dynsym_sh, 24), u64, img.len);
    try std.testing.expectError(error.Truncated, dynamicSymbols(a, &img));
    // Offset plus size overflows.
    put(&img, SymImage.field(SymImage.dynsym_sh, 24), u64, std.math.maxInt(u64) - 8);
    try std.testing.expectError(error.Corrupt, dynamicSymbols(a, &img));
    // A name offset outside the string table.
    img = SymImage.build();
    put(&img, SymImage.sym_off + sym_size, u32, 1000);
    try std.testing.expectError(error.Corrupt, dynamicSymbols(a, &img));
    // A string table link past the section count.
    img = SymImage.build();
    put(&img, SymImage.field(SymImage.dynsym_sh, 40), u32, 99);
    try std.testing.expectError(error.Corrupt, dynamicSymbols(a, &img));
    // A version entry chain that points out of its section.
    img = SymImage.build();
    put(&img, SymImage.vn_off + verneed_size + 12, u32, 4096);
    try std.testing.expectError(error.Truncated, neededVersions(a, &img));
    // Section headers cut off; not an ELF at all.
    try std.testing.expectError(error.Truncated, dynamicSymbols(a, img[0 .. img.len - 1]));
    try std.testing.expectError(error.NotElf64, dynamicSymbols(a, "nope"));
}

test "every single-byte change of a symbol image ends" {
    const a = std.testing.allocator;
    const good = SymImage.build();
    for (0..good.len) |i| {
        for ([_]u8{ 0, 1, 0x7f, 0xff }) |v| {
            var img = good;
            img[i] = v;
            if (dynamicSymbols(a, &img)) |s| a.free(s) else |_| {}
            if (neededVersions(a, &img)) |s| a.free(s) else |_| {}
        }
    }
}

const FuzzCtx = struct {
    fn run(_: @This(), smith: *std.testing.Smith) anyerror!void {
        var buf: [4096]u8 = undefined;
        const n = smith.slice(&buf);
        var diag: [256]u8 = undefined;
        checkBytes(buf[0..n], &diag) catch |err| switch (err) {
            error.NotElf64, error.Truncated, error.Corrupt => {
                try std.testing.expect(diagText(&diag).len > 0);
                return;
            },
            else => return err,
        };
    }
};

test "fuzz checkComplete" {
    const header = minimalHeader();
    const zeros = std.mem.zeroes([64]u8);
    try std.testing.fuzz(FuzzCtx{}, FuzzCtx.run, .{ .corpus = &.{ &header, &zeros } });
}

test "integration: elf ok" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lib = try testing_support.buildAnswerLib(a, tmp);
    defer a.free(lib.bytes);
    const f = try std.Io.Dir.cwd().openFile(io, lib.bytes, .{});
    defer f.close(io);
    var diag: [256]u8 = undefined;
    try checkComplete(io, f, &diag);
}

test "integration: elf truncated" {
    try testing_support.requireIntegration();
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lib = try testing_support.buildAnswerLib(a, tmp);
    defer a.free(lib.bytes);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, lib.bytes, a, .unlimited);
    defer a.free(bytes);
    const shoff = std.mem.readInt(u64, bytes[40..48], .little);
    var diag: [256]u8 = undefined;
    // Half the file, and everything before the section headers.
    try std.testing.expectError(error.Truncated, checkBytes(bytes[0 .. bytes.len / 2], &diag));
    try std.testing.expect(diagText(&diag).len > 0);
    try std.testing.expectError(error.Truncated, checkBytes(bytes[0..@intCast(shoff)], &diag));
}
