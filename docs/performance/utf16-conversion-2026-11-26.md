# Strict UTF-8/UTF-16 conversion profile, 2026-11-26

The native-endian `utf16` APIs now use shared UTF vector kernels, exact-size
owned outputs, and append-style reusable buffers. This profile compares the
old allocating APIs from `88fdb07` with the same current APIs, and separately
compares caller-buffer conversion with simdutf 9.5.0 and ICU 78.3.

## Method and contracts

- Intel Core i9-13900K, logical CPU 2, Linux x86-64. Zig 0.16.0 ReleaseFast
  native; GCC 13 `-O3 -std=c++17`, simdutf `haswell`, ICU 78.3.
- Seventeen identical UTF-8 files cover ASCII, accented Latin, Chinese,
  mixed-script text, emoji, and two short cases. Both directions use the same
  text; UTF-16 input is prepared outside timing. The Zig harness uses the
  standard library, while the C++ harness cross-checks simdutf and ICU
  results and checks complete round trips against the original text.
- Allocation rows include producing and freeing the owned slice in both
  versions of icuz. Reuse rows prepare maximum-size output capacity outside
  timing in all libraries: one UTF-16 unit per input UTF-8 byte, or three
  UTF-8 bytes per input UTF-16 unit. These contracts are measured separately.
- All measured conversion APIs validate untrusted input. The input pointer
  and length depend on one volatile read per iteration, and mutable output
  memory remains observable. Result lengths and complete contents are checked
  against independent conversions outside timing.
- Five trials per row offer roughly 8 MiB each; three rounds reverse library
  order in alternating rounds. Values are minima. CPU timing on this shared
  machine varies; differences around ten percent are treated as parity.
- [Raw samples](utf16-conversion-2026-11-26.json) record all rounds, input
  hashes, binary hashes, source hashes, versions, and the external source pin.

The 4 KiB ASCII allocating UTF-8 to UTF-16 operation is about 124x faster
than the old scalar append loop. The reusable CJK rows exceed simdutf by
about 2.65x and 1.64x in the two directions; emoji rows by about 4.02x and
5.06x. Latin and mixed-script reuse still trail simdutf, and remain part of
the active optimization work. These results cover this CPU and the listed
inputs.

## Implementation and verification

`utf16.utf8ToUtf16Into` and `utf16.utf16ToUtf8Into` append to an existing list.
Input errors and allocation failures preserve the list's logical contents.
With sufficient spare capacity, validation is fused into conversion. When
capacity must grow, input is checked before allocation and exact output size
is computed. The allocating variants allocate their exact result once.

The low-level blocks now live under `src/unicode/utf/`, shared with charset
conversion. ASCII widens or narrows in batches, uniform two-, three-, and
four-byte sequences use vector blocks, and mixed BMP/Latin-1 units are packed
with byte shuffle controls. Conversion-direction kernels are separated under
`utf/convert/`. UTF-16 validation and scalar counts handle high/low surrogate
pairs across vector boundaries.

The self-hosted Debug backend was found to load a full 16-byte register for
some smaller pointer-cast vectors. Explicit bounded array loads are used in
that backend; the guarded-buffer Debug test now passes. LLVM retains its
vector pointer loads.

A pre-existing strict charset bug was independently reproduced at `88fdb07`:
`E4 00 80` was accepted as UTF-16 bytes `00 40`. The scalar three-byte fallback
combined continuation bytes with OR, which hid an ASCII byte. It now checks
each continuation byte and correctly returns `InvalidSequence` for UTF-16LE
and UTF-16BE conversion.

Validation includes every Unicode scalar, every surrogate-pair combination,
all 65,536 UTF-16 unit values at window boundaries, every BMP width combination,
Latin-1 width masks, and allocated/reused mixed strings. Failing-allocator tests
exercise error precedence and unchanged prefixes. Linux tests put input and
exact output ends next to unreadable pages. Native ReleaseSafe, baseline x86-64,
Debug guard tests, and AArch64/PowerPC64 compilation pass. The final full-library
gate passes all 522 tests; committed Unicode data verification passes.

## Allocating APIs: same contract before and after

