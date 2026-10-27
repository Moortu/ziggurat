//! Joins a thin arm64 dylib and a thin x86_64 dylib into one universal
//! (fat) file (L1, std only), as `lipo -create` writes it: a big-endian
//! FAT_MAGIC header and arch table, then the x86_64 slice and the arm64
//! slice, each at the next multiple of 2^14, zero bytes between them, and
//! the file ending with the last slice. The output depends only on the two
//! inputs. tools/macho_fat.zig is the command line over it; the macOS
//! export build uses it too.
//!
//! Both inputs must be complete thin images (`macho.checkComplete`) of the
//! named CPU: a fat input, two slices of one arch or swapped inputs are
//! refused, so a universal file never has a slice whose checks were not
//! run. The output is checked again with `macho.checkComplete`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const macho = @import("macho.zig");

/// The slice alignment, as a power of two: 2^14, the arm64 page size.
pub const align_log2 = 14;

pub const Error = macho.Error || Allocator.Error || error{
    /// An input is a fat file, not one thin image.
    NotThin,
    /// An input is not of the CPU type its place names (arm64 first,
    /// x86_64 second).
    WrongCpu,
    /// The output would pass 4 GiB, the limit of FAT_MAGIC's 32-bit offsets.
    TooLarge,
};

const fat_header_size = 8;
const fat_arch_size = 20;

/// The inputs in output order, with the CPU each must have.
const Input = struct { bytes: []const u8, cpu: macho.Cpu, name: []const u8, place: []const u8 };

/// The universal file of `arm64` and `x86_64` (each the bytes of a thin
/// dylib). On an error, `diag` gets one sentence about it (NUL-terminated).
/// The caller frees the result.
pub fn join(a: Allocator, arm64: []const u8, x86_64: []const u8, diag: ?*[256]u8) Error![]u8 {
    const inputs = [_]Input{
        .{ .bytes = x86_64, .cpu = .x86_64, .name = "x86_64", .place = "second" },
        .{ .bytes = arm64, .cpu = .arm64, .name = "arm64", .place = "first" },
    };
    for (inputs) |in| try checkInput(in, diag);

    const unit: u64 = 1 << align_log2;
    var offsets: [inputs.len]u64 = undefined;
    var end: u64 = fat_header_size + fat_arch_size * inputs.len;
    for (&offsets, inputs) |*off, in| {
        off.* = std.mem.alignForward(u64, end, unit);
        end = off.* + in.bytes.len;
    }
    if (end > std.math.maxInt(u32)) {
        setDiag(diag, "The universal file would have {d} bytes; FAT_MAGIC allows at most 4 GiB.", .{end});
        return error.TooLarge;
    }

    const out = try a.alloc(u8, @intCast(end));
    errdefer a.free(out);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], std.macho.FAT_MAGIC, .big);
    std.mem.writeInt(u32, out[4..8], inputs.len, .big);
    for (inputs, offsets, 0..) |in, off, i| {
        const e = out[fat_header_size + fat_arch_size * i ..][0..fat_arch_size];
        std.mem.writeInt(u32, e[0..4], @backingInt(in.cpu), .big);
        // cpusubtype as the image's header has it.
        std.mem.writeInt(u32, e[4..8], std.mem.readInt(u32, in.bytes[8..12], .little), .big);
        std.mem.writeInt(u32, e[8..12], @intCast(off), .big);
        std.mem.writeInt(u32, e[12..16], @intCast(in.bytes.len), .big);
        std.mem.writeInt(u32, e[16..20], align_log2, .big);
        @memcpy(out[@intCast(off)..][0..in.bytes.len], in.bytes);
    }
    // The output must pass the reader's own check (alignment, CPU types,
    // ranges); the loader and the export checks run the same one.
    macho.checkCompleteDiag(out, diag) catch |err| return err;
    return out;
}

/// Refuses an input that is not a complete thin image of `in.cpu`.
fn checkInput(in: Input, diag: ?*[256]u8) Error!void {
    var inner: [256]u8 = @splat(0);
    macho.checkCompleteDiag(in.bytes, &inner) catch |err| {
        setDiag(diag, "The {s} input (the {s} one): {s}", .{ in.name, in.place, std.mem.sliceTo(&inner, 0) });
        return err;
    };
    // A complete file is a thin image (MH_MAGIC_64) or a fat file.
    if (std.mem.readInt(u32, in.bytes[0..4], .little) != std.macho.MH_MAGIC_64) {
        setDiag(diag, "The {s} input (the {s} one) is a fat file; it must be one thin {s} dylib.", .{ in.name, in.place, in.name });
        return error.NotThin;
    }
    const cpu: macho.Cpu = @fromBackingInt(std.mem.readInt(u32, in.bytes[4..8], .little));
    if (cpu != in.cpu) {
        setDiag(diag, "The {s} input (the {s} one) has the CPU type {s}; it must be a thin {s} dylib.", .{ in.name, in.place, cpuName(cpu), in.name });
        return error.WrongCpu;
    }
}

fn cpuName(cpu: macho.Cpu) []const u8 {
    return switch (cpu) {
        .x86_64 => "x86_64",
        .arm64 => "arm64",
        _ => "of another CPU",
    };
}

/// Writes one sentence into `diag`, NUL-terminated, cut to fit if too long
/// (the form of `macho.zig`'s own).
fn setDiag(diag: ?*[256]u8, comptime fmt: []const u8, args: anytype) void {
    const d = diag orelse return;
    @memset(d, 0);
    var w: std.Io.Writer = .fixed(d[0..255]);
    w.print(fmt, args) catch {};
}
