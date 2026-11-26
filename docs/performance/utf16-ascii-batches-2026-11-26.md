# ASCII and batched UTF conversion profile, 2026-11-26

This profile compares current strict conversion with `a611885`, the preceding
variable-width implementation, and `7f3939c`, the original vectorized APIs.
It isolates owned allocation from warmed caller-buffer conversion. The large
Latin caller-buffer rows now exceed simdutf 9.5.0 in both directions on this
hardware. ASCII UTF-16→UTF-8 also improves in both API contracts.

## Method and provenance

- Intel Core i9-13900K, logical CPU 2, Linux x86-64. Zig 0.16.0 ReleaseFast
  native; external GCC 13 `-O3 -std=c++17`, simdutf 9.5.0 `haswell`, ICU 78.3.
- Seventeen identical inputs: ASCII, accented Latin, Chinese, mixed scripts
  and emoji, pure emoji, and short tails around 31 bytes. Names use minimum
  UTF-8 sizes; the JSON records exact input bytes and native UTF-16 units.
- Five rounds, five trials per row, about 8 MiB of original corpus bytes per
  trial and at least 2,000 calls. Tables show the minimum ns/op across rounds.
- Libraries run sequentially for each corpus on CPU 2. Order is
  icuz/external/a611885/7f3939c in even-numbered rounds, reversed in odd rounds.
  This task's compilation and tests finish before sampling. Other workstation
  activity remains visible in the raw per-round values.
- Owned rows include validation, exact sizing, allocating, converting, and
  freeing the result. Reuse rows perform strict conversion into warmed caller
  buffers. Only reuse rows are compared with the strict simdutf and ICU
  caller-buffer APIs; their allocation is outside the timed loop.
- icuz and both predecessors check output against independent std conversion.
  The external harness checks status, length, and content. The Python driver
  verifies every required row, input length, and output size.
- Both preserved predecessor binary hashes match the
  [preceding profile](utf16-variable-width-2026-11-26.json): its icuz binary is
  `a611885`, its baseline is `7f3939c`. The external binary hash also matches.
  simdutf source commit: `9064366fa571fac03bcd28db35af597e97fba842`.
- [Raw evidence](utf16-ascii-batches-2026-11-26.json) contains all samples,
  input hashes, binary hashes, and current converter/validator/build/driver
  source hashes. `baseline` denotes `a611885`; `reference` denotes `7f3939c`.

## Implementation

ASCII UTF-16 conversion uses a dedicated fixed-stride scan. Finding the first
non-ASCII position stays in a separate cold helper, so the uniform loop does
not depend on a per-block bit-count result. Overlapping tail loads remain
within input bounds. An initial mixed window is left for BMP packing. Small
calls inline the scanner; large calls keep its vector state local.

When the exact UTF-8 size equals the number of UTF-16 units, the validated
input is entirely ASCII: every other scalar needs more bytes per unit. Owned
conversion and insufficient-capacity Into calls reuse that result and copy
without classifying again. A compact validated entry avoids expanding the
general dispatch inside allocating callers. Public signatures, native
endianness, exact owned sizes, and prefix-preserving errors are unchanged.

Latin UTF-8 decoding classifies bounded 64-byte windows once. High/continuation
masks validate placement, and byte masks reject C0/C1 before decoding groups.
A sixteen-scalar group uses one 32-bit `pext`, two eight-scalar controls, and
one AVX2 shuffle/multiply-add. Masked byte weights produce at most U+07FF, so
signed saturation stays inactive. Shuffle/bit/weight controls occupy 16 KiB
with 64-byte alignment. The short eight-scalar path uses AVX/SSSE3/BMI2; AVX2
gates the wide classification and sixteen-scalar path.

The final batch tail reads the last sixteen bytes inside the classified
window and shifts them in registers. Zero padding may participate in a
candidate decode, but only a group entirely inside the real window can
commit. A lead in byte 63 is deferred to the next window. Portable kernels
and bounded array loads for non-LLVM backends remain available. Conversion
tests are grouped under `src/unicode/utf/convert/tests/`.

## Owned allocation comparison

Speedup is a611885/current. These rows include producing and freeing the owned result.

