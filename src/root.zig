//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const testing = std.testing;

const Alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const InverseAlphabet = init: {
    // 255 represents an invalid value
    var table = [1]u8{255} ** 256;
    for (Alphabet, 0..) |c, i| {
        table[c] = @intCast(i);
    }

    break :init table;
};

// intermediate base 58^5
const intermediate_base: u64 = 656356768;

fn intermediateSize(comptime N: usize) usize {
    return switch (N) {
        32 => 9,
        64 => 18,
        else => @compileError("unsupported byte size, only 32 and 64 are supported"),
    };
}

fn makeEncTable(comptime N: usize) [N / 4][intermediateSize(N) - 1]u32 {
    const binary_sz = N / 4;
    const cols = intermediateSize(N) - 1;
    const base: comptime_int = 656356768;

    var table: [binary_sz][cols]u32 = .{.{0} ** cols} ** binary_sz;

    for (0..binary_sz) |i| {
        var value: comptime_int = 1 << (32 * (binary_sz - 1 - i));
        var j: usize = cols;
        while (j > 0) {
            j -= 1;
            table[i][j] = @intCast(value % base);
            value /= base;
        }
    }

    return table;
}

const enc_table_32: [8][8]u32 = makeEncTable(32);
const enc_table_64: [16][17]u32 = makeEncTable(64);

fn makeDecTable(comptime N: usize) [intermediateSize(N)][N / 4]u32 {
    @setEvalBranchQuota(10000);

    const inter_sz = intermediateSize(N);
    const binary_sz = N / 4;
    const base: comptime_int = 1 << 32;

    var table: [inter_sz][binary_sz]u32 = .{.{0} ** binary_sz} ** inter_sz;
    for (0..inter_sz) |j| {
        var value: comptime_int = 1;
        var p: usize = 0;
        while (p < 5 * (inter_sz - 1 - j)) : (p += 1) value *= 58;
        var k: usize = binary_sz;
        while (k > 0) {
            k -= 1;
            table[j][k] = @intCast(value % base);
            value /= base;
        }
    }

    return table;
}

const dec_table_32: [9][8]u32 = makeDecTable(32);
const dec_table_64: [18][16]u32 = makeDecTable(64);

pub const Base58Error = error{ Decode, InvalidCharacter, NoSpaceLeft };

/// Returns the minimum buffer size needed for encode(dst, src) given src.len.
/// For 32 and 64-byte inputs the fast path (encode32/encode64) needs a working
/// buffer of intermediateSize(N)*5, which exceeds the generic formula for N=64.
pub fn encodedLen(src_len: usize) usize {
    return switch (src_len) {
        32 => comptime encodedMaxLen(32),
        64 => comptime encodedMaxLen(64),
        else => (src_len * 138 / 100) + 1,
    };
}

/// Returns the maximum buffer size needed for decode(dst, src) given src.len.
pub fn decodedLen(src_len: usize) usize {
    return src_len;
}

pub fn encode(dst: []u8, src: []const u8) ![]u8 {
    return switch (src.len) {
        32 => encode32(dst, src[0..32].*),
        64 => encode64(dst, src[0..64].*),
        else => _encode(dst, src),
    };
}

pub fn encodeAlloc(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, encodedLen(src.len));
    errdefer allocator.free(buf);
    const result = try encode(buf, src);
    return allocator.realloc(buf, result.len);
}

pub fn decodeAlloc(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, decodedLen(src.len));
    errdefer allocator.free(buf);
    const result = try decode(buf, src);
    return allocator.realloc(buf, result.len);
}

