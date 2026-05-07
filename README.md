# base58

Base58 encoding and decoding library for Zig, following the Bitcoin alphabet (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`).

NOTE: I'm learning Zig with this small lib.

## Requirements

Zig `0.16.0` or newer.

## Installation

```bash
zig fetch --save git+https://github.com/you/base58#main
```

In your `build.zig`:

```zig
const base58_dep = b.dependency("base58", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("base58", base58_dep.module("base58"));
```

## Usage

The caller provides the destination buffer. No allocator required.

```zig
const base58 = @import("base58");

// Encode
var enc_buf: [base58.encodedLen(src.len)]u8 = undefined;
const encoded = try base58.encode(&enc_buf, &src);

// Decode
var dec_buf: [encoded.len]u8 = undefined;
const decoded = try base58.decode(&dec_buf, encoded);
```

Both functions write into the caller-supplied buffer and return a slice of it.

## API

```zig
pub fn encode(dst: []u8, src: []const u8) ![]u8
pub fn decode(dst: []u8, src: []const u8) ![]u8

/// Minimum dst size for encode.
pub fn encodedLen(src_len: usize) usize

/// Minimum dst size for decode.
pub fn decodedLen(src_len: usize) usize

pub const Base58Error = error{ Decode, InvalidCharacter, NoSpaceLeft };
```

## Running tests

```bash
zig build test
```
