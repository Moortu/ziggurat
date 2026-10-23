//! minisign signature check for downloaded Zig archives (L1, std only).
//! Format: https://jedisct1.github.io/minisign/ ("Public key format",
//! "Signature format").
const std = @import("std");
const pins = @import("pins.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

pub const Error = error{
    /// The text is not a minisign public key or signature file.
    Malformed,
    /// The signature uses the legacy `Ed` format (the file itself is signed,
    /// not its BLAKE2b-512 hash). New tools must not accept it by default.
    LegacyAlgorithm,
    /// The signature was made by another key.
    KeyIdMismatch,
    /// The file signature does not match the digest.
    BadSignature,
    /// The signature over the trusted comment does not match.
    BadGlobalSignature,
    /// The trusted comment names another file (or no file).
    FileNameMismatch,
};

/// Signature files longer than this are refused as `Malformed`.
pub const max_signature_text = 4096;

pub const digest_length = Blake2b512.digest_length;

pub const PublicKey = struct {
    key_id: [8]u8,
    key: Ed25519.PublicKey,

    /// Parses the base64 line of a minisign public key (`Ed` || key id ||
    /// Ed25519 key, 42 bytes).
    pub fn parse(b64: []const u8) error{Malformed}!PublicKey {
        var raw: [42]u8 = undefined;
        try decodeExact(&raw, b64);
        if (!std.mem.eql(u8, raw[0..2], "Ed")) return error.Malformed;
        const key = Ed25519.PublicKey.fromBytes(raw[10..42].*) catch return error.Malformed;
        return .{ .key_id = raw[2..10].*, .key = key };
    }
};

pub const Algorithm = enum { prehashed, legacy };

/// A parsed signature file. `trusted_comment` points into the text.
pub const Signature = struct {
    algorithm: Algorithm,
    key_id: [8]u8,
    signature: [64]u8,
    trusted_comment: []const u8,
    global_signature: [64]u8,
};

/// Parses the four lines of a `.minisig` file. A newline after the last
/// line is optional; anything else after it is refused.
pub fn parseSignature(text: []const u8) error{Malformed}!Signature {
    if (text.len > max_signature_text) return error.Malformed;
    var rest = text;
    const untrusted = try takeLine(&rest);
    const sig_line = try takeLine(&rest);
    const trusted = try takeLine(&rest);
    // The last line: a final newline is optional, nothing may follow it.
    const global_line = if (std.mem.indexOfScalar(u8, rest, '\n')) |i| blk: {
        if (i + 1 != rest.len) return error.Malformed;
        break :blk rest[0..i];
    } else rest;

    if (!std.mem.startsWith(u8, untrusted, untrusted_prefix)) return error.Malformed;
    if (!std.mem.startsWith(u8, trusted, trusted_prefix)) return error.Malformed;

    var head: [74]u8 = undefined;
    try decodeExact(&head, sig_line);
    const algorithm: Algorithm = if (std.mem.eql(u8, head[0..2], "ED"))
        .prehashed
    else if (std.mem.eql(u8, head[0..2], "Ed"))
        .legacy
    else
        return error.Malformed;

    var global: [64]u8 = undefined;
    try decodeExact(&global, global_line);
    return .{
        .algorithm = algorithm,
        .key_id = head[2..10].*,
        .signature = head[10..74].*,
        .trusted_comment = trusted[trusted_prefix.len..],
        .global_signature = global,
    };
}

const untrusted_prefix = "untrusted comment: ";
const trusted_prefix = "trusted comment: ";

/// The text up to the next LF; `rest` moves past it. A missing LF or a CR
/// in the line is refused.
fn takeLine(rest: *[]const u8) error{Malformed}![]const u8 {
    const i = std.mem.indexOfScalar(u8, rest.*, '\n') orelse return error.Malformed;
    const line = rest.*[0..i];
    rest.* = rest.*[i + 1 ..];
    if (std.mem.indexOfScalar(u8, line, '\r') != null) return error.Malformed;
    return line;
}

/// Decodes padded standard base64 that must give exactly `out.len` bytes.
fn decodeExact(out: []u8, text: []const u8) error{Malformed}!void {
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(text) catch return error.Malformed;
    if (n != out.len) return error.Malformed;
    decoder.decode(out, text) catch return error.Malformed;
}

/// The value of the one `file:` field of a TAB-separated trusted comment,
/// or null when there is none or more than one.
fn fileField(comment: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, comment, '\t');
    while (it.next()) |field| {
        if (!std.mem.startsWith(u8, field, "file:")) continue;
        if (found != null) return null;
        found = field["file:".len..];
    }
    return found;
}