/// Encodes src into dst using Base58.
/// dst must be at least encodedLen(src.len) bytes.
/// Returns a slice of dst containing the encoded result.
fn _encode(dst: []u8, src: []const u8) ![]u8 {
    if (src.len == 0) return dst[0..0];

    var zero_cnt: usize = 0;
    while (zero_cnt < src.len and src[zero_cnt] == 0) : (zero_cnt += 1) {}

    const intermediate_len = encodedLen(src.len - zero_cnt);
    if (dst.len < intermediate_len) return Base58Error.NoSpaceLeft;

    @memset(dst[0..intermediate_len], 0);

    var high: usize = 0;
    for (src[zero_cnt..]) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;
        while (i < high or carry > 0) {
            const current = carry + @as(u32, dst[i]) * 256;
            dst[i] = @intCast(current % 58);
            carry = current / 58;
            i += 1;
        }
        high = i;
    }

    const out_len = zero_cnt + high;
    if (out_len > dst.len) return Base58Error.NoSpaceLeft;

    // dst[0..high] is LSB-first raw base58 indices. Reverse to MSB-first,
    // shift right by zero_cnt (copyBackwards handles src/dst overlap safely),
    // fill leading '1's, then map indices to alphabet characters.
    std.mem.reverse(u8, dst[0..high]);
    std.mem.copyBackwards(u8, dst[zero_cnt..out_len], dst[0..high]);
    @memset(dst[0..zero_cnt], '1');
    for (dst[zero_cnt..out_len]) |*c| c.* = Alphabet[c.*];

    return dst[0..out_len];
}

/// Decodes a Base58-encoded src into dst.
/// dst must be at least src.len bytes.
/// Returns a slice of dst containing the decoded result.
pub fn decode(dst: []u8, src: []const u8) ![]u8 {
    if (src.len == 0) return dst[0..0];

    var zero_cnt: usize = 0;
    while (zero_cnt < src.len and src[zero_cnt] == '1') : (zero_cnt += 1) {}

    const intermediate_len = decoded_len(src.len - zero_cnt);
    if (dst.len < intermediate_len) return Base58Error.NoSpaceLeft;

    @memset(dst[0..intermediate_len], 0);

    var high: usize = 0;
    for (src[zero_cnt..]) |c| {
        const char_idx = InverseAlphabet[c];
        if (char_idx == 255) return Base58Error.InvalidCharacter;

        var carry: u32 = @intCast(char_idx);
        var i: usize = 0;
        while (i < high or carry > 0) {
            if (i >= dst.len) return Base58Error.Decode;
            const current = carry + (@as(u32, dst[i]) * 58);
            dst[i] = @intCast(current % 256);
            carry = current / 256;
            i += 1;
        }
        high = i;
    }

    const out_len = zero_cnt + high;
    if (out_len > dst.len) return Base58Error.NoSpaceLeft;

    std.mem.reverse(u8, dst[0..high]);
    std.mem.copyBackwards(u8, dst[zero_cnt..out_len], dst[0..high]);
    @memset(dst[0..zero_cnt], 0);

    return dst[0..out_len];
}

fn decoded_len(size: usize) usize {
    return (size * 733 / 1000) + 1;
}

// pubkeyLimbs interpret the pubkey as 8 limbs.
fn pubkeyLimbs(src: [32]u8) [8]u32 {
    const limbs: @Vector(8, u32) = @bitCast(src);
    return @bitCast(@byteSwap(limbs));
}

fn signatureLimbs(src: [64]u8) [16]u32 {
    const limbs: @Vector(16, u32) = @bitCast(src);
    return @bitCast(@byteSwap(limbs));
}

fn limbsToIntermediate32(limbs: [8]u32) [9]u64 {
    var intermediate: [9]u64 = .{0} ** 9;

    for (0..8) |i| {
        const limb: @Vector(8, u64) = @splat(@as(u64, limbs[i]));
        var table_row: @Vector(8, u64) = undefined;
        inline for (0..8) |j| table_row[j] = enc_table_32[i][j];
        const acc: @Vector(8, u64) = @bitCast(intermediate[1..9].*);
        intermediate[1..9].* = @bitCast(acc + limb * table_row);
    }

    var k: usize = 8;
    while (k > 0) : (k -= 1) {
        intermediate[k - 1] += intermediate[k] / intermediate_base;
        intermediate[k] %= intermediate_base;
    }

    return intermediate;
}

