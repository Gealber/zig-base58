# base58

Base58 encoding and decoding library for Zig, following the Bitcoin alphabet (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`).

This lib tries to follow the base58 implementation of [fireadancer](https://github.com/firedancer-io/firedancer/blob/main/src/ballet/base58/fd_base58.c) so all the credits for the optimizations go to them. Vectors in Zig makes the inclusion of SIMD instructions "trivial" or at least a lot easier. 

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

For 32-byte pubkeys and 64-byte signatures, use the typed fast paths (`encode32`/`decode32`, `encode64`/`decode64`). The generic `encode`/`decode` handle arbitrary lengths but are slower (O(n²)).

```zig
const base58 = @import("base58");

// Fast path — 32-byte pubkey
var enc_buf: [base58.encodedMaxLen(32)]u8 = undefined;
const encoded = try base58.encode32(&enc_buf, pubkey_bytes);

var dec_buf: [32]u8 = undefined;
const decoded = try base58.decode32(&dec_buf, encoded);

// Fast path — 64-byte signature
var enc_buf: [base58.encodedMaxLen(64)]u8 = undefined;
const encoded = try base58.encode64(&enc_buf, sig_bytes);

var dec_buf: [64]u8 = undefined;
const decoded = try base58.decode64(&dec_buf, encoded);

// Generic — arbitrary length
var enc_buf: [base58.encodedLen(src.len)]u8 = undefined;
const encoded = try base58.encode(&enc_buf, src);

var dec_buf: [src.len]u8 = undefined;
const decoded = try base58.decode(&dec_buf, encoded);
```

All functions write into the caller-supplied buffer and return a slice of it.

## API

```zig
// Fast paths (SIMD-optimized, AVX2)
pub fn encode32(dst: []u8, src: [32]u8) ![]u8
pub fn encode64(dst: []u8, src: [64]u8) ![]u8
pub fn decode32(dst: []u8, src: []const u8) ![]u8
pub fn decode64(dst: []u8, src: []const u8) ![]u8

// Generic (arbitrary length, O(n²))
pub fn encode(dst: []u8, src: []const u8) ![]u8
pub fn decode(dst: []u8, src: []const u8) ![]u8

/// Exact dst size for encode32/encode64.
pub fn encodedMaxLen(comptime src_len: usize) usize

/// Minimum dst size for generic encode.
pub fn encodedLen(src_len: usize) usize

/// Minimum dst size for generic decode.
pub fn decodedLen(src_len: usize) usize

pub const Base58Error = error{ Decode, InvalidCharacter, NoSpaceLeft };
```

## Running tests

```bash
zig build test
```

## Documentation

- [Encoding](docs/encoding.md) — how the encode algorithm works
- [Decoding](docs/decoding.md) — how the decode algorithm works

## Benchmarks

Compared against [Syndica/base58-zig](https://github.com/Syndica/base58-zig) (used by the [Syndica/sig](https://github.com/Syndica/sig) Solana validator) and [firedancer-io/firedancer](https://github.com/firedancer-io/firedancer/tree/main/src/ballet/base58) (Jump Crypto's AVX2-optimized C implementation). Benchmarks run with [hendriknielaender/zBench](https://github.com/hendriknielaender/zBench).

**Summary (avg time/run, ReleaseFast, AVX2):**

| | encode 32b | encode 64b | decode 32b | decode 64b |
|---|---|---|---|---|
| **this library** | 74ns | 177ns | **51ns** | **104ns** |
| firedancer (C+AVX2) | 46ns | 87ns | 78ns | 150ns |
| sindica | 846ns | 4117ns | 381ns | 1549ns |

The decode fast paths (`decode32`/`decode64`) outperform Firedancer's fully scalar C decode by ~1.5×. Firedancer's encode uses a dedicated AVX2 path; bridging that gap is a future target.

```
❯ zig build run -Doptimize=ReleaseFast
benchmark               runs     total time     time/run (avg ± σ)    (min ... max)                p75        p99        p995
------------------------------------------------------------------------------------------------------------------------------------
gealber encode 32b      100000   7.444ms        74ns ± 57ns           (69ns ... 9.874us)           73ns       98ns       129ns
sindica encode 32b      100000   84.646ms       846ns ± 172ns         (805ns ... 13.536us)         820ns      1.459us    1.656us
firedancer encode 32b   100000   4.689ms        46ns ± 26ns           (44ns ... 7.017us)           47ns       48ns       51ns
gealber encode 64b      100000   17.713ms       177ns ± 44ns          (172ns ... 6.692us)          177ns      188ns      198ns
sindica encode 64b      100000   411.702ms      4.117us ± 524ns       (3.942us ... 56.276us)       4.066us    5.528us    6.9us
firedancer encode 64b   100000   8.7ms          87ns ± 60ns           (82ns ... 12.046us)          87ns       93ns       103ns
gealber decode 32b      100000   5.19ms         51ns ± 21ns           (48ns ... 3.75us)            52ns       61ns       64ns
sindica decode 32b      100000   38.166ms       381ns ± 111ns         (340ns ... 17.073us)         383ns      509ns      659ns
firedancer decode 32b   100000   7.8ms          78ns ± 37ns           (71ns ... 8.982us)           78ns       81ns       91ns
gealber decode 64b      100000   10.464ms       104ns ± 75ns          (98ns ... 14.34us)           103ns      151ns      164ns
sindica decode 64b      100000   154.95ms       1.549us ± 1.378us     (1.388us ... 252.166us)      1.456us    4.29us     5.034us
firedancer decode 64b   100000   15.039ms       150ns ± 258ns         (144ns ... 59.078us)         149ns      152ns      152ns
```