/// Checks the format (`ED` only), the key id and the global signature (over
/// the signature and the trusted comment). It does not check the file.
pub fn verifyGlobal(key: PublicKey, sig_text: []const u8) Error!Signature {
    const sig = try parseChecked(key, sig_text);
    try checkGlobal(key, sig);
    return sig;
}

/// Parses and checks the format (`ED` only) and the key id.
fn parseChecked(key: PublicKey, sig_text: []const u8) Error!Signature {
    const sig = try parseSignature(sig_text);
    if (sig.algorithm == .legacy) return error.LegacyAlgorithm;
    if (!std.mem.eql(u8, &sig.key_id, &key.key_id)) return error.KeyIdMismatch;
    return sig;
}

fn checkGlobal(key: PublicKey, sig: Signature) Error!void {
    const global = Ed25519.Signature.fromBytes(sig.global_signature);
    var v = global.verifier(key.key) catch return error.BadGlobalSignature;
    v.update(&sig.signature);
    v.update(sig.trusted_comment);
    v.verifyStrict() catch return error.BadGlobalSignature;
}

/// Full check of a downloaded file: format (`ED` only) and key id, the file
/// signature over `digest` (BLAKE2b-512 of the file), the global signature,
/// then the trusted comment's one `file:` field must equal `expected_file`.
pub fn verifyFile(key: PublicKey, sig_text: []const u8, digest: [digest_length]u8, expected_file: []const u8) Error!void {
    const sig = try parseChecked(key, sig_text);
    Ed25519.Signature.fromBytes(sig.signature).verifyStrict(&digest, key.key) catch return error.BadSignature;
    try checkGlobal(key, sig);
    const name = fileField(sig.trusted_comment) orelse return error.FileNameMismatch;
    if (!std.mem.eql(u8, name, expected_file)) return error.FileNameMismatch;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const build_options = @import("build_options");

/// A minisign key made from a fixed seed, for tests.
pub const TestSigner = struct {
    pair: Ed25519.KeyPair,
    key_id: [8]u8,

    pub fn init(seed_byte: u8, key_id: [8]u8) TestSigner {
        const pair = Ed25519.KeyPair.generateDeterministic(@splat(seed_byte)) catch unreachable;
        return .{ .pair = pair, .key_id = key_id };
    }

    /// The base64 public key line.
    pub fn publicText(self: TestSigner, buf: *[56]u8) []const u8 {
        var raw: [42]u8 = undefined;
        raw[0..2].* = "Ed".*;
        raw[2..10].* = self.key_id;
        raw[10..42].* = self.pair.public_key.toBytes();
        return std.base64.standard.Encoder.encode(buf, &raw);
    }

    pub fn publicKey(self: TestSigner) PublicKey {
        return .{ .key_id = self.key_id, .key = self.pair.public_key };
    }

    /// A `.minisig` text. `alg` is "ED" or "Ed"; `message` is what the file
    /// signature covers (the digest for "ED"); `comment` is the trusted
    /// comment. The caller frees the result.
    pub fn sign(self: TestSigner, a: std.mem.Allocator, alg: *const [2]u8, message: []const u8, comment: []const u8) ![]u8 {
        const sig = (try self.pair.sign(message, null)).toBytes();
        var head: [74]u8 = undefined;
        head[0..2].* = alg.*;
        head[2..10].* = self.key_id;
        head[10..74].* = sig;
        var global_msg: std.ArrayList(u8) = .empty;
        defer global_msg.deinit(a);
        try global_msg.appendSlice(a, &sig);
        try global_msg.appendSlice(a, comment);
        const global = (try self.pair.sign(global_msg.items, null)).toBytes();
        var head_b64: [100]u8 = undefined;
        var global_b64: [88]u8 = undefined;
        return std.fmt.allocPrint(a, "untrusted comment: signature from minisign secret key\n{s}\ntrusted comment: {s}\n{s}\n", .{
            std.base64.standard.Encoder.encode(&head_b64, &head),
            comment,
            std.base64.standard.Encoder.encode(&global_b64, &global),
        });
    }

    /// Signs `data` the way the Zig release files are signed.
    pub fn signFile(self: TestSigner, a: std.mem.Allocator, data: []const u8, file_name: []const u8) ![]u8 {
        var digest: [digest_length]u8 = undefined;
        Blake2b512.hash(data, &digest, .{});
        const comment = try std.fmt.allocPrint(a, "timestamp:1790965431\tfile:{s}\thashed", .{file_name});
        defer a.free(comment);
        return self.sign(a, "ED", &digest, comment);
    }
};

const test_key_id = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
const test_name = "zig-x86_64-linux-0.17.0.tar.xz";
const test_data = "pretend this is a Zig archive";

fn testDigest() [digest_length]u8 {
    var d: [digest_length]u8 = undefined;
    Blake2b512.hash(test_data, &d, .{});
    return d;
}

test "minisign: pinned key parses" {
    const key = try PublicKey.parse(pins.zig_minisign_key);
    try testing.expectEqualSlices(u8, &.{ 0x86, 0x3a, 0xad, 0x8d, 0x55, 0xe7, 0x00, 0xd9 }, &key.key_id);
    try testing.expectError(error.Malformed, PublicKey.parse(""));
    try testing.expectError(error.Malformed, PublicKey.parse(pins.zig_minisign_key[0 .. pins.zig_minisign_key.len - 4]));
    try testing.expectError(error.Malformed, PublicKey.parse(pins.zig_minisign_key ++ " "));
    // Right length, wrong algorithm prefix ("ED" instead of "Ed").
    try testing.expectError(error.Malformed, PublicKey.parse("RUSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U"));
}

test "real zig signature global part verifies" {
    const a = testing.allocator;
    const io = testing.io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, build_options.toolchain_real_minisig, a, .limited(max_signature_text));
    defer a.free(text);
    const key = try PublicKey.parse(pins.zig_minisign_key);
    const sig = try verifyGlobal(key, text);
    try testing.expectEqual(Algorithm.prehashed, sig.algorithm);
    try testing.expectEqualStrings("timestamp:1790965431\tfile:zig-x86_64-linux-0.17.0.tar.xz\thashed", sig.trusted_comment);
    const zeros: [digest_length]u8 = @splat(0);
    try testing.expectError(error.BadSignature, verifyFile(key, text, zeros, test_name));
    // Another key id: refused before any signature is checked.
    var other = key;
    other.key_id[0] ^= 1;
    try testing.expectError(error.KeyIdMismatch, verifyGlobal(other, text));
    // A changed trusted comment breaks the global signature.
    const changed = try std.mem.replaceOwned(u8, a, text, "timestamp:1790965431", "timestamp:1790965432");
    defer a.free(changed);
    try testing.expectError(error.BadGlobalSignature, verifyGlobal(key, changed));
}