fn limbsToIntermediate64(limbs: [16]u32) [18]u64 {
    var intermediate: [18]u64 = .{0} ** 18;

    for (0..8) |i| {
        const limb: @Vector(17, u64) = @splat(@as(u64, limbs[i]));
        var table_row: @Vector(17, u64) = undefined;
        inline for (0..17) |j| table_row[j] = enc_table_64[i][j];
        const acc: @Vector(17, u64) = @bitCast(intermediate[1..18].*);
        intermediate[1..18].* = @bitCast(acc + limb * table_row);
    }

    // mini-reduction to prevent intermediate[16] overflow
    intermediate[15] += intermediate[16] / intermediate_base;
    intermediate[16] %= intermediate_base;

    for (8..16) |i| {
        const limb: @Vector(17, u64) = @splat(@as(u64, limbs[i]));
        var table_row: @Vector(17, u64) = undefined;
        inline for (0..17) |j| table_row[j] = enc_table_64[i][j];
        const acc: @Vector(17, u64) = @bitCast(intermediate[1..18].*);
        intermediate[1..18].* = @bitCast(acc + limb * table_row);
    }

    var k: usize = 17;
    while (k > 0) : (k -= 1) {
        intermediate[k - 1] += intermediate[k] / intermediate_base;
        intermediate[k] %= intermediate_base;
    }

    return intermediate;
}

inline fn intermediateToRaw(comptime N: usize, intermediate: [intermediateSize(N)]u64) [intermediateSize(N) * 5]u8 {
    const inter_sz = comptime intermediateSize(N);
    const VecType = @Vector(inter_sz, u32);

    // cast all intermediates to u32 (safe: all < 58^5 < 2^32)
    var values: VecType = undefined;
    inline for (0..inter_sz) |i| values[i] = @intCast(intermediate[i]);

    const s58: VecType = @splat(58);
    const d4 = values / @as(VecType, @splat(11316496));
    const d3 = values / @as(VecType, @splat(195112)) % s58;
    const d2 = values / @as(VecType, @splat(3364)) % s58;
    const d1 = values / @as(VecType, @splat(58)) % s58;
    const d0 = values % s58;

    var raw: [inter_sz * 5]u8 = undefined;
    inline for (0..inter_sz) |i| {
        raw[5 * i + 0] = @intCast(d4[i]);
        raw[5 * i + 1] = @intCast(d3[i]);
        raw[5 * i + 2] = @intCast(d2[i]);
        raw[5 * i + 3] = @intCast(d1[i]);
        raw[5 * i + 4] = @intCast(d0[i]);
    }

    return raw;
}

inline fn rawToBase58(comptime N: usize, in_leading_zero: usize, raw: [intermediateSize(N) * 5]u8, dst: []u8) ![]u8 {
    const raw_sz = comptime intermediateSize(N) * 5;
    const raw_leading_zero = countLeadingZeros(raw_sz, raw);
    const skip = raw_leading_zero - in_leading_zero;
    const out_len = raw_sz - skip;

    if (dst.len < out_len) return Base58Error.NoSpaceLeft;

    for (0..out_len) |i| {
        dst[i] = Alphabet[raw[skip + i]];
    }

    return dst[0..out_len];
}

pub fn encodedMaxLen(comptime N: usize) usize {
    return intermediateSize(N) * 5;
}

fn countLeadingZeros(comptime N: usize, src: [N]u8) usize {
    const MaskType = std.meta.Int(.unsigned, N);
    const v: @Vector(N, u8) = src;
    const is_nonzero = v != @as(@Vector(N, u8), @splat(0));
    const mask: MaskType = @bitCast(is_nonzero);
    return if (mask == 0) N else @ctz(mask);
}

fn encode32(dst: []u8, src: [32]u8) ![]u8 {
    const max_out_sz = intermediateSize(32) * 5;
    if (dst.len < max_out_sz) return Base58Error.NoSpaceLeft;

    const limbs = pubkeyLimbs(src);
    const intermediate = limbsToIntermediate32(limbs);
    const raw = intermediateToRaw(32, intermediate);

    const in_leading_zero: usize = countLeadingZeros(32, src);
    return rawToBase58(32, in_leading_zero, raw, dst);
}