| Corpus | Direction | Current ns | a611885 ns | 7f3939c ns | Speedup |
|---|---|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 26.692 | 26.704 | 23.930 | 1.00x |
| ascii-32 | utf16-to-utf8 | 19.126 | 25.296 | 22.991 | 1.32x |
| ascii-128 | utf8-to-utf16 | 27.530 | 27.825 | 24.593 | 1.01x |
| ascii-128 | utf16-to-utf8 | 25.044 | 30.940 | 28.938 | 1.24x |
| ascii-4096 | utf8-to-utf16 | 245.230 | 244.951 | 235.371 | 1.00x |
| ascii-4096 | utf16-to-utf8 | 294.016 | 346.348 | 352.465 | 1.18x |
| latin-32 | utf8-to-utf16 | 52.321 | 52.821 | 62.934 | 1.01x |
| latin-32 | utf16-to-utf8 | 32.530 | 33.046 | 36.576 | 1.02x |
| latin-128 | utf8-to-utf16 | 94.367 | 129.338 | 154.991 | 1.37x |
| latin-128 | utf16-to-utf8 | 53.492 | 53.409 | 75.927 | 1.00x |
| latin-4096 | utf8-to-utf16 | 1758.152 | 2965.149 | 3408.063 | 1.69x |
| latin-4096 | utf16-to-utf8 | 940.370 | 942.633 | 1659.630 | 1.00x |
| chinese-32 | utf8-to-utf16 | 26.481 | 26.216 | 23.733 | 0.99x |
| chinese-32 | utf16-to-utf8 | 23.765 | 23.854 | 24.191 | 1.00x |
| chinese-128 | utf8-to-utf16 | 34.519 | 34.517 | 31.562 | 1.00x |
| chinese-128 | utf16-to-utf8 | 22.677 | 23.147 | 22.549 | 1.02x |
| chinese-4096 | utf8-to-utf16 | 549.613 | 554.768 | 547.012 | 1.01x |
| chinese-4096 | utf16-to-utf8 | 381.199 | 380.147 | 370.788 | 1.00x |
| mixed-32 | utf8-to-utf16 | 88.015 | 91.445 | 94.294 | 1.04x |
| mixed-32 | utf16-to-utf8 | 65.963 | 66.018 | 83.932 | 1.00x |
| mixed-128 | utf8-to-utf16 | 163.006 | 161.281 | 175.948 | 0.99x |
| mixed-128 | utf16-to-utf8 | 117.422 | 116.378 | 164.144 | 0.99x |
| mixed-4096 | utf8-to-utf16 | 2702.032 | 2689.811 | 2932.556 | 1.00x |
| mixed-4096 | utf16-to-utf8 | 1994.973 | 1958.448 | 3073.416 | 0.98x |
| emoji-32 | utf8-to-utf16 | 29.886 | 29.904 | 27.397 | 1.00x |
| emoji-32 | utf16-to-utf8 | 22.901 | 23.212 | 22.735 | 1.01x |
| emoji-128 | utf8-to-utf16 | 46.421 | 46.419 | 43.627 | 1.00x |
| emoji-128 | utf16-to-utf8 | 36.214 | 36.505 | 34.409 | 1.01x |
| emoji-4096 | utf8-to-utf16 | 826.388 | 827.935 | 821.199 | 1.00x |
| emoji-4096 | utf16-to-utf8 | 713.040 | 722.456 | 700.444 | 1.01x |
| tiny-ascii-31 | utf8-to-utf16 | 29.405 | 29.104 | 27.078 | 0.99x |
| tiny-ascii-31 | utf16-to-utf8 | 20.989 | 27.956 | 27.362 | 1.33x |
| tiny-emoji-31 | utf8-to-utf16 | 20.869 | 20.896 | 18.684 | 1.00x |
| tiny-emoji-31 | utf16-to-utf8 | 17.754 | 18.097 | 18.044 | 1.02x |

## Warmed reusable-buffer comparison

Speedup columns are a611885/current and simdutf/current. Values below 1 mean
current icuz takes longer.