| Input | Direction | previous ns/op | current ns/op | previous / current |
|---|---|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 433.704 | 23.928 | 18.13x |
| ascii-32 | utf16-to-utf8 | 296.936 | 23.011 | 12.90x |
| ascii-128 | utf8-to-utf16 | 1220.419 | 24.612 | 49.59x |
| ascii-128 | utf16-to-utf8 | 755.909 | 28.921 | 26.14x |
| ascii-4096 | utf8-to-utf16 | 29187.041 | 235.596 | 123.89x |
| ascii-4096 | utf16-to-utf8 | 17365.629 | 351.829 | 49.36x |
| latin-32 | utf8-to-utf16 | 334.118 | 63.294 | 5.28x |
| latin-32 | utf16-to-utf8 | 236.232 | 36.654 | 6.44x |
| latin-128 | utf8-to-utf16 | 921.875 | 157.071 | 5.87x |
| latin-128 | utf16-to-utf8 | 672.237 | 75.930 | 8.85x |
| latin-4096 | utf8-to-utf16 | 23308.074 | 3436.304 | 6.78x |
| latin-4096 | utf16-to-utf8 | 16064.374 | 1659.345 | 9.68x |
| chinese-32 | utf8-to-utf16 | 144.912 | 23.721 | 6.11x |
| chinese-32 | utf16-to-utf8 | 91.782 | 24.251 | 3.78x |
| chinese-128 | utf8-to-utf16 | 456.995 | 31.578 | 14.47x |
| chinese-128 | utf16-to-utf8 | 258.004 | 22.640 | 11.40x |
| chinese-4096 | utf8-to-utf16 | 12007.434 | 549.660 | 21.85x |
| chinese-4096 | utf16-to-utf8 | 6599.591 | 371.216 | 17.78x |
| mixed-32 | utf8-to-utf16 | 529.615 | 93.087 | 5.69x |
| mixed-32 | utf16-to-utf8 | 379.548 | 83.992 | 4.52x |
| mixed-128 | utf8-to-utf16 | 1018.260 | 176.671 | 5.76x |
| mixed-128 | utf16-to-utf8 | 700.193 | 164.247 | 4.26x |
| mixed-4096 | utf8-to-utf16 | 19107.334 | 2983.093 | 6.41x |
| mixed-4096 | utf16-to-utf8 | 13029.832 | 3071.658 | 4.24x |
| emoji-32 | utf8-to-utf16 | 169.942 | 27.369 | 6.21x |
| emoji-32 | utf16-to-utf8 | 114.480 | 22.732 | 5.04x |
| emoji-128 | utf8-to-utf16 | 424.195 | 43.493 | 9.75x |
| emoji-128 | utf16-to-utf8 | 265.100 | 34.458 | 7.69x |
| emoji-4096 | utf8-to-utf16 | 11164.129 | 822.834 | 13.57x |
| emoji-4096 | utf16-to-utf8 | 6974.621 | 703.587 | 9.91x |
| tiny-ascii-31 | utf8-to-utf16 | 257.115 | 27.157 | 9.47x |
| tiny-ascii-31 | utf16-to-utf8 | 169.151 | 27.369 | 6.18x |
| tiny-emoji-31 | utf8-to-utf16 | 125.675 | 18.691 | 6.72x |
| tiny-emoji-31 | utf16-to-utf8 | 86.742 | 18.043 | 4.81x |

## Caller-owned buffers: current industry comparison

