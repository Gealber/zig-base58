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

pub const Base58Error = error{ Decode, InvalidCharacter, NoSpaceLeft };

/// Returns the maximum buffer size needed for encode(dst, src) given src.len.
pub fn encodedLen(src_len: usize) usize {
    return (src_len * 138 / 100) + 1;
}

/// Returns the maximum buffer size needed for decode(dst, src) given src.len.
pub fn decodedLen(src_len: usize) usize {
    return src_len;
}

pub fn encode(dst: []u8, src: []const u8) ![]u8 {
    return _encode(dst, src);
}

pub fn decode(dst: []u8, src: []const u8) ![]u8 {
    return _decode(dst, src);
}

/// Encodes src into dst using Base58.
/// dst must be at least encodedLen(src.len) bytes.
/// Returns a slice of dst containing the encoded result.
fn _encode(dst: []u8, src: []const u8) ![]u8 {
    if (src.len == 0) return dst[0..0];

    var zero_cnt: usize = 0;
    while (zero_cnt < src.len and src[zero_cnt] == 0) : (zero_cnt += 1) {}

    const intermediate_len = encoded_len(src.len - zero_cnt);
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
fn _decode(dst: []u8, src: []const u8) ![]u8 {
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

fn encoded_len(size: usize) usize {
    return (size * 138 / 100) + 1;
}

fn decoded_len(size: usize) usize {
    return (size * 733 / 1000) + 1;
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
