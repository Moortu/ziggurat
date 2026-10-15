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
fn setDiag(diag: *[256]u8, comptime fmt: []const u8, args: anytype) void {
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
    const ident_ok = try readAt(io, file, &raw, 0);
    if (!ident_ok or !std.mem.eql(u8, raw[0..4], "\x7fELF") or raw[4] != 2 or raw[5] != 1) {
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
    // A file shorter than a header is not an ELF file either.
    try std.testing.expectError(error.NotElf64, checkBytes("\x7fELF", &diag));
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