fn encode64(dst: []u8, src: [64]u8) ![]u8 {
    const max_out_sz = intermediateSize(64) * 5;
    if (dst.len < max_out_sz) return Base58Error.NoSpaceLeft;

    const limbs = signatureLimbs(src);
    const intermediate = limbsToIntermediate64(limbs);
    const raw = intermediateToRaw(64, intermediate);

    const in_leading_zero: usize = countLeadingZeros(64, src);
    return rawToBase58(64, in_leading_zero, raw, dst);
}

fn countLeadingOnes(src: []const u8) usize {
    var count: usize = 0;
    while (count < src.len and src[count] == '1') : (count += 1) {}
    return count;
}

// Parse a base58 string into a raw digit array (values 0-57), right-aligned.
// Mirrors rawToBase58.
inline fn base58ToRaw(comptime N: usize, in_leading_ones: usize, src: []const u8) ![intermediateSize(N) * 5]u8 {
    const raw_sz = comptime intermediateSize(N) * 5;
    const max_encoded = comptime if (N == 32) 44 else 88;

    if (src.len > max_encoded) return Base58Error.Decode;

    var raw: [raw_sz]u8 = .{0} ** raw_sz;

    const payload = src[in_leading_ones..];
    const offset = raw_sz - payload.len;
    for (payload, 0..) |c, i| {
        const v = InverseAlphabet[c];
        if (v == 255) return Base58Error.InvalidCharacter;
        raw[offset + i] = v;
    }

    return raw;
}

// Group each consecutive 5 raw digits into one base-58^5 intermediate value.
// Mirrors intermediateToRaw. Vectorized across all inter_sz groups simultaneously.
inline fn rawToIntermediate(comptime N: usize, raw: [intermediateSize(N) * 5]u8) [intermediateSize(N)]u64 {
    const inter_sz = comptime intermediateSize(N);
    const VecType = @Vector(inter_sz, u64);

    var d4: VecType = undefined;
    var d3: VecType = undefined;
    var d2: VecType = undefined;
    var d1: VecType = undefined;
    var d0: VecType = undefined;
    inline for (0..inter_sz) |i| {
        d4[i] = raw[5 * i + 0];
        d3[i] = raw[5 * i + 1];
        d2[i] = raw[5 * i + 2];
        d1[i] = raw[5 * i + 3];
        d0[i] = raw[5 * i + 4];
    }

    const result = d4 * @as(VecType, @splat(11316496)) +
        d3 * @as(VecType, @splat(195112)) +
        d2 * @as(VecType, @splat(3364)) +
        d1 * @as(VecType, @splat(58)) +
        d0;

    return @bitCast(result);
}

// Matrix multiply intermediate base-58^5 values into 32-bit binary limbs.
// Mirrors limbsToIntermediate32.
//
// u64 accumulators are sufficient: each intermediate[j] < 58^5 < 2^30, and
// the actual column sums of dec_table_32 are bounded such that the worst-case
// accumulator (column 7) stays below 2^63. Verified by Firedancer.
fn intermediateToLimbs32(intermediate: [9]u64) ![8]u32 {
    var binary: [8]u64 = .{0} ** 8;

    for (0..9) |j| {
        const limb: @Vector(8, u64) = @splat(intermediate[j]);
        var table_row: @Vector(8, u64) = undefined;
        inline for (0..8) |k| table_row[k] = dec_table_32[j][k];
        const acc: @Vector(8, u64) = @bitCast(binary);
        binary = @bitCast(acc + limb * table_row);
    }

    var k: usize = 7;
    while (k > 0) : (k -= 1) {
        binary[k - 1] += binary[k] >> 32;
        binary[k] &= 0xFFFF_FFFF;
    }

    if (binary[0] >> 32 != 0) return Base58Error.Decode;

    var limbs: [8]u32 = undefined;
    for (0..8) |i| limbs[i] = @intCast(binary[i]);
    return limbs;
}