| Corpus | Direction | Current ns | a611885 ns | 7f3939c ns | simdutf ns | ICU ns | vs a611885 | vs simdutf |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ascii-32 | utf8-to-utf16 | 4.760 | 4.760 | 4.510 | 12.397 | 36.944 | 1.00x | 2.60x |
| ascii-32 | utf16-to-utf8 | 4.103 | 8.782 | 5.660 | 10.445 | 37.197 | 2.14x | 2.55x |
| ascii-128 | utf8-to-utf16 | 6.565 | 6.772 | 6.287 | 9.897 | 95.250 | 1.03x | 1.51x |
| ascii-128 | utf16-to-utf8 | 9.058 | 11.777 | 8.779 | 13.806 | 92.317 | 1.30x | 1.52x |
| ascii-4096 | utf8-to-utf16 | 97.228 | 98.057 | 97.221 | 110.753 | 2099.978 | 1.01x | 1.14x |
| ascii-4096 | utf16-to-utf8 | 112.818 | 152.028 | 140.446 | 198.239 | 2083.570 | 1.35x | 1.76x |
| latin-32 | utf8-to-utf16 | 35.516 | 37.103 | 47.063 | 38.281 | 38.354 | 1.04x | 1.08x |
| latin-32 | utf16-to-utf8 | 12.645 | 12.058 | 18.151 | 23.602 | 27.879 | 0.95x | 1.87x |
| latin-128 | utf8-to-utf16 | 68.149 | 111.164 | 128.860 | 87.334 | 92.503 | 1.63x | 1.28x |
| latin-128 | utf16-to-utf8 | 26.078 | 25.084 | 49.823 | 35.232 | 70.178 | 0.96x | 1.35x |
| latin-4096 | utf8-to-utf16 | 1529.705 | 2730.404 | 3229.798 | 1897.726 | 2161.948 | 1.78x | 1.24x |
| latin-4096 | utf16-to-utf8 | 521.242 | 527.618 | 1299.051 | 617.436 | 1665.873 | 1.01x | 1.18x |
| chinese-32 | utf8-to-utf16 | 12.409 | 12.148 | 12.903 | 23.244 | 23.827 | 0.98x | 1.87x |
| chinese-32 | utf16-to-utf8 | 9.436 | 10.274 | 9.752 | 18.161 | 18.720 | 1.09x | 1.92x |
| chinese-128 | utf8-to-utf16 | 13.422 | 13.442 | 12.903 | 83.426 | 87.645 | 1.00x | 6.22x |
| chinese-128 | utf16-to-utf8 | 12.255 | 10.743 | 10.305 | 32.481 | 63.239 | 0.88x | 2.65x |
| chinese-4096 | utf8-to-utf16 | 359.096 | 358.383 | 359.311 | 944.079 | 2076.737 | 1.00x | 2.63x |
| chinese-4096 | utf16-to-utf8 | 271.288 | 271.435 | 256.058 | 407.501 | 1388.295 | 1.00x | 1.50x |
| mixed-32 | utf8-to-utf16 | 79.846 | 84.280 | 87.377 | 68.357 | 67.076 | 1.06x | 0.86x |
| mixed-32 | utf16-to-utf8 | 50.682 | 47.704 | 67.709 | 47.139 | 50.489 | 0.94x | 0.93x |
| mixed-128 | utf8-to-utf16 | 155.472 | 163.630 | 162.309 | 121.832 | 123.595 | 1.05x | 0.78x |
| mixed-128 | utf16-to-utf8 | 92.563 | 87.997 | 139.362 | 76.345 | 92.067 | 0.95x | 0.82x |
| mixed-4096 | utf8-to-utf16 | 2487.300 | 2347.148 | 2989.645 | 1921.940 | 2258.146 | 0.94x | 0.77x |
| mixed-4096 | utf16-to-utf8 | 1674.331 | 1658.007 | 2801.149 | 1040.535 | 1650.145 | 0.99x | 0.62x |
| emoji-32 | utf8-to-utf16 | 12.569 | 12.551 | 12.195 | 31.245 | 57.162 | 1.00x | 2.49x |
| emoji-32 | utf16-to-utf8 | 10.901 | 9.467 | 9.213 | 27.947 | 28.537 | 0.87x | 2.56x |
| emoji-128 | utf8-to-utf16 | 26.227 | 26.193 | 25.762 | 99.347 | 153.668 | 1.00x | 3.79x |
| emoji-128 | utf16-to-utf8 | 19.649 | 18.363 | 18.087 | 73.480 | 80.284 | 0.93x | 3.74x |
| emoji-4096 | utf8-to-utf16 | 593.793 | 585.025 | 584.420 | 2345.393 | 3671.251 | 0.99x | 3.95x |
| emoji-4096 | utf16-to-utf8 | 408.591 | 401.609 | 390.144 | 1963.393 | 1950.464 | 0.98x | 4.81x |
| tiny-ascii-31 | utf8-to-utf16 | 5.271 | 5.267 | 5.268 | 12.014 | 24.227 | 1.00x | 2.28x |
| tiny-ascii-31 | utf16-to-utf8 | 3.781 | 11.428 | 12.263 | 11.404 | 22.364 | 3.02x | 3.02x |
| tiny-emoji-31 | utf8-to-utf16 | 5.464 | 5.452 | 5.147 | 21.975 | 38.238 | 1.00x | 4.02x |
| tiny-emoji-31 | utf16-to-utf8 | 5.576 | 4.768 | 4.518 | 19.359 | 21.252 | 0.85x | 3.47x |