test "ED passes" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    const text = try s.signFile(a, test_data, test_name);
    defer a.free(text);
    try verifyFile(s.publicKey(), text, testDigest(), test_name);
    // The same key through its text form.
    var buf: [56]u8 = undefined;
    try verifyFile(try PublicKey.parse(s.publicText(&buf)), text, testDigest(), test_name);
    var other = testDigest();
    other[5] ^= 0x40;
    try testing.expectError(error.BadSignature, verifyFile(s.publicKey(), text, other, test_name));
    // Another key with the same key id.
    const t = TestSigner.init(8, test_key_id);
    try testing.expectError(error.BadSignature, verifyFile(t.publicKey(), text, testDigest(), test_name));
}

test "legacy Ed refused" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    // A valid legacy signature over the file itself.
    const text = try s.sign(a, "Ed", test_data, "timestamp:1\tfile:" ++ test_name);
    defer a.free(text);
    try testing.expectError(error.LegacyAlgorithm, verifyFile(s.publicKey(), text, testDigest(), test_name));
    const odd = try s.sign(a, "EX", &testDigest(), "timestamp:1\tfile:" ++ test_name);
    defer a.free(odd);
    try testing.expectError(error.Malformed, verifyFile(s.publicKey(), odd, testDigest(), test_name));
}