// Mirrors intermediateToLimbs32 for the 64-byte (signature) case.
//
// Same u64 bound applies. The tightest column (13) reaches at most ~2^63.998
// — fits in u64 with no overflow. Verified by Firedancer.
fn intermediateToLimbs64(intermediate: [18]u64) ![16]u32 {
    var binary: [16]u64 = .{0} ** 16;

    for (0..18) |j| {
        const limb: @Vector(16, u64) = @splat(intermediate[j]);
        var table_row: @Vector(16, u64) = undefined;
        inline for (0..16) |k| table_row[k] = dec_table_64[j][k];
        const acc: @Vector(16, u64) = @bitCast(binary);
        binary = @bitCast(acc + limb * table_row);
    }

    var k: usize = 15;
    while (k > 0) : (k -= 1) {
        binary[k - 1] += binary[k] >> 32;
        binary[k] &= 0xFFFF_FFFF;
    }

    if (binary[0] >> 32 != 0) return Base58Error.Decode;

    var limbs: [16]u32 = undefined;
    for (0..16) |i| limbs[i] = @intCast(binary[i]);
    return limbs;
}

pub fn decode32(dst: []u8, src: []const u8) ![]u8 {
    if (dst.len < 32) return Base58Error.NoSpaceLeft;

    const in_leading_ones = countLeadingOnes(src);
    const raw = try base58ToRaw(32, in_leading_ones, src);
    const intermediate = rawToIntermediate(32, raw);

    const limbs = try intermediateToLimbs32(intermediate);
    const bytes: [32]u8 = @bitCast(@byteSwap(@as(@Vector(8, u32), @bitCast(limbs))));

    if (countLeadingZeros(32, bytes) != in_leading_ones) return Base58Error.Decode;

    dst[0..32].* = bytes;
    return dst[0..32];
}

pub fn decode64(dst: []u8, src: []const u8) ![]u8 {
    if (dst.len < 64) return Base58Error.NoSpaceLeft;

    const in_leading_ones = countLeadingOnes(src);
    const raw = try base58ToRaw(64, in_leading_ones, src);
    const intermediate = rawToIntermediate(64, raw);
    const limbs = try intermediateToLimbs64(intermediate);
    const bytes: [64]u8 = @bitCast(@byteSwap(@as(@Vector(16, u32), @bitCast(limbs))));

    if (countLeadingZeros(64, bytes) != in_leading_ones) return Base58Error.Decode;

    dst[0..64].* = bytes;
    return dst[0..64];
}

test "countLeadingZeros 32" {
    try testing.expectEqual(@as(usize, 32), countLeadingZeros(32, [_]u8{0} ** 32));
    try testing.expectEqual(@as(usize, 0), countLeadingZeros(32, [_]u8{1} ++ [_]u8{0} ** 31));
    try testing.expectEqual(@as(usize, 3), countLeadingZeros(32, [_]u8{0} ** 3 ++ [_]u8{1} ++ [_]u8{0} ** 28));
}

test "countLeadingZeros 64" {
    try testing.expectEqual(@as(usize, 64), countLeadingZeros(64, [_]u8{0} ** 64));
    try testing.expectEqual(@as(usize, 0), countLeadingZeros(64, [_]u8{1} ++ [_]u8{0} ** 63));
    try testing.expectEqual(@as(usize, 5), countLeadingZeros(64, [_]u8{0} ** 5 ++ [_]u8{1} ++ [_]u8{0} ** 58));
}

test "pubkey, signature to limbs" {
    const pubkey: [32]u8 = [1]u8{10} ** 32;
    const pk_limbs = pubkeyLimbs(pubkey);
    const pk_limbs_expected = [1]u32{168430090} ** 8;

    const signature: [64]u8 = [1]u8{10} ** 64;
    const sig_limbs = signatureLimbs(signature);
    const sig_limbs_expected = [1]u32{168430090} ** 16;

    try std.testing.expectEqualSlices(u32, &pk_limbs_expected, &pk_limbs);
    try std.testing.expectEqualSlices(u32, &sig_limbs_expected, &sig_limbs);

    // std.debug.print("{any}\n", .{pk_limbs});
    // std.debug.print("{any}\n", .{sig_limbs});
}