## Remaining work

The active optimization goal remains broader than this profile. Mixed-script
conversion still trails simdutf. The large mixed UTF-8→UTF-16 reuse row also
adds about 6% versus a611885, while remaining faster than 7f3939c. Large
Chinese UTF-16→UTF-8 remains about 6% slower than the original vectorized
implementation. Short allocating UTF-8→UTF-16 rows retain older overhead.
The complete tables expose these gaps and small regressions; they are not
evidence of universal industry leadership. Other CPUs and instruction sets
need their own performance profiles.

## Reproduce

Use the external binary build from the
[original conversion profile](utf16-conversion-2026-11-26.md#reproduce).
Rebuild both predecessors with the same benchmark source:

```sh
zig build bench-utf16-build
for revision in a611885 7f3939c; do
  revision_dir="/tmp/icuz-conversion-$revision"
  mkdir -p "$revision_dir"
  git archive "$revision" src/unicode/utf16.zig src/unicode/utf src/unicode/scalar | tar -x -C "$revision_dir"
  zig build-exe -O ReleaseFast -lc --dep utf16 -Mroot=bench/utf16/bench.zig \
    -O ReleaseFast -Mutf16="$revision_dir/src/unicode/utf16.zig" \
    -femit-bin="/tmp/icuz-utf16-$revision-rebuilt"
done
python3 bench/utf16/compare.py --icuz zig-out/bin/icuz-utf16-bench \
  --baseline /tmp/icuz-utf16-a611885-rebuilt --baseline-reuse \
  --reference /tmp/icuz-utf16-7f3939c-rebuilt \
  --external /tmp/icuz-transcode-external --cpu 2 --rounds 5 --interleave-cases \
  --output /tmp/icuz-ascii-batches-reproduced.json
```

## Validation

- Native ReleaseSafe UTF module: 22/22 passed.
- Baseline x86-64 ReleaseSafe UTF module: 22/22 passed.
- Debug guarded input/exact output tests: 4/4 passed.
- AArch64 and big-endian PowerPC64 ReleaseSafe compilation passed, using
  `-fno-emit-bin`; these are compilation checks rather than runtime profiles.
- Full library ReleaseSafe: 4/4 build steps succeeded, 532/532 tests passed.
- Unicode verifier: 431 blobs, 34 generated sources, 3 generated bitmaps,
  and 134 generators verified.
- Coverage includes every Unicode scalar, every two-byte scalar in batched
  windows, all 65,536 sixteen-scalar UTF-8 width masks in both checked and
  prevalidated paths, all 256 recurring width patterns across batch boundaries,
  all 65,536 sixteen-unit Latin encoding masks, all 6,561 eight-unit BMP
  patterns, 513-unit ASCII transitions, malformed/truncated neighbors,
  surrogate positions, exact ends, preserved prefixes, and allocation failure.
- Source and binary hashes matched the recorded profile after validation.

```sh
zig test src/unicode/utf16.zig -O ReleaseSafe --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target x86_64-linux-gnu -mcpu baseline --test-filter UTF
zig test src/unicode/utf16.zig -O Debug --test-filter guarded
zig test src/unicode/utf16.zig -O ReleaseSafe -target aarch64-linux-gnu -fno-emit-bin --test-filter UTF
zig test src/unicode/utf16.zig -O ReleaseSafe -target powerpc64-linux-gnu -fno-emit-bin --test-filter UTF
zig build test -Doptimize=ReleaseSafe --summary all
zig build unicode-verify
```
