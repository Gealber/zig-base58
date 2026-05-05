//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Allocator = std.mem.Allocator;
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

pub const Base58Error = error{ Decode, InvalidCharacter };

pub fn encode(allocator: Allocator, src: []const u8) ![]u8 {
    switch (src.len) {
        // NOTE: dont implemented for now
        // 32 => return _encode32(src[0..32].*),
        // 64 => return _encode64(src[0..64].*),
        else => return try _encode(allocator, src),
    }
}

pub fn decode(allocator: Allocator, src: []const u8) ![]u8 {
    switch (src.len) {
        // NOTE: dont implemented for now
        // 32 => return _decode32(src[0..32].*),
        // 64 => return _decode64(src[0..64].*),
        else => return try _decode(allocator, src),
    }
}

fn _encode32(_: [32]u8) []const u8 {
    return "_encode32 not implemented";
}

fn _encode64(_: [64]u8) []const u8 {
    return "_encode64 not implemented";
}

fn _encode(allocator: Allocator, src: []const u8) ![]u8 {
    if (src.len == 0) return try allocator.alloc(u8, 0);

    var zero_cnt: usize = 0;
    while (zero_cnt < src.len and src[zero_cnt] == 0) : (zero_cnt += 1) {}

    const padding_len = encoded_len(src.len - zero_cnt);
    var padding: []u8 = try allocator.alloc(u8, padding_len);
    defer allocator.free(padding);
    @memset(padding, 0);

    var high: usize = 0;

    for (src[zero_cnt..]) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;

        while (i < high or carry > 0) {
            const current = carry + @as(u32, padding[i]) * 256;
            padding[i] = @intCast(current % 58);
            carry = current / 58;
            i += 1;
        }

        high = i;
    }

    const out_len = zero_cnt + high;
    var out = try allocator.alloc(u8, out_len);
    @memset(out[0..zero_cnt], '1');

    for (0..high) |i| {
        out[zero_cnt + i] = Alphabet[padding[high - 1 - i]];
    }

    return out;
}

fn _decode(allocator: Allocator, src: []const u8) ![]u8 {
    if (src.len == 0) return try allocator.alloc(u8, 0);

    var zero_cnt: usize = 0;
    while (zero_cnt < src.len and src[zero_cnt] == '1') : (zero_cnt += 1) {}

    const raw_bytes_len = decoded_len(src.len - zero_cnt);
    var raw_bytes: []u8 = try allocator.alloc(u8, raw_bytes_len);
    defer allocator.free(raw_bytes);
    @memset(raw_bytes, 0);

    var high: usize = 0;

    for (src[zero_cnt..]) |c| {
        const char_idx = InverseAlphabet[c];
        if (char_idx == 255) return Base58Error.InvalidCharacter;

        var carry: u32 = @intCast(char_idx);
        var i: usize = 0;

        while (i < high or carry > 0) {
            if (i >= raw_bytes.len) return Base58Error.Decode;

            const current = carry + (@as(u32, raw_bytes[i]) * 58);
            raw_bytes[i] = @intCast(current % 256);
            carry = current / 256;
            i += 1;
        }

        high = i;
    }

    var out = try allocator.alloc(u8, high + zero_cnt);
    @memset(out[0..zero_cnt], 0);

    for (0..high) |i| {
        out[zero_cnt + i] = raw_bytes[high - 1 - i];
    }

    return out;
}

fn encoded_len(size: usize) usize {
    return (size * 138 / 100) + 1;
}

fn decoded_len(size: usize) usize {
    return (size * 733 / 1000) + 1;
}

test "null pubkey, encode/decode" {
    const alloc = std.testing.allocator;
    const pk = [_]u8{0} ** 32;

    const result = try encode(alloc, &pk);
    defer alloc.free(result);
    const expected = "11111111111111111111111111111111";
    try testing.expectEqualStrings(expected, result);

    const encoded = try decode(alloc, expected);
    defer alloc.free(encoded);
    try testing.expectEqualSlices(u8, &pk, encoded);
}

test "Hellow World!, encode" {
    const alloc = std.testing.allocator;
    const pk: *const [12:0]u8 = "Hello World!";

    const result = try encode(alloc, pk);
    defer alloc.free(result);
    const expected = "2NEpo7TZRRrLZSi2U";
    try testing.expectEqualStrings(expected, result);

    const encoded = try decode(alloc, expected);
    defer alloc.free(encoded);
    try testing.expectEqualSlices(u8, pk, encoded);
}

test "phrase, encode" {
    const alloc = std.testing.allocator;
    const pk: *const [44:0]u8 = "The quick brown fox jumps over the lazy dog.";

    const result = try encode(alloc, pk);
    defer alloc.free(result);
    const expected = "USm3fpXnKG5EUBx2ndxBDMPVciP5hGey2Jh4NDv6gmeo1LkMeiKrLJUUBk6Z";
    try testing.expectEqualStrings(expected, result);

    const encoded = try decode(alloc, expected);
    defer alloc.free(encoded);
    try testing.expectEqualSlices(u8, pk, encoded);
}

test "magic case, encode" {
    const alloc = std.testing.allocator;
    const pk = [_]u8{ 0x00, 0x00, 0x28, 0x7f, 0xb4, 0xcd };

    const result = try encode(alloc, &pk);
    defer alloc.free(result);
    const expected = "11233QC4";
    try testing.expectEqualStrings(expected, result);

    const encoded = try decode(alloc, expected);
    defer alloc.free(encoded);
    try testing.expectEqualSlices(u8, &pk, encoded);
}