test "pubkey, _encode32" {
    const pk = [_]u8{0} ** 32;
    var out: [encodedMaxLen(32)]u8 = undefined;
    const result = try encode32(&out, pk);
    const expected = "11111111111111111111111111111111";
    try testing.expectEqualStrings(expected, result);
}

test "null signature, _encode64" {
    const sig = [_]u8{0} ** 64;
    var out: [encodedMaxLen(64)]u8 = undefined;
    const result = try encode64(&out, sig);
    const expected = "1" ** 64;
    try testing.expectEqualStrings(expected, result);
}

test "null pubkey, encode/decode" {
    const pk = [_]u8{0} ** 32;
    var enc_buf: [64]u8 = undefined;
    var dec_buf: [64]u8 = undefined;

    const result = try encode(&enc_buf, &pk);
    const expected = "11111111111111111111111111111111";
    try testing.expectEqualStrings(expected, result);

    const decoded_result = try decode(&dec_buf, expected);
    try testing.expectEqualSlices(u8, &pk, decoded_result);
}

test "Hello World!, encode" {
    const pk: *const [12:0]u8 = "Hello World!";
    var enc_buf: [32]u8 = undefined;
    var dec_buf: [32]u8 = undefined;

    const result = try encode(&enc_buf, pk);
    const expected = "2NEpo7TZRRrLZSi2U";
    try testing.expectEqualStrings(expected, result);

    const decoded_result = try decode(&dec_buf, expected);
    try testing.expectEqualSlices(u8, pk, decoded_result);
}

test "phrase, encode" {
    const pk: *const [44:0]u8 = "The quick brown fox jumps over the lazy dog.";
    var enc_buf: [128]u8 = undefined;
    var dec_buf: [128]u8 = undefined;

    const result = try encode(&enc_buf, pk);
    const expected = "USm3fpXnKG5EUBx2ndxBDMPVciP5hGey2Jh4NDv6gmeo1LkMeiKrLJUUBk6Z";
    try testing.expectEqualStrings(expected, result);

    const decoded_result = try decode(&dec_buf, expected);
    try testing.expectEqualSlices(u8, pk, decoded_result);
}

test "magic case, encode" {
    const pk = [_]u8{ 0x00, 0x00, 0x28, 0x7f, 0xb4, 0xcd };
    var enc_buf: [32]u8 = undefined;
    var dec_buf: [32]u8 = undefined;

    const result = try encode(&enc_buf, &pk);
    const expected = "11233QC4";
    try testing.expectEqualStrings(expected, result);

    const decoded_result = try decode(&dec_buf, expected);
    try testing.expectEqualSlices(u8, &pk, decoded_result);
}

test "intermediateToRaw 32, all zeros" {
    const raw = intermediateToRaw(32, .{0} ** 9);
    try testing.expectEqualSlices(u8, &(.{0} ** 45), &raw);
}

test "intermediateToRaw 32, last = 1" {
    var intermediate: [9]u64 = .{0} ** 9;
    intermediate[8] = 1;
    const raw = intermediateToRaw(32, intermediate);
    var expected: [45]u8 = .{0} ** 45;
    expected[44] = 1; // 5*8+4
    try testing.expectEqualSlices(u8, &expected, &raw);
}

test "intermediateToRaw 32, last = 58" {
    var intermediate: [9]u64 = .{0} ** 9;
    intermediate[8] = 58;
    const raw = intermediateToRaw(32, intermediate);
    var expected: [45]u8 = .{0} ** 45;
    expected[43] = 1; // 5*8+3, digit = 58/58 % 58 = 1
    try testing.expectEqualSlices(u8, &expected, &raw);
}