test "file name mismatch" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    // Signed for 0.16.0: a downgrade to another signed release.
    const text = try s.signFile(a, test_data, "zig-x86_64-linux-0.16.0.tar.xz");
    defer a.free(text);
    try testing.expectError(error.FileNameMismatch, verifyFile(s.publicKey(), text, testDigest(), test_name));
    // A prefix of the expected name is not enough.
    const short = try s.sign(a, "ED", &testDigest(), "timestamp:1\tfile:zig-x86_64-linux-0.17.0.tar");
    defer a.free(short);
    try testing.expectError(error.FileNameMismatch, verifyFile(s.publicKey(), short, testDigest(), test_name));
    // No file field.
    const none = try s.sign(a, "ED", &testDigest(), "timestamp:1\thashed");
    defer a.free(none);
    try testing.expectError(error.FileNameMismatch, verifyFile(s.publicKey(), none, testDigest(), test_name));
    // Two file fields.
    const two = try s.sign(a, "ED", &testDigest(), "file:" ++ test_name ++ "\tfile:" ++ test_name);
    defer a.free(two);
    try testing.expectError(error.FileNameMismatch, verifyFile(s.publicKey(), two, testDigest(), test_name));
}

test "tab-separated comment" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    // TAB separators (as in the real files) pass.
    const tabs = try s.sign(a, "ED", &testDigest(), "timestamp:1790965431\tfile:" ++ test_name ++ "\thashed");
    defer a.free(tabs);
    try verifyFile(s.publicKey(), tabs, testDigest(), test_name);
    // The file field may be last.
    const last = try s.sign(a, "ED", &testDigest(), "timestamp:1790965431\tfile:" ++ test_name);
    defer a.free(last);
    try verifyFile(s.publicKey(), last, testDigest(), test_name);
    // Space separators do not split fields: "file:<name> hashed" is not the name.
    const spaces = try s.sign(a, "ED", &testDigest(), "timestamp:1790965431 file:" ++ test_name ++ " hashed");
    defer a.free(spaces);
    try testing.expectError(error.FileNameMismatch, verifyFile(s.publicKey(), spaces, testDigest(), test_name));
}

test "missing trailing newline accepted" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    const text = try s.signFile(a, test_data, test_name);
    defer a.free(text);
    try testing.expect(text[text.len - 1] == '\n');
    try verifyFile(s.publicKey(), text[0 .. text.len - 1], testDigest(), test_name);
}

test "trailing garbage refused" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    const text = try s.signFile(a, test_data, test_name);
    defer a.free(text);
    const key = s.publicKey();
    const d = testDigest();
    for ([_][]const u8{ "\n", "x", "\nx", " ", "\r\n" }) |tail| {
        const bad = try std.mem.concat(a, u8, &.{ text, tail });
        defer a.free(bad);
        try testing.expectError(error.Malformed, verifyFile(key, bad, d, test_name));
    }
    // Truncated texts, empty text, a CRLF file, and a missing prefix.
    for (0..text.len - 1) |n| {
        if (verifyFile(key, text[0..n], d, test_name)) |_| return error.TestUnexpectedResult else |_| {}
    }
    const crlf = try std.mem.replaceOwned(u8, a, text, "\n", "\r\n");
    defer a.free(crlf);
    try testing.expectError(error.Malformed, verifyFile(key, crlf, d, test_name));
    const no_prefix = try std.mem.replaceOwned(u8, a, text, "untrusted comment: ", "");
    defer a.free(no_prefix);
    try testing.expectError(error.Malformed, verifyFile(key, no_prefix, d, test_name));
    const big = try a.alloc(u8, max_signature_text + 1);
    defer a.free(big);
    @memset(big, 'A');
    try testing.expectError(error.Malformed, verifyFile(key, big, d, test_name));
}

test "wrong key id" {
    const a = testing.allocator;
    const s = TestSigner.init(7, test_key_id);
    const text = try s.signFile(a, test_data, test_name);
    defer a.free(text);
    // The same Ed25519 key, but the public key names another id.
    const other = TestSigner.init(7, .{ 9, 9, 9, 9, 9, 9, 9, 9 });
    try testing.expectError(error.KeyIdMismatch, verifyFile(other.publicKey(), text, testDigest(), test_name));
    // The pinned key refuses a signature from the test key.
    try testing.expectError(error.KeyIdMismatch, verifyFile(try PublicKey.parse(pins.zig_minisign_key), text, testDigest(), test_name));
}