| Input | Direction | icuz ns/op | simdutf ns/op | ICU ns/op | simdutf / icuz | ICU / icuz |
|---|---|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 4.510 | 12.753 | 37.027 | 2.83x | 8.21x |
| ascii-32 | utf16-to-utf8 | 5.587 | 10.456 | 36.459 | 1.87x | 6.53x |
| ascii-128 | utf8-to-utf16 | 6.822 | 9.899 | 95.143 | 1.45x | 13.95x |
| ascii-128 | utf16-to-utf8 | 8.779 | 13.807 | 93.483 | 1.57x | 10.65x |
| ascii-4096 | utf8-to-utf16 | 97.231 | 110.738 | 2098.554 | 1.14x | 21.58x |
| ascii-4096 | utf16-to-utf8 | 139.907 | 198.141 | 2075.360 | 1.42x | 14.83x |
| latin-32 | utf8-to-utf16 | 46.749 | 39.147 | 38.292 | 0.84x | 0.82x |
| latin-32 | utf16-to-utf8 | 18.005 | 23.703 | 27.687 | 1.32x | 1.54x |
| latin-128 | utf8-to-utf16 | 127.948 | 87.393 | 91.356 | 0.68x | 0.71x |
| latin-128 | utf16-to-utf8 | 49.481 | 35.340 | 69.481 | 0.71x | 1.40x |
| latin-4096 | utf8-to-utf16 | 3228.168 | 1893.681 | 2176.208 | 0.59x | 0.67x |
| latin-4096 | utf16-to-utf8 | 1300.098 | 642.379 | 1683.995 | 0.49x | 1.30x |
| chinese-32 | utf8-to-utf16 | 12.856 | 23.104 | 23.756 | 1.80x | 1.85x |
| chinese-32 | utf16-to-utf8 | 9.432 | 18.211 | 18.771 | 1.93x | 1.99x |
| chinese-128 | utf8-to-utf16 | 12.899 | 82.279 | 87.707 | 6.38x | 6.80x |
| chinese-128 | utf16-to-utf8 | 10.287 | 32.087 | 62.842 | 3.12x | 6.11x |
| chinese-4096 | utf8-to-utf16 | 358.294 | 948.077 | 2077.874 | 2.65x | 5.80x |
| chinese-4096 | utf16-to-utf8 | 255.604 | 419.427 | 1390.629 | 1.64x | 5.44x |
| mixed-32 | utf8-to-utf16 | 88.044 | 68.495 | 67.002 | 0.78x | 0.76x |
| mixed-32 | utf16-to-utf8 | 67.547 | 46.750 | 50.206 | 0.69x | 0.74x |
| mixed-128 | utf8-to-utf16 | 162.330 | 121.197 | 123.006 | 0.75x | 0.76x |
| mixed-128 | utf16-to-utf8 | 139.251 | 76.592 | 93.508 | 0.55x | 0.67x |
| mixed-4096 | utf8-to-utf16 | 2986.452 | 1923.839 | 2273.286 | 0.64x | 0.76x |
| mixed-4096 | utf16-to-utf8 | 2800.280 | 1019.975 | 1626.036 | 0.36x | 0.58x |
| emoji-32 | utf8-to-utf16 | 12.203 | 31.216 | 57.112 | 2.56x | 4.68x |
| emoji-32 | utf16-to-utf8 | 9.692 | 27.682 | 28.541 | 2.86x | 2.94x |
| emoji-128 | utf8-to-utf16 | 25.720 | 99.178 | 153.158 | 3.86x | 5.95x |
| emoji-128 | utf16-to-utf8 | 17.691 | 75.786 | 79.251 | 4.28x | 4.48x |
| emoji-4096 | utf8-to-utf16 | 584.156 | 2345.668 | 3670.687 | 4.02x | 6.28x |
| emoji-4096 | utf16-to-utf8 | 389.932 | 1971.946 | 1951.573 | 5.06x | 5.00x |
| tiny-ascii-31 | utf8-to-utf16 | 5.269 | 11.899 | 24.247 | 2.26x | 4.60x |
| tiny-ascii-31 | utf16-to-utf8 | 12.162 | 11.429 | 22.478 | 0.94x | 1.85x |
| tiny-emoji-31 | utf8-to-utf16 | 5.128 | 22.002 | 38.244 | 4.29x | 7.46x |
| tiny-emoji-31 | utf16-to-utf8 | 4.520 | 19.581 | 21.228 | 4.33x | 4.70x |

## Reproduce

```sh
zig build bench-utf16-build
# Use the simdutf 9.5.0 amalgamation generated by the previous profile.
ICUZ_ICU_PREFIX=/path/to/icu-78.3
g++ -O3 -std=c++17 -I /tmp/icuz-simdutf-9.5.0/amalgamation \
  -I "$ICUZ_ICU_PREFIX/include" bench/utf16/compare.cpp \
  /tmp/icuz-simdutf-9.5.0/amalgamation/simdutf.cpp \
  -L "$ICUZ_ICU_PREFIX/lib" -Wl,-rpath,"$ICUZ_ICU_PREFIX/lib" \
  -licuuc -licudata -pthread -o /tmp/icuz-transcode-external

mkdir -p /tmp/icuz-convert-before
git archive 88fdb07 src/unicode/utf16.zig src/unicode/scalar | tar -x -C /tmp/icuz-convert-before
zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/bench.zig \
  -O ReleaseFast -Mutf16=/tmp/icuz-convert-before/src/unicode/utf16.zig \
  -femit-bin=/tmp/icuz-utf16-before
python3 bench/utf16/compare.py --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-utf16-before --external /tmp/icuz-transcode-external \
  --cpu 2 --rounds 3 --output /tmp/icuz-utf16-conversion.json

zig test src/unicode/utf16.zig -O ReleaseSafe --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline --test-filter UTF
zig test src/unicode/utf16.zig -O Debug --test-filter guarded
zig test src/unicode/utf16.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target powerpc64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/charset.zig -O ReleaseSafe --test-filter 'UTF-8 three-byte runs'
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```

The external source fetch and amalgamation commands are in the
[UTF-8 profile](utf8-short-validation-2026-11-26.md#reproduce).