test "intermediateToRaw 32, first = 58^5 - 1" {
    var intermediate: [9]u64 = .{0} ** 9;
    intermediate[0] = 656356767;
    const raw = intermediateToRaw(32, intermediate);
    var expected: [45]u8 = .{0} ** 45;
    expected[0] = 57;
    expected[1] = 57;
    expected[2] = 57;
    expected[3] = 57;
    expected[4] = 57;
    try testing.expectEqualSlices(u8, &expected, &raw);
}

test "intermediateToRaw 64, all zeros" {
    const raw = intermediateToRaw(64, .{0} ** 18);
    try testing.expectEqualSlices(u8, &(.{0} ** 90), &raw);
}

test "rawToIntermediate 32, all zeros" {
    const intermediate = rawToIntermediate(32, .{0} ** 45);
    try testing.expectEqualSlices(u64, &(.{0} ** 9), &intermediate);
}

test "rawToIntermediate 32, last group = [0,0,0,0,1]" {
    var raw: [45]u8 = .{0} ** 45;
    raw[44] = 1;
    const intermediate = rawToIntermediate(32, raw);
    var expected: [9]u64 = .{0} ** 9;
    expected[8] = 1;
    try testing.expectEqualSlices(u64, &expected, &intermediate);
}

test "rawToIntermediate 32, last group = [1,0,0,0,0]" {
    var raw: [45]u8 = .{0} ** 45;
    raw[40] = 1; // first digit of last group → 1 * 58^4 = 11316496
    const intermediate = rawToIntermediate(32, raw);
    var expected: [9]u64 = .{0} ** 9;
    expected[8] = 11316496;
    try testing.expectEqualSlices(u64, &expected, &intermediate);
}

test "rawToIntermediate/intermediateToRaw round-trip 32" {
    // encode a known intermediate, convert to raw, convert back
    var original: [9]u64 = .{0} ** 9;
    original[3] = 123456;
    original[7] = 58 * 3 + 17; // 191
    const raw = intermediateToRaw(32, original);
    const recovered = rawToIntermediate(32, raw);
    try testing.expectEqualSlices(u64, &original, &recovered);
}

test "decode32, null pubkey" {
    var out: [32]u8 = undefined;
    const result = try decode32(&out, "11111111111111111111111111111111");
    try testing.expectEqualSlices(u8, &(.{0} ** 32), result);
}

test "decode64, null signature" {
    var out: [64]u8 = undefined;
    const result = try decode64(&out, "1" ** 64);
    try testing.expectEqualSlices(u8, &(.{0} ** 64), result);
}

test "decode32 round-trip" {
    const pk = [32]u8{
        1,  2,  3,  4,  5,  6,  7,  8,
        9,  10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24,
        25, 26, 27, 28, 29, 30, 31, 32,
    };
    var enc_buf: [encodedMaxLen(32)]u8 = undefined;
    var dec_buf: [32]u8 = undefined;
    const encoded = try encode32(&enc_buf, pk);
    const decoded = try decode32(&dec_buf, encoded);
    try testing.expectEqualSlices(u8, &pk, decoded);
}

test "decode64 round-trip" {
    const sig = [64]u8{
        1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
        33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
    };
    var enc_buf: [encodedMaxLen(64)]u8 = undefined;
    var dec_buf: [64]u8 = undefined;
    const encoded = try encode64(&enc_buf, sig);
    const decoded = try decode64(&dec_buf, encoded);
    try testing.expectEqualSlices(u8, &sig, decoded);
}

test "decode32 round-trip, leading zero bytes" {
    const pk = [8]u8{ 0, 0, 0, 1, 2, 3, 4, 5 } ++ [_]u8{0} ** 24;
    var enc_buf: [encodedMaxLen(32)]u8 = undefined;
    var dec_buf: [32]u8 = undefined;
    const encoded = try encode32(&enc_buf, pk);
    try testing.expect(encoded[0] == '1');
    try testing.expect(encoded[1] == '1');
    try testing.expect(encoded[2] == '1');
    const decoded = try decode32(&dec_buf, encoded);
    try testing.expectEqualSlices(u8, &pk, decoded);
}

test "decode32, invalid character" {
    var out: [32]u8 = undefined;
    // 'O' is not in the base58 alphabet
    try testing.expectError(Base58Error.InvalidCharacter, decode32(&out, "1111111111111111111111111111111O"));
}

test "decode32, input too long" {
    var out: [32]u8 = undefined;
    try testing.expectError(Base58Error.Decode, decode32(&out, "1" ** 45));
}

test "decode32, leading ones mismatch" {
    // null pubkey encodes to 32 '1's; adding a 33rd '1' must be rejected
    var out: [32]u8 = undefined;
    try testing.expectError(Base58Error.Decode, decode32(&out, "1" ** 33));
}

// --- Fuzz tests ---

fn fuzzEncodeDecodeRoundTrip(_: void, smith: *std.testing.Smith) !void {
    var raw: [128]u8 = undefined;
    const len = smith.slice(&raw);
    if (len == 0) return;
    const input = raw[0..len];
    var enc_buf: [encodedLen(128)]u8 = undefined;
    const encoded = encode(enc_buf[0..encodedLen(input.len)], input) catch return;
    var dec_buf: [128]u8 = undefined;
    const decoded = decode(&dec_buf, encoded) catch return;
    try testing.expectEqualSlices(u8, input, decoded);
}

// Round-trip through the public encode (dispatches to encode32/encode64 for 32/64b,
// _encode otherwise) and _decode for arbitrary binary inputs up to 128 bytes.
test "fuzz encode/_decode round-trip" {
    try std.testing.fuzz({}, fuzzEncodeDecodeRoundTrip, .{});
}

fn fuzzEncode32Decode32(_: void, smith: *std.testing.Smith) !void {
    var src: [32]u8 = undefined;
    smith.bytes(&src);
    var enc_buf: [encodedMaxLen(32)]u8 = undefined;
    const encoded = try encode32(&enc_buf, src);
    var dec_buf: [32]u8 = undefined;
    const decoded = try decode32(&dec_buf, encoded);
    try testing.expectEqualSlices(u8, &src, decoded);
}

// Round-trip through the encode32/decode32 fast path for arbitrary 32-byte inputs.
test "fuzz encode32/decode32 round-trip" {
    try std.testing.fuzz({}, fuzzEncode32Decode32, .{
        .corpus = &.{
            &([_]u8{0} ** 32), // null pubkey
            &([_]u8{0xFF} ** 32), // max pubkey
        },
    });
}

fn fuzzEncode64Decode64(_: void, smith: *std.testing.Smith) !void {
    var src: [64]u8 = undefined;
    smith.bytes(&src);
    var enc_buf: [encodedMaxLen(64)]u8 = undefined;
    const encoded = try encode64(&enc_buf, src);
    var dec_buf: [64]u8 = undefined;
    const decoded = try decode64(&dec_buf, encoded);
    try testing.expectEqualSlices(u8, &src, decoded);
}

// Round-trip through the encode64/decode64 fast path for arbitrary 64-byte inputs.
test "fuzz encode64/decode64 round-trip" {
    try std.testing.fuzz({}, fuzzEncode64Decode64, .{
        .corpus = &.{
            &([_]u8{0} ** 64), // null signature
            &([_]u8{0xFF} ** 64), // max signature
        },
    });
}

fn fuzzDecodeNeverPanics(_: void, smith: *std.testing.Smith) !void {
    var raw: [512]u8 = undefined;
    const len = smith.slice(&raw);
    var buf: [512]u8 = undefined;
    _ = decode(&buf, raw[0..len]) catch {};
}

// decode must return an error (never panic) on any byte sequence.
test "fuzz decode never panics" {
    try std.testing.fuzz({}, fuzzDecodeNeverPanics, .{
        .corpus = &.{
            "11111111111111111111111111111111", // null pubkey encoded
            "1" ** 64, // null signature encoded
            "2NEpo7TZRRrLZSi2U", // "Hello World!" encoded
            "OIl0", // chars excluded from the alphabet
        },
    });
}
